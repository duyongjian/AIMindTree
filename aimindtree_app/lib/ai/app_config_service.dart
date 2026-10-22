/// App 运行配置下发拉取器（AC-16 / AC-17）。
///
/// 启动时向 llm_server 打一次 `GET /v1/app/config`（**无鉴权**），把下发的
/// 服务地址 / 后端 / 模型幂等落到 `ai_providers` 表，从此设置页只显示
/// 「AI 服务状态」，不再有运维级配置 UI。
///
/// 三条硬约束：
/// - **永不抛异常**（R2）：网络失败 / 坏 JSON / schema 不对都走降级，
///   由 [AppConfigSource] 表达「这次是怎么来的」；
/// - **绝不阻塞首帧**：单地址 3s、总预算 8s，连接被拒会立即返回；
/// - **落库幂等**（AC-17）：sha1 相同且四列一致则跳过写库。
///
/// ⚠️ 落库只用 `settings_repository.dart` 现有的 4 个方法
/// （`addLlmServerProvider` / `updateLlmServerProvider` / `setEnabled` /
/// `allProviders`），列解析只用 [backendOf] / [firstModel]（C1 + C8：表结构
/// 零改动、白名单只有一份实现）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/id.dart';
import '../core/logger.dart';
import '../core/secret_store.dart';
import '../data/db/drift_database.dart';
import '../data/repositories/settings_repository.dart';
import '../data/sync/sync_config.dart';
import 'clients/llm_server_client.dart';

/// 下发配置来源（决定状态区怎么说话）。
enum AppConfigSource {
  /// 200 且 `schema == 1`：真拿到了下发值。
  pushed,

  /// 服务在跑但版本较旧（404 / 405）：用内置默认值，功能部分可用。
  legacyService,

  /// 用了内置默认值（某一个候选失败，或全部失败前的兜底）。
  builtinDefault,

  /// 所有候选都试过且都失败：服务不可达。
  unreachable,
}

/// 同步（Supabase）下发段（契约 `GET /v1/app/config` 的 `sync` 对象：
/// `{ base_url, enabled, token(可 null), token_set }`）。
///
/// - [token]：服务端下发的 token 明文。**只经 SecretStore 落本机**，绝不入
///   prefs / DB；`null` = 服务端没有下发 token。
/// - [tokenSet]：服务端是否已配置 token。`token` 为 null 但为 true 时，
///   App **不动**本地已存 token（任务 B）。
/// - [present]：响应里是否**真的有** `sync` 段。旧服务（无下发 / 404 降级 /
///   内置默认快照）为 false —— 此时 App 绝不改写本地同步配置（优雅降级）。
class SyncPush {
  const SyncPush({
    required this.baseUrl,
    required this.enabled,
    required this.tokenSet,
    this.token,
    this.present = false,
  });

  final String baseUrl;
  final bool enabled;
  final bool tokenSet;
  final String? token;
  final bool present;

  /// 服务端给空则「保留本地」：App 用 [baseUrl] 是否为空判断。
  bool get hasBaseUrl => baseUrl.trim().isNotEmpty;
}

/// 一份下发快照（字段与服务端 `core/app_config.py` 的 13 字段一一对应）。
class AppConfigSnapshot {
  const AppConfigSnapshot({
    required this.schema,
    required this.serverVersion,
    required this.serviceName,
    required this.protocol,
    required this.baseUrl,
    required this.backend,
    required this.model,
    required this.consoleUrl,
    required this.timeouts,
    required this.taskBackends,
    required this.sync,
    required this.configSha1,
    required this.updatedAt,
  });

  /// 只认 1；其它值 App 按「不支持下发」处理。
  final int schema;

  final String serverVersion;
  final String serviceName;

  /// 恒 `llm_server`。
  final String protocol;

  final String baseUrl;

  /// 原始值（可能不在白名单里）；落库前必须走 [backendOf]。
  final String backend;

  /// 空 = 用后端默认模型。
  final String model;

  final String consoleUrl;
  final Map<String, int> timeouts;

  /// 仅展示 / 诊断用：App **不做**本地路由（C11）。
  final Map<String, Object?> taskBackends;

  final SyncPush sync;
  final String configSha1;
  final String updatedAt;

  /// 内置默认快照（服务不可达 / 版本过旧时用）。
  factory AppConfigSnapshot.builtin() => AppConfigSnapshot(
        schema: 1,
        serverVersion: '',
        serviceName: 'AIMindTree AI 服务',
        protocol: kLlmServerProtocol,
        baseUrl: kLlmServerDefaultBaseUrl,
        backend: 'auto',
        model: '',
        consoleUrl: '$kLlmServerDefaultBaseUrl/admin',
        timeouts: const <String, int>{
          'structured_s': 120,
          'chat_s': 120,
          'connect_s': 10,
        },
        taskBackends: const <String, Object?>{},
        sync: const SyncPush(baseUrl: '', enabled: false, tokenSet: false),
        configSha1: '',
        updatedAt: '',
      );

  /// 展示用短 sha1（前 8 位）。
  String get shortSha1 =>
      configSha1.length <= 8 ? configSha1 : configSha1.substring(0, 8);
}

/// 下发拉取 + 幂等落库。
class AppConfigService {
  AppConfigService._();

  /// 最近一次成功 / 降级的快照（进程内静态单例，D6）。
  ///
  /// 不改 `bootstrap` 返回的 5 元组、不改 `main.dart` 的解构 —— 设置页状态区
  /// 直接读这里。
  static AppConfigSnapshot? last;

  /// 最近一次的来源（默认「不可达」，与「还没拉过」同义）。
  static AppConfigSource lastSource = AppConfigSource.unreachable;

  /// `SharedPreferences` 里存 sha1 的键。
  static const String kSha1Key = 'ai_config_sha1';

  static final AppLog _log = AppLog('ai_config');

  /// 纯函数：解析下发 JSON。
  ///
  /// `schema != 1` 或字段缺失严重 → 抛 [FormatException]（调用方按「不支持
  /// 下发」降级到内置默认，等价于服务端 404 分支）。
  static AppConfigSnapshot parse(Object? decoded) {
    if (decoded is! Map) {
      throw const FormatException('下发配置不是 JSON 对象');
    }
    final map = Map<String, dynamic>.from(decoded);
    final rawSchema = (map['schema'] as num?)?.toInt();
    if (rawSchema == null || rawSchema != 1) {
      throw FormatException('不支持的下发 schema：$rawSchema（只识别 1）');
    }
    final schema = rawSchema;

    final baseUrl = (map['base_url'] as String?) ?? '';
    if (baseUrl.trim().isEmpty) {
      throw const FormatException('下发配置缺少 base_url');
    }
    final backend = (map['backend'] as String?) ?? '';
    if (backend.trim().isEmpty) {
      throw const FormatException('下发配置缺少 backend');
    }

    // timeouts：缺字段按内置值兜底，非法值忽略。
    final rawTimeouts = map['timeouts'];
    final timeouts = <String, int>{
      'structured_s': 120,
      'chat_s': 120,
      'connect_s': 10,
    };
    if (rawTimeouts is Map) {
      for (final entry in rawTimeouts.entries) {
        final key = entry.key.toString();
        final value = (entry.value as num?)?.toInt();
        if (value != null && timeouts.containsKey(key)) timeouts[key] = value;
      }
    }

    // task_backends：仅展示，不做本地路由（C11）。
    final taskBackends = <String, Object?>{};
    final rawTasks = map['task_backends'];
    if (rawTasks is Map) {
      for (final entry in rawTasks.entries) {
        taskBackends[entry.key.toString()] = entry.value;
      }
    }

    // sync：服务端恒返回 object（Q-C），这里仍做空态兜底。
    // 契约形状：{ base_url, enabled, token(可 null), token_set }。
    // present=false（无 sync 段）= 旧服务 → apply 时本地同步配置分毫不动。
    SyncPush sync = const SyncPush(baseUrl: '', enabled: false, tokenSet: false);
    final rawSync = map['sync'];
    if (rawSync is Map) {
      sync = SyncPush(
        baseUrl: (rawSync['base_url'] as String?) ?? '',
        // 缺省 true：管理后台一旦下发 sync 段，默认即开启自动同步（任务 B）。
        enabled: (rawSync['enabled'] as bool?) ?? true,
        tokenSet: (rawSync['token_set'] as bool?) ?? false,
        token: rawSync['token'] as String?,
        present: true,
      );
    }

    return AppConfigSnapshot(
      schema: schema,
      serverVersion: (map['server_version'] as String?) ?? '',
      serviceName: (map['service_name'] as String?) ?? '',
      protocol: (map['protocol'] as String?) ?? kLlmServerProtocol,
      baseUrl: baseUrl,
      backend: backend,
      model: (map['model'] as String?) ?? '',
      consoleUrl: (map['console_url'] as String?) ?? '',
      timeouts: timeouts,
      taskBackends: taskBackends,
      sync: sync,
      configSha1: (map['config_sha1'] as String?) ?? '',
      updatedAt: (map['updated_at'] as String?) ?? '',
    );
  }

  /// 纯函数：是否真的要写库（AC-17 / N-7，双保险，任一满足即跳过）。
  ///
  /// - [lastSha1]：上次落库时记的 sha1（可能为 null = 从没写过）；
  /// - [row]：目标行（可能为 null = 表里还没有 llm_server 行）。
  static bool shouldWrite({
    required String? lastSha1,
    required AppConfigSnapshot snap,
    required AiProviderRow? row,
    required String name,
    required String base,
    required String backend,
    required String model,
  }) {
    // 降级快照（服务不可达 / 旧版本）没有服务端 sha1（空串）。此时用「上次也是
    // 空」当作 sha1 命中，配合 rowMatches 兜住「服务一直没起」的重复启动 ——
    // 否则每次启动都会因为 sameSha=false 而白写一次库（违反 N-7）。
    final sameSha = lastSha1 != null &&
        (snap.configSha1.isEmpty
            ? lastSha1.isEmpty
            : lastSha1 == snap.configSha1);
    final rowMatches = row != null &&
        row.name == name &&
        row.baseUrl == base &&
        backendOf(row.type) == backend &&
        firstModel(row.models) == model;
    return !(sameSha && rowMatches); // true = 要写
  }

  /// 网络：依次试候选，返回非空快照（内置默认兜底）。**永不抛异常**。
  ///
  /// 404 / 405 → [AppConfigSource.legacyService] 并**立即停**（服务在跑，
  /// 只是版本旧，再试其它地址没意义）。
  static Future<AppConfigSource> fetch({
    required List<String> candidates,
    Duration perTry = const Duration(seconds: 3),
    Duration totalBudget = const Duration(seconds: 8),
  }) async {
    final sw = Stopwatch()..start();
    var anyReachable = false;

    for (final raw in candidates) {
      final remaining = totalBudget - sw.elapsed;
      if (remaining <= Duration.zero) break;

      final base = _trimSlash(raw);
      if (base.isEmpty) continue;

      HttpClient? client;
      try {
        client = HttpClient()..connectionTimeout = perTry;
        final budget = remaining < perTry ? remaining : perTry;
        final uri = Uri.parse('$base/v1/app/config');
        final req = await client.getUrl(uri).timeout(budget);
        final resp = await req.close().timeout(budget);
        final body = await resp
            .transform(utf8.decoder)
            .join()
            .timeout(budget);
        final status = resp.statusCode;

        if (status == 404 || status == 405) {
          // 服务在跑但不支持下发 → 旧版本，用内置默认，不再试其它地址。
          last = AppConfigSnapshot.builtin();
          lastSource = AppConfigSource.legacyService;
          _log.w('$base 不支持 /v1/app/config（HTTP $status），按旧版本降级');
          return lastSource;
        }
        if (status < 200 || status >= 300) {
          anyReachable = true;
          _log.w('$base/v1/app/config 返回 HTTP $status');
          continue;
        }
        final decoded = jsonDecode(body);
        final snap = parse(decoded);
        last = snap;
        lastSource = AppConfigSource.pushed;
        _log.i(
          'source=pushed sha1=${snap.shortSha1} base=${snap.baseUrl} '
          'backend=${snap.backend} model=${snap.model}',
        );
        return lastSource;
      } on Object catch (e) {
        _log.w('$base/v1/app/config 拉取失败：$e');
      } finally {
        // Windows 上不 force close 会泄漏句柄（R2）。
        client?.close(force: true);
      }
    }

    last ??= AppConfigSnapshot.builtin();
    lastSource =
        anyReachable ? AppConfigSource.builtinDefault : AppConfigSource.unreachable;
    _log.w('全部候选都未命中（$lastSource），使用内置默认 ${last?.baseUrl}');
    return lastSource;
  }

  /// 拉取 + 幂等落库（bootstrap 与「重新连接」共用）。**永不抛异常**。
  ///
  /// 候选地址 = 已存的 `llm_server` 行 base_url（按出现顺序去重）
  /// + 内置 `kLlmServerDefaultBaseUrl` + 可选 `extraCandidates`（测试注入）。
  ///
  /// [syncConfig] / [secretStore]（任务 B）：消费下发 `sync` 段时使用；
  /// 缺省走 [FileSecretStore] 默认实例（与 main.dart 同一个 secrets 文件，
  /// `sync_<ulid>` ref 机制与设置页完全一致）。
  static Future<AppConfigSnapshot> fetchAndApply(
    SettingsRepository repo,
    SharedPreferences prefs, {
    List<String>? extraCandidates,
    SyncConfig? syncConfig,
    SecretStore? secretStore,
  }) async {
    try {
      final candidates = <String>[];
      final rows = await repo.allProviders();
      for (final r in rows) {
        if (r.protocol != kLlmServerProtocol) continue;
        final url = _trimSlash(r.baseUrl);
        if (url.isNotEmpty && !candidates.contains(url)) candidates.add(url);
      }
      if (!candidates.contains(kLlmServerDefaultBaseUrl)) {
        candidates.add(kLlmServerDefaultBaseUrl);
      }
      for (final extra in extraCandidates ?? const <String>[]) {
        final url = _trimSlash(extra);
        if (url.isNotEmpty && !candidates.contains(url)) candidates.add(url);
      }

      await fetch(candidates: candidates);
      await apply(
        repo,
        prefs,
        syncConfig: syncConfig,
        secretStore: secretStore,
      );
    } on Object catch (e, s) {
      // 整体吞异常：配置拉取失败绝不能让 App 起不来（R2）。
      _log.e('fetchAndApply 失败（已降级为内置默认）', error: e, stackTrace: s);
      last ??= AppConfigSnapshot.builtin();
    }
    return last ?? AppConfigSnapshot.builtin();
  }

  /// 幂等落库（AC-17）。只用 repository 现有的 4 个方法（C1）。
  ///
  /// 任务 B：响应含 `sync` 段时，顺带把系统级同步配置落到 SyncConfig / prefs /
  /// SecretStore（增量、优雅降级：旧服务无 sync 段时本地值分毫不动）。
  /// [syncConfig] / [secretStore] 供测试与设置页「重新连接」注入；缺省用
  /// [FileSecretStore] 默认实例。
  static Future<void> apply(
    SettingsRepository repo,
    SharedPreferences prefs, {
    SyncConfig? syncConfig,
    SecretStore? secretStore,
  }) async {
    final snap = last;
    if (snap == null) return;
    try {
      final rows = await repo.allProviders();
      final llm = rows
          .where((r) => r.protocol == kLlmServerProtocol)
          .toList(growable: false);
      AiProviderRow? target;
      for (final r in llm) {
        if (r.isDefault) {
          target = r;
          break;
        }
      }
      target ??= llm.isEmpty ? null : llm.first;

      // 降级守卫（架构师裁定 R-降级）：来源不是「服务端下发」时（服务不可达 /
      // 旧版服务 404 / 整体异常），绝不用降级快照改写已存在的真实下发行 ——
      // 否则首次成功下发（可能是局域网地址）后服务临时挂掉，该行会被写成
      // `127.0.0.1` 且服务恢复前改不回来。只有表里**没有** llm_server 行时
      // 才允许 seed 一次。
      if (lastSource != AppConfigSource.pushed && target != null) {
        _log.i('source=$lastSource 已有 llm_server 行（id=${target.id}），'
            '降级快照不落库，保留下发行');
        return;
      }

      // 任务 B：消费下发的 sync 段。放在 sha1 幂等判断**之前** —— 老版本 App
      // 可能落过相同 sha1 却从没消费过 sync，升级后必须补上，否则管理后台
      // 下发的同步配置永远到不了本机。
      await _applySyncConfig(
        prefs,
        syncConfig: syncConfig,
        secretStore: secretStore,
      );

      final backend = backendOf(snap.backend); // 唯一的白名单容错（C8）
      final model = snap.model.trim();
      final name = snap.serviceName.trim().isEmpty
          ? 'AIMindTree AI 服务'
          : snap.serviceName.trim();
      final base = snap.baseUrl.trim().isEmpty
          ? kLlmServerDefaultBaseUrl
          : snap.baseUrl.trim();

      final lastSha1 = prefs.getString(kSha1Key);
      final write = shouldWrite(
        lastSha1: lastSha1,
        snap: snap,
        row: target,
        name: name,
        base: base,
        backend: backend,
        model: model,
      );
      if (!write) {
        _log.i('source=$lastSource sha1=${snap.shortSha1} 落库=跳过 '
            'base=$base backend=$backend model=$model');
        return;
      }

      if (target == null) {
        await repo.addLlmServerProvider(
          displayName: name,
          baseUrl: base,
          backend: backend,
          model: model,
          setDefault: true,
        );
      } else {
        await repo.updateLlmServerProvider(
          target.id,
          name: name,
          baseUrl: base,
          backend: backend,
          model: model,
        );
        await repo.setEnabled(target.id, true);
      }
      await prefs.setString(kSha1Key, snap.configSha1);
      _log.i('source=$lastSource sha1=${snap.shortSha1} 落库=写入 '
          'base=$base backend=$backend model=$model');
    } on Object catch (e, s) {
      _log.e('落库失败（不影响启动）', error: e, stackTrace: s);
    }
  }

  /// 任务 B：把下发 `sync` 段写进 SyncConfig / prefs / SecretStore。
  ///
  /// 规则（契约 + 降级口径）：
  /// - **无 `sync` 段**（旧服务 / 内置默认快照）→ 什么都不写，本地值保留；
  /// - `base_url` 非空 → 写 prefs（空则不覆盖本地已有值）；
  /// - `enabled` → 写 `aimindtree.sync.enabled`（作为默认，用户随后仍可本地
  ///   改；重启后回到管理后台下发的默认值）；
  /// - `token` 非 null → 存 SecretStore 并设 `token_ref`（复用设置页同一
  ///   `sync_<ulid>` ref 机制，旧 ref 删除）；`token` 为 null 但
  ///   `token_set=true` → 不动本地 token。
  ///
  /// **永不抛异常**：写入失败只记日志，绝不影响 ai_providers 落库与启动。
  static Future<void> _applySyncConfig(
    SharedPreferences prefs, {
    SyncConfig? syncConfig,
    SecretStore? secretStore,
  }) async {
    final snap = last;
    if (snap == null) return;
    final push = snap.sync;
    if (!push.present) return; // 旧服务无 sync 段：不回归、不动本地值
    try {
      final store = secretStore ?? await FileSecretStore.defaultInstance();
      final cfg = syncConfig ?? SyncConfig(prefs: prefs, secretStore: store);

      if (push.hasBaseUrl) {
        await cfg.setBaseUrl(push.baseUrl.trim());
      }
      await cfg.setEnabled(push.enabled);

      final token = push.token;
      if (token != null && token.trim().isNotEmpty) {
        // `sync_<ulid>` ref 机制（原设置页 _save() 的口径）：新 ref 写
        // SecretStore，旧 ref 清理，prefs 只留引用名。
        final ref = 'sync_${newUlid()}';
        await store.set(ref, token);
        final old = cfg.tokenRef;
        if (old != null && old != ref) {
          await store.delete(old);
        }
        await cfg.setTokenRef(ref);
      }
      _log.i('sync 段已消费：base=${cfg.baseUrl} enabled=${push.enabled} '
          'tokenSet=${push.tokenSet} tokenRef=${cfg.tokenRef}');
    } on Object catch (e, s) {
      _log.e('sync 段消费失败（同步配置保持本地值）', error: e, stackTrace: s);
    }
  }

  /// 去掉结尾的 `/`，避免拼出 `//v1/app/config`。
  static String _trimSlash(String url) {
    var s = url.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

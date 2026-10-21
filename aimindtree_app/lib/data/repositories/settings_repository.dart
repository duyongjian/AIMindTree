/// AI Provider 配置仓储（T07：密钥不再硬编码）。
///
/// - Provider 记录在 `ai_providers` 表；**llm_server 场景不存密钥**
///   （`api_key_ref` 恒空串，密钥在服务端 `.env`，见密钥边界 C4）。
/// - `api_key_ref` 是**引用名**（如 `dify_<ulid>`），不是密钥本身。
/// - P0 启动会从 [LocalAiConfig] seed 一个 LLM 服务 provider，开箱即用。
///
/// ⚠️ 表结构不可改（Drift 依赖 build_runner）：backend 复用 `type` 列、
/// model 覆盖复用 `models` 列，语义见 `data/db/tables.dart` 的注释。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import '../../ai/ai_task.dart';
import '../../ai/clients/llm_server_client.dart';
import '../../ai/extraction_service.dart';
import '../../core/id.dart';
import '../../core/logger.dart';
import '../../core/secret_store.dart';
import '../db/drift_database.dart';

class SettingsRepository {
  SettingsRepository(this._db, {required this.secretStore});
  final AppDatabase _db;
  final SecretStore secretStore;
  static final AppLog _log = AppLog('settings_repo');

  // ============ 查询 ============

  Future<List<AiProviderRow>> allProviders() =>
      _db.select(_db.aiProviders).get();

  Future<List<AiProviderRow>> enabledProviders() =>
      (_db.select(_db.aiProviders)..where((t) => t.enabled.equals(true))).get();

  Future<AiProviderRow?> firstEnabled() async {
    final rows = await enabledProviders();
    return rows.isEmpty ? null : rows.first;
  }

  // ============ Dify Provider CRUD（已停用，保留仅供回退）============
  //
  // ⚠️ 这两个方法**保留**是有意为之：
  //   ① test/settings_repository_test.dart 里有 14 处调用，删掉 = 大面积编译 error；
  //   ② 三步回退 Dify 时需要它们；
  //   ③ 因此**不得**加 @Deprecated —— 测试仍在调用，会触发全量
  //      deprecated_member_use warning，门禁直接判 fail。

  /// 新增一个 Dify provider：密钥写入 SecretStore，引用名入表。
  Future<AiProviderRow> addDifyProvider({
    required String displayName,
    required String baseUrl,
    required String apiKey,
  }) async {
    final id = newUlid();
    final refName = 'dify_$id';
    await secretStore.set(refName, apiKey);
    await _db
        .into(_db.aiProviders)
        .insert(
          AiProvidersCompanion(
            id: Value(id),
            name: Value(displayName),
            type: Value('dify'),
            protocol: Value('dify'),
            baseUrl: Value(baseUrl),
            apiKeyRef: Value(refName),
            models: const Value('[]'),
            isDefault: const Value(false),
            enabled: const Value(true),
          ),
        );
    return AiProviderRow(
      id: id,
      name: displayName,
      type: 'dify',
      protocol: 'dify',
      baseUrl: baseUrl,
      apiKeyRef: refName,
      models: '[]',
      isDefault: false,
      enabled: true,
      // 无相关字段，留 null
    );
  }

  // ============ LLM Server Provider CRUD ============

  /// 新增一个 LLM 服务 provider。
  ///
  /// 列复用约定（表结构不可改，见 `tables.dart` 注释）：
  /// - `protocol` 恒 `llm_server`；
  /// - `type` 存 backend（`auto`/`ollama`/`minimax`/`openai_compat`）；
  /// - `models` 存 JSON 数组（最多 1 个元素 = model 覆盖，`[]` = 后端默认）；
  /// - `api_key_ref` 恒空串（密钥在服务端 `.env`，C4 密钥边界）。
  Future<AiProviderRow> addLlmServerProvider({
    required String displayName,
    required String baseUrl,
    String backend = 'auto',
    String model = '',
    bool setDefault = false,
  }) async {
    final id = newUlid();
    final modelsJson = encodeLlmServerModels(model);
    await _db.into(_db.aiProviders).insert(
          AiProvidersCompanion(
            id: Value(id),
            name: Value(displayName),
            type: Value(backend),
            protocol: Value(kLlmServerProtocol),
            baseUrl: Value(baseUrl),
            apiKeyRef: const Value(''),
            models: Value(modelsJson),
            isDefault: Value(setDefault),
            enabled: const Value(true),
          ),
        );
    _log.i('新增 LLM 服务 provider：$displayName ($baseUrl, backend=$backend)');
    return AiProviderRow(
      id: id,
      name: displayName,
      type: backend,
      protocol: kLlmServerProtocol,
      baseUrl: baseUrl,
      apiKeyRef: '',
      models: modelsJson,
      isDefault: setDefault,
      enabled: true,
    );
  }

  /// 更新 LLM 服务的连接参数（`type` / `models` 两列的语义见上）。
  ///
  /// 返回更新后的行；id 不存在返回 null。
  Future<AiProviderRow?> updateLlmServerProvider(
    String id, {
    String? name,
    String? baseUrl,
    String? backend,
    String? model,
  }) async {
    final row = await (_db.select(_db.aiProviders)
          ..where((t) => t.id.equals(id))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return null;

    await (_db.update(_db.aiProviders)..where((t) => t.id.equals(id))).write(
      AiProvidersCompanion(
        name: name == null ? const Value.absent() : Value(name),
        baseUrl: baseUrl == null ? const Value.absent() : Value(baseUrl),
        type: backend == null ? const Value.absent() : Value(backend),
        models: model == null
            ? const Value.absent()
            : Value(encodeLlmServerModels(model)),
      ),
    );
    return (_db.select(_db.aiProviders)
          ..where((t) => t.id.equals(id))
          ..limit(1))
        .getSingleOrNull();
  }

  /// 启用/停用。
  Future<void> setEnabled(String id, bool enabled) async {
    await (_db.update(_db.aiProviders)..where((t) => t.id.equals(id))).write(
      AiProvidersCompanion(enabled: Value(enabled)),
    );
  }

  /// 删除：连带清理 SecretStore + 指向它的任务路由。
  ///
  /// 返回被解除绑定的任务数（用于 UI 提示）。
  Future<int> deleteProvider(String id) async {
    final row =
        await (_db.select(_db.aiProviders)
              ..where((t) => t.id.equals(id))
              ..limit(1))
            .getSingleOrNull();
    if (row != null) await secretStore.delete(row.apiKeyRef);
    final unbound = await _db.aiTaskRouteDao.unbindProvider(id);
    await (_db.delete(_db.aiProviders)..where((t) => t.id.equals(id))).go();
    return unbound;
  }

  /// 编辑 provider：只更新传入的字段。
  ///
  /// - `apiKey` 为 null / 空 → **不改密钥**（大多数时候只是改个显示名）；
  ///   非空则覆盖 SecretStore 里 `api_key_ref` 指向的值（引用名本身不变）。
  /// - 返回更新后的行；id 不存在返回 null。
  ///
  /// ⚠️ 改 `baseUrl` / `apiKey` 后需要**重启 App** 才生效：bootstrap 在启动时
  /// 已按旧值实例化了 `DifyClient`，内存里的实例不会跟着变。只改显示名无此问题。
  Future<AiProviderRow?> updateProvider(
    String id, {
    String? name,
    String? baseUrl,
    String? apiKey,
  }) async {
    final row =
        await (_db.select(_db.aiProviders)
              ..where((t) => t.id.equals(id))
              ..limit(1))
            .getSingleOrNull();
    if (row == null) return null;

    if (apiKey != null && apiKey.isNotEmpty) {
      await secretStore.set(row.apiKeyRef, apiKey);
    }
    if (name != null || baseUrl != null) {
      await (_db.update(_db.aiProviders)..where((t) => t.id.equals(id))).write(
        AiProvidersCompanion(
          name: name == null ? const Value.absent() : Value(name),
          baseUrl: baseUrl == null ? const Value.absent() : Value(baseUrl),
        ),
      );
    }
    return (_db.select(_db.aiProviders)
          ..where((t) => t.id.equals(id))
          ..limit(1))
        .getSingleOrNull();
  }

  // ============ 任务级路由绑定 ============

  /// 全部路由行（`ai_task` code → provider）。
  Future<List<AiTaskRouteRow>> allRoutes() => _db.aiTaskRouteDao.all();

  /// 绑定任务 → provider（同任务重复绑定 = 覆盖）。
  ///
  /// Dify 的 Key 按「应用」签发，一个工作流 = 一个 Key = 一个 Provider，
  /// 所以 T3 / T4 必须各自绑到自己的 Provider 上；不绑就走本地兜底（AI 不跑）。
  Future<void> bindTask(AiTask task, String providerId) =>
      _db.aiTaskRouteDao.bind(task: task, providerId: providerId);

  /// 解绑：通用任务回落默认 Provider；T3/T4 走本地兜底。
  Future<void> unbindTask(AiTask task) => _db.aiTaskRouteDao.unbind(task);

  /// 取密钥（仅内部/Provider 构造用）。
  Future<String?> resolveApiKey(String apiKeyRef) => secretStore.get(apiKeyRef);

  // ============ Seed ============

  /// 首次启动：若没有 LLM 服务 provider，从 [LocalAiConfig] seed 一个。
  ///
  /// 注意：**不写 SecretStore**（llm_server 无客户端密钥，C4）。
  Future<void> seedFromLocalIfEmpty(LocalAiConfig cfg) async {
    final existing = await allProviders();
    final hasLlmServer = existing.any((p) => p.protocol == kLlmServerProtocol);
    if (hasLlmServer) return;
    _log.i('首次启动：seed LLM 服务 provider from LocalAiConfig');
    await addLlmServerProvider(
      displayName: '本地 LLM 服务（默认）',
      baseUrl: cfg.baseUrl,
      backend: cfg.backend,
      model: cfg.model,
      setDefault: true,
    );
  }

  // ============ 连接测试 ============

  /// 用 (baseUrl, apiKey) 试连 Dify 的 setup 接口（无需 auth），返回 null = OK。
  Future<String?> testDify(
    String baseUrl,
    String apiKey, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final client = HttpClient()..connectionTimeout = timeout;
      final url = Uri.parse('$baseUrl/console/api/setup');
      final req = await client.getUrl(url);
      final resp = await req.close().timeout(timeout);
      await resp.drain<void>();
      client.close(force: true);
      if (resp.statusCode == 200) return null;
      return 'HTTP ${resp.statusCode}';
    } on Object catch (e) {
      return e.toString();
    }
  }

  /// 用 `GET {baseUrl}/health` 探 LLM 服务，返回 null = OK。
  ///
  /// 与 [testDify] 签名保持一致（返回错误文案，`null` 表示成功），
  /// 便于设置页复用同一套提示逻辑。
  Future<String?> testLlmServer(
    String baseUrl, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    try {
      final client = HttpClient()
        ..connectionTimeout = timeout
        // 127.0.0.1 / 本机探活绝不经系统代理（对齐服务端 trust_env=false）：
        // 本机有 HTTP_PROXY 时 Dart 默认也会把 loopback 请求发往代理而「假连不上」。
        ..findProxy = (Uri uri) => 'DIRECT';
      final req = await client.getUrl(Uri.parse('$base/health'));
      final resp = await req.close().timeout(timeout);
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode != 200) return 'HTTP ${resp.statusCode}';

      // 服务活着但后端不可达 → 只有「默认后端」不可达才算真失败：
      // App 实际只走 default_backend（记忆：default_backend 决定全局），
      // 非默认后端（如未订阅的 MiniMax）挂了不影响使用，不应误报「未连接」。
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['backends'] is List) {
        final backends = decoded['backends'] as List;
        final defaultName = decoded['default_backend'];
        final down = <String>[];
        String? defaultDown;
        for (final b in backends) {
          if (b is! Map) continue;
          final name = b['name'];
          final reachable = b['reachable'] == true;
          if (!reachable) {
            if (name is String) down.add(name);
            if (name is String && name == defaultName) defaultDown = name;
          }
        }
        // 全部不可达（兜底，避免 default_backend 缺失时漏报）。
        if (down.length == backends.length) {
          return '服务已启动，但全部后端不可达：${down.join('、')}（请在管理后台检查）。';
        }
        // 仅默认后端不可达 → 真失败（App 实际走它）。
        if (defaultDown != null) {
          return '服务已启动，但默认后端「$defaultDown」不可达（请在管理后台检查）。';
        }
        // 仅非默认后端不可达 → 连通，记日志即可，不阻断状态。
        if (down.isNotEmpty) {
          _log.i('AI 服务连通，非默认后端不可用：${down.join('、')}（不影响使用）');
        }
      }
      return null;
    } on Object catch (e) {
      return e.toString();
    }
  }
}

/// 把「模型覆盖」编码成 `models` 列的 JSON 数组字符串。
///
/// 空串 → `'[]'`（用后端默认模型）；否则 `'["qwen2.5:7b"]'`。
/// 该列最多承载 1 个元素（表结构不可改的前提下按约定只放一个）。
String encodeLlmServerModels(String model) {
  final m = model.trim();
  return m.isEmpty ? '[]' : jsonEncode(<String>[m]);
}

// ================= 列解析 helper（**唯一实现**）=================
//
// ⚠️ `bootstrap` 与设置页**都必须**调这两个函数，任何其他文件都不得自己解析
//    `row.type` / `row.models`。否则迟早出现「设置页显示 ollama、bootstrap 实际
//    走 auto」的漂移 —— 用户看到的配置和实际生效的配置不一致，且极难排查。
//
// 默认值口径（只此一份）：
//   · `type` 不在白名单或为空   → `auto`（跟随服务端 config.yaml）
//   · `models` 不是合法 JSON    → `''`（用后端默认模型）
//   · `models` 长度 > 1         → 只取第 0 个
//   · 第 0 个非字符串或空       → `''`（用后端默认模型）

/// 从 `ai_providers.type` 列解析 backend 名（带白名单容错）。
///
/// 白名单即 [kLlmServerBackends]（唯一来源，勿在本文件另抄一份）。
/// 非法值**绝不原样透传**给服务端 —— 那会拿到 `backend_unknown` 400。
String backendOf(String rawType) {
  final t = rawType.trim();
  return kLlmServerBackends.contains(t) ? t : 'auto';
}

/// 从 `ai_providers.models` 列解析模型覆盖（带 JSON 容错）。
///
/// 空串 = 用后端默认模型（不要与「未配置」混淆，二者本就同义）。
String firstModel(String modelsJson) {
  if (modelsJson.trim().isEmpty) return '';
  try {
    final decoded = jsonDecode(modelsJson);
    if (decoded is List && decoded.isNotEmpty) {
      final first = decoded.first;
      if (first is String) return first.trim();
    }
  } on Object {
    return '';
  }
  return '';
}

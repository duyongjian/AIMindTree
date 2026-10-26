/// SyncApi 抽象 + Http 实现 + Mock 实现（T03）。
///
/// 客户端不直连 Supabase；统一走 Supabase ai-proxy 中转：
///   POST /sync/push   `{device_id, envelopes}` → `{received, server_time}`
///   POST /sync/pull   `{device_id, since}`      → `{envelopes, server_time}`
///   GET  /sync/manifest                         → `{count, max_version}`
///
/// HttpSyncApi 用 dart:io `HttpClient`（与 DifyClient 同实现，复用 UTF-8 +
/// 超时逻辑）；不引入 `package:http` 以减少依赖。MockSyncApi 给测试用，
/// 可预设响应序列。
///
/// HttpSyncApi 用 dart:io HttpClient（与 DifyClient 同实现，复用 UTF-8 +
/// 超时逻辑）；不引入 `package:http` 以减少依赖。MockSyncApi 给测试用，
/// 可预设响应序列。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'direct_connect.dart';
import 'sync_config.dart';
import 'sync_types.dart';

/// 抽象同步后端。
abstract class SyncApi {
  /// 推送一批 envelope；返回服务端时间戳 + 接受数量。
  Future<SyncPushResult> pushBatch(List<SyncEnvelope> envelopes);

  /// 拉取 [since] 之后的所有 envelope；since 为 null 表示全量。
  Future<SyncPullResult> pullSince(DateTime? since);

  /// 测试连通性；返回 null = OK，非 null = 错误描述。
  Future<String?> testConnection();

  /// 取服务端该用户命名空间的数据总览（记录数 + 最大版本号）。
  ///
  /// 取不到（未登录 / 网络失败 / 旧中继不支持）时返回
  /// [SyncManifestResult.fail]，**不抛异常**——调用方是设置页 UI，总要能
  /// 优雅降级成「—」而不是崩掉一张卡。
  Future<SyncManifestResult> fetchManifest();

  /// 关闭底层 HTTP 客户端 / 测试占位。
  void close();

  /// 单批 push 字节预算（默认 4MB；[HttpSyncApi] 按后端覆盖，edgeone 收紧
  /// 到 850KB）。[SyncEngine] 据此贪心切批，避免超出中继请求体上限。
  int get pushBatchBudgetBytes => SyncConfig.kSyncPushBatchBudgetBytes;

  /// 单条 envelope 硬上限（默认 6MB；[HttpSyncApi] 按后端覆盖，edgeone 收紧
  /// 到 850KB）。超过它的 envelope 直接标记 failed，不进切批。
  int get maxEnvelopeBytes => SyncConfig.kSyncMaxEnvelopeBytes;
}

class SyncPushResult {
  const SyncPushResult({
    required this.accepted,
    required this.serverTime,
    this.versions = const {},
  });
  final int accepted;
  final DateTime serverTime;

  /// 服务端权威版本映射：`<entity_table>:<entity_id>` → 该实体被服务端分配的
  /// 新版本号（`newVer = max(服务器现有版本, 客户端声明 baseVersion) + 1`）。
  ///
  /// App 用它把本地 `version` 列对齐服务器（见 [SyncEngine._adoptServerVersions]），
  /// 使后续 [SyncEngine.pull] 的 LWW 比较不被「本地版本落后」误导。pull 侧
  /// 不调整版本（按用户决策：拉取直接覆盖、不做冲突检测），所以本地 version
  /// 的唯一权威来源就是这里的 adoption。
  final Map<String, int> versions;
}

class SyncPullResult {
  const SyncPullResult({required this.envelopes, required this.serverTime});
  final List<SyncEnvelope> envelopes;
  final DateTime serverTime;
}

/// `GET /sync/manifest` 的响应：服务端该用户命名空间下的**数据总览**。
///
/// ⚠️ 口径说明（与本地侧 `SyncOverview` 对齐，UI 并列显示时才有可比性）：
/// - [count]：服务端保存的 envelope 条数（按 `(entity_table, entity_id)` 去重
///   后的实体数）。软删墓碑（tombstone）在服务端也占一条，所以它会把「已删除」
///   的数据算进来；
/// - [maxVersion]：所有 envelope 里最大的 `base_version`。它是**逐实体修订号**
///   而不是全局 generation——每个实体各自从 1 起算，且服务端每次收到 push 都
///   对该实体做 `max(既有, 客户端声明) + 1`，所以**未变化的行也会让服务端版本
///   递增**。因此本机与服务器这两个数字**不必然相等**，只看作「差多少」的粗
///   略参考，不是一致性断言。
class SyncManifest {
  const SyncManifest({required this.count, required this.maxVersion});

  /// 服务端实体条数（含墓碑）。
  final int count;

  /// 服务端最大实体修订号（无数据时为 0）。
  final int maxVersion;
}

/// [SyncApi.fetchManifest] 的返回：成功带 [manifest]，失败带 [error]。
///
/// 单独包一层（而不是直接返回可空的 [SyncManifest]）是为了让 UI 能区分
/// 「服务器真的 0 条」与「压根没取到」——两者都显示 0 会误导用户。
class SyncManifestResult {
  const SyncManifestResult.ok(this.manifest) : error = null;

  const SyncManifestResult.fail(this.error) : manifest = null;

  final SyncManifest? manifest;

  /// 失败原因（人类可读，直接进 UI）；成功时为 null。
  final String? error;

  bool get ok => manifest != null;
}

class SyncApiException implements Exception {
  const SyncApiException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;
  @override
  String toString() => 'SyncApiException($statusCode): $message';
}

/// 真实 HTTP 实现（走 supabase ai-proxy 中转）。
///
/// 实现要点（参考 DifyClient 已踩坑）：
/// - 中文 body 必须 UTF-8 编码（`utf8.encode`）；
/// - Authorization: Bearer `<user_token>`；
/// - 单批上限 100（P0 简化由 SyncEngine 控制）。
class HttpSyncApi implements SyncApi {
  HttpSyncApi({
    required String baseUrl,
    required this.userToken,
    this.backend,
    HttpClient? client,
  })  : baseUrl = baseUrl,
        _externalClient = client;

  /// 中继基地址（构造时原样保存，不做后端特定的路径改写）。
  final String baseUrl;
  final String userToken;

  /// 目标同步后端（可空）。非空时 [pushBatchBudgetBytes] / [maxEnvelopeBytes]
  /// 按后端返回——edgeone 收紧到 850KB（平台请求体 1MB 硬限）；其余后端
  /// 沿用默认 4MB / 6MB。为空（历史/测试）时回落默认，行为与旧版一致。
  final SyncBackend? backend;

  @override
  int get pushBatchBudgetBytes =>
      backend?.pushBatchBudgetBytes ?? SyncConfig.kSyncPushBatchBudgetBytes;

  @override
  int get maxEnvelopeBytes =>
      backend?.maxEnvelopeBytes ?? SyncConfig.kSyncMaxEnvelopeBytes;

  /// 外部注入的 client（测试桩用）；为空时懒创建「DoH 直连」client。
  final HttpClient? _externalClient;

  /// 懒创建的 client（[close] 时关闭）。
  HttpClient? _client;

  Future<HttpClient>? _clientInit;

  /// 取底层 client：外部注入优先；否则经 [createDirectHttpClient] 创建
  /// （`*.workers.dev` 走 DoH 真实 IP 直连，任何失败都安静回退普通 client，
  /// PC 端现状行为不变）。并发调用复用同一次创建结果。
  Future<HttpClient> _ensureClient() {
    final external = _externalClient;
    if (external != null) return Future.value(external);
    return _clientInit ??= createDirectHttpClient(
      baseUrl,
      connectionTimeout: const Duration(seconds: 30),
    ).then((c) => _client = c);
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $userToken',
        'Content-Type': 'application/json; charset=utf-8',
      };

  String _normalize(String u) =>
      u.endsWith('/') ? u.substring(0, u.length - 1) : u;

  Uri _url(String path) => Uri.parse('${_normalize(baseUrl)}/sync/$path');

  Future<Map<String, dynamic>> _postJson(
    String path,
    Object body, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final url = _url(path);
    final client = await _ensureClient();
    final req = await client.postUrl(url).timeout(timeout);
    _headers.forEach(req.headers.set);
    req.add(utf8.encode(jsonEncode(body)));
    final resp = await req.close().timeout(timeout);
    final payload = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      // 中继网关的 413 payload 可能是英文（如 `EXCEED_MAX_PAYLOAD_SIZE`），用户看
      // 不懂；附一句中文说明（压缩图片 / 换后端），statusCode 仍照原样带上。
      final detail =
          payload.length > 200 ? '${payload.substring(0, 200)}…' : payload;
      throw SyncApiException(
        resp.statusCode == 413
            ? 'sync/$path 返回 413：请求体超过该后端网关上限，'
                '请压缩图片或更换同步后端（$detail）'
            : 'sync/$path 返回 ${resp.statusCode}：$detail',
        resp.statusCode,
      );
    }
    return jsonDecode(payload) as Map<String, dynamic>;
  }

  @override
  Future<SyncPushResult> pushBatch(List<SyncEnvelope> envelopes) async {
    final m = await _postJson('push', {
      'device_id': envelopes.isEmpty ? '' : envelopes.first.deviceId,
      'envelopes': envelopes.map((e) => e.toJson()).toList(),
    });
    return SyncPushResult(
      // 字段兼容：CF Worker 目前返回 `received`，其它后端（llm_server 中继 /
      // 旧实现）返回 `accepted`。以前只读 `accepted` → CF 链路永远回落 0，
      // 用户看到「上传成功但 0 条」。优先 `received`，回退 `accepted`。
      accepted: ((m['received'] ?? m['accepted']) as num?)?.toInt() ?? 0,
      serverTime: DateTime.parse(m['server_time'] as String),
      versions: _parseVersions(m['versions']),
    );
  }

  /// 把服务端 push 响应里的 `versions` 对象安全解析成 `<String,int>`。
  ///
  /// 旧后端 / 测试桩可能不返回该字段（返回 null 或非 Map），统一回落为
  /// 空 Map —— adoption 退化为 no-op，不影响既有同步行为。值 ≤ 0 的条目
  /// 直接丢弃（服务端不会分配 ≤ 0 的版本，出现只可能是坏数据）。
  static Map<String, int> _parseVersions(dynamic raw) {
    final out = <String, int>{};
    if (raw is! Map) return out;
    for (final e in raw.entries) {
      final v = (e.value as num?)?.toInt() ?? 0;
      if (v > 0) out[e.key.toString()] = v;
    }
    return out;
  }

  @override
  Future<SyncPullResult> pullSince(DateTime? since) async {
    final m = await _postJson('pull', {
      'device_id': '',
      'since': since?.toUtc().toIso8601String(),
    });
    final list = (m['envelopes'] as List<dynamic>? ?? const [])
        .map((e) => SyncEnvelope.fromJson(e as Map<String, dynamic>))
        .toList();
    return SyncPullResult(
      envelopes: list,
      serverTime: DateTime.parse(m['server_time'] as String),
    );
  }

  @override
  Future<String?> testConnection() async {
    try {
      final url = _url('manifest');
      final client = await _ensureClient();
      final req =
          await client.getUrl(url).timeout(const Duration(seconds: 10));
      _headers.forEach(req.headers.set);
      final resp = await req.close().timeout(const Duration(seconds: 10));
      await resp.drain<void>();
      if (resp.statusCode == 200) return null;
      return 'HTTP ${resp.statusCode}';
    } on Object catch (e) {
      return e.toString();
    }
  }

  /// 带令牌 GET `sync/manifest` 并解析总览。
  ///
  /// 与 [testConnection] 走同一个端点，但这里**解析响应体**（那里只 drain）。
  /// 任何异常（网络 / 超时 / 4xx / 坏 JSON）都被收敛成
  /// [SyncManifestResult.fail]，调用方无需 try/catch。
  @override
  Future<SyncManifestResult> fetchManifest() async {
    try {
      final url = _url('manifest');
      final client = await _ensureClient();
      final req = await client.getUrl(url).timeout(const Duration(seconds: 15));
      _headers.forEach(req.headers.set);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final payload = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        return SyncManifestResult.fail('HTTP ${resp.statusCode}');
      }
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return const SyncManifestResult.fail('响应不是 JSON 对象');
      }
      return SyncManifestResult.ok(parseManifest(decoded));
    } on Object catch (e) {
      return SyncManifestResult.fail('$e');
    }
  }

  /// 把 manifest 响应体解析成 [SyncManifest]。
  ///
  /// **对旧中继容错**：`max_version` 是本轮新增字段，已部署的旧中继仍只回
  /// `{count}`。缺字段时回落 0（而不是抛异常 / 返回 null）——设置页据此显示
  /// 「—」，而不是整张卡崩掉。同理 `count` 缺失或非数字也回落 0。
  static SyncManifest parseManifest(Map<String, dynamic> json) => SyncManifest(
        count: _intOf(json['count']),
        maxVersion: _intOf(json['max_version']),
      );

  /// 宽容取整数：字段缺失 / 为 null / 类型不对（网关塞了字符串或 null）一律
  /// 回落 0，绝不让一次坏响应把整张设置页卡崩。
  static int _intOf(Object? v) => v is num ? v.toInt() : 0;

  @override
  void close() => _client?.close(force: true);
}

/// 测试用 Mock：可预设 push 接受策略 + pull 返回 envelope 序列。
class MockSyncApi implements SyncApi {
  /// Mock 不走真实后端，字节预算取默认（4MB / 6MB），与 CF / Netlify
  /// 非 edgeone 路径一致。
  @override
  int get pushBatchBudgetBytes => SyncConfig.kSyncPushBatchBudgetBytes;

  @override
  int get maxEnvelopeBytes => SyncConfig.kSyncMaxEnvelopeBytes;

  MockSyncApi({
    this.deviceIdOfCaller = 'remote-device-1',
    this.pushShouldFail = false,
    List<SyncEnvelope> initialPull = const [],
  }) : _pullQueue = [...initialPull];

  /// 调用方 deviceId（自回声过滤测试用）。
  final String deviceIdOfCaller;

  /// true 时 pushBatch 抛异常（模拟网络/服务端错误）。
  bool pushShouldFail;

  /// 预置 pull 响应序列：每次 pullSince 取出一条。
  final List<SyncEnvelope> _pullQueue;

  /// [fetchManifest] 的预设返回值；null 表示「服务端没有数据可取」。
  ///
  /// 测试想验证降级路径就把它设成 null 或设 [manifestError]。
  SyncManifest? manifestOverride = const SyncManifest(count: 0, maxVersion: 0);

  /// 非空时 [fetchManifest] 一律返回失败（模拟未登录 / 网络失败 / 旧中继）。
  String? manifestError;

  /// fetchManifest 调用次数（测试断言用）。
  int manifestCalls = 0;

  /// push 历史（用于测试断言）。
  final List<List<SyncEnvelope>> pushHistory = [];

  /// 模拟 push 失败时触发（业务回调）。
  void Function(List<SyncEnvelope>)? onPushFailed;

  @override
  Future<SyncPushResult> pushBatch(List<SyncEnvelope> envelopes) async {
    pushHistory.add(envelopes);
    if (pushShouldFail) {
      onPushFailed?.call(envelopes);
      throw const SyncApiException('mock failure', 500);
    }
    return SyncPushResult(
      accepted: envelopes.length,
      serverTime: DateTime.now().toUtc(),
      // Mock 后端没有持久化存储，不计算 server-authoritative 版本，回退空 Map；
      // 需要验证 adoption 的测试请改用自定义 SyncApi 返回非空 versions。
      versions: const {},
    );
  }

  @override
  Future<SyncPullResult> pullSince(DateTime? since) async {
    final snap = List<SyncEnvelope>.from(_pullQueue);
    _pullQueue.clear();
    return SyncPullResult(
      envelopes: snap,
      serverTime: DateTime.now().toUtc(),
    );
  }

  /// 往队列追加新 pull 响应（下次 pullSince 取走）。
  void enqueuePull(List<SyncEnvelope> envs) {
    _pullQueue.addAll(envs);
  }

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<SyncManifestResult> fetchManifest() async {
    manifestCalls++;
    final err = manifestError;
    if (err != null) return SyncManifestResult.fail(err);
    return SyncManifestResult.ok(
      manifestOverride ?? const SyncManifest(count: 0, maxVersion: 0),
    );
  }

  @override
  void close() {}
}
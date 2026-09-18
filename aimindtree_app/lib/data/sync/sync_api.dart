/// SyncApi 抽象 + Http 实现 + Mock 实现（T03）。
///
/// 客户端不直连 Supabase；统一走 Supabase ai-proxy 中转：
///   POST /sync/push   `{device_id, envelopes}` → `{received, server_time}`
///   POST /sync/pull   `{device_id, since}`      → `{envelopes, server_time}`
///   GET  /sync/manifest                         → `{count}`
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

import 'sync_types.dart';

/// 抽象同步后端。
abstract class SyncApi {
  /// 推送一批 envelope；返回服务端时间戳 + 接受数量。
  Future<SyncPushResult> pushBatch(List<SyncEnvelope> envelopes);

  /// 拉取 [since] 之后的所有 envelope；since 为 null 表示全量。
  Future<SyncPullResult> pullSince(DateTime? since);

  /// 测试连通性；返回 null = OK，非 null = 错误描述。
  Future<String?> testConnection();

  /// 关闭底层 HTTP 客户端 / 测试占位。
  void close();
}

class SyncPushResult {
  const SyncPushResult({required this.accepted, required this.serverTime});
  final int accepted;
  final DateTime serverTime;
}

class SyncPullResult {
  const SyncPullResult({required this.envelopes, required this.serverTime});
  final List<SyncEnvelope> envelopes;
  final DateTime serverTime;
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
    required this.baseUrl,
    required this.userToken,
    HttpClient? client,
  }) : _client = client ?? HttpClient()..connectionTimeout = const Duration(seconds: 30);

  final String baseUrl;
  final String userToken;
  final HttpClient _client;

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
    final req = await _client.postUrl(url).timeout(timeout);
    _headers.forEach(req.headers.set);
    req.add(utf8.encode(jsonEncode(body)));
    final resp = await req.close().timeout(timeout);
    final payload = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw SyncApiException(
        'sync/$path 返回 ${resp.statusCode}：'
        '${payload.length > 200 ? '${payload.substring(0, 200)}…' : payload}',
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
      accepted: (m['accepted'] as num?)?.toInt() ?? 0,
      serverTime: DateTime.parse(m['server_time'] as String),
    );
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
      final req = await _client.getUrl(url).timeout(const Duration(seconds: 10));
      _headers.forEach(req.headers.set);
      final resp = await req.close().timeout(const Duration(seconds: 10));
      await resp.drain<void>();
      if (resp.statusCode == 200) return null;
      return 'HTTP ${resp.statusCode}';
    } on Object catch (e) {
      return e.toString();
    }
  }

  @override
  void close() => _client.close(force: true);
}

/// 测试用 Mock：可预设 push 接受策略 + pull 返回 envelope 序列。
class MockSyncApi implements SyncApi {
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
  void close() {}
}
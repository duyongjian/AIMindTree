/// CF 账号 API（方案 B 多租户）：/auth/register、/auth/login。
///
/// 普通用户用用户名+密码自助注册/登录；成功后服务端下发每用户令牌，
/// 该令牌即作为 ``HttpSyncApi`` 的 Bearer，服务端据此按 owner_id 隔离数据。
/// 不再需要任何共享的 SYNC_TOKEN。
///
/// 复用 ``HttpSyncApi`` 的 dart:io 实现风格（UTF-8 + 超时），不引入 package:http。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'http_proxy.dart';

/// 登录/注册返回的会话（user_id + 每用户令牌）。
class SyncAccountSession {
  const SyncAccountSession({required this.userId, required this.token});
  final String userId;
  final String token;
}

class SyncAccountApiException implements Exception {
  const SyncAccountApiException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;
  @override
  String toString() => 'SyncAccountApiException($statusCode): $message';
}

class SyncAccountApi {
  SyncAccountApi({required this.baseUrl, HttpClient? client})
      : _client = client ?? _createClient();

  static HttpClient _createClient() {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    c.findProxy = syncFindProxy;
    return c;
  }

  final String baseUrl;
  final HttpClient _client;

  String _normalize(String u) => u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  Uri _url(String path) => Uri.parse('${_normalize(baseUrl)}/$path');

  Future<SyncAccountSession> _auth(
    String path,
    String username,
    String password,
  ) async {
    final url = _url(path);
    try {
      final req =
          await _client.postUrl(url).timeout(const Duration(seconds: 20));
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.add(utf8.encode(jsonEncode({'username': username, 'password': password})));
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final payload = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        var msg = 'auth $path 返回 ${resp.statusCode}';
        try {
          final m = jsonDecode(payload) as Map<String, dynamic>;
          final err = m['error'];
          if (err is String && err.isNotEmpty) msg = err;
        } on Object {
          // 非 JSON 错误体，保留状态码描述
        }
        throw SyncAccountApiException(msg, resp.statusCode);
      }
      final m = jsonDecode(payload) as Map<String, dynamic>;
      return SyncAccountSession(
        userId: m['user_id'] as String,
        token: m['token'] as String,
      );
    } on SyncAccountApiException {
      rethrow; // 服务端明确错误（409/400/401 等）原样上抛
    } on TimeoutException {
      throw const SyncAccountApiException('连接服务器超时（网络被拦截，或代理未生效）');
    } on SocketException catch (e) {
      throw SyncAccountApiException(
        '无法连接服务器：${e.osError?.message ?? e.message}（请检查网络或代理）',
      );
    } on Object catch (e) {
      throw SyncAccountApiException('请求失败：$e');
    }
  }

  Future<SyncAccountSession> register(String username, String password) =>
      _auth('auth/register', username, password);

  Future<SyncAccountSession> login(String username, String password) =>
      _auth('auth/login', username, password);

  void close() => _client.close(force: true);
}

/// SyncAccountApi 集成测试（方案 B 多租户账号）。
///
/// 起一个本地 HttpServer 模拟 Worker 的 /auth/register、/auth/login，
/// 验证 App 端账号客户端与 Worker 契约一致：成功返回 {user_id, token}、
/// 重名 409、弱密码 400、错误密码 401。覆盖真实 HttpClient 通路。
library;

import 'dart:convert';
import 'dart:io';

import 'package:aimindtree_app/data/sync/sync_account.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SyncAccountApi', () {
    late HttpServer server;
    late int port;
    // 内存账号表：username -> {pw, userId, token}
    final Map<String, Map<String, String>> users = <String, Map<String, String>>{};

    setUp(() async {
      users.clear();
      server = await HttpServer.bind('127.0.0.1', 0);
      port = server.port;
      server.listen((req) async {
        final bytes = await req.fold<List<int>>(<int>[], (p, e) => p..addAll(e));
        final body = utf8.decode(bytes);
        final Map<String, dynamic>? json =
            body.isEmpty ? null : jsonDecode(body) as Map<String, dynamic>;
        final username = (json?['username'] ?? '').toString();
        final password = (json?['password'] ?? '').toString();

        Future<void> respond(int code, Map<String, dynamic> payload) async {
          req.response
            ..statusCode = code
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(payload));
          await req.response.close();
        }

        if (req.method == 'POST' && req.uri.path.endsWith('/auth/register')) {
          if (username.length < 3) {
            await respond(400, {'error': 'username too short (>=3)'});
            return;
          }
          if (password.length < 8) {
            await respond(400, {'error': 'password too short (>=8)'});
            return;
          }
          if (users.containsKey(username)) {
            await respond(409, {'error': 'username taken'});
            return;
          }
          final token = 'tok_${users.length}_$username';
          users[username] = <String, String>{
            'pw': password,
            'userId': 'u_$username',
            'token': token,
          };
          await respond(200, {'user_id': 'u_$username', 'token': token});
          return;
        }

        if (req.method == 'POST' && req.uri.path.endsWith('/auth/login')) {
          final u = users[username];
          if (u == null || u['pw'] != password) {
            await respond(401, {'error': 'invalid credentials'});
            return;
          }
          await respond(200, {'user_id': u['userId']!, 'token': u['token']!});
          return;
        }

        await respond(404, {'error': 'not found'});
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    SyncAccountApi api(String path) =>
        SyncAccountApi(baseUrl: 'http://127.0.0.1:$port$path');

    test('register 成功返回 user_id + token', () async {
      final a = api('');
      final s = await a.register('alice', 'password123');
      expect(s.userId, 'u_alice');
      expect(s.token, startsWith('tok_'));
      a.close();
    });

    test('register 重名 → 409', () async {
      final a = api('');
      await a.register('alice', 'password123');
      final a2 = api('');
      expect(
        () => a2.register('alice', 'password456'),
        throwsA(isA<SyncAccountApiException>()),
      );
      a.close();
      a2.close();
    });

    test('register 弱密码 → 400', () async {
      final a = api('');
      expect(
        () => a.register('bob', 'short'),
        throwsA(isA<SyncAccountApiException>()),
      );
      a.close();
    });

    test('login 成功返回同一令牌；错误密码 → 401', () async {
      final reg = api('');
      final s = await reg.register('alice', 'password123');
      reg.close();

      final login = api('');
      final s2 = await login.login('alice', 'password123');
      expect(s2.userId, s.userId);
      expect(s2.token, s.token);
      login.close();

      final bad = api('');
      expect(
        () => bad.login('alice', 'wrong'),
        throwsA(isA<SyncAccountApiException>()),
      );
      bad.close();
    });
  });
}

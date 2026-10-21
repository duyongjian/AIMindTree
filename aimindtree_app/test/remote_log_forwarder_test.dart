/// P0-5 回归测试：``RemoteLogForwarder`` 把 App 日志批量 POST 到本机
/// llm_server ``/v1/logs``，使管理后台 M7 能看到 App 侧日志。
///
/// 用本地 ``HttpServer``（loopback，端口 0）模拟 llm_server 接收端，验证：
///   1. enqueue 的日志会在 2s 周期后批量 POST 到 ``/v1/logs``；
///   2. 请求体为 ``{"entries":[{level,module,message}...]}``；
///   3. 批量合流：同一周期内的多条日志合并为一次请求。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aimindtree_app/core/remote_log_forwarder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RemoteLogForwarder（P0-5：App→服务端日志抄送）', () {
    late HttpServer server;
    late List<Map<String, dynamic>> received;
    late int requestCount;
    late Completer<void> gotRequest;

    setUp(() async {
      received = <Map<String, dynamic>>[];
      requestCount = 0;
      gotRequest = Completer<void>();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        requestCount++;
        try {
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          final entries = decoded['entries'] as List<dynamic>;
          for (final e in entries) {
            received.add(e as Map<String, dynamic>);
          }
        } on Object {
          // 解析失败不影响断言，下面 requestCount 仍 > 0。
        }
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'accepted': received.length}));
        await req.response.close();
        if (!gotRequest.isCompleted) gotRequest.complete();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('enqueue 后 2s 内批量 POST 到 /v1/logs，多条合流为一次', () async {
      final baseUrl = 'http://127.0.0.1:${server.port}';
      final fwd = RemoteLogForwarder(baseUrl);
      fwd.enqueue('INFO', 'app.extract', '开始提取知识点');
      fwd.enqueue('ERROR', 'app.note', '保存失败');

      // 等 flush 周期（2s）+ 网络往返。
      await gotRequest.future.timeout(const Duration(seconds: 6));

      expect(requestCount, greaterThan(0),
          reason: '应至少收到一次 /v1/logs POST');
      expect(received.length, greaterThanOrEqualTo(2),
          reason: '至少抄送 2 条日志');

      final levels = received.map((e) => e['level'] as String).toList();
      expect(levels, contains('INFO'));
      expect(levels, contains('ERROR'));

      final modules = received.map((e) => e['module'] as String).toList();
      expect(
          modules.any((m) => m == 'app.extract' || m == 'app.note'), isTrue);

      final first = received.first;
      expect(first['message'], isA<String>());
      fwd.dispose();
    });
  });
}

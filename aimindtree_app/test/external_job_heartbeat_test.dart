/// 外部任务（BACKGROUND / SESSION）心跳 + 终态上报回归测试。
///
/// 三条根因，各自一条用例锁死（旧实现必红）：
///   1. ``registerExternal`` **不带** ``heartbeat_s`` → 服务端看门狗永久豁免
///      （``core/jobs.py`` 的 ``heartbeat_deadline = None``），App 崩溃后管理
///      后台那行永远是「进行中」；
///   2. 注册是 fire-and-forget，收尾只看 ``job.serverJobId`` → 注册 HTTP 往返
///      比执行体慢（短任务 / 服务端慢）时 ``finish`` 被整个跳过 → 永远 running；
///   3. ``finishExternal`` 单发一次，丢一次包就永久 running。
///
/// 假服务端是本地 `HttpServer`（`dart:io`），记录收到的请求序列 —— 断言的是
/// 「真正发出去的报文」，不是内部字段，所以反向着色可靠。
library;

import 'dart:convert';
import 'dart:io';

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ai/llm_channel.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假服务端收到的一条请求（[responseCode] 是本测试里回给它的状态码）。
class _Req {
  _Req(this.method, this.path, this.body);

  final String method;
  final String path;
  final Map<String, dynamic> body;
  int? responseCode;

  bool get isRegister => path.endsWith('/register');
  bool get isFinish => path.endsWith('/finish');
  bool get isProgress => path.endsWith('/progress');

  @override
  String toString() => '$method $path -> $responseCode';
}

/// 假 llm_server（只实现本测试需要的四条路径）。
class _FakeServer {
  _FakeServer._(this._server);

  static Future<_FakeServer> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeServer._(s);
    s.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  final List<_Req> requests = <_Req>[];

  /// 注册应答的额外延迟（模拟「服务端慢 / 网络慢」）。
  Duration? registerDelay;

  /// ``finish`` 前 [failFinishTimes] 次回 500。
  int failFinishTimes = 0;
  int finishCount = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  List<_Req> get registers => requests.where((r) => r.isRegister).toList();
  List<_Req> get finishes => requests.where((r) => r.isFinish).toList();
  List<String> get pathSequence => requests.map((r) => r.path).toList();

  Future<void> _handle(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    Map<String, dynamic> body = <String, dynamic>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) body = Map<String, dynamic>.from(decoded);
    }
    final req = _Req(request.method, request.uri.path, body);
    requests.add(req);

    var code = 200;
    var payload = <String, dynamic>{'job_id': 'ext-1', 'status': 'running'};
    if (req.isRegister) {
      final delay = registerDelay;
      if (delay != null) await Future<void>.delayed(delay);
      code = 201;
      payload = <String, dynamic>{'job_id': 'ext-1', 'status': 'running'};
    } else if (req.isFinish) {
      finishCount++;
      if (finishCount <= failFinishTimes) {
        code = 500;
        payload = <String, dynamic>{
          'error': <String, dynamic>{
            'code': 'upstream_error',
            'message': '临时失败',
            'retryable': true,
          },
        };
      } else {
        payload = <String, dynamic>{
          'job_id': 'ext-1',
          'status': body['status'] ?? 'done',
        };
      }
    } else if (req.isProgress) {
      payload = <String, dynamic>{'job_id': 'ext-1', 'status': 'running'};
    } else {
      code = 404;
      payload = <String, dynamic>{
        'error': <String, dynamic>{'code': 'not_found', 'message': '未实现'},
      };
    }
    req.responseCode = code;
    request.response.statusCode = code;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// 等到 [condition] 为真（或超时放弃，由断言报红）。
Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late _FakeServer server;
  late AiJobService service;

  setUp(() async {
    // 通道是进程内单例：清掉上一个用例可能残留的持有者 / 等待者。
    LlmChannel.instance.debugReset();
    LlmChannel.watchdogsEnabled = false;
    // 15s 周期 Timer 不在本文件断言范围内（间隔是 const，实时等太久），
    // 关掉以免跨用例泄漏；``heartbeat_s`` 的报文断言与这个开关无关。
    AiJobService.heartbeatsEnabled = false;
    server = await _FakeServer.start();
    service = AiJobService(baseUrl: server.baseUrl);
  });

  tearDown(() async {
    service.dispose();
    await server.close();
    AiJobService.heartbeatsEnabled = true;
  });

  group('外部任务上报（僵尸行根因）', () {
    test('BACKGROUND 登记必须带 heartbeat_s（否则看门狗永久豁免）', () async {
      final task = service.runDetached(
        label: '出题中（1 个知识点）',
        body: (t) async {},
      );
      await task.done;
      await _waitFor(() => server.registers.isNotEmpty);

      expect(server.registers, hasLength(1), reason: '后台任务必须登记到服务端');
      final register = server.registers.single;
      // 旧实现只发 task/label/resource_key → 该键缺失 → 服务端不设截止时间。
      expect(register.body.containsKey('heartbeat_s'), isTrue,
          reason: '缺 heartbeat_s 等于向服务端申请看门狗永久豁免');
      expect(register.body['heartbeat_s'], equals(45));
      expect(register.body['task'], equals('BACKGROUND'));
    });

    test('SESSION 登记必须带 heartbeat_s（交互会话同理）', () async {
      final id = service.holdInteractive('kp:1', label: 'AI 助手：回答中');
      await _waitFor(() => server.registers.isNotEmpty);

      expect(server.registers, hasLength(1));
      expect(server.registers.single.body['heartbeat_s'], equals(45));
      expect(server.registers.single.body['task'], equals('SESSION'));
      service.releaseInteractive(id);
    });

    test('注册应答慢于执行体：仍然必须发出 finish（旧实现整条漏发）', () async {
      // 注册 300ms 才回来，执行体立刻结束 —— 这就是「确定性竞态」的现场。
      server.registerDelay = const Duration(milliseconds: 300);
      final task = service.runDetached(
        label: '出题中（1 个知识点）',
        body: (t) async {},
      );
      await task.done;
      // 旧实现此刻 serverJobId 仍是 null → 一次 finish 都不会发。
      await _waitFor(() => server.finishes.any((r) => r.responseCode == 200));

      expect(server.registers, hasLength(1));
      expect(server.finishes, hasLength(1),
          reason: '注册晚到不能成为漏发终态的理由');
      expect(server.finishes.single.path, endsWith('/v1/jobs/ext-1/finish'));
      expect(server.finishes.single.body['status'], equals('done'));
      // 请求序列：先登记、后终态（顺序也说明是「等注册回来再 finish」）。
      expect(server.pathSequence,
          equals(<String>['/v1/jobs/register', '/v1/jobs/ext-1/finish']));
      // 托盘行照旧立刻进终态，不被这次 HTTP 往返拖住。
      expect(service.activeJobs, isEmpty);
      expect(service.recentJobs.first.message, equals('已完成'));
    });

    test('交互会话释放早于注册返回：仍然必须发出 finish', () async {
      server.registerDelay = const Duration(milliseconds: 300);
      final id = service.holdInteractive('kp:2', label: '老师模式');
      // 用户开页面就退：注册还在路上。
      service.releaseInteractive(id);
      await _waitFor(() => server.finishes.isNotEmpty);

      expect(server.finishes, hasLength(1), reason: '会话行不能永远 running');
      expect(server.finishes.single.body['status'], equals('canceled'));
    });

    test('finish 第一次 500：自动重试并最终 200（丢一次包不留僵尸行）', () async {
      server.failFinishTimes = 1;
      final task = service.runDetached(
        label: '出题中（1 个知识点）',
        body: (t) async {},
      );
      await task.done;
      await _waitFor(() => server.finishes.any((r) => r.responseCode == 200));

      expect(server.finishes, hasLength(2), reason: '旧实现只发一次 → 永久 running');
      expect(server.finishes.first.responseCode, equals(500));
      expect(server.finishes.last.responseCode, equals(200));
      expect(server.finishes.last.body['status'], equals('done'));
    });
  });
}

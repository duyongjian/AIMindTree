/// LlmServerClient 的 **线上格式契约**测试（variant 走 body 穿透）。
///
/// 背景：App 侧只证明「variant 传到了 AiProvider.runTask」还不够——服务端
/// `routers/tasks.py` 只从 **body 顶层**读 `variant`，提示词按 `(task, variant)`
/// 二元组检索（点号不拆分）。所以这里起一个本机 HttpServer，直接抓真实
/// HTTP 请求，断言：
/// - URL 是 `/v1/task/T1`（**不是** `/v1/task/T1.keypoints`，那是服务端
///   unknown_task 的老坑）；
/// - body 顶层带 `variant: 'keypoints'` / `'both'`；
/// - variant 为空/不传时 body **不带** variant 字段（保旧行为）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/ai/clients/llm_server_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 抓到的这一次 HTTP 请求。
class _Captured {
  const _Captured(this.method, this.path, this.body);

  final String method;
  final String path;
  final Map<String, dynamic> body;
}

void main() {
  late HttpServer server;
  late _Captured captured;

  setUp(() async {
    captured = const _Captured('', '', {});
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      final raw = await utf8.decodeStream(req);
      final body = raw.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(raw) as Map).cast<String, dynamic>();
      captured = _Captured(req.method, req.uri.path, body);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, dynamic>{
        'content': '{"knowledge_points":[]}',
        'parsed': <String, dynamic>{
          'knowledge_points': <dynamic>[],
        },
      }));
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  String baseUrl() => 'http://127.0.0.1:${server.port}';

  test('variant=keypoints：URL 仍是 /v1/task/T1，body 顶层带 variant', () async {
    final client = LlmServerClient(id: 'p1', baseUrl: baseUrl());
    await client.runTask(
      AiTask.t1Extract,
      <String, dynamic>{'note_text': '导数是核心工具'},
      variant: 'keypoints',
    );

    expect(captured.method, 'POST');
    expect(captured.path, '/v1/task/T1');
    expect(captured.body['variant'], 'keypoints');
    // variant 在 body 顶层，不塞进 inputs。
    final inputs = captured.body['inputs'] as Map<String, dynamic>;
    expect(inputs['note_text'], '导数是核心工具');
    expect(inputs.containsKey('variant'), isFalse);
  });

  test('variant=both：body 顶层带 both', () async {
    final client = LlmServerClient(id: 'p1', baseUrl: baseUrl());
    await client.runTask(
      AiTask.t1Extract,
      <String, dynamic>{'note_text': 'x'},
      variant: 'both',
    );

    expect(captured.path, '/v1/task/T1');
    expect(captured.body['variant'], 'both');
  });

  test('不传 variant / 空串：body 不带 variant 字段（保旧行为）', () async {
    final client = LlmServerClient(id: 'p1', baseUrl: baseUrl());

    await client.runTask(AiTask.t1Extract, <String, dynamic>{'note_text': 'x'});
    expect(captured.path, '/v1/task/T1');
    expect(captured.body.containsKey('variant'), isFalse);

    await client.runTask(
      AiTask.t1Extract,
      <String, dynamic>{'note_text': 'x'},
      variant: '',
    );
    expect(captured.path, '/v1/task/T1');
    expect(captured.body.containsKey('variant'), isFalse);
  });

  test('T15：URL 是 /v1/task/T15，inputs 带 selection + note_text', () async {
    final client = LlmServerClient(id: 'p1', baseUrl: baseUrl());
    await client.runTask(
      AiTask.t15KpFromSelection,
      <String, dynamic>{
        'selection': '导数是核心工具',
        'note_text': '整篇笔记',
      },
    );

    expect(captured.path, '/v1/task/T15');
    expect(captured.body.containsKey('variant'), isFalse);
    final inputs = captured.body['inputs'] as Map<String, dynamic>;
    expect(inputs['selection'], '导数是核心工具');
    expect(inputs['note_text'], '整篇笔记');
  });
}

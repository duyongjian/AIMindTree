/// LlmServerClient 的 variant 契约测试（**HTTP 层实证**，不是 provider 层替身）。
///
/// 背景：T1 的提取模式是**提示词变体**——同一任务码 `T1` 下按
/// `variant=keypoints|both` 选不同 `.md`。服务端只从 **body 顶层**读 variant
/// （`llm_server/routers/tasks.py:96`），再按 `(task, variant)` 二元组检索提示词
/// （`core/prompt_store.py:300-317`）。
///
/// 于是客户端有两点必须钉死，任一错都造成**静默错误**（用户无感知）：
/// 1. 变体**不许进 URL**：`/v1/task/T1.keypoints` 在服务端是 `unknown_task`
///    （实测：selftest F 节 `POST /v1/task/T1.keypoints` → 400 unknown_task）；
/// 2. 变体必须在 body 顶层、**不许塞进 `inputs`**：塞进去服务端读不到，回落到
///    主形态——用户勾了「仅要点重点」却拿到知识点，且没有任何报错。
///
/// 本测试起一个本地 HttpServer 截获**真实请求**，逐条断言上述契约；
/// 顺带守住「中文 body 按 UTF-8 往返」（latin1 编码会让中文抛异常/乱码）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/ai/clients/llm_server_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late LlmServerClient client;

  /// 最近一次请求的路径与 body（每个用例前清空）。
  late String lastPath;
  late Map<String, dynamic> lastBody;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    lastPath = '';
    lastBody = <String, dynamic>{};
    server.listen((HttpRequest req) async {
      lastPath = req.uri.path;
      final raw = await utf8.decoder.bind(req).join();
      lastBody = raw.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      req.response
        ..statusCode = 200
        ..headers.contentType =
            ContentType('application', 'json', charset: 'utf-8')
        ..write(jsonEncode(<String, dynamic>{
          'content': '{"knowledge_points": []}',
          'parsed': <String, dynamic>{'knowledge_points': <dynamic>[]},
          'latency_ms': 1,
          'model_id': 'fake',
        }));
      await req.response.close();
    });
    client = LlmServerClient(
      id: 'local',
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
  });

  tearDown(() async {
    client.dispose();
    await server.close(force: true);
  });

  test('variant=keypoints：URL 仍是 /v1/task/T1，variant 在 body 顶层', () async {
    await client.runTask(
      AiTask.t1Extract,
      <String, dynamic>{'note_text': '牛顿第二定律'},
      variant: 'keypoints',
    );
    expect(lastPath, '/v1/task/T1');
    expect(lastBody['variant'], 'keypoints');
    // 变体绝不能混进 inputs：服务端只读 body 顶层，混进去 = 静默回落主形态。
    final inputs = Map<String, dynamic>.from(lastBody['inputs'] as Map);
    expect(inputs.containsKey('variant'), isFalse);
    expect(inputs['note_text'], '牛顿第二定律');
  });

  test('variant=both 同样走 body 顶层', () async {
    await client.runTask(
      AiTask.t1Extract,
      <String, dynamic>{'note_text': 'x'},
      variant: 'both',
    );
    expect(lastPath, '/v1/task/T1');
    expect(lastBody['variant'], 'both');
  });

  test('不传 variant → body 里没有 variant 键（保旧：走主形态）', () async {
    await client.runTask(AiTask.t1Extract, <String, dynamic>{'note_text': 'x'});
    expect(lastPath, '/v1/task/T1');
    expect(lastBody.containsKey('variant'), isFalse);
  });

  test("variant='' → 同样不发 variant 键（空串视同不传）", () async {
    await client.runTask(
      AiTask.t1Extract,
      <String, dynamic>{'note_text': 'x'},
      variant: '',
    );
    expect(lastBody.containsKey('variant'), isFalse);
  });

  test('T15 是独立任务码：URL 即 /v1/task/T15，无 variant', () async {
    await client.runTask(
      AiTask.t15KpFromSelection,
      <String, dynamic>{'selection': '一段话', 'note_text': '全文'},
    );
    expect(lastPath, '/v1/task/T15');
    expect(lastBody.containsKey('variant'), isFalse);
    // 中文 body 必须 UTF-8 往返（latin1 编码会抛异常，服务端也读不对）。
    final inputs = Map<String, dynamic>.from(lastBody['inputs'] as Map);
    expect(inputs['selection'], '一段话');
  });
}

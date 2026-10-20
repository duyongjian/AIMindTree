// 端到端冒烟（纯 Dart，无 Drift / 无 sqlite3 原生依赖）。
//
// 链路：LlmServerClient.runTask(T1) → AiService（路由）→ 自研 LLM Server
// （127.0.0.1:8787，内部走 Ollama / MiniMax / OpenAI 兼容端点）→ 解析
// knowledge_points → 打印结果。
//
// 用法（在 aimindtree_app 目录，llm_server 需已启动）：
//   dart run tool/smoke_ai_service.dart
//   dart run tool/smoke_ai_service.dart "自定义笔记文本"
//
// 启动服务（另一个终端，仓库根目录）：
//   scripts\run_llm_server.bat
//   python llm_server/run.py
//
// 环境变量（若设了 http_proxy，需让 127.0.0.1 走直连）：
//   no_proxy=localhost,127.0.0.1 dart run tool/smoke_ai_service.dart

import 'dart:io';

import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/clients/llm_server_client.dart';
import 'package:aimindtree_app/core/result.dart';

Future<void> main(List<String> args) async {
  final note = args.isNotEmpty
      ? args.join(' ')
      : '牛顿第一定律：任何物体都要保持匀速直线运动或静止状态，'
          '直到外力迫使它改变运动状态为止。它说明了惯性的概念，是经典力学的基础。';

  // 无密钥：密钥在服务端 llm_server/.env 里，App 侧什么都不传。
  final client = LlmServerClient(
    id: 'llm-server-local',
    baseUrl: kLlmServerDefaultBaseUrl,
  );
  final router = AiTaskRouter(
    // 本冒烟只测 AiService，不读写 ai_task_routes，传 null 直接走 fallback。
    db: null,
    providers: {client.id: client},
    fallback: client,
  );
  final ai = AiService(router: router);

  stdout.writeln('==> 调用 LLM Server T1 提取（${client.baseUrl}）：');
  stdout.writeln('    $note');
  final sw = Stopwatch()..start();
  final res = await ai.run(AiTask.t1Extract, {'note_text': note});
  sw.stop();

  switch (res) {
    case Success(value: final v):
      stdout.writeln('✅ 提取成功，耗时=${sw.elapsedMilliseconds}ms'
          '（服务端 ${v.latencyMs}ms，model=${v.modelId ?? '-'}）');
      final parsed = v.parsed;
      if (parsed is Map && parsed['knowledge_points'] is List) {
        final list = parsed['knowledge_points'] as List<dynamic>;
        stdout.writeln('   知识点条数=${list.length}');
        for (final e in list) {
          if (e is! Map) continue;
          stdout.writeln(
              '   - [${e['type']}] ${e['name']}  (置信度 ${e['confidence']})');
          if (e['source_quote'] != null) {
            stdout.writeln('       quote: ${e['source_quote']}');
          }
          if (e['prerequisites'] is List &&
              (e['prerequisites'] as List).isNotEmpty) {
            stdout.writeln('       前置: ${e['prerequisites']}');
          }
        }
      } else {
        stdout.writeln('⚠️ 解析后非知识树结构：$parsed');
      }
    case Failure():
      stderr.writeln('❌ 提取失败：${res.message}');
      stderr.writeln('   请确认 llm_server 已启动（$kLlmServerDefaultBaseUrl）：'
          'scripts\\run_llm_server.bat 或 python llm_server/run.py');
      exit(1);
  }
  exit(0);
}

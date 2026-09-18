// 端到端冒烟（纯 Dart，无 Drift / 无 sqlite3 原生依赖）。
//
// 链路：DifyClient.runTask(T1) → AiService（路由）→ 真实 Dify 工作流
// → 解析 knowledge_points → 打印结果。
//
// 用法（在 aimindtree_app 目录，Dify 需已启动）：
//   dart run tool/smoke_ai_service.dart
//   dart run tool/smoke_ai_service.dart "自定义笔记文本"
//
// 环境变量（若设了 http_proxy，需让 localhost 走直连）：
//   no_proxy=localhost,127.0.0.1 dart run tool/smoke_ai_service.dart

import 'dart:io';

import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/clients/dify_client.dart';
import 'package:aimindtree_app/core/result.dart';

Future<void> main(List<String> args) async {
  final note = args.isNotEmpty
      ? args.join(' ')
      : '牛顿第一定律：任何物体都要保持匀速直线运动或静止状态，'
          '直到外力迫使它改变运动状态为止。它说明了惯性的概念，是经典力学的基础。';

  final dify = DifyClient(
    id: 'dify-t1-local',
    baseUrl: 'http://localhost:8080',
    appApiKey: 'app-fhXwVvHFfVbVWRq3tRMOX8fd',
  );
  final router = AiTaskRouter(
    // 本冒烟只测 AiService，不读写 ai_task_routes，传 null 直接走 fallback。
    db: null,
    providers: {dify.id: dify},
    fallback: dify,
  );
  final ai = AiService(router: router);

  stdout.writeln('==> 调用 Dify T1 提取：');
  stdout.writeln('    $note');
  final sw = Stopwatch()..start();
  final res = await ai.run(AiTask.t1Extract, {'note_text': note});
  sw.stop();

  switch (res) {
    case Success(value: final v):
      stdout.writeln('✅ 提取成功，耗时=${sw.elapsedMilliseconds}ms');
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
      stderr.writeln('   请确认 Dify 已启动（http://localhost:8080）且 T1 工作流已发布。');
      exit(1);
  }
  exit(0);
}

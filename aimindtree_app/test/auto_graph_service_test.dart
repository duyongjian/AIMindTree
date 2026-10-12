import 'package:aimindtree_app/ai/ai_provider.dart';
import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/auto_graph_service.dart';
import 'package:aimindtree_app/ai/prereq_depth.dart';
import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;
  late TreeRepository trees;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 't');
    trees = TreeRepository(db, deviceId: 't');
  });

  tearDown(() => db.close());

  /// 造一篇笔记 + 若干知识点，返回知识点 id（顺序与 specs 一致）。
  Future<List<String>> seed(
    String noteId,
    List<(String name, String def)> specs,
  ) async {
    await repo.saveNote(Note(id: noteId, contentMd: 'x'));
    final r = await repo.saveExtracted(
      noteId: noteId,
      noteContent: 'x',
      rawPoints: [
        for (final s in specs)
          RawKnowledgePoint(
            name: s.$1,
            definition: s.$2,
            sourceQuote: 'x',
          ),
      ],
    );
    expect((r as Success).isSuccess, isTrue);
    return repo.pointIdsOfNote(noteId);
  }

  Future<String> makeTree(List<String> kpIds) async {
    final res = await trees.createTree('T', fixedId: 'tree1');
    final id = (res as Success).value.id;
    await trees.addPoints(id, kpIds);
    return id;
  }

  /// 把 parsed 直接当 AI 结果返回（DSL-first 路径）。
  AiRun okRun(Object? parsed) {
    return (AiTask task, Map<String, dynamic> inputs,
        {Duration timeout = const Duration(seconds: 120)}) {
      return Future.value(
        Success(AiTaskResult(content: '', parsed: parsed)),
      );
    };
  }

  /// 必然失败的 AI（走到本地兜底）。
  Future<Result<AiTaskResult>> failRun(AiTask task, Map<String, dynamic> inputs,
      {Duration timeout = const Duration(seconds: 120)}) {
    return Future.value(Failure<AiTaskResult>(StateError('no dify')));
  }

  /// 递归 AI：level1 以 [rootName] 为 target 时返回 gap [gapA]；以 [gapA] 为 target
  /// 时（即递归第二层）返回 gap [gapB]，用于验证多层级递归。
  AiRun recursiveRun(String rootName, String gapA, String gapB) {
    return (AiTask task, Map<String, dynamic> inputs,
        {Duration timeout = const Duration(seconds: 120)}) {
      final target = (inputs['target'] as String?) ?? '';
      final parsed = target.startsWith(gapA)
          ? {
              'gaps': [
                {
                  'name': gapB,
                  'type': '概念',
                  'definition': '更底层概念',
                  'reason': '需要先掌握 $gapB',
                  'level': 1,
                }
              ]
            }
          : {
              'gaps': [
                {
                  'name': gapA,
                  'type': '概念',
                  'definition': '直接前置',
                  'reason': '需要先掌握 $gapA',
                  'level': 1,
                }
              ]
            };
      return Future.value(Success(AiTaskResult(content: '', parsed: parsed)));
    };
  }

  bool hasCycle(List<PrerequisiteEdge> edges) {
    final adj = <String, Set<String>>{};
    for (final e in edges) {
      adj.putIfAbsent(e.fromKpId, () => <String>{}).add(e.toKpId);
    }
    // 对每个起点 DFS，若走回起点则存在环。
    for (final s in adj.keys) {
      final visited = <String>{};
      final stack = [s];
      while (stack.isNotEmpty) {
        final n = stack.removeLast();
        if (n == s && visited.isNotEmpty) return true;
        if (!visited.add(n)) continue;
        for (final nx in adj[n] ?? const <String>[]) {
          stack.add(nx);
        }
      }
    }
    return false;
  }

  group('自动连线（T3）', () {
    test('DSL-first：AI 返回 prerequisites → 直接落库，usedFallback=false', () async {
      final ids = await seed('n1', const [
        ('牛顿第二定律', '经典力学'),
        ('动量定理', '由牛顿第二定律导出'),
        ('动能定理', '由动量推导'),
      ]);
      final treeId = await makeTree(ids);

      final ai = AutoGraphService(
        ai: AiService(router: AiTaskRouter(providers: const {})),
        repo: repo,
        trees: trees,
        aiRun: okRun({
          'prerequisites': [
            {'from': ids[0], 'to': ids[1], 'reason': 'r1'},
            {'from': ids[1], 'to': ids[2], 'reason': 'r2'},
          ]
        }),
      );

      final res = await ai.autoLink(treeId);
      final r = (res as Success).value;
      expect(r.usedFallback, isFalse);
      expect(r.created, 2);
      final existing = await repo.prerequisiteEdgesAmong(ids);
      expect(existing.map((e) => '${e.fromKpId}->${e.toKpId}'), containsAll([
        '${ids[0]}->${ids[1]}',
        '${ids[1]}->${ids[2]}',
      ]));
    });

    test('AI 按 name 也能解析（容错不区分 id/name）', () async {
      final ids = await seed('n1', const [
        ('导数', '微积分基础'),
        ('泰勒展开', '依赖导数'),
      ]);
      final treeId = await makeTree(ids);

      final ai = AutoGraphService(
        ai: AiService(router: AiTaskRouter(providers: const {})),
        repo: repo,
        trees: trees,
        aiRun: okRun({
          'prerequisites': [
            {'from': '导数', 'to': '泰勒展开', 'reason': 'r'},
          ]
        }),
      );
      final r = (await ai.autoLink(treeId) as Success).value;
      expect(r.created, 1);
    });

    test('AI 失败 → 返回 Failure（不再本地启发式兜底，不落库）', () async {
      final ids = await seed('n1', const [
        ('牛顿第二定律', '经典力学'),
        ('动量定理', '由牛顿第二定律导出'),
        ('动能定理', '由动量推导'),
      ]);
      final treeId = await makeTree(ids);

      final ai = AutoGraphService(
        ai: AiService(router: AiTaskRouter(providers: const {})),
        repo: repo,
        trees: trees,
        aiRun: failRun,
      );
      final res = await ai.autoLink(treeId);
      expect(res.isSuccess, isFalse);
      // 不兜底 → 一条边都不该落库。
      expect(await repo.prerequisiteEdgesAmong(ids), isEmpty);
    });

    test('与已有边去重：AI 重复给出已存在的边不再新建', () async {
      final ids = await seed('n1', const [
        ('导数', 'a'),
        ('泰勒展开', '依赖导数'),
      ]);
      final treeId = await makeTree(ids);
      // 先手动建一条 导数→泰勒展开
      await repo.addManualPrerequisiteEdge(ids[0], ids[1]);

      final ai = AutoGraphService(
        ai: AiService(router: AiTaskRouter(providers: const {})),
        repo: repo,
        trees: trees,
        aiRun: okRun({
          'prerequisites': [
            {'from': ids[0], 'to': ids[1], 'reason': 'r'},
          ]
        }),
      );
      final r = (await ai.autoLink(treeId) as Success).value;
      expect(r.created, 0); // 已存在，跳过
      final all = await repo.prerequisiteEdgesAmong(ids);
      expect(all.length, 1);
    });

    test('防环：AI 给出 A→B 与 B→A，只保留其中一条', () async {
      final ids = await seed('n1', const [
        ('A', 'x'),
        ('B', 'x'),
      ]);
      final treeId = await makeTree(ids);
      final ai = AutoGraphService(
        ai: AiService(router: AiTaskRouter(providers: const {})),
        repo: repo,
        trees: trees,
        aiRun: okRun({
          'prerequisites': [
            {'from': ids[0], 'to': ids[1]},
            {'from': ids[1], 'to': ids[0]},
          ]
        }),
      );
      final r = (await ai.autoLink(treeId) as Success).value;
      expect(r.created, 1);
      final all = await repo.prerequisiteEdgesAmong(ids);
      expect(hasCycle(all), isFalse);
    });
  });

  group('自动补前置（T4，递归深度补前置）', () {
    test('DSL-first：AI 返回 gaps → 作为建议，不入库', () async {
      final ids = await seed('n1', const [
        ('牛顿第二定律', '经典力学'),
        ('动量定理', '由牛顿第二定律导出'),
      ]);
      final points = await repo.pointsByIds(ids);
      final target = points.first;

      final ai = AutoGraphService(
        ai: AiService(router: AiTaskRouter(providers: const {})),
        repo: repo,
        trees: trees,
        aiRun: okRun({
          'gaps': [
            {
              'name': '微积分基础',
              'type': '概念',
              'definition': 'xxx',
              'reason': '需要它',
              'level': 1,
            }
          ]
        }),
      );
      final r = (await ai.autoPrerequisites(target, PrereqDepth.medium) as Success<AutoPrereqResult>)
          .value;
      expect(r.usedFallback, isFalse);
      expect(r.suggestions, hasLength(1));
      expect(r.suggestions.first.name, '微积分基础');
      // 不入库：知识点数量没变
      expect(await repo.pointsByIds(ids), hasLength(2));
    });

    test('AI 失败 → 返回 Failure（不再本地启发式兜底，不入库）', () async {
      final ids = await seed('n1', const [
        ('泰勒展开', '由导数和极限推出'),
        ('洛必达法则', '用导数求极限'),
      ]);
      final points = await repo.pointsByIds(ids);
      final target = points.first;

      final ai = AutoGraphService(
        ai: AiService(router: AiTaskRouter(providers: const {})),
        repo: repo,
        trees: trees,
        aiRun: failRun,
      );
      final res = await ai.autoPrerequisites(target, PrereqDepth.medium);
      expect(res.isSuccess, isFalse);
      // 不入库
      expect(await repo.pointsByIds(ids), hasLength(2));
    });
  });

  group('路由修正（T1）与 T4 递归', () {
    test('路由：T4 未绑定专属 provider → resolve 返回 null（不回落 T1）', () async {
      final r = AiTaskRouter(providers: const {});
      expect(await r.resolve(AiTask.t4GapAnalysis), isNull);
    });

    test('路由：T3 未绑定专属 provider → resolve 返回 null（不回落 T1）', () async {
      final r = AiTaskRouter(providers: const {});
      expect(await r.resolve(AiTask.t3Prerequisite), isNull);
    });

    test('AiService.run(T4) 无 provider → 返回 Failure（provider 为 null）', () async {
      final svc = AiService(router: AiTaskRouter(providers: const {}));
      final res =
          await svc.run(AiTask.t4GapAnalysis, {'target': 'x', 'depth': 'high'});
      expect(res.isSuccess, isFalse);
    });

    test('递归：level1 返回 A、level2（以 A 为 target）返回 B → 含两层且层级≤maxLevels',
        () async {
      final ids = await seed('n1', const [
        ('目标知识点', '高阶内容'),
      ]);
      final points = await repo.pointsByIds(ids);
      final target = points.first;
      final ai = AutoGraphService(
        ai: AiService(router: AiTaskRouter(providers: const {})),
        repo: repo,
        trees: trees,
        aiRun: recursiveRun(target.name, '直接前置A', '更底层B'),
      );
      final r = (await ai.autoPrerequisites(target, PrereqDepth.medium) as Success<AutoPrereqResult>)
          .value;
      expect(r.usedFallback, isFalse);
      final levels = r.suggestions.map((s) => s.level).toSet();
      expect(levels, contains(1));
      expect(levels, contains(2));
      expect(r.suggestions.any((s) => s.name == '直接前置A'), isTrue);
      expect(r.suggestions.any((s) => s.name == '更底层B'), isTrue);
      // 层数不超过 maxLevels(medium=2)
      expect(r.suggestions.every((s) => s.level <= 2), isTrue);
      // 全程不入库：知识点数量没变
      expect(await repo.pointsByIds(ids), hasLength(1));
    });

    test('深度差异：low 仅 1 层，high 出现 level=2（客户端递归受 maxLevels 约束）', () async {
      final ids = await seed('n1', const [
        ('高阶概念', 'x'),
      ]);
      final points = await repo.pointsByIds(ids);
      final target = points.first;
      final ai = AutoGraphService(
        ai: AiService(router: AiTaskRouter(providers: const {})),
        repo: repo,
        trees: trees,
        aiRun: recursiveRun(target.name, '直接前置A', '更底层B'),
      );
      final low =
          (await ai.autoPrerequisites(target, PrereqDepth.low) as Success).value;
      final high =
          (await ai.autoPrerequisites(target, PrereqDepth.high) as Success).value;
      expect(low.suggestions.every((s) => s.level == 1), isTrue);
      expect(high.suggestions.any((s) => s.level == 2), isTrue);
      expect(await repo.pointsByIds(ids), hasLength(1));
    });

    test('自定义指令：一层 → maxLevels=1（只产出 level=1）', () async {
      final ids = await seed('n1', const [
        ('高阶概念', 'x'),
      ]);
      final points = await repo.pointsByIds(ids);
      final target = points.first;
      final ai = AutoGraphService(
        ai: AiService(router: AiTaskRouter(providers: const {})),
        repo: repo,
        trees: trees,
        aiRun: recursiveRun(target.name, '直接前置A', '更底层B'),
      );
      final r = (await ai.autoPrerequisites(
        target,
        PrereqDepth.custom,
        customInstruction: '只要一层直接前置即可',
      ) as Success<AutoPrereqResult>)
          .value;
      expect(r.usedFallback, isFalse);
      expect(r.suggestions.every((s) => s.level == 1), isTrue);
    });
  });
}

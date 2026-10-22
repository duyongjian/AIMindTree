/// 知识点「查重去重」测试（T14 App 侧）。
///
/// 覆盖四层：
/// 1. **本地预筛**（findDedupCandidates）：同名（大小写 / 标点差异）、包含
///    关系、bigram 近似、明显不同名不误报、cap 截断与降序排序；
/// 2. **聚类**（parseDedupDuplicates / clusterDuplicateIds /
///    buildKpDedupClusters）：并查集传递性、缺成员丢簇、JSON 容错；
/// 3. **合并核心**（mergeDuplicateCluster）端到端：来源笔记 / 树成员 + 位置 /
///    连线重建（含单后继冲突跳过计数）/ 掌握度复制 / 软删墓碑；
/// 4. **触发与对话窗**：无候选回调、在飞短路、对话窗默认保留最老者 +
///    确认合并 + toast 回执。
library;

import 'dart:io';

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:aimindtree_app/features/knowledge/kp_dedup.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 不起真网络的假 HttpClient：postUrl 直接抛（模拟 llm_server 没起）。
class _NoServerHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> postUrl(Uri url) async =>
      throw const SocketException('test: no llm_server');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;
  late TreeRepository trees;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 't');
    trees = TreeRepository(db, deviceId: 't');
  });

  tearDown(() async {
    await db.close();
  });

  /// 造一个纯 Dart 知识点（预筛 / 聚类纯函数测试用，不入库）。
  KnowledgePoint kp(
    String id,
    String name, {
    DateTime? createdAt,
    String sourceNoteId = '',
    String definition = '',
  }) =>
      KnowledgePoint(
        id: id,
        name: name,
        definition: definition,
        sourceNoteId: sourceNoteId,
        sourceStart: 0,
        sourceEnd: 0,
        sourceQuote: '',
        createdAt: createdAt,
      );

  /// 入库一个手动知识点（合并端到端测试用）。
  Future<KnowledgePoint> makeKp(String name, {String sourceNoteId = ''}) async {
    final res = await repo.createManualKnowledgePoint(
      name: name,
      sourceNoteId: sourceNoteId,
    );
    return (res as Success<KnowledgePoint>).value;
  }

  // ==================== 1. 本地预筛 ====================

  group('findDedupCandidates（本地预筛，控制喂 LLM 的量）', () {
    test('同名（大小写 / 标点差异也算）→ 1.0', () {
      final out = findDedupCandidates(<KnowledgePoint>[
        kp('a', '牛顿第一定律'),
        kp('b', '牛顿第一定律。'),
        kp('c', 'Derivative'),
        kp('d', 'derivative'),
        kp('e', "Newton's First Law"),
        kp('f', 'Newtons First Law'),
      ]);
      // 三对同名，跨对不误报（中英文之间二元组不重叠）。
      expect(out.map((p) => '${p.aId}${p.bId}'), <String>['ab', 'cd', 'ef']);
      expect(out.every((p) => p.score == 1.0), isTrue);
    });

    test('包含关系（较短者 ≥4）→ 0.8；较短者 <4 不命中', () {
      final hit = findDedupCandidates(<KnowledgePoint>[
        kp('a', '光合作用'),
        kp('b', '光合作用过程'),
      ]);
      expect(hit, hasLength(1));
      expect(hit.single.score, 0.8);
      expect(hit.single.aId, 'a'); // 无序对只出一次，按输入顺序

      // 「极限」（2 字）被「极限的概念」包含，但较短者 <4 → 不按包含计；
      // 二元组 1/4 也低于 0.6 → 整对不出。
      final miss = findDedupCandidates(<KnowledgePoint>[
        kp('a', '极限'),
        kp('b', '极限的概念'),
      ]);
      expect(miss, isEmpty);
    });

    test('字符二元组近似 → 分数 = Jaccard', () {
      // 共享前 7 个二元组、尾部各差 1 字：7/11 ≈ 0.636（非包含、非同名）。
      final out = findDedupCandidates(<KnowledgePoint>[
        kp('a', '概率图模型理论与应用'),
        kp('b', '概率图模型理论与实战'),
      ]);
      expect(out, hasLength(1));
      expect(out.single.score, closeTo(7 / 11, 1e-9));
    });

    test('明显不同名不误报', () {
      final out = findDedupCandidates(<KnowledgePoint>[
        kp('a', '光合作用'),
        kp('b', '牛顿第一定律'),
        kp('c', '线性代数'),
      ]);
      expect(out, isEmpty);
    });

    test('按分数降序 + cap 截断', () {
      final points = <KnowledgePoint>[
        kp('a', '牛顿第一定律'),
        kp('b', '牛顿第一定律！'), // (a,b) 1.0
        kp('c', '光合作用'),
        kp('d', '光合作用过程'), // (c,d) 0.8
        kp('e', '概率图模型理论与应用'),
        kp('f', '概率图模型理论与实战'), // (e,f) ≈0.636
      ];
      final all = findDedupCandidates(points);
      expect(all.map((p) => '${p.aId}${p.bId}'), <String>['ab', 'cd', 'ef']);
      expect(
        all.map((p) => p.score),
        <Object>[1.0, 0.8, closeTo(7 / 11, 1e-9)],
      );

      final top2 = findDedupCandidates(points, maxPairs: 2);
      expect(top2.map((p) => '${p.aId}${p.bId}'), <String>['ab', 'cd']);

      final top1 = findDedupCandidates(points, maxPairs: 1);
      expect(top1.map((p) => '${p.aId}${p.bId}'), <String>['ab']);
    });

    test('空 / 单点 / 非正 cap → 空', () {
      expect(findDedupCandidates(const <KnowledgePoint>[]), isEmpty);
      expect(findDedupCandidates(<KnowledgePoint>[kp('a', 'x')]), isEmpty);
      expect(
        findDedupCandidates(
          <KnowledgePoint>[kp('a', '同名'), kp('b', '同名')],
          maxPairs: 0,
        ),
        isEmpty,
      );
    });
  });

  // ==================== 2. 聚类（并查集） ====================

  group('聚类（并查集）', () {
    test('parseDedupDuplicates：容错解析（缺键 / 空 id / 自环 / 非 Map 跳过）', () {
      final dups = parseDedupDuplicates(<dynamic>[
        <String, dynamic>{'a_id': 'a', 'b_id': 'b', 'reason': '同义不同名'},
        <String, dynamic>{'a_id': '', 'b_id': 'b'},
        <String, dynamic>{'a_id': 'a'},
        'not a map',
        <String, dynamic>{'a_id': 'c', 'b_id': 'c'},
        <String, dynamic>{'a_id': 'd', 'b_id': 'e'},
      ]);
      expect(dups, hasLength(2));
      expect(dups.first.aId, 'a');
      expect(dups.first.bId, 'b');
      expect(dups.first.reason, '同义不同名');
      expect(dups.last.reason, ''); // 缺 reason 不炸，退空串

      // 非列表输入一律空。
      expect(parseDedupDuplicates(null), isEmpty);
      expect(parseDedupDuplicates('x'), isEmpty);
      expect(
        parseDedupDuplicates(<String, dynamic>{'duplicates': <dynamic>[]}),
        isEmpty,
      );
    });

    test('传递性：A-B、B-C 合成一簇', () {
      final clusters = clusterDuplicateIds(const <DedupDuplicatePair>[
        DedupDuplicatePair(aId: 'a', bId: 'b'),
        DedupDuplicatePair(aId: 'b', bId: 'c'),
      ]);
      expect(clusters, hasLength(1));
      expect(clusters.single, <String>['a', 'b', 'c']);
    });

    test('两个独立簇：乱序输入也按首个 id 升序输出', () {
      final clusters = clusterDuplicateIds(const <DedupDuplicatePair>[
        DedupDuplicatePair(aId: 'd', bId: 'c'),
        DedupDuplicatePair(aId: 'b', bId: 'a'),
      ]);
      expect(clusters, hasLength(2));
      expect(clusters.first, <String>['a', 'b']);
      expect(clusters.last, <String>['c', 'd']);
    });

    test('buildKpDedupClusters：成员被删得不成簇就丢弃；理由合并展示', () {
      final pairs = const <DedupDuplicatePair>[
        DedupDuplicatePair(aId: 'a', bId: 'b', reason: '理由一'),
        DedupDuplicatePair(aId: 'b', bId: 'c', reason: '理由二'),
      ];
      // b 已被删：a、c 靠传递性仍同簇（2 个存活成员，保留）。
      final two = buildKpDedupClusters(
        pairs: pairs,
        points: <KnowledgePoint>[
          kp('a', '甲', createdAt: DateTime.utc(2024)),
          kp('c', '丙', createdAt: DateTime.utc(2024)),
        ],
      );
      expect(two, hasLength(1));
      expect(two.single.memberIds, <String>['a', 'c']);
      expect(two.single.reason, '理由一；理由二');

      // 只剩 1 个存活成员：不成簇，丢弃。
      final one = buildKpDedupClusters(
        pairs: pairs,
        points: <KnowledgePoint>[kp('a', '甲')],
      );
      expect(one, isEmpty);

      // 无输入对 → 空。
      expect(
        buildKpDedupClusters(pairs: const <DedupDuplicatePair>[], points: const <KnowledgePoint>[]),
        isEmpty,
      );
    });

    test('defaultKeepId：默认保留 createdAt 最老者，并列取列表中第一个', () {
      final old = kp('old', '老', createdAt: DateTime.utc(2024, 1, 1));
      final fresh = kp('new', '新', createdAt: DateTime.utc(2025, 1, 1));
      expect(defaultKeepId(<KnowledgePoint>[fresh, old]), 'old');

      final t1 = kp('t1', '并列1', createdAt: DateTime.utc(2024, 6, 1));
      final t2 = kp('t2', '并列2', createdAt: DateTime.utc(2024, 6, 1));
      expect(defaultKeepId(<KnowledgePoint>[t2, t1]), 't2');
    });
  });

  // ==================== 3. 合并核心（端到端） ====================

  group('mergeDuplicateCluster（端到端，内存库）', () {
    test('来源 / 树成员 + 位置 / 连线重建 / 掌握度迁移 + 软删墓碑', () async {
      // 保留点 K：无来源、无掌握、不在树里。
      final k = await makeKp('光合作用');
      // 被删点 D：有来源 note-1、将有掌握记录、在树 A 有位置。
      final d = await makeKp('光合作用。', sourceNoteId: 'note-1');
      // 目标点 X。
      final x = await makeKp('呼吸作用');

      // 边（批量写入不走单后继校验，专测迁移逻辑）：
      //   D→K（重复对之间一条边，迁移即成自环 → 跳过）
      //   D→X（出射边，应重建到 K 上）
      await repo.addPrerequisiteEdges(<PrerequisiteEdge>[
        PrerequisiteEdge(fromKpId: d.id, toKpId: k.id),
        PrerequisiteEdge(fromKpId: d.id, toKpId: x.id),
      ]);

      // 树 A：D 是成员且有位置 (150, 90, pinned)；K 不在树里。
      await trees.createTree('树A', fixedId: 'tree-a');
      await trees.addPoints('tree-a', <String>[d.id]);
      await repo.saveNodePosition('tree-a', d.id, 150, 90, pinned: true);

      // D 有掌握记录；K 没有。
      await repo.setMastery(d.id, MasteryStatus.mastered);

      // 执行合并（成员现场重新加载，与对话窗口径一致）。
      final report = await mergeDuplicateCluster(
        repo: repo,
        trees: trees,
        db: db,
        members: await repo.pointsByIds(<String>[k.id, d.id]),
        keepId: k.id,
      );

      expect(report.mergedCount, 1);
      // D→K（重复对之间的边）迁移成 K→K 自环 → 跳过并计数；
      // D→X 迁移成 K→X 成功重建（保留点此时没有后继）。
      expect(report.skippedEdges, 1);
      expect(report.failedIds, isEmpty);

      // 保留点存活、被删点墓碑（直查库）。
      final kRow = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(k.id)))
          .getSingle();
      final dRow = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(d.id)))
          .getSingle();
      expect(kRow.deletedAt, isNull);
      expect(dRow.deletedAt, isNotNull);

      // 来源笔记继承（K 原来没有来源，单列只能「空者继承」）。
      expect(kRow.sourceNoteId, 'note-1');

      // 树成员迁移 + 位置继承（含 pinned）。
      expect(await trees.memberPointIds('tree-a'), <String>[k.id]);
      final layout = await repo.loadNodeLayout('tree-a');
      expect(layout[k.id], (x: 150.0, y: 90.0, pinned: true));

      // 连线：D→X 重建为 K→X；D 的边随软删级联清掉。
      final edges = await db.select(db.prerequisiteEdges).get();
      expect(edges, hasLength(1));
      expect(edges.single.fromKpId, k.id);
      expect(edges.single.toKpId, x.id);
      expect(edges.single.origin, 'manual');
      expect(edges.single.reason, '查重合并迁移');

      // 掌握度复制到保留点。
      expect(await repo.currentMastery(k.id), MasteryStatus.mastered);
    });

    test('单后继冲突：保留点已有后继时，被删点出射边跳过并计数', () async {
      final k = await makeKp('细胞分裂');
      final d = await makeKp('细胞分裂。');
      final x = await makeKp('有丝分裂');
      // K→X 已存在（K 已有后继）；D→X 指向同一个目标 → 迁移必撞单后继规则。
      await repo.addPrerequisiteEdges(<PrerequisiteEdge>[
        PrerequisiteEdge(fromKpId: k.id, toKpId: x.id),
        PrerequisiteEdge(fromKpId: d.id, toKpId: x.id),
      ]);

      final report = await mergeDuplicateCluster(
        repo: repo,
        trees: trees,
        db: db,
        members: await repo.pointsByIds(<String>[k.id, d.id]),
        keepId: k.id,
      );

      expect(report.mergedCount, 1);
      expect(report.skippedEdges, 1);
      expect(report.failedIds, isEmpty);

      // 没有硬挂出重复连线：K→X 还是原来那一条。
      final edges = await db.select(db.prerequisiteEdges).get();
      expect(edges, hasLength(1));
      expect(edges.single.fromKpId, k.id);
      expect(edges.single.toKpId, x.id);

      // 被删点墓碑。
      final dRow = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(d.id)))
          .getSingle();
      expect(dRow.deletedAt, isNotNull);
    });

    test('防环 / 入射边冲突都跳过并计数（不硬挂）', () async {
      final k = await makeKp('甲');
      final d = await makeKp('乙');
      final x = await makeKp('丙');
      final y = await makeKp('丁');
      // X→K（X 是 K 的前置）；D→X（D 的前置是 X）。
      // 迁移 D→X 成 K→X 会成环（X→K→X）→ 防环校验拒绝。
      // Y→D（Y 是 D 的前置）：迁移成 Y→K 撞「Y 已有后继」规则 → 拒绝。
      await repo.addPrerequisiteEdges(<PrerequisiteEdge>[
        PrerequisiteEdge(fromKpId: x.id, toKpId: k.id),
        PrerequisiteEdge(fromKpId: d.id, toKpId: x.id),
        PrerequisiteEdge(fromKpId: y.id, toKpId: d.id),
      ]);

      final report = await mergeDuplicateCluster(
        repo: repo,
        trees: trees,
        db: db,
        members: await repo.pointsByIds(<String>[k.id, d.id]),
        keepId: k.id,
      );

      expect(report.mergedCount, 1);
      expect(report.skippedEdges, 2); // 出射防环 1 + 入射单后继 1
      expect(report.failedIds, isEmpty);

      // 冲突的边都没硬挂：只剩原来的 X→K。
      final edges = await db.select(db.prerequisiteEdges).get();
      expect(edges, hasLength(1));
      expect(edges.single.fromKpId, x.id);
      expect(edges.single.toKpId, k.id);
    });

    test('成员不足 2 个 → 空报告不写库', () async {
      final k = await makeKp('孤点');
      final report = await mergeDuplicateCluster(
        repo: repo,
        trees: trees,
        db: db,
        members: <KnowledgePoint>[k],
        keepId: k.id,
      );
      expect(report.mergedCount, 0);
      expect(report.skippedEdges, 0);
      expect(report.failedIds, isEmpty);
      final row = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(k.id)))
          .getSingle();
      expect(row.deletedAt, isNull);
    });
  });

  // ==================== 4. 触发与对话窗 ====================

  group('触发（kpDedupRunNow / kpDedupSchedule）', () {
    test('无候选 → 回调 onNoCandidates，不提交任务', () async {
      var called = false;
      await kpDedupRunNow(
        repo: repo,
        jobs: AiJobService(
          baseUrl: 'http://127.0.0.1:1',
          client: _NoServerHttpClient(),
        ),
        onNoCandidates: () => called = true,
      );
      expect(called, isTrue);
      expect(kpDedupInFlight, isFalse);
    });

    test('在飞标志：扫描启动即置位；重复触发直接跳过；终态后释放', () async {
      await makeKp('重复点');
      await makeKp('重复点');
      final jobs = AiJobService(
        baseUrl: 'http://127.0.0.1:1',
        client: _NoServerHttpClient(),
      );

      // 第一次：有候选 → 进 submit（假 client 抛错 → 内部吞掉）。
      final first = kpDedupRunNow(repo: repo, jobs: jobs);
      // 同步段已跑完（首个 await 之前标志即置位）。
      expect(kpDedupInFlight, isTrue);

      // 第二次：在飞 → 立即返回（不重复读库 / 提交）。
      var secondReturned = false;
      await kpDedupRunNow(repo: repo, jobs: jobs)
          .then((_) => secondReturned = true);
      expect(secondReturned, isTrue);

      // 等第一次走完（submit 失败被吞）→ 标志释放。
      await first;
      expect(kpDedupInFlight, isFalse);
    });
  });

  group('对话窗（showKpDedupDialog）', () {
    /// 开对话窗的测试 harness（按钮触发，模拟页面入口）。
    Widget harness(void Function(BuildContext ctx) open) => MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => open(ctx),
                child: const Text('打开'),
              ),
            ),
          ),
        );

    /// 建一对重复点并强制 createdAt（kOld 更老），返回 (old, new)。
    Future<(KnowledgePoint, KnowledgePoint)> makePair() async {
      final oldKp = await makeKp('光合作用');
      final newKp = await makeKp('光合作用。');
      await (db.update(db.knowledgePoints)
            ..where((t) => t.id.equals(oldKp.id)))
          .write(KnowledgePointsCompanion(
        createdAt: Value(DateTime.utc(2024, 1, 1)),
      ));
      await (db.update(db.knowledgePoints)
            ..where((t) => t.id.equals(newKp.id)))
          .write(KnowledgePointsCompanion(
        createdAt: Value(DateTime.utc(2025, 1, 1)),
      ));
      return (oldKp, newKp);
    }

    testWidgets('默认保留最老者；确认后合并 + toast 回执', (tester) async {
      final (oldKp, newKp) = await makePair();
      // 给被删点（默认会被删的新点）造条掌握记录，验证合并时复制过去。
      await repo.setMastery(newKp.id, MasteryStatus.mastered);

      await tester.pumpWidget(harness(
        (ctx) => showKpDedupDialog(
          ctx,
          <KpDedupCluster>[
            KpDedupCluster(
              members: <KnowledgePoint>[oldKp, newKp],
              reason: '同一概念的不同表述',
            ),
          ],
          repo: repo,
          trees: trees,
          db: db,
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      // 标题 + AI 理由 + 两个成员都在。
      expect(find.text('发现 1 组重复知识点'), findsOne);
      expect(find.textContaining('同一概念的不同表述'), findsOne);
      expect(find.text('光合作用'), findsOne);
      expect(find.text('光合作用。'), findsOne);

      // 不改选，直接确认：默认保留最老者 oldKp。
      await tester.tap(find.text('去重并迁移关联'));
      await tester.pumpAndSettle();

      final oldRow = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(oldKp.id)))
          .getSingle();
      final newRow = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(newKp.id)))
          .getSingle();
      expect(oldRow.deletedAt, isNull);
      expect(newRow.deletedAt, isNotNull);
      // 掌握度复制到保留者。
      expect(await repo.currentMastery(oldKp.id), MasteryStatus.mastered);
      // toast 回执。
      expect(find.textContaining('已合并'), findsOne);
    });

    testWidgets('改选保留者：新选的存活，默认最老者被合并', (tester) async {
      final (oldKp, newKp) = await makePair();

      await tester.pumpWidget(harness(
        (ctx) => showKpDedupDialog(
          ctx,
          <KpDedupCluster>[
            KpDedupCluster(
              members: <KnowledgePoint>[oldKp, newKp],
              reason: '同一概念的不同表述',
            ),
          ],
          repo: repo,
          trees: trees,
          db: db,
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      // 改选较新者：点它的 RadioListTile。
      await tester.tap(find.byWidgetPredicate(
        (w) => w is RadioListTile<String> && w.value == newKp.id,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('去重并迁移关联'));
      await tester.pumpAndSettle();

      final oldRow = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(oldKp.id)))
          .getSingle();
      final newRow = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(newKp.id)))
          .getSingle();
      expect(newRow.deletedAt, isNull);
      expect(oldRow.deletedAt, isNotNull);
      expect(find.textContaining('已合并'), findsOne);
    });

    testWidgets('「暂不处理」直接关闭，不写库', (tester) async {
      final (oldKp, newKp) = await makePair();

      await tester.pumpWidget(harness(
        (ctx) => showKpDedupDialog(
          ctx,
          <KpDedupCluster>[
            KpDedupCluster(
              members: <KnowledgePoint>[oldKp, newKp],
              reason: '同一概念的不同表述',
            ),
          ],
          repo: repo,
          trees: trees,
          db: db,
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('暂不处理'));
      await tester.pumpAndSettle();

      expect(find.text('发现 1 组重复知识点'), findsNothing);
      final rows = await db.select(db.knowledgePoints).get();
      expect(rows.every((r) => r.deletedAt == null), isTrue);
    });
  });
}

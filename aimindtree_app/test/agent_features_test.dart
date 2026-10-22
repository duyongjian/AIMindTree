/// AI 助手三件套测试（D 直连入树 / G 检测面板 / H 会话管理）。
///
/// 覆盖：
/// - **D**：检测建议直连入树——建成 origin=user_manual 知识点并入树，
///   **不产生任何笔记**；空名/失败项进 failures 不阻塞成功项。
/// - **G**：检测面板可收起 / 展开；单条「不添加」与批量「不添加 / 全不添加」
///   只从本地检测列表移除（widget 测试，pumpWidget + 注入检测项）。
/// - **H**：会话管理走仓储——新建 / 列表（最近在前）/ 消息持久化与软删过滤 /
///   清空（留会话）/ 删除（连消息）/ 重命名（title 列）/ KP 会话不混入。
library;

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/extraction_service.dart';
import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_tree.dart';
import 'package:aimindtree_app/data/repositories/ai_session_repository.dart';
import 'package:aimindtree_app/data/repositories/group_repository.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/note_asset_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:aimindtree_app/features/agent/agent_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;
  late TreeRepository trees;
  late AiSessionRepository sessions;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 't');
    trees = TreeRepository(db, deviceId: 't');
    sessions = AiSessionRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// 建一棵树（固定 id，断言省心）。
  Future<KnowledgeTree> makeTree(String name, String id) async {
    final res = await trees.createTree(name, fixedId: id);
    return (res as Success<KnowledgeTree>).value;
  }

  /// 造一个只够初始化页面的 ExtractionService（测试不发消息、不提交任务）。
  ExtractionService makeService() => ExtractionService(
        repo: repo,
        trees: trees,
        groups: GroupRepository(db, deviceId: 't'),
        ai: AiService(router: AiTaskRouter(providers: const {})),
        jobs: AiJobService(baseUrl: 'http://127.0.0.1:1'),
        assets: NoteAssetRepository(db, deviceId: 't'),
      );

  // ============================== D：直连入树 ==============================

  group('D：检测建议直连入树（user_manual，不产生笔记）', () {
    test('勾选项直连建成 user_manual KP 并入树，且不产生任何笔记', () async {
      final tree = await makeTree('高等数学', 'tree-d1');
      final result = await addDetectedDirectlyToTree(
        repo: repo,
        trees: trees,
        db: db,
        tree: tree,
        items: const [
          AgentDetectedItem(name: '导数', definition: '描述变化率的数学概念'),
          AgentDetectedItem(name: '极限', definition: '逼近的思想', weak: true),
        ],
      );

      expect(result.failures, isEmpty);
      expect(result.createdIds, hasLength(2));
      expect(result.addedCount, 2);

      // 知识点：origin=user_manual（锚点豁免），锚点四件套留空、无出处笔记。
      final kps = await repo.allKnowledgePoints();
      expect(kps, hasLength(2));
      for (final kp in kps) {
        expect(kp.origin, 'user_manual');
        expect(kp.sourceNoteId, '');
        expect(kp.sourceStart, -1);
        expect(kp.sourceEnd, -1);
        expect(kp.sourceQuote, '');
      }
      expect(kps.map((k) => k.name), containsAll(<String>{'导数', '极限'}));
      // definition 带过去了（可改）。
      expect(kps.firstWhere((k) => k.name == '导数').definition,
          '描述变化率的数学概念');

      // 入树（幂等 addPoints）。
      expect(await trees.memberPointIds(tree.id), hasLength(2));

      // **不产生笔记**（这是 D 与旧「先建笔记再 T1 提取」路径的核心差异）。
      expect(await db.select(db.notes).get(), isEmpty);
    });

    test('同一 KP 重复入同一棵树不重复添加（幂等）', () async {
      final tree = await makeTree('幂等树', 'tree-d2');
      const items = [AgentDetectedItem(name: '罗尔定理')];
      final first = await addDetectedDirectlyToTree(
        repo: repo,
        trees: trees,
        db: db,
        tree: tree,
        items: items,
      );
      expect(first.addedCount, 1);
      // 新点已是树成员：再 addPoints 同一 id 集合，added=0。
      final second = await addDetectedDirectlyToTree(
        repo: repo,
        trees: trees,
        db: db,
        tree: tree,
        items: const [AgentDetectedItem(name: '罗尔定理')],
      );
      // 第二次是「同名新建 + 同棵新树成员」，点数仍是 2（每个 id 只入一次）。
      expect(await trees.memberPointIds(tree.id), hasLength(2));
      expect(second.addedCount, 1);
    });

    test('空名 / 创建失败进 failures，成功项照常入树', () async {
      final tree = await makeTree('容错树', 'tree-d3');
      final result = await addDetectedDirectlyToTree(
        repo: repo,
        trees: trees,
        db: db,
        tree: tree,
        items: const [
          AgentDetectedItem(name: '   '), // 空名 → 仓储拒绝
          AgentDetectedItem(name: '有效点'),
        ],
      );
      expect(result.failures, hasLength(1));
      expect(result.createdNames, <String>['有效点']);
      expect(result.addedCount, 1);
      expect(await trees.memberPointIds(tree.id), <String>[
        result.createdIds.single,
      ]);
    });
  });

  // ============================== G：检测面板 ==============================

  group('G：检测面板可收起 / 可不添加', () {
    const seed = <AgentDetectedItem>[
      AgentDetectedItem(name: '薄弱点：极限概念', reason: 'ε-δ 表述说不清', weak: true),
      AgentDetectedItem(name: '需要的知识点：导数', reason: '对话里反复出现'),
    ];

    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: child));

    testWidgets('头部点击收起 / 展开：收起只剩标题，展开恢复列表', (tester) async {
      await tester.pumpWidget(wrap(AgentPage(
        service: makeService(),
        db: db,
        debugSeedDetected: seed,
      )));
      await tester.pumpAndSettle();

      // 默认展开：标题 + 列表项都在。
      expect(find.text('检测到的知识点（2）'), findsOne);
      expect(find.text('薄弱点：极限概念'), findsOne);

      // 收起：只剩标题行。
      await tester.tap(find.text('检测到的知识点（2）'));
      await tester.pumpAndSettle();
      expect(find.text('检测到的知识点（2）'), findsOne);
      expect(find.text('薄弱点：极限概念'), findsNothing);
      expect(find.byTooltip('不添加'), findsNothing);

      // 再点展开：列表回来。
      await tester.tap(find.text('检测到的知识点（2）'));
      await tester.pumpAndSettle();
      expect(find.text('薄弱点：极限概念'), findsOne);
    });

    testWidgets('单条「不添加」：仅从本地检测列表移除', (tester) async {
      await tester.pumpWidget(wrap(AgentPage(
        service: makeService(),
        db: db,
        debugSeedDetected: seed,
      )));
      await tester.pumpAndSettle();

      // 面板列表区矮（ListView 懒加载）：ensureVisible 把第二条也构建出来，
      // 且第一条（weak 项）仍完整可见。
      await tester.ensureVisible(find.byTooltip('不添加').last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('不添加'), findsNWidgets(2));

      // 点可见的那条（weak 项）的「不添加」。
      await tester.tap(find.byTooltip('不添加').first);
      await tester.pumpAndSettle();

      // 计数 2 → 1，被移除项消失；不入库（库里的知识点表仍为空）。
      expect(find.text('检测到的知识点（1）'), findsOne);
      expect(find.text('薄弱点：极限概念'), findsNothing);
      expect(find.text('需要的知识点：导数'), findsOne);
      expect(await repo.allKnowledgePoints(), isEmpty);
      expect(await db.select(db.notes).get(), isEmpty);
    });

    testWidgets('批量不添加（对勾选项）+ 全不添加：清空本地检测列表',
        (tester) async {
      await tester.pumpWidget(wrap(AgentPage(
        service: makeService(),
        db: db,
        debugSeedDetected: seed,
      )));
      await tester.pumpAndSettle();

      // 勾选可见的第一条（weak 项）。
      await tester.tap(find.text('薄弱点：极限概念'));
      await tester.pumpAndSettle();
      expect(find.text('批量不添加（1）'), findsOne);

      // 批量不添加：勾选项移除，未勾的留下。
      await tester.tap(find.text('批量不添加（1）'));
      await tester.pumpAndSettle();
      expect(find.text('检测到的知识点（1）'), findsOne);
      expect(find.text('薄弱点：极限概念'), findsNothing);
      expect(find.text('需要的知识点：导数'), findsOne);

      // 全不添加：列表清空 → 整个面板卸载。
      await tester.tap(find.text('全不添加'));
      await tester.pumpAndSettle();
      expect(find.text('检测到的知识点（1）'), findsNothing);
      expect(find.byTooltip('不添加'), findsNothing);
      // 输入栏还在（页面本身没坏）。
      expect(find.byType(TextField), findsOne);
    });

    testWidgets('收起后面板真正收拢：仅剩标题行、检测项消失且容器高度收缩',
        (tester) async {
      await tester.pumpWidget(wrap(AgentPage(
        service: makeService(),
        db: db,
        debugSeedDetected: seed,
      )));
      await tester.pumpAndSettle();

      // 定位检测面板容器（maxHeight: 260）。
      final panel = find.byWidgetPredicate(
        (w) => w is Container && w.constraints?.maxHeight == 260.0,
      );
      expect(panel, findsOne);
      final expandedH = tester.getSize(panel).height;

      // 默认展开：标题 + 检测项都可见。
      expect(find.text('检测到的知识点（2）'), findsOne);
      expect(find.text('薄弱点：极限概念'), findsOne);

      // 收起。
      await tester.tap(find.text('检测到的知识点（2）'));
      await tester.pumpAndSettle();

      // 标题仍可见，任一检测项标题已不可见（真正收拢，非留空白）。
      expect(find.text('检测到的知识点（2）'), findsOne);
      expect(find.text('薄弱点：极限概念'), findsNothing);
      expect(find.text('需要的知识点：导数'), findsNothing);

      // 容器高度从 ~260 收缩到仅标题行高度（远小于展开时的一半）。
      final collapsedH = tester.getSize(panel).height;
      expect(collapsedH, lessThan(expandedH / 2));
      expect(collapsedH, lessThan(120));
    });

    testWidgets('点「全部添加」：勾选全部检测项，加入按钮计数=总数',
        (tester) async {
      await tester.pumpWidget(wrap(AgentPage(
        service: makeService(),
        db: db,
        debugSeedDetected: seed,
      )));
      await tester.pumpAndSettle();

      // 初始无勾选 → 加入（0）。
      expect(find.text('加入（0）'), findsOne);

      // 点「全部添加」（默认展开、按钮可见且可用）。
      await tester.tap(find.text('全部添加'));
      await tester.pumpAndSettle();

      // 全部检测项被勾选 → 加入按钮 N = 检测项总数（2）。
      expect(find.text('全部添加'), findsOne);
      expect(find.text('加入（2）'), findsOne);
      expect(find.text('批量不添加（2）'), findsOne);
      // 未选目标树时只提示、不入树（库仍为空）。
      expect(await repo.allKnowledgePoints(), isEmpty);
    });
  });

  // ============================== H：会话管理 ==============================

  group('H：会话管理（仓储）', () {
    test('新建 + 列表：最近活跃在前，KP 绑定的老师会话不混入', () async {
      final a = await sessions.createAgentSession();
      await Future.delayed(const Duration(milliseconds: 5));
      final b = await sessions.createAgentSession();

      // KP 会话（老师模式）不应出现在 agent 列表里。
      await sessions.getOrCreateForKp(kpId: 'kp-1', task: AiTask.t5Ask);

      final list = await sessions.listAgentSessions();
      expect(list.map((s) => s.id), <String>[b.id, a.id]);
      expect(list.every((s) => s.kpId == null), isTrue);
      expect(list.every((s) => s.deletedAt == null), isTrue);
    });

    test('消息持久化 + 按时间序读取；追加消息会把会话顶到最前', () async {
      // 注意：Drift 的 updated_at 是**秒级**精度，跨秒才能稳定区分先后，
      // 所以这里用 1.1s 的步进（生产上同一秒内的并列按 id 倒序兜底）。
      final a = await sessions.createAgentSession();
      await Future.delayed(const Duration(milliseconds: 1100));
      final b = await sessions.createAgentSession();
      expect((await sessions.listAgentSessions()).first.id, b.id);

      await Future.delayed(const Duration(milliseconds: 1100));
      await sessions.addMessage(sessionId: a.id, role: 'user', content: '第一问');
      await sessions.addMessage(sessionId: a.id, role: 'assistant', content: '第一答');

      final msgs = await sessions.listMessages(a.id);
      expect(msgs.map((m) => m.role), <String>['user', 'assistant']);
      expect(msgs.map((m) => m.content), <String>['第一问', '第一答']);
      // a 刚说过话 → 顶到最前。
      expect((await sessions.listAgentSessions()).first.id, a.id);

      await Future.delayed(const Duration(milliseconds: 1100));
      await sessions.addMessage(sessionId: b.id, role: 'user', content: '那边聊了');
      expect((await sessions.listAgentSessions()).first.id, b.id);
    });

    test('重命名：写 title 列并可读回（不改表结构）', () async {
      final s = await sessions.createAgentSession();
      await sessions.addMessage(sessionId: s.id, role: 'user', content: '导数是什么');

      // 未重命名：标题由首条 user 消息派生。
      var row = (await sessions.listAgentSessions()).single;
      var msgs = await sessions.listMessages(row.id);
      expect(deriveSessionTitle(storedTitle: row.title, messages: msgs), '导数是什么');

      await sessions.renameSession(s.id, '高数救急');
      row = (await sessions.listAgentSessions()).single;
      msgs = await sessions.listMessages(row.id);
      expect(row.title, '高数救急');
      // 重命名覆盖派生标题。
      expect(deriveSessionTitle(storedTitle: row.title, messages: msgs), '高数救急');
    });

    test('派生标题：无消息退「新对话」，超长截断', () async {
      final s = await sessions.createAgentSession();
      var row = (await sessions.listAgentSessions()).single;
      expect(deriveSessionTitle(storedTitle: row.title, messages: const []), '新对话');

      await sessions.addMessage(
          sessionId: s.id,
          role: 'user',
          content: '一二三四五六七八九十十一十二十三十四十五十六十七十八');
      row = (await sessions.listAgentSessions()).single;
      final msgs = await sessions.listMessages(row.id);
      final title = deriveSessionTitle(storedTitle: row.title, messages: msgs);
      expect(title.length, 25); // 24 字 + 省略号
      expect(title.endsWith('…'), isTrue);
    });

    test('清空会话：消息全软删（读不到），会话行保留', () async {
      final s = await sessions.createAgentSession();
      await sessions.addMessage(sessionId: s.id, role: 'user', content: '问1');
      await sessions.addMessage(sessionId: s.id, role: 'assistant', content: '答1');

      final cleared = await sessions.clearMessages(s.id);
      expect(cleared, 2);

      // 读路径：一条不剩（软删铁律）。
      expect(await sessions.listMessages(s.id), isEmpty);
      // 会话还在（清空 ≠ 删除）。
      expect((await sessions.listAgentSessions()).single.id, s.id);
      // 行留墓碑（deleted_at 非空），供同步传播。
      final rows = await db.select(db.aiMessages).get();
      expect(rows, hasLength(2));
      expect(rows.every((r) => r.deletedAt != null), isTrue);
    });

    test('删除会话：连同消息一起软删，列表不再有它', () async {
      final s = await sessions.createAgentSession();
      await sessions.addMessage(sessionId: s.id, role: 'user', content: '问');
      final other = await sessions.createAgentSession();

      await sessions.deleteSession(s.id);

      final list = await sessions.listAgentSessions();
      expect(list.map((e) => e.id), <String>[other.id]);
      expect(await sessions.listMessages(s.id), isEmpty);
      // 墓碑仍在库里（软删，不物理删）。
      final sessionRows = await db.select(db.aiSessions).get();
      expect(sessionRows.where((r) => r.id == s.id).single.deletedAt, isNotNull);
    });

    test('删除 / 清空后 resync：当前会话没了就回落到最新会话', () async {
      final a = await sessions.createAgentSession();
      await Future.delayed(const Duration(milliseconds: 5));
      final b = await sessions.createAgentSession();

      // 模拟页面行为：当前是 b，把 b 删掉 → 列表只剩 a。
      await sessions.deleteSession(b.id);
      final list = await sessions.listAgentSessions();
      expect(list.single.id, a.id);
    });
  });
}

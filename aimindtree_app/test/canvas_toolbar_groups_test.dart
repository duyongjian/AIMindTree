/// 知识树工具栏「4 个分组图标菜单」测试。
///
/// 背景：画布页顶部工具栏原来是一排 11 个平铺图标按钮，现按职责归组为
/// 4 个 PopupMenuButton（知识树 / 内容导入 / 布局视图 / AI 与作业）。
///
/// 本测试守住两条铁律：
/// 1. **动作不丢**：4 个分组按钮齐全，每组菜单项与原平铺图标一一对应；
/// 2. **禁用态保留**：`tree == null`（空库）时，除「新建知识树」外全部禁用。
///
/// 另验证画布右下角悬浮栏的「框选模式」开关图标翻转（crop_free ⇄ deselect），
/// 确认悬浮栏按钮的 handler 是真的接上了，而不是空壳。
library;

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ai/ai_provider.dart';
import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/auto_graph_service.dart';
import 'package:aimindtree_app/ai/extraction_service.dart';
import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/models/knowledge_tree.dart';
import 'package:aimindtree_app/data/repositories/group_repository.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/note_asset_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:aimindtree_app/features/canvas/canvas_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;
  late TreeRepository trees;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 'd');
    trees = TreeRepository(db, deviceId: 'd');
  });

  tearDown(() async {
    await db.close();
  });

  /// 造一个够用的 ExtractionService（画布页加载只用到 repo / trees）。
  ExtractionService makeService() => ExtractionService(
        repo: repo,
        trees: trees,
        groups: GroupRepository(db, deviceId: 'd'),
        jobs: AiJobService(baseUrl: 'http://127.0.0.1:8787'),
        ai: AiService(router: AiTaskRouter(providers: <String, AiProvider>{})),
        assets: NoteAssetRepository(db, deviceId: 'd'),
      );

  /// 整页 pump 画布页（生产环境挂在 Scaffold 下，测试保持一致）。
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CanvasPage(service: makeService(), db: db)),
    ));
    await tester.pumpAndSettle();
  }

  /// 造一棵树 + 一个成员知识点后 pump（_load 会自动选中第一棵树）。
  Future<void> pumpCanvasWithTree(WidgetTester tester) async {
    final treeRes = await trees.createTree('测试树');
    expect(treeRes, isA<Success<KnowledgeTree>>());
    final tree = (treeRes as Success<KnowledgeTree>).value;
    final kpRes = await repo.createManualKnowledgePoint(name: '成员点');
    expect(kpRes, isA<Success<KnowledgePoint>>());
    await trees.addPoints(
        tree.id, <String>[(kpRes as Success<KnowledgePoint>).value.id]);
    await pumpPage(tester);
  }

  /// 点开某个分组按钮，返回该组菜单项标签（按渲染顺序）。
  Future<List<String>> openGroup(WidgetTester tester, IconData icon) async {
    // 先关掉可能还开着的菜单（弹出菜单带全屏模态屏障，点角落即关闭）。
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(icon));
    await tester.pumpAndSettle();

    final labels = <String>[];
    for (final item in tester
        .widgetList<PopupMenuItem<int>>(find.byType(PopupMenuItem<int>))) {
      final row = item.child as Row;
      labels.add(row.children.whereType<Text>().first.data ?? '');
    }
    return labels;
  }

  /// 读某个菜单项的启用态（PopupMenuItem.enabled）。
  bool itemEnabled(WidgetTester tester, String label) {
    final item = tester.widget<PopupMenuItem<int>>(find.ancestor(
      of: find.text(label),
      matching: find.byType(PopupMenuItem<int>),
    ));
    return item.enabled;
  }

  group('工具栏渲染 4 个分组按钮', () {
    testWidgets('4 个分组图标各出现一次，且都是 PopupMenuButton', (tester) async {
      await pumpCanvasWithTree(tester);

      expect(find.byType(PopupMenuButton<int>), findsNWidgets(4));
      for (final icon in const <IconData>[
        Icons.account_tree, // ① 知识树
        Icons.playlist_add, // ② 内容导入
        Icons.dashboard_outlined, // ③ 布局视图
        Icons.auto_awesome, // ④ AI 与作业
      ]) {
        expect(find.byIcon(icon), findsOneWidget);
      }
    });

    testWidgets('原来平铺的一排图标按钮（及其 tooltip）已不在工具栏里', (tester) async {
      await pumpCanvasWithTree(tester);

      for (final tip in const <String>[
        '新建知识树',
        '重命名',
        '删除知识树',
        '把某篇笔记的知识点并入当前树',
        '把已有知识点加入当前树',
        '自动连线：推断知识点之间的前置关系',
        '作业模式：框选薄弱点布置作业',
        '框选重排：框选若干知识点后局部重排',
        '框选移动：框选若干知识点后拖动其中一个，整组一起移动',
        '补充选中知识点的前置（先点选一个节点）',
      ]) {
        expect(find.byTooltip(tip), findsNothing, reason: '旧平铺按钮应已移除：$tip');
      }
    });
  });

  group('分组菜单内容（选中一棵树）', () {
    testWidgets('① 知识树组：新建 / 重命名 / 删除，选中树后全部可用', (tester) async {
      await pumpCanvasWithTree(tester);

      final labels = await openGroup(tester, Icons.account_tree);
      expect(labels, <String>['新建知识树', '重命名', '删除知识树']);
      expect(itemEnabled(tester, '新建知识树'), isTrue);
      expect(itemEnabled(tester, '重命名'), isTrue);
      expect(itemEnabled(tester, '删除知识树'), isTrue);
    });

    testWidgets('② 内容导入组：从笔记并入 / 加入已有 / 移除（含框选移除）',
        (tester) async {
      await pumpCanvasWithTree(tester);

      final labels = await openGroup(tester, Icons.playlist_add);
      expect(labels, <String>[
        '从笔记并入知识点',
        '加入已有知识点',
        '从知识树移除知识点',
        '移除框选的知识点',
      ]);
      expect(itemEnabled(tester, '从笔记并入知识点'), isTrue);
      expect(itemEnabled(tester, '加入已有知识点'), isTrue);
      // 树里有「成员点」→ 移除可用；未开框选模式 → 框选移除禁用。
      expect(itemEnabled(tester, '从知识树移除知识点'), isTrue);
      expect(itemEnabled(tester, '移除框选的知识点'), isFalse);
    });

    testWidgets('③ 布局与连线组：重新布局 / 局部重排 / 自动连线 / 局部连线',
        (tester) async {
      await pumpCanvasWithTree(tester);

      final labels = await openGroup(tester, Icons.dashboard_outlined);
      expect(labels, <String>[
        '重新布局',
        '局部重排',
        '自动连线',
        '局部连线',
      ]);
      // 防回归：旧的「自动布局」label 不应再出现（已改名「自动连线」）。
      expect(labels, isNot(contains('自动布局')));
      // 防回归：「框选模式」开关已移到画布右下角悬浮栏，菜单里不应再有它。
      expect(labels, isNot(contains('框选模式')));
      expect(itemEnabled(tester, '重新布局'), isTrue);
      expect(itemEnabled(tester, '自动连线'), isTrue);
      // 未开框选模式时「局部重排」禁用（需框选模式 + 至少 1 个选中点）。
      expect(itemEnabled(tester, '局部重排'), isFalse);
      // 少于 2 个框选知识点时「局部连线」禁用（需至少 2 个点才连得起来）。
      expect(itemEnabled(tester, '局部连线'), isFalse);
    });

    testWidgets('④ AI 与作业组：批量补前置 / 布置作业 / 作业历史 / 作业模式',
        (tester) async {
      await pumpCanvasWithTree(tester);

      final labels = await openGroup(tester, Icons.auto_awesome);
      expect(labels, <String>['批量补前置', '布置作业', '作业历史', '作业模式']);
      // 防回归：旧的「补前置」label 不应再出现（已改名「批量补前置」）。
      expect(labels, isNot(contains('补前置')));
      // 无框选、无单点选中 → 批量补前置 禁用。
      expect(itemEnabled(tester, '批量补前置'), isFalse);
      expect(itemEnabled(tester, '作业历史'), isTrue);
      expect(itemEnabled(tester, '作业模式'), isTrue);
      // 未框选薄弱点时「布置作业」禁用（与作业模式条内按钮一致）。
      expect(itemEnabled(tester, '布置作业'), isFalse);
    });

    testWidgets('点悬浮栏「框选模式」真的触发既有 handler：可开可关', (tester) async {
      await pumpCanvasWithTree(tester);

      // 初始：画布右下角悬浮栏（_ZoomControls）显示 crop_free（未开框选模式）。
      expect(find.byIcon(Icons.crop_free), findsOneWidget);

      // 点它 → _toggleFrameMode 生效：图标翻成 deselect（crop_free 消失）。
      await tester.tap(find.byIcon(Icons.crop_free));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.deselect), findsOneWidget);
      expect(find.byIcon(Icons.crop_free), findsNothing);

      // 开启时的 toast 是一条 2s SnackBar，盖在屏幕底部会挡住悬浮栏按钮：
      // 推虚拟时间越过其时长并等退场动画结束，确认它消失后再点退出。
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);

      // 再点一次退出，图标翻回来。
      await tester.tap(find.byIcon(Icons.deselect));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.crop_free), findsOneWidget);
      expect(find.byIcon(Icons.deselect), findsNothing);
    });
  });

  group('禁用态保留（tree == null，空库）', () {
    testWidgets('① 组只有「新建知识树」可用，重命名 / 删除禁用', (tester) async {
      await pumpPage(tester); // 空库：没有任何知识树。

      final labels = await openGroup(tester, Icons.account_tree);
      expect(labels, <String>['新建知识树', '重命名', '删除知识树']);
      expect(itemEnabled(tester, '新建知识树'), isTrue);
      expect(itemEnabled(tester, '重命名'), isFalse);
      expect(itemEnabled(tester, '删除知识树'), isFalse);
    });

    testWidgets('② ③ ④ 组所有依赖树的动作全部禁用', (tester) async {
      await pumpPage(tester); // 空库：没有任何知识树。

      var labels = await openGroup(tester, Icons.playlist_add);
      expect(labels, <String>[
        '从笔记并入知识点',
        '加入已有知识点',
        '从知识树移除知识点',
        '移除框选的知识点',
      ]);
      expect(itemEnabled(tester, '从笔记并入知识点'), isFalse);
      expect(itemEnabled(tester, '加入已有知识点'), isFalse);
      // 空库：移除类动作同样依赖树，全部禁用。
      expect(itemEnabled(tester, '从知识树移除知识点'), isFalse);
      expect(itemEnabled(tester, '移除框选的知识点'), isFalse);

      labels = await openGroup(tester, Icons.dashboard_outlined);
      expect(labels, <String>[
        '重新布局',
        '局部重排',
        '自动连线',
        '局部连线',
      ]);
      for (final l in const <String>[
        '重新布局',
        '局部重排',
        '自动连线',
        '局部连线',
      ]) {
        expect(itemEnabled(tester, l), isFalse, reason: '无树时应禁用：$l');
      }

      labels = await openGroup(tester, Icons.auto_awesome);
      expect(labels, <String>['批量补前置', '布置作业', '作业历史', '作业模式']);
      for (final l in const <String>[
        '批量补前置',
        '布置作业',
        '作业历史',
        '作业模式',
      ]) {
        expect(itemEnabled(tester, l), isFalse, reason: '无树时应禁用：$l');
      }
    });
  });

  group('菜单改名防回归（需求①②③④）', () {
    testWidgets('③ 含 重新布局/自动连线/局部连线，不含 框选模式/自动布局', (tester) async {
      await pumpCanvasWithTree(tester);
      final labels = await openGroup(tester, Icons.dashboard_outlined);
      expect(labels, contains('重新布局'));
      expect(labels, contains('自动连线'));
      expect(labels, contains('局部连线'));
      expect(labels, isNot(contains('框选模式')));
      expect(labels, isNot(contains('自动布局')));
    });

    testWidgets('④ 含 批量补前置，不含 补前置', (tester) async {
      await pumpCanvasWithTree(tester);
      final labels = await openGroup(tester, Icons.auto_awesome);
      expect(labels, contains('批量补前置'));
      expect(labels, isNot(contains('补前置')));
    });
  });

  group('T3 局部连线：linkFromParsed 的 restrictToIds 过滤', () {
    test('restrictToIds 只保留两端都在集合内的边', () async {
      final treeRes = await trees.createTree('连线树');
      final tree = (treeRes as Success<KnowledgeTree>).value;
      final a = (await repo.createManualKnowledgePoint(name: 'A'))
          as Success<KnowledgePoint>;
      final b = (await repo.createManualKnowledgePoint(name: 'B'))
          as Success<KnowledgePoint>;
      final c = (await repo.createManualKnowledgePoint(name: 'C'))
          as Success<KnowledgePoint>;
      await trees.addPoints(tree.id, [a.value.id, b.value.id, c.value.id]);

      final auto = AutoGraphService(
        ai: AiService(router: AiTaskRouter(providers: <String, AiProvider>{})),
        repo: repo,
        trees: trees,
      );
      final parsed = <String, dynamic>{
        'prerequisites': [
          {
            'from': a.value.id,
            'to': b.value.id,
          }, // 两端都在集合内 → 保留
          {
            'from': a.value.id,
            'to': c.value.id,
          }, // 一端(c)不在集合 → 过滤掉
          {
            'from': 'x-out',
            'to': 'y-out',
          }, // 两端都不在树/集合 → 解析阶段跳过
        ]
      };
      final res = await auto.linkFromParsed(
        tree.id,
        parsed,
        restrictToIds: {a.value.id, b.value.id},
      );
      expect(res, isA<Success<AutoLinkResult>>());
      expect((res as Success<AutoLinkResult>).value.created, 1);
    });
  });
}

/// 知识树（画布）界面「就地编辑知识点」测试。
///
/// 诉求原话：「知识树界面也应该允许有途径对选中的知识点进行编辑，方便多了。」
/// 实现口径：单点操作浮层（[_showNodeActions] 对应的 bottom sheet）新增第一项
/// 「编辑知识点」→ 弹 [_showEditKpDialog] 改名称 / 类型 / 定义 → 复用
/// [KnowledgeRepository.updateKpMeta] 落库。
///
/// 本测试守住四条铁律：
/// 1. **入口唯一且不丢老动作**：浮层第一项是「编辑知识点」，原有四项（讲解 /
///    掌握度 / 连接前置 / 补前置）仍全在；
/// 2. **改到点子上**：名称 / 类型 / 定义三个展示性字段真的落库（含 version+1）；
/// 3. **不伤结构**：锚点四件套、树成员关系、画布节点坐标全部原样不变；
/// 4. **体验细节**：名称为空就地 toast 且不关窗；保存后该节点仍保持选中高亮。
library;

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ai/ai_provider.dart';
import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/extraction_service.dart';
import 'package:aimindtree_app/canvas/render/knowledge_node_card.dart';
import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/models/knowledge_tree.dart';
import 'package:aimindtree_app/data/repositories/group_repository.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/note_asset_repository.dart';
import 'package:aimindtree_app/data/repositories/notebook_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:aimindtree_app/features/canvas/canvas_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;
  late TreeRepository trees;

  /// [pumpCanvasWithPoint] 造的树的 id（「成员关系 / 坐标不变」用例要用）。
  late String createdTreeId;

  /// 测试用的初始坐标：绝对值写死，避免断言依赖布局引擎的默认铺位。
  const double kX = 120.0;
  const double kY = 240.0;

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
        notebooks: NotebookRepository(repo.db, deviceId: 't'),
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

  /// 造一棵树 + 一个成员知识点（带定义与固定坐标）后 pump 画布，返回 kpId。
  ///
  /// 树的 id 记在 [createdTreeId]（多数用例只关心知识点，但「成员关系 / 坐标
  /// 不变」那条要按树查成员行）。
  ///
  /// 先在库里写好 `canvas_nodes` 位置，是为了让「保存后坐标未变」这条断言有意义
  /// （没有落库位置时画布会走 `_autoFitOnce`，坐标断言就成了空测）。
  Future<String> pumpCanvasWithPoint(WidgetTester tester) async {
    final treeRes = await trees.createTree('测试树');
    expect(treeRes, isA<Success<KnowledgeTree>>());
    final tree = (treeRes as Success<KnowledgeTree>).value;

    final kpRes = await repo.createManualKnowledgePoint(
      name: '成员点',
      definition: '旧定义',
    );
    expect(kpRes, isA<Success<KnowledgePoint>>());
    final kp = (kpRes as Success<KnowledgePoint>).value;

    await trees.addPoints(tree.id, <String>[kp.id]);
    await repo.saveNodePosition(tree.id, kp.id, kX, kY);

    await pumpPage(tester);
    createdTreeId = tree.id;
    return kp.id;
  }

  /// 点卡片主体 → 弹出单点操作浮层。
  Future<void> tapCard(WidgetTester tester, String name) async {
    // 卡片标题文本在 InkWell 内，点它即命中卡片主体的 onTap。
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
  }

  /// 浮层里点「编辑知识点」→ 弹出编辑对话框。
  Future<void> openEditDialog(WidgetTester tester, String name) async {
    await tapCard(tester, name);
    await tester.tap(find.text('编辑知识点'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: '点「编辑知识点」应弹出编辑对话框');
  }

  /// 读库里该知识点的当前快照（不存在返回 null）。
  Future<KnowledgePoint?> readKp(String kpId) async {
    final list = await repo.pointsByIds(<String>[kpId]);
    return list.isEmpty ? null : list.first;
  }

  group('单点操作浮层入口', () {
    testWidgets('浮层第一项是「编辑知识点」，原有四项动作一个不少', (tester) async {
      await pumpCanvasWithPoint(tester);
      await tapCard(tester, '成员点');

      final titles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title! as Text).data)
          .toList();
      expect(titles.first, '编辑知识点',
          reason: '用户诉求的核心入口要放在浮层最上面，一眼就能看到');
      expect(
        titles,
        containsAll(<String>[
          '编辑知识点',
          'AI 讲解 / 追问',
          '标记为已掌握',
          '连接前置',
          '补充前置知识',
        ]),
        reason: '新增入口不能顶掉任何一个老动作',
      );
    });
  });

  group('保存后落库', () {
    testWidgets('改名称 / 类型 / 定义 → 三项都落库且 version+1', (tester) async {
      final kpId = await pumpCanvasWithPoint(tester);
      expect((await readKp(kpId))!.version, 1, reason: '新建时 version 应为 1');

      await openEditDialog(tester, '成员点');

      // 名称：清空后重填。
      await tester.enterText(find.byType(TextField).at(0), '改名后的点');
      // 类型：概念 → 方法。
      await tester.tap(find.byType(DropdownButtonFormField<KnowledgePointType>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('方法').last);
      await tester.pumpAndSettle();
      // 定义：第二颗 TextField。
      await tester.enterText(find.byType(TextField).at(1), '新定义内容');

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing, reason: '保存成功后应关窗');

      final after = await readKp(kpId);
      expect(after, isNotNull);
      expect(after!.name, '改名后的点');
      expect(after.type, KnowledgePointType.method);
      expect(after.definition, '新定义内容');
      expect(after.version, 2, reason: 'updateKpMeta 自带 version+1（同步 LWW 靠它）');
    });

    testWidgets('锚点四件套 / origin 不被编辑破坏', (tester) async {
      final kpId = await pumpCanvasWithPoint(tester);
      final before = await readKp(kpId);
      expect(before, isNotNull);

      await openEditDialog(tester, '成员点');
      await tester.enterText(find.byType(TextField).at(0), '锚点不变');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final after = await readKp(kpId);
      expect(after, isNotNull);
      expect(after!.name, '锚点不变');
      expect(after.sourceNoteId, before!.sourceNoteId,
          reason: '来源笔记是锚点的一部分，编辑展示字段不能改它');
      expect(after.sourceStart, before.sourceStart);
      expect(after.sourceEnd, before.sourceEnd);
      expect(after.sourceQuote, before.sourceQuote);
      expect(after.origin, before.origin);
      expect(after.confidence, before.confidence);
    });

    testWidgets('树成员关系与画布节点坐标都不动', (tester) async {
      final kpId = await pumpCanvasWithPoint(tester);
      final membersBefore = await trees.memberPointIds(createdTreeId);
      expect(membersBefore, <String>[kpId]);

      await openEditDialog(tester, '成员点');
      await tester.enterText(find.byType(TextField).at(0), '改完还在树里');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final membersAfter = await trees.memberPointIds(createdTreeId);
      expect(membersAfter, <String>[kpId],
          reason: '编辑只写 knowledge_points，不应该增删 canvas_nodes 成员行');

      final pos = await repo.loadNodePositions(createdTreeId);
      expect(pos.containsKey(kpId), isTrue, reason: '节点位置记录不能丢');
      expect(pos[kpId]!.x, kX, reason: '编辑名称不能让节点在画布上跳位置');
      expect(pos[kpId]!.y, kY);
    });

    testWidgets('画布卡片立刻显示新名称，且该节点保持选中高亮', (tester) async {
      await pumpCanvasWithPoint(tester);

      await openEditDialog(tester, '成员点');
      await tester.enterText(find.byType(TextField).at(0), '画布新名字');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('成员点'), findsNothing, reason: '旧名字应该从画布上消失');
      expect(find.text('画布新名字'), findsWidgets,
          reason: '刷新后画布应渲染新名字');

      // _loadForTree 首行会清空选中态，实现里按 id 找回了新实例；
      // 若丢了这一步，卡片会自己「掉选」，用户还得再点一次。
      expect(
        find.byWidgetPredicate(
          (w) => w is KnowledgeNodeCard && w.isSelected,
        ),
        findsOneWidget,
        reason: '保存后刚编辑过的节点应仍是选中态',
      );
    });
  });

  group('边界与取消', () {
    testWidgets('名称为空 → 就地 toast 且不关窗，库不变', (tester) async {
      final kpId = await pumpCanvasWithPoint(tester);

      await openEditDialog(tester, '成员点');
      await tester.enterText(find.byType(TextField).at(0), '   ');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('名称不能为空'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget,
          reason: '名称为空应就地提示，不能把用户刚填的内容一起关掉');
      expect((await readKp(kpId))!.name, '成员点', reason: '库不应被改成空名');
    });

    testWidgets('取消 → 库不变', (tester) async {
      final kpId = await pumpCanvasWithPoint(tester);

      await openEditDialog(tester, '成员点');
      await tester.enterText(find.byType(TextField).at(0), '不该被保存');
      await tester.enterText(find.byType(TextField).at(1), '不该被保存的定义');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      final after = await readKp(kpId);
      expect(after!.name, '成员点');
      expect(after.definition, '旧定义');
      expect(after.version, 1, reason: '取消不应产生版本号噪音');
    });

    testWidgets('对话框预填当前值（名称 / 定义），原样保存也能走完', (tester) async {
      final kpId = await pumpCanvasWithPoint(tester);

      await openEditDialog(tester, '成员点');

      final nameField = tester.widget<TextField>(find.byType(TextField).at(0));
      final defField = tester.widget<TextField>(find.byType(TextField).at(1));
      expect(nameField.controller!.text, '成员点', reason: '编辑框应预填当前名称');
      expect(defField.controller!.text, '旧定义', reason: '编辑框应预填当前定义');

      // 原样保存：内容不变也应能正常走完（幂等更新，version 照常 +1）。
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final after = await readKp(kpId);
      expect(after!.name, '成员点');
      expect(after.definition, '旧定义');
    });
  });
}

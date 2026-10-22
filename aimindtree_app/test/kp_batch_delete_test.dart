/// 知识点批量删除测试（P1-1 多选批删 + 任务 E 笔记批量删除入口）。
///
/// 覆盖：
/// 1. **仓储层数据面**：多选批删 = 对每个选中 KP 调
///    [KnowledgeRepository.softDeleteKnowledgePoint]（墓碑）→ 全部进回收站，
///    `allKnowledgePoints()` 不含（软删铁律）。
/// 2. **管理页交互**：AppBar 多选入口 / 长按入口 / 全选 /「删除(N)」确认弹窗
///    （说明移入回收站可恢复 + 前置边影响面）→ 批删 → toast 回执；
///    取消不删；原单条菜单删除保持不变。
/// 3. **笔记列表入口**（任务 E）：AppBar `Icons.checklist` 图标进入多选态，
///    删除语义不变。
library;

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ai/ai_provider.dart';
import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/extraction_service.dart';
import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/group_repository.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:aimindtree_app/features/knowledge/knowledge_manage_page.dart';
import 'package:aimindtree_app/main.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 'd');
  });

  tearDown(() async => db.close());

  /// 建一个知识点（手动入口：锚点豁免，最省事）。
  Future<KnowledgePoint> makeKp(String name) async {
    final res = await repo.createManualKnowledgePoint(name: name);
    return (res as Success<KnowledgePoint>).value;
  }

  /// 造一个够用的 ExtractionService（管理页只用到 repo / trees）。
  ExtractionService makeService() => ExtractionService(
        repo: repo,
        trees: TreeRepository(db, deviceId: 'd'),
        groups: GroupRepository(db, deviceId: 'd'),
        jobs: AiJobService(baseUrl: 'http://127.0.0.1:8787'),
        ai: AiService(router: AiTaskRouter(providers: <String, AiProvider>{})),
      );

  group('仓储层：多选批软删的数据面', () {
    test('N 个选中 → 全部进回收站，allKnowledgePoints() 不含', () async {
      final kps = <KnowledgePoint>[
        await makeKp('批删点A'),
        await makeKp('批删点B'),
        await makeKp('批删点C'),
      ];
      expect(await repo.allKnowledgePoints(), hasLength(3));

      // 页面 _confirmBatchDelete 的执行方式：对每个选中 KP 逐个软删。
      var deleted = 0;
      for (final kp in kps) {
        final res = await repo.softDeleteKnowledgePoint(kp.id);
        expect(res, isA<Success<int>>());
        deleted += (res as Success<int>).value;
      }
      expect(deleted, 3);

      // 常规列表全消失（软删铁律）。
      final all = await repo.allKnowledgePoints();
      expect(all, isEmpty);
      expect(all.map((k) => k.id), isNot(contains(kps.first.id)));

      // 回收站里全部在（可恢复）。
      final bin = await repo.deletedKnowledgePoints();
      expect(bin, hasLength(3));
      expect(
        bin.map((k) => k.id),
        unorderedEquals(<String>[for (final k in kps) k.id]),
      );
      for (final k in bin) {
        expect(k.deletedAt, isNotNull);
      }
    });

    test('批删影响面：前置边按选中 KP 汇总（确认弹窗数据源）', () async {
      final a = await makeKp('边A');
      final b = await makeKp('边B');
      final c = await makeKp('边C');
      await repo.addManualPrerequisiteEdge(a.id, b.id);

      // 页面 _confirmBatchDelete 的汇总逻辑。
      var edgeCount = 0;
      for (final id in <String>[a.id, b.id, c.id]) {
        edgeCount += await repo.countPrerequisiteEdges(id);
      }
      // a→b：a（出边）与 b（入边）各数一次，c 无关。
      expect(edgeCount, 2);

      // 批删后边被级联清掉（软删 KP 时硬删从属行）。
      await repo.softDeleteKnowledgePoint(a.id);
      await repo.softDeleteKnowledgePoint(b.id);
      expect(await repo.countPrerequisiteEdges(c.id), 0);
      final edges = await repo.prerequisiteEdgesAmong(<String>[a.id, b.id, c.id]);
      expect(edges, isEmpty);
    });
  });

  group('知识点管理页：多选批量删除', () {
    /// 挂起管理页（真实仓储，验证「页 → 仓储 → 库」整条链）。
    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: KnowledgeManagePage(service: makeService(), db: db),
      ));
      await tester.pumpAndSettle();
    }

    /// 建知识点并强制写入指定 updatedAt（制造可控的排序顺序）。
    Future<String> makeKpAt(String name, DateTime updatedAt) async {
      final kp = await makeKp(name);
      await (db.update(db.knowledgePoints)..where((t) => t.id.equals(kp.id)))
          .write(KnowledgePointsCompanion(updatedAt: Value(updatedAt)));
      return kp.id;
    }

    /// 读取当前列表可见条目的名称顺序（按展示自上而下）。
    List<String> _visibleNames(WidgetTester tester) {
      final tiles = tester.widgetList<ListTile>(find.byType(ListTile));
      return tiles.map((t) {
        final title = t.title;
        return title is Text ? (title.data ?? '') : '';
      }).toList();
    }

    testWidgets('更新时间排序：默认降序，可切换升序', (tester) async {
      await makeKpAt('旧点', DateTime.utc(2024, 1, 1));
      await makeKpAt('中点', DateTime.utc(2024, 3, 15));
      await makeKpAt('新点', DateTime.utc(2024, 6, 30));
      await pumpPage(tester);

      // 默认降序：最近改动在上。
      expect(_visibleNames(tester), <String>['新点', '中点', '旧点']);

      // 点排序图标 → 切换为升序。
      await tester.tap(find.byTooltip('更新时间降序（最近改动在上）'));
      await tester.pumpAndSettle();
      expect(_visibleNames(tester), <String>['旧点', '中点', '新点']);

      // 再点 → 切回降序。
      await tester.tap(find.byTooltip('更新时间升序（最早改动在上）'));
      await tester.pumpAndSettle();
      expect(_visibleNames(tester), <String>['新点', '中点', '旧点']);
    });

    testWidgets('AppBar 有多选入口图标，点击进入多选态', (tester) async {
      await makeKp('入口点');
      await pumpPage(tester);

      // 常规态：标题「知识点」，有多选入口图标。
      expect(find.text('知识点'), findsOneWidget);
      expect(find.byIcon(Icons.checklist), findsOneWidget);

      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();

      // 多选态：标题显示已选数量、出现关闭按钮，每条出现 Checkbox。
      expect(find.text('已选 0 个'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byType(Checkbox), findsOneWidget);
      // 多选态下没有「新建 / 回收站 / 刷新」图标（被多选动作替换）。
      expect(find.byIcon(Icons.add), findsNothing);
    });

    testWidgets('长按条目进入多选并预选该条', (tester) async {
      await makeKp('长按点');
      await makeKp('另一条');
      await pumpPage(tester);

      await tester.longPress(find.text('长按点'));
      await tester.pumpAndSettle();

      expect(find.text('已选 1 个'), findsOneWidget);
      // 预选的那条 Checkbox 为选中态。
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox).first);
      expect(checkbox.value, isTrue);
    });

    testWidgets('全选 →「删除(N)」确认弹窗 → 全部移入回收站', (tester) async {
      final a = await makeKp('全选删A');
      final b = await makeKp('全选删B');
      final c = await makeKp('全选删C');
      // 造一条前置边，验证弹窗里的影响面汇总。
      await repo.addManualPrerequisiteEdge(a.id, b.id);
      await pumpPage(tester);

      // 图标进入多选 → 全选。
      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.select_all));
      await tester.pumpAndSettle();
      expect(find.text('已选 3 个'), findsOneWidget);

      // 点「删除(3)」→ 确认弹窗。
      await tester.tap(find.text('删除(3)'));
      await tester.pumpAndSettle();
      expect(find.text('批量删除知识点'), findsOneWidget);
      expect(find.textContaining('确定删除选中的 3 个知识点'), findsOneWidget);
      expect(find.textContaining('涉及 2 条前置关系'), findsOneWidget);
      expect(find.textContaining('移入回收站，可恢复'), findsOneWidget);

      // 确认 → 批删执行。
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '移入回收站'),
      ));
      await tester.pumpAndSettle();

      // toast 回执 + 退出多选 + 列表刷新为空态。
      expect(find.text('已将 3 个知识点移入回收站'), findsOneWidget);
      expect(find.textContaining('还没有知识点'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);

      // 数据面：全进回收站，常规列表为空。
      expect(await repo.allKnowledgePoints(), isEmpty);
      final bin = await repo.deletedKnowledgePoints();
      expect(bin, hasLength(3));
      expect(
        bin.map((k) => k.id),
        unorderedEquals(<String>[a.id, b.id, c.id]),
      );
    });

    testWidgets('确认弹窗点「取消」→ 一个都不删', (tester) async {
      await makeKp('取消点A');
      await makeKp('取消点B');
      await pumpPage(tester);

      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 个'), findsOneWidget);

      await tester.tap(find.text('删除(1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '取消'),
      ));
      await tester.pumpAndSettle();

      // 一条都没删，且仍在多选态。
      expect(await repo.allKnowledgePoints(), hasLength(2));
      expect(await repo.deletedKnowledgePoints(), isEmpty);
      expect(find.text('已选 1 个'), findsOneWidget);
    });

    testWidgets('原单条菜单删除保持不变（软删进回收站）', (tester) async {
      final keep = await makeKp('保留点');
      final gone = await makeKp('菜单删的点');
      await pumpPage(tester);

      // 条目菜单 → 删除 → 确认。
      // 列表按更新时间倒序，不能假设条目位置：按文本定位到「菜单删的点」
      // 所在 ListTile，再点它自己的菜单按钮。
      final tile = find.ancestor(
        of: find.text('菜单删的点'),
        matching: find.byType(ListTile),
      );
      await tester.tap(find.descendant(
        of: tile,
        matching: find.byTooltip('更多'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除知识点'), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '删除'),
      ));
      await tester.pumpAndSettle();

      // 只剩保留点；删掉的进回收站。
      final all = await repo.allKnowledgePoints();
      expect(all.map((k) => k.id), <String>[keep.id]);
      final bin = await repo.deletedKnowledgePoints();
      expect(bin.map((k) => k.id), <String>[gone.id]);
    });
  });

  group('笔记列表：批量删除入口（任务 E）', () {
    testWidgets('AppBar checklist 图标进入多选态，可勾选 / 退出', (tester) async {
      await repo.saveNote(Note(title: '笔记一', contentMd: '内容一'));
      await repo.saveNote(Note(title: '笔记二', contentMd: '内容二'));

      await tester.pumpWidget(MaterialApp(
        home: NotesListPage(service: makeService(), db: db),
      ));
      await tester.pumpAndSettle();

      // 常规态：标题「笔记」，有批量删除入口图标（原只能长按进入）。
      expect(find.text('笔记'), findsOneWidget);
      expect(find.byIcon(Icons.checklist), findsOneWidget);

      // 点图标 → 进入多选态（不预选）。
      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 篇'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);

      // 点条目 → 勾选。
      await tester.tap(find.text('笔记一'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 篇'), findsOneWidget);

      // 关闭 → 回到常规态（删除语义未动，只是入口可发现）。
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 篇'), findsNothing);
      expect(find.text('笔记'), findsOneWidget);
      expect(find.byIcon(Icons.checklist), findsOneWidget);

      // 笔记一篇都没少。
      final notes = await repo.listNotes();
      expect(notes, hasLength(2));
    });
  });
}

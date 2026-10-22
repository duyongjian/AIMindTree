/// 知识点分组 / 置顶 / 排序字段测试（T03）。
///
/// 覆盖四层：
/// 1. **仓储层**：`setPinned` 置顶只 bump version、**刻意不 bump updated_at**；
///    幂等（同值不写、不入队）；墓碑行拒绝置顶；同步 outbox 接线。
/// 2. **管理页交互**：条目菜单「置顶」→ 旧点跳到最前 + push_pin 角标；
///    排序字段下拉切「创建时间」后按 createdAt 排。
/// 3. **分组筛选与批量归组**：批量归组后 chips 筛选只显示该组成员，
///    「未分组」chips 过滤互补（组 = 编排容器，不产新知识点）。
/// 4. **分组管理面板**：新建 / 重命名 / 删除（删组不解散成员——组内知识点
///    回到「未分组」）。
library;

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ai/ai_provider.dart';
import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/extraction_service.dart';
import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/models/kp_group.dart';
import 'package:aimindtree_app/data/repositories/group_repository.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:aimindtree_app/data/sync/sync_outbox.dart';
import 'package:aimindtree_app/data/sync/sync_types.dart';
import 'package:aimindtree_app/features/knowledge/knowledge_manage_page.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;
  late GroupRepository groups;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 'd');
    groups = GroupRepository(db, deviceId: 'd');
  });

  tearDown(() async {
    // 全局接线点必须复位，否则会漏到别的测试文件里。
    SyncOutboxRepo.current = null;
    await db.close();
  });

  Future<KnowledgePoint> makeKp(String name) async {
    final res = await repo.createManualKnowledgePoint(name: name);
    return (res as Success<KnowledgePoint>).value;
  }

  /// 建知识点并强制写入指定 updatedAt（制造可控的排序顺序）。
  Future<KnowledgePoint> makeKpAt(String name, DateTime updatedAt) async {
    final kp = await makeKp(name);
    await (db.update(db.knowledgePoints)..where((t) => t.id.equals(kp.id)))
        .write(KnowledgePointsCompanion(updatedAt: Value(updatedAt)));
    return kp;
  }

  /// 造一个够用的 ExtractionService（管理页只用到 repo / trees / groups）。
  ExtractionService makeService() => ExtractionService(
        repo: repo,
        trees: TreeRepository(db, deviceId: 'd'),
        groups: groups,
        jobs: AiJobService(baseUrl: 'http://127.0.0.1:8787'),
        ai: AiService(router: AiTaskRouter(providers: <String, AiProvider>{})),
      );

  group('仓储层：setPinned', () {
    test('置顶：pinned 落库 + version+1，但 updated_at 不变（刻意）', () async {
      final kp = await makeKp('置顶点');
      final before = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(kp.id)))
          .getSingle();
      final updatedAtBefore = before.updatedAt;

      final res = await repo.setPinned(kp.id, true);
      expect(res, isA<Success<void>>());

      final after = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(kp.id)))
          .getSingle();
      expect(after.pinned, isTrue);
      expect(after.version, before.version + 1);
      // 铁律：置顶不是内容变更，不得 bump updated_at。
      expect(
        after.updatedAt.millisecondsSinceEpoch,
        updatedAtBefore.millisecondsSinceEpoch,
      );

      // 读回领域对象同步反映。
      final list = await repo.allKnowledgePoints();
      expect(list.firstWhere((k) => k.id == kp.id).pinned, isTrue);
    });

    test('幂等：同值再调不写库、不 bump version', () async {
      final kp = await makeKp('幂等点');
      await repo.setPinned(kp.id, true);
      final after1 = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(kp.id)))
          .getSingle();

      final res = await repo.setPinned(kp.id, true);
      expect(res, isA<Success<void>>());

      final after2 = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(kp.id)))
          .getSingle();
      expect(after2.version, after1.version);
    });

    test('已软删的知识点拒绝置顶（墓碑行不响应 UI 操作）', () async {
      final kp = await makeKp('墓碑点');
      await repo.softDeleteKnowledgePoint(kp.id);
      final res = await repo.setPinned(kp.id, true);
      expect(res, isA<Failure<void>>());
    });

    test('同步接线：置顶后 outbox 有 knowledge_points upsert（payload 带 pinned）',
        () async {
      // 先建点（未接线，不入队），再接线 → pending 只剩置顶这一条。
      final kp = await makeKp('同步置顶点');
      final outbox = SyncOutboxRepo(db, deviceId: 'd');
      SyncOutboxRepo.current = outbox;

      await repo.setPinned(kp.id, true);

      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      final row = pending.single;
      expect(row.entityTable, 'knowledge_points');
      expect(row.entityId, kp.id);
      expect(row.op, SyncOp.upsert.name);
      // payload 的 pinned 必须是 true（同步层原样搬运，不解析语义）。
      expect(row.payloadJson, contains('"pinned":true'));
    });
  });

  group('管理页：置顶与排序字段', () {
    /// 挂起管理页（真实仓储，验证「页 → 仓储 → 库」整条链）。
    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: KnowledgeManagePage(service: makeService(), db: db),
      ));
      await tester.pumpAndSettle();
    }

    /// 当前列表可见条目的名称顺序（按展示自上而下）。
    List<String> visibleNames(WidgetTester tester) {
      final tiles = tester.widgetList<ListTile>(find.byType(ListTile));
      return tiles.map((t) {
        final title = t.title;
        return title is Text ? (title.data ?? '') : '';
      }).toList();
    }

    /// 打开某条目（按名称）的更多菜单。
    Future<void> openItemMenu(WidgetTester tester, String name) async {
      final tile = find.widgetWithText(ListTile, name);
      await tester.tap(find.descendant(
        of: tile,
        matching: find.byType(PopupMenuButton<String>),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('菜单「置顶」→ 旧点跳到最前（即使它更旧）+ push_pin 角标',
        (tester) async {
      await makeKpAt('旧点', DateTime.utc(2024, 1, 1));
      await makeKpAt('新点', DateTime.utc(2024, 6, 1));
      await pumpPage(tester);

      // 默认：最近改动在上。
      expect(visibleNames(tester), <String>['新点', '旧点']);

      await openItemMenu(tester, '旧点');
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();

      // 置顶恒在最前，与更新时间无关。
      expect(visibleNames(tester), <String>['旧点', '新点']);
      expect(find.byIcon(Icons.push_pin), findsOneWidget);

      // 数据面：置顶已落库。
      final list = await repo.allKnowledgePoints();
      expect(list.firstWhere((k) => k.name == '旧点').pinned, isTrue);

      // 取消置顶 → 回到时间序。
      await openItemMenu(tester, '旧点');
      await tester.tap(find.text('取消置顶'));
      await tester.pumpAndSettle();
      expect(visibleNames(tester), <String>['新点', '旧点']);
      expect(find.byIcon(Icons.push_pin), findsNothing);
    });

    testWidgets('排序字段下拉：切「创建时间」后按 createdAt 排', (tester) async {
      // 建得早但改得晚 vs 建得晚但改得早——两个字段顺序相反。
      final early = await makeKpAt('建早改晚', DateTime.utc(2024, 6, 1));
      await (db.update(db.knowledgePoints)..where((t) => t.id.equals(early.id)))
          .write(KnowledgePointsCompanion(
              createdAt: Value(DateTime.utc(2024, 1, 1))));
      final late = await makeKpAt('建晚改早', DateTime.utc(2024, 1, 1));
      await (db.update(db.knowledgePoints)..where((t) => t.id.equals(late.id)))
          .write(KnowledgePointsCompanion(
              createdAt: Value(DateTime.utc(2024, 6, 1))));
      await pumpPage(tester);

      // 默认按更新时间降序：改得晚的在上。
      expect(visibleNames(tester), <String>['建早改晚', '建晚改早']);

      // 切到创建时间（下拉第一项即当前值，直接点菜单里的「创建时间」）。
      await tester.tap(find.text('更新时间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建时间').last);
      await tester.pumpAndSettle();

      // 创建时间降序：建得晚的在上（与更新时间序相反，证明字段生效）。
      expect(visibleNames(tester), <String>['建晚改早', '建早改晚']);
    });
  });

  group('管理页：分组筛选与批量归组', () {
    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: KnowledgeManagePage(service: makeService(), db: db),
      ));
      await tester.pumpAndSettle();
    }

    List<String> visibleNames(WidgetTester tester) {
      final tiles = tester.widgetList<ListTile>(find.byType(ListTile));
      return tiles.map((t) {
        final title = t.title;
        return title is Text ? (title.data ?? '') : '';
      }).toList();
    }

    /// 建一个全局组并返回它。
    Future<KpGroup> makeGroup(String name) async {
      final res = await groups.createGlobalGroup(name: name);
      return (res as Success<KpGroup>).value;
    }

    testWidgets('批量归组 → chips 筛选只显示该组成员；未分组互补',
        (tester) async {
      final math = await makeGroup('数学');
      await makeKp('归组点A');
      await makeKp('归组点B');
      await makeKp('散零点');
      await pumpPage(tester);

      // 多选态勾选 A、B（onTap 即切换勾选）。
      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      await tester.tap(find.text('归组点A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('归组点B'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 个'), findsOneWidget);

      // 批量归组 → 选「数学」。
      await tester.tap(find.byTooltip('批量归组'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SimpleDialogOption, '数学'));
      await tester.pumpAndSettle();

      // toast 回执 + 退出多选。
      expect(find.text('已归入分组（2 个）'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);

      // 数据面：组成员 = A、B，不含散零点（按 id 精确断言）。
      final reloaded = await groups.listGlobalGroups();
      final g = reloaded.firstWhere((x) => x.id == math.id);
      final ids = (await repo.allKnowledgePoints())
          .where((k) => const {'归组点A', '归组点B'}.contains(k.name))
          .map((k) => k.id)
          .toList();
      expect(g.memberIds, unorderedEquals(ids));

      // 点「数学」chip → 只显示该组成员。
      await tester.tap(find.widgetWithText(FilterChip, '数学'));
      await tester.pumpAndSettle();
      expect(visibleNames(tester), unorderedEquals(<String>['归组点A', '归组点B']));

      // 点「未分组」chip → 只剩散零点。
      await tester.tap(find.widgetWithText(FilterChip, '未分组'));
      await tester.pumpAndSettle();
      expect(visibleNames(tester), <String>['散零点']);

      // 回「全部分组」→ 全部回来。
      await tester.tap(find.widgetWithText(FilterChip, '全部分组'));
      await tester.pumpAndSettle();
      expect(visibleNames(tester), hasLength(3));
    });

    testWidgets('单条菜单「设置分组…」→ 移到未分组（归属可逆）', (tester) async {
      final kp = await makeKp('单条归组点');
      await makeGroup('英语');
      await pumpPage(tester);

      // 单条菜单 → 设置分组 → 英语。
      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, '单条归组点'),
        matching: find.byType(PopupMenuButton<String>),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置分组…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SimpleDialogOption, '英语'));
      await tester.pumpAndSettle();
      expect(find.text('已归入分组（1 个）'), findsOneWidget);

      final g = (await groups.listGlobalGroups()).single;
      expect(g.memberIds, <String>[kp.id]);

      // 同一条路径 → 移到未分组：组被摘空，知识点回到未分组。
      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, '单条归组点'),
        matching: find.byType(PopupMenuButton<String>),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置分组…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SimpleDialogOption, '移到未分组'));
      await tester.pumpAndSettle();

      final g2 = (await groups.listGlobalGroups()).single;
      expect(g2.memberIds, isEmpty);
      expect(find.widgetWithText(FilterChip, '未分组'), findsOneWidget);
    });
  });

  group('分组管理面板：新建 / 重命名 / 删除', () {
    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: KnowledgeManagePage(service: makeService(), db: db),
      ));
      await tester.pumpAndSettle();
    }

    /// 打开分组管理面板。
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byTooltip('分组管理'));
      await tester.pumpAndSettle();
      expect(find.text('分组管理'), findsOneWidget);
    }

    /// 关闭面板（点顶部遮罩）。
    Future<void> closeSheet(WidgetTester tester) async {
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.text('分组管理'), findsNothing);
    }

    testWidgets('新建 → 重命名 → 删除（删组不解散成员）', (tester) async {
      final kp = await makeKp('面板归组点');
      await pumpPage(tester);
      await openSheet(tester);

      // 空态 → 新建分组（TextField 限定在弹窗内：页面背后还有搜索框）。
      expect(find.textContaining('还没有分组'), findsOneWidget);
      await tester.tap(find.text('新建分组'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '数学',
      );
      await tester.tap(find.widgetWithText(TextButton, '确定'));
      await tester.pumpAndSettle();
      expect(find.text('已创建「数学」'), findsOneWidget);
      expect(find.text('数学'), findsOneWidget);

      // 把知识点归进该组（数据面直接走仓储，面板 UI 不承担归组）。
      final g = (await groups.listGlobalGroups()).single;
      await groups.addMembers(g.id, <String>[kp.id]);

      // 重命名：点头像行 → 改名。
      await tester.tap(find.text('数学'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '高等数学',
      );
      await tester.tap(find.widgetWithText(TextButton, '确定'));
      await tester.pumpAndSettle();
      expect(find.text('高等数学'), findsOneWidget);

      // 删除：确认弹窗说明「知识点将回到未分组，不会被删除」。
      await tester.tap(find.byTooltip('删除分组'));
      await tester.pumpAndSettle();
      expect(find.text('删除分组「高等数学」？'), findsOneWidget);
      expect(find.textContaining('知识点将回到「未分组」'), findsOneWidget);
      expect(find.textContaining('知识点本身不会被删除'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();

      // 面板回到空态；组已软删（墓碑铁律）。
      expect(find.textContaining('还没有分组'), findsOneWidget);
      expect(await groups.listGlobalGroups(), isEmpty);

      await closeSheet(tester);

      // 页面侧：分组 chips 只剩「未分组」口径，知识点仍在列表里
      // （删的是容器，不是内容）。
      expect(find.text('面板归组点'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilterChip, '未分组'));
      await tester.pumpAndSettle();
      expect(find.text('面板归组点'), findsOneWidget);
    });
  });
}


/// 回收站批量彻底删除测试（用户需求：一键删除 + 批量删除）。
///
/// 覆盖：
/// 1. **仓储层**：[KnowledgeRepository.purgeKnowledgePoints] 批量物理删除
///    （墓碑行 + 残留从属行全清）、单条失败不阻断其余（触发器制造失败）、
///    不存在的 id 幂等计成功、一键清空口径（全量 id）；
/// 2. **上行同步**：每个留档行入队一条 delete op（payload 含 deleted_at），
///    残留从属行同样入队；
/// 3. **页面交互**：回收站页「一键清空」入口（确认弹窗写明彻底删除 N 个、
///    不可恢复）/ 多选态（长按或 AppBar 图标进入、全选、「彻底删除(N)」）。
library;

import 'dart:convert';

import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/sync/sync_outbox.dart';
import 'package:aimindtree_app/data/sync/sync_types.dart';
import 'package:aimindtree_app/features/knowledge/knowledge_recycle_bin_page.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;
  late SyncOutboxRepo outbox;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 'd');
    outbox = SyncOutboxRepo(db, deviceId: 'd');
  });

  tearDown(() async {
    // 全局接线点必须复位，否则会漏到别的测试文件里。
    SyncOutboxRepo.current = null;
    await db.close();
  });

  /// 建一个知识点（手动入口：锚点豁免，最省事）。
  Future<KnowledgePoint> makeKp(String name) async {
    final res = await repo.createManualKnowledgePoint(name: name);
    return (res as Success<KnowledgePoint>).value;
  }

  /// 软删进回收站（墓碑）。
  Future<void> softDelete(String kpId) =>
      repo.softDeleteKnowledgePoint(kpId).then((_) {});

  group('仓储层：purgeKnowledgePoints 批量彻底删除', () {
    test('批量彻底删除：墓碑行物理消失，回收站与常规列表都为空', () async {
      final kps = <KnowledgePoint>[
        await makeKp('批删点A'),
        await makeKp('批删点B'),
        await makeKp('批删点C'),
      ];
      for (final kp in kps) {
        await softDelete(kp.id);
      }
      expect(await repo.deletedKnowledgePoints(), hasLength(3));

      final res = await repo.purgeKnowledgePoints(<String>[for (final kp in kps) kp.id]);
      expect(res, isA<Success<int>>());
      expect((res as Success<int>).value, 3);

      // 回收站与常规列表都没了，物理行确实不存在（不是墓碑）。
      expect(await repo.deletedKnowledgePoints(), isEmpty);
      expect(await repo.allKnowledgePoints(), isEmpty);
      expect(await db.select(db.knowledgePoints).get(), isEmpty);
    });

    test('空列表：幂等返回成功 0，不炸', () async {
      final res = await repo.purgeKnowledgePoints(<String>[]);
      expect(res, isA<Success<int>>());
      expect((res as Success<int>).value, 0);
    });

    test('不存在的 id 按幂等计为成功，且不阻断其余', () async {
      final kp = await makeKp('真实点');
      await softDelete(kp.id);

      final res = await repo.purgeKnowledgePoints(<String>['ghost-1', kp.id, 'ghost-2']);
      expect((res as Success<int>).value, 3);
      // 真实点照样被物理删除。
      expect(await db.select(db.knowledgePoints).get(), isEmpty);
    });

    test('部分失败容错：单条删除失败不阻断其余（触发器制造失败）', () async {
      final good1 = await makeKp('好点1');
      final boom = await makeKp('炸点');
      final good2 = await makeKp('好点2');
      for (final kp in <KnowledgePoint>[good1, boom, good2]) {
        await softDelete(kp.id);
      }
      // 造一个触发器：删「炸点」那一行时抛错，其余行不受影响。
      await db.customStatement(
        'CREATE TRIGGER block_boom BEFORE DELETE ON knowledge_points '
        "WHEN OLD.id = '${boom.id}' BEGIN "
        "SELECT RAISE(ABORT, 'blocked by test'); END",
      );

      final res =
          await repo.purgeKnowledgePoints(<String>[good1.id, boom.id, good2.id]);
      expect(res, isA<Success<int>>());
      // 炸点失败被跳过，两个好点成功。
      expect((res as Success<int>).value, 2);

      // 数据面：好点真删了，炸点仍留在回收站。
      expect(await db.select(db.knowledgePoints).get(), hasLength(1));
      expect((await db.select(db.knowledgePoints).get()).single.id, boom.id);
      final bin = await repo.deletedKnowledgePoints();
      expect(bin.map((k) => k.id), <String>[boom.id]);
    });

    test('一键清空口径：传入全量 id（不受搜索过滤影响），全部物理删除', () async {
      final a = await makeKp('清空点A');
      final b = await makeKp('清空点B');
      await softDelete(a.id);
      await softDelete(b.id);

      // 页面「一键清空」的口径：deletedKnowledgePoints() 的全量 id。
      final allIds = <String>[for (final kp in await repo.deletedKnowledgePoints()) kp.id];
      expect(allIds, unorderedEquals(<String>[a.id, b.id]));

      final res = await repo.purgeKnowledgePoints(allIds);
      expect((res as Success<int>).value, 2);
      expect(await repo.deletedKnowledgePoints(), isEmpty);
      expect(await db.select(db.knowledgePoints).get(), isEmpty);
    });

    test('批量彻底删除连带清掉残留从属行', () async {
      final a = await makeKp('带边点A');
      final b = await makeKp('邻居点');
      await softDelete(a.id);
      // 软删已级联清过一遍；再灌一点残留，验证批量 purge 兜底。
      await db.into(db.prerequisiteEdges).insert(PrerequisiteEdgesCompanion.insert(
            id: 'e-residual',
            fromKpId: a.id,
            toKpId: b.id,
            updatedAt: DateTime.now().toUtc(),
            deviceId: 'd',
          ));
      await db.into(db.masteryRecords).insert(MasteryRecordsCompanion.insert(
            id: 'm-residual',
            kpId: a.id,
            status: 'learning',
            source: const Value('self'),
            updatedAt: DateTime.now().toUtc(),
            deviceId: 'd',
          ));
      await db.into(db.canvasNodes).insert(CanvasNodesCompanion.insert(
            id: 'n-residual',
            canvasId: 'tree-1',
            targetType: 'kp',
            targetId: a.id,
            updatedAt: DateTime.now().toUtc(),
            deviceId: 'd',
          ));

      final res = await repo.purgeKnowledgePoints(<String>[a.id]);
      expect((res as Success<int>).value, 1);

      // 从属行全没了（邻居点本身不受影响）。
      expect(await db.select(db.masteryRecords).get(), isEmpty);
      expect(await db.select(db.prerequisiteEdges).get(), isEmpty);
      expect(await db.select(db.canvasNodes).get(), isEmpty);
      expect(await db.select(db.knowledgePoints).get(), hasLength(1));
    });
  });

  group('仓储层：批量彻底删除的上行同步接线', () {
    test('每个留档行入队一条 delete op（payload 含 deleted_at）', () async {
      SyncOutboxRepo.current = outbox;

      final a = await makeKp('同步点A');
      final b = await makeKp('同步点B');
      await softDelete(a.id);
      await softDelete(b.id);
      // 清掉前面的 upsert + 墓碑，只看批量 purge 这些条。
      await outbox.markPushed(<int>[
        for (final r in await outbox.pending()) r.id,
      ]);

      await repo.purgeKnowledgePoints(<String>[a.id, b.id]);

      final pending = await outbox.pending();
      expect(pending, hasLength(2));
      for (final row in pending) {
        expect(row.entityTable, 'knowledge_points');
        expect(row.entityId, anyOf(a.id, b.id));
        expect(row.op, SyncOp.delete.name);
        // 墓碑时间必须在 payload 里（engine 的 _extractDeletedAt 从这里取）。
        final payload = jsonDecode(row.payloadJson) as Map<String, dynamic>;
        expect(payload.containsKey('deleted_at'), isTrue);
        expect(DateTime.tryParse(payload['deleted_at'] as String), isNotNull);
      }
    });

    test('残留从属行同样入队（整列表一次性交给 sync writer）', () async {
      SyncOutboxRepo.current = outbox;

      final a = await makeKp('残留点A');
      final b = await makeKp('残留点B');
      await softDelete(a.id);
      await softDelete(b.id);
      // 灌残留从属行（挂在 a 上）。
      await db.into(db.prerequisiteEdges).insert(PrerequisiteEdgesCompanion.insert(
            id: 'e-batch',
            fromKpId: a.id,
            toKpId: b.id,
            updatedAt: DateTime.now().toUtc(),
            deviceId: 'd',
          ));
      await db.into(db.masteryRecords).insert(MasteryRecordsCompanion.insert(
            id: 'm-batch',
            kpId: a.id,
            status: 'learning',
            source: const Value('self'),
            updatedAt: DateTime.now().toUtc(),
            deviceId: 'd',
          ));
      await db.into(db.canvasNodes).insert(CanvasNodesCompanion.insert(
            id: 'n-batch',
            canvasId: 'tree-1',
            targetType: 'kp',
            targetId: a.id,
            updatedAt: DateTime.now().toUtc(),
            deviceId: 'd',
          ));
      await outbox.markPushed(<int>[
        for (final r in await outbox.pending()) r.id,
      ]);

      await repo.purgeKnowledgePoints(<String>[a.id, b.id]);

      final pending = await outbox.pending();
      // 2 条 KP delete + 边 / 掌握 / 画布节点各 1 条 delete。
      expect(pending, hasLength(5));
      expect(pending.where((r) => r.entityTable == 'knowledge_points'), hasLength(2));
      expect(pending.where((r) => r.entityTable == 'prerequisite_edges'), hasLength(1));
      expect(pending.where((r) => r.entityTable == 'mastery_records'), hasLength(1));
      expect(pending.where((r) => r.entityTable == 'canvas_nodes'), hasLength(1));
      for (final row in pending) {
        expect(row.op, SyncOp.delete.name);
      }
    });

    test('未接线时不入队也不炸（current 为 null）', () async {
      SyncOutboxRepo.current = null;
      final a = await makeKp('未接线点');
      await softDelete(a.id);

      final res = await repo.purgeKnowledgePoints(<String>[a.id]);
      expect((res as Success<int>).value, 1);
      expect(await db.select(db.knowledgePoints).get(), isEmpty);
    });
  });

  group('回收站页：一键清空', () {
    /// 把回收站页挂起来（用真实仓储，验证「页 → 仓储 → 库」整条链）。
    Future<void> pumpBin(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: KnowledgeRecycleBinPage(repo: repo),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('空回收站：「一键清空」入口存在但禁用', (tester) async {
      await pumpBin(tester);

      final btn = tester.widget<IconButton>(find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == '一键清空回收站',
      ));
      expect(btn.onPressed, isNull);
      // 批量入口仍在（进入后无勾选项，不炸）。
      expect(find.byTooltip('批量彻底删除'), findsOneWidget);
    });

    testWidgets('点「一键清空」→ 确认弹窗写明彻底删除 N 个、不可恢复 → 真删',
        (tester) async {
      final a = await makeKp('清空点A');
      final b = await makeKp('清空点B');
      await softDelete(a.id);
      await softDelete(b.id);
      await pumpBin(tester);

      await tester.tap(find.byTooltip('一键清空回收站'));
      await tester.pumpAndSettle();

      expect(find.text('一键清空回收站'), findsOneWidget);
      expect(find.textContaining('彻底删除 2 个知识点'), findsOneWidget);
      expect(find.textContaining('不可恢复'), findsOneWidget);
      // 确认框出现时数据还没动。
      expect(await repo.deletedKnowledgePoints(), hasLength(2));

      // 确认 → 全量物理删除。
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '彻底删除'),
      ));
      await tester.pumpAndSettle();

      expect(await repo.deletedKnowledgePoints(), isEmpty);
      expect(await db.select(db.knowledgePoints).get(), isEmpty);
      expect(find.text('已彻底删除 2 个知识点'), findsOneWidget);
      expect(find.text('回收站是空的'), findsOneWidget);
    });

    testWidgets('一键清空确认框点「取消」→ 一条都不删', (tester) async {
      final a = await makeKp('取消清空点');
      await softDelete(a.id);
      await pumpBin(tester);

      await tester.tap(find.byTooltip('一键清空回收站'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '取消'),
      ));
      await tester.pumpAndSettle();

      expect(await repo.deletedKnowledgePoints(), hasLength(1));
    });

    testWidgets('一键清空口径是全量：搜索过滤不影响清空数量', (tester) async {
      final a = await makeKp('口径点A');
      final b = await makeKp('口径点B');
      final c = await makeKp('口径点C');
      for (final kp in <KnowledgePoint>[a, b, c]) {
        await softDelete(kp.id);
      }
      await pumpBin(tester);

      // 搜索过滤到只剩 1 条可见。
      await tester.enterText(find.byType(TextField), '口径点A');
      await tester.pumpAndSettle();
      expect(find.text('口径点B'), findsNothing);

      // 但清空口径是全量 3 个。
      await tester.tap(find.byTooltip('一键清空回收站'));
      await tester.pumpAndSettle();
      expect(find.textContaining('彻底删除 3 个知识点'), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '彻底删除'),
      ));
      await tester.pumpAndSettle();

      expect(await repo.deletedKnowledgePoints(), isEmpty);
      expect(await db.select(db.knowledgePoints).get(), isEmpty);
    });
  });

  group('回收站页：多选批量彻底删除', () {
    Future<void> pumpBin(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: KnowledgeRecycleBinPage(repo: repo),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('长按卡片进入多选并预选该条', (tester) async {
      final a = await makeKp('长按删A');
      final b = await makeKp('长按删B');
      await softDelete(a.id);
      await softDelete(b.id);
      await pumpBin(tester);

      await tester.longPress(find.text('长按删A'));
      await tester.pumpAndSettle();

      expect(find.text('已选 1 个'), findsOneWidget);
      final checkbox = tester.widget<Checkbox>(find.descendant(
        of: find.ancestor(
          of: find.text('长按删A'),
          matching: find.byType(Card),
        ),
        matching: find.byType(Checkbox),
      ));
      expect(checkbox.value, isTrue);
    });

    testWidgets('AppBar 批量入口 → 全选 →「彻底删除(N)」→ 全部物理删除',
        (tester) async {
      final a = await makeKp('多选删A');
      final b = await makeKp('多选删B');
      await softDelete(a.id);
      await softDelete(b.id);
      await pumpBin(tester);

      // AppBar 图标进入多选态（不预选）。
      await tester.tap(find.byTooltip('批量彻底删除'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 个'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);

      // 勾选第一条 → 全选。
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 个'), findsOneWidget);
      await tester.tap(find.byTooltip('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 个'), findsOneWidget);

      // 点「彻底删除(2)」→ 确认弹窗。
      await tester.tap(find.text('彻底删除(2)'));
      await tester.pumpAndSettle();
      expect(find.text('批量彻底删除'), findsOneWidget);
      expect(find.textContaining('确定彻底删除选中的 2 个知识点'), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '彻底删除'),
      ));
      await tester.pumpAndSettle();

      // 全删 + 退出多选 + 回执。
      expect(await repo.deletedKnowledgePoints(), isEmpty);
      expect(await db.select(db.knowledgePoints).get(), isEmpty);
      expect(find.text('已彻底删除 2 个知识点'), findsOneWidget);
      expect(find.text('回收站是空的'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('批量确认框点「取消」→ 一条都不删，仍留在多选态', (tester) async {
      final a = await makeKp('取消多选点');
      final b = await makeKp('取消多选点2');
      await softDelete(a.id);
      await softDelete(b.id);
      await pumpBin(tester);

      await tester.tap(find.byTooltip('批量彻底删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 个'), findsOneWidget);

      await tester.tap(find.text('彻底删除(1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '取消'),
      ));
      await tester.pumpAndSettle();

      expect(await repo.deletedKnowledgePoints(), hasLength(2));
      expect(find.text('已选 1 个'), findsOneWidget);
    });

    testWidgets('多选态勾选全部取消时自动退出多选', (tester) async {
      final a = await makeKp('退出多选点');
      await softDelete(a.id);
      await pumpBin(tester);

      await tester.longPress(find.text('退出多选点'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 个'), findsOneWidget);

      // 再点一次勾选 → 取消 → 自动退出多选。
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 个'), findsNothing);
      expect(find.text('回收站'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('多选态里「恢复」某条 → 该条摘掉勾选，不参与批量删除',
        (tester) async {
      final a = await makeKp('多选恢复点');
      final b = await makeKp('多选删除点');
      await softDelete(a.id);
      await softDelete(b.id);
      await pumpBin(tester);

      // 长按 A 进入多选（预选 A），再勾上 B → 已选 2 个。
      await tester.longPress(find.text('多选恢复点'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.ancestor(
          of: find.text('多选删除点'),
          matching: find.byType(Card),
        ),
        matching: find.byType(Checkbox),
      ));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 个'), findsOneWidget);

      // 在多选态里点 A 卡片的「恢复」→ A 回到常规列表，勾选摘掉。
      await tester.tap(find.descendant(
        of: find.ancestor(
          of: find.text('多选恢复点'),
          matching: find.byType(Card),
        ),
        matching: find.widgetWithText(TextButton, '恢复'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('已选 1 个'), findsOneWidget);
      expect((await repo.allKnowledgePoints()).map((k) => k.id), <String>[a.id]);

      // 再批量彻底删除 → 只删 B（A 已恢复，不在回收站）。
      await tester.tap(find.text('彻底删除(1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '彻底删除'),
      ));
      await tester.pumpAndSettle();

      expect(await repo.deletedKnowledgePoints(), isEmpty);
      expect(await db.select(db.knowledgePoints).get(), hasLength(1));
      expect((await db.select(db.knowledgePoints).get()).single.id, a.id);
    });
  });
}

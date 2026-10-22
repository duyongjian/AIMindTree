/// 知识点回收站测试（P2）。
///
/// 覆盖三条主线：
/// 1. **软删铁律**：已删 KP 只出现在回收站（`deletedKnowledgePoints`），
///    绝不进入任何常规列表（`allKnowledgePoints`）。
/// 2. **恢复**：墓碑置空 + version++ 后，KP 重新回到常规列表，回收站不再有它。
/// 3. **彻底删除**：物理删除，回收站与常规列表都没有它。
///
/// 附带验证**上行同步接线**：恢复入队 `upsert`、彻底删除入队 `delete`
/// （payload 含 `deleted_at`），让这两个动作能跨设备传播。
library;

import 'dart:convert';

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
import 'package:aimindtree_app/data/repositories/note_asset_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:aimindtree_app/data/sync/sync_outbox.dart';
import 'package:aimindtree_app/data/sync/sync_types.dart';
import 'package:aimindtree_app/features/knowledge/knowledge_manage_page.dart';
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

  group('知识点回收站：软删铁律', () {
    test('软删后 KP 只出现在回收站，不在常规列表', () async {
      final kp = await makeKp('待删点');
      expect(await repo.allKnowledgePoints(), hasLength(1));

      final del = await repo.softDeleteKnowledgePoint(kp.id);
      expect((del as Success<int>).value, 1);

      // 常规列表：消失（软删铁律）。
      final all = await repo.allKnowledgePoints();
      expect(all, isEmpty);
      expect(all.map((k) => k.id), isNot(contains(kp.id)));

      // 回收站：出现，且带墓碑时间。
      final bin = await repo.deletedKnowledgePoints();
      expect(bin, hasLength(1));
      expect(bin.single.id, kp.id);
      expect(bin.single.deletedAt, isNotNull);
    });

    test('未删除的知识点不在回收站里', () async {
      await makeKp('活着的点');
      expect(await repo.deletedKnowledgePoints(), isEmpty);
    });
  });

  group('知识点回收站：恢复', () {
    test('恢复后回收站不再有它，常规列表重新有它', () async {
      final kp = await makeKp('可恢复点');
      await repo.softDeleteKnowledgePoint(kp.id);
      expect(await repo.deletedKnowledgePoints(), hasLength(1));

      final res = await repo.restoreKnowledgePoint(kp.id);
      expect(res, isA<Success<KnowledgePoint>>());
      final restored = (res as Success<KnowledgePoint>).value;
      expect(restored.id, kp.id);
      expect(restored.deletedAt, isNull);
      // version 递增（配合 LWW 同步）。
      expect(restored.version, greaterThan(kp.version));

      // 回收站：没有了。
      expect(await repo.deletedKnowledgePoints(), isEmpty);
      // 常规列表：回来了。
      final all = await repo.allKnowledgePoints();
      expect(all, hasLength(1));
      expect(all.single.id, kp.id);
      expect(all.single.deletedAt, isNull);
    });

    test('恢复不存在的知识点返回 Failure', () async {
      final res = await repo.restoreKnowledgePoint('ghost-id');
      expect(res, isA<Failure<KnowledgePoint>>());
    });

    test('对未删除的知识点恢复是幂等的（不重复写库）', () async {
      final kp = await makeKp('活着的点');
      final before = await repo.allKnowledgePoints();

      final res = await repo.restoreKnowledgePoint(kp.id);
      expect(res, isA<Success<KnowledgePoint>>());
      final after = await repo.allKnowledgePoints();
      expect(after.single.version, before.single.version);
    });
  });

  group('知识点回收站：彻底删除', () {
    test('彻底删除后行彻底消失（回收站与常规列表都没有）', () async {
      final kp = await makeKp('待彻底删除');
      await repo.softDeleteKnowledgePoint(kp.id);
      expect(await repo.deletedKnowledgePoints(), hasLength(1));

      final res = await repo.purgeKnowledgePoint(kp.id);
      expect(res, isA<Success<void>>());

      // 回收站：没有了。
      expect(await repo.deletedKnowledgePoints(), isEmpty);
      // 常规列表：也没有。
      expect(await repo.allKnowledgePoints(), isEmpty);
      // 物理行确实没了（不是墓碑，是真删）。
      final rows = await db.select(db.knowledgePoints).get();
      expect(rows, isEmpty);
    });

    test('彻底删除不存在的知识点幂等返回成功', () async {
      final res = await repo.purgeKnowledgePoint('ghost-id');
      expect(res, isA<Success<void>>());
    });

    test('彻底删除连带清掉残留的从属行', () async {
      final kp = await makeKp('带边的点');
      final other = await makeKp('邻居点');
      // 造一条前置边 A→B。
      await repo.addManualPrerequisiteEdge(kp.id, other.id);
      expect(await repo.countPrerequisiteEdges(kp.id), 1);

      await repo.softDeleteKnowledgePoint(kp.id);
      // 软删已级联清过一遍；这里再灌一点残留，验证 purge 兜底。
      await db.into(db.prerequisiteEdges).insert(PrerequisiteEdgesCompanion.insert(
            id: 'e-residual',
            fromKpId: kp.id,
            toKpId: other.id,
            updatedAt: DateTime.now().toUtc(),
            deviceId: 'd',
          ));
      await db.into(db.masteryRecords).insert(MasteryRecordsCompanion.insert(
            id: 'm-residual',
            kpId: kp.id,
            status: 'learning',
            source: const Value('self'),
            updatedAt: DateTime.now().toUtc(),
            deviceId: 'd',
          ));
      await db.into(db.canvasNodes).insert(CanvasNodesCompanion.insert(
            id: 'n-residual',
            canvasId: 'tree-1',
            targetType: 'kp',
            targetId: kp.id,
            updatedAt: DateTime.now().toUtc(),
            deviceId: 'd',
          ));

      await repo.purgeKnowledgePoint(kp.id);

      // 从属行全没了（邻居点本身不受影响）。
      expect(await db.select(db.masteryRecords).get(), isEmpty);
      expect(await db.select(db.prerequisiteEdges).get(), isEmpty);
      expect(await db.select(db.canvasNodes).get(), isEmpty);
      // 邻居点还在（只清「与被删 KP 相关」的行）。
      expect(await db.select(db.knowledgePoints).get(), hasLength(1));
    });
  });

  group('知识点回收站：上行同步接线', () {
    test('恢复 → knowledge_points upsert（deleted_at 为空）', () async {
      SyncOutboxRepo.current = outbox;

      final kp = await makeKp('待恢复点');
      await repo.softDeleteKnowledgePoint(kp.id);
      // 清掉前面的 upsert + 墓碑，只看恢复这一条。
      await outbox.markPushed(<int>[
        for (final r in await outbox.pending()) r.id,
      ]);

      await repo.restoreKnowledgePoint(kp.id);

      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      final row = pending.single;
      expect(row.entityTable, 'knowledge_points');
      expect(row.entityId, kp.id);
      expect(row.op, SyncOp.upsert.name);
      // baseVersion = 写完后该行的新 version。
      final restored = await repo.allKnowledgePoints();
      expect(row.baseVersion, restored.single.version);

      final payload =
          jsonDecode(row.payloadJson) as Map<String, dynamic>;
      expect(payload['id'], kp.id);
      expect(payload['name'], '待恢复点');
      // 恢复 = 墓碑清空（payload 里 deleted_at 为 null，远端据此复活）。
      expect(payload['deleted_at'], isNull);
    });

    test('彻底删除 → knowledge_points delete（payload 含 deleted_at）', () async {
      SyncOutboxRepo.current = outbox;

      final kp = await makeKp('待purge点');
      await repo.softDeleteKnowledgePoint(kp.id);
      await outbox.markPushed(<int>[
        for (final r in await outbox.pending()) r.id,
      ]);

      await repo.purgeKnowledgePoint(kp.id);

      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      final row = pending.single;
      expect(row.entityTable, 'knowledge_points');
      expect(row.entityId, kp.id);
      expect(row.op, SyncOp.delete.name);
      // 墓碑时间必须在 payload 里（engine 的 _extractDeletedAt 从这里取）。
      final payload =
          jsonDecode(row.payloadJson) as Map<String, dynamic>;
      expect(payload.containsKey('deleted_at'), isTrue);
      expect(DateTime.tryParse(payload['deleted_at'] as String), isNotNull);
    });
  });

  group('知识点回收站：页面交互', () {
    /// 把回收站页挂起来（用真实仓储，验证的是「页 → 仓储 → 库」整条链）。
    Future<void> pumpBin(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: KnowledgeRecycleBinPage(repo: repo),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('空态文案：回收站是空的', (tester) async {
      await pumpBin(tester);
      expect(find.text('回收站是空的'), findsOneWidget);
    });

    testWidgets('列出已删知识点并展示类型 / 来源 / 删除时间', (tester) async {
      final kp = await makeKp('被删的点');
      await repo.softDeleteKnowledgePoint(kp.id);
      await pumpBin(tester);

      expect(find.text('被删的点'), findsOneWidget);
      // 类型标签「概念」+ 来源标签「手动」（与删除时间在同一个 Text 里）。
      expect(find.text('概念'), findsOneWidget);
      expect(find.textContaining('手动'), findsOneWidget);
      expect(find.textContaining('删除于'), findsOneWidget);
      // 恢复 / 彻底删除两个动作都在。
      expect(find.text('恢复'), findsOneWidget);
      expect(find.text('彻底删除'), findsOneWidget);
    });

    testWidgets('点「恢复」→ 从列表移除并回到常规列表', (tester) async {
      final kp = await makeKp('可恢复的点');
      await repo.softDeleteKnowledgePoint(kp.id);
      await pumpBin(tester);

      await tester.tap(find.text('恢复'));
      await tester.pumpAndSettle();

      // 回收站里没有了，常规列表里回来了。
      expect(find.text('可恢复的点'), findsNothing);
      expect(await repo.deletedKnowledgePoints(), isEmpty);
      final all = await repo.allKnowledgePoints();
      expect(all, hasLength(1));
      expect(all.single.id, kp.id);
    });

    testWidgets('点「彻底删除」→ 先弹确认框，确认后才真删', (tester) async {
      final kp = await makeKp('待彻底删的点');
      await repo.softDeleteKnowledgePoint(kp.id);
      await pumpBin(tester);

      await tester.tap(find.text('彻底删除'));
      await tester.pumpAndSettle();

      // 确认框出现，且尚未删除。
      expect(find.textContaining('彻底删除后不可恢复'), findsOneWidget);
      expect(await repo.deletedKnowledgePoints(), hasLength(1));

      // 确认 → 真删（只点确认框里的那个按钮）。
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '彻底删除'),
      ));
      await tester.pumpAndSettle();

      expect(await repo.deletedKnowledgePoints(), isEmpty);
      final rows = await db.select(db.knowledgePoints).get();
      expect(rows, isEmpty);
    });

    testWidgets('确认框点「取消」→ 不删', (tester) async {
      final kp = await makeKp('取消就别删');
      await repo.softDeleteKnowledgePoint(kp.id);
      await pumpBin(tester);

      await tester.tap(find.text('彻底删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '取消'),
      ));
      await tester.pumpAndSettle();

      expect(await repo.deletedKnowledgePoints(), hasLength(1));
    });
  });

  group('知识点管理页：回收站入口 + 下拉断言防护', () {
    /// 造一个够用的 ExtractionService（管理页只用到 repo / trees）。
    ExtractionService makeService() => ExtractionService(
          repo: repo,
          trees: TreeRepository(db, deviceId: 'd'),
          groups: GroupRepository(db, deviceId: 'd'),
          jobs: AiJobService(baseUrl: 'http://127.0.0.1:8787'),
          ai: AiService(router: AiTaskRouter(providers: <String, AiProvider>{})),
          assets: NoteAssetRepository(db, deviceId: 'd'),
        );

    testWidgets('AppBar 有回收站入口，点进去能看到已删知识点',
        (tester) async {
      final kp = await makeKp('已删的入口点');
      await repo.softDeleteKnowledgePoint(kp.id);

      await tester.pumpWidget(MaterialApp(
        home: KnowledgeManagePage(service: makeService(), db: db),
      ));
      await tester.pumpAndSettle();

      // 常规列表看不到它（软删铁律）。
      expect(find.text('已删的入口点'), findsNothing);

      // AppBar 上有回收站入口。
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      // 回收站里能看到。
      expect(find.text('回收站'), findsOneWidget);
      expect(find.text('已删的入口点'), findsOneWidget);
    });

    testWidgets('编辑「来源笔记已删」的知识点不触发下拉断言崩溃',
        (tester) async {
      // 造一个知识点，其来源笔记随后被软删 → 编辑时下拉按 id 取不到实例。
      final note = Note(title: '会被删的笔记', contentMd: '正文');
      await repo.saveNote(note);
      final kpRes = await repo.createManualKnowledgePoint(
        name: '锚在已删笔记上的点',
        sourceNoteId: note.id,
      );
      expect(kpRes, isA<Success<KnowledgePoint>>());
      // 软删来源笔记（listNotes 只返回未删笔记 → 下拉里取不到该 id）。
      await repo.saveNote(Note(
        id: note.id,
        title: note.title,
        contentMd: note.contentMd,
        deletedAt: DateTime.now().toUtc(),
      ));

      await tester.pumpWidget(MaterialApp(
        home: KnowledgeManagePage(service: makeService(), db: db),
      ));
      await tester.pumpAndSettle();

      // 打开条目菜单 → 编辑：旧实现这里会因 DropdownButton 0 匹配而断言崩溃。
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();

      expect(find.text('编辑知识点'), findsOneWidget);
      // 占位项如实展示当前关联。
      expect(find.text('（来源笔记已删除）'), findsOneWidget);
    });
  });
}

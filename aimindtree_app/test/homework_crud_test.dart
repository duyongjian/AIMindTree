import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/homework.dart';
import 'package:aimindtree_app/data/repositories/homework_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 作业的增删改查（**含草稿**）。
///
/// 锁住四件事：
/// 1. **草稿允许零题目**：`status='draft'` 的空壳照样是一行记录，历史里查得到
///    ——「我明明存过，历史里却没有」是这个需求最容易写坏的地方。
/// 2. **软删 → 撤销**：`softDelete` 后列表看不见，`restore` 后原样回来，且是
///    **同一 id、同一内容**（不是重新 create 一条换了 id 的复制品）。
/// 3. **状态双向流转**：draft ⇄ assigned → done（历史页菜单三项都走 updateStatus）。
/// 4. **软删的行不能漏进任何列表查询**（`listAll` / `listByKp` / `listByCanvas`）。
///
/// 同步侧不在这里测：`upsertHomework` / `tombstoneHomework` 的 payload 键集由
/// `sync_row_map_test.dart` 的四方一致性护栏覆盖（写键 == 读键 == 契约 == 真实列）。
void main() {
  late AppDatabase db;
  late HomeworkRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = HomeworkRepository(db, deviceId: 'test-device');
  });

  tearDown(() async {
    await db.close();
  });

  const HomeworkItem q1 = HomeworkItem(
    kpId: 'kp1',
    kpName: '极限的定义',
    type: 'short',
    question: '用 ε-δ 语言叙述极限的定义。',
    answer: '任取 ε>0，存在 δ>0 …',
  );
  const HomeworkItem q2 = HomeworkItem(
    kpId: 'kp1',
    kpName: '极限的定义',
    type: 'fill',
    question: 'lim(x→0) sin x / x = ___',
    answer: '1',
  );

  /// 建一份草稿（默认零题目，正好覆盖「草稿可以是空壳」）。
  Future<Homework> newDraft({
    String canvasId = 'tree1',
    String? kpId = 'kp1',
    List<HomeworkItem> items = const <HomeworkItem>[],
    String status = 'draft',
  }) async {
    final r = await repo.create(
      canvasId: canvasId,
      title: '第三章错题',
      kpIds: kpId == null ? const <String>[] : <String>[kpId],
      items: items,
      kpId: kpId,
      status: status,
    );
    final Homework? hw = r.valueOrNull;
    expect(hw, isNotNull, reason: 'create 失败：${r.valueOrNull}');
    return hw!;
  }

  /// 直读底层行（仓储不暴露 version / deleted_at，这里要看真值）。
  Future<HomeworkRow> rawRow(String id) =>
      (db.select(db.homeworks)..where((t) => t.id.equals(id))).getSingle();

  group('草稿（增 / 查）', () {
    test('零题目的草稿也是一条记录：存在、可查、状态是 draft', () async {
      final hw = await newDraft();

      final all = await repo.listAll();
      expect(all.length, 1);
      expect(all.single.id, hw.id);
      expect(all.single.status, 'draft');
      expect(all.single.itemCount, 0, reason: '空壳草稿允许 0 题');

      final row = await rawRow(hw.id);
      expect(row.version, 1);
      expect(row.deletedAt, isNull);
    });

    test('有题目的草稿：题目 JSON 往返不丢字段', () async {
      final hw = await newDraft(items: const <HomeworkItem>[q1, q2]);
      final got = await repo.byId(hw.id);
      expect(got, isNotNull);
      expect(got!.itemCount, 2);
      expect(got.items.first.kpName, '极限的定义');
      expect(got.items.first.question, '用 ε-δ 语言叙述极限的定义。');
      expect(got.items.last.answer, '1');
    });

    test('草稿能被「保存」覆盖（改标题 + 加题），version 递增', () async {
      final hw = await newDraft();
      final before = await rawRow(hw.id);

      final r = await repo.save(hw.copyWith(
        title: '第三章错题（改）',
        items: const <HomeworkItem>[q1],
      ));
      expect(r.isSuccess, isTrue);

      final after = await rawRow(hw.id);
      expect(after.title, '第三章错题（改）');
      expect(after.version, before.version + 1);
      expect(
        after.updatedAt.isBefore(before.updatedAt),
        isFalse,
        reason: 'save 必须把 updated_at 往前推（历史页按它排序 / 分组）',
      );
      expect((await repo.byId(hw.id))!.itemCount, 1);
    });
  });

  group('状态流转（改）', () {
    test('draft → assigned → done → draft 都能落库', () async {
      final hw = await newDraft();
      expect((await repo.byId(hw.id))!.status, 'draft');

      for (final s in <String>['assigned', 'done', 'draft']) {
        await repo.updateStatus(hw.id, s);
        expect((await repo.byId(hw.id))!.status, s);
      }
    });

    test('状态变更也 bump version（同步靠它判先后）', () async {
      final hw = await newDraft();
      final v1 = (await rawRow(hw.id)).version;
      await repo.updateStatus(hw.id, 'done');
      expect((await rawRow(hw.id)).version, v1 + 1);
    });
  });

  group('删除与撤销（删）', () {
    test('软删后：listAll / listByKp / listByCanvas / byId 全部查不到', () async {
      final hw = await newDraft(items: const <HomeworkItem>[q1]);

      final r = await repo.softDelete(hw.id);
      expect(r.isSuccess, isTrue);

      expect(await repo.listAll(), isEmpty);
      expect(await repo.listByKp('kp1'), isEmpty);
      expect(await repo.listByCanvas('tree1'), isEmpty);
      expect(await repo.byId(hw.id), isNull);

      // 行还在库里（墓碑），不是物理删除 —— 否则跨设备删除传播不了。
      final row = await rawRow(hw.id);
      expect(row.deletedAt, isNotNull);
      expect(row.version, 2);
    });

    test('restore 撤销：同 id 原样回来，内容不变，version 递增', () async {
      final hw = await newDraft(items: const <HomeworkItem>[q1, q2]);
      await repo.softDelete(hw.id);

      final r = await repo.restore(hw.id);
      expect(r.isSuccess, isTrue);

      final back = await repo.byId(hw.id);
      expect(back, isNotNull, reason: 'restore 后必须能在历史里重新看到');
      expect(back!.id, hw.id, reason: '必须是同一条，不能是新建的复制品');
      expect(back.title, '第三章错题');
      expect(back.itemCount, 2);
      expect(back.status, 'draft');

      final row = await rawRow(hw.id);
      expect(row.deletedAt, isNull);
      expect(row.version, 3, reason: 'create=1 → softDelete=2 → restore=3');
      expect(await repo.listAll(), hasLength(1));
    });

    test('restore 一条已被物理删掉的行：按成功处理，不抛', () async {
      final hw = await newDraft();
      await (db.delete(db.homeworks)..where((t) => t.id.equals(hw.id))).go();

      final r = await repo.restore(hw.id);
      expect(r.isSuccess, isTrue);
      expect(await repo.listAll(), isEmpty);
    });
  });

  group('按知识点 / 按树查询（查）', () {
    test('listByKp 只返回该点的行；listByCanvas 只返回该树的行', () async {
      final a = await newDraft(kpId: 'kp1', canvasId: 'tree1');
      final b = await newDraft(kpId: 'kp2', canvasId: 'tree1');
      final c = await newDraft(kpId: 'kp1', canvasId: 'tree2');

      final byKp1 = await repo.listByKp('kp1');
      expect(byKp1.map((h) => h.id).toSet(), <String>{a.id, c.id});

      final byTree1 = await repo.listByCanvas('tree1');
      expect(byTree1.map((h) => h.id).toSet(), <String>{a.id, b.id});
    });

    test('listByKp 排除已软删的行，且按最近更新倒序', () async {
      final first = await newDraft(kpId: 'kp1');
      final second = await newDraft(kpId: 'kp1');

      // 排序必须用**显式**的 updated_at 验，不能靠「连着创建两次谁更晚」——
      // 两次 create 可能落在同一毫秒，那时顺序由二级排序（id desc，ULID 递增）
      // 决定，断言会随机器速度时红时绿。
      await (db.update(db.homeworks)..where((t) => t.id.equals(first.id)))
          .write(HomeworksCompanion(updatedAt: Value(DateTime.utc(2026, 1, 1))));
      await (db.update(db.homeworks)..where((t) => t.id.equals(second.id)))
          .write(HomeworksCompanion(updatedAt: Value(DateTime.utc(2026, 1, 2))));

      final list = await repo.listByKp('kp1');
      expect(
        list.map((h) => h.id).toList(),
        <String>[second.id, first.id],
        reason: '最近更新的排前面',
      );

      await repo.softDelete(second.id);
      final after = await repo.listByKp('kp1');
      expect(after.map((h) => h.id), <String>[first.id]);
    });
  });
}

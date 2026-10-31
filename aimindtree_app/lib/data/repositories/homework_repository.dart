/// 作业仓储（`homeworks` 表）。
///
/// 与 GroupRepository 同构：行 → 领域模型的转换都在 `_fromRow`，JSON 列的编解码
/// 走 `models/homework.dart` 的 `decode*` / `encode*`（坏数据一律降级为空，不抛）。
library;

import 'package:drift/drift.dart';

import '../../core/id.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../db/drift_database.dart';
import '../models/homework.dart';
import '../sync/sync_outbox_writer.dart';

class HomeworkRepository {
  HomeworkRepository(this._db, {this.deviceId = ''});

  final AppDatabase _db;
  final String deviceId;

  static final AppLog _log = AppLog('homework_repo');

  /// 上行同步写入器（把本地写登记进 outbox；未接线时自动跳过）。
  ///
  /// 与 [HomeworkRepository] 共用**同一个** [AppDatabase] 实例，否则
  /// `SyncOutboxWriter` 的身份校验会静默跳过入队（避免实体与发件箱错位）。
  late final SyncOutboxWriter _sync = SyncOutboxWriter(_db);

  /// 某棵树的作业，最近更新的在前。
  ///
  /// ⚠️ 二级排序带上 `id`：同秒写入时 `updatedAt` 会撞车（unix 秒精度退化后
  /// 顺序由 rowid 决定，看起来就像「刚保存的作业跑到列表中间去了」）。
  Future<List<Homework>> listByCanvas(String canvasId) async {
    final rows = await (_db.select(_db.homeworks)
          ..where((t) => t.canvasId.equals(canvasId) & t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm.desc(t.updatedAt),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .get();
    return <Homework>[for (final r in rows) _fromRow(r)];
  }

  Future<Homework?> byId(String id) async {
    final row = await (_db.select(_db.homeworks)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  Future<Result<Homework>> create({
    required String canvasId,
    required String title,
    required List<String> kpIds,
    required List<HomeworkItem> items,
    String? kpId,
    String? batchId,
    String status = 'assigned',
    DateTime? dueAt,
  }) async {
    try {
      final id = newUlid();
      final now = DateTime.now().toUtc();
      await _db.into(_db.homeworks).insert(HomeworksCompanion(
            id: Value(id),
            canvasId: Value(canvasId),
            title: Value(title),
            kpIdsJson: Value(encodeKpIds(kpIds)),
            itemsJson: Value(encodeHomeworkItems(items)),
            kpId: kpId == null ? const Value.absent() : Value(kpId),
            batchId: batchId == null ? const Value.absent() : Value(batchId),
            status: Value(status),
            dueAt: dueAt == null ? const Value.absent() : Value(dueAt),
            updatedAt: Value(now),
            version: const Value(1),
            deviceId: Value(deviceId),
          ));
      // 上行记账：行已落到本地库，登记它的最终态（未接线时静默跳过）。
      await _sync.upsertHomework(id);
      return Success(Homework(
        id: id,
        canvasId: canvasId,
        title: title,
        kpIds: kpIds,
        items: items,
        updatedAt: now,
        kpId: kpId,
        batchId: batchId,
        status: status,
        dueAt: dueAt,
      ));
    } on Object catch (e, s) {
      _log.e('新建作业失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 保存标题 / 薄弱点 / 题目（整体覆写，version +1）。
  Future<Result<void>> save(Homework hw) async {
    try {
      final existing = await (_db.select(_db.homeworks)
            ..where((t) => t.id.equals(hw.id)))
          .getSingleOrNull();
      await (_db.update(_db.homeworks)..where((t) => t.id.equals(hw.id)))
          .write(HomeworksCompanion(
        title: Value(hw.title),
        kpIdsJson: Value(encodeKpIds(hw.kpIds)),
        itemsJson: Value(encodeHomeworkItems(hw.items)),
        kpId: hw.kpId == null ? const Value.absent() : Value(hw.kpId),
        batchId: hw.batchId == null ? const Value.absent() : Value(hw.batchId),
        status: Value(hw.status),
        dueAt: hw.dueAt == null ? const Value.absent() : Value(hw.dueAt),
        updatedAt: Value(DateTime.now().toUtc()),
        version: Value((existing?.version ?? 0) + 1),
      ));
      // 上行记账：整行最终态（含 version 已 bump）。
      await _sync.upsertHomework(hw.id);
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('保存作业失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 软删除（tombstone）：删除要能传播给别端，所以不物理删（§11）。
  Future<Result<void>> softDelete(String id) async {
    try {
      final existing = await (_db.select(_db.homeworks)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      await (_db.update(_db.homeworks)..where((t) => t.id.equals(id)))
          .write(HomeworksCompanion(
        deletedAt: Value(DateTime.now().toUtc()),
        updatedAt: Value(DateTime.now().toUtc()),
        version: Value((existing?.version ?? 0) + 1),
      ));
      // 上行记账：墓碑（不要用 hardDelete —— 行还在本地，deleted_at 才刚写进）。
      await _sync.tombstoneHomework(id);
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('删除作业失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 撤销删除：把 `deleted_at` 清回 null（配 `softDelete` 用，供「撤销」按钮）。
  ///
  /// 跨设备为什么也能救回来：本方法清空 `deleted_at` 后照常
  /// [SyncOutboxWriter.upsertHomework] 上报，对端下次 pull 拿到的是
  /// `deleted_at: null` 的正常行，`_upsertLocal` 走 `insertOrReplace` →
  /// 就算对端此前已被墓碑硬删，也会被重新插回来。
  ///
  /// ⚠️ 前提是**先 restore 再 push**（本方法内部就是这个顺序）。若反过来
  /// 先把墓碑推上去，对端会无条件硬删，本端再恢复也拉不回来。
  Future<Result<void>> restore(String id) async {
    try {
      final existing = await (_db.select(_db.homeworks)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (existing == null) {
        // 行已物理消失（对端墓碑拉过来后被硬删）→ 无可恢复，按成功处理。
        return const Success<void>(null);
      }
      await (_db.update(_db.homeworks)..where((t) => t.id.equals(id)))
          .write(HomeworksCompanion(
        deletedAt: const Value<DateTime?>(null),
        updatedAt: Value(DateTime.now().toUtc()),
        version: Value(existing.version + 1),
      ));
      await _sync.upsertHomework(id);
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('恢复作业失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 新建一行作业并返回底层 `insert` 的整型 rowid。
  ///
  /// 与 [create] 的区别：本方法直接吃「原始字段」并生成 ULID，返回 rowid
  /// （而非 [Homework] 领域对象），供内部批量编排使用。
  ///
  /// 注意：相比设计稿签名这里补了 [canvasId]——`homeworks` 表强制要求该列，
  /// 且作业必归属某棵知识树，无可省略。作业与知识点的关联经 [kpId] 表达，
  /// [kpIdsJson] 顺带记录该作业覆盖的知识点快照（取 [kpId] 单元素）。
  Future<int> createHomework({
    required String canvasId,
    required String? kpId,
    String? batchId,
    String title = '',
    String? itemsJson,
    String status = 'assigned',
    DateTime? dueAt,
  }) async {
    final id = newUlid();
    final rowId = await _db.into(_db.homeworks).insert(HomeworksCompanion(
          id: Value(id),
          canvasId: Value(canvasId),
          title: Value(title),
          kpIdsJson: Value(encodeKpIds(kpId == null ? <String>[] : <String>[kpId])),
          itemsJson: Value(itemsJson ?? encodeHomeworkItems(<HomeworkItem>[])),
          kpId: kpId == null ? const Value.absent() : Value(kpId),
          batchId: batchId == null ? const Value.absent() : Value(batchId),
          status: Value(status),
          dueAt: dueAt == null ? const Value.absent() : Value(dueAt),
          updatedAt: Value(DateTime.now().toUtc()),
          version: const Value(1),
          deviceId: Value(deviceId),
        ));
    // 上行记账：用局部 ULID（表的业务主键），不是 insert 返回的整型 rowid。
    await _sync.upsertHomework(id);
    return rowId;
  }

  /// 按主知识点外键筛选（进某知识点看其作业）。
  Future<List<Homework>> listByKp(String kpId) async {
    final rows = await (_db.select(_db.homeworks)
          ..where((t) => t.kpId.equals(kpId) & t.deletedAt.isNull())
          // 二级排序带上 id：同秒写入 / 批量布置时 updatedAt 会撞车，
          // 缺这列会让列表顺序在两次打开之间跳动。
          ..orderBy([
            (t) => OrderingTerm.desc(t.updatedAt),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .get();
    return <Homework>[for (final r in rows) _fromRow(r)];
  }

  /// 按批量布置聚合键筛选（同 batch 的 N 行合并展示）。
  Future<List<Homework>> listByBatch(String batchId) async {
    final rows = await (_db.select(_db.homeworks)
          ..where((t) => t.batchId.equals(batchId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
    return <Homework>[for (final r in rows) _fromRow(r)];
  }

  /// 全量（忽略软删），按最近更新排序，供全局历史视图。
  Future<List<Homework>> listAll() async {
    final rows = await (_db.select(_db.homeworks)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
    return <Homework>[for (final r in rows) _fromRow(r)];
  }

  /// 更新作业状态（assigned / draft / done），并 bump 版本号。
  Future<void> updateStatus(String id, String status) async {
    final existing = await (_db.select(_db.homeworks)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    await (_db.update(_db.homeworks)..where((t) => t.id.equals(id)))
        .write(HomeworksCompanion(
      status: Value(status),
      updatedAt: Value(DateTime.now().toUtc()),
      version: Value((existing?.version ?? 0) + 1),
    ));
    // 上行记账：状态变更也要跨设备可见。
    await _sync.upsertHomework(id);
  }

  Homework _fromRow(HomeworkRow r) => Homework(
        id: r.id,
        canvasId: r.canvasId,
        title: r.title,
        kpIds: decodeKpIds(r.kpIdsJson),
        items: decodeHomeworkItems(r.itemsJson),
        updatedAt: r.updatedAt,
        kpId: r.kpId,
        batchId: r.batchId,
        status: r.status,
        dueAt: r.dueAt,
      );
}

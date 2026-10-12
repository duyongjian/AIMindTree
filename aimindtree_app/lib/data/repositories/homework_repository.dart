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

class HomeworkRepository {
  HomeworkRepository(this._db, {this.deviceId = ''});

  final AppDatabase _db;
  final String deviceId;

  static final AppLog _log = AppLog('homework_repo');

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
  }) async {
    try {
      final id = newUlid();
      await _db.into(_db.homeworks).insert(HomeworksCompanion(
            id: Value(id),
            canvasId: Value(canvasId),
            title: Value(title),
            kpIdsJson: Value(encodeKpIds(kpIds)),
            itemsJson: Value(encodeHomeworkItems(items)),
            updatedAt: Value(DateTime.now().toUtc()),
            version: const Value(1),
            deviceId: Value(deviceId),
          ));
      return Success(Homework(
        id: id,
        canvasId: canvasId,
        title: title,
        kpIds: kpIds,
        items: items,
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
        updatedAt: Value(DateTime.now().toUtc()),
        version: Value((existing?.version ?? 0) + 1),
      ));
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
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('删除作业失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  Homework _fromRow(HomeworkRow r) => Homework(
        id: r.id,
        canvasId: r.canvasId,
        title: r.title,
        kpIds: decodeKpIds(r.kpIdsJson),
        items: decodeHomeworkItems(r.itemsJson),
      );
}

/// 笔记文件夹（笔记本）仓储。
///
/// 提供文件夹的增删改查与置顶：
/// - [createFolder] / [listFolders] / [renameFolder] / [deleteFolder] / [pinFolder]
/// - 删除文件夹时，其下笔记**退回「未分类」**（notebook_id 置空并各自上行），
///   文件夹本身软删（墓碑），随同步传播——与笔记的删除口径一致。
///
/// 写操作统一走本仓储（§11：禁止 UI 直写表）；Outbox 追加在 T03 接入。
library;

import 'package:drift/drift.dart';

import '../../core/id.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../db/drift_database.dart';
import '../models/notebook.dart';
import '../sync/sync_outbox_writer.dart';

/// 笔记文件夹仓储。
class NotebookRepository {
  NotebookRepository(this._db, {this.deviceId = ''});

  final AppDatabase _db;
  final String deviceId;

  /// 底层库句柄（只读暴露，不新增写入入口）。
  AppDatabase get db => _db;

  static final AppLog _log = AppLog('notebook_repo');

  /// 上行同步写入器（把本地写登记进 outbox；未接线时自动跳过）。
  late final SyncOutboxWriter _sync = SyncOutboxWriter(_db);

  /// 新建文件夹（[parentId] 非空即成为某文件夹的子文件夹，构成层级）。
  Future<Result<Notebook>> createFolder({
    required String name,
    String? parentId,
    bool pinned = false,
  }) async {
    try {
      final now = DateTime.now().toUtc();
      final id = newUlid();
      await _db.into(_db.notebooks).insert(NotebooksCompanion(
            id: Value(id),
            name: Value(name),
            parentId: Value(parentId),
            sortOrder: const Value(0),
            pinned: Value(pinned),
            updatedAt: Value(now),
            version: const Value(1),
            deviceId: Value(deviceId),
          ));
      // 上行同步：新建 = 一条 upsert。
      await _sync.upsertNotebook(id);
      return Success(_rowToModel(
        await (_db.select(_db.notebooks)..where((t) => t.id.equals(id)))
            .getSingle(),
      ));
    } on Object catch (e, s) {
      _log.e('新建文件夹失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 列出未删除的文件夹：置顶优先，其次 sortOrder 升序，再次名称升序。
  ///
  /// UI 据此在内存里按 [parentId] 组装成树；置顶文件夹恒在同级最前。
  Future<Result<List<Notebook>>> listFolders() async {
    try {
      final rows = await (_db.select(_db.notebooks)
            ..where((t) => t.deletedAt.isNull())
            ..orderBy([
              (t) => OrderingTerm.desc(t.pinned),
              (t) => OrderingTerm.asc(t.sortOrder),
              (t) => OrderingTerm.asc(t.name),
            ]))
          .get();
      return Success(rows.map(_rowToModel).toList());
    } on Object catch (e, s) {
      _log.e('列出文件夹失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 重命名文件夹（version+1、updatedAt 刷新、上行同步）。
  Future<Result<Notebook>> renameFolder(String id, String name) async {
    try {
      final existing = await (_db.select(_db.notebooks)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (existing == null) return Failure(StateError('文件夹不存在'));
      final now = DateTime.now().toUtc();
      await (_db.update(_db.notebooks)..where((t) => t.id.equals(id))).write(
        NotebooksCompanion(
          name: Value(name),
          updatedAt: Value(now),
          version: Value(existing.version + 1),
        ),
      );
      await _sync.upsertNotebook(id);
      final updated = await (_db.select(_db.notebooks)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (updated == null) return Failure(StateError('重命名后读取失败'));
      return Success(_rowToModel(updated));
    } on Object catch (e, s) {
      _log.e('重命名文件夹失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 置顶 / 取消置顶文件夹（version+1、updatedAt 刷新、上行同步）。
  Future<Result<Notebook>> pinFolder(String id, bool pinned) async {
    try {
      final existing = await (_db.select(_db.notebooks)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (existing == null) return Failure(StateError('文件夹不存在'));
      final now = DateTime.now().toUtc();
      await (_db.update(_db.notebooks)..where((t) => t.id.equals(id))).write(
        NotebooksCompanion(
          pinned: Value(pinned),
          updatedAt: Value(now),
          version: Value(existing.version + 1),
        ),
      );
      await _sync.upsertNotebook(id);
      final updated = await (_db.select(_db.notebooks)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (updated == null) return Failure(StateError('置顶后读取失败'));
      return Success(_rowToModel(updated));
    } on Object catch (e, s) {
      _log.e('置顶文件夹失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 删除文件夹。
  ///
  /// 1. 其下未删笔记退回「未分类」（notebook_id 置空、version+1、各自上行）；
  /// 2. 文件夹本身软删（写 deleted_at、version+1、上行墓碑）。
  ///
  /// ⚠️ 子文件夹不级联删除：仅清掉直接归属的笔记，子文件夹的 parent_id 会指向
  /// 一个已删文件夹——UI 侧把「父不存在 / 父已删」视作根级展示。如需递归删除，
  /// 由调用方先递归处理子文件夹。
  Future<Result<void>> deleteFolder(String id) async {
    try {
      // 1) 直接归属的笔记退回未分类，并各自上行（让对端同步清掉归属）。
      final notes = await (_db.select(_db.notes)
            ..where((t) => t.notebookId.equals(id) & t.deletedAt.isNull()))
          .get();
      for (final n in notes) {
        await (_db.update(_db.notes)..where((t) => t.id.equals(n.id))).write(
          NotesCompanion(
            notebookId: const Value<String?>(null),
            updatedAt: Value(DateTime.now().toUtc()),
            version: Value(n.version + 1),
          ),
        );
        await _sync.upsertNote(n.id);
      }
      // 2) 文件夹软删（墓碑）。
      final existing = await (_db.select(_db.notebooks)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (existing == null) return const Success<void>(null);
      await (_db.update(_db.notebooks)..where((t) => t.id.equals(id))).write(
        NotebooksCompanion(
          deletedAt: Value(DateTime.now().toUtc()),
          updatedAt: Value(DateTime.now().toUtc()),
          version: Value(existing.version + 1),
        ),
      );
      await _sync.tombstoneNotebook(id);
      _log.i('删除文件夹 $id（其下 ${notes.length} 篇笔记退回未分类）');
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('删除文件夹失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  Notebook _rowToModel(NotebookRow r) => Notebook(
        id: r.id,
        name: r.name,
        parentId: r.parentId,
        sortOrder: r.sortOrder,
        pinned: r.pinned,
        updatedAt: r.updatedAt,
        version: r.version,
        deviceId: r.deviceId,
        deletedAt: r.deletedAt,
      );
}

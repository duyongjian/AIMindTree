/// 知识树仓储。
///
/// 承载「树」实体的 CRUD + 成员管理（哪些知识点被收进了哪棵树）。
///
/// 设计要点：
/// - 树 = `canvases` 表；成员 = `canvas_nodes`（target_type='kp'），
///   成员记录和它的画布坐标是**同一条**，所以「加入树」和「保存位置」都走
///   `insertOnConflictUpdate`，不会互相覆盖。
/// - 笔记树的 id **等于 noteId**，因此历史上按 noteId 存的位置数据无需迁移，
///   直接就是「这篇笔记的树」的成员。
library;

import 'package:drift/drift.dart';

import '../../core/logger.dart';
import '../../core/result.dart';
import '../db/drift_database.dart';
import '../models/knowledge_tree.dart';

class TreeRepository {
  TreeRepository(this._db, {this.deviceId = ''});

  final AppDatabase _db;
  final String deviceId;

  static final AppLog _log = AppLog('tree_repo');

  // ============ 查询 ============

  Future<List<KnowledgeTree>> listTrees() async {
    final rows = await _db.select(_db.canvases).get();
    return rows.map(_treeFromRow).toList();
  }

  Future<KnowledgeTree?> getTree(String id) async {
    final row = await (_db.select(_db.canvases)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _treeFromRow(row);
  }

  /// 某棵树里的知识点 id（成员）。
  Future<List<String>> memberPointIds(String treeId) async {
    final rows = await (_db.select(_db.canvasNodes)
          ..where((t) => t.canvasId.equals(treeId) & t.targetType.equals('kp')))
        .get();
    return rows.map((r) => r.targetId).toList();
  }

  /// 一批知识点分别落在哪些树里（删除笔记时用于弹窗提示影响范围）。
  ///
  /// 只统计仍然存在的树；成员记录指向已被删除的树时忽略。
  Future<List<TreeImpact>> treesContaining(List<String> kpIds) async {
    if (kpIds.isEmpty) return const <TreeImpact>[];
    final nodes = await (_db.select(_db.canvasNodes)
          ..where((t) => t.targetType.equals('kp') & t.targetId.isIn(kpIds)))
        .get();
    if (nodes.isEmpty) return const <TreeImpact>[];

    final known = {for (final t in await listTrees()) t.id: t.name};
    final counts = <String, int>{};
    for (final n in nodes) {
      if (!known.containsKey(n.canvasId)) continue;
      counts[n.canvasId] = (counts[n.canvasId] ?? 0) + 1;
    }
    return [
      for (final e in counts.entries)
        TreeImpact(
          treeId: e.key,
          treeName: known[e.key] ?? '(未命名知识树)',
          pointCount: e.value,
        ),
    ]..sort((a, b) => b.pointCount.compareTo(a.pointCount));
  }

  /// 某棵树里的知识点都来自哪些笔记（用于删除笔记时提示影响范围）。
  Future<List<String>> sourceNoteIdsOf(String treeId) async {
    final kpIds = await memberPointIds(treeId);
    if (kpIds.isEmpty) return const <String>[];
    final rows = await (_db.select(_db.knowledgePoints)
          ..where((t) => t.id.isIn(kpIds)))
        .get();
    return rows.map((r) => r.sourceNoteId).toSet().toList();
  }

  // ============ 树的写入 ============

  /// 新建一棵树。
  Future<Result<KnowledgeTree>> createTree(
    String name, {
    String? notebookId,
    String? fixedId,
  }) async {
    try {
      final tree = KnowledgeTree(
        id: fixedId,
        name: name,
        notebookId: notebookId,
      );
      await _db.into(_db.canvases).insert(CanvasesCompanion(
            id: Value(tree.id),
            notebookId: Value(notebookId),
            name: Value(name),
            updatedAt: Value(DateTime.now().toUtc()),
            version: const Value(1),
            deviceId: Value(deviceId),
          ));
      return Success(tree);
    } on Object catch (e, s) {
      _log.e('新建知识树失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 重命名。
  Future<Result<void>> renameTree(String id, String name) async {
    try {
      await (_db.update(_db.canvases)..where((t) => t.id.equals(id))).write(
        CanvasesCompanion(
          name: Value(name),
          updatedAt: Value(DateTime.now().toUtc()),
          version: const Value(1),
        ),
      );
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('重命名知识树失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 删除树：[deletePoints] 为 true 时连树里的知识点一起删，
  /// 否则只解除关系、知识点保留为独立资产。
  Future<Result<void>> deleteTree(String id, {bool deletePoints = false}) async {
    try {
      final kpIds = await memberPointIds(id);
      await (_db.delete(_db.canvasNodes)..where((t) => t.canvasId.equals(id)))
          .go();
      await (_db.delete(_db.canvases)..where((t) => t.id.equals(id))).go();
      if (deletePoints && kpIds.isNotEmpty) {
        await (_db.delete(_db.knowledgePoints)..where((t) => t.id.isIn(kpIds)))
            .go();
      }
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('删除知识树失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 确保某篇笔记有对应的「笔记树」（幂等）。
  ///
  /// 树的 id 用 noteId，这样历史位置数据（canvas_id = noteId）直接就是它的成员。
  Future<Result<KnowledgeTree>> ensureNoteTree({
    required String noteId,
    required String noteTitle,
    String? notebookId,
  }) async {
    final existing = await getTree(noteId);
    if (existing != null) return Success(existing);
    return createTree(
      noteTitle.isEmpty ? '未命名笔记' : noteTitle,
      notebookId: notebookId,
      fixedId: noteId,
    );
  }

  // ============ 成员管理 ============

  /// 把知识点收进某棵树（幂等：已在树里则跳过，不覆盖已有坐标）。
  Future<Result<int>> addPoints(String treeId, List<String> kpIds) async {
    var added = 0;
    try {
      final existing = (await memberPointIds(treeId)).toSet();
      for (final kpId in kpIds) {
        if (existing.contains(kpId)) continue;
        await _db.into(_db.canvasNodes).insert(CanvasNodesCompanion(
              id: Value('$treeId:$kpId'),
              canvasId: Value(treeId),
              targetType: const Value('kp'),
              targetId: Value(kpId),
              updatedAt: Value(DateTime.now().toUtc()),
              version: const Value(1),
              deviceId: Value(deviceId),
            ));
        existing.add(kpId);
        added++;
      }
      return Success(added);
    } on Object catch (e, s) {
      _log.e('知识点并入知识树失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 从某棵树里移除知识点（只解除关系，不删知识点本身）。
  Future<Result<void>> removePoints(String treeId, List<String> kpIds) async {
    if (kpIds.isEmpty) return const Success<void>(null);
    try {
      await (_db.delete(_db.canvasNodes)
            ..where((t) =>
                t.canvasId.equals(treeId) & t.targetId.isIn(kpIds)))
          .go();
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('从知识树移除知识点失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  KnowledgeTree _treeFromRow(CanvasRow r) => KnowledgeTree(
        id: r.id,
        name: r.name,
        notebookId: r.notebookId,
      );
}

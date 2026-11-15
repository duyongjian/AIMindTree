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

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/id.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../db/drift_database.dart';
import '../models/canvas_content.dart';
import '../models/knowledge_tree.dart';
import '../sync/sync_outbox_writer.dart';

class TreeRepository {
  TreeRepository(this._db, {this.deviceId = ''});

  final AppDatabase _db;
  final String deviceId;

  static final AppLog _log = AppLog('tree_repo');

  /// 上行同步写入器（把本地写登记进 outbox；未接线时自动跳过）。
  late final SyncOutboxWriter _sync = SyncOutboxWriter(_db);

  // ============ 查询 ============

  /// 列出所有知识树。
  ///
  /// tombstone 行（软删 / 同步删除标记，deletedAt 非空）不进列表——
  /// 软删铁律要求所有列表查询过滤（§11）。
  Future<List<KnowledgeTree>> listTrees() async {
    final rows = await (_db.select(_db.canvases)
          ..where((t) => t.deletedAt.isNull()))
        .get();
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
      await _sync.upsertCanvas(tree.id);
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
      await _sync.upsertCanvas(id);
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
      // 先留档被硬删的行（删完就没法取 id / version 了）。
      final removedNodes = await (_db.select(_db.canvasNodes)
            ..where((t) => t.canvasId.equals(id)))
          .get();
      final treeRow = await (_db.select(_db.canvases)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      final removedKps = (deletePoints && kpIds.isNotEmpty)
          ? await (_db.select(_db.knowledgePoints)..where((t) => t.id.isIn(kpIds)))
              .get()
          : <KnowledgePointRow>[];

      // 原子删除：三个本地删除要么都成功、要么都回滚，避免「树没了但节点/知识点
      // 残留」的部分删除态（之前无事务包裹，任一步失败都会留下脏数据）。
      await _db.transaction(() async {
        await (_db.delete(_db.canvasNodes)..where((t) => t.canvasId.equals(id)))
            .go();
        await (_db.delete(_db.canvases)..where((t) => t.id.equals(id))).go();
        if (deletePoints && kpIds.isNotEmpty) {
          await (_db.delete(_db.knowledgePoints)..where((t) => t.id.isIn(kpIds)))
              .go();
        }
      });
      // 上行同步：硬删的行逐个入队，让远端跟着删。
      await _sync.hardDeleteCanvasNodes(removedNodes);
      if (treeRow != null) {
        await _sync.hardDeleteCanvases(<CanvasRow>[treeRow]);
      }
      await _sync.hardDeleteKnowledgePoints(removedKps);
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
        final nodeId = '$treeId:$kpId';
        await _db.into(_db.canvasNodes).insert(CanvasNodesCompanion(
              id: Value(nodeId),
              canvasId: Value(treeId),
              targetType: const Value('kp'),
              targetId: Value(kpId),
              updatedAt: Value(DateTime.now().toUtc()),
              version: const Value(1),
              deviceId: Value(deviceId),
            ));
        existing.add(kpId);
        added++;
        await _sync.upsertCanvasNode(nodeId);
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
      // 先留档被摘下的成员行（硬删后行就没了，id / version 要提前取）。
      final removed = await (_db.select(_db.canvasNodes)
            ..where((t) =>
                t.canvasId.equals(treeId) & t.targetId.isIn(kpIds)))
          .get();
      await (_db.delete(_db.canvasNodes)
            ..where((t) =>
                t.canvasId.equals(treeId) & t.targetId.isIn(kpIds)))
          .go();
      await _sync.hardDeleteCanvasNodes(removed);
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

  // ============ 画布文本卡片（★2.0.0）============

  /// 从样式 JSON 里取卡片种类（`note_card` / `text_box`），缺省 `text_box`。
  static String _cardKind(String styleJson) {
    try {
      final m = jsonDecode(styleJson) as Map<String, dynamic>;
      final k = m['kind'];
      if (k == 'note_card' || k == 'text_box') return k as String;
    } on Object {
      // 忽略：解析失败按默认处理
    }
    return 'text_box';
  }

  /// 列出某画布上的全部文本卡片（内容 + 位置一起取回）。
  Future<List<CanvasCardVm>> listCards(String canvasId) async {
    final nodes = await (_db.select(_db.canvasNodes)
          ..where(
              (t) => t.canvasId.equals(canvasId) & t.targetType.equals('card')))
        .get();
    if (nodes.isEmpty) return const <CanvasCardVm>[];
    final cardIds = nodes.map((n) => n.targetId).toList();
    final cards = await (_db.select(_db.canvasCards)
          ..where((t) => t.id.isIn(cardIds)))
        .get();
    final byId = <String, CanvasCardRow>{for (final c in cards) c.id: c};
    final out = <CanvasCardVm>[];
    for (final n in nodes) {
      final c = byId[n.targetId];
      if (c == null) continue;
      out.add(CanvasCardVm(
        id: c.id,
        nodeId: n.id,
        x: n.x,
        y: n.y,
        w: n.w,
        h: n.h,
        noteId: c.noteId,
        title: c.title,
        body: c.body,
        kind: _cardKind(c.styleJson),
      ));
    }
    return out;
  }

  /// 在画布上创建一张文本卡片（同时插 `CanvasCards` + `CanvasNodes`）。
  ///
  /// 关联笔记时由调用方先取好标题/摘要再传入；这里只负责落库 + 登记同步。
  Future<Result<CanvasCardVm>> createCard(
    String canvasId,
    double x,
    double y,
    String kind, {
    String? noteId,
    String? title,
    String? body,
  }) async {
    try {
      final cardId = newUlid();
      final nodeId = '$canvasId:$cardId';
      await _db.batch((b) {
        b.insert(_db.canvasCards, CanvasCardsCompanion(
              id: Value(cardId),
              noteId: Value(noteId),
              title: Value(title ?? ''),
              body: Value(body ?? ''),
              styleJson: Value(jsonEncode(<String, dynamic>{'kind': kind})),
              updatedAt: Value(DateTime.now().toUtc()),
              version: const Value(1),
              deviceId: Value(deviceId),
            ));
        b.insert(_db.canvasNodes, CanvasNodesCompanion(
              id: Value(nodeId),
              canvasId: Value(canvasId),
              targetType: const Value('card'),
              targetId: Value(cardId),
              x: Value(x),
              y: Value(y),
              updatedAt: Value(DateTime.now().toUtc()),
              version: const Value(1),
              deviceId: Value(deviceId),
            ));
      });
      await _sync.upsertCanvasCard(cardId);
      await _sync.upsertCanvasNode(nodeId);
      return Success(CanvasCardVm(
        id: cardId,
        nodeId: nodeId,
        x: x,
        y: y,
        noteId: noteId,
        title: title ?? '',
        body: body ?? '',
        kind: kind,
      ));
    } on Object catch (e, s) {
      _log.e('创建画布卡片失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 更新卡片内容（标题 / 正文 / 关联笔记 / 种类）其一或其组合。
  Future<Result<void>> updateCard(
    String cardId, {
    String? title,
    String? body,
    String? noteId,
    String? kind,
  }) async {
    try {
      final existing = await (_db.select(_db.canvasCards)
            ..where((t) => t.id.equals(cardId)))
          .getSingleOrNull();
      if (existing == null) return const Success<void>(null);
      final nextKind = kind ?? _cardKind(existing.styleJson);
      await (_db.update(_db.canvasCards)..where((t) => t.id.equals(cardId)))
          .write(CanvasCardsCompanion(
        title: Value(title ?? existing.title),
        body: Value(body ?? existing.body),
        noteId: Value(noteId ?? existing.noteId),
        styleJson: Value(jsonEncode(<String, dynamic>{'kind': nextKind})),
        updatedAt: Value(DateTime.now().toUtc()),
        version: const Value(1),
      ));
      await _sync.upsertCanvasCard(cardId);
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('更新画布卡片失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 删除卡片：内容行 + 其 `CanvasNodes` 行一起物理删，二者都登记同步。
  Future<Result<void>> deleteCard(String cardId) async {
    try {
      final card = await (_db.select(_db.canvasCards)
            ..where((t) => t.id.equals(cardId)))
          .getSingleOrNull();
      if (card == null) return const Success<void>(null);
      final node = await (_db.select(_db.canvasNodes)
            ..where((t) =>
                t.targetType.equals('card') & t.targetId.equals(cardId)))
          .getSingleOrNull();
      await (_db.delete(_db.canvasCards)..where((t) => t.id.equals(cardId)))
          .go();
      if (node != null) {
        await (_db.delete(_db.canvasNodes)..where((t) => t.id.equals(node.id)))
            .go();
      }
      await _sync.hardDeleteCanvasCards(<CanvasCardRow>[card]);
      if (node != null) {
        await _sync.hardDeleteCanvasNodes(<CanvasNodeRow>[node]);
      }
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('删除画布卡片失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 移动卡片位置（更新其 `CanvasNodes` 行；target_type 保持 'card'）。
  ///
  /// 不能复用 [KnowledgeRepository.saveNodePosition]，后者会把 target_type 写死成
  /// 'kp'，会把卡片节点覆盖成知识点节点而破坏卡片。这里按 nodeId 直接改 x/y。
  Future<Result<void>> moveCard(
    String canvasId,
    String cardId,
    double x,
    double y,
  ) async {
    final nodeId = '$canvasId:$cardId';
    try {
      final existing = await (_db.select(_db.canvasNodes)
            ..where((t) => t.id.equals(nodeId)))
          .getSingleOrNull();
      await (_db.update(_db.canvasNodes)..where((t) => t.id.equals(nodeId)))
          .write(CanvasNodesCompanion(
        x: Value(x),
        y: Value(y),
        pinned: const Value(true),
        updatedAt: Value(DateTime.now().toUtc()),
        version: Value((existing?.version ?? 0) + 1),
      ));
      await _sync.upsertCanvasNode(nodeId);
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('移动画布卡片失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  // ============ 画布手写笔迹（★2.0.0）============

  /// 画布坐标点序列 ↔ JSON 互转（drift 只能存字符串）。
  static List<({double x, double y})> _decodePoints(String json) {
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return <({double x, double y})>[
        for (final e in list)
          if (e is Map)
            (
              x: (e['x'] as num?)?.toDouble() ?? 0,
              y: (e['y'] as num?)?.toDouble() ?? 0,
            ),
      ];
    } on Object {
      return const [];
    }
  }

  static String _encodePoints(List<({double x, double y})> pts) =>
      jsonEncode(<Map<String, dynamic>>[
        for (final p in pts) <String, dynamic>{'x': p.x, 'y': p.y},
      ]);

  static CanvasStrokeVm _strokeVmFromRow(CanvasStrokeRow r) => CanvasStrokeVm(
        id: r.id,
        canvasId: r.canvasId,
        points: _decodePoints(r.pointsJson),
        color: r.color,
        width: r.width,
      );

  /// 列出某画布上的全部笔迹。
  Future<List<CanvasStrokeVm>> listStrokes(String canvasId) async {
    final rows = await (_db.select(_db.canvasStrokes)
          ..where((t) => t.canvasId.equals(canvasId)))
        .get();
    return rows.map(_strokeVmFromRow).toList();
  }

  /// 新增一条笔迹（落库 + 登记同步）。
  Future<Result<CanvasStrokeVm>> addStroke(
    String canvasId,
    List<({double x, double y})> points,
    String color,
    double width,
  ) async {
    try {
      final id = newUlid();
      await _db.into(_db.canvasStrokes).insert(CanvasStrokesCompanion(
            id: Value(id),
            canvasId: Value(canvasId),
            pointsJson: Value(_encodePoints(points)),
            color: Value(color),
            width: Value(width),
            updatedAt: Value(DateTime.now().toUtc()),
            version: const Value(1),
            deviceId: Value(deviceId),
          ));
      await _sync.upsertCanvasStroke(id);
      return Success(CanvasStrokeVm(
        id: id,
        canvasId: canvasId,
        points: points,
        color: color,
        width: width,
      ));
    } on Object catch (e, s) {
      _log.e('新增笔迹失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 删除一条笔迹（橡皮整笔擦除）。
  Future<Result<void>> deleteStroke(String strokeId) async {
    try {
      final row = await (_db.select(_db.canvasStrokes)
            ..where((t) => t.id.equals(strokeId)))
          .getSingleOrNull();
      if (row == null) return const Success<void>(null);
      await (_db.delete(_db.canvasStrokes)..where((t) => t.id.equals(strokeId)))
          .go();
      await _sync.hardDeleteCanvasStrokes(<CanvasStrokeRow>[row]);
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('删除笔迹失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }
}

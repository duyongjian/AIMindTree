/// 上行同步接线：把「本地写完的行最终态」登记进 outbox（T03）。
///
/// 仓储层写完本地库后调用本文件的方法：
/// - `upsertXxx(id)`：行被写入/更新 → payload = 行的最终态（读回实体的真实
///   列值，键名见 `sync_row_map.dart`，与 `sync_engine` 的 `*FromMap` 严格一致）；
/// - `tombstoneXxx(id)`：行被软删（墓碑）→ payload = 墓碑时间；
/// - `hardDeleteXxx(rows)`：行被物理删除 → payload = 删除时刻。
///
/// 全局接线点是 [SyncOutboxRepo.current]：
/// - 生产环境在 `ExtractionService.bootstrap` 里赋值 → 写仓储就自动入队；
/// - 单测默认 `null` → 本文件的调用全部静默跳过（不入队、也不崩）。
///
/// **入队失败不影响业务写入**：outbox 是「写成功后记账」的旁路，
/// 记账失败只记日志（否则会出现「数据写成功了但业务返回失败」的假象）。
library;

import '../../core/logger.dart';
import '../db/drift_database.dart';
import 'sync_outbox.dart';
import 'sync_row_map.dart';
import 'sync_types.dart';

/// 表感知的上行同步写入器。
///
/// 持有 [AppDatabase]（读回刚写好的行），把行最终态登记进
/// [SyncOutboxRepo.current] 指向的 outbox。
///
/// ⚠️ 接线约束：`SyncOutboxRepo.current` 必须与本写入器共用**同一个**
/// [AppDatabase] 实例（生产环境由 bootstrap 保证）。若不是同一个库，
/// 本写入器会跳过入队并记一条 warning——宁可不同步，也不能把 outbox 行
/// 写进另一个库（那会造成「实体在 A 库、发件箱在 B 库」的静默错位）。
class SyncOutboxWriter {
  SyncOutboxWriter(this._db);

  final AppDatabase _db;

  static final AppLog _log = AppLog('sync_outbox_writer');

  // ============ upsert（行最终态）============

  /// 笔记 upsert。
  Future<void> upsertNote(String id) => _upsert(
        table: 'notes',
        id: id,
        load: () => (_db.select(_db.notes)..where((t) => t.id.equals(id)))
            .getSingleOrNull(),
        toMap: noteRowToMap,
      );

  /// 知识点 upsert。
  Future<void> upsertKnowledgePoint(String id) => _upsert(
        table: 'knowledge_points',
        id: id,
        load: () =>
            (_db.select(_db.knowledgePoints)..where((t) => t.id.equals(id)))
                .getSingleOrNull(),
        toMap: knowledgePointRowToMap,
      );

  /// 前置关系边 upsert。
  Future<void> upsertPrerequisiteEdge(String id) => _upsert(
        table: 'prerequisite_edges',
        id: id,
        load: () => (_db.select(_db.prerequisiteEdges)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull(),
        toMap: prerequisiteEdgeRowToMap,
      );

  /// 掌握记录 upsert（append-only：每次写入都是一个新 id 的新行）。
  Future<void> upsertMasteryRecord(String id) => _upsert(
        table: 'mastery_records',
        id: id,
        load: () => (_db.select(_db.masteryRecords)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull(),
        toMap: masteryRecordRowToMap,
      );

  /// 知识树（画布）upsert。
  Future<void> upsertCanvas(String id) => _upsert(
        table: 'canvases',
        id: id,
        load: () =>
            (_db.select(_db.canvases)..where((t) => t.id.equals(id)))
                .getSingleOrNull(),
        toMap: canvasRowToMap,
      );

  /// 画布节点 upsert（树成员 / 坐标）。
  Future<void> upsertCanvasNode(String id) => _upsert(
        table: 'canvas_nodes',
        id: id,
        load: () => (_db.select(_db.canvasNodes)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull(),
        toMap: canvasNodeRowToMap,
      );

  /// 画布自由文本卡片 upsert（★2.0.0：笔记卡片 / 透明文本框）。
  Future<void> upsertCanvasCard(String id) => _upsert(
        table: 'canvas_cards',
        id: id,
        load: () => (_db.select(_db.canvasCards)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull(),
        toMap: canvasCardRowToMap,
      );

  /// 画布手写笔迹 upsert（★2.0.0：圆珠笔 + 橡皮）。
  Future<void> upsertCanvasStroke(String id) => _upsert(
        table: 'canvas_strokes',
        id: id,
        load: () => (_db.select(_db.canvasStrokes)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull(),
        toMap: canvasStrokeRowToMap,
      );

  /// AI 会话 upsert。
  Future<void> upsertAiSession(String id) => _upsert(
        table: 'ai_sessions',
        id: id,
        load: () => (_db.select(_db.aiSessions)..where((t) => t.id.equals(id)))
            .getSingleOrNull(),
        toMap: aiSessionRowToMap,
      );

  /// AI 消息 upsert。
  Future<void> upsertAiMessage(String id) => _upsert(
        table: 'ai_messages',
        id: id,
        load: () => (_db.select(_db.aiMessages)..where((t) => t.id.equals(id)))
            .getSingleOrNull(),
        toMap: aiMessageRowToMap,
      );

  /// 知识点分组 upsert（kp_groups）。
  ///
  /// ⚠️ `members_json` 是整段成员 JSON 字符串，同步层原样搬运、不解析。
  Future<void> upsertKpGroup(String id) => _upsert(
        table: 'kp_groups',
        id: id,
        load: () =>
            (_db.select(_db.kpGroups)..where((t) => t.id.equals(id)))
                .getSingleOrNull(),
        toMap: kpGroupRowToMap,
      );

  /// 笔记附件 upsert（note_assets）。
  ///
  /// payload 里含整段 `data_base64`，可达数 MB；push 侧有字节预算切批，
  /// 这里不额外做体积限制（入库时的上限校验归仓储层）。
  Future<void> upsertNoteAsset(String id) => _upsert(
        table: 'note_assets',
        id: id,
        load: () => (_db.select(_db.noteAssets)..where((t) => t.id.equals(id)))
            .getSingleOrNull(),
        toMap: noteAssetRowToMap,
      );

  // ============ 软删（墓碑）============

  /// 笔记墓碑（软删：行仍在本地，deleted_at 非空）。
  Future<void> tombstoneNote(String id) => _tombstone(
        table: 'notes',
        id: id,
        load: () =>
            (_db.select(_db.notes)..where((t) => t.id.equals(id)))
                .getSingleOrNull(),
        toMap: noteRowToMap,
      );

  /// 知识点墓碑（软删：行仍在本地，deleted_at 非空）。
  Future<void> tombstoneKnowledgePoint(String id) => _tombstone(
        table: 'knowledge_points',
        id: id,
        load: () =>
            (_db.select(_db.knowledgePoints)..where((t) => t.id.equals(id)))
                .getSingleOrNull(),
        toMap: knowledgePointRowToMap,
      );

  /// 知识点分组墓碑（软删：行仍在本地，deleted_at 非空）。
  ///
  /// ⚠️ 删组**不解散成员**：组内知识点只是回到未分组，绝不能连知识点一起删。
  Future<void> tombstoneKpGroup(String id) => _tombstone(
        table: 'kp_groups',
        id: id,
        load: () =>
            (_db.select(_db.kpGroups)..where((t) => t.id.equals(id)))
                .getSingleOrNull(),
        toMap: kpGroupRowToMap,
      );

  /// 笔记附件墓碑（软删：行仍在本地，deleted_at 非空）。
  Future<void> tombstoneNoteAsset(String id) => _tombstone(
        table: 'note_assets',
        id: id,
        load: () => (_db.select(_db.noteAssets)..where((t) => t.id.equals(id)))
            .getSingleOrNull(),
        toMap: noteAssetRowToMap,
      );

  // ============ 硬删（行已从本地消失）============

  /// 前置关系边硬删。
  Future<void> hardDeletePrerequisiteEdges(Iterable<PrerequisiteEdgeRow> rows) =>
      _hardDelete(table: 'prerequisite_edges', rows: rows, toMap: prerequisiteEdgeRowToMap);

  /// 掌握记录硬删。
  Future<void> hardDeleteMasteryRecords(Iterable<MasteryRecordRow> rows) =>
      _hardDelete(table: 'mastery_records', rows: rows, toMap: masteryRecordRowToMap);

  /// 画布节点硬删（成员关系解除 / 树被删）。
  Future<void> hardDeleteCanvasNodes(Iterable<CanvasNodeRow> rows) =>
      _hardDelete(table: 'canvas_nodes', rows: rows, toMap: canvasNodeRowToMap);

  /// 画布自由文本卡片硬删（★2.0.0）。卡片内容随卡片节点一起被删。
  Future<void> hardDeleteCanvasCards(Iterable<CanvasCardRow> rows) =>
      _hardDelete(table: 'canvas_cards', rows: rows, toMap: canvasCardRowToMap);

  /// 画布手写笔迹硬删（★2.0.0：橡皮整笔擦除 / 画布清空）。
  Future<void> hardDeleteCanvasStrokes(Iterable<CanvasStrokeRow> rows) =>
      _hardDelete(table: 'canvas_strokes', rows: rows, toMap: canvasStrokeRowToMap);

  /// 知识树（画布）硬删。
  Future<void> hardDeleteCanvases(Iterable<CanvasRow> rows) =>
      _hardDelete(table: 'canvases', rows: rows, toMap: canvasRowToMap);

  /// 知识点硬删。
  Future<void> hardDeleteKnowledgePoints(Iterable<KnowledgePointRow> rows) =>
      _hardDelete(table: 'knowledge_points', rows: rows, toMap: knowledgePointRowToMap);

  /// 笔记附件硬删（笔记被物理删除时，附件跟着一起走）。
  Future<void> hardDeleteNoteAssets(Iterable<NoteAssetRow> rows) =>
      _hardDelete(table: 'note_assets', rows: rows, toMap: noteAssetRowToMap);

  // ============ 内部实现 ============

  /// 取出当前接线点；未接线或库不匹配时返回 null（= 本次不入队）。
  SyncOutboxRepo? _outbox() {
    final outbox = SyncOutboxRepo.current;
    if (outbox == null) return null;
    if (!identical(outbox.db, _db)) {
      _log.w('outbox 与仓储不在同一个库，跳过入队（避免实体与发件箱错位）');
      return null;
    }
    return outbox;
  }

  /// upsert 入队：payload = 刚写完那一行的最终态。
  Future<void> _upsert<T>({
    required String table,
    required String id,
    required Future<T?> Function() load,
    required Map<String, dynamic> Function(T row) toMap,
  }) async {
    final outbox = _outbox();
    if (outbox == null) return;
    try {
      final row = await load();
      if (row == null) return;
      final payload = toMap(row);
      await outbox.enqueue(
        entityTable: table,
        entityId: payload['id'] as String,
        op: SyncOp.upsert,
        payload: payload,
        // baseVersion = 写完之后该行的 version（服务端按它做 LWW 落地）。
        baseVersion: (payload['version'] as num?)?.toInt() ?? 1,
      );
    } on Object catch (e, s) {
      _log.e('upsert 入队失败：$table/$id', error: e, stackTrace: s);
    }
  }

  /// 墓碑入队：payload 只带 `deleted_at`（传输层的 deletedAt 就是从它取的）。
  Future<void> _tombstone<T>({
    required String table,
    required String id,
    required Future<T?> Function() load,
    required Map<String, dynamic> Function(T row) toMap,
  }) async {
    final outbox = _outbox();
    if (outbox == null) return;
    try {
      final row = await load();
      if (row == null) return;
      final payload = toMap(row);
      await outbox.enqueue(
        entityTable: table,
        entityId: payload['id'] as String,
        op: SyncOp.delete,
        payload: <String, dynamic>{
          'deleted_at': (payload['deleted_at'] as DateTime?) ?? DateTime.now().toUtc(),
        },
        baseVersion: (payload['version'] as num?)?.toInt() ?? 1,
      );
    } on Object catch (e, s) {
      _log.e('墓碑入队失败：$table/$id', error: e, stackTrace: s);
    }
  }

  /// 硬删入队：行已不存在，墓碑时间取删除时刻，version 取删除前那一行的值。
  Future<void> _hardDelete<T>({
    required String table,
    required Iterable<T> rows,
    required Map<String, dynamic> Function(T row) toMap,
  }) async {
    final outbox = _outbox();
    if (outbox == null) return;
    if (rows.isEmpty) return;
    final deletedAt = DateTime.now().toUtc();
    try {
      for (final row in rows) {
        final payload = toMap(row);
        await outbox.enqueue(
          entityTable: table,
          entityId: payload['id'] as String,
          op: SyncOp.delete,
          payload: <String, dynamic>{'deleted_at': deletedAt},
          baseVersion: (payload['version'] as num?)?.toInt() ?? 1,
        );
      }
    } on Object catch (e, s) {
      _log.e('硬删入队失败：$table', error: e, stackTrace: s);
    }
  }
}

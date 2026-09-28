/// SyncEngine（T03 核心）：push / pull / merge / LWW。
///
/// 推送：读 outbox pending → 批量走 SyncApi → markPushed / markFailed
/// 拉取：走 SyncApi.pullSince → 自回声过滤 → 逐行 LWW merge → 更新 last_pulled_at
///
/// 表覆盖范围（P1 已完成 11 张带 SyncMeta 的表）：
/// notebooks / notes / knowledge_points / prerequisite_edges / mastery_records /
/// cards / canvases / canvas_nodes / canvas_edges / ai_sessions / ai_messages。
///
/// 故意不同步 2 张：`ai_providers`（密钥引用本地化，跨设备命名空间不一致）、
/// `ai_task_routes`（依赖 ai_providers，单独同步无意义）。
/// 将来要同步它们需先加 SyncMeta mixin + schemaVersion=2 迁移。
///
/// LWW 规则（MEMORY.md "Append-only 排序陷阱" 同源）：
/// - `remote.baseVersion > local.version` → apply remote；
/// - `remote.baseVersion < local.version` → keep local；
/// - `==` 时看 `updated_at`：remote 更晚则 apply；
/// - `remote.deletedAt != null` → 硬删除本地对应行；
/// - `remote.deviceId == 本地 deviceId` → 跳过（自回声）。
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/logger.dart';
import '../db/drift_database.dart';
import 'sync_api.dart';
import 'sync_outbox.dart';
import 'sync_types.dart';

/// 推送结果。
class PushReport {
  const PushReport({
    required this.pushed,
    required this.failed,
    required this.serverTime,
  });
  final int pushed;
  final int failed;
  final DateTime serverTime;
}

/// 拉取结果。
class PullReport {
  const PullReport({
    required this.applied,
    required this.skipped,
    required this.serverTime,
  });
  final int applied;
  final int skipped;
  final DateTime serverTime;
}

class SyncEngine {
SyncEngine({
    required this._db,
    required this._api,
    required this._outbox,
    required this.deviceId,
  });

  /// 手动设置起始 last_pulled_at（持久化恢复用）。
  void bootstrapLastPulledAt(DateTime? t) {
    _lastPulledAt = t;
  }

  final AppDatabase _db;
  final SyncApi _api;
  final SyncOutboxRepo _outbox;
  final String deviceId;

  static final AppLog _log = AppLog('sync_engine');

  DateTime? _lastPulledAt;
  DateTime? get lastPulledAt => _lastPulledAt;

  // ============ Push ============

  /// 推送 outbox pending → 成功 done / 失败 failed。
  ///
  /// [limit] 单批上限；[includeFailed] 是否同时拉 failed 重试。
  Future<PushReport> push({
    int limit = 100,
    bool includeFailed = true,
  }) async {
    final pending = await _outbox.pending(limit: limit);
    final failed = includeFailed
        ? await _outbox.failedPending(limit: limit - pending.length)
        : <SyncOutboxRow>[];
    final rows = [...pending, ...failed];
    if (rows.isEmpty) {
      return PushReport(pushed: 0, failed: 0, serverTime: _epoch);
    }

    final ids = rows.map((r) => r.id).toList();
    await _outbox.markSending(ids);

    final envelopes = <SyncEnvelope>[];
    final idToRow = <int, SyncOutboxRow>{};
    for (final r in rows) {
      idToRow[r.id] = r;
      envelopes.add(SyncEnvelope(
        deviceId: r.deviceId,
        entityTable: r.entityTable,
        entityId: r.entityId,
        op: SyncOp.parse(r.op),
        payload: _decodePayload(r.payloadJson),
        baseVersion: r.baseVersion,
        updatedAt: r.createdAt, // 简化：用 outbox 创建时间（行真正 updatedAt 在 payload 里）
        deletedAt: _extractDeletedAt(r.entityTable, r.payloadJson),
      ));
    }

    try {
      final result = await _api.pushBatch(envelopes);
      await _outbox.markPushed(ids);
      _log.i('push 成功 ${result.accepted} 条；server_time=${result.serverTime}');
      return PushReport(
        pushed: result.accepted,
        failed: 0,
        serverTime: result.serverTime,
      );
    } on Object catch (e) {
      _log.w('push 失败：$e；${ids.length} 条回到 failed');
      await _outbox.markFailed(ids);
      return PushReport(pushed: 0, failed: ids.length, serverTime: DateTime.now().toUtc());
    }
  }

  // ============ Pull ============

  /// 拉取 since [lastPulledAt]（首次为 null = 全量）→ 自回声过滤 → LWW merge。
  Future<PullReport> pull() async {
    final result = await _api.pullSince(_lastPulledAt);
    var applied = 0;
    var skipped = 0;
    for (final env in result.envelopes) {
      // 自回声：本机产生的变更不需要再次 merge（外层 push 已经应用）
      if (env.deviceId == deviceId) {
        skipped++;
        continue;
      }
      await _merge(env);
      applied++;
    }
    _lastPulledAt = result.serverTime;
    _log.i('pull applied=$applied skipped=$skipped server_time=${result.serverTime}');
    return PullReport(
      applied: applied,
      skipped: skipped,
      serverTime: result.serverTime,
    );
  }

  /// 外部更新 last_pulled_at（例如从持久化恢复）。
  void updateLastPulledAt(DateTime t) {
    _lastPulledAt = t;
  }

  // ============ Merge（LWW）============
  //
  // 决策表（local=null 视为 version=0 / deletedAt=null）：
  // ┌─────────────────────────────┬────────────────────────┐
  // │ remote vs local             │ 结果                    │
  // ├─────────────────────────────┼────────────────────────┤
  // │ remote.deletedAt != null    │ 本地硬删除该行          │
  // │ remote.baseVersion > local  │ apply remote            │
  // │ remote.baseVersion < local  │ keep local              │
  // │ ==                          │ remote.updatedAt 晚则 apply │
  // └─────────────────────────────┴────────────────────────┘

  Future<void> _merge(SyncEnvelope env) async {
    final local = await _readLocalVersion(env.entityTable, env.entityId);
    if (env.deletedAt != null) {
      // tombstone：硬删本地
      await _deleteLocal(env.entityTable, env.entityId);
      return;
    }
    if (local == null) {
      // 本地无记录，直接 apply
      await _applyInsert(env);
      return;
    }
    final cmp = _compare(env, local);
    if (cmp > 0) {
      await _applyUpdate(env);
    } else {
      _log.d('LWW keep local：${env.entityTable}/${env.entityId}');
    }
  }

  /// 返回 -1 / 0 / 1：remote vs local。
  int _compare(SyncEnvelope env, _LocalVer local) {
    if (env.baseVersion > local.version) return 1;
    if (env.baseVersion < local.version) return -1;
    // baseVersion 相等 → 看时间
    return env.updatedAt.isAfter(local.updatedAt) ? 1 : -1;
  }

  // ============ 表适配 ============

  /// 读本地 (table, id) 的当前 version + updatedAt；不存在返回 null。
  Future<_LocalVer?> _readLocalVersion(String table, String id) async {
    final row = await _readLocalRow(table, id);
    if (row == null) return null;
    return _LocalVer(
      version: (row['version'] as num?)?.toInt() ?? 0,
      updatedAt: row['updated_at'] as DateTime,
    );
  }

  Future<Map<String, dynamic>?> _readLocalRow(String table, String id) async {
    switch (table) {
      case 'notebooks':
        final r = await (_db.select(_db.notebooks)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : _notebookToMap(r);
      case 'notes':
        final r = await (_db.select(_db.notes)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : _noteToMap(r);
      case 'knowledge_points':
        final r = await (_db.select(_db.knowledgePoints)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : _kpToMap(r);
      case 'prerequisite_edges':
        final r = await (_db.select(_db.prerequisiteEdges)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : _edgeToMap(r);
      case 'mastery_records':
        final r = await (_db.select(_db.masteryRecords)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : _masteryToMap(r);
      case 'cards':
        final r = await (_db.select(_db.cards)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : _cardToMap(r);
      case 'canvases':
        final r = await (_db.select(_db.canvases)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : _canvasToMap(r);
      case 'canvas_nodes':
        final r = await (_db.select(_db.canvasNodes)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : _canvasNodeToMap(r);
      case 'canvas_edges':
        final r = await (_db.select(_db.canvasEdges)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : _canvasEdgeToMap(r);
      case 'ai_sessions':
        final r = await (_db.select(_db.aiSessions)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : _aiSessionToMap(r);
      case 'ai_messages':
        final r = await (_db.select(_db.aiMessages)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : _aiMessageToMap(r);
      default:
        _log.w('未知表 $table，跳过读 local');
        return null;
    }
  }

  Future<void> _applyInsert(SyncEnvelope env) async {
    final payload = env.payload;
    if (payload == null) {
      _log.w('insert 收到 null payload：${env.entityTable}/${env.entityId}');
      return;
    }
    await _upsertLocal(env.entityTable, _hydrate(env, payload));
  }

  Future<void> _applyUpdate(SyncEnvelope env) async {
    final payload = env.payload;
    if (payload == null) return;
    // 先删后插（简化；保留 P0 语义；后续可改 drift into insertOnConflictUpdate）
    await _deleteLocal(env.entityTable, env.entityId);
    await _upsertLocal(env.entityTable, _hydrate(env, payload));
  }

  /// 把 envelope 的 updatedAt / version 注入到 payload（让下游 fromMap
  /// 不用再做缺失 fallback）。
  ///
  /// baseVersion 的语义：远端在 push 时把该行的**目标 version** 装进
  /// envelope（不是前置 version），pull 时直接落地为本地 version。
  Map<String, dynamic> _hydrate(SyncEnvelope env, Map<String, dynamic> p) {
    return {
      ...p,
      'updated_at': env.updatedAt,
      'version': env.baseVersion,
      'device_id': env.deviceId,
    };
  }

  Future<void> _upsertLocal(String table, Map<String, dynamic> p) async {
    switch (table) {
      case 'notebooks':
        await _db.into(_db.notebooks).insert(_notebookFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      case 'notes':
        await _db.into(_db.notes).insert(_noteFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      case 'knowledge_points':
        await _db.into(_db.knowledgePoints).insert(_kpFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      case 'prerequisite_edges':
        await _db.into(_db.prerequisiteEdges).insert(_edgeFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      case 'mastery_records':
        await _db.into(_db.masteryRecords).insert(_masteryFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      case 'cards':
        await _db.into(_db.cards).insert(_cardFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      case 'canvases':
        await _db.into(_db.canvases).insert(_canvasFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      case 'canvas_nodes':
        await _db.into(_db.canvasNodes).insert(_canvasNodeFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      case 'canvas_edges':
        await _db.into(_db.canvasEdges).insert(_canvasEdgeFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      case 'ai_sessions':
        await _db.into(_db.aiSessions).insert(_aiSessionFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      case 'ai_messages':
        await _db.into(_db.aiMessages).insert(_aiMessageFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      default:
        _log.w('未知表 $table，跳过 insert');
    }
  }

  Future<void> _deleteLocal(String table, String id) async {
    switch (table) {
      case 'notebooks':
        await (_db.delete(_db.notebooks)..where((t) => t.id.equals(id))).go();
        break;
      case 'notes':
        await (_db.delete(_db.notes)..where((t) => t.id.equals(id))).go();
        break;
      case 'knowledge_points':
        await (_db.delete(_db.knowledgePoints)..where((t) => t.id.equals(id))).go();
        break;
      case 'prerequisite_edges':
        await (_db.delete(_db.prerequisiteEdges)..where((t) => t.id.equals(id))).go();
        break;
      case 'mastery_records':
        await (_db.delete(_db.masteryRecords)..where((t) => t.id.equals(id))).go();
        break;
      case 'cards':
        await (_db.delete(_db.cards)..where((t) => t.id.equals(id))).go();
        break;
      case 'canvases':
        await (_db.delete(_db.canvases)..where((t) => t.id.equals(id))).go();
        break;
      case 'canvas_nodes':
        await (_db.delete(_db.canvasNodes)..where((t) => t.id.equals(id))).go();
        break;
      case 'canvas_edges':
        await (_db.delete(_db.canvasEdges)..where((t) => t.id.equals(id))).go();
        break;
      case 'ai_sessions':
        await (_db.delete(_db.aiSessions)..where((t) => t.id.equals(id))).go();
        break;
      case 'ai_messages':
        await (_db.delete(_db.aiMessages)..where((t) => t.id.equals(id))).go();
        break;
      default:
        _log.w('未知表 $table，跳过 delete');
    }
  }

  // ============ Row ↔ Map 适配 ============

  Map<String, dynamic> _notebookToMap(NotebookRow r) => {
        'id': r.id,
        'name': r.name,
        'parent_id': r.parentId,
        'sort_order': r.sortOrder,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };

  NotebooksCompanion _notebookFromMap(Map<String, dynamic> p) => NotebooksCompanion(
        id: Value(p['id'] as String),
        name: Value((p['name'] as String?) ?? ''),
        parentId: Value(p['parent_id'] as String?),
        sortOrder: Value((p['sort_order'] as num?)?.toInt() ?? 0),
        updatedAt: Value(p['updated_at'] as DateTime),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(p['deleted_at'] as DateTime?),
      );

  Map<String, dynamic> _noteToMap(NoteRow r) => {
        'id': r.id,
        'notebook_id': r.notebookId,
        'title': r.title,
        'content_md': r.contentMd,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };

  NotesCompanion _noteFromMap(Map<String, dynamic> p) => NotesCompanion(
        id: Value(p['id'] as String),
        notebookId: Value(p['notebook_id'] as String?),
        title: Value((p['title'] as String?) ?? ''),
        contentMd: Value((p['content_md'] as String?) ?? ''),
        updatedAt: Value(p['updated_at'] as DateTime),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(p['deleted_at'] as DateTime?),
      );

  Map<String, dynamic> _kpToMap(KnowledgePointRow r) => {
        'id': r.id,
        'notebook_id': r.notebookId,
        'name': r.name,
        'type': r.type,
        'definition': r.definition,
        'source_note_id': r.sourceNoteId,
        'source_start': r.sourceStart,
        'source_end': r.sourceEnd,
        'source_quote': r.sourceQuote,
        'origin': r.origin,
        'confidence': r.confidence,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };

  KnowledgePointsCompanion _kpFromMap(Map<String, dynamic> p) =>
      KnowledgePointsCompanion(
        id: Value(p['id'] as String),
        notebookId: Value(p['notebook_id'] as String?),
        name: Value((p['name'] as String?) ?? ''),
        type: Value((p['type'] as String?) ?? 'concept'),
        definition: Value((p['definition'] as String?) ?? ''),
        sourceNoteId: Value((p['source_note_id'] as String?) ?? ''),
        sourceStart: Value((p['source_start'] as num?)?.toInt() ?? 0),
        sourceEnd: Value((p['source_end'] as num?)?.toInt() ?? 0),
        sourceQuote: Value((p['source_quote'] as String?) ?? ''),
        origin: Value((p['origin'] as String?) ?? 'ai_extract'),
        confidence: Value((p['confidence'] as num?)?.toDouble() ?? 0),
        updatedAt: Value(p['updated_at'] as DateTime),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(p['deleted_at'] as DateTime?),
      );

  Map<String, dynamic> _edgeToMap(PrerequisiteEdgeRow r) => {
        'id': r.id,
        'from_kp_id': r.fromKpId,
        'to_kp_id': r.toKpId,
        'reason': r.reason,
        'origin': r.origin,
        'confidence': r.confidence,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };

  PrerequisiteEdgesCompanion _edgeFromMap(Map<String, dynamic> p) =>
      PrerequisiteEdgesCompanion(
        id: Value(p['id'] as String),
        fromKpId: Value(p['from_kp_id'] as String),
        toKpId: Value(p['to_kp_id'] as String),
        reason: Value((p['reason'] as String?) ?? ''),
        origin: Value((p['origin'] as String?) ?? 'ai'),
        confidence: Value((p['confidence'] as num?)?.toDouble() ?? 0),
        updatedAt: Value(p['updated_at'] as DateTime),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(p['deleted_at'] as DateTime?),
      );

  Map<String, dynamic> _masteryToMap(MasteryRecordRow r) => {
        'id': r.id,
        'kp_id': r.kpId,
        'status': r.status,
        'source': r.source,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };

  MasteryRecordsCompanion _masteryFromMap(Map<String, dynamic> p) =>
      MasteryRecordsCompanion(
        id: Value(p['id'] as String),
        kpId: Value(p['kp_id'] as String),
        status: Value((p['status'] as String?) ?? 'unknown'),
        source: Value((p['source'] as String?) ?? 'self'),
        updatedAt: Value(p['updated_at'] as DateTime),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(p['deleted_at'] as DateTime?),
      );

  // ============ helpers ============

  Map<String, dynamic>? _decodePayload(String json) {
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } on Object {
      return null;
    }
  }

  DateTime? _extractDeletedAt(String table, String json) {
    // payload 的 deleted_at 在 _decodePayload 里就有，但 SyncEnvelope.deletedAt
    // 是 transport-level 字段。本实现把它直接从 payload 取（与 outbox row
    // 重叠字段），保持简单。
    final p = _decodePayload(json);
    return p?['deleted_at'] as DateTime?;
  }

  // ============ Cards ============

  Map<String, dynamic> _cardToMap(CardRow r) => {
        'id': r.id,
        'type': r.type,
        'source_ref': r.sourceRef,
        'parent_card_id': r.parentCardId,
        'regenerated_from_id': r.regeneratedFromId,
        'content_md': r.contentMd,
        'session_id': r.sessionId,
        'model_id': r.modelId,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };

  CardsCompanion _cardFromMap(Map<String, dynamic> p) => CardsCompanion(
        id: Value(p['id'] as String),
        type: Value((p['type'] as String?) ?? 'qna'),
        sourceRef: Value((p['source_ref'] as String?) ?? '{}'),
        parentCardId: Value(p['parent_card_id'] as String?),
        regeneratedFromId: Value(p['regenerated_from_id'] as String?),
        contentMd: Value((p['content_md'] as String?) ?? ''),
        sessionId: Value(p['session_id'] as String?),
        modelId: Value(p['model_id'] as String?),
        updatedAt: Value(p['updated_at'] as DateTime),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(p['deleted_at'] as DateTime?),
      );

  // ============ Canvases ============

  Map<String, dynamic> _canvasToMap(CanvasRow r) => {
        'id': r.id,
        'notebook_id': r.notebookId,
        'name': r.name,
        'viewport': r.viewport,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };

  CanvasesCompanion _canvasFromMap(Map<String, dynamic> p) => CanvasesCompanion(
        id: Value(p['id'] as String),
        notebookId: Value(p['notebook_id'] as String?),
        name: Value((p['name'] as String?) ?? ''),
        viewport: Value((p['viewport'] as String?) ?? '{"x":0,"y":0,"zoom":1}'),
        updatedAt: Value(p['updated_at'] as DateTime),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(p['deleted_at'] as DateTime?),
      );

  // ============ CanvasNodes ============

  Map<String, dynamic> _canvasNodeToMap(CanvasNodeRow r) => {
        'id': r.id,
        'canvas_id': r.canvasId,
        'target_type': r.targetType,
        'target_id': r.targetId,
        'x': r.x,
        'y': r.y,
        'w': r.w,
        'h': r.h,
        'z': r.z,
        'collapsed': r.collapsed,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };

  CanvasNodesCompanion _canvasNodeFromMap(Map<String, dynamic> p) =>
      CanvasNodesCompanion(
        id: Value(p['id'] as String),
        canvasId: Value((p['canvas_id'] as String?) ?? ''),
        targetType: Value((p['target_type'] as String?) ?? 'note'),
        targetId: Value((p['target_id'] as String?) ?? ''),
        x: Value((p['x'] as num?)?.toDouble() ?? 0),
        y: Value((p['y'] as num?)?.toDouble() ?? 0),
        w: Value((p['w'] as num?)?.toDouble() ?? 200),
        h: Value((p['h'] as num?)?.toDouble() ?? 120),
        z: Value((p['z'] as num?)?.toInt() ?? 0),
        collapsed: Value((p['collapsed'] as bool?) ?? false),
        updatedAt: Value(p['updated_at'] as DateTime),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(p['deleted_at'] as DateTime?),
      );

  // ============ CanvasEdges ============

  Map<String, dynamic> _canvasEdgeToMap(CanvasEdgeRow r) => {
        'id': r.id,
        'canvas_id': r.canvasId,
        'from_node_id': r.fromNodeId,
        'to_node_id': r.toNodeId,
        'edge_type': r.edgeType,
        'prereq_edge_id': r.prereqEdgeId,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };

  CanvasEdgesCompanion _canvasEdgeFromMap(Map<String, dynamic> p) =>
      CanvasEdgesCompanion(
        id: Value(p['id'] as String),
        canvasId: Value((p['canvas_id'] as String?) ?? ''),
        fromNodeId: Value((p['from_node_id'] as String?) ?? ''),
        toNodeId: Value((p['to_node_id'] as String?) ?? ''),
        edgeType: Value((p['edge_type'] as String?) ?? 'manual'),
        prereqEdgeId: Value(p['prereq_edge_id'] as String?),
        updatedAt: Value(p['updated_at'] as DateTime),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(p['deleted_at'] as DateTime?),
      );

  // ============ AiSessions ============

  Map<String, dynamic> _aiSessionToMap(AiSessionRow r) => {
        'id': r.id,
        'type': r.type,
        'target_ref': r.targetRef,
        'title': r.title,
        'kp_id': r.kpId,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };

  AiSessionsCompanion _aiSessionFromMap(Map<String, dynamic> p) => AiSessionsCompanion(
        id: Value(p['id'] as String),
        type: Value((p['type'] as String?) ?? 'chat'),
        targetRef: Value((p['target_ref'] as String?) ?? ''),
        title: Value((p['title'] as String?) ?? ''),
        kpId: Value(p['kp_id'] as String?),
        updatedAt: Value(p['updated_at'] as DateTime),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(p['deleted_at'] as DateTime?),
      );

  // ============ AiMessages ============

  Map<String, dynamic> _aiMessageToMap(AiMessageRow r) => {
        'id': r.id,
        'session_id': r.sessionId,
        'role': r.role,
        'content_md': r.contentMd,
        'tokens': r.tokens,
        'latency_ms': r.latencyMs,
        'model_id': r.modelId,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };

  AiMessagesCompanion _aiMessageFromMap(Map<String, dynamic> p) => AiMessagesCompanion(
        id: Value(p['id'] as String),
        sessionId: Value((p['session_id'] as String?) ?? ''),
        role: Value((p['role'] as String?) ?? 'user'),
        contentMd: Value((p['content_md'] as String?) ?? ''),
        tokens: Value((p['tokens'] as num?)?.toInt()),
        latencyMs: Value((p['latency_ms'] as num?)?.toInt()),
        modelId: Value(p['model_id'] as String?),
        updatedAt: Value(p['updated_at'] as DateTime),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(p['deleted_at'] as DateTime?),
      );

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);
}

class _LocalVer {
  const _LocalVer({required this.version, required this.updatedAt});
  final int version;
  final DateTime updatedAt;
}
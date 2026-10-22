/// SyncEngine（T03 核心）：push / pull / merge / LWW。
///
/// 推送：读 outbox pending → 批量走 SyncApi → markPushed / markFailed
/// 拉取：走 SyncApi.pullSince → 自回声过滤 → 逐行 LWW merge → 更新 last_pulled_at
///
/// 表覆盖范围（13 张带 SyncMeta 的表，见 [kSyncTableAllowlist]）：
/// notebooks / notes / knowledge_points / prerequisite_edges / mastery_records /
/// cards / canvases / canvas_nodes / canvas_edges / ai_sessions / ai_messages /
/// kp_groups / note_assets（后两张为 v5 新增）。
///
/// 故意不同步 4 张：`ai_providers`（密钥引用本地化，跨设备命名空间不一致）、
/// `ai_task_routes`（依赖 ai_providers，单独同步无意义）、
/// `homeworks`（一次性草稿，无跨设备价值）、`sync_outbox`（发件箱自身）。
/// 将来要同步它们需先加 SyncMeta mixin + schemaVersion 迁移。
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
import 'sync_row_map.dart';
import 'sync_types.dart';

/// 参与同步的表名白名单（**一行可回退的开关**）。
///
/// ⚠️ 远端是 Supabase Edge Function（源码不在本仓库、无法验证），若它有
/// 表名白名单校验，新增表名会让**整批** push 失败 → outbox 全标 failed。
///
/// 真机跨设备同步报 4xx 时，把下面 `'kp_groups'` / `'note_assets'` 两行
/// 注释掉即可秒回退：这两张表不再上行，其余 11 张表与本地功能不受影响。
///
/// 白名单只作用于 **push**（上行）：不上行 ≠ 不下行，远端若仍有这些表的
/// 历史数据，pull 下来照样能被本地 `_upsertLocal` 消费。
const Set<String> kSyncTableAllowlist = <String>{
  'notebooks',
  'notes',
  'knowledge_points',
  'prerequisite_edges',
  'mastery_records',
  'cards',
  'canvases',
  'canvas_nodes',
  'canvas_edges',
  'ai_sessions',
  'ai_messages',
  'kp_groups',
  'note_assets',
};

/// 单批 push 的**字节预算**（4MB）。
///
/// 一条图片附件的 `data_base64` 可达 2.7MB，若和别的行挤在同一批里，
/// 整批会逼近甚至超过 Edge Function 的请求体上限 → 全批失败。
/// 预算式切批让「大 envelope 单独成批」，小 envelope 则照旧一次带走。
const int kPushBatchBudgetBytes = 4 * 1024 * 1024;

/// 单条 envelope 的**硬上限**（6MB）。
///
/// 超过它的 envelope 不会被切批逻辑无限重试：直接 `markFailed` + 一条
/// warning 日志，避免一条畸形巨包把整个 outbox 队列永久堵住。
const int kMaxEnvelopeBytes = 6 * 1024 * 1024;

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
  /// [limit] 单批上限（**条数**上限；真正的成批边界还受
  /// [kPushBatchBudgetBytes] 字节预算约束）；[includeFailed] 是否同时拉
  /// failed 重试。
  ///
  /// 流程：
  /// 1. 出队 pending + failed → 逐条构造 envelope；
  /// 2. 表名不在 [kSyncTableAllowlist] 里的行**原地跳过**（保持 pending，
  ///    不入队失败）—— 这是远端表名白名单不兼容时的回退通道；
  /// 3. 单条 > [kMaxEnvelopeBytes] → `markFailed` + warning，不参与切批；
  /// 4. 其余按 [kPushBatchBudgetBytes] 贪心切批 → 逐批 push。
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

    // ---- 1. 构造 envelope + 过滤 ----
    final entries = <_PushEntry>[];
    final oversized = <int>[];
    final blockedTables = <String>{};

    for (final r in rows) {
      if (!kSyncTableAllowlist.contains(r.entityTable)) {
        blockedTables.add(r.entityTable);
        continue;
      }
      final env = SyncEnvelope(
        deviceId: r.deviceId,
        entityTable: r.entityTable,
        entityId: r.entityId,
        op: SyncOp.parse(r.op),
        payload: _decodePayload(r.payloadJson),
        baseVersion: r.baseVersion,
        updatedAt: r.createdAt, // 简化：用 outbox 创建时间（行真正 updatedAt 在 payload 里）
        deletedAt: _extractDeletedAt(r.entityTable, r.payloadJson),
      );
      final bytes = _envelopeBytes(env, r.payloadJson);
      if (bytes > kMaxEnvelopeBytes) {
        // 单条就超硬上限：切批也救不了，标记 failed 让它别堵住队列。
        oversized.add(r.id);
        continue;
      }
      entries.add(_PushEntry(row: r, envelope: env, bytes: bytes));
    }

    if (blockedTables.isNotEmpty) {
      _log.w(
        '表 ${blockedTables.join(', ')} 不在 kSyncTableAllowlist 内，'
        '${blockedTables.length} 张表的 outbox 行本轮跳过（保持 pending）',
      );
    }
    if (oversized.isNotEmpty) {
      _log.w(
        '${oversized.length} 条 envelope 超过 ${kMaxEnvelopeBytes ~/ (1024 * 1024)}MB '
        '硬上限，标记 failed 跳过（否则会永久堵住队列）',
      );
      await _outbox.markFailed(oversized);
    }
    if (entries.isEmpty) {
      return PushReport(
        pushed: 0,
        failed: oversized.length,
        serverTime: DateTime.now().toUtc(),
      );
    }

    // ---- 2. 按字节预算切批 ----
    final batches = _splitBatches(entries);
    if (batches.length > 1) {
      _log.i('push 切成 ${batches.length} 批（字节预算 ${kPushBatchBudgetBytes ~/ (1024 * 1024)}MB）');
    }

    // ---- 3. 逐批 push ----
    var pushed = 0;
    var failedCount = oversized.length;
    var serverTime = DateTime.now().toUtc();

    for (final batch in batches) {
      final ids = <int>[for (final e in batch) e.row.id];
      await _outbox.markSending(ids);
      try {
        final result =
            await _api.pushBatch(<SyncEnvelope>[for (final e in batch) e.envelope]);
        await _outbox.markPushed(ids);
        pushed += result.accepted;
        serverTime = result.serverTime;
        _log.i('push 成功 ${result.accepted} 条；server_time=${result.serverTime}');
      } on Object catch (e) {
        _log.w('push 失败：$e；${ids.length} 条回到 failed');
        await _outbox.markFailed(ids);
        failedCount += ids.length;
      }
    }

    return PushReport(
      pushed: pushed,
      failed: failedCount,
      serverTime: serverTime,
    );
  }

  /// 估算一条 envelope 序列化后的字节数（UTF-8）。
  ///
  /// [rawPayloadJson] 是 outbox 里存的原始 JSON 串，只在 `jsonEncode` 抛出
  /// （payload 里混入了 jsonEncode 不支持的对象）时用作退化估算，
  /// 保证切批逻辑不会因为一条坏包而整体崩掉。
  int _envelopeBytes(SyncEnvelope env, String rawPayloadJson) {
    try {
      return utf8.encode(jsonEncode(env.toJson())).length;
    } on Object {
      // base64 正文基本是纯 ASCII，1.2 倍系数足够保守。
      return (rawPayloadJson.length * 1.2).ceil();
    }
  }

  /// 贪心切批：按 [entries] 原顺序累加，超出预算就断开当前批。
  ///
  /// 效果是「一条 2.7MB 的 asset envelope 单独成批」——它既不会被拆开
  /// （envelope 是原子的），也不会把后面的小 envelope 一起拖下水。
  static List<List<_PushEntry>> _splitBatches(List<_PushEntry> entries) {
    final batches = <List<_PushEntry>>[];
    var current = <_PushEntry>[];
    var currentBytes = 0;
    for (final e in entries) {
      if (current.isNotEmpty && currentBytes + e.bytes > kPushBatchBudgetBytes) {
        batches.add(current);
        current = <_PushEntry>[];
        currentBytes = 0;
      }
      current.add(e);
      currentBytes += e.bytes;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
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
      updatedAt: _dt(row['updated_at']) ?? _epoch,
    );
  }

  Future<Map<String, dynamic>?> _readLocalRow(String table, String id) async {
    switch (table) {
      case 'notebooks':
        final r = await (_db.select(_db.notebooks)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : notebookRowToMap(r);
      case 'notes':
        final r = await (_db.select(_db.notes)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : noteRowToMap(r);
      case 'knowledge_points':
        final r = await (_db.select(_db.knowledgePoints)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : knowledgePointRowToMap(r);
      case 'prerequisite_edges':
        final r = await (_db.select(_db.prerequisiteEdges)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : prerequisiteEdgeRowToMap(r);
      case 'mastery_records':
        final r = await (_db.select(_db.masteryRecords)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : masteryRecordRowToMap(r);
      case 'cards':
        final r = await (_db.select(_db.cards)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : cardRowToMap(r);
      case 'canvases':
        final r = await (_db.select(_db.canvases)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : canvasRowToMap(r);
      case 'canvas_nodes':
        final r = await (_db.select(_db.canvasNodes)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : canvasNodeRowToMap(r);
      case 'canvas_edges':
        final r = await (_db.select(_db.canvasEdges)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : canvasEdgeRowToMap(r);
      case 'ai_sessions':
        final r = await (_db.select(_db.aiSessions)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : aiSessionRowToMap(r);
      case 'ai_messages':
        final r = await (_db.select(_db.aiMessages)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : aiMessageRowToMap(r);
      case 'kp_groups':
        final r = await (_db.select(_db.kpGroups)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : kpGroupRowToMap(r);
      case 'note_assets':
        // ⚠️ 轻量查询：LWW 只需要 id / version / updated_at 三个字段。
        // 若 select 整行，每次比较都要为取两个字段把数 MB 的 `data_base64`
        // 读进内存（一条 2MB 图片的 base64 约 2.7MB）。
        final r = await (_db.selectOnly(_db.noteAssets)
              ..addColumns([
                _db.noteAssets.id,
                _db.noteAssets.version,
                _db.noteAssets.updatedAt,
              ])
              ..where(_db.noteAssets.id.equals(id)))
            .getSingleOrNull();
        return r == null
            ? null
            : <String, dynamic>{
                'id': r.read(_db.noteAssets.id),
                'version': r.read(_db.noteAssets.version),
                'updated_at': r.read(_db.noteAssets.updatedAt),
              };
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
      case 'kp_groups':
        await _db.into(_db.kpGroups).insert(_kpGroupFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      case 'note_assets':
        await _db.into(_db.noteAssets).insert(_noteAssetFromMap(p), mode: InsertMode.insertOrReplace);
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
      case 'kp_groups':
        await (_db.delete(_db.kpGroups)..where((t) => t.id.equals(id))).go();
        break;
      case 'note_assets':
        await (_db.delete(_db.noteAssets)..where((t) => t.id.equals(id))).go();
        break;
      default:
        _log.w('未知表 $table，跳过 delete');
    }
  }

  // ============ Row ↔ Map 适配 ============
  //
  // 行 → Map 的映射在 `sync_row_map.dart`（与仓储层 enqueue 共用同一份真相源，
  // 保证「上行 payload 的键」与「下行 fromMap 读的键」永远一致）。
  // 下面只保留 Map → 行的方向。

  NotebooksCompanion _notebookFromMap(Map<String, dynamic> p) => NotebooksCompanion(
        id: Value(p['id'] as String),
        name: Value((p['name'] as String?) ?? ''),
        parentId: Value(p['parent_id'] as String?),
        sortOrder: Value((p['sort_order'] as num?)?.toInt() ?? 0),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  NotesCompanion _noteFromMap(Map<String, dynamic> p) => NotesCompanion(
        id: Value(p['id'] as String),
        notebookId: Value(p['notebook_id'] as String?),
        title: Value((p['title'] as String?) ?? ''),
        contentMd: Value((p['content_md'] as String?) ?? ''),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

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
        // v5 新增两列：缺了这两行，对端 pull 时会静默丢掉置顶与创建时间。
        pinned: Value((p['pinned'] as bool?) ?? false),
        createdAt: Value(_dt(p['created_at'])),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  PrerequisiteEdgesCompanion _edgeFromMap(Map<String, dynamic> p) =>
      PrerequisiteEdgesCompanion(
        id: Value(p['id'] as String),
        fromKpId: Value(p['from_kp_id'] as String),
        toKpId: Value(p['to_kp_id'] as String),
        reason: Value((p['reason'] as String?) ?? ''),
        origin: Value((p['origin'] as String?) ?? 'ai'),
        confidence: Value((p['confidence'] as num?)?.toDouble() ?? 0),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  MasteryRecordsCompanion _masteryFromMap(Map<String, dynamic> p) =>
      MasteryRecordsCompanion(
        id: Value(p['id'] as String),
        kpId: Value(p['kp_id'] as String),
        status: Value((p['status'] as String?) ?? 'unknown'),
        source: Value((p['source'] as String?) ?? 'self'),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  // ============ helpers ============

  /// 宽容地把 payload 里的时间值解析成 [DateTime]。
  ///
  /// payload 经 outbox 的 JSON 往返后，DateTime 会变成 ISO 8601 **字符串**
  /// （Dart 的 `jsonEncode` 不支持 DateTime）。旧代码直接 `as DateTime` 会抛
  /// TypeError——「一旦 payload 变成真实数据就会暴露」的根因。
  ///
  /// 三种输入都要能吃下：
  /// - `DateTime`：本地直传（未经 JSON）；
  /// - `String`：JSON 往返后的 ISO 8601;
  /// - 其他（null / 数字 / 乱码）：返回 null，由调用方决定兜底。
  DateTime? _dt(dynamic v) {
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

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
    // ⚠️ JSON 往返后它是 ISO 字符串，必须用 _dt 解析（不能 `as DateTime?`）。
    final p = _decodePayload(json);
    return _dt(p?['deleted_at']);
  }

  // ============ Cards ============

  CardsCompanion _cardFromMap(Map<String, dynamic> p) => CardsCompanion(
        id: Value(p['id'] as String),
        type: Value((p['type'] as String?) ?? 'qna'),
        sourceRef: Value((p['source_ref'] as String?) ?? '{}'),
        parentCardId: Value(p['parent_card_id'] as String?),
        regeneratedFromId: Value(p['regenerated_from_id'] as String?),
        contentMd: Value((p['content_md'] as String?) ?? ''),
        sessionId: Value(p['session_id'] as String?),
        modelId: Value(p['model_id'] as String?),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  // ============ Canvases ============

  CanvasesCompanion _canvasFromMap(Map<String, dynamic> p) => CanvasesCompanion(
        id: Value(p['id'] as String),
        notebookId: Value(p['notebook_id'] as String?),
        name: Value((p['name'] as String?) ?? ''),
        viewport: Value((p['viewport'] as String?) ?? '{"x":0,"y":0,"zoom":1}'),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  // ============ CanvasNodes ============

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
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  // ============ CanvasEdges ============

  CanvasEdgesCompanion _canvasEdgeFromMap(Map<String, dynamic> p) =>
      CanvasEdgesCompanion(
        id: Value(p['id'] as String),
        canvasId: Value((p['canvas_id'] as String?) ?? ''),
        fromNodeId: Value((p['from_node_id'] as String?) ?? ''),
        toNodeId: Value((p['to_node_id'] as String?) ?? ''),
        edgeType: Value((p['edge_type'] as String?) ?? 'manual'),
        prereqEdgeId: Value(p['prereq_edge_id'] as String?),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  // ============ AiSessions ============

  AiSessionsCompanion _aiSessionFromMap(Map<String, dynamic> p) => AiSessionsCompanion(
        id: Value(p['id'] as String),
        type: Value((p['type'] as String?) ?? 'chat'),
        targetRef: Value((p['target_ref'] as String?) ?? ''),
        title: Value((p['title'] as String?) ?? ''),
        kpId: Value(p['kp_id'] as String?),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  // ============ KpGroups ============
  //
  // ⚠️ `members_json` 整段搬运，同步层不解析（分组成员语义归 GroupRepository）。

  KpGroupsCompanion _kpGroupFromMap(Map<String, dynamic> p) => KpGroupsCompanion(
        id: Value(p['id'] as String),
        canvasId: Value((p['canvas_id'] as String?) ?? ''),
        name: Value((p['name'] as String?) ?? ''),
        orderIndex: Value((p['order_index'] as num?)?.toInt() ?? 0),
        foundationalLevel:
            Value((p['foundational_level'] as num?)?.toInt() ?? 0),
        membersJson: Value((p['members_json'] as String?) ?? '[]'),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  // ============ NoteAssets ============
  //
  // ⚠️ 键名来自 drift 生成产物逐列提取：`dataBase64` → **`data_base64`**，
  // `bytes` 就是 `bytes`（int）。拼错 = 对端静默回落默认值且不报错。

  NoteAssetsCompanion _noteAssetFromMap(Map<String, dynamic> p) =>
      NoteAssetsCompanion(
        id: Value(p['id'] as String),
        noteId: Value((p['note_id'] as String?) ?? ''),
        name: Value((p['name'] as String?) ?? ''),
        mime: Value((p['mime'] as String?) ?? 'image/png'),
        sha1: Value((p['sha1'] as String?) ?? ''),
        bytes: Value((p['bytes'] as num?)?.toInt() ?? 0),
        dataBase64: Value((p['data_base64'] as String?) ?? ''),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  // ============ AiMessages ============

  AiMessagesCompanion _aiMessageFromMap(Map<String, dynamic> p) => AiMessagesCompanion(
        id: Value(p['id'] as String),
        sessionId: Value((p['session_id'] as String?) ?? ''),
        role: Value((p['role'] as String?) ?? 'user'),
        contentMd: Value((p['content_md'] as String?) ?? ''),
        tokens: Value((p['tokens'] as num?)?.toInt()),
        latencyMs: Value((p['latency_ms'] as num?)?.toInt()),
        modelId: Value(p['model_id'] as String?),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);
}

class _LocalVer {
  const _LocalVer({required this.version, required this.updatedAt});
  final int version;
  final DateTime updatedAt;
}

/// 一次 push 里「outbox 行 ↔ envelope ↔ 预估字节数」的三元组。
class _PushEntry {
  const _PushEntry({
    required this.row,
    required this.envelope,
    required this.bytes,
  });

  final SyncOutboxRow row;
  final SyncEnvelope envelope;

  /// 该 envelope 序列化后的 UTF-8 字节数（切批依据）。
  final int bytes;
}
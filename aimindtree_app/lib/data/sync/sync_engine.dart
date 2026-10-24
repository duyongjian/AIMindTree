/// SyncEngine（T03 核心）：push / pull / merge / LWW。
///
/// 推送：读 outbox pending → 批量走 SyncApi → markPushed / markFailed
/// 拉取：走 SyncApi.pullSince → 自回声过滤 → 逐行 LWW merge → 更新 last_pulled_at
///
/// 表覆盖范围（15 张带 SyncMeta 的表，见 [kSyncTableAllowlist]）：
/// notebooks / notes / knowledge_points / prerequisite_edges / mastery_records /
/// cards / canvases / canvas_nodes / canvas_edges / ai_sessions / ai_messages /
/// kp_groups / note_assets（后两张为 v5 新增）/
/// canvas_cards / canvas_strokes（后两张为 ★2.0.0 新增）。
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
  'canvas_cards',
  'canvas_strokes',
};

/// 单批 push 的**字节预算** / 单条 envelope 的**硬上限**——按后端取值。
///
/// 默认 4MB / 6MB（与 Cloudflare / Netlify 的放宽上限一致）；edgeone
/// 受平台请求体 ~1MB 硬限约束，经
/// [SyncBackend.pushBatchBudgetBytes] / [SyncBackend.maxEnvelopeBytes]
/// 收紧到 850KB。具体数值见 [SyncConfig]
/// （`kSyncPushBatchBudgetBytes` / `kSyncMaxEnvelopeBytes` /
/// `kSyncEoPushBudgetBytes`），[push] / [pushAll]
/// 在运行时从目标 [SyncApi] 读出对应后端的预算再切批，不再写死常量。
///
/// 背景：一条图片附件的 `data_base64` 可达 2.7MB，若和别的行挤在同一批里，
/// 整批会逼近甚至超过中继的请求体上限 → 全批失败。预算式切批让「大 envelope
/// 单独成批」，小 envelope 则照旧一次带走。

/// 全量快照（[SyncEngine.pushAll]）**单批条数上限**（200）。
///
/// 字节预算（4MB）单独不足以保护远端：一行 payload 平均只有 ~1KB 时，
/// 4MB 能塞进约 4000 条 envelope，而远端 `handlePush` 是一次性
/// `env.DB.batch(batch)` 提交，D1 的 batch 语句数有上限 → 整批 500。
///
/// 200 条的取舍：200 × ~1KB ≈ 200KB，远低于 4MB 预算且给 D1 留足余量；
/// 万一失败也只丢一小批，重试成本低。
const int kSnapshotMaxBatchCount = 200;

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
  /// [limit] 单批上限（**条数**上限；真正的成批边界还受目标后端的
  /// [SyncBackend.pushBatchBudgetBytes] 字节预算约束）；[includeFailed] 是否
  /// 同时拉 failed 重试。
  ///
  /// 流程：
  /// 1. 出队 pending + failed → 逐条构造 envelope；
  /// 2. 表名不在 [kSyncTableAllowlist] 里的行**原地跳过**（保持 pending，
  ///    不入队失败）—— 这是远端表名白名单不兼容时的回退通道；
  /// 3. 单条 > 目标后端的 [SyncBackend.maxEnvelopeBytes] → `markFailed` +
  ///    warning，不参与切批；
  /// 4. 其余按目标后端的 [SyncBackend.pushBatchBudgetBytes] 贪心切批 → 逐批 push。
  ///
  /// [api] 可覆盖默认后端（用于「上传到 llmserver / 上传到 CF」双目标分流）；
  /// 不传则用构造时的 [_api]。
  Future<PushReport> push({
    int limit = 100,
    bool includeFailed = true,
    SyncApi? api,
  }) async {
    final target = api ?? _api;
    // 字节预算 / 单条硬上限按后端取值（edgeone 收紧到 850KB）。
    final budget = target.pushBatchBudgetBytes;
    final maxEnv = target.maxEnvelopeBytes;
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
      if (bytes > maxEnv) {
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
        '${oversized.length} 条 envelope 超过 ${maxEnv ~/ (1024 * 1024)}MB '
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
    final batches = _splitBatches(entries, budgetBytes: budget);
    if (batches.length > 1) {
      _log.i('push 切成 ${batches.length} 批（字节预算 ${budget ~/ (1024 * 1024)}MB）');
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
            await target.pushBatch(<SyncEnvelope>[for (final e in batch) e.envelope]);
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
  /// 保证切批逻辑不会因为一条坏包而整体崩掉。全量快照（[pushAll]）没有
  /// 原始 JSON 串，传 null 即可（`SyncEnvelope.toJson` 已用 `toJsonSafe`
  /// 把 DateTime 等转成字符串，正常情况下不会抛）。
  int _envelopeBytes(SyncEnvelope env, [String? rawPayloadJson]) {
    try {
      return utf8.encode(jsonEncode(env.toJson())).length;
    } on Object {
      final raw = rawPayloadJson;
      if (raw == null) return 0;
      // base64 正文基本是纯 ASCII，1.2 倍系数足够保守。
      return (raw.length * 1.2).ceil();
    }
  }

  /// 贪心切批：按 [entries] 原顺序累加，超出预算就断开当前批。
  ///
  /// 效果是「一条 2.7MB 的 asset envelope 单独成批」——它既不会被拆开
  /// （envelope 是原子的），也不会把后面的小 envelope 一起拖下水。
  ///
  /// 泛型化是为了让「增量 push」与「全量快照 pushAll」共用同一套切批口径。
  /// [maxCount] 是可选的**条数**上限（0 = 不限，保持 `push()` 的原语义）。
  /// [budgetBytes] 是**字节**预算上限（按后端，edgeone 取 850KB，其余 4MB），
  /// 由调用方从目标 [SyncApi] 读出后传入。
  ///
  /// 为什么需要条数上限：远端 `handlePush` 把这个数组整个展开成一次
  /// `env.DB.batch(batch)` 提交，而 D1 的 batch 有语句数上限。一行 payload
  /// 平均 ~1KB 时，4MB 预算能塞进约 4000 条 → 整批 500，用户看到的是
  /// 「上传失败」而不是「慢」。全量快照（[kSnapshotMaxBatchCount] = 200）
  /// 必须同时受条数与字节双重约束；增量 `push()` 本来就有 `limit` 保护。
  static List<List<T>> _splitBatches<T extends _ByteSized>(
    List<T> entries, {
    int maxCount = 0,
    required int budgetBytes,
  }) {
    final batches = <List<T>>[];
    var current = <T>[];
    var currentBytes = 0;
    for (final e in entries) {
      final overBudget = currentBytes + e.bytes > budgetBytes;
      final overCount = maxCount > 0 && current.length >= maxCount;
      if (current.isNotEmpty && (overBudget || overCount)) {
        batches.add(current);
        current = <T>[];
        currentBytes = 0;
      }
      current.add(e);
      currentBytes += e.bytes;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  // ============ Push：全量快照 ============

  /// 全量快照推送：把 [kSyncTableAllowlist] 里 15 张表的**所有现存行**当作
  /// upsert 推上去，与 outbox 是否为空无关。
  ///
  /// 为什么必须要有它：outbox 是**增量发件箱**，只记录「接线之后经仓储写入」
  /// 的变更。本 App 在同步接线（`extraction_service.dart` 的 bootstrap）之前
  /// 就已存在大量历史数据，这些行永远不会入队，只靠 [push] 会一条都发不出去
  /// （用户实测表现就是「提示上传成功，但是 0 条」）。
  ///
  /// 与 [push] 的分工：
  /// - [push] 负责**变更语义**——含硬删墓碑（行已不在表里，快照扫不到）；
  /// - [pushAll] 负责**状态对齐**——含历史存量与未接线的表。
  /// 调用方应「先 push() 再 pushAll()」，两者都跑才完整，报告分开计数。
  ///
  /// 分页读取（[pageSize] 行/页）避免把整表（尤其 note_assets 的
  /// data_base64）一次性读进内存；复用 `sync_row_map.dart` 的 `*RowToMap`，
  /// 保证 payload 键与下行 `*FromMap` 严格一致。
  ///
  /// **不写 outbox**：全量是对齐，不是变更记账（outbox 行由 [push] 负责）。
  Future<PushReport> pushAll({SyncApi? api, int pageSize = 50}) async {
    final target = api ?? _api;
    // 字节预算 / 单条硬上限按后端取值（edgeone 收紧到 850KB）。
    final budget = target.pushBatchBudgetBytes;
    final maxEnv = target.maxEnvelopeBytes;
    var pushed = 0;
    var failed = 0;
    var serverTime = DateTime.now().toUtc();

    // 边读边发：缓冲到字节预算就整批下发，内存峰值 ≈ 一个批次（4MB）
    // 加上一页数据，而不是整张表。
    final buffer = <_SnapshotEntry>[];
    var bufferBytes = 0;

    Future<void> flush() async {
      if (buffer.isEmpty) return;
      final batches = _splitBatches<_SnapshotEntry>(
        buffer,
        maxCount: kSnapshotMaxBatchCount,
        budgetBytes: budget,
      );
      buffer.clear();
      bufferBytes = 0;
      for (final batch in batches) {
        try {
          final result = await target.pushBatch(
            <SyncEnvelope>[for (final e in batch) e.envelope],
          );
          pushed += result.accepted;
          serverTime = result.serverTime;
          _log.i('pushAll 批成功 ${result.accepted} 条；'
              'server_time=${result.serverTime}');
        } on Object catch (e) {
          _log.w('pushAll 批失败：$e；${batch.length} 条计入 failed');
          failed += batch.length;
        }
      }
    }

    // 表名顺序固定（Set 的迭代顺序 = 字面量插入顺序），便于测试断言。
    for (final table in kSyncTableAllowlist) {
      var offset = 0;
      while (true) {
        final page = await _readPagePayloads(table, pageSize, offset);
        if (page.isEmpty) break;
        for (final payload in page) {
          final env = SyncEnvelope(
            deviceId: deviceId,
            entityTable: table,
            entityId: payload['id'] as String,
            op: SyncOp.upsert,
            payload: payload,
            baseVersion: (payload['version'] as num?)?.toInt() ?? 1,
            updatedAt: _dt(payload['updated_at']) ?? _epoch,
            // 软删行也要带上墓碑时间：快照是「状态对齐」，
            // 漏掉 deleted_at 会让对端把已删的行业当成活数据收下。
            deletedAt: _dt(payload['deleted_at']),
          );
          final bytes = _envelopeBytes(env);
          if (bytes > maxEnv) {
            // 单条超硬上限：跳过但不中断整轮（否则一张坏表堵死全部快照）。
            failed++;
            _log.w('pushAll 跳过超大 envelope：$table/${payload['id']} '
                '(${bytes ~/ 1024}KB > ${maxEnv ~/ (1024 * 1024)}MB)');
            continue;
          }
          if (buffer.isNotEmpty &&
              bufferBytes + bytes > budget) {
            await flush();
          }
          buffer.add(_SnapshotEntry(envelope: env, bytes: bytes));
          bufferBytes += bytes;
        }
        if (page.length < pageSize) break;
        offset += page.length;
      }
    }
    await flush();

    _log.i('pushAll 完成：pushed=$pushed failed=$failed');
    return PushReport(pushed: pushed, failed: failed, serverTime: serverTime);
  }

  /// 读一张表的一页并转成 payload 列表（按 id 升序保证分页稳定）。
  ///
  /// ⚠️ [note_assets] 必须**整行 select**：payload 要带完整 `data_base64`，
  /// 不能像 [_readLocalRow] 那样只取三列（那里是 LWW 比较，不需要正文）。
  Future<List<Map<String, dynamic>>> _readPagePayloads(
    String table,
    int limit,
    int offset,
  ) async {
    switch (table) {
      case 'notebooks':
        final rows = await (_db.select(_db.notebooks)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(notebookRowToMap).toList();
      case 'notes':
        final rows = await (_db.select(_db.notes)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(noteRowToMap).toList();
      case 'knowledge_points':
        final rows = await (_db.select(_db.knowledgePoints)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(knowledgePointRowToMap).toList();
      case 'prerequisite_edges':
        final rows = await (_db.select(_db.prerequisiteEdges)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(prerequisiteEdgeRowToMap).toList();
      case 'mastery_records':
        final rows = await (_db.select(_db.masteryRecords)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(masteryRecordRowToMap).toList();
      case 'cards':
        final rows = await (_db.select(_db.cards)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(cardRowToMap).toList();
      case 'canvases':
        final rows = await (_db.select(_db.canvases)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(canvasRowToMap).toList();
      case 'canvas_nodes':
        final rows = await (_db.select(_db.canvasNodes)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(canvasNodeRowToMap).toList();
      case 'canvas_edges':
        final rows = await (_db.select(_db.canvasEdges)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(canvasEdgeRowToMap).toList();
      case 'ai_sessions':
        final rows = await (_db.select(_db.aiSessions)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(aiSessionRowToMap).toList();
      case 'ai_messages':
        final rows = await (_db.select(_db.aiMessages)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(aiMessageRowToMap).toList();
      case 'kp_groups':
        final rows = await (_db.select(_db.kpGroups)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(kpGroupRowToMap).toList();
      case 'note_assets':
        final rows = await (_db.select(_db.noteAssets)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(noteAssetRowToMap).toList();
      case 'canvas_cards':
        final rows = await (_db.select(_db.canvasCards)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(canvasCardRowToMap).toList();
      case 'canvas_strokes':
        final rows = await (_db.select(_db.canvasStrokes)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(canvasStrokeRowToMap).toList();
      default:
        _log.w('pushAll 遇到未知表 $table，跳过');
        return const <Map<String, dynamic>>[];
    }
  }

  // ============ Push：排空积压 ============

  /// 反复调用 [push] 直到 outbox 排空，返回**累计**结果。
  ///
  /// 为什么需要它：[push] 单次受 `limit`（默认 100 条）约束。积压超过 100 条
  /// 时一次「上传」推不完——用户会连续几次看到同样的「增量 100 条」，误以为
  /// 同步卡住；更麻烦的是 pending 占满 limit 后
  /// `failedPending(limit: limit - pending.length)` 的参数恒为 0，
  /// **失败行永远轮不到重试**。
  ///
  /// 退出条件（任一满足）：
  /// - `pendingCount()` 归零（推完了）；
  /// - 连续两轮 `pushed == 0 && failed == 0`（防空转：全是超限包或白名单外
  ///   的行时它们会一直留在 pending，不设这个兜底会空转到 [maxRounds]）；
  /// - 达到 [maxRounds] 安全上限（默认 100 轮 × 100 条 = 1 万条）。
  ///
  /// [batchLimit] 是**每轮**的条数上限（不是总量上限）；[maxRounds] 是安全
  /// 上限而非预期轮数。
  Future<PushReport> pushDrain({
    SyncApi? api,
    int batchLimit = 100,
    int maxRounds = 100,
  }) async {
    var pushed = 0;
    var failed = 0;
    var serverTime = DateTime.now().toUtc();
    var idleRounds = 0;

    for (var round = 1; round <= maxRounds; round++) {
      final report = await push(api: api, limit: batchLimit);
      pushed += report.pushed;
      failed += report.failed;
      // 空 outbox 时 push() 早返回 epoch，别让它覆盖真实的服务端时间。
      if (report.pushed > 0 || report.failed > 0) {
        serverTime = report.serverTime;
      }

      final remaining = await _outbox.pendingCount();
      _log.d(
        'pushDrain 第 $round 轮：本轮 pushed=${report.pushed} '
        'failed=${report.failed}，剩余 pending=$remaining',
      );

      if (remaining == 0) break;

      if (report.pushed == 0 && report.failed == 0) {
        idleRounds++;
        if (idleRounds >= 2) {
          _log.w(
            'pushDrain 连续 $idleRounds 轮无进展（剩余 $remaining 条），'
            '可能全是白名单外或超限行，提前退出避免空转',
          );
          break;
        }
      } else {
        idleRounds = 0;
      }

      if (round == maxRounds) {
        _log.w('pushDrain 达到轮数上限 $maxRounds，仍有 $remaining 条未推');
      }
    }

    _log.i('pushDrain 完成：pushed=$pushed failed=$failed');
    return PushReport(pushed: pushed, failed: failed, serverTime: serverTime);
  }

  // ============ Pull ============

  /// 拉取 since [lastPulledAt]（首次为 null = 全量）→ 自回声过滤 → LWW merge。
  ///
  /// [api] 可覆盖默认后端（用于「从 llmserver / 从 CF 拉取」双目标分流）；
  /// 不传则用构造时的 [_api]。
  Future<PullReport> pull({SyncApi? api}) async {
    final target = api ?? _api;
    final result = await target.pullSince(_lastPulledAt);
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
      case 'canvas_cards':
        final r = await (_db.select(_db.canvasCards)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : canvasCardRowToMap(r);
      case 'canvas_strokes':
        final r = await (_db.select(_db.canvasStrokes)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : canvasStrokeRowToMap(r);
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
      case 'canvas_cards':
        await _db.into(_db.canvasCards).insert(_canvasCardFromMap(p), mode: InsertMode.insertOrReplace);
        break;
      case 'canvas_strokes':
        await _db.into(_db.canvasStrokes).insert(_canvasStrokeFromMap(p), mode: InsertMode.insertOrReplace);
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
      case 'canvas_cards':
        await (_db.delete(_db.canvasCards)..where((t) => t.id.equals(id))).go();
        break;
      case 'canvas_strokes':
        await (_db.delete(_db.canvasStrokes)..where((t) => t.id.equals(id))).go();
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
        contentHash: Value((p['content_hash'] as String?) ?? ''),
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
        pinned: Value(_bool(p['pinned'], false)),
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

  /// 布尔字段的容错解析：[fallback] 必须与该列的 **`withDefault` 值一致**。
  ///
  /// 为什么不能写 `p['x'] as bool?`：JSON 往返后 boolean 可能被服务端 / 网关
  /// 回成 `0/1`（int）或 `'true'`（String），`as bool?` 一律算 null → 静默
  /// 回落 → 测试全绿、线上无声丢失。
  ///
  /// ⚠️ [fallback] 的取值要对着 `tables.dart` 的 `withDefault` 抄：
  /// `knowledge_points.pinned` 是 `Constant(false)`，`canvas_nodes.pinned`
  /// 是 **`Constant(true)`** —— 抄错就会在每次 pull 时反向重置该列。
  bool _bool(dynamic v, bool fallback) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.toLowerCase().trim();
      if (s == 'true' || s == '1') return true;
      if (s == 'false' || s == '0') return false;
    }
    return fallback;
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
        collapsed: Value(_bool(p['collapsed'], false)),
        // ⚠️ 回落值必须是 **true**，与 `CanvasNodes.pinned` 的列默认
        // （`Constant(true)`）保持一致。抄 `knowledge_points` 的 `?? false` 会
        // 让对端每次 pull 都把节点取消锁定（`_applyUpdate` 先删后插）。
        pinned: Value(_bool(p['pinned'], true)),
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

  // ============ CanvasCards（★2.0.0）============
  //
  // ⚠️ 位置/尺寸经 [CanvasNodes]（`target_type='card'`）同步，本表只存内容。

  CanvasCardsCompanion _canvasCardFromMap(Map<String, dynamic> p) =>
      CanvasCardsCompanion(
        id: Value(p['id'] as String),
        noteId: Value(p['note_id'] as String?),
        title: Value((p['title'] as String?) ?? ''),
        body: Value((p['body'] as String?) ?? ''),
        styleJson: Value((p['style_json'] as String?) ?? '{}'),
        updatedAt: Value(_dt(p['updated_at']) ?? _epoch),
        version: Value((p['version'] as num?)?.toInt() ?? 1),
        deviceId: Value((p['device_id'] as String?) ?? deviceId),
        deletedAt: Value(_dt(p['deleted_at'])),
      );

  // ============ CanvasStrokes（★2.0.0）============

  CanvasStrokesCompanion _canvasStrokeFromMap(Map<String, dynamic> p) =>
      CanvasStrokesCompanion(
        id: Value(p['id'] as String),
        canvasId: Value((p['canvas_id'] as String?) ?? ''),
        pointsJson: Value((p['points_json'] as String?) ?? '[]'),
        color: Value((p['color'] as String?) ?? '#1a1a1a'),
        width: Value((p['width'] as num?)?.toDouble() ?? 3.0),
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

/// 「带预估字节数」的待发条目（[SyncEngine._splitBatches] 的切批依据）。
///
/// 抽成接口是为了让增量 push（[_PushEntry]，来自 outbox）与全量快照
/// （[_SnapshotEntry]，来自表扫描）共用同一套字节预算切批逻辑。
abstract class _ByteSized {
  /// 该 envelope 序列化后的 UTF-8 字节数。
  int get bytes;
}

/// 一次 push 里「outbox 行 ↔ envelope ↔ 预估字节数」的三元组。
class _PushEntry implements _ByteSized {
  const _PushEntry({
    required this.row,
    required this.envelope,
    required this.bytes,
  });

  final SyncOutboxRow row;
  final SyncEnvelope envelope;

  /// 该 envelope 序列化后的 UTF-8 字节数（切批依据）。
  @override
  final int bytes;
}

/// 全量快照里的一条待发条目（没有 outbox 行：快照不记账）。
class _SnapshotEntry implements _ByteSized {
  const _SnapshotEntry({required this.envelope, required this.bytes});

  final SyncEnvelope envelope;

  /// 该 envelope 序列化后的 UTF-8 字节数（切批依据）。
  @override
  final int bytes;
}
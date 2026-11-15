/// SyncEngine（T03 核心）：push / pull / merge / LWW。
///
/// 推送：读 outbox pending → 批量走 SyncApi → markPushed / markFailed
/// 拉取：走 SyncApi.pullSince → 自回声过滤 → 逐行 LWW merge → 更新 last_pulled_at
///
/// 表覆盖范围（16 张带 SyncMeta 的表，见 [kSyncTableAllowlist]）：
/// notebooks / notes / knowledge_points / prerequisite_edges / mastery_records /
/// cards / canvases / canvas_nodes / canvas_edges / ai_sessions / ai_messages /
/// kp_groups / note_assets（后两张为 v5 新增）/
/// canvas_cards / canvas_strokes（后两张为 ★2.0.0 新增）/
/// homeworks（作业：本表已带 SyncMeta，纳入同步后作业可跨设备）。
///
/// 故意不同步 3 张：`ai_providers`（密钥引用本地化，跨设备命名空间不一致）、
/// `ai_task_routes`（依赖 ai_providers，单独同步无意义）、
/// `sync_outbox`（发件箱自身）。
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
import 'sync_json.dart';
import 'sync_outbox.dart';
import 'sync_row_map.dart';
import 'sync_types.dart';

import '../../core/note_merge.dart';

/// 参与同步的表名白名单（**一行可回退的开关**）。
///
/// ⚠️ 远端是 Supabase Edge Function（源码不在本仓库、无法验证），若它有
/// 表名白名单校验，新增表名会让**整批** push 失败 → outbox 全标 failed。
///
/// 真机跨设备同步报 4xx 时，把下面 `'kp_groups'` / `'note_assets'` 两行
/// 注释掉即可秒回退：这两张表不再上行，其余 14 张表与本地功能不受影响。
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
  'homeworks',
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

/// 服务端 skipped 行的自动重推总轮数上限（含首轮）。
///
/// 第 1 轮被守卫跳过后，adoption 会把本地 version 抬到服务端 authStart，
/// 刷新 outbox 行的 base_version / payload 后第 2 轮必然 `incoming >=
/// authStart`。给 2 轮足以自愈；仍 skipped 就留 pending，不无限重试。
const int kMaxSkippedRetryRounds = 2;

/// 推送结果。
class PushReport {
  const PushReport({
    required this.pushed,
    required this.failed,
    required this.serverTime,
    this.skipped = 0,
  });
  final int pushed;
  final int failed;

  /// 服务端「防陈旧覆盖」守卫跳过、经自动重推后仍未落库的条数。
  /// 这些行保留在 outbox 的 pending 里，等下次同步再试。
  final int skipped;
  final DateTime serverTime;
}

/// 本地同步数据的**总览**（设置页「数据版本」卡的本机一侧）。
///
/// ⚠️ 口径说明（必须与服务端 [SyncManifest] 的口径一起读）：
/// - [count] 是 [kSyncTableAllowlist] 16 张表的**总行数**，含软删（tombstone）
///   行——本地删除是软删（`deleted_at` 非空但行还在），服务端也存墓碑，两边
///   都算进去才可比；`ai_providers` 等 3 张不同步的表**不在**统计范围内；
/// - [maxVersion] 是 16 张表里最大的 `version`。它是**逐实体修订号**，不是
///   全局 generation：每个实体各自从 1 起算，且每次「上传」都会跑全量
///   `pushAll`，服务端对**未变化的行**也做 `max(既有, 声明) + 1`，所以服务
///   端版本会一路爬升、本机与服务器的数字**不必然相等**。本视图只回答
///   「两边大概差多少」，不是一致性断言。
class SyncOverview {
  const SyncOverview({required this.count, required this.maxVersion});

  /// 16 张同步表的总行数（含墓碑）。
  final int count;

  /// 16 张同步表里最大的 `version`（无任何行时为 0）。
  final int maxVersion;
}

/// 拉取结果。
class PullReport {
  const PullReport({
    required this.applied,
    required this.skipped,
    required this.serverTime,
    this.keptLocal = 0,
    this.conflictsMerged = 0,
    this.deleted = 0,
  });
  final int applied;

  /// 自回声跳过（本机自己上传的行）。
  final int skipped;

  /// 拉到了、但 LWW 判定「保留本地」而**没有落库**的条数。
  /// 与 [applied] 分开计数，避免「零写入也报应用 N 条」的假成功。
  final int keptLocal;

  /// 正文冲突时，输的一方被**内联合并**进胜方笔记的条数（P0）。
  ///
  /// 与 [applied] 分开：内联合并是「在胜方笔记里追加输方内容」的冲突解决动作，
  /// 既不是「应用远端变更」也不算「保留本地」，单独计数便于观察冲突频率。
  final int conflictsMerged;

  /// 拉取时因 tombstone 而在本地被硬删的条数。
  ///
  /// 与 [applied] 分开：删除不是「应用远端变更」，单独计数避免「应用 N 条」虚高。
  final int deleted;
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
  }) {
    return _pushWithRetry(
      limit: limit,
      includeFailed: includeFailed,
      api: api,
      round: 0,
    );
  }

  /// 服务端返回 skipped 时，刷新这些行后自动重推，最多
  /// [kMaxSkippedRetryRounds] 轮；仍 skipped 就留 pending 并记 warning。
  ///
  /// 为什么不直接标 failed：failed 行会被追加在新 pending 行之后，形成
  /// `[新版, 旧版]` 批内乱序，中继的 `authStart` 批内不重读，旧行会以更高
  /// 版本把旧正文写回云端（反向倒灌）。留 pending 才安全。
  Future<PushReport> _pushWithRetry({
    required int limit,
    required bool includeFailed,
    required SyncApi? api,
    required int round,
  }) async {
    final report = await _pushOnce(
      limit: limit,
      includeFailed: includeFailed,
      api: api,
    );
    if (report.skipped == 0 || round >= kMaxSkippedRetryRounds - 1) {
      if (report.skipped != 0) {
        _log.w('${report.skipped} 条仍被服务端跳过，保留 pending 等下次同步');
      }
      return report;
    }
    _log.i('${report.skipped} 条被服务端跳过，已刷新 payload/version，'
        '自动重推第 ${round + 2} 轮');
    final again = await _pushWithRetry(
      limit: limit,
      includeFailed: includeFailed,
      api: api,
      round: round + 1,
    );
    return PushReport(
      pushed: report.pushed + again.pushed,
      failed: report.failed + again.failed,
      skipped: again.skipped,
      serverTime: again.serverTime,
    );
  }

  Future<PushReport> _pushOnce({
    required int limit,
    required bool includeFailed,
    required SyncApi? api,
  }) async {
    final target = api ?? _api;
    // 字节预算 / 单条硬上限按后端取值（edgeone 收紧到 850KB）。
    final budget = target.pushBatchBudgetBytes;
    final maxEnv = target.maxEnvelopeBytes;
    final pending = await _outbox.pending(limit: limit);
    final failed = includeFailed
        ? await _outbox.failedPending(limit: limit - pending.length)
        : <SyncOutboxRow>[];
    // 【必须】稳定按 baseVersion 升序：同键的旧行在前、新行在后。
    // `[...pending, ...failed]` 会把之前 failed 的旧行追加在新 pending 行
    // 之后；服务端 `authStart` 每键每批只读一次、守卫永远跟批前版本比，
    // 于是 [v2, v1] 里 v1 只要 `v1 >= authStart` 也会被接受且算出更高的
    // `newVer = running+1` → 旧正文以最高版本写回云端，对端 `_compare`
    // 判「远端更新」主动 apply 旧正文。排成 [v1, v2] 后最后写入的是新行。
    final rows = _stableSortBy<SyncOutboxRow>(
      <SyncOutboxRow>[...pending, ...failed],
      (r) => r.baseVersion,
    );
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
      final payload = _decodePayload(r.payloadJson);
      final env = SyncEnvelope(
        deviceId: r.deviceId,
        entityTable: r.entityTable,
        entityId: r.entityId,
        op: SyncOp.parse(r.op),
        payload: payload,
        baseVersion: r.baseVersion,
        // 与 pushAll（:417 附近）口径一致：用行真正的 updated_at，而不是
        // 发件箱创建时间。旧写法把「上传时间」带进 _hydrate，会污染
        // _compare 的平局判定；JSON 往返后是 ISO 字符串，必须走 _dt。
        updatedAt: _dt(payload?['updated_at']) ?? r.createdAt,
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
    var skippedCount = 0;
    var serverTime = DateTime.now().toUtc();

    for (final batch in batches) {
      final ids = <int>[for (final e in batch) e.row.id];
      await _outbox.markSending(ids);
      try {
        final result =
            await target.pushBatch(<SyncEnvelope>[for (final e in batch) e.envelope]);
        final skippedKeys = result.skipped.toSet();
        final doneIds = <int>[];
        final skippedEntries = <_PushEntry>[];
        for (final e in batch) {
          final key = '${e.envelope.entityTable}:${e.envelope.entityId}';
          if (skippedKeys.contains(key)) {
            skippedEntries.add(e);
          } else {
            doneIds.add(e.row.id);
          }
        }
        // 只有真正落库的行才标 done；skipped 的绝不能清掉。
        if (doneIds.isNotEmpty) {
          await _outbox.markPushed(doneIds);
          // 笔记上行成功后，把「刚推上去的正文」记为基线（本机与服务器已收敛），
          // 供后续拉取时的段级三方合并（P2）使用。
          for (final e in batch) {
            if (doneIds.contains(e.row.id) && e.envelope.entityTable == 'notes') {
              final md = (e.envelope.payload?['content_md'] as String?) ?? '';
              if (md.isNotEmpty) {
                await _writeBaseline(
                  e.envelope.entityId,
                  md,
                  e.envelope.baseVersion,
                  e.envelope.updatedAt,
                );
              }
            }
          }
        }
        pushed += result.accepted;
        serverTime = result.serverTime;
        // 把服务端权威版本回写本地，使本地 version 与服务器对齐
        // （pull 侧不调版本，这是本地 version 的唯一权威来源）。
        // 必须先于 skipped 行刷新：刷新要读到 adoption 之后的 version。
        if (result.versions.isNotEmpty) {
          await _adoptServerVersions(result.versions);
        }
        // skipped 行：用当前库整行重建 payload + base_version，重置 pending。
        // adoption 已把本地 version 抬到 authStart，重推 incoming >= authStart。
        for (final e in skippedEntries) {
          final refreshed = await _refreshSkippedRow(e.row);
          if (!refreshed) {
            // 实体行已被物理删除，无法重建 payload：只重置 pending，
            // 否则会永远卡在 sending（pending()/failedPending() 都取不到）。
            await _outbox.markPending(<int>[e.row.id]);
          }
        }
        skippedCount += skippedEntries.length;
        if (skippedEntries.isNotEmpty) {
          _log.w('${skippedEntries.length} 条被服务端防陈旧覆盖守卫跳过'
              '（未落库），已刷新并重置 pending');
        }
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
      skipped: skippedCount,
      serverTime: serverTime,
    );
  }

  /// 用当前库里的整行最终态刷新一条 skipped outbox 行，并重置为 pending。
  /// 返回 false 表示实体行已不存在（调用方只重置 pending）。
  Future<bool> _refreshSkippedRow(SyncOutboxRow row) async {
    final payload = await _readRowPayload(row.entityTable, row.entityId);
    if (payload == null) return false;
    await _outbox.refreshAndRequeue(
      id: row.id,
      payloadJson: encodeSyncJson(payload),
      baseVersion: (payload['version'] as num?)?.toInt() ?? row.baseVersion,
    );
    return true;
  }

  /// 按 (table,id) 读整行并转成 payload（供 [_refreshSkippedRow] 用）。
  ///
  /// [_readLocalRow] 对 15 张表已返回完整的 `*RowToMap`；唯独 `note_assets`
  /// 是 LWW 轻量查询（只 3 列），重建 payload 必须整行 select，否则会把数 MB
  /// 的 `data_base64` 丢掉。
  Future<Map<String, dynamic>?> _readRowPayload(String table, String id) async {
    if (table == 'note_assets') {
      final r = await (_db.select(_db.noteAssets)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      return r == null ? null : noteAssetRowToMap(r);
    }
    return _readLocalRow(table, id);
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

  /// 全量快照推送：把 [kSyncTableAllowlist] 里 16 张表的**所有现存行**当作
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
    var skipped = 0;
    var serverTime = DateTime.now().toUtc();

    // 边读边发：缓冲到字节预算就整批下发，内存峰值 ≈ 一个批次（4MB）
    // 加上一页数据，而不是整张表。
    final buffer = <_SnapshotEntry>[];
    var bufferBytes = 0;

    Future<void> flush() async {
      if (buffer.isEmpty) return;
      // 【必须】稳定按 baseVersion 升序，与 push() 同一口径：批内同键旧行
      // 在前、新行在后，避免 [新版, 旧版] 倒灌（服务端 authStart 批内不重读，
      // 旧行会被接受并以更高版本覆盖新行）。
      final ordered = _stableSortBy<_SnapshotEntry>(
        buffer,
        (e) => e.envelope.baseVersion,
      );
      final batches = _splitBatches<_SnapshotEntry>(
        ordered,
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
          // 取舍：全量快照的 envelope 不经过 outbox，所以这里被跳过的行
          // **没有重推路径**（只有 push()/pushDrain 带 _pushWithRetry）。
          // 这是可接受的：用户刚编辑的行已在先跑的 pushDrain 里自愈；
          // 快照里被跳过的多半是「云端版本较新、本地落后」的行，跳过本来
          // 就是正确行为，不该用本地旧数据覆盖云端——正确动作是「拉取」
          // 对齐。这里只如实计数，让设置页不再把它算进成功数。
          skipped += result.skipped.length;
          serverTime = result.serverTime;
          // 把服务端权威版本回写本地（pull 侧不调版本）。
          if (result.versions.isNotEmpty) {
            await _adoptServerVersions(result.versions);
          }
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

    _log.i('pushAll 完成：pushed=$pushed failed=$failed skipped=$skipped');
    return PushReport(
      pushed: pushed,
      failed: failed,
      skipped: skipped,
      serverTime: serverTime,
    );
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
      case 'homeworks':
        final rows = await (_db.select(_db.homeworks)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(limit, offset: offset))
            .get();
        return rows.map(homeworkRowToMap).toList();
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
    var skipped = 0;
    var serverTime = DateTime.now().toUtc();
    var idleRounds = 0;

    for (var round = 1; round <= maxRounds; round++) {
      final report = await push(api: api, limit: batchLimit);
      pushed += report.pushed;
      failed += report.failed;
      skipped = report.skipped;
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

    _log.i('pushDrain 完成：pushed=$pushed failed=$failed skipped=$skipped');
    return PushReport(
      pushed: pushed,
      failed: failed,
      skipped: skipped,
      serverTime: serverTime,
    );
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
    var keptLocal = 0;
    var conflictsMerged = 0;
    var deleted = 0;
    for (final env in result.envelopes) {
      // 自回声：本机产生的变更不需要再次 merge（外层 push 已经应用）
      if (env.deviceId == deviceId) {
        skipped++;
        continue;
      }
      final outcome = await _merge(env);
      if (outcome == _MergeOutcome.keptLocal) {
        keptLocal++;
      } else if (outcome == _MergeOutcome.conflictMerged) {
        conflictsMerged++;
      } else if (outcome == _MergeOutcome.deleted) {
        deleted++;
      } else {
        applied++;
      }
    }
    _lastPulledAt = result.serverTime;
    _log.i('pull applied=$applied skipped=$skipped keptLocal=$keptLocal '
        'conflictsMerged=$conflictsMerged server_time=${result.serverTime}');
    return PullReport(
      applied: applied,
      skipped: skipped,
      keptLocal: keptLocal,
      conflictsMerged: conflictsMerged,
      deleted: deleted,
      serverTime: result.serverTime,
    );
  }

  /// 外部更新 last_pulled_at（例如从持久化恢复）。
  void updateLastPulledAt(DateTime t) {
    _lastPulledAt = t;
  }

  // ============ 本地总览（设置页「数据版本」卡）============

  /// 统计本机同步范围（[kSyncTableAllowlist] 的 16 张表）的记录数与最大版本。
  ///
  /// 为什么单独提供：设置页要显示「本机 vs 服务器」的总览，但**不让 UI 直接
  /// 写 SQL**——表名清单的唯一真相源是 [kSyncTableAllowlist]，写死在 UI 里会
  /// 在加表/减表时静默失配。
  ///
  /// 实现是 16 次 `SELECT COUNT(*), MAX(version)`（每表一次，走索引/全表扫但
  /// 不读 payload，因此 [note_assets] 的 `data_base64` 不会被拉进内存）。
  /// 表名来自编译期常量，不是用户输入 → 无注入面。
  Future<SyncOverview> localOverview() async {
    var count = 0;
    var maxVersion = 0;
    for (final table in kSyncTableAllowlist) {
      final stat = await _tableStat(table);
      count += stat.count;
      if (stat.maxVersion > maxVersion) maxVersion = stat.maxVersion;
    }
    return SyncOverview(count: count, maxVersion: maxVersion);
  }

  /// 单表的 `COUNT(*)` + `MAX(version)`。
  ///
  /// 空表时 SQLite 的 `MAX()` 返回 NULL → 用 [readNullable] 读并回落 0。
  Future<({int count, int maxVersion})> _tableStat(String table) async {
    final row = await _db
        .customSelect('SELECT COUNT(*) AS c, MAX(version) AS m FROM $table')
        .getSingle();
    return (
      count: row.read<int>('c'),
      maxVersion: row.readNullable<int>('m') ?? 0,
    );
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

  Future<_MergeOutcome> _merge(SyncEnvelope env) async {
    final local = await _readLocalVersion(env.entityTable, env.entityId);
    if (env.deletedAt != null) {
      // tombstone：硬删本地
      await _deleteLocal(env.entityTable, env.entityId);
      return _MergeOutcome.deleted;
    }
    if (local == null) {
      // 本地无记录，直接 apply；notes 同时记下收敛基线，供后续 pull 判断「本地是否改过」。
      await _applyInsert(env);
      if (env.entityTable == 'notes') {
        final md = (env.payload?['content_md'] as String?) ?? '';
        await _writeBaseline(env.entityId, md, env.baseVersion, env.updatedAt);
      }
      return _MergeOutcome.inserted;
    }
    // notes 走特判：正文冲突时做段级三方合并或落「冲突副本」，避免输方被静默丢弃。
    if (env.entityTable == 'notes') {
      return _mergeNote(env, local);
    }
    final cmp = _compare(env, local);
    if (cmp > 0) {
      await _applyUpdate(env);
      return _MergeOutcome.applied;
    }
    _log.d('LWW keep local：${env.entityTable}/${env.entityId}');
    return _MergeOutcome.keptLocal;
  }

  /// 返回 -1 / 0 / 1：remote vs local。
  int _compare(SyncEnvelope env, _LocalVer local) {
    if (env.baseVersion > local.version) return 1;
    if (env.baseVersion < local.version) return -1;
    // baseVersion 相等 → 看时间
    return env.updatedAt.isAfter(local.updatedAt) ? 1 : -1;
  }

  // ============ notes 特判（P0 不丢输方 + P2 段级三方合并 / 内联合并）============

  /// 笔记的合并特判：在普通 LWW 之上，检测正文（content_md）是否真冲突，并避免
  /// 把「远端单纯比本地新（本地未改过）」误判成冲突。
  ///
  /// 判定顺序：
  /// 1. 本地无记录 → 直接插入，并把远端正文记为收敛基线。
  /// 2. 正文相同 → 走普通 LWW（只是标题/置顶等元数据差异，无需冲突处理）；
  ///    落库后同样刷新基线。
  /// 3. 正文不同，但本地正文 == 收敛基线 → 说明本地自上次同步后**没改过**，
  ///    远端是更新真相，干净按 LWW 应用远端，不触发冲突合并（防「假冲突」）。
  /// 4. 正文不同且有基线 → 段级三方合并（[threeWayMergeNotes]）：
  ///    不同段落各自保留，仅在「两边都改了同一段」时回落冲突处理；
  ///    合并结果过 L1 安全校验才落地，否则回落内联合并。
  /// 5. 正文不同但无基线（首次分叉，无共同祖先）→ 回落内联合并。
  ///
  /// 冲突回落（4/5）不再另开冲突副本：把「输方」正文作为带标记的段落**内联**
  /// 进胜方笔记（[inlineMergeNotesConflict]），保证输方内容不被静默丢弃（P0）。
  Future<_MergeOutcome> _mergeNote(SyncEnvelope env, _LocalVer local) async {
    final localRow = await _readLocalRow('notes', env.entityId);
    final remotePayload = env.payload;
    if (localRow == null || remotePayload == null) {
      // 退化到普通 LWW（理论不可达：_merge 已保证 local != null 且非 tombstone）。
      final cmp = _compare(env, local);
      if (cmp > 0) {
        await _applyUpdate(env);
        return _MergeOutcome.applied;
      }
      return _MergeOutcome.keptLocal;
    }
    final localMd = (localRow['content_md'] as String?) ?? '';
    final remoteMd = (remotePayload['content_md'] as String?) ?? '';

    // 正文相同 → 整行走普通 LWW，无需冲突处理；落库后刷新收敛基线。
    if (localMd == remoteMd) {
      final cmp = _compare(env, local);
      if (cmp > 0) {
        await _applyUpdate(env);
        await _writeBaseline(env.entityId, remoteMd, env.baseVersion, env.updatedAt);
        return _MergeOutcome.applied;
      }
      return _MergeOutcome.keptLocal;
    }

    // 正文不同 → 真正的正文冲突。
    final remoteWins = _compare(env, local) > 0;

    // 0) 关键护栏：若本地自上次收敛后**没改过**（local 正文 == 基线），
    // 则这是「远端单纯比本地新」而不是冲突——干净按 LWW 应用远端，
    // 否则会出现「假冲突」把旧正文又拼回笔记（见 sync_edit_propagation_test）。
    final baseline = await _readBaseline(env.entityId);
    if (baseline != null && localMd == baseline.contentMd) {
      if (remoteWins) {
        await _applyUpdate(env);
        await _writeBaseline(env.entityId, remoteMd, env.baseVersion, env.updatedAt);
        return _MergeOutcome.applied;
      }
      // 远端更旧且本地未改（本地即收敛内容）→ 保持，基线不变。
      return _MergeOutcome.keptLocal;
    }

    // 1) 尝试段级三方合并（需要「上次收敛内容」基线 + 本地确实改过）。
    if (baseline != null) {
      final merged = threeWayMergeNotes(baseline.contentMd, localMd, remoteMd);
      // 合并结果必须真的不同于本地（否则等于没解决冲突，还是内联更稳）。
      if (merged != null && merged != localMd) {
        final mergedPayload = <String, dynamic>{...remotePayload, 'content_md': merged};
        await _applyUpdate(env.copyWith(payload: mergedPayload));
        await _writeBaseline(env.entityId, merged, env.baseVersion, env.updatedAt);
        _log.i('notes 三方合并成功：${env.entityId}');
        return _MergeOutcome.merged;
      }
    }

    // 2) 回落：把「输方」正文作为标记段落**内联**进胜方笔记（不另开副本，
    // 避免笔记越攒越多）。胜方正文保留，输方内容追加在末尾的「同步冲突」区块。
    _log.i('notes 内容冲突，内联合并进胜方笔记：${env.entityId}（remoteWins=$remoteWins）');
    if (remoteWins) {
      // 胜方 = 远端；输方 = 本地旧正文，追加进笔记。
      final merged = inlineMergeNotesConflict(
        remoteMd,
        localMd,
        localRow['device_id'] as String?,
        localRow['updated_at'] as DateTime?,
      );
      final finalContent = merged ?? remoteMd;
      await _applyUpdate(env.copyWith(
        payload: <String, dynamic>{...remotePayload, 'content_md': finalContent},
      ));
      await _writeBaseline(env.entityId, finalContent, env.baseVersion, env.updatedAt);
    } else {
      // 胜方 = 本地（保持）；输方 = 远端正文，追加进本地笔记。
      final merged = inlineMergeNotesConflict(
        localMd,
        remoteMd,
        remotePayload['device_id'] as String?,
        _dt(remotePayload['updated_at']),
      );
      final finalContent = merged ?? localMd;
      // 合并后整体抬一档版本号（取本地/远端较高者 +1），保证回推时严格晚于对端
      // 当前版本，避免被 LWW 平局 / 旧版本覆盖（见 [_compare]）。
      final bumped = (local.version > env.baseVersion ? local.version : env.baseVersion) + 1;
      final now = DateTime.now().toUtc();
      final mergedPayload = <String, dynamic>{
        ...localRow,
        'content_md': finalContent,
        'version': bumped,
        'updated_at': now,
        'device_id': deviceId,
      };
      await _upsertLocal('notes', mergedPayload);
      // 回推：把合并结果登记进发件箱，让服务器与另一台设备也拿到合并后的笔记。
      // 否则冲突只在本地解决，对端仍是旧版本，造成长期分叉。
      await _enqueueMergedNote(mergedPayload);
      // 写基线 = 合并后内容：本机已与（回推后的）服务器收敛到 merged，
      // 避免下次 pull 又把本地误判为「未改」而重复触发冲突合并。
      await _writeBaseline(env.entityId, finalContent, bumped, now);
    }
    return _MergeOutcome.conflictMerged;
  }

  /// 读笔记的同步基线（上次与服务器收敛后的正文）；无则返回 null。
  Future<({String contentMd, int version, DateTime updatedAt})?> _readBaseline(
    String noteId,
  ) async {
    final row = await (_db.select(_db.noteSyncBaseline)
          ..where((t) => t.noteId.equals(noteId)))
        .getSingleOrNull();
    if (row == null) return null;
    return (
      contentMd: row.contentMd,
      version: row.version,
      updatedAt: row.updatedAt,
    );
  }

  /// 写/更新笔记同步基线（按 note_id 主键 upsert）。
  Future<void> _writeBaseline(
    String noteId,
    String contentMd,
    int version,
    DateTime updatedAt,
  ) async {
    await _db.into(_db.noteSyncBaseline).insertOnConflictUpdate(
          NoteSyncBaselineCompanion(
            noteId: Value(noteId),
            contentMd: Value(contentMd),
            version: Value(version),
            updatedAt: Value(updatedAt),
          ),
        );
  }

  /// 把合并后的笔记正文登记进 outbox（回推），让冲突结果跨设备收敛。
  ///
  /// 入队失败不阻断本地合并——outbox 是旁路记账，失败只记日志（见
  /// [SyncOutboxWriter] 的契约）。
  Future<void> _enqueueMergedNote(Map<String, dynamic> payload) async {
    try {
      await _outbox.enqueue(
        entityTable: 'notes',
        entityId: payload['id'] as String,
        op: SyncOp.upsert,
        payload: payload,
        baseVersion: (payload['version'] as num?)?.toInt() ?? 1,
      );
    } on Object catch (e, s) {
      _log.e('合并笔记回推入队失败', error: e, stackTrace: s);
    }
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
      case 'homeworks':
        final r = await (_db.select(_db.homeworks)..where((t) => t.id.equals(id))).getSingleOrNull();
        return r == null ? null : homeworkRowToMap(r);
      default:
        _log.w('未知表 $table，跳过读 local');
        return null;
    }
  }

  /// 把服务端 push 返回的权威 `versions` 映射回写本地行，使本地 `version`
  /// 列与服务器对齐。
  ///
  /// 服务端在 push 时计算 `newVer = max(服务器现有版本, 客户端声明 baseVersion) + 1`
  /// 并落库，返回 `versions{ "<table>:<id>": newVer }`。这里逐键解析
  /// （键格式 `<entity_table>:<entity_id>`，首个冒号分隔表名与 id），把本地
  /// 对应行的 `version` 抬到同一值。
  ///
  /// 为什么需要它：pull 侧**不**调整版本（按用户决策——拉取直接覆盖、不做
  /// 冲突检测），于是本地 `version` 的唯一权威来源就是这里的 adoption。若
  /// 不做，本地 version 停留在「上次写库时的值」，后续 [pull] 的 LWW 比较
  /// （`remote.baseVersion` vs `local.version`）会因本地版本落后而误判。
  ///
  /// 只写 `version` 一列，不触发整行 upsert（避免触碰其它字段）；本地行已
  /// 被硬删（tombstone 场景）时 `where id` 命中 0 行，静默 no-op。
  Future<void> _adoptServerVersions(Map<String, int> versions) async {
    for (final entry in versions.entries) {
      final sep = entry.key.indexOf(':');
      if (sep <= 0) continue;
      final table = entry.key.substring(0, sep);
      final id = entry.key.substring(sep + 1);
      await _updateLocalVersion(table, id, entry.value);
    }
  }

  Future<void> _updateLocalVersion(String table, String id, int version) async {
    switch (table) {
      case 'notebooks':
        await (_db.update(_db.notebooks)..where((t) => t.id.equals(id)))
            .write(NotebooksCompanion(version: Value(version)));
        break;
      case 'notes':
        await (_db.update(_db.notes)..where((t) => t.id.equals(id)))
            .write(NotesCompanion(version: Value(version)));
        break;
      case 'knowledge_points':
        await (_db.update(_db.knowledgePoints)..where((t) => t.id.equals(id)))
            .write(KnowledgePointsCompanion(version: Value(version)));
        break;
      case 'prerequisite_edges':
        await (_db.update(_db.prerequisiteEdges)..where((t) => t.id.equals(id)))
            .write(PrerequisiteEdgesCompanion(version: Value(version)));
        break;
      case 'mastery_records':
        await (_db.update(_db.masteryRecords)..where((t) => t.id.equals(id)))
            .write(MasteryRecordsCompanion(version: Value(version)));
        break;
      case 'cards':
        await (_db.update(_db.cards)..where((t) => t.id.equals(id)))
            .write(CardsCompanion(version: Value(version)));
        break;
      case 'canvases':
        await (_db.update(_db.canvases)..where((t) => t.id.equals(id)))
            .write(CanvasesCompanion(version: Value(version)));
        break;
      case 'canvas_nodes':
        await (_db.update(_db.canvasNodes)..where((t) => t.id.equals(id)))
            .write(CanvasNodesCompanion(version: Value(version)));
        break;
      case 'canvas_edges':
        await (_db.update(_db.canvasEdges)..where((t) => t.id.equals(id)))
            .write(CanvasEdgesCompanion(version: Value(version)));
        break;
      case 'ai_sessions':
        await (_db.update(_db.aiSessions)..where((t) => t.id.equals(id)))
            .write(AiSessionsCompanion(version: Value(version)));
        break;
      case 'ai_messages':
        await (_db.update(_db.aiMessages)..where((t) => t.id.equals(id)))
            .write(AiMessagesCompanion(version: Value(version)));
        break;
      case 'kp_groups':
        await (_db.update(_db.kpGroups)..where((t) => t.id.equals(id)))
            .write(KpGroupsCompanion(version: Value(version)));
        break;
      case 'note_assets':
        await (_db.update(_db.noteAssets)..where((t) => t.id.equals(id)))
            .write(NoteAssetsCompanion(version: Value(version)));
        break;
      case 'canvas_cards':
        await (_db.update(_db.canvasCards)..where((t) => t.id.equals(id)))
            .write(CanvasCardsCompanion(version: Value(version)));
        break;
      case 'canvas_strokes':
        await (_db.update(_db.canvasStrokes)..where((t) => t.id.equals(id)))
            .write(CanvasStrokesCompanion(version: Value(version)));
        break;
      case 'homeworks':
        await (_db.update(_db.homeworks)..where((t) => t.id.equals(id)))
            .write(HomeworksCompanion(version: Value(version)));
        break;
      default:
        _log.w('adoptServerVersions 遇到未知表 $table，跳过');
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
      case 'homeworks':
        await _db.into(_db.homeworks).insert(_homeworkFromMap(p), mode: InsertMode.insertOrReplace);
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
      case 'homeworks':
        await (_db.delete(_db.homeworks)..where((t) => t.id.equals(id))).go();
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
        // v8 新增：文件夹置顶。缺键（旧端 push 没带）回落默认 false，与列默认值一致。
        pinned: Value(_bool(p['pinned'], false)),
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
        // v8 新增：笔记置顶。缺键回落默认 false。
        pinned: Value(_bool(p['pinned'], false)),
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

  // ============ Homeworks ============
  //
  // ⚠️ `kp_ids_json` / `items_json` 整段搬运，同步层不解析
  // （薄弱点快照与题目的编解码归 HomeworkRepository）。

  /// homeworks payload → Companion（pull 落库）。
  ///
  /// ⚠️ fallback 对着 `tables.dart` 的 `withDefault` 抄：`status` 默认是
  /// **`'assigned'`**（不是 ''、不是 'draft'）——抄错会让对端每次 pull 把
  /// 作业状态刷成空值。`items_json` / `kp_ids_json` 默认 `'[]'`（抄成 '' 会丢题）。
  /// `due_at` / `deleted_at` / `updated_at` 是 DateTime 列，必须走 `_dt()`：
  /// pull 的 payload 已过 JSON 往返，DateTime 会变成 ISO 字符串。
  HomeworksCompanion _homeworkFromMap(Map<String, dynamic> p) => HomeworksCompanion(
        id: Value(p['id'] as String),
        canvasId: Value((p['canvas_id'] as String?) ?? ''),
        title: Value((p['title'] as String?) ?? ''),
        kpIdsJson: Value((p['kp_ids_json'] as String?) ?? '[]'),
        itemsJson: Value((p['items_json'] as String?) ?? '[]'),
        kpId: Value(p['kp_id'] as String?),
        batchId: Value(p['batch_id'] as String?),
        status: Value((p['status'] as String?) ?? 'assigned'),
        dueAt: Value(_dt(p['due_at'])),
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

/// [SyncEngine._merge] 的结果：区分「真正落库」与「LWW 保留本地」。
/// 只有前三者计入 [PullReport.applied]，避免零写入也报「应用 N 条」。
enum _MergeOutcome { inserted, applied, deleted, keptLocal, merged, conflictMerged }

/// 稳定地按 [key] 升序排序：相等元素保持原顺序（Dart 的 `List.sort` 不稳定）。
/// 批内 envelope 必须用它排，保证同 baseVersion 的行不因排序抖动而乱序。
List<T> _stableSortBy<T>(List<T> src, int Function(T) key) {
  final indexed = <({int index, T value})>[
    for (var i = 0; i < src.length; i++) (index: i, value: src[i]),
  ];
  indexed.sort((a, b) {
    final cmp = key(a.value).compareTo(key(b.value));
    return cmp != 0 ? cmp : a.index.compareTo(b.index);
  });
  return <T>[for (final e in indexed) e.value];
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
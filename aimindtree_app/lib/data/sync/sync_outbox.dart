/// SyncOutbox 仓储（T03）。
///
/// 每次本地写（upsert/delete）都会在 outbox 留一条记录：
/// - enqueue 时序列化最终态 payload；
/// - pending / markSending / markPushed / markFailed 控制推生命周期；
/// - cleanDone 定期清理已完成的旧记录（默认保留 7 天）。
///
/// 注意：outbox 行**不参与自身同步**（sync_outbox 不在 SyncMeta 表清单）。
library;

import 'package:drift/drift.dart';

import '../db/drift_database.dart';
import 'sync_json.dart';
import 'sync_types.dart';

class SyncOutboxRepo {
  SyncOutboxRepo(this._db, {required this.deviceId});
  final AppDatabase _db;
  final String deviceId;

  /// 本 outbox 所属的数据库实例（接线一致性校验用）。
  AppDatabase get db => _db;

  /// **全局接线点**：生产环境在 `ExtractionService.bootstrap` 里赋值，
  /// 仓储层（`KnowledgeRepository` / `TreeRepository` / `AiSessionRepository`）
  /// 写完本地库后就用它入队，实现「本地 → 服务端」上行同步。
  ///
  /// - 生产：`bootstrap` 里 `SyncOutboxRepo.current = outbox;`（本对象与
  ///   仓储共用同一个 [AppDatabase]）。
  /// - 测试：默认 `null` → 仓储层不入队、也不崩（不入队 = 不影响断言）。
  ///
  /// 之所以用静态字段而不是往仓储构造函数里注入：仓储在 UI 各页被直接
  /// `KnowledgeRepository(db)` 构造（测试也大量这么用），改签名会破坏既有调用。
  static SyncOutboxRepo? current;

  // ============ 写入 ============

  /// 入队一行变更。
  ///
  /// [baseVersion] 是该行**变更后**的 version（新插入通常 1，更新为 version+1）；
  /// 服务端把它当作该行的目标 version（LWW 判定 + pull 落地都用它），
  /// 所以必须填「写完之后那行的新 version」，不是变更前的旧值。
  ///
  /// [payload] 是行最终态（键 = 表的 snake_case 列名，见 `sync_row_map.dart`）。
  /// `op=delete` 时 payload 至少要带 `deleted_at`（墓碑时间）——传输层
  /// `SyncEnvelope.deletedAt` 就是从 payload 里取的。
  ///
  /// [deletedAt] 形参以前是死参（insert 时没写入任何列），现在会补写进
  /// payload 的 `deleted_at` 键（payload 已自带该键时以 payload 为准）。
  Future<int> enqueue({
    required String entityTable,
    required String entityId,
    required SyncOp op,
    required Map<String, dynamic>? payload,
    required int baseVersion,
    DateTime? deletedAt,
  }) async {
    final body = <String, dynamic>{...?payload};
    if (deletedAt != null) {
      body.putIfAbsent('deleted_at', () => deletedAt);
    }
    return _db.into(_db.syncOutbox).insert(SyncOutboxCompanion(
          entityTable: Value(entityTable),
          entityId: Value(entityId),
          op: Value(op.name),
          // DateTime 会被转成 ISO 8601 字符串（jsonEncode 默认不支持 DateTime）。
          payloadJson: Value(encodeSyncJson(body)),
          deviceId: Value(deviceId),
          baseVersion: Value(baseVersion),
          status: Value(OutboxStatus.pending.name),
          createdAt: Value(DateTime.now().toUtc()),
        ));
  }

  // ============ 状态流转 ============

  /// 取出 pending 状态的行（按 id 升序，保证先进先出）。
  Future<List<SyncOutboxRow>> pending({int limit = 100}) {
    return (_db.select(_db.syncOutbox)
          ..where((t) => t.status.equals(OutboxStatus.pending.name))
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(limit))
        .get();
  }

  /// 待重试的失败行（指数退避后回到 pending）。
  Future<List<SyncOutboxRow>> failedPending({int limit = 100}) {
    return (_db.select(_db.syncOutbox)
          ..where((t) => t.status.equals(OutboxStatus.failed.name))
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(limit))
        .get();
  }

  /// 标记为 sending（防重推；同一 outbox row 在 sending 期间不会被 pending() 取到）。
  Future<void> markSending(List<int> ids) async {
    if (ids.isEmpty) return;
    await (_db.update(_db.syncOutbox)..where((t) => t.id.isIn(ids)))
        .write(SyncOutboxCompanion(status: Value(OutboxStatus.sending.name)));
  }

  /// 标记推送成功（done）。
  Future<void> markPushed(List<int> ids) async {
    if (ids.isEmpty) return;
    await (_db.update(_db.syncOutbox)..where((t) => t.id.isIn(ids)))
        .write(SyncOutboxCompanion(status: Value(OutboxStatus.done.name)));
  }

  /// 标记推送失败：retryCount+1，状态回到 failed。
  Future<void> markFailed(List<int> ids) async {
    if (ids.isEmpty) return;
    // 走 customUpdate 因为 Companion 字段不接受 Expression。
    // id 都是自增整数，安全拼接到 IN list（无注入风险）。
    final inList = ids.join(',');
    await _db.customUpdate(
      "UPDATE sync_outbox SET status='failed', retry_count = retry_count + 1 "
      "WHERE id IN ($inList)",
      updates: {_db.syncOutbox},
    );
  }

  /// 失败行 → pending（指数退避后重试入口）。
  Future<int> retryFailed() async {
    return _db.customUpdate(
      "UPDATE sync_outbox SET status='pending' WHERE status='failed'",
      updates: {_db.syncOutbox},
    );
  }

  // ============ 维护 ============

  /// 删除 status='done' 且 createdAt < [before] 的旧行（防止表膨胀）。
  Future<int> cleanDone({DateTime? before}) async {
    final cutoff = before ?? DateTime.now().toUtc().subtract(const Duration(days: 7));
    return (_db.delete(_db.syncOutbox)
          ..where((t) =>
              t.status.equals(OutboxStatus.done.name) &
              t.createdAt.isSmallerThanValue(cutoff)))
        .go();
  }

  // ============ 查询 ============

  Future<int> pendingCount() async {
    final row = await (_db.selectOnly(_db.syncOutbox)
          ..addColumns([_db.syncOutbox.id.count()])
          ..where(_db.syncOutbox.status.equals(OutboxStatus.pending.name)))
        .map((r) => r.read(_db.syncOutbox.id.count()))
        .getSingle();
    return row ?? 0;
  }

  Future<int> failedCount() async {
    final row = await (_db.selectOnly(_db.syncOutbox)
          ..addColumns([_db.syncOutbox.id.count()])
          ..where(_db.syncOutbox.status.equals(OutboxStatus.failed.name)))
        .map((r) => r.read(_db.syncOutbox.id.count()))
        .getSingle();
    return row ?? 0;
  }
}
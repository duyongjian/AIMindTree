/// SyncOutbox 仓储（T03）。
///
/// 每次本地写（upsert/delete）都会在 outbox 留一条记录：
/// - enqueue 时序列化最终态 payload；
/// - pending / markSending / markPushed / markFailed 控制推生命周期；
/// - cleanDone 定期清理已完成的旧记录（默认保留 7 天）。
///
/// 注意：outbox 行**不参与自身同步**（sync_outbox 不在 SyncMeta 表清单）。
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/drift_database.dart';
import 'sync_types.dart';

class SyncOutboxRepo {
  SyncOutboxRepo(this._db, {required this.deviceId});
  final AppDatabase _db;
  final String deviceId;

  // ============ 写入 ============

  /// 入队一行变更。
  ///
  /// [baseVersion] 是该行变更前的本地 version（push 时服务端用作乐观锁，
  /// P0 暂不强制）。[payload] 是行最终态（已序列化为 Map）；op=delete 时
  /// 可传空 Map（保留壳位）。
  Future<int> enqueue({
    required String entityTable,
    required String entityId,
    required SyncOp op,
    required Map<String, dynamic>? payload,
    required int baseVersion,
    DateTime? deletedAt,
  }) async {
    return _db.into(_db.syncOutbox).insert(SyncOutboxCompanion(
          entityTable: Value(entityTable),
          entityId: Value(entityId),
          op: Value(op.name),
          payloadJson: Value(jsonEncode(payload ?? const <String, dynamic>{})),
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
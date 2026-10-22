/// 同步传输单位 + Outbox 状态枚举（T03）。
///
/// SyncEnvelope 是 push / pull 跨网络传输的最小单位：
/// - 本地 write → 序列化进 SyncOutbox.payloadJson → push 时还原成 envelope；
/// - pull 时服务端 envelope → 本地 merge → 还原成 row 落库。
///
/// OutboxStatus 控制推送生命周期，避免重复推或漏推。
library;

import '../../core/logger.dart';
import 'sync_json.dart';

/// 单条变更的传输语义。
enum SyncOp {
  /// 插入或更新（行最终态在 payload 里）。
  upsert,

  /// 删除（payload 通常为 null；deletedAt 非空）。
  delete;

  static SyncOp parse(String s) {
    for (final v in values) {
      if (v.name == s) return v;
    }
    return SyncOp.upsert;
  }
}

/// Outbox 行状态（P0 简化版）。
///
/// 生命周期：`pending` → `sending` → `done`（成功）
///                       └→ `failed`（失败，retryCount++，指数退避后再回到 pending）
enum OutboxStatus {
  pending,
  sending,
  done,
  failed;

  static OutboxStatus parse(String s) {
    for (final v in values) {
      if (v.name == s) return v;
    }
    return OutboxStatus.pending;
  }
}

/// 一次同步传输的不可变载体。
class SyncEnvelope {
  const SyncEnvelope({
    required this.deviceId,
    required this.entityTable,
    required this.entityId,
    required this.op,
    required this.payload,
    required this.baseVersion,
    required this.updatedAt,
    this.deletedAt,
  });

  /// 产生此变更的设备 id（用于自回声过滤）。
  final String deviceId;

  /// 表名（与 Drift 表名一致）。
  final String entityTable;

  /// 行 id。
  final String entityId;

  /// upsert：payload 是最终态；delete：payload 通常为空。
  final SyncOp op;

  /// 行序列化（nullable：delete 时为空）。
  final Map<String, dynamic>? payload;

  /// push 前的本地 version（服务端可用作乐观锁；P0 暂不强制）。
  final int baseVersion;

  /// 行 updated_at。
  final DateTime updatedAt;

  /// 软删除 tombstone（删除时非空）。
  final DateTime? deletedAt;

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'entity_table': entityTable,
        'entity_id': entityId,
        'op': op.name,
        // payload 里可能有 DateTime（updated_at / deleted_at）→ 转成 ISO 8601
        // 字符串，否则 jsonEncode 会抛 JsonUnsupportedObjectError。
        'payload': payload == null ? null : toJsonSafe(payload),
        'base_version': baseVersion,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'deleted_at': deletedAt?.toUtc().toIso8601String(),
      };

  factory SyncEnvelope.fromJson(Map<String, dynamic> json) {
    return SyncEnvelope(
      deviceId: json['device_id'] as String,
      entityTable: json['entity_table'] as String,
      entityId: json['entity_id'] as String,
      op: SyncOp.parse(json['op'] as String),
      payload: (json['payload'] as Map<String, dynamic>?),
      baseVersion: (json['base_version'] as num?)?.toInt() ?? 0,
      updatedAt: _parseDateTime(json['updated_at']),
      deletedAt: json['deleted_at'] == null
          ? null
          : _parseDateTime(json['deleted_at']),
    );
  }

  /// 宽容解析时间字段：接受 DateTime / ISO 8601 字符串 / null。
  static DateTime _parseDateTime(Object? v) {
    if (v is DateTime) return v;
    if (v is String) {
      return DateTime.tryParse(v) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  SyncEnvelope copyWith({
    String? deviceId,
    String? entityTable,
    String? entityId,
    SyncOp? op,
    Map<String, dynamic>? payload,
    int? baseVersion,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) =>
      SyncEnvelope(
        deviceId: deviceId ?? this.deviceId,
        entityTable: entityTable ?? this.entityTable,
        entityId: entityId ?? this.entityId,
        op: op ?? this.op,
        payload: payload ?? this.payload,
        baseVersion: baseVersion ?? this.baseVersion,
        updatedAt: updatedAt ?? this.updatedAt,
        deletedAt: deletedAt ?? this.deletedAt,
      );
}

/// 同毫秒排序不稳定的兜底（参考 MEMORY.md "Append-only 排序陷阱"）。
int envelopeSeqKey(SyncEnvelope e) =>
    (e.baseVersion << 32) ^ e.entityId.hashCode ^ e.updatedAt.millisecondsSinceEpoch;

class SyncLog {
  static final AppLog log = AppLog('sync');
}
/// AI 会话仓储（T06：老师模式 / 追问消息持久化）。
///
/// 设计：
/// - 一个 KP 对应一个 session（type=tutor/chat，按 AiTask 决定）。
/// - 消息按时间序追加，append-only（PRD：卡片 append-only 同理）。
/// - conversationId（Dify 会话）持久化在 session modelId 字段后的元数据里，
///   简化：存在内存态，App 重启后重新发起会话（Dify 会话重启即失效，但用户
///   仍能看到历史消息）。
library;

import 'package:drift/drift.dart';

import '../../ai/ai_task.dart';
import '../../core/id.dart';
import '../db/drift_database.dart';

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.createdAt,
  });
  final String id;
  final String sessionId;
  final String role; // user/assistant/system
  final String content;
  final DateTime createdAt;
}

class AiSessionRepository {
  AiSessionRepository(this._db);
  final AppDatabase _db;

  /// 获取或创建该 KP 的会话（每个 KP 一个 session）。
  Future<AiSessionRow> getOrCreateForKp({
    required String kpId,
    required AiTask task,
  }) async {
    final type = _sessionTypeFor(task);
    final rows = await (_db.select(_db.aiSessions)
          ..where((t) => t.kpId.equals(kpId) & t.type.equals(type))
          ..limit(1))
        .get();
    if (rows.isNotEmpty) return rows.first;
    final now = DateTime.now().toUtc();
    final id = newUlid();
    await _db.into(_db.aiSessions).insert(AiSessionsCompanion(
          id: Value(id),
          type: Value(type),
          targetRef: Value(kpId),
          title: Value(''),
          kpId: Value(kpId),
          modelId: const Value('dify-t1-local'),
          tutorState: const Value('{}'),
          updatedAt: Value(now),
          version: const Value(1),
          deviceId: const Value('local-dev'),
        ));
    return AiSessionRow(
      id: id,
      type: type,
      targetRef: kpId,
      title: '',
      kpId: kpId,
      modelId: 'dify-t1-local',
      tutorState: '{}',
      updatedAt: now,
      version: 1,
      deviceId: 'local-dev',
      deletedAt: null,
    );
  }

  /// 追加一条消息（不更新 updatedAt 字段以外的元数据）。
  Future<void> addMessage({
    required String sessionId,
    required String role,
    required String content,
    String? modelId,
  }) async {
    final now = DateTime.now().toUtc();
    await _db.into(_db.aiMessages).insert(AiMessagesCompanion(
          id: Value(newUlid()),
          sessionId: Value(sessionId),
          role: Value(role),
          contentMd: Value(content),
          modelId: Value(modelId),
          updatedAt: Value(now),
          version: const Value(1),
          deviceId: const Value('local-dev'),
        ));
  }

  /// 列出某 session 的全部消息（按时间序）。
  Future<List<ChatMessage>> listMessages(String sessionId) async {
    final rows = await (_db.select(_db.aiMessages)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([(t) => OrderingTerm.asc(t.updatedAt)]))
        .get();
    return rows
        .map((r) => ChatMessage(
              id: r.id,
              sessionId: r.sessionId,
              role: r.role,
              content: r.contentMd,
              createdAt: r.updatedAt,
            ))
        .toList();
  }

  static String _sessionTypeFor(AiTask t) {
    // 老师模式用 tutor；其他对话用 chat。
    return t == AiTask.t7Socratic ? 'tutor' : 'chat';
  }
}

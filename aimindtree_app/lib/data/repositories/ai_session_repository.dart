/// AI 会话仓储（T06：老师模式 / 追问消息持久化；H：AI 助手自由问答会话）。
///
/// 设计：
/// - 一个 KP 对应一个 session（type=tutor/chat，按 AiTask 决定）。
/// - 消息按时间序追加，append-only（PRD：卡片 append-only 同理）。
/// - conversationId（Dify 会话）持久化在 session modelId 字段后的元数据里，
///   简化：存在内存态，App 重启后重新发起会话（Dify 会话重启即失效，但用户
///   仍能看到历史消息）。
/// - H（AI 助手会话管理）：一个「会话」= 一行 **kpId 为空**的 type=chat
///   session，消息落 ai_messages。标题**运行时派生**（首条 user 消息 / 时间），
///   重命名写**现有** title 列（表本就带该列，严禁改表结构）。
library;

import 'package:drift/drift.dart';

import '../../ai/ai_task.dart';
import '../../core/id.dart';
import '../db/drift_database.dart';
import '../sync/sync_outbox_writer.dart';

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

  /// 上行同步写入器（把本地写登记进 outbox；未接线时自动跳过）。
  late final SyncOutboxWriter _sync = SyncOutboxWriter(_db);

  /// Agent 会话类型（H：AI 助手自由问答）。
  ///
  /// 复用 `chat`（与 T5 追问同类型），但以 **kpId 为空** 与 KP 绑定的
  /// 老师模式会话区分：[listAgentSessions] 只捞 kpId isNull 的 chat 行。
  static const String kAgentSessionType = 'chat';

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
    await _sync.upsertAiSession(id);
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

  /// 追加一条消息（顺带把会话 updatedAt 推到当前时间，会话列表据此排序）。
  Future<void> addMessage({
    required String sessionId,
    required String role,
    required String content,
    String? modelId,
  }) async {
    final now = DateTime.now().toUtc();
    final id = newUlid();
    await _db.into(_db.aiMessages).insert(AiMessagesCompanion(
          id: Value(id),
          sessionId: Value(sessionId),
          role: Value(role),
          contentMd: Value(content),
          modelId: Value(modelId),
          updatedAt: Value(now),
          version: const Value(1),
          deviceId: const Value('local-dev'),
        ));
    await _sync.upsertAiMessage(id);
    await _touchSession(sessionId, now: now);
  }

  /// 列出某 session 的全部消息（按时间序）。
  ///
  /// 软删铁律：`deleted_at` 非空的消息是墓碑，一律过滤（清空会话后不得复现）。
  Future<List<ChatMessage>> listMessages(String sessionId) async {
    final rows = await (_db.select(_db.aiMessages)
          ..where((t) => t.sessionId.equals(sessionId) & t.deletedAt.isNull())
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

  // ===================== H：Agent 会话管理 =====================

  /// 新建一条 Agent 会话（一个「会话」= 一行 ai_session）。
  ///
  /// 纯本地写，**不依赖 AI 可用性**：AI 不可用时历史会话照样能建、能看。
  Future<AiSessionRow> createAgentSession() async {
    final now = DateTime.now().toUtc();
    final id = newUlid();
    await _db.into(_db.aiSessions).insert(AiSessionsCompanion(
          id: Value(id),
          type: const Value(kAgentSessionType),
          targetRef: const Value(''),
          title: const Value(''),
          kpId: const Value(null),
          modelId: const Value('dify-t1-local'),
          tutorState: const Value('{}'),
          updatedAt: Value(now),
          version: const Value(1),
          deviceId: const Value('local-dev'),
        ));
    await _sync.upsertAiSession(id);
    return AiSessionRow(
      id: id,
      type: kAgentSessionType,
      targetRef: '',
      title: '',
      kpId: null,
      modelId: 'dify-t1-local',
      tutorState: '{}',
      updatedAt: now,
      version: 1,
      deviceId: 'local-dev',
      deletedAt: null,
    );
  }

  /// Agent 会话列表（最近活跃在前；AI 不可用时也可查看）。
  ///
  /// 只捞 kpId 为空的 chat 行：KP 绑定的老师模式会话不混入。
  /// 次级排序按 id 倒序：同一毫秒建的两个会话 ULID 仍可分出先后。
  Future<List<AiSessionRow>> listAgentSessions() async {
    final rows = await (_db.select(_db.aiSessions)
          ..where((t) =>
              t.type.equals(kAgentSessionType) &
              t.kpId.isNull() &
              t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm.desc(t.updatedAt),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .get();
    return rows;
  }

  /// 重命名会话（写**现有** title 列；ai_sessions 本就带该列，无需改表）。
  ///
  /// 未重命名时 title 为空，UI 运行时从首条 user 消息 / 时间派生标题。
  Future<void> renameSession(String sessionId, String title) async {
    final now = DateTime.now().toUtc();
    final row = await (_db.select(_db.aiSessions)
          ..where((t) => t.id.equals(sessionId)))
        .getSingleOrNull();
    if (row == null) return;
    await (_db.update(_db.aiSessions)..where((t) => t.id.equals(sessionId)))
        .write(AiSessionsCompanion(
      title: Value(title.trim()),
      updatedAt: Value(now),
      version: Value(row.version + 1),
    ));
    await _sync.upsertAiSession(sessionId);
  }

  /// 清空会话消息（软删该会话全部消息，**保留会话行**）。返回清空条数。
  Future<int> clearMessages(String sessionId) async {
    final now = DateTime.now().toUtc();
    final rows = await (_db.select(_db.aiMessages)
          ..where((t) => t.sessionId.equals(sessionId) & t.deletedAt.isNull()))
        .get();
    for (final r in rows) {
      await (_db.update(_db.aiMessages)..where((t) => t.id.equals(r.id)))
          .write(AiMessagesCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        version: Value(r.version + 1),
      ));
      await _sync.upsertAiMessage(r.id);
    }
    return rows.length;
  }

  /// 删除会话（连同消息一起软删；行留墓碑供同步传播，不物理删）。
  Future<void> deleteSession(String sessionId) async {
    final now = DateTime.now().toUtc();
    final row = await (_db.select(_db.aiSessions)
          ..where((t) => t.id.equals(sessionId)))
        .getSingleOrNull();
    if (row == null) return;
    await (_db.update(_db.aiSessions)..where((t) => t.id.equals(sessionId)))
        .write(AiSessionsCompanion(
      deletedAt: Value(now),
      updatedAt: Value(now),
      version: Value(row.version + 1),
    ));
    await _sync.upsertAiSession(sessionId);
    await clearMessages(sessionId);
  }

  /// 把会话 updatedAt / version 推到当前变更（消息追加后调用）。
  Future<void> _touchSession(String sessionId, {required DateTime now}) async {
    final row = await (_db.select(_db.aiSessions)
          ..where((t) => t.id.equals(sessionId)))
        .getSingleOrNull();
    if (row == null) return;
    await (_db.update(_db.aiSessions)..where((t) => t.id.equals(sessionId)))
        .write(AiSessionsCompanion(
      updatedAt: Value(now),
      version: Value(row.version + 1),
    ));
    await _sync.upsertAiSession(sessionId);
  }

  static String _sessionTypeFor(AiTask t) {
    // 每个会话类任务各自独立 session（同一 KP 下 T5 追问 / T6 讲解 不能混）。
    // T7 苏格拉底走 tutor，T5/T6 用各自 code 区分，其余对话归到 chat。
    if (t == AiTask.t7Socratic) return 'tutor';
    if (t == AiTask.t5Ask) return 'chat';
    if (t == AiTask.t6Explain) return 'explain';
    return t.code;
  }
}

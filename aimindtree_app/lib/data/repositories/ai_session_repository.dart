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
    this.modelId,
  });
  final String id;
  final String sessionId;
  final String role; // user/assistant/system
  final String content;
  final DateTime createdAt;

  /// 产生该条消息的模型 / 任务码。
  ///
  /// `'dify-t6'` = 老师模式讲解；`'dify-t5'` = 老师模式追问；
  /// `null` = 普通消息 / 老数据 / 非本模块写入（**null 合法，不得抛异常**）。
  ///
  /// ⚠️ 刻意做成**可选**字段：改成必填会让既有构造调用点（及
  /// `test/agent_features_test.dart`）编译失败。
  final String? modelId;
}

/// 老数据合并的结果（可观测性载体）。
enum LegacyMergeOutcome {
  /// 合并完成（可能含 type 归一）。
  merged,

  /// 该 KP 下没有未删的 `explain` 行 —— 无需处理（**幂等态**）。
  skippedNoLegacy,

  /// 合并异常：**数据一条未删**（事务已回滚），调用方须提示用户。
  failed,
}

/// 老数据合并的结果明细。
class LegacyMergeResult {
  const LegacyMergeResult({
    required this.outcome,
    this.chatSessionId,
    this.explainSessionId,
    this.movedMessages = 0,
    this.normalizedOnly = 0,
    this.error,
  });

  final LegacyMergeOutcome outcome;

  /// 保留方（合并后的主会话）id。
  final String? chatSessionId;

  /// 被并入方（迁移发生时的 explain 会话）id。
  final String? explainSessionId;

  /// 实际迁移的消息条数。
  final int movedMessages;

  /// 仅做了 `type` 归一（该 KP 下原本只有 explain、没有 chat）的条数。
  final int normalizedOnly;

  /// [LegacyMergeOutcome.failed] 时的异常对象。
  final Object? error;
}

class AiSessionRepository {
  AiSessionRepository(this._db, {this.deviceId = ''});
  final AppDatabase _db;

  /// 同步设备号：写本表的每一行都要带上它，供同步自回声过滤
  /// （`sync_engine.dart` 的 `env.deviceId == deviceId`）识别「本机自己上传的行」。
  ///
  /// ⚠️ **绝不**使用常量兜底（历史上曾用过一个写死的占位值）——那会让所有设备拿到
  /// 同一个号码，pull 时服务端**所有**行都被当成「本机自己上传的」跳过，
  /// 表现为「应用变更 0 条，跳过 N 条」，换任何中继后端都一模一样。
  /// 兜底用**空串**（不谎报设备号）。
  final String deviceId;

  /// 上行同步写入器（把本地写登记进 outbox；未接线时自动跳过）。
  late final SyncOutboxWriter _sync = SyncOutboxWriter(_db);

  /// Agent 会话类型（H：AI 助手自由问答）。
  ///
  /// 复用 `chat`（与 T5 追问同类型），但以 **kpId 为空** 与 KP 绑定的
  /// 老师模式会话区分：[listAgentSessions] 只捞 kpId isNull 的 chat 行。
  static const String kAgentSessionType = 'chat';

  /// 获取或创建该 KP 的会话（每个 KP 一个 session）。
  ///
  /// ⚠️ 软删铁律：查询**必须**带 `deletedAt.isNull()` —— 否则被软删的会话
  /// 仍会被捞回，页面永远显示旧会话、删除操作形同虚设。
  /// ⚠️ 排序：显式 `orderBy(id ASC)` —— id 是 ULID（毫秒时间戳内嵌 + 单调递增），
  /// 所以 id 序 ≡ 创建序，取第一条即「最早创建的那条」。
  ///
  /// 【老师模式已不再使用本方法】统一走 merge → primary → create
  /// （见 [mergeLegacyExplain] / [primarySessionForKp] / [createSessionForKp]）。
  /// 保留它仅为兼容既有调用与测试；`task: AiTask.t6Explain` 会造出
  /// `type='explain'` 的会话 —— 老师模式**禁止**再走这条路径（会产生双会话）。
  Future<AiSessionRow> getOrCreateForKp({
    required String kpId,
    required AiTask task,
  }) async {
    final type = _sessionTypeFor(task);
    final rows = await (_db.select(_db.aiSessions)
          ..where((t) =>
              t.kpId.equals(kpId) & t.type.equals(type) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
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
          deviceId: Value(deviceId),
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
      deviceId: deviceId,
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
    await insertMessageRow(AiMessagesCompanion(
      id: Value(id),
      sessionId: Value(sessionId),
      role: Value(role),
      contentMd: Value(content),
      modelId: Value(modelId),
      updatedAt: Value(now),
      version: const Value(1),
      deviceId: Value(deviceId),
    ));
    await _sync.upsertAiMessage(id);
    await _touchSession(sessionId, now: now);
  }

  /// 【测试接缝】写入一条消息行。
  ///
  /// [addMessage] 与 [mergeLegacyExplain] 的消息迁移都走这个方法，因此测试
  /// 可以继承本类并覆写它来**注入失败**，从而稳定地验证「合并失败 →
  /// 源数据一条不删、异常被吞掉并转成 [LegacyMergeOutcome.failed]」这条路径
  /// （SQLite 对 `content_md` 无长度限制，靠构造坏输入很难触发约束失败）。
  ///
  /// 生产代码请勿直接调用。
  Future<void> insertMessageRow(AiMessagesCompanion row) async {
    await _db.into(_db.aiMessages).insert(row);
  }

  /// 列出某 session 的全部消息（按**纯 id 升序**）。
  ///
  /// 软删铁律：`deleted_at` 非空的消息是墓碑，一律过滤（清空会话后不得复现）。
  ///
  /// ⚠️ **排序键 = 唯一的 `id ASC`**（不是 `updated_at ASC`）：
  /// 增量推送会用 outbox 的创建时间覆盖 envelope 里的 `updated_at`
  /// （`sync_engine.dart:183`），pull 时 `_hydrate`（`sync_engine.dart:744-751`）
  /// 再用它覆盖对端行的 `updated_at` → **跨端 `updated_at` 不可信**；
  /// 而 ULID 的毫秒位内嵌在 id 里 → id 序天然跨端一致。
  /// 老数据合并时新消息的 id 由 [newDerivedUlid] 确定性派生（毫秒 +1），
  /// 所以同秒并列的消息顺序在两端都能被稳定还原。
  Future<List<ChatMessage>> listMessages(String sessionId) async {
    final rows = await (_db.select(_db.aiMessages)
          ..where((t) => t.sessionId.equals(sessionId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    return rows
        .map((r) => ChatMessage(
              id: r.id,
              sessionId: r.sessionId,
              role: r.role,
              content: r.contentMd,
              createdAt: r.updatedAt,
              modelId: r.modelId,
            ))
        .toList();
  }

  // ============ 老师模式会话管理（按 kpId 取会话的通用能力） ============
  //
  // ⚠️ 这里的四个方法**刻意不带「老师模式」字样**：它们表达的是「按 kpId
  // 取 / 建会话」这一通用能力，与具体业务页面解耦；将来别的页面按 kpId
  // 取会话时不必再复制一份实现。

  /// 列出该 KP 下**全部未删除**的会话（最近活跃在前）。
  ///
  /// ⚠️ 按 `kp_id` 过滤，**不按 `type` 过滤**：合并失败残留的 `type='explain'`
  /// 行必须仍然出现在列表里（否则用户就看不到「还有一条没合并掉的讲解」）。
  /// Agent 会话的 `kp_id IS NULL` → 与本查询天然互斥。
  ///
  /// ⚠️ 排序口径与「会话内消息流的纯 `id ASC`」是**两个层级**，别混淆：
  /// 这里排的是**会话列表**（沿用 [listAgentSessions] 的 `updated_at DESC`
  /// + `id DESC` 兜底口径，本次不改）。
  Future<List<AiSessionRow>> listSessionsForKp(String kpId) async {
    final rows = await (_db.select(_db.aiSessions)
          ..where((t) => t.kpId.equals(kpId) & t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm.desc(t.updatedAt),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .get();
    return rows;
  }

  /// 取**主会话**：该 KP 下未删除、`type='chat'` 的会话中 `id` 最小者。
  ///
  /// `type='chat'` 这一条件的作用：合并失败残留的 `explain` 行（id 往往更小）
  /// 不会抢走主会话。
  /// 无则返回 `null`（调用方决定是否补建 + 是否自动讲解）。
  Future<AiSessionRow?> primarySessionForKp(String kpId) async {
    final rows = await (_db.select(_db.aiSessions)
          ..where((t) =>
              t.kpId.equals(kpId) &
              t.type.equals(kAgentSessionType) &
              t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  /// 在该 KP 下新建一条会话（`type='chat'`、`kp_id=kpId`、`title` 留空
  /// → 运行时派生）。
  ///
  /// 纯本地写，**不依赖 AI 可用性**：AI 不可用时照样能建、能看。
  Future<AiSessionRow> createSessionForKp(String kpId, {String title = ''}) async {
    final now = DateTime.now().toUtc();
    final id = newUlid();
    await _db.into(_db.aiSessions).insert(AiSessionsCompanion(
          id: Value(id),
          type: const Value(kAgentSessionType),
          targetRef: Value(kpId),
          title: Value(title.trim()),
          kpId: Value(kpId),
          modelId: const Value('dify-t1-local'),
          tutorState: const Value('{}'),
          updatedAt: Value(now),
          version: const Value(1),
          deviceId: Value(deviceId),
        ));
    await _sync.upsertAiSession(id);
    return AiSessionRow(
      id: id,
      type: kAgentSessionType,
      targetRef: kpId,
      title: title.trim(),
      kpId: kpId,
      modelId: 'dify-t1-local',
      tutorState: '{}',
      updatedAt: now,
      version: 1,
      deviceId: deviceId,
      deletedAt: null,
    );
  }

  /// 老数据合并：把该 KP 下未删的 `type='explain'` 会话并入 `type='chat'` 会话。
  ///
  /// 方向固定 **explain → chat**。保留方 = `id` 最小的 chat 行；若无 chat 行，
  /// 则把 `id` 最小的 explain 行**原地归一**为 chat（同一行、id 不变）。
  ///
  /// 消息迁移 = **复制 + 软删原行**（不直接改 `session_id`，否则跨端会看到
  /// 「同一行凭空换了归属」）。新行 id 由 [newDerivedUlid] 从源 id 确定性派生
  /// → **幂等**：重复进入 / 跨端重复合并都收敛到同一批行。
  ///
  /// 🔴 **失败绝不丢数据**：整个过程跑在一个事务里，任何异常都会整体回滚，
  /// 然后被吞掉并转成 [LegacyMergeOutcome.failed]（不抛给调用方）。
  Future<LegacyMergeResult> mergeLegacyExplain(String kpId) async {
    try {
      return await _db.transaction(() => _mergeLegacyExplainInTx(kpId));
    } on Object catch (e) {
      return LegacyMergeResult(outcome: LegacyMergeOutcome.failed, error: e);
    }
  }

  /// [mergeLegacyExplain] 的事务体（**不要**直接调用）。
  Future<LegacyMergeResult> _mergeLegacyExplainInTx(String kpId) async {
    final sessions = await listSessionsForKp(kpId);
    final explains = sessions.where((s) => s.type == 'explain').toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (explains.isEmpty) {
      return const LegacyMergeResult(outcome: LegacyMergeOutcome.skippedNoLegacy);
    }
    final chats = sessions.where((s) => s.type == kAgentSessionType).toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    final now = DateTime.now().toUtc();
    var moved = 0;
    var normalized = 0;
    String keepId;

    if (chats.isEmpty) {
      // 只有 explain：把最早的那条**原地归一**为 chat（id 不变 → 它就是主会话）
      final first = explains.first;
      keepId = first.id;
      await (_db.update(_db.aiSessions)..where((t) => t.id.equals(keepId)))
          .write(AiSessionsCompanion(
        type: const Value(kAgentSessionType),
        updatedAt: Value(now),
        version: Value(first.version + 1),
      ));
      await _sync.upsertAiSession(keepId);
      normalized = 1;
      // 其余 explain 行（若有）的消息迁入保留方后软删该行
      for (final e in explains.skip(1)) {
        moved += await _migrateMessages(e.id, keepId, now);
        await _softDeleteSession(e.id, now);
      }
      return LegacyMergeResult(
        outcome: LegacyMergeOutcome.merged,
        chatSessionId: keepId,
        explainSessionId: explains.length > 1 ? explains[1].id : explains.first.id,
        movedMessages: moved,
        normalizedOnly: normalized,
      );
    }

    // 有 chat：保留方 = id 最小的 chat；所有 explain 行的消息迁入后软删该行
    final keep = chats.first;
    keepId = keep.id;
    String? lastExplainId;
    for (final e in explains) {
      moved += await _migrateMessages(e.id, keepId, now);
      await _softDeleteSession(e.id, now);
      lastExplainId = e.id;
    }
    await (_db.update(_db.aiSessions)..where((t) => t.id.equals(keepId)))
        .write(AiSessionsCompanion(
      updatedAt: Value(now),
      version: Value(keep.version + 1),
    ));
    await _sync.upsertAiSession(keepId);
    return LegacyMergeResult(
      outcome: LegacyMergeOutcome.merged,
      chatSessionId: keepId,
      explainSessionId: lastExplainId,
      movedMessages: moved,
      normalizedOnly: normalized,
    );
  }

  /// 把 [fromSessionId] 的全部未删消息**复制**到 [toSessionId]（并软删原行）。
  ///
  /// 返回实际迁移条数。被移动消息的 `role` / `content_md` / `model_id` /
  /// `updated_at`（原始时间戳）**原样保留**，只改 `session_id` 与 `id`。
  Future<int> _migrateMessages(
    String fromSessionId,
    String toSessionId,
    DateTime now,
  ) async {
    final rows = await (_db.select(_db.aiMessages)
          ..where((t) =>
              t.sessionId.equals(fromSessionId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    var moved = 0;
    for (final r in rows) {
      final newId = newDerivedUlid(r.id);
      // 幂等：派生 id 已存在（跨端重复合并过）→ 跳过，不重复插入
      final dup = await (_db.select(_db.aiMessages)
            ..where((t) => t.id.equals(newId)))
          .get();
      if (dup.isNotEmpty) continue;
      await insertMessageRow(AiMessagesCompanion(
        id: Value(newId),
        sessionId: Value(toSessionId),
        role: Value(r.role),
        contentMd: Value(r.contentMd),
        tokens: Value(r.tokens),
        latencyMs: Value(r.latencyMs),
        modelId: Value(r.modelId),
        updatedAt: Value(r.updatedAt),
        version: const Value(1),
        deviceId: Value(deviceId),
      ));
      await _sync.upsertAiMessage(newId);
      // 原行软删（墓碑靠 deleted_at 传播，不物理删）
      await (_db.update(_db.aiMessages)..where((t) => t.id.equals(r.id)))
          .write(AiMessagesCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        version: Value(r.version + 1),
      ));
      await _sync.upsertAiMessage(r.id);
      moved++;
    }
    return moved;
  }

  /// 软删一个会话行（墓碑靠 `deleted_at` 传播）。
  Future<void> _softDeleteSession(String sessionId, DateTime now) async {
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
          deviceId: Value(deviceId),
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
      deviceId: deviceId,
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

/// 老师模式会话控制器（T03）。
///
/// 职责：封装 L2 注入拼装、会话创建/合并/删除。
///
/// **本控制器不发任何 AI 调用**（问题9）：打开知识点进老师模式时只补建一条
/// 空会话就停手，讲解由用户在空态点「开始老师讲解」触发，不点也没事。
/// 讲解的流式读取 + 落库在 `teacher_page._startStreamJob`（后台任务）里。
///
/// 对齐设计文档 §3.1 / §3.2 / §3.5 / §4.3。
library;

import '../../ai/ai_task.dart';
import '../../data/db/drift_database.dart' show AiSessionRow;
import '../../data/models/knowledge_point.dart';
import '../../data/repositories/ai_session_repository.dart';
import '../shared/session_context.dart';
import '../shared/session_ui.dart';

// ---------------------------------------------------------------------------
// 常量（PRD C11 三处同源铁律）
// ---------------------------------------------------------------------------

/// 老师模式 L2 注入规模（裁决 8）：10 条 = 5 轮。
const int kTeacherContextMaxMessages = 10;

/// 老师模式 L2 注入字符上限。
const int kTeacherContextMaxChars = 4000;

/// 删除主会话确认文案模板（PRD C11 逐字来源）。
/// 含占位符 `{nextTitle}`，由调用方替换。
///
/// 问题9：重建出来的是一条**空会话**，不再自动讲解（讲不讲解由用户点）。
const String kDeletePrimaryConfirmTemplate =
    '这是该知识点的默认会话。删除后将自动切换到『{nextTitle}』；若无其它会话，将新建一条空会话。确定删除？';

/// 底部常驻按钮文案：产出一段新的老师讲解（追加，不覆盖旧讲解）。
///
/// 问题9 前叫「再讲一次」—— 容易被读成「重试上一次失败的生成」。改成
/// 「生成老师讲解」后与空态引导按钮同义，都是「我要一段讲解」。
const String kGenerateExplainLabel = '生成老师讲解';

/// 空态引导按钮文案（问题9：打开不再自动讲解，讲解由用户点这一下）。
const String kStartExplainLabel = '开始老师讲解';

/// 新建会话提示副标题（PRD C13）。
const String kNewSessionHint = '新会话从提问开始，不会自动讲解';

/// 空态引导文案（主会话已就位但还没有任何消息）。
///
/// 问题9：以前进页面就自动讲解，用户根本看不到空会话；现在空态是常态，
/// 所以这里要说清「能做什么」，而不是只报「还没有内容」。
const String kEmptyPrimaryGuidance = '还没有讲解。点「开始老师讲解」生成一段，或直接在下面提问。';

// ---------------------------------------------------------------------------
// 判别（裁决 7 / 15）
// ---------------------------------------------------------------------------

/// 该消息是否是「讲解」消息。
///
/// 判别依据：model_id == 'dify-t6'（讲解任务码）。
/// 容错：model_id 为 null / 其它值 / 历史老数据 → 一律 false，不抛异常。
bool isExplainMessage(ChatMessage m) => m.modelId == 'dify-t6';

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// 老师模式会话控制器。
///
/// 职责（与页面解耦，可单测）：
/// 1. L2 拼装：`buildQuery(task, history, kp)`
/// 2. 会话创建：`createUserSession()` / `createPrimarySession()`
/// 3. 老数据合并：`mergeLegacy(kpId)`
/// 4. 删除会话（含主会话顺延）：`deleteSession(id)`
class TeacherSessionController {
  TeacherSessionController({
    required this.repo,
    required this.kp,
  });

  final AiSessionRepository repo;
  final KnowledgePoint kp;

  /// 拼装一次对话的 query（T5 追问 / T6 讲解 / 「生成老师讲解」共用）。
  ///
  /// [history] 当前会话的消息列表（按 id ASC，不含本轮问题）。
  /// [task]    任务码（t5Ask 或 t6Explain）。
  /// [currentQuestion] 用户本轮输入（T5 必须，T6 可为空）。
  String buildQuery({
    required List<ChatMessage> history,
    required AiTask task,
    required String currentQuestion,
  }) {
    // L2：组装前文块（不含本轮问题）
    final turns = history
        .where((m) => m.role == 'user' || m.role == 'assistant')
        .map((m) => (role: m.role, content: m.content))
        .toList();
    final l2 = buildSessionContext(
      turns,
      maxMessages: kTeacherContextMaxMessages,
      maxChars: kTeacherContextMaxChars,
    );

    // L1：知识点上下文（逐字沿用现状）
    final ctx = '知识点：${kp.name}（${kp.type.label}）。\n'
        '定义：${kp.definition}\n'
        '来源：${kp.sourceQuote}';

    if (task == AiTask.t6Explain) {
      final instruction =
          '请用通俗、循序渐进的方式讲解这个概念，帮助初学者建立直观理解，并点出它容易和哪些概念混淆。';
      return l2.isEmpty
          ? '$ctx\n\n$instruction'
          : '$ctx\n\n$l2\n\n$instruction';
    } else {
      return l2.isEmpty
          ? '$ctx\n\n用户问题：$currentQuestion'
          : '$ctx\n\n$l2\n\n用户问题：$currentQuestion';
    }
  }

  /// 用户主动新建会话（不自动讲解）。
  Future<AiSessionRow> createUserSession() async {
    return repo.createSessionForKp(kp.id);
  }

  /// 取回/补建该知识点的主会话。
  ///
  /// **不发任何 AI 调用**（问题9）：主会话不存在时只新建一条空会话就收工。
  /// 以前这里会自动讲解一次 —— 「点开知识点」等于立刻烧一次大模型推理，
  /// 想先看看再说都不行。
  Future<AiSessionRow> ensurePrimarySession() async {
    final existing = await repo.primarySessionForKp(kp.id);
    if (existing != null) return existing;
    return createPrimarySession();
  }

  /// 新建一条**空**的主会话（不讲解）。
  ///
  /// 标题沿用 `{kp.name} 讲解`：它是默认会话，讲解多半会落在这里，也让
  /// 会话列表的默认标题与 `deriveSessionTitle` 的 fallback 保持一致。
  Future<AiSessionRow> createPrimarySession() {
    return repo.createSessionForKp(kp.id, title: '${kp.name} 讲解');
  }

  /// 合并该 KP 下的老数据（explain → chat）。
  Future<LegacyMergeResult> mergeLegacy(String kpId) async {
    return repo.mergeLegacyExplain(kpId);
  }

  /// 删除会话（若删除的是主会话，顺延到下一个会话或重建主会话）。
  ///
  /// 返回（新会话 id, 新会话标题, toast 文案）。
  ///
  /// 重建出来的主会话是**空的**（问题9：不再自动讲解），要讲解由用户点按钮。
  Future<(String?, String, String)> deleteSession({
    required String sessionId,
  }) async {
    await repo.deleteSession(sessionId);

    // 重算主会话
    final sessions = await repo.listSessionsForKp(kp.id);
    final next = sessions.isNotEmpty ? sessions.first : null;

    if (next == null) {
      // 已无任何会话 → 补一条空主会话（不讲解）
      final recreated = await createPrimarySession();
      return (recreated.id, recreated.title, '已新建空会话');
    }

    // 顺延到 id 最小的未删会话
    final msgs = await repo.listMessages(next.id);
    final title = deriveSessionTitle(
      storedTitle: next.title,
      messages: msgs,
      fallbackTitle: '${kp.name} 讲解',
    );
    return (next.id, title, '已切换到会话『$title』');
  }

  /// 清空会话消息（保留会话本身）。
  Future<void> clearSession(String sessionId) async {
    await repo.clearMessages(sessionId);
  }

  /// 重命名会话。
  Future<void> renameSession(String sessionId, String newTitle) async {
    await repo.renameSession(sessionId, newTitle);
  }
}

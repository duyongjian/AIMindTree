/// 老师模式会话控制器（T03）。
///
/// 职责：封装 L2 注入拼装、会话创建/合并/删除、自动讲解触发。
///
/// 对齐设计文档 §3.1 / §3.2 / §3.5 / §4.3。
library;

import 'package:flutter/material.dart';

import '../../ai/ai_service.dart';
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
const String kDeletePrimaryConfirmTemplate =
    '这是该知识点的默认会话。删除后将自动切换到『{nextTitle}』；若无其它会话，将新建一条并自动生成一次讲解。确定删除？';

/// 「再讲一次」按钮文案。
const String kRegenerateLabel = '再讲一次';

/// 新建会话提示副标题（PRD C13）。
const String kNewSessionHint = '新会话从提问开始，不会自动讲解';

/// 空态引导文案（用户主动新建的空会话）。
const String kEmptyPrimaryGuidance = '这个会话还没有内容，问点什么吧';

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
/// 2. 会话创建：`createUserSession()` / `createPrimarySessionWithExplain()`
/// 3. 老数据合并：`mergeLegacy(kpId)`
/// 4. 删除会话（含主会话顺延）：`deleteSession(id)`
class TeacherSessionController {
  TeacherSessionController({
    required this.repo,
    required this.ai,
    required this.kp,
  });

  final AiSessionRepository repo;
  final AiService ai;
  final KnowledgePoint kp;

  /// 拼装一次对话的 query（T5 追问 / T6 讲解 / 「再讲一次」共用）。
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

  /// 系统补建主会话，并在空会话时自动讲解一次。
  ///
  /// 返回新建/选定的主会话行。若 [context] 非空且新建了会话，会显示 toast。
  Future<AiSessionRow> ensurePrimarySession({BuildContext? context}) async {
    final existing = await repo.primarySessionForKp(kp.id);
    if (existing != null) return existing;

    // 无主会话 → 新建 + 自动讲解
    // 需要 context 来显示 toast；若没有则抛异常（调用方应保证有 context）
    if (context == null) {
      throw StateError('需要 BuildContext 以显示 toast');
    }
    return createPrimarySessionWithExplain(
      context: context,
      onGenerated: () {},
    );
  }

  /// 新建主会话并立即自动讲解一次。
  Future<AiSessionRow> createPrimarySessionWithExplain({
    required BuildContext context,
    required VoidCallback onGenerated,
  }) async {
    final session = await repo.createSessionForKp(
        kp.id, title: '${kp.name} 讲解');
    await _generateExplainOnce(
      context: context,
      sessionId: session.id,
      onGenerated: onGenerated,
    );
    return session;
  }

  /// 合并该 KP 下的老数据（explain → chat）。
  Future<LegacyMergeResult> mergeLegacy(String kpId) async {
    return repo.mergeLegacyExplain(kpId);
  }

  /// 删除会话（若删除的是主会话，顺延到下一个会话或重建主会话）。
  ///
  /// 返回（新会话 id, 新会话标题, toast 文案）。
  ///
  /// ⚠️ 若需新建主会话，[context] 必须非空（用于显示 toast）。
  Future<(String?, String, String)> deleteSession({
    required String sessionId,
    BuildContext? context,
  }) async {
    await repo.deleteSession(sessionId);

    // 重算主会话
    final sessions = await repo.listSessionsForKp(kp.id);
    final next = sessions.isNotEmpty ? sessions.first : null;

    if (next == null) {
      // 已无任何会话 → 新建主会话 + 自动讲解
      if (context == null) {
        throw StateError(
            'deleteSession 需要 BuildContext 以显示 toast（重建主会话时）');
      }
      final recreated = await createPrimarySessionWithExplain(
        context: context,
        onGenerated: () {},
      );
      return (recreated.id, recreated.title,
          '已新建会话并自动生成一次讲解');
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

  // ---- 内部辅助 ----

  /// 为一次讲解生成流式调用并落库。
  ///
  /// 不阻塞返回；结果通过 [onGenerated] 回调通知 UI 刷新。
  Future<void> _generateExplainOnce({
    required BuildContext context,
    required String sessionId,
    required VoidCallback onGenerated,
  }) async {
    final history = await repo.listMessages(sessionId);
    final query = buildQuery(
      history: history,
      task: AiTask.t6Explain,
      currentQuestion: '',
    );

    final buf = StringBuffer();
    try {
      await for (final chunk in ai.chat(AiTask.t6Explain, query)) {
        if (chunk.delta != null) buf.write(chunk.delta);
        if (chunk.done) break;
      }
      final text = buf.toString().trim();
      if (text.isNotEmpty) {
        await repo.addMessage(
          sessionId: sessionId,
          role: 'assistant',
          content: text,
          modelId: 'dify-t6',
        );
      }
    } on Object catch (e) {
      // 讲解失败不阻断会话使用；UI 侧另行处理错误条
      debugPrint('老师模式自动讲解失败: $e');
    }
    // 不检查 mounted，由调用方保证生命周期
    onGenerated();
  }
}

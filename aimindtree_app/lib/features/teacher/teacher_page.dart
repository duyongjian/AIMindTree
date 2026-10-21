/// 老师模式页面（T06）：按 KP 发起对话，问"这个知识点的疑惑"。
///
/// 两个能力合在一个页面（底部浮层入口叫「AI 讲解 / 追问」）：
/// - **讲解（T6）**：打开页面时自动用流式调用生成一段通俗讲解，可「重新生成」。
/// - **追问（T5）**：多轮问答，把 KP 信息作为上下文塞给 LLM，消息持久化到
///   ai_sessions / ai_messages。
///
/// 无可用 Provider 时给出明确提示（而非静默失败 / 空白）。
///
/// B4 互斥：会话打开期间持 `kp:{id}` 资源锁（入口处挡「同点另开老师模式」），
/// 托盘同步显示一行计时；生成中 / 空闲两种文案联动。
library;

import 'package:flutter/material.dart';

import '../../ai/ai_job_service.dart';
import '../../ai/ai_service.dart';
import '../../ai/ai_task.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/repositories/ai_session_repository.dart';
import '../../data/repositories/knowledge_repository.dart';

class TeacherPage extends StatefulWidget {
  const TeacherPage({
    super.key,
    required this.kp,
    required this.sessions,
    required this.ai,
    required this.repo,
    required this.jobs,
  });

  final KnowledgePoint kp;
  final AiSessionRepository sessions;
  final AiService ai;
  final KnowledgeRepository repo;

  /// 任务队列服务（B4：会话持 `kp:{id}` 锁 + 托盘计时）。
  final AiJobService jobs;

  @override
  State<TeacherPage> createState() => _TeacherPageState();
}

class _TeacherPageState extends State<TeacherPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _askBusy = false;
  String? _askError;
  late String _askSessionId;
  List<ChatMessage> _askMessages = <ChatMessage>[];
  String? _askConversationId;
  MasteryStatus _mastery = MasteryStatus.unknown;

  /// B4：交互会话 id（持 `kp:{id}` 锁；dispose 时释放）。
  String _sessionTicket = '';

  // —— 讲解（T6）态 ——
  late String _explainSessionId;
  bool _explainBusy = false;
  String _explainText = '';
  String? _explainError;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    // 会话级持锁：页开即占、页关即放（「同点另开老师模式」在入口处被挡）。
    _sessionTicket = widget.jobs.holdInteractive(
      'kp:${widget.kp.id}',
      label: '老师模式：${widget.kp.name}',
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final askSession = await widget.sessions.getOrCreateForKp(
        kpId: widget.kp.id, task: AiTask.t5Ask);
    final askMsgs = await widget.sessions.listMessages(askSession.id);
    final explainSession = await widget.sessions.getOrCreateForKp(
        kpId: widget.kp.id, task: AiTask.t6Explain);
    final explainMsgs = await widget.sessions.listMessages(explainSession.id);
    final m = await widget.repo.currentMastery(widget.kp.id);
    if (!mounted) return;
    setState(() {
      _askSessionId = askSession.id;
      _explainSessionId = explainSession.id;
      _askMessages = askMsgs;
      _mastery = m;
    });
    // 还没有讲解就自动生成一段（让用户一进来就看到「讲解」）。
    if (explainMsgs.where((x) => x.role == 'assistant').isEmpty) {
      _generateExplain();
    }
  }

  /// 生成讲解（T6）：流式调用，结果作为一条 assistant 消息持久化。
  Future<void> _generateExplain() async {
    if (_explainBusy) return;
    setState(() {
      _explainBusy = true;
      _explainError = null;
      _explainText = '';
    });
    _ticket('正在生成讲解…');
    final ctx = '知识点：${widget.kp.name}（${widget.kp.type.label}）。\n'
        '定义：${widget.kp.definition}\n'
        '来源：${widget.kp.sourceQuote}';
    final query = '$ctx\n\n'
        '请用通俗、循序渐进的方式讲解这个概念，帮助初学者建立直观理解，'
        '并点出它容易和哪些概念混淆。';
    final buf = StringBuffer();
    try {
      await for (final chunk in widget.ai.chat(AiTask.t6Explain, query)) {
        if (chunk.delta != null) {
          buf.write(chunk.delta);
          if (mounted) setState(() => _explainText = buf.toString());
        }
        if (chunk.done) break;
      }
      final text = buf.toString();
      if (text.trim().isNotEmpty) {
        await widget.sessions.addMessage(
          sessionId: _explainSessionId,
          role: 'assistant',
          content: text,
          modelId: 'dify-t6',
        );
      }
    } on Object catch (e) {
      if (mounted) setState(() => _explainError = _friendlyError(e));
    } finally {
      if (mounted) {
        setState(() => _explainBusy = false);
        _ticket('会话进行中');
      }
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _askBusy) return;
    setState(() {
      _askBusy = true;
      _askError = null;
    });
    _ticket('正在回答追问…');

    await widget.sessions.addMessage(
        sessionId: _askSessionId, role: 'user', content: text);

    final ctx = '知识点：${widget.kp.name}（${widget.kp.type.label}）。\n'
        '定义：${widget.kp.definition}\n'
        '来源：${widget.kp.sourceQuote}';
    final fullQuery = '$ctx\n\n用户问题：$text';

    String? answer;
    try {
      await for (final chunk in widget.ai.chat(
        AiTask.t5Ask,
        fullQuery,
        conversationId: _askConversationId,
      )) {
        if (chunk.conversationId != null) {
          _askConversationId = chunk.conversationId;
        }
        if (chunk.delta != null) answer = chunk.delta;
        if (chunk.done) break;
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _askError = _friendlyError(e);
        _askBusy = false;
      });
      _ticket('会话进行中');
      return;
    }

    final finalAnswer = answer ?? '(无响应)';
    await widget.sessions.addMessage(
      sessionId: _askSessionId,
      role: 'assistant',
      content: finalAnswer,
      modelId: 'dify-t5',
    );

    final msgs = await widget.sessions.listMessages(_askSessionId);
    if (!mounted) return;
    setState(() {
      _askMessages = msgs;
      _input.clear();
      _askBusy = false;
    });
    _ticket('会话进行中');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 托盘文案联动：会话开着的整个期间托盘行都可见，生成中 / 空闲两种态。
  void _ticket(String message) {
    if (_sessionTicket.isEmpty) return;
    widget.jobs.setInteractiveMessage(_sessionTicket, message);
  }

  /// 把「无 Provider」之类的底层错误翻译成用户能看懂的提示。
  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('没有任何可用的 AI Provider')) {
      return '当前没有可用的 AI Provider。请到「设置」页确认已配置 Dify Key，'
          '并重启 App 使其生效。';
    }
    return s;
  }

  @override
  void dispose() {
    // 先放锁再拆控件：会话页关掉 = `kp:{id}` 解锁 + 托盘行消失。
    widget.jobs.releaseInteractive(_sessionTicket);
    _tab.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('老师模式'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '讲解 (T6)'),
            Tab(text: '追问 (T5)'),
          ],
        ),
      ),
      body: Column(
        children: [
          _KpHeader(kp: widget.kp, mastery: _mastery),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _ExplainPane(
                  busy: _explainBusy,
                  text: _explainText,
                  error: _explainError,
                  onRegenerate: _generateExplain,
                ),
                _AskPane(
                  messages: _askMessages,
                  error: _askError,
                  busy: _askBusy,
                  scroll: _scroll,
                  input: _input,
                  onSend: _send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 讲解面板（T6）。
class _ExplainPane extends StatelessWidget {
  const _ExplainPane({
    required this.busy,
    required this.text,
    required this.error,
    required this.onRegenerate,
  });
  final bool busy;
  final String text;
  final String? error;
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Text('AI 讲解', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton.icon(
                  onPressed: busy ? null : onRegenerate,
                  icon: busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 16),
                  label: const Text('重新生成'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text('错误：$error',
                        style: const TextStyle(color: Colors.red)),
                  )
                else if (busy && text.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('正在生成讲解…',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  )
                else if (text.isNotEmpty)
                  SelectableText(text, style: const TextStyle(fontSize: 14, height: 1.5))
                else
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('暂无讲解，点「重新生成」。',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
}

/// 追问面板（T5）。
class _AskPane extends StatelessWidget {
  const _AskPane({
    required this.messages,
    required this.error,
    required this.busy,
    required this.scroll,
    required this.input,
    required this.onSend,
  });
  final List<ChatMessage> messages;
  final String? error;
  final bool busy;
  final ScrollController scroll;
  final TextEditingController input;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text('在这条知识点下提问吧～',
                        style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length + (error != null ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (error != null && i == messages.length) {
                        return Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text('错误：$error',
                              style: const TextStyle(color: Colors.red)),
                        );
                      }
                      final m = messages[i];
                      return _MessageBubble(role: m.role, content: m.content);
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.grey.shade300)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: input,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: r'问：为什么 $\frac{d}{dt}$ 在物理里这么重要？',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: busy ? null : onSend,
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    tooltip: '发送',
                  ),
                ],
              ),
            ),
          ),
        ],
      );
}

class _KpHeader extends StatelessWidget {
  const _KpHeader({required this.kp, required this.mastery});
  final KnowledgePoint kp;
  final MasteryStatus mastery;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        color: Colors.indigo.shade50,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(kp.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                Text('掌握：${mastery.label}',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 4),
            Text('${kp.type.label} · 置信度 ${kp.confidence.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (kp.definition.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(kp.definition,
                    style: const TextStyle(fontSize: 13)),
              ),
            if (kp.sourceQuote.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '原文：${kp.sourceQuote}',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic),
                ),
              ),
          ],
        ),
      );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.role, required this.content});
  final String role;
  final String content;

  @override
  Widget build(BuildContext context) {
    final isUser = role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isUser ? Colors.indigo : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          content,
          style: TextStyle(color: isUser ? Colors.white : Colors.black87),
        ),
      ),
    );
  }
}

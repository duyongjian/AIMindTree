/// 老师模式页面（T06）：按 KP 发起对话，问"这个知识点的疑惑"。
///
/// - 顶部：KP 名 / 类型 / 定义 / 锚点引用 / 掌握状态
/// - 中间：历史消息流
/// - 底部：输入框 → 调 AiService.chat(t5Ask) → 流式阻塞单块
///   → 持久化 user/assistant 两条消息到 ai_sessions/ai_messages
library;

import 'package:flutter/material.dart';

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
  });

  final KnowledgePoint kp;
  final AiSessionRepository sessions;
  final AiService ai;
  final KnowledgeRepository repo;

  @override
  State<TeacherPage> createState() => _TeacherPageState();
}

class _TeacherPageState extends State<TeacherPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _busy = false;
  String? _error;
  late String _sessionId;
  List<ChatMessage> _messages = <ChatMessage>[];
  String? _conversationId;
  MasteryStatus _mastery = MasteryStatus.unknown;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final session =
        await widget.sessions.getOrCreateForKp(kpId: widget.kp.id, task: AiTask.t5Ask);
    final msgs = await widget.sessions.listMessages(session.id);
    final m = await widget.repo.currentMastery(widget.kp.id);
    if (!mounted) return;
    setState(() {
      _sessionId = session.id;
      _messages = msgs;
      _mastery = m;
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    // 1) 追加用户消息
    await widget.sessions.addMessage(
        sessionId: _sessionId, role: 'user', content: text);

    // 2) 调 AiService（T5 追问：把 KP 信息作为 system 上下文塞给 LLM）
    final ctx = '知识点：${widget.kp.name}（${widget.kp.type.label}）。\n'
        '定义：${widget.kp.definition}\n'
        '来源：${widget.kp.sourceQuote}';
    final fullQuery = '$ctx\n\n用户问题：$text';

    String? answer;
    try {
      await for (final chunk in widget.ai.chat(
        AiTask.t5Ask,
        fullQuery,
        conversationId: _conversationId,
      )) {
        if (chunk.conversationId != null) {
          _conversationId = chunk.conversationId;
        }
        if (chunk.delta != null) answer = chunk.delta;
        if (chunk.done) break;
      }
    } on Object catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
      return;
    }

    // 3) 追加 AI 回复
    final finalAnswer = answer ?? '(无响应)';
    await widget.sessions.addMessage(
        sessionId: _sessionId,
        role: 'assistant',
        content: finalAnswer,
        modelId: 'dify-t1-local');

    // 4) 回读
    final msgs = await widget.sessions.listMessages(_sessionId);
    if (!mounted) return;
    setState(() {
      _messages = msgs;
      _input.clear();
      _busy = false;
    });
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('老师模式'),
      ),
      body: Column(
        children: [
          _KpHeader(kp: widget.kp, mastery: _mastery),
          const Divider(height: 1),
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text('在这条知识点下提问吧～',
                        style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length + (_error != null ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (_error != null && i == _messages.length) {
                        return Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text('错误：$_error',
                              style: const TextStyle(color: Colors.red)),
                        );
                      }
                      final m = _messages[i];
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
                      controller: _input,
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
                    onPressed: _busy ? null : _send,
                    icon: _busy
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
      ),
    );
  }
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

/// 老师模式页面（T03 重构）：单会话流 + 会话管理。
///
/// 重构前双 Tab（讲解 T6 / 追问 T5）各持一个会话，重构后：
/// - 单消息流：所有消息在同一个会话中按 id ASC 排列
/// - 会话管理：AppBar 图标 → 底部弹层（新建/重命名/清空/删除）
/// - 自动讲解：主会话不存在时自动补建 + 讲解一次（T1 触发点）
/// - 「再讲一次」：追加新讲解到当前会话（不覆盖旧讲解）
/// - L2 注入：每次提问前组装历史快照，确保多轮记忆
///
/// B4 互斥：会话打开期间持 `kp:{id}` 资源锁。
library;

import 'package:flutter/material.dart';

import '../../ai/ai_job_service.dart';
import '../../ai/ai_service.dart';
import '../../ai/ai_task.dart';
import '../../data/db/drift_database.dart' show AiSessionRow;
import '../../data/models/knowledge_point.dart';
import '../../data/repositories/ai_session_repository.dart';
import '../../data/repositories/knowledge_repository.dart';
import '../shared/session_ui.dart';
import 'teacher_session_controller.dart';

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

class _TeacherPageState extends State<TeacherPage> {
  late final TeacherSessionController _controller;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _askBusy = false;
  String? _error;
  String? _currentSessionId;
  List<ChatMessage> _messages = <ChatMessage>[];
  List<AiSessionRow> _sessions = <AiSessionRow>[];
  String? _primarySessionId;
  MasteryStatus _mastery = MasteryStatus.unknown;

  /// B4：交互会话 id（持 `kp:{id}` 锁；dispose 时释放）。
  String _sessionTicket = '';

  @override
  void initState() {
    super.initState();
    _controller = TeacherSessionController(
      repo: widget.sessions,
      ai: widget.ai,
      kp: widget.kp,
    );
    // 会话级持锁：页开即占、页关即放（「同点另开老师模式」在入口处被挡）。
    _sessionTicket = widget.jobs.holdInteractive(
      'kp:${widget.kp.id}',
      label: '老师模式：${widget.kp.name}',
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // ① 合并老数据
    await _controller.mergeLegacy(widget.kp.id);
    // ② 取主会话
    final primary = await _controller.ensurePrimarySession(context: context);
    // ③ 加载会话列表 + 主会话消息
    final sessions = await widget.sessions.listSessionsForKp(widget.kp.id);
    final msgs = await widget.sessions.listMessages(primary.id);
    final m = await widget.repo.currentMastery(widget.kp.id);

    if (!mounted) return;
    setState(() {
      _currentSessionId = primary.id;
      _primarySessionId = primary.id;
      _sessions = sessions;
      _messages = msgs;
      _mastery = m;
    });

    // ④ 若主会话为空 → 触发自动讲解（T2 触发点）
    if (primary.title.isNotEmpty ||
        msgs.where((x) => x.role == 'assistant').isNotEmpty) {
      return;
    }
    await _generateExplainOnce(sessionId: primary.id);
  }

  Future<void> _generateExplainOnce({required String sessionId}) async {
    final history = await widget.sessions.listMessages(sessionId);
    // 「讲解」恒走 T6：本方法只有两个调用点（空主会话的自动讲解 / 用户点
    // 「再讲一次」），两者语义都是「产出一段讲解」，不随会话里是否已有讲解
    // 而改变任务码（旧实现走 _taskForSession，会在已有讲解时退化成 T5 追问，
    // 导致「再讲一次」其实问了一个追问）。
    const task = AiTask.t6Explain;
    final query = _controller.buildQuery(
      history: history,
      task: task,
      currentQuestion: '',
    );

    // 先把「生成中」的气泡状态立起来，再发请求。
    setState(() {
      _askBusy = true;
      _error = null;
    });
    _ticket('正在生成讲解…');

    final buf = StringBuffer();
    try {
      await for (final chunk in widget.ai.chat(task, query)) {
        if (chunk.delta != null) buf.write(chunk.delta);
        if (chunk.done) break;
      }
      final text = buf.toString().trim();
      if (text.isNotEmpty) {
        await widget.sessions.addMessage(
          sessionId: sessionId,
          role: 'assistant',
          content: text,
          modelId: 'dify-t6',
        );
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(e));
    } finally {
      if (!mounted) return;
      await _reloadMessages();
      setState(() => _askBusy = false);
      _ticket('会话进行中');
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _askBusy || _currentSessionId == null) return;

    // L2：快照在写入本轮 user 消息之前，确保本轮问题不出现在前文块中
    final historySnapshot = List<ChatMessage>.from(_messages);

    setState(() {
      _askBusy = true;
      _error = null;
    });
    _ticket('正在回答追问…');

    await widget.sessions.addMessage(
      sessionId: _currentSessionId!,
      role: 'user',
      content: text,
    );

    final query = _controller.buildQuery(
      history: historySnapshot,
      task: AiTask.t5Ask,
      currentQuestion: text,
    );

    final answer = StringBuffer();
    try {
      await for (final chunk in widget.ai.chat(AiTask.t5Ask, query)) {
        if (chunk.delta != null) answer.write(chunk.delta);
        if (chunk.done) break;
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(e));
    } finally {
      if (!mounted) return;
      final finalAnswer = answer.isEmpty ? '(无响应)' : answer.toString();
      await widget.sessions.addMessage(
        sessionId: _currentSessionId!,
        role: 'assistant',
        content: finalAnswer,
        modelId: 'dify-t5',
      );
      await _reloadMessages();
      setState(() => _askBusy = false);
      _ticket('会话进行中');
    }

    _input.clear();
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

  Future<void> _reloadMessages() async {
    if (_currentSessionId == null) return;
    final msgs = await widget.sessions.listMessages(_currentSessionId!);
    if (mounted) setState(() => _messages = msgs);
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

  void _openSessionPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SessionManagerSheet(
        kp: widget.kp,
        sessions: _sessions,
        currentSessionId: _currentSessionId,
        primarySessionId: _primarySessionId,
        controller: _controller,
        onCreated: () => _bootstrap(),
        onSelected: (id) {
          Navigator.pop(context);
          _switchSession(id);
        },
        onRenamed: () => _bootstrap(),
        onCleared: () => _reloadMessages(),
        onDeleted: (result) {
          Navigator.pop(context);
          if (result.$1 != null) {
            _switchSession(result.$1!);
          } else {
            _bootstrap();
          }
        },
      ),
    );
  }

  Future<void> _switchSession(String sessionId) async {
    final msgs = await widget.sessions.listMessages(sessionId);
    if (!mounted) return;
    setState(() {
      _currentSessionId = sessionId;
      _messages = msgs;
    });
    _ticket('会话进行中');
  }

  @override
  void dispose() {
    // 先放锁再拆控件：会话页关掉 = `kp:{id}` 解锁 + 托盘行消失。
    widget.jobs.releaseInteractive(_sessionTicket);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('老师模式 · ${widget.kp.name}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.forum_outlined),
            tooltip: '会话列表',
            onPressed: _openSessionPanel,
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: '新建会话',
            onPressed: () async {
              final session = await _controller.createUserSession();
              if (!mounted) return;
              await _switchSession(session.id);
              _ticket('新会话');
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (value == 'rename' && _currentSessionId != null) {
                final newTitle = await askNameDialog(
                  context,
                  title: '重命名会话',
                  hint: '输入新名称',
                  initial: _sessions
                      .firstWhere((s) => s.id == _currentSessionId,
                          orElse: () => AiSessionRow(
                              id: '',
                              version: 0,
                              updatedAt: DateTime.now(),
                              deviceId: '',
                              type: '',
                              targetRef: '',
                              title: '',
                              tutorState: ''))
                      .title,
                );
                if (newTitle != null && newTitle.isNotEmpty) {
                  await widget.sessions.renameSession(_currentSessionId!, newTitle);
                  if (mounted) _bootstrap();
                }
              } else if (value == 'clear' && _currentSessionId != null) {
                final confirmed = await confirmDialog(
                  context,
                  title: '清空消息',
                  message: '会话会保留，消息不可恢复。',
                );
                if (confirmed) {
                  await widget.sessions.clearMessages(_currentSessionId!);
                  if (mounted) await _reloadMessages();
                }
              } else if (value == 'delete' && _currentSessionId != null) {
                final isPrimary = _currentSessionId == _primarySessionId;
                String message;
                if (isPrimary) {
                  final next = _sessions
                      .where((s) => s.id != _currentSessionId! && s.deletedAt == null)
                      .toList();
                  final nextTitle = next.isNotEmpty
                      ? deriveSessionTitle(
                          storedTitle: next.first.title,
                          messages: await widget.sessions.listMessages(next.first.id),
                          fallbackTitle: '${widget.kp.name} 讲解',
                        )
                      : '';
                  message = kDeletePrimaryConfirmTemplate
                      .replaceAll('{nextTitle}', nextTitle);
                } else {
                  message = '连同消息一起删除，不可恢复。';
                }
                final confirmed = await confirmDialog(
                  context,
                  title: '删除会话',
                  message: message,
                );
                if (confirmed) {
                  final result = await _controller.deleteSession(
                    sessionId: _currentSessionId!,
                    context: context,
                  );
                  if (!mounted) return;
                  if (result.$1 != null) {
                    await _switchSession(result.$1!);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(result.$3)),
                      );
                    }
                  } else {
                    await _bootstrap();
                  }
                }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'rename',
                child: Text('重命名会话'),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: Text('清空消息'),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Text('删除会话'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _KpHeader(kp: widget.kp, mastery: _mastery),
          const Divider(height: 1),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      _currentSessionId == _primarySessionId
                          ? kEmptyPrimaryGuidance
                          : '这个会话还没有内容，问点什么吧',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
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
                      return _MessageBubble(
                        role: m.role,
                        content: m.content,
                        isExplain: isExplainMessage(m),
                      );
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
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
                        onPressed: _askBusy ? null : _send,
                        icon: _askBusy
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
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _askBusy ? null : () => _generateExplainOnce(
                          sessionId: _currentSessionId ?? ''),
                      icon: _askBusy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 16),
                      label: const Text(kRegenerateLabel),
                    ),
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
                padding: const EdgeInsets.only(top: 4),
                child: Text(kp.definition,
                    style: const TextStyle(fontSize: 13)),
              ),
            if (kp.sourceQuote.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
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
  const _MessageBubble({
    required this.role,
    required this.content,
    this.isExplain = false,
  });
  final String role;
  final String content;
  final bool isExplain;

  @override
  Widget build(BuildContext context) {
    final isUser = role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (isExplain)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 2),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.indigo.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '讲解',
                  style: TextStyle(fontSize: 11, color: Colors.indigo),
                ),
              ),
            ),
          Align(
            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
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
                style: TextStyle(
                    color: isUser ? Colors.white : Colors.black87),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 会话管理底部弹层。
class _SessionManagerSheet extends StatelessWidget {
  const _SessionManagerSheet({
    required this.kp,
    required this.sessions,
    required this.currentSessionId,
    required this.primarySessionId,
    required this.controller,
    required this.onCreated,
    required this.onSelected,
    required this.onRenamed,
    required this.onCleared,
    required this.onDeleted,
  });

  final KnowledgePoint kp;
  final List<AiSessionRow> sessions;
  final String? currentSessionId;
  final String? primarySessionId;
  final TeacherSessionController controller;
  final VoidCallback onCreated;
  final ValueChanged<String> onSelected;
  final VoidCallback onRenamed;
  final VoidCallback onCleared;
  final ValueChanged<(String?, String, String)> onDeleted;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      // ⚠️ 形参名不得叫 controller：本 sheet 有一个同名的会话控制器字段，
      // 会被这个 ScrollController 形参遮蔽。
      builder: (_, scrollCtrl) => Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Row(
              children: [
                const Text('会话列表',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: ListTile(
              leading: const Icon(Icons.add_comment),
              title: const Text('新建对话'),
              subtitle: Text(kNewSessionHint),
              onTap: () async {
                Navigator.pop(context);
                onCreated();
              },
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scrollCtrl,
              itemCount: sessions.length,
              itemBuilder: (_, i) {
                final s = sessions[i];
                final isCurrent = s.id == currentSessionId;
                final isPrimary = s.id == primarySessionId;
                return ListTile(
                  leading: Icon(
                    isCurrent ? Icons.chat_bubble : Icons.chat_bubble_outline,
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          deriveSessionTitle(
                            storedTitle: s.title,
                            messages: [],
                            fallbackTitle: isPrimary
                                ? '${kp.name} 讲解'
                                : '${kp.name} 会话',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isPrimary)
                        Container(
                          margin: const EdgeInsets.only(left: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.indigo.shade100,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('默认',
                              style: TextStyle(fontSize: 10)),
                        ),
                    ],
                  ),
                  subtitle: Text(
                    '${_fmtTime(s.updatedAt)} · ${s.type == "chat" ? "聊天" : "讲解"}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) async {
                      if (value == 'rename') {
                        final newTitle = await askNameDialog(
                          context,
                          title: '重命名会话',
                          hint: '输入新名称',
                          initial: s.title,
                        );
                        if (newTitle != null && newTitle.isNotEmpty) {
                          await controller.renameSession(s.id, newTitle);
                          if (context.mounted) {
                            Navigator.pop(context);
                            onRenamed();
                          }
                        }
                      } else if (value == 'clear') {
                        final confirmed = await confirmDialog(
                          context,
                          title: '清空消息',
                          message: '会话会保留，消息不可恢复。',
                        );
                        if (confirmed) {
                          await controller.clearSession(s.id);
                          if (context.mounted) {
                            Navigator.pop(context);
                            onCleared();
                          }
                        }
                      } else if (value == 'delete') {
                        final isPrimarySession = s.id == primarySessionId;
                        final message = isPrimarySession
                            ? kDeletePrimaryConfirmTemplate
                                .replaceAll('{nextTitle}', '会话列表')
                            : '连同消息一起删除，不可恢复。';
                        final confirmed = await confirmDialog(
                          context,
                          title: '删除会话',
                          message: message,
                        );
                        if (confirmed) {
                          final result = await controller.deleteSession(
                            sessionId: s.id,
                            context: context,
                          );
                          if (context.mounted) {
                            Navigator.pop(context);
                            onDeleted(result);
                          }
                        }
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('重命名'),
                      ),
                      const PopupMenuItem(
                        value: 'clear',
                        child: Text('清空消息'),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('删除'),
                      ),
                    ],
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    onSelected(s.id);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) {
    return '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

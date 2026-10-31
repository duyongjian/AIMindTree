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
///
/// D：改后台任务，页面销毁不中断 —— 讲解（T6）与追问（T5）的流式读取 +
/// 落库整体跑在 [AiJobService.runDetached] 的执行体里（托盘一行可见、
/// 可取消），用户中途退出页面时回答照样写进库。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../ai/ai_job_service.dart';
import '../../ai/ai_service.dart';
import '../../ai/ai_task.dart';
import '../../data/db/drift_database.dart' show AiSessionRow;
import '../../data/models/knowledge_point.dart';
import '../../data/repositories/ai_session_repository.dart';
import '../../data/repositories/knowledge_repository.dart';
import '../shared/session_ui.dart';
import 'markdown_message.dart';
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

  /// D：当前流式生成的后台任务（取消链路的文案锚点）。
  ///
  /// 任务的**执行体**由 [AiJobService] 持有，页面 dispose 不会中断它；
  /// 这里只留一个句柄，供托盘点「取消」时补一句「正在取消…」。
  DetachedTask? _running;

  /// D：后台任务终态订阅 —— 生成可能在本页销毁期间跑完，回到本页时把结果
  /// 补进消息流（否则用户会看到「托盘说已生成、会话里却是空的」）。
  StreamSubscription<AiJob>? _jobSub;

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
      // D：托盘点本行的 ✕ → **真正把这个知识点的后台生成取消掉**。
      //     只改文案是不行的：`_running` 是一个 `runDetached` 任务，页面
      //     自己 `break` 不掉它（读流循环在 service 持有的 Future 里），
      //     必须走 `cancel()` 才会置 cancelRequested + 触发 interrupt。
      onCancel: () {
        final running = _running;
        if (running == null) return;
        unawaited(widget.jobs.cancel(running.id));
      },
    );
    // D：本知识点的后台生成（`kp:{id}:chat` 锁）一落终态就补拉消息。
    _jobSub = widget.jobs.terminalStream.listen((job) {
      if (!mounted || job.resourceKey != _chatLockKey) return;
      unawaited(_reloadMessages());
    });
    _bootstrap();
  }

  /// D：老师模式「生成中」任务的资源锁（与会话锁 `kp:{id}` 是两个 key）。
  String get _chatLockKey => 'kp:${widget.kp.id}:chat';

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

  /// 自动讲解 / 「再讲一次」：产出一段讲解并落到 [sessionId] 会话里。
  ///
  /// D：改后台任务，页面销毁不中断 —— 建好 query 后把「读流 + 落库」整体
  /// 交给 [AiJobService.runDetached]，用户中途退出页面（`mounted == false`）
  /// 时回答照样写进库，不再丢。
  Future<void> _generateExplainOnce({required String sessionId}) async {
    // 已有一段讲解在生成：本页连点，或上次退出页面后后台任务仍在跑（
    // 那种情况同一个 `kp:{id}:chat` 锁还被占着，绝不能再开一段）。
    if (_askBusy || widget.jobs.isLocked(_chatLockKey)) return;
    final sid = sessionId.isNotEmpty ? sessionId : (_currentSessionId ?? '');
    if (sid.isEmpty) {
      if (mounted) setState(() => _error = '还没有会话，请先新建一个会话。');
      return;
    }

    final history = await widget.sessions.listMessages(sid);
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

    if (!mounted) return;
    // 先把「生成中」的气泡状态立起来，再登记后台任务。
    setState(() {
      _askBusy = true;
      _error = null;
    });

    _startStreamJob(
      sessionId: sid,
      task: task,
      query: query,
      modelId: 'dify-t6',
      startMessage: '正在生成讲解…',
      doneMessage: '讲解已生成',
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _askBusy || _currentSessionId == null) return;

    // L2：快照在写入本轮 user 消息之前，确保本轮问题不出现在前文块中
    final historySnapshot = List<ChatMessage>.from(_messages);
    final sessionId = _currentSessionId!;

    setState(() {
      _askBusy = true;
      _error = null;
    });
    // 回答改由后台任务产出，本轮不再「等答案才能清输入框」。
    _input.clear();

    await widget.sessions.addMessage(
      sessionId: sessionId,
      role: 'user',
      content: text,
    );

    final query = _controller.buildQuery(
      history: historySnapshot,
      task: AiTask.t5Ask,
      currentQuestion: text,
    );

    _startStreamJob(
      sessionId: sessionId,
      task: AiTask.t5Ask,
      query: query,
      modelId: 'dify-t5',
      startMessage: '正在回答追问…',
      doneMessage: '回答已生成',
      // 旧实现空回答落 `(无响应)`，保留这条语义（它本身是一条有效消息）。
      emptyFallback: '(无响应)',
    );

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

  /// 登记一个「流式读 + 落库」的后台任务（讲解 / 追问共用）。
  ///
  /// D：改后台任务，页面销毁不中断。执行体内三条铁律：
  /// - **落库无条件执行**（不再 `if (!mounted)` 包 DB 写）——这正是回答
  ///   不丢的关键；只有 `setState` 前面才判 `mounted`；
  /// - **逐块检查取消**：托盘点 ✕ → `isCanceled` 为真 → 下一块即 break，
  ///   半截回答**不入库**（避免把残缺答案当成完整讲解留在会话里）；
  /// - **进度节流**：累计 ≥200 字或距上次刷新 >400ms 才刷托盘，否则每块都
  ///   刷新会让托盘行疯狂抖动。
  void _startStreamJob({
    required String sessionId,
    required AiTask task,
    required String query,
    required String modelId,
    required String startMessage,
    required String doneMessage,
    String emptyFallback = '',
  }) {
    final bg = widget.jobs.runDetached(
      // 行名与页级会话行（`老师模式：xxx`）区分开：一个在跑、一个只是开着页。
      label: '老师模式 · 生成中：${widget.kp.name}',
      // ⚠️ 页级会话锁是 `kp:{id}`（initState 里占的），这里必须换一个 key，
      // 否则 `runDetached` 会把同一张锁表里的 key 覆盖掉、自己把自己锁死。
      resourceKey: _chatLockKey,
      silent: false,
      doneMessage: doneMessage,
      body: (t) async {
        t.progress(startMessage);
        final buf = StringBuffer();
        var flushedChars = 0;
        var flushedAt = DateTime.now();
        try {
          await for (final chunk in widget.ai.chat(task, query)) {
            // 用户已请求取消：下一块就收工（不必等模型吐完）。
            if (t.isCanceled) break;
            if (chunk.delta != null) buf.write(chunk.delta);
            final now = DateTime.now();
            if (buf.length - flushedChars >= 200 ||
                now.difference(flushedAt) > const Duration(milliseconds: 400)) {
              flushedChars = buf.length;
              flushedAt = now;
              t.progress('已生成 ${buf.length} 字');
            }
            if (chunk.done) break;
          }
          if (t.isCanceled) {
            t.progress('已取消');
            return;
          }
          var text = buf.toString().trim();
          if (text.isEmpty && emptyFallback.isNotEmpty) text = emptyFallback;
          if (text.isNotEmpty) {
            // 无条件落库：页面已销毁也照写（回答不能因为退出页面而消失）。
            await widget.sessions.addMessage(
              sessionId: sessionId,
              role: 'assistant',
              content: text,
              modelId: modelId,
            );
          }
          t.progress('已完成', percent: 1);
        } on Object catch (e) {
          if (t.isCanceled) {
            t.progress('已取消');
            return;
          }
          // 托盘会把终态记成 failed；页面还活着就顺带把原因挂到消息流下方。
          if (mounted) setState(() => _error = _friendlyError(e));
          rethrow;
        } finally {
          _running = null;
          if (mounted) {
            setState(() => _askBusy = false);
            await _reloadMessages();
          }
        }
      },
    );
    _running = bg;
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
        onCreated: () => _createAndSwitchSession(),
        // ⚠️ 这里**不能**再 `Navigator.pop(context)`：弹层自己在 onTap 里已经
        // 关掉了，父页再 pop 一次弹掉的就是 TeacherPage 自身的路由 → 直接
        // 退回上一页（用户报「点会话就返回了知识点列表」）。
        onSelected: (id) => _switchSession(id),
        onRenamed: () => _bootstrap(),
        onCleared: () => _reloadMessages(),
        onDeleted: (result) async {
          // 同上：弹层的删除分支在回调前已经 pop 过，这里不能再 pop。
          if (result.$1 != null) {
            await _switchSession(result.$1!);
          } else {
            await _bootstrap();
          }
          // 已删的那条不能留在内存列表里，否则重开面板还看得见它。
          await _refreshSessions();
        },
      ),
    );
  }

  /// 新建一条用户会话并切过去（会话面板「新建对话」与 AppBar「新建会话」共用）。
  ///
  /// ★ 不能复用 [_bootstrap]：它只做「合并老数据 → 取主会话」，主会话已存在时
  ///   压根不会新建任何会话 —— 这就是「点新建对话毫无反应」的根因。
  Future<void> _createAndSwitchSession() async {
    final session = await _controller.createUserSession();
    if (!mounted) return;
    // 刷新列表，否则重开面板看不到刚建的这条。
    await _refreshSessions();
    await _switchSession(session.id);
    _ticket('新会话');
  }

  /// 重新拉一次会话列表（新建 / 删除后都能立刻反映到面板里）。
  Future<void> _refreshSessions() async {
    final list = await widget.sessions.listSessionsForKp(widget.kp.id);
    if (!mounted) return;
    setState(() => _sessions = list);
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
    // 页面走了但后台生成还在跑：只断「回填消息」的订阅，任务本身不受影响。
    _jobSub?.cancel();
    _jobSub = null;
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
            onPressed: () => _createAndSwitchSession(),
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
        // 去掉原先整条 indigo.shade50 大色块（会话列表上方「一大滩多余颜色」），
        // 改成安静的浅灰底 + 一条细分隔线，和全 App 视觉一致。
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
        ),
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
              child: isUser
                  ? Text(
                      content,
                      style: const TextStyle(color: Colors.white),
                    )
                  // 老师（助手）回复是 Markdown + LaTeX：渲染成富文本，
                  // 不再把 `##`/`**`/`$...$` 原样显示成源码。
                  : MarkdownMessage(data: content),
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

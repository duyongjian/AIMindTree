/// AI Agent 入口（问答中识别「需要的知识点 / 薄弱点」，让用户选择加入指定知识树）。
///
/// 设计要点（参照产品方法论：最小闭环、薄弱点定位是核心痛点、AI 输出可控可改、锚点铁律）：
/// 1. 自由问答：复用 T5 流式对话，不绑定单个知识点，像一个随时在线的学习搭子。
/// 2. 每轮 AI 回答后跑一次「检测」：让 AI 从对话中抽两类建议——
///    - needed：对话涉及、用户应掌握的知识点；
///    - weak：用户明显薄弱 / 混淆 / 答错的知识点。
///    检测结果是「建议」，**不入库**；用户可勾选加入知识树，也可「不添加」。
/// 3. 加入知识树（D：直连知识点）：检测建议**没有原文出处**，走 T1 锚定必被
///    整条剔除，因此按「手动知识点」（origin=user_manual，锚点豁免，PRD §4.2）
///    直建，再幂等并入所选树。**不再先建笔记**；与 canvas_page 共用的
///    [ExtractIntoTreeChain]（笔记 → T1 路径）保持原样，本页不走。
/// 4. 会话管理（H）：一个「会话」= 一行 kpId 为空的 ai_session，消息落
///    ai_messages；标题运行时派生（首条 user 消息 / 时间），重命名写现有
///    title 列。AI 不可用时历史会话照样能看。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../ai/ai_job_service.dart' show kAiJobQueueEnabled;
import '../../ai/ai_task.dart';
import '../../ai/agent_tools.dart';
import '../../ai/extraction_service.dart';
import '../../canvas/layout_autoplace.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/models/knowledge_tree.dart';
import '../../data/repositories/ai_session_repository.dart';
import '../../data/repositories/knowledge_repository.dart';
import '../../data/repositories/tree_repository.dart';

/// 工具协议（**客户端透传**，与 ``_runDetection`` 同款模式）：
/// 工具目录是 Dart 侧动态生成的，放不进服务端提示词文件；服务端主形态
/// ``t5_ask.md`` 保证「模型没按协议输出」时退化为正常问答，不会崩。
/// 协议要求模型要么输出**一行工具调用 JSON**，要么直接自然语言回答。
const String _kToolProtocol = '''
你可以使用下列「只读工具」查询用户自己的知识库（知识树 / 知识点 / 笔记 / 前置关系）：
- 需要数据时：只输出一行 JSON，形如 {"tool":"工具名","args":{...}}；
  不要任何解释、不要 ``` 围栏、不要输出思考过程。
- 不需要工具时：直接用自然语言回答，不要输出 JSON。
- 工具只能读取，不能修改任何数据。
- tree_id / point_id / note_id 必须是工具结果里出现过的真实 id，不要臆造；
  传入不存在的 id 会返回错误，请改正参数或直接说明查不到。''';

/// 对话中检测到的「知识点建议」：分「需要的知识点」与「薄弱点」两类。
class AgentDetectedItem {
  const AgentDetectedItem({
    required this.name,
    this.definition = '',
    this.reason = '',
    this.weak = false,
  });

  final String name;
  final String definition;
  final String reason;

  /// true = 薄弱点（用户明显不会）；false = 需要的知识点（应掌握但未在树里）。
  final bool weak;

  String toMarkdown() => '# $name\n\n$definition';

  @override
  bool operator ==(Object other) =>
      other is AgentDetectedItem && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// D：直连入树结果（建点 / 入树的执行明细，供 UI 精确移除与提示）。
class DirectAddResult {
  const DirectAddResult({
    required this.createdIds,
    required this.createdNames,
    required this.addedCount,
    required this.failures,
  });

  /// 新建知识点的 id（与 [createdNames] 同序对齐）。
  final List<String> createdIds;

  /// 新建成功的知识点名（用于从检测列表精确移除成功项）。
  final List<String> createdNames;

  /// 实际并入树的点数（[TreeRepository.addPoints] 幂等去重后）。
  final int addedCount;

  /// 创建失败的知识点名（建点抛错 / 名称为空）。
  final List<String> failures;
}

/// D：把检测建议**直连**为手动知识点并入树（不建笔记、不走 T1 锚定）。
///
/// 为什么直连：检测建议没有原文出处，走 T1 锚定必被整条剔除（无出处不入库），
/// 所以按 origin=user_manual 直建（锚点豁免，PRD §4.2）。
/// 抽成模块级函数：agent 页与单测共用同一实现，避免「逻辑藏在 UI 里测不到」。
Future<DirectAddResult> addDetectedDirectlyToTree({
  required KnowledgeRepository repo,
  required TreeRepository trees,
  required AppDatabase db,
  required KnowledgeTree tree,
  required List<AgentDetectedItem> items,
}) async {
  final ids = <String>[];
  final names = <String>[];
  final failures = <String>[];
  for (final item in items) {
    final res = await repo.createManualKnowledgePoint(
      name: item.name,
      // needed / weak 都按「概念」直建：检测建议无原文，锚点字段只能留空，
      // 类型仅作展示分类，统一 concept 最稳（类型可在知识库页再改）。
      type: KnowledgePointType.concept,
      definition: item.definition,
    );
    res.fold(
      (kp) {
        ids.add(kp.id);
        names.add(item.name);
      },
      (e, _) => failures.add(item.name),
    );
  }
  if (ids.isEmpty) {
    return DirectAddResult(
      createdIds: const <String>[],
      createdNames: const <String>[],
      addedCount: 0,
      failures: failures,
    );
  }
  final existing = (await trees.memberPointIds(tree.id)).toSet();
  final newIds = ids.where((id) => !existing.contains(id)).toList();
  final addRes = await trees.addPoints(tree.id, ids);
  final added = addRes.valueOrNull ?? 0;
  // 新并入的点 x/y 默认 0，用布局引擎铺开（与 canvas 页同一函数，避免叠在原点）。
  if (added > 0 && newIds.isNotEmpty) {
    await autoPlaceNewPointsInTree(
      db: db,
      trees: trees,
      repo: repo,
      treeId: tree.id,
      newIds: newIds,
    );
  }
  return DirectAddResult(
    createdIds: ids,
    createdNames: names,
    addedCount: added,
    failures: failures,
  );
}

/// 会话标题：优先用户在 title 列里的重命名覆盖；否则**运行时派生**——
/// 首条 user 消息首行（截 24 字），没有再退「新对话」。
///
/// ai_sessions 本就带 title 列（tables.dart），重命名直接写该列即可，
/// **不需要改表结构**；未重命名时该列为空，退回派生标题。
String deriveSessionTitle({
  required String storedTitle,
  required List<ChatMessage> messages,
}) {
  final override = storedTitle.trim();
  if (override.isNotEmpty) return override;
  for (final m in messages) {
    if (m.role != 'user') continue;
    final first = m.content.trim().split('\n').first.trim();
    if (first.isEmpty) continue;
    return first.length <= 24 ? first : '${first.substring(0, 24)}…';
  }
  return '新对话';
}

/// 会话列表时间戳（本地时区，MM-dd HH:mm）。
String fmtSessionTime(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

/// 弹一个单行输入框（建树命名 / 会话重命名共用）。
Future<String?> askNameDialog(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
}) async {
  final c = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(hintText: hint, isDense: true),
        onSubmitted: (_) => Navigator.pop(ctx, c.text.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, c.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  return name;
}

/// 通用确认框（清空 / 删除会话）。
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定')),
      ],
    ),
  );
  return ok ?? false;
}

/// 一条对话消息。
class _Msg {
  const _Msg({required this.role, required this.content});
  final String role; // 'user' | 'assistant'
  final String content;
}

class AgentPage extends StatefulWidget {
  const AgentPage({
    super.key,
    required this.service,
    required this.db,
    this.debugSeedDetected,
  });

  final ExtractionService service;
  final AppDatabase db;

  /// 测试注入的初始检测项（仅单测用；生产不传）。
  ///
  /// 让 widget 测试能绕过「必须真的聊一轮」直接验证检测面板的
  /// 收起 / 不添加 / 批量不添加交互。
  @visibleForTesting
  final List<AgentDetectedItem>? debugSeedDetected;

  @override
  State<AgentPage> createState() => AgentPageState();
}

class AgentPageState extends State<AgentPage> {
  static final AppLog _log = AppLog('agent_page');

  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _busy = false;
  String? _error;
  String? _conversationId;

  /// H：当前会话行 id（一个「会话」= 一行 ai_session；null = 尚未建）。
  String? _sessionId;

  /// H：会话仓储（与 main.dart 各自持有实例，底层同一个 AppDatabase）。
  late final AiSessionRepository _sessions = AiSessionRepository(widget.db);

  List<_Msg> _history = const <_Msg>[];
  bool _detecting = false;

  /// 检测到的建议（去重累加，跨多轮；仅当前会话的内存态，切会话即清空）。
  List<AgentDetectedItem> _detected = const <AgentDetectedItem>[];
  final Set<AgentDetectedItem> _picked = <AgentDetectedItem>{};

  /// G：检测面板是否展开（默认展开；收起只显示标题行）。
  bool _panelExpanded = true;

  /// 目标知识树（对话语境 + 加入落点）。null = 未指定，加入前须先选。
  List<KnowledgeTree> _trees = const <KnowledgeTree>[];
  KnowledgeTree? _activeTree;

  /// 知识库只读工具集（T5 问答可查询用户自己的数据；权限字段预留）。
  late final AgentToolset _tools;

  /// 输入栏上方的瞬态状态（思考中 / 正在查某个工具）。
  String _status = '';

  @override
  void initState() {
    super.initState();
    _tools = AgentToolset.create(
      repo: widget.service.repo,
      trees: widget.service.trees,
    );
    _detected = widget.debugSeedDetected ?? const <AgentDetectedItem>[];
    _loadTrees();
    _initSession();
  }

  Future<void> _loadTrees() async {
    final trees = await widget.service.trees.listTrees();
    if (!mounted) return;
    setState(() {
      _trees = trees;
      // 选中项要换成新列表里的实例（DropdownButton 用 identical 比较）：
      // KnowledgeTree 未重写 ==，listTrees 每次查库都是新对象，沿用旧实例会
      // 匹配不上任何菜单项，DropdownButton 直接断言崩溃。树被别处删掉时同步
      // 降为 null，避免留下指向已删树的陈旧选中态。
      final prevId = _activeTree?.id;
      if (prevId != null) {
        final idx = trees.indexWhere((t) => t.id == prevId);
        _activeTree = idx == -1 ? null : trees[idx];
      }
    });
  }

  /// 供 AppShell 切 Tab 时调用：重查知识树列表，让别处刚删/建的树及时反映。
  /// （本页在 IndexedStack 常驻，initState 只跑一次，必须外部触发刷新。）
  Future<void> refresh() => _loadTrees();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ===================== H：会话管理 =====================

  /// 进页面：打开最近一次会话；没有则新建。
  ///
  /// 纯本地 DB 操作，**AI 不可用时历史照样能看能切**。
  Future<void> _initSession() async {
    try {
      final sessions = await _sessions.listAgentSessions();
      if (!mounted) return;
      if (sessions.isEmpty) {
        // 首次自动建会话只是补一行会话记录：不重置视图态（生产里此刻视图态
        // 本就是空的，重置与否无差别；保留语义更保守）。
        await _newSession(resetView: false);
      } else {
        await _openSession(sessions.first);
      }
    } on Object catch (e) {
      // 会话初始化失败不阻断问答（_send 里还会兜底建会话）。
      _log.w('会话初始化失败（不影响问答）：$e');
    }
  }

  /// 新建对话（建会话行；[resetView] = 是否同时清空当前视图态）。
  Future<void> _newSession({bool resetView = true}) async {
    try {
      final s = await _sessions.createAgentSession();
      if (!mounted) return;
      setState(() {
        _sessionId = s.id;
        if (resetView) {
          _history = const <_Msg>[];
          _detected = const <AgentDetectedItem>[];
          _picked.clear();
          // Dify conversationId 只存内存：换会话即重开（App 重启同样失效，
          // 历史消息仍可看，见 AiSessionRepository 文档）。
          _conversationId = null;
        }
      });
    } on Object catch (e) {
      _log.w('新建会话失败：$e');
    }
  }

  /// 切换 / 打开某会话：读消息重建视图（工具回显不入库，只留 user/assistant）。
  Future<void> _openSession(AiSessionRow row) async {
    try {
      final msgs = await _sessions.listMessages(row.id);
      if (!mounted) return;
      setState(() {
        _sessionId = row.id;
        _history = msgs
            .where((m) => m.role == 'user' || m.role == 'assistant')
            .map((m) => _Msg(role: m.role, content: m.content))
            .toList();
        _detected = const <AgentDetectedItem>[];
        _picked.clear();
        _conversationId = null;
      });
    } on Object catch (e) {
      _log.w('打开会话失败：$e');
    }
  }

  /// 当前会话被删 / 清空后重新对齐：还在就重开，没了就取最新或新建。
  Future<void> _resyncCurrentSession() async {
    final id = _sessionId;
    if (id != null) {
      final sessions = await _sessions.listAgentSessions();
      if (!mounted) return;
      final still = sessions.where((s) => s.id == id).toList();
      if (still.isNotEmpty) {
        await _openSession(still.first);
        return;
      }
    }
    final sessions = await _sessions.listAgentSessions();
    if (!mounted) return;
    if (sessions.isEmpty) {
      await _newSession();
    } else {
      await _openSession(sessions.first);
    }
  }

  /// 发送前确保有会话行（初始化失败时的兜底）。
  Future<void> _ensureSession() async {
    if (_sessionId != null) return;
    final s = await _sessions.createAgentSession();
    if (!mounted) return;
    setState(() => _sessionId = s.id);
  }

  /// 消息落 ai_messages（失败只记日志：持久化是增强，不阻断问答）。
  Future<void> _persistMessage(String role, String content) async {
    final id = _sessionId;
    if (id == null || content.trim().isEmpty) return;
    try {
      await _sessions.addMessage(sessionId: id, role: role, content: content);
    } on Object catch (e) {
      _log.w('消息持久化失败（$role）：$e');
    }
  }

  /// 打开会话管理面板（H：列表 + 切换 / 重命名 / 清空 / 删除 / 新建）。
  Future<void> _openSessionSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SessionManagerSheet(
        sessions: _sessions,
        currentSessionId: _sessionId,
        onOpen: _openSession,
        onNew: () async {
          await _newSession();
        },
        onCurrentMutated: _resyncCurrentSession,
      ),
    );
  }

  // ===================== 问答 =====================

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    await _ensureSession();
    setState(() {
      _busy = true;
      _error = null;
      _status = 'AI 正在思考…';
      _history = [..._history, _Msg(role: 'user', content: text)];
    });
    _input.clear();
    _scrollToEnd();
    await _persistMessage('user', text);

    // 工具循环：每一轮都是一次完整的 T5 问答；整轮输出是合法工具调用 →
    // 就地执行（只读）并把结果并入下一轮；否则即为最终答案。
    // 轮数上限 kAgentToolMaxRounds 防模型反复调用工具不回答。
    final toolLog = StringBuffer();
    for (var round = 1; round <= kAgentToolMaxRounds; round++) {
      final buf = StringBuffer();
      var convId = _conversationId;
      try {
        await for (final c in widget.service.ai.chat(
          AiTask.t5Ask,
          _composeQuery(text, toolLog.toString()),
          conversationId: _conversationId,
        )) {
          if (c.conversationId != null) convId = c.conversationId;
          if (c.delta != null) buf.write(c.delta);
        }
      } on Object catch (e) {
        if (!mounted) return;
        setState(() {
          _error = _friendlyError(e);
          _busy = false;
          _status = '';
        });
        return;
      }
      _conversationId = convId;

      final call = AgentToolset.parseCall(buf.toString());
      if (call == null) {
        // 最终答案（自然语言）。
        await _finishWithAnswer(buf.toString());
        return;
      }

      // 工具调用：执行 + 回显（用户看得见 AI 查了什么）。
      if (!mounted) return;
      setState(() => _status = '🔧 正在查询知识库（${call.name}）…');
      final result = await _tools.dispatch(call.name, call.args);
      toolLog.writeln('【第 $round 轮工具调用】${call.name} ${jsonEncode(call.args)}');
      toolLog.writeln('【第 $round 轮工具结果】$result');
      if (!mounted) return;
      setState(() {
        _history = [
          ..._history,
          _Msg(role: 'tool', content: '🔧 ${call.name} → ${cutText(result, 140)}'),
        ];
      });
      _scrollToEnd();
    }

    // 轮数用尽：最后再问一次，明确禁止工具、基于已有结果直接作答；
    // 这一轮的输出一律当最终答案（即使形状像工具调用也不再执行）。
    final buf = StringBuffer();
    try {
      await for (final c in widget.service.ai.chat(
        AiTask.t5Ask,
        _composeQuery(text, toolLog.toString(), forceAnswer: true),
        conversationId: _conversationId,
      )) {
        if (c.delta != null) buf.write(c.delta);
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(e);
        _busy = false;
        _status = '';
      });
      return;
    }
    await _finishWithAnswer(buf.toString());
  }

  /// 拼接带工具协议的 query（透传模式：上下文全在 user message 里）。
  ///
  /// [forceAnswer] = 工具轮数用尽后的收尾轮：追加「禁止再调用工具」。
  String _composeQuery(String text, String toolLog, {bool forceAnswer = false}) {
    final ctx = _activeTree == null
        ? ''
        : '（你正在帮用户在知识树「${_activeTree!.name}」里补全知识点，'
            '回答时请围绕这张树的脉络展开。）\n\n';
    final b = StringBuffer()
      ..write(ctx)
      ..write(_kToolProtocol)
      ..write('\n\n【可用工具】\n')
      ..write(_tools.catalogText());
    if (toolLog.isNotEmpty) {
      b
        ..write('\n\n【已执行的工具调用与结果】\n')
        ..write(toolLog)
        ..write('\n（工具结果已给出。还缺关键信息才可以再调用一个工具，'
            '否则请直接用自然语言给出最终回答，不要输出 JSON。）');
    }
    b.write('\n\n【用户问题】\n$text\n');
    if (forceAnswer) {
      b.write('\n（工具调用次数已达上限：禁止再调用工具，必须基于以上信息直接回答；'
          '信息不足就直说，不要编造。）');
    }
    return b.toString();
  }

  /// 收尾：落最终答案（持久化）+ 跑每轮检测。
  Future<void> _finishWithAnswer(String answer) async {
    if (!mounted) return;
    setState(() {
      _history = [..._history, _Msg(role: 'assistant', content: answer)];
      _busy = false;
      _status = '';
    });
    _scrollToEnd();
    await _persistMessage('assistant', answer);

    // 每轮回答后自动检测薄弱点 / 需要的知识点。
    await _runDetection();
  }

  void _scrollToEnd() {
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

  // ===================== 检测 =====================

  /// 从当前对话抽「需要的知识点」与「薄弱点」两类建议。
  ///
  /// 复用 T5（``variant='detect'``，服务端透传 + JSON 修复）。队列路径（B3）：
  /// 静默提交——占 ``conversation:agent`` 锁 + 托盘计时，终态不弹 SnackBar，
  /// 失败只写日志（检测是增强能力，不阻断主问答）；开关关闭 / 服务不可达 →
  /// 原流式路径兜底。
  Future<void> _runDetection() async {
    if (_detecting || _history.isEmpty) return;
    if (!mounted) return;

    final prompt = await _buildDetectPrompt();
    if (prompt == null || !mounted) return;

    if (kAiJobQueueEnabled) {
      try {
        final job = await widget.service.jobs.submit(
          task: 'T5',
          resourceKey: 'conversation:agent',
          label: '分析对话中的知识点建议',
          query: prompt,
          variant: 'detect',
          silent: true,
          onDone: (j) => _applyDetection(j.result?['content'] as String? ?? ''),
          onError: (e) => _log.w('检测失败（忽略）：$e'),
          onCancel: () {
            if (mounted) setState(() => _detecting = false);
          },
        );
        if (job == null) {
          // 锁被占（上一轮检测仍在跑）：静默跳过，下轮问答后再检测。
          _log.i('检测跳过：conversation:agent 锁被占');
          return;
        }
        if (mounted) setState(() => _detecting = true);
      } on Object catch (e) {
        _log.w('检测提交失败（回落同步路径）：$e');
        await _runDetectionSync(prompt);
      }
      return;
    }
    await _runDetectionSync(prompt);
  }

  /// 拼检测 prompt：树上下文（活跃树已有知识点）+ 对话转录。
  /// 页面在查库期间被销毁则返回 null。
  Future<String?> _buildDetectPrompt() async {
    var treeCtx = '';
    if (_activeTree != null) {
      final ids = await widget.service.trees.memberPointIds(_activeTree!.id);
      final pts = await widget.service.repo.pointsByIds(ids);
      if (pts.isNotEmpty) {
        treeCtx = '用户正在构建知识树「${_activeTree!.name}」，已有知识点：'
            '${pts.map((p) => p.name).join('、')}。'
            '请重点指出用户还缺哪些、哪些明显薄弱。\n\n';
      }
    }

    final transcript = _history
        .map((m) => '${m.role == 'user' ? '用户' : 'AI'}：${m.content}')
        .join('\n');
    return '${treeCtx}下面是用户与 AI 助手的对话。请识别其中：\n'
        '1) needed：对话涉及、用户应当掌握的知识点；\n'
        '2) weak：用户明显薄弱 / 混淆 / 答错的知识点。\n'
        '只输出一个 JSON 对象，不要任何解释或代码块标记：\n'
        '{"needed":[{"name":"","definition":"","reason":""}],'
        '"weak":[{"name":"","definition":"","reason":""}]}\n\n'
        '对话：\n$transcript';
  }

  /// 同步路径（开关关闭 / 提交失败兜底）：原流式实现。
  Future<void> _runDetectionSync(String prompt) async {
    if (!mounted) return;
    setState(() => _detecting = true);

    final buf = StringBuffer();
    try {
      // variant='detect'：让服务端装载 t5_ask__detect.md（只输出 JSON 契约）。
      await for (final c in widget.service.ai
          .chat(AiTask.t5Ask, prompt, variant: 'detect')) {
        if (c.delta != null) buf.write(c.delta);
      }
    } on Object catch (e) {
      _log.w('检测调用失败（忽略）：$e');
      if (mounted) setState(() => _detecting = false);
      return;
    }
    _applyDetection(buf.toString());
  }

  /// 解析检测输出 → 按名字去重合并进 [_detected] → 清进行中标。
  /// 队列路径（服务端已 JSON 修复）与同步路径共用。
  void _applyDetection(String raw) {
    final items = _parseDetection(raw);
    if (!mounted) return;
    if (items.isNotEmpty) {
      final merged = <AgentDetectedItem>[..._detected];
      for (final it in items) {
        if (!merged.any((d) => d.name == it.name)) merged.add(it);
      }
      setState(() => _detected = merged);
    }
    if (mounted) setState(() => _detecting = false);
  }

  List<AgentDetectedItem> _parseDetection(String raw) {
    var s = raw.trim();
    // 去掉可能的 ```json 围栏。
    if (s.startsWith('```')) {
      s = s.substring(s.indexOf('\n') + 1);
      if (s.endsWith('```')) s = s.substring(0, s.length - 3);
    }
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start < 0 || end <= start) return const <AgentDetectedItem>[];
    try {
      final map = jsonDecode(s.substring(start, end + 1)) as Map<String, dynamic>;
      final out = <AgentDetectedItem>[];
      void take(String key, bool weak) {
        final list = map[key];
        if (list is! List) return;
        for (final e in list) {
          if (e is! Map) continue;
          final name = (e['name'] as String?)?.trim() ?? '';
          if (name.isEmpty) continue;
          out.add(AgentDetectedItem(
            name: name,
            definition: (e['definition'] as String?)?.trim() ?? '',
            reason: (e['reason'] as String?)?.trim() ?? '',
            weak: weak,
          ));
        }
      }

      take('needed', false);
      take('weak', true);
      return out;
    } on Object catch (e) {
      _log.w('检测 JSON 解析失败（忽略）：$e');
      return const <AgentDetectedItem>[];
    }
  }

  // ===================== 加入知识树（D：直连知识点） =====================

  /// 加入知识树：勾选项 → 直连建 user_manual 知识点 → 幂等并入所选树。
  ///
  /// 不再先建笔记 / 不走 T1 锚定：检测建议无原文出处，锚定必被整条剔除
  /// （PRD §4.2 手动点锚点豁免）。与 canvas_page 共用的 ExtractIntoTreeChain
  /// 保持原样（那是「笔记 → T1」路径，本页不碰）。
  Future<void> _addToTree() async {
    final chosen = _detected.where((d) => _picked.contains(d)).toList();
    if (chosen.isEmpty) {
      _toast('先勾选要加入的知识点');
      return;
    }
    final tree = _activeTree;
    if (tree == null) {
      _toast('先在上方选择目标知识树');
      return;
    }

    final result = await addDetectedDirectlyToTree(
      repo: widget.service.repo,
      trees: widget.service.trees,
      db: widget.db,
      tree: tree,
      items: chosen,
    );
    if (!mounted) return;

    // 只移除「建成功」的；失败的留在列表里可重试。
    final created = result.createdNames.toSet();
    setState(() {
      _detected = _detected.where((d) => !created.contains(d.name)).toList();
      _picked.clear();
    });
    if (result.addedCount == 0 && result.createdIds.isEmpty) {
      _toast('加入失败：${result.failures.join('、')} 创建知识点出错');
      return;
    }
    var msg = '已加入「${tree.name}」：${result.addedCount} 个';
    if (result.failures.isNotEmpty) {
      msg += '（${result.failures.join('、')} 创建失败）';
    }
    _toast(msg);
  }

  // ===================== 目标树选择 =====================

  Future<KnowledgeTree?> _createTreeInline() async {
    final name = await askNameDialog(
      context,
      title: '新建知识树',
      hint: '给这棵树起个名字',
    );
    if (name == null || name.trim().isEmpty) return null;
    final res = await widget.service.trees.createTree(name.trim());
    if (!mounted) return null;
    final created = res.valueOrNull;
    if (created == null) {
      res.fold((_) => null, (e, _) => _toast('新建失败：$e'));
      return null;
    }
    await _loadTrees();
    if (!mounted) return created;
    // 选中项必须取新列表里的同 id 实例：createTree 返回的对象与 listTrees
    // 重新查出来的不是同一个（KnowledgeTree 未重写 ==，identical 比较下
    // 匹配不上任何菜单项，DropdownButton 会断言崩溃）。
    final idx = _trees.indexWhere((t) => t.id == created.id);
    setState(() => _activeTree = idx == -1 ? created : _trees[idx]);
    return created;
  }

  Widget _buildTreePicker() {
    final trees = _trees;
    return DropdownButtonHideUnderline(
      child: DropdownButton<KnowledgeTree?>(
        isExpanded: true,
        hint: const Text('选择知识树'),
        value: _activeTree,
        items: [
          for (final t in trees)
            DropdownMenuItem(
              value: t,
              child: Text(
                t.name.isEmpty ? '(未命名)' : t.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const DropdownMenuItem<KnowledgeTree?>(
            value: null,
            child: Row(
              children: [
                Icon(Icons.add, size: 18),
                SizedBox(width: 4),
                Text('＋ 新建知识树'),
              ],
            ),
          ),
        ],
        onChanged: (v) async {
          if (v == null) {
            await _createTreeInline();
          } else {
            setState(() => _activeTree = v);
          }
        },
      ),
    );
  }

  // ===================== UI =====================

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('AI 助手'),
          actions: [
            // H：会话管理入口（历史列表 + 切换 / 重命名 / 清空 / 删除 / 新建）。
            IconButton(
              tooltip: '会话',
              icon: const Icon(Icons.history),
              onPressed: _openSessionSheet,
            ),
          ],
          bottom: _activeTree == null
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(34),
                  child: Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    color: Colors.teal.shade50,
                    child: Text(
                      '并入目标树：「${_activeTree!.name}」',
                      style: const TextStyle(fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
        ),
        body: Column(
          children: [
            Expanded(
              child: _history.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error == null
                              ? '和 AI 助手聊一聊你的学习。每轮回答后，'
                                  '它会标出你「需要的知识点」和「薄弱点」，\n'
                                  '勾选后即可一键加入指定知识树。'
                              : '错误：$_error',
                          style: const TextStyle(color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: _history.length + (_error != null ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (_error != null && i == _history.length) {
                          return Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text('错误：$_error',
                                style: const TextStyle(color: Colors.red)),
                          );
                        }
                        final m = _history[i];
                        return _Bubble(role: m.role, content: m.content);
                      },
                    ),
            ),
            if (_detected.isNotEmpty) _buildDetectPanel(),
            _buildInputBar(),
          ],
        ),
      );

  Widget _buildDetectPanel() {
    final needed = _detected.where((d) => !d.weak).toList();
    final weak = _detected.where((d) => d.weak).toList();
    final expanded = _panelExpanded;
    // Container 只画边框，背景色交给内层 Material：ListTile（勾选行）的墨水
    // 反馈需要就近的 Material 祖先，直接给带底色的 Container 会触发
    // 「ListTile background color or ink splashes may be invisible」断言。
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Material(
        color: Colors.grey.shade50,
        child: Column(
        children: [
          // G：头部整行可点，收起 / 展开（收起只显示标题）。
          InkWell(
            onTap: () => setState(() => _panelExpanded = !expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: Colors.grey,
                  ),
                  Icon(Icons.auto_awesome_outlined,
                      size: 16, color: Colors.teal),
                  const SizedBox(width: 6),
                  Text('检测到的知识点（${_detected.length}）',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (_detecting)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    TextButton(
                      onPressed: _runDetection,
                      child: const Text('重新分析'),
                    ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            // G：批量「不添加」（仅从本地检测列表移除，不入库、不持久化）。
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: _picked.isEmpty ? null : _removePickedDetected,
                    icon: const Icon(Icons.playlist_remove, size: 16),
                    label: Text('批量不添加（${_picked.length}）'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _removeAllDetected,
                    icon: const Icon(Icons.clear_all, size: 16),
                    label: const Text('全不添加'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  if (weak.isNotEmpty) ...[
                    const _SectionLabel(text: '薄弱点（应重点补）', weak: true),
                    for (final d in weak)
                      _DetectTile(
                        item: d,
                        picked: _picked,
                        onTap: _toggle,
                        onRemove: _removeDetected,
                      ),
                  ],
                  if (needed.isNotEmpty) ...[
                    const _SectionLabel(text: '需要的知识点', weak: false),
                    for (final d in needed)
                      _DetectTile(
                        item: d,
                        picked: _picked,
                        onTap: _toggle,
                        onRemove: _removeDetected,
                      ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.account_tree_outlined,
                      size: 18, color: Colors.grey),
                  const SizedBox(width: 8),
                  const Text('并入：', style: TextStyle(fontSize: 13)),
                  Expanded(child: _buildTreePicker()),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add),
                    onPressed: _picked.isEmpty || _activeTree == null
                        ? null
                        : _addToTree,
                    label: Text('加入（${_picked.length}）'),
                  ),
                ],
              ),
            ),
          ],
        ],
        ),
      ),
    );
  }

  void _toggle(AgentDetectedItem item) {
    setState(() {
      if (_picked.contains(item)) {
        _picked.remove(item);
      } else {
        _picked.add(item);
      }
    });
  }

  /// G：单条「不添加」——仅从本地检测列表移除（不入库、不持久化）。
  void _removeDetected(AgentDetectedItem item) {
    setState(() {
      _detected = _detected.where((d) => d.name != item.name).toList();
      _picked.remove(item);
    });
  }

  /// G：批量不添加（对勾选项）——从本地检测列表移除已选项。
  void _removePickedDetected() {
    setState(() {
      _detected = _detected.where((d) => !_picked.contains(d)).toList();
      _picked.clear();
    });
  }

  /// G：全不添加——清空整个本地检测列表。
  void _removeAllDetected() {
    setState(() {
      _detected = const <AgentDetectedItem>[];
      _picked.clear();
    });
  }

  Widget _buildInputBar() => SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Colors.grey.shade300)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 瞬态状态：思考中 / 正在查某个工具（工具循环的进度可视化）。
              if (_busy && _status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 6),
                  child: Text(_status,
                      style: const TextStyle(fontSize: 12, color: Colors.teal)),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: '问：导数和微分到底有什么区别？',
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
            ],
          ),
        ),
      );

  // ===================== 工具 =====================

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('没有任何可用的 AI Provider')) {
      return '当前没有可用的 AI Provider。请到「设置」页确认已配置 Dify Key，'
          '并重启 App 使其生效。';
    }
    return s;
  }
}

/// 对话气泡。role='user' 用户（青色右对齐）；'tool' 工具调用回显
/// （小号灰色左对齐，不带气泡）；其余为 AI 回答。
class _Bubble extends StatelessWidget {
  const _Bubble({required this.role, required this.content});
  final String role;
  final String content;

  @override
  Widget build(BuildContext context) {
    if (role == 'tool') {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
          child: SelectableText(
            content,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
      );
    }
    final isUser = role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        decoration: BoxDecoration(
          color: isUser ? Colors.teal : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(10),
        ),
        child: SelectableText(
          content,
          style: TextStyle(color: isUser ? Colors.white : Colors.black87),
        ),
      ),
    );
  }
}

/// 检测项（可勾选 + 行尾「不添加」）。
class _DetectTile extends StatelessWidget {
  const _DetectTile({
    required this.item,
    required this.picked,
    required this.onTap,
    required this.onRemove,
  });
  final AgentDetectedItem item;
  final Set<AgentDetectedItem> picked;
  final ValueChanged<AgentDetectedItem> onTap;

  /// G：「不添加」——仅从本地检测列表移除（不入库、不持久化）。
  final ValueChanged<AgentDetectedItem> onRemove;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
        contentPadding: const EdgeInsets.only(left: 8, right: 8),
        controlAffinity: ListTileControlAffinity.leading,
        value: picked.contains(item),
        onChanged: (_) => onTap(item),
        title: Row(
          children: [
            if (item.weak)
              const Icon(Icons.warning_amber_rounded,
                  size: 14, color: Colors.orange)
            else
              const Icon(Icons.lightbulb_outline,
                  size: 14, color: Colors.teal),
            const SizedBox(width: 6),
            Expanded(
              child: Text(item.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        subtitle: item.reason.isNotEmpty
            ? Text(item.reason,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12))
            : null,
        secondary: IconButton(
          icon: const Icon(Icons.close, size: 16),
          tooltip: '不添加',
          visualDensity: VisualDensity.compact,
          onPressed: () => onRemove(item),
        ),
        dense: true,
      );
}

/// 分组小标题。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text, required this.weak});
  final String text;
  final bool weak;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
        child: Text(
          text,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12,
            color: weak ? Colors.orange.shade800 : Colors.teal.shade800,
          ),
        ),
      );
}

/// H：会话管理面板（历史列表 + 切换 / 重命名 / 清空 / 删除 / 新建）。
///
/// 标题：优先 title 列里的重命名覆盖，否则运行时派生（见 [deriveSessionTitle]）。
/// 所有动作走 [AiSessionRepository]，软删铁律（读过滤 deleted_at isNull）。
class _SessionManagerSheet extends StatefulWidget {
  const _SessionManagerSheet({
    required this.sessions,
    required this.currentSessionId,
    required this.onOpen,
    required this.onNew,
    required this.onCurrentMutated,
  });

  final AiSessionRepository sessions;
  final String? currentSessionId;

  /// 切换 / 打开某会话（页面负责重建视图）。
  final Future<void> Function(AiSessionRow row) onOpen;

  /// 新建对话。
  final Future<void> Function() onNew;

  /// 当前会话被删 / 被清空后，页面重新对齐当前会话。
  final Future<void> Function() onCurrentMutated;

  @override
  State<_SessionManagerSheet> createState() => _SessionManagerSheetState();
}

class _SessionManagerSheetState extends State<_SessionManagerSheet> {
  /// 自增 revision：任何变更后 +1，FutureBuilder 据此重新拉列表。
  int _revision = 0;

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _revision++);
  }

  /// 拉「会话行 + 消息」对（消息用于派生标题与条数；会话量小，逐条查可接受）。
  Future<List<(AiSessionRow, List<ChatMessage>)>> _load() async {
    final rows = await widget.sessions.listAgentSessions();
    final out = <(AiSessionRow, List<ChatMessage>)>[];
    for (final r in rows) {
      out.add((r, await widget.sessions.listMessages(r.id)));
    }
    return out;
  }

  Future<void> _onMenu(
      String action, AiSessionRow row, List<ChatMessage> msgs) async {
    switch (action) {
      case 'rename':
        final name = await askNameDialog(
          context,
          title: '重命名会话',
          hint: '给会话起个名字',
          initial: deriveSessionTitle(storedTitle: row.title, messages: msgs),
        );
        if (name == null || name.trim().isEmpty) return;
        await widget.sessions.renameSession(row.id, name.trim());
        await _refresh();
      case 'clear':
        final ok = await confirmDialog(
          context,
          title: '清空该会话的消息？',
          message: '会话会保留，消息不可恢复。',
        );
        if (!ok) return;
        await widget.sessions.clearMessages(row.id);
        await widget.onCurrentMutated();
        await _refresh();
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: '删除该会话？',
          message: '连同消息一起删除，不可恢复。',
        );
        if (!ok) return;
        await widget.sessions.deleteSession(row.id);
        await widget.onCurrentMutated();
        await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.add_comment_outlined),
              title: const Text('新建对话'),
              onTap: () async {
                Navigator.pop(context);
                await widget.onNew();
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<List<(AiSessionRow, List<ChatMessage>)>>(
                key: ValueKey<int>(_revision),
                future: _load(),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final list = snap.data ?? const <(AiSessionRow, List<ChatMessage>)>[];
                  if (list.isEmpty) {
                    return const Center(child: Text('还没有历史会话'));
                  }
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final (row, msgs) = list[i];
                      final title = deriveSessionTitle(
                        storedTitle: row.title,
                        messages: msgs,
                      );
                      final current = row.id == widget.currentSessionId;
                      return ListTile(
                        selected: current,
                        leading: Icon(current
                            ? Icons.chat_bubble
                            : Icons.chat_bubble_outline),
                        title: Text(title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${fmtSessionTime(row.updatedAt)} · ${msgs.length} 条消息'),
                        trailing: PopupMenuButton<String>(
                          tooltip: '会话操作',
                          onSelected: (v) => _onMenu(v, row, msgs),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'rename', child: Text('重命名')),
                            PopupMenuItem(value: 'clear', child: Text('清空消息')),
                            PopupMenuItem(value: 'delete', child: Text('删除会话')),
                          ],
                        ),
                        onTap: () async {
                          Navigator.pop(context);
                          await widget.onOpen(row);
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
/// 5. 后台可见（D）：一轮问答期间在托盘挂一行「AI 助手：回答中」（可取消）；
///    回答最终答案无条件落库，页面切走 / 销毁也不丢。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../ai/ai_job_service.dart' show kAiJobQueueEnabled, AiJobStatus;
import '../../ai/ai_task.dart';
import '../../ai/agent_memory.dart';
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
import '../knowledge/kp_dedup.dart';
import '../shared/session_context.dart';
import '../shared/session_ui.dart';

// 会话相关的共享工具已搬到 `lib/features/shared/session_ui.dart`；
// 这里 re-export 以**保持既有 import 路径不变**（调用方与既有测试零改动）。
export '../shared/session_ui.dart'
    show deriveSessionTitle, fmtSessionTime, askNameDialog, confirmDialog;

/// 工具协议（**客户端透传**，与 ``_runDetection`` 同款模式）：
/// 工具目录是 Dart 侧动态生成的，放不进服务端提示词文件；服务端主形态
/// ``t5_ask.md`` 保证「模型没按协议输出」时退化为正常问答，不会崩。
/// 协议要求模型要么输出**一行工具调用 JSON**，要么直接自然语言回答。
const String _kToolProtocol = '''
你可以使用下列「知识库工具」查询或修改用户自己的数据：

【只读工具】list_knowledge_trees / list_tree_points / get_knowledge_point /
find_knowledge_points / list_notes / get_note / get_point_relations。
需要查看数据时，输出一行工具调用 JSON 即可。

【写入工具】create_note / update_note / delete_note / create_knowledge_point /
update_knowledge_point / set_mastery / soft_delete_knowledge_point /
restore_knowledge_point / purge_knowledge_point / create_knowledge_tree /
rename_knowledge_tree / delete_knowledge_tree / add_points_to_tree /
remove_points_from_tree / create_group / rename_group / add_group_members /
remove_group_members / delete_group / add_prerequisite_edge /
delete_prerequisite_edge / save_memory / delete_memory。
当用户想「新增 / 修改 / 删除 / 连线 / 记一笔长期记忆」任何数据时，使用对应的
写入工具。注意：写入操作会先列成清单让你逐项确认，**你批准后才真正写入**，
被拒的操作不会执行——所以放心提议，由用户把关。

通用约定：
- 需要数据时：只输出一行 JSON，形如 {"tool":"工具名","args":{...}}；
  不要任何解释、不要 ``` 围栏、不要输出思考过程。
- 不需要工具时：直接用自然语言回答，不要输出 JSON。
- tree_id / point_id / note_id / group_id 必须是工具结果里出现过的真实 id，
  不要臆造；传入不存在的 id 会被拒绝，请改正参数或直接说明查不到。
- 危险操作（删树 / 彻底删除 / 删笔记带删点）会被高亮警示，请如实说明影响。''';

/// 对话中检测到的「知识点建议」：分「需要的知识点」与「薄弱点」两类。
class AgentDetectedItem {
  const AgentDetectedItem({
    required this.name,
    this.definition = '',
    this.reason = '',
    this.weak = false,
    this.extension = false,
  });

  final String name;
  final String definition;
  final String reason;

  /// true = 薄弱点（用户明显不会）；false = 需要的知识点（应掌握但未在树里）。
  final bool weak;

  /// true = 树外延伸（同一知识体系里树还没有、AI 建议补进树）。
  final bool extension;

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
  late final AiSessionRepository _sessions =
      AiSessionRepository(widget.db, deviceId: widget.service.repo.deviceId);

  /// AI 助手长期记忆存储（设置里可开关 / 查看内容）。
  final AgentMemoryStore _memory = AgentMemoryStore();

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

  /// D：用户已在托盘点了「取消」——流式循环逐块检查它，看到就收工。
  ///
  /// 本页的问答是「模型 → 工具 → 用户逐项批准 → 再问」的多轮循环，中途要弹
  /// 审批框，**不能**整段搬进 `runDetached`；因此只把这一轮登记成托盘里的
  /// 交互会话行（可见 + 可取消），取消语义靠这个标记 + 循环检查实现。
  bool _cancelRequested = false;

  /// D：本轮问答的托盘会话 id（空 = 没在问答；`releaseInteractive` 用）。
  String _sessionTicket = '';

  @override
  void initState() {
    super.initState();
    _tools = AgentToolset.create(
      repo: widget.service.repo,
      trees: widget.service.trees,
      groups: widget.service.groups,
      memory: _memory,
    );
    _detected = widget.debugSeedDetected ?? const <AgentDetectedItem>[];
    _loadTrees();
    _initMemory();
    _initSession();
  }

  /// 记忆初始化（读开关 + 预解析文件路径）；失败只记日志，不影响问答。
  Future<void> _initMemory() async {
    try {
      await _memory.init();
    } on Object catch (e) {
      _log.w('记忆初始化失败（不影响问答）：$e');
    }
    if (mounted) setState(() {});
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
      _tools.setActiveTree(_activeTree?.id);
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

  /// 发送一轮问答（D：整轮在托盘可见 + 可取消）。
  ///
  /// 只做三件事：拦空 / 忙、占一行托盘交互会话、把重活交给 [_runTurn]。
  /// `finally` 保证托盘行在**任何**返回路径（[_runTurn] 内多处提前 return）
  /// 上都被撤掉，不会留一条永远「进行中」的幽灵行。
  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    // 先立忙碌态再 await：同一帧连点两次不会双开一轮（否则两条托盘会话行的
    // id 会互相覆盖，前一条永远不被释放）。
    setState(() => _busy = true);
    _cancelRequested = false;
    _sessionTicket = '';
    try {
      await _ensureSession();
      _sessionTicket = widget.service.jobs.holdInteractive(
        'agent:chat',
        label: 'AI 助手：回答中',
        onCancel: () {
          // 托盘点 ✕ → 置标记 + 换文案；下一块数据到达 / 下一轮开始时即退出。
          _cancelRequested = true;
          widget.service.jobs.setInteractiveMessage(_sessionTicket, '正在取消…');
        },
      );
      await _runTurn(text);
    } on Object catch (e) {
      // 兜底：任何未预期异常都要把轮次收干净（托盘行 finally 释放）。
      _log.w('问答异常：$e');
      if (mounted) {
        setState(() {
          _error = _friendlyError(e);
          _busy = false;
          _status = '';
        });
      }
    } finally {
      widget.service.jobs.releaseInteractive(_sessionTicket);
      _sessionTicket = '';
      _cancelRequested = false;
    }
  }

  /// 取消收尾：清忙碌态。半截回答**不落库**（已入库的用户消息保留）。
  void _abortCanceled() {
    _cancelRequested = false;
    if (mounted) {
      setState(() {
        _busy = false;
        _status = '';
      });
    }
  }

  /// 一轮问答的执行体：工具循环 + 收尾作答。
  ///
  /// 托盘会话的占位 / 释放与取消标记的复位由调用方 [_send] 负责。
  Future<void> _runTurn(String text) async {
    // 页面在 `_ensureSession` 的 await 期间被销毁：用户消息照样落库，只不刷 UI。
    if (!mounted) {
      await _persistMessage('user', text);
      return;
    }
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
    // 读工具就地执行（只读）并把结果并入下一轮；写工具先生成操作清单、
    // 经用户逐项勾选批准后才执行，被拒的不写；否则即为最终答案。
    // 轮数上限 kAgentToolMaxRounds 防模型反复调用工具不回答。
    final memoryCtx = await _buildMemoryContext();
    // L2 前文：由公共纯函数组装（AI 助手与老师模式共用同一份实现，避免两份
    // 同构实现各自漂移）。默认 maxMessages=12 / maxChars=0 → 与迁移前的私有
    // 实现 `_buildSessionContext()` **输出逐字相同**。
    final sessionCtx = buildSessionContext(
      _history.map((m) => (role: m.role, content: m.content)).toList(),
    );
    final toolLog = StringBuffer();
    for (var round = 1; round <= kAgentToolMaxRounds; round++) {
      // 取消（托盘 ✕）：不再开始新一轮。
      if (_cancelRequested) {
        _abortCanceled();
        return;
      }
      widget.service.jobs
          .setInteractiveMessage(_sessionTicket, '第 $round 轮：正在思考…');
      final buf = StringBuffer();
      var convId = _conversationId;
      try {
        await for (final c in widget.service.ai.chat(
          AiTask.t5Ask,
          _composeQuery(
            text,
            toolLog.toString(),
            memoryCtx: memoryCtx,
            sessionCtx: sessionCtx,
          ),
          conversationId: _conversationId,
        )) {
          // 取消即停收：本轮的半截文本随后被整体丢弃（不上屏、不入库）。
          if (_cancelRequested) break;
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
      if (_cancelRequested) {
        _abortCanceled();
        return;
      }

      final call = AgentToolset.parseCall(buf.toString());
      if (call == null) {
        // 最终答案（自然语言）。
        await _finishWithAnswer(buf.toString());
        return;
      }

      // 读工具：直接执行（权限闸在 dispatch 内）。
      if (_tools.findWrite(call.name) == null) {
        if (!mounted) return;
        setState(() => _status = '🔧 正在查询知识库（${call.name}）…');
        widget.service.jobs
            .setInteractiveMessage(_sessionTicket, '正在执行工具…');
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
        continue;
      }

      // 写工具：记忆关闭时直接阻止记忆写工具，不弹审批框。
      if (!mounted) return;
      if ((call.name == 'save_memory' || call.name == 'delete_memory') &&
          !_memory.enabled) {
        toolLog.writeln('【写入】${call.name} 被阻止：记忆功能已关闭');
        setState(() {
          _history = [
            ..._history,
            _Msg(role: 'tool', content: '⛔ ${call.name} 被阻止：记忆功能已关闭'),
          ];
        });
        _scrollToEnd();
        continue;
      }

      // 生成操作计划（含存在性校验）；规划失败 → 回灌模型自我纠正。
      final plan = await _tools.planWrite(call.name, call.args);
      if (plan.isError) {
        toolLog.writeln('【写入】${call.name} 规划失败：${plan.error}');
        if (!mounted) return;
        setState(() {
          _history = [
            ..._history,
            _Msg(role: 'tool', content: '⚠️ ${call.name} 无法执行：${plan.error}'),
          ];
        });
        _scrollToEnd();
        continue;
      }

      // 弹审批清单，逐项勾选；返回空 = 用户全部拒绝。
      setState(() => _status = '⏳ 等待你确认操作…');
      widget.service.jobs
          .setInteractiveMessage(_sessionTicket, '等待你确认操作…');
      final approved = await _requestApproval([plan]);
      if (!mounted) return;
      // 审批框开着时用户也点了托盘 ✕ → 一行都不写，直接收工。
      if (_cancelRequested) {
        _abortCanceled();
        return;
      }
      if (approved.isEmpty) {
        toolLog.writeln('【写入】用户拒绝了操作：${call.name}');
        setState(() {
          _history = [
            ..._history,
            _Msg(role: 'tool', content: '⛔ 已拒绝：${plan.summary}'),
          ];
        });
        _scrollToEnd();
        // 把「被拒」告知模型，让它调整或改用自然语言回答。
        continue;
      }

      for (final p in approved) {
        final res = await _tools.executeWrite(p.toolName, p.args);
        toolLog.writeln('【已执行】${p.toolName} ${jsonEncode(p.args)} → $res');
        if (!mounted) return;
        setState(() {
          _history = [
            ..._history,
            _Msg(role: 'tool', content: '✅ ${p.summary}'),
          ];
        });
      }
      _scrollToEnd();
      // 写操作可能改变了树 / 知识点，刷新选择器与检测上下文。
      await _loadTrees();
    }

    // 轮数用尽：最后再问一次，明确禁止工具、基于已有结果直接作答；
    // 这一轮的输出一律当最终答案（即使形状像工具调用也不再执行）。
    if (_cancelRequested) {
      _abortCanceled();
      return;
    }
    widget.service.jobs
        .setInteractiveMessage(_sessionTicket, '正在整理最终回答…');
    final buf = StringBuffer();
    try {
      await for (final c in widget.service.ai.chat(
        AiTask.t5Ask,
        _composeQuery(
          text,
          toolLog.toString(),
          forceAnswer: true,
          memoryCtx: memoryCtx,
          sessionCtx: sessionCtx,
        ),
        conversationId: _conversationId,
      )) {
        // 取消即停收（半截最终回答不入库）。
        if (_cancelRequested) break;
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
    // 取消时不落半截回答（用户消息已在开头入库，保留）。
    if (_cancelRequested) {
      _abortCanceled();
      return;
    }
    await _finishWithAnswer(buf.toString());
  }

  /// 拼接带工具协议的 query（透传模式：上下文全在 user message 里）。
  ///
  /// [memoryCtx] / [sessionCtx] 分别注入长期记忆与单会话前文（见 _send）。
  /// [forceAnswer] = 工具轮数用尽后的收尾轮：追加「禁止再调用工具」。
  String _composeQuery(
    String text,
    String toolLog, {
    bool forceAnswer = false,
    String memoryCtx = '',
    String sessionCtx = '',
  }) {
    final tree = _activeTree;
    final ctx = tree == null
        ? ''
        : '（当前知识树：「${tree.name}」，id=${tree.id}。'
            '查看这棵树的知识点可直接调用 list_tree_points，'
            'tree_id 可省略（默认即当前树）或填 ${tree.id}，'
            '无需再先调用 list_knowledge_trees 查 id。'
            '回答时请围绕这张树的脉络展开。）\n'
            '（若用户想学这张树里还没有、但属于同一知识体系的内容，'
            '请结合已有知识点的脉络做延伸讲解，明确指出哪些是树外补充，'
            '不要因为树里没有就拒答。）\n\n';
    final b = StringBuffer()
      ..write(ctx)
      ..write(_kToolProtocol)
      ..write('\n\n【可用工具】\n')
      ..write(_tools.catalogText());
    if (sessionCtx.isNotEmpty) {
      b..write('\n\n')..write(sessionCtx);
    }
    if (memoryCtx.isNotEmpty) {
      b..write('\n\n')..write(memoryCtx);
    }
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

  // ===================== 记忆 / 会话上下文 / 审批 =====================

  /// 长期记忆上下文（开启时）；关闭或为空返回 ''。
  Future<String> _buildMemoryContext() async {
    if (!_memory.enabled) return '';
    try {
      return await _memory.toContext();
    } on Object {
      return '';
    }
  }

  /// 单会话前文：把当前会话里最近的 user/assistant 轮回灌给模型，
  /// 保证同一会话内问答互相参考、不彼此孤立。
  /// 写入操作审批：列出操作清单，每项一个勾选框，返回用户勾选批准的部分。
  /// 返回空列表 = 用户全部拒绝（不执行任何写入）。
  Future<List<AgentToolPlan>> _requestApproval(List<AgentToolPlan> plans) async {
    final checked = <int>{for (var i = 0; i < plans.length; i++) i};
    final result = await showDialog<List<AgentToolPlan>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSt) => AlertDialog(
          title: const Text('请确认要执行的操作'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text('以下操作会修改你的本地数据，勾选要执行的项：',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                const SizedBox(height: 8),
                for (var i = 0; i < plans.length; i++)
                  _ApprovalTile(
                    plan: plans[i],
                    checked: checked.contains(i),
                    onChanged: (v) => setSt(() {
                      if (v) checked.add(i);
                      else checked.remove(i);
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, const <AgentToolPlan>[]),
              child: const Text('全部拒绝'),
            ),
            ElevatedButton(
              onPressed: checked.isEmpty
                  ? null
                  : () => Navigator.pop(ctx, [for (final i in checked) plans[i]]),
              child: Text('执行选中的 ${checked.length} 项'),
            ),
          ],
        ),
      ),
    );
    return result ?? const <AgentToolPlan>[];
  }

  /// 打开 AI 助手设置（记忆开关 / 查看 / 清空）。
  Future<void> _openAgentSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AgentSettingsSheet(
        memory: _memory,
        onChanged: () => setState(() {}),
      ),
    );
  }

  /// 收尾：落最终答案（持久化）+ 跑每轮检测。
  ///
  /// D：改后台任务，页面销毁不中断 —— 落库**无条件**执行（用户切走 / 退出
  /// 页面后回答不能丢），只有 UI 副作用（setState / 滚动 / 检测）才判
  /// `mounted`。
  Future<void> _finishWithAnswer(String answer) async {
    await _persistMessage('assistant', answer);
    if (!mounted) return;
    setState(() {
      _history = [..._history, _Msg(role: 'assistant', content: answer)];
      _busy = false;
      _status = '';
    });
    _scrollToEnd();

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

  /// 问题3：基于当前树已有知识点，让 AI 梳理「树外延伸」概念
  /// （同一知识体系里树还没有、值得补的），结果并入检测面板可直接勾选入树。
  Future<void> _runExtension() async {
    final tree = _activeTree;
    if (tree == null) {
      _toast('请先在上方选择知识树，再让 AI 梳理树外延伸');
      return;
    }
    if (_detecting) return;
    setState(() => _detecting = true);
    _toast('正在梳理「${tree.name}」的树外延伸…');
    final ids = await widget.service.trees.memberPointIds(tree.id);
    final pts = await widget.service.repo.pointsByIds(ids);
    final names = pts.map((p) => p.name).join('、');
    final prompt = '用户正在构建知识树「${tree.name}」，目前树里只有这些知识点：'
        '${names.isEmpty ? '（空树）' : names}。\n'
        '请基于这张树的主题与已有脉络，列出 3-8 个「树里还没有、但属于同一知识体系、'
        '值得补进来深入学」的延伸概念（可以是现有知识点的前置基础、并列分支或后续进阶）。\n'
        '只输出一个 JSON 对象，不要任何解释或代码块标记：\n'
        '{"extension":[{"name":"","definition":"","reason":""}]}\n'
        'reason 要说明它和树里哪个已有知识点相关、为什么值得延伸。';
    // 登记成托盘后台任务：切走页面后仍能在「后台任务」托盘看到它在跑、并可取消。
    // buf 提到外层：body 与 `await task.done` 之后的解析共用同一份已收集内容。
    final buf = StringBuffer();
    final task = widget.service.jobs.runDetached(
      label: 'AI 助手 · 延伸讲解：${tree.name}',
      // 不传 resourceKey（保持默认空串 = 不占锁）：本方法与「重新分析」可能并发，
      // 占锁会把 holdInteractive('agent:chat') 的锁逻辑搞复杂，这里无需互斥。
      silent: true, // 终态不弹 SnackBar（本页自有 _detecting 状态，避免打扰）；托盘行仍可见。
      doneMessage: '延伸梳理完成',
      body: (t) async {
        var flushedChars = 0;
        var flushedAt = DateTime.now();
        try {
          await for (final c in widget.service.ai.chat(AiTask.t5Ask, prompt)) {
            // 用户点托盘「取消」：下一块就收工（不必等模型吐完）。
            if (t.isCanceled) break;
            if (c.delta != null) buf.write(c.delta);
            // 进度节流：累计 ≥200 字或距上次刷新 >400ms 才刷托盘，避免托盘行疯狂抖动。
            final now = DateTime.now();
            if (buf.length - flushedChars >= 200 ||
                now.difference(flushedAt) > const Duration(milliseconds: 400)) {
              flushedChars = buf.length;
              flushedAt = now;
              t.progress('已梳理 ${buf.length} 字…');
            }
          }
        } on Object catch (e) {
          // 记日志后**必须** rethrow：让 AiJobService 把任务标 failed，
          // 页面才能区分「真失败」与「成功了但没梳理出概念」（吞掉会把失败伪装成没概念）。
          _log.w('树外延伸失败（忽略）：$e');
          rethrow;
        }
      },
    );
    // done 在 done / failed / canceled 都会 complete，不抛；页面被销毁也不会卡住
    // （Future 由 jobs 持有，body 独立跑完才 complete，与页面生命周期无关）。
    await task.done;
    if (task.isCanceled) {
      // 取消后必须复位 _detecting（否则按钮永久禁用）；半截结果不解析入面板。
      if (mounted) setState(() => _detecting = false);
      return;
    }
    if (task.job.status == AiJobStatus.failed) {
      // silent:true 压掉了服务层 SnackBar，失败提示只能由页面自己给
      // （否则用户会把「调用失败」误当成「没梳理出概念」）。
      final msg = task.job.errorMessage ?? '未知错误';
      if (mounted) setState(() => _detecting = false);
      _toast('延伸梳理失败：$msg');
      return;
    }
    final before = _detected.length;
    _applyDetection(buf.toString());
    if (mounted && _detected.length == before) {
      _toast('这次没梳理出新概念，可以换个说法再试');
    }
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
      void take(String key, bool weak, {bool extension = false}) {
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
            extension: extension,
          ));
        }
      }

      take('needed', false);
      take('weak', true);
      take('extension', false, extension: true);
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
    // 检测建议入树 = 一批新建的知识点：后台异步跑一轮查重（T14），
    // 与库里既有知识点判出重复簇时弹窗让用户选择合并。
    if (result.createdIds.isNotEmpty) {
      kpDedupSchedule(repo: widget.service.repo, jobs: widget.service.jobs);
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
    _tools.setActiveTree(_activeTree?.id);
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
            _tools.setActiveTree(v.id);
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
            // 问题3：基于当前树梳理「树外延伸」概念（需先选树）。
            IconButton(
              tooltip: '延伸讲解（树外拓展）',
              icon: const Icon(Icons.school_outlined),
              onPressed:
                  _activeTree == null || _detecting ? null : _runExtension,
            ),
            // 设置入口：记忆开关 / 查看 / 清空。
            IconButton(
              tooltip: '设置',
              icon: const Icon(Icons.settings_outlined),
              onPressed: _openAgentSettings,
            ),
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
    final needed = _detected.where((d) => !d.weak && !d.extension).toList();
    final weak = _detected.where((d) => d.weak).toList();
    final extension = _detected.where((d) => d.extension).toList();
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
          mainAxisSize: MainAxisSize.min,
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
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _detected.isEmpty ? null : _addAllDetected,
                    icon: const Icon(Icons.done_all, size: 16),
                    label: const Text('全部添加'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  if (extension.isNotEmpty) ...[
                    const _SectionLabel(text: '树外延伸（可补进树）', weak: false),
                    for (final d in extension)
                      _DetectTile(
                        item: d,
                        picked: _picked,
                        onTap: _toggle,
                        onRemove: _removeDetected,
                      ),
                  ],
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

  /// G：全部添加——勾选所有检测项；已选好目标树时直接走加入流程。
  void _addAllDetected() {
    setState(() => _picked.addAll(_detected));
    if (_activeTree != null) {
      _addToTree();
    } else {
      _toast('已全选，先在下方选择要并入的知识树');
    }
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

/// 审批清单里的一行：勾选框 + 操作摘要 + 风险标签。
class _ApprovalTile extends StatelessWidget {
  const _ApprovalTile({
    required this.plan,
    required this.checked,
    required this.onChanged,
  });
  final AgentToolPlan plan;
  final bool checked;
  final ValueChanged<bool> onChanged;

  Color _riskColor() {
    switch (plan.risk) {
      case AgentToolRisk.danger:
        return Colors.red.shade700;
      case AgentToolRisk.caution:
        return Colors.orange.shade700;
      case AgentToolRisk.normal:
        return Colors.teal;
    }
  }

  @override
  Widget build(BuildContext context) => CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: checked,
        onChanged: (v) => onChanged(v ?? false),
        title: Text(plan.summary, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: plan.riskNote != null
            ? Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 13, color: _riskColor()),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(plan.riskNote!,
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
                ],
              )
            : null,
        secondary: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: _riskColor().withOpacity(0.12),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            plan.risk == AgentToolRisk.danger
                ? '高危'
                : plan.risk == AgentToolRisk.caution
                    ? '留意'
                    : '写入',
            style: TextStyle(fontSize: 11, color: _riskColor()),
          ),
        ),
        dense: true,
      );
}

/// AI 助手设置面板：记忆开关 / 查看记忆文件内容 / 清空记忆。
class _AgentSettingsSheet extends StatefulWidget {
  const _AgentSettingsSheet({required this.memory, required this.onChanged});
  final AgentMemoryStore memory;
  final VoidCallback onChanged;

  @override
  State<_AgentSettingsSheet> createState() => _AgentSettingsSheetState();
}

class _AgentSettingsSheetState extends State<_AgentSettingsSheet> {
  Future<void> _toggle(bool v) async {
    await widget.memory.setEnabled(v);
    if (mounted) setState(() {});
    widget.onChanged();
  }

  Future<void> _viewMemory() async {
    final path = await widget.memory.filePath;
    final content = await widget.memory.rawContent();
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('记忆文件内容'),
        content: SizedBox(
          width: double.maxFinite,
          height: 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('路径：$path', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 8),
              Expanded(
                child: SelectableText(content,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _clear() async {
    final ok = await confirmDialog(context,
        title: '清空全部记忆？',
        message: '所有长期记忆将被删除，此操作不可恢复（记忆开关状态保留）。');
    if (!ok) return;
    await widget.memory.clear();
    if (mounted) setState(() {});
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.5,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.memory),
                title: const Text('长期记忆'),
                subtitle: const Text('AI 会参考你记下的偏好 / 事实；关闭后不再读写'),
                trailing: Switch(value: widget.memory.enabled, onChanged: _toggle),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: const Text('查看记忆文件内容'),
                onTap: _viewMemory,
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('清空记忆'),
                onTap: _clear,
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.all(12),
                child: const Text('记忆仅保存在本机，不上云、不进同步。',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            ],
          ),
        ),
      );
}

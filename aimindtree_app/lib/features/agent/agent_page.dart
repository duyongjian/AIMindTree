/// AI Agent 入口（问答中识别「需要的知识点 / 薄弱点」，让用户选择加入指定知识树）。
///
/// 设计要点（参照产品方法论：最小闭环、薄弱点定位是核心痛点、AI 输出可控可改、锚点铁律）：
/// 1. 自由问答：复用 T5 流式对话，不绑定单个知识点，像一个随时在线的学习搭子。
/// 2. 每轮 AI 回答后跑一次「检测」：让 AI 从对话中抽两类建议——
///    - needed：对话涉及、用户应掌握的知识点；
///    - weak：用户明显薄弱 / 混淆 / 答错的知识点。
///    检测结果是「建议」，**不入库**；只有用户勾选并「加入知识树」时才走 T1 锚定。
/// 3. 加入知识树：勾选项 → 拼成 Markdown → [ExtractionService.extract]（T1 锚点校验，
///    剔除无出处的幻觉点）→ [TreeRepository.addPoints] → 共享布局铺开新点。
///    与 canvas_page 的 _supplementIntoTree 同源逻辑，保证「无原文出处不入库」。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../ai/ai_task.dart';
import '../../ai/agent_tools.dart';
import '../../ai/auto_graph_service.dart';
import '../../ai/extraction_service.dart';
import '../../canvas/layout_autoplace.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/knowledge_tree.dart';
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

/// 一条对话消息。
class _Msg {
  const _Msg({required this.role, required this.content});
  final String role; // 'user' | 'assistant'
  final String content;
}

class AgentPage extends StatefulWidget {
  const AgentPage({super.key, required this.service, required this.db});

  final ExtractionService service;
  final AppDatabase db;

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  static final AppLog _log = AppLog('agent_page');

  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _busy = false;
  String? _error;
  String? _conversationId;

  List<_Msg> _history = const <_Msg>[];
  bool _detecting = false;

  /// 检测到的建议（去重累加，跨多轮）。
  List<AgentDetectedItem> _detected = const <AgentDetectedItem>[];
  final Set<AgentDetectedItem> _picked = <AgentDetectedItem>{};

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
    _loadTrees();
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

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ===================== 问答 =====================

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = 'AI 正在思考…';
      _history = [..._history, _Msg(role: 'user', content: text)];
    });
    _input.clear();
    _scrollToEnd();

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

  /// 收尾：落最终答案 + 跑每轮检测。
  Future<void> _finishWithAnswer(String answer) async {
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
  /// 复用 T5 流式调用，让模型只输出 JSON；解析失败则静默忽略（检测是增强能力，
  /// 不应因解析问题阻断主问答流程）。
  Future<void> _runDetection() async {
    if (_detecting || _history.isEmpty) return;
    if (!mounted) return;
    setState(() => _detecting = true);

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
    final prompt = '${treeCtx}下面是用户与 AI 助手的对话。请识别其中：\n'
        '1) needed：对话涉及、用户应当掌握的知识点；\n'
        '2) weak：用户明显薄弱 / 混淆 / 答错的知识点。\n'
        '只输出一个 JSON 对象，不要任何解释或代码块标记：\n'
        '{"needed":[{"name":"","definition":"","reason":""}],'
        '"weak":[{"name":"","definition":"","reason":""}]}\n\n'
        '对话：\n$transcript';

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

    final items = _parseDetection(buf.toString());
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

  // ===================== 加入知识树（锚定铁律） =====================

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

    // 1) 拼成 Markdown 笔记 → T1 锚定（无原文出处的不入库）。
    final md = chosen.map((i) => i.toMarkdown()).join('\n\n');

    if (!mounted) return;
    final progress = ValueNotifier<String>('正在通过 T1 锚定知识点…');
    // 阻塞等对话框被关闭；提取完成后由各分支显式 pop，不会卡住主流程。
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, msg, __) => Text('$msg\n并入「${tree.name}」'),
              ),
            ),
          ],
        ),
      ),
    );

    final ext = await widget.service.extract(md);
    if (!mounted) return;
    if (ext is Failure<ExtractionSaveResult>) {
      Navigator.of(context, rootNavigator: true).pop();
      _toast('T1 锚定失败：${ext.error}');
      return;
    }
    final res = (ext as Success<ExtractionSaveResult>).value;
    final ids = res.saved.map((k) => k.id).toList();
    if (ids.isEmpty) {
      Navigator.of(context, rootNavigator: true).pop();
      _toast('没有可锚定的知识点被收录（${res.rejectedCount} 条因缺少原文出处被剔除）。'
          '可改用「新建笔记」手动收录。');
      return;
    }

    final existing = await widget.service.trees.memberPointIds(tree.id);
    final newIds = ids.where((id) => !existing.contains(id)).toList();
    final addRes = await widget.service.trees.addPoints(tree.id, ids);
    if (!mounted) return;
    await addRes.fold(
      (added) async {
        // 新并入的点默认 x/y=0，会被布局引擎当成「放在原点」→ 用布局引擎算不重叠坐标。
        await autoPlaceNewPointsInTree(
          db: widget.db,
          trees: widget.service.trees,
          repo: widget.service.repo,
          treeId: tree.id,
          newIds: newIds,
        );

        // 新点落位后，立刻为它们补上前置关系：复用 T3「自动连线」这条**仅 AI** 的路径
        // （无本地启发式兜底）。连线失败不阻断「加入知识树」——用户可稍后手动点「自动连线」。
        // ExtractionService 暴露了 ai / repo / trees，直接就地组装 AutoGraphService。
        var linkNote = '';
        final autoGraph = AutoGraphService(
          ai: widget.service.ai,
          repo: widget.service.repo,
          trees: widget.service.trees,
        );
        final linkRes = await autoGraph.autoLink(tree.id);
        linkRes.fold(
          (r) {
            if (r.created > 0) {
              linkNote = '；已自动建立 ${r.created} 条前置关系';
            }
          },
          (e, _) {
            linkNote = '（自动连线未完成：$e，可稍后手动点「自动连线」）';
          },
        );

        if (!mounted) return;
        Navigator.of(context, rootNavigator: true).pop();
        setState(() {
          // 已加入的从候选里移除，避免重复加。
          _detected = _detected.where((d) => !_picked.contains(d)).toList();
          _picked.clear();
        });
        _toast('已加入「${tree.name}」：$added 个知识点'
            '${res.rejectedCount > 0 ? '（${res.rejectedCount} 条无出处未入库）' : ''}'
            '$linkNote');
      },
      (e, _) {
        if (!mounted) return;
        Navigator.of(context, rootNavigator: true).pop();
        _toast('并入失败：$e');
      },
    );
  }

  // ===================== 目标树选择 =====================

  Future<KnowledgeTree?> _createTreeInline() async {
    final name = await _askName('新建知识树', '给这棵树起个名字', '');
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
                                  '勾选后即可一键加入指定知识树（经 T1 锚定，无出处不入库）。'
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
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
        color: Colors.grey.shade50,
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Row(
              children: [
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
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                if (weak.isNotEmpty) ...[
                  const _SectionLabel(text: '薄弱点（应重点补）', weak: true),
                  for (final d in weak) _DetectTile(item: d, picked: _picked, onTap: _toggle),
                ],
                if (needed.isNotEmpty) ...[
                  const _SectionLabel(text: '需要的知识点', weak: false),
                  for (final d in needed) _DetectTile(item: d, picked: _picked, onTap: _toggle),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                const Icon(Icons.account_tree_outlined, size: 18, color: Colors.grey),
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

  Future<String?> _askName(String title, String hint, String initial) async {
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return name;
  }

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

/// 检测项（可勾选）。
class _DetectTile extends StatelessWidget {
  const _DetectTile({
    required this.item,
    required this.picked,
    required this.onTap,
  });
  final AgentDetectedItem item;
  final Set<AgentDetectedItem> picked;
  final ValueChanged<AgentDetectedItem> onTap;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
        contentPadding: const EdgeInsets.only(left: 8, right: 8),
        controlAffinity: ListTileControlAffinity.leading,
        value: picked.contains(item),
        onChanged: (_) => onTap(item),
        title: Row(
          children: [
            if (item.weak)
              const Icon(Icons.warning_amber_rounded, size: 14, color: Colors.orange)
            else
              const Icon(Icons.lightbulb_outline, size: 14, color: Colors.teal),
            const SizedBox(width: 6),
            Expanded(
              child: Text(item.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        subtitle: item.reason.isNotEmpty
            ? Text(item.reason,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))
            : null,
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

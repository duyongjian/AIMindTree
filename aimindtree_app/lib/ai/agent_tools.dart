/// AI 助手的「知识库工具集」（agent_page 的 T5 问答可查询 / 修改用户自己的数据）。
///
/// 设计铁律：
/// 1. **读工具只读**：list_* / get_* / find_* 全部只读，权限闸统一收口在 dispatch。
/// 2. **写工具需审批**：所有会修改数据的工具（create_*/update_*/delete_*/add_*
///    /remove_*/save_memory/delete_memory）在 agent_page 里**先生成操作清单、
///    经用户逐项勾选批准后才真正执行**；被拒的操作不会写入任何东西。
/// 3. **权限边界**：每个工具带 [AgentToolPermission]；当前只启用 owner；admin /
///    shared 为预留字段，dispatch / planWrite 一律硬闸拒绝。
/// 4. **执行全本地**：工具在 App 进程内经 Repository / Drift 直查本地 sqlite，
///    不经过 LLM Server、不外发任何内容。
/// 5. **结果有界**：列表截断、长文本截断、最终 JSON ≤4000 字符。
library;

import 'dart:convert';

import '../../data/models/knowledge_point.dart';
import '../../data/repositories/group_repository.dart';
import '../../data/repositories/knowledge_repository.dart';
import '../../data/repositories/tree_repository.dart';
import '../core/logger.dart';
import '../core/result.dart';
import 'agent_memory.dart';
import 'structured_parse.dart';

/// 工具权限级。
enum AgentToolPermission {
  /// 当前用户自己的数据（**唯一启用的权限级**）。
  owner,

  /// 预留：管理员可见数据（未启用；dispatch / planWrite 一律拒绝）。
  admin,

  /// 预留：协作共享数据（未启用；同上）。
  shared,
}

/// 一次工具调用请求（模型输出 → 解析 → dispatch / planWrite）。
class AgentToolCall {
  const AgentToolCall({required this.name, required this.args});

  final String name;
  final Map<String, dynamic> args;
}

/// 工具参数声明（进 catalogText 给模型看）。
class AgentToolParam {
  const AgentToolParam(this.name, this.type, this.description, {this.required = false});

  final String name;

  /// `string` / `integer` / `boolean` / `list`（给模型看的松散类型）。
  final String type;
  final String description;
  final bool required;
}

/// 写操作的风险等级（决定审批面板上如何高亮，提醒用户注意）。
enum AgentToolRisk {
  /// 常规写（新增 / 编辑 / 软删可逆 / 连线）——普通提示。
  normal,

  /// 需留意（软删除知识点 / 移除树关系 / 移除分组成员）——橙色提示。
  caution,

  /// 高危（彻底删除 / 删树带删点）——红色提示，操作多不可逆。
  danger,
}

/// 一次写工具「操作计划」：模型提议 → App 生成清单 → 用户审批 → 执行。
///
/// [isError] 为 true 表示规划阶段就失败（如 id 不存在），此时 [error]
/// 非空，agent_page 会把它回灌给模型自我纠正，而不是弹审批框。
class AgentToolPlan {
  const AgentToolPlan({
    required this.toolName,
    required this.summary,
    required this.args,
    this.risk = AgentToolRisk.normal,
    this.riskNote,
    this.error,
  });

  final String toolName;

  /// 给人看的一句话摘要（如「新建笔记「导数」」）。
  final String summary;

  /// 交给 execute 的规整参数（规划阶段已做存在性校验 / 类型归一）。
  final Map<String, dynamic> args;

  final AgentToolRisk risk;

  /// 风险提示（如「将永久删除 N 个知识点」）。
  final String? riskNote;

  /// 非空 = 规划失败（如 id 不存在），不进入审批流。
  final String? error;

  bool get isError => error != null;

  static AgentToolPlan errorPlan(String toolName, String message) =>
      AgentToolPlan(toolName: toolName, summary: '', args: const {}, error: message);
}

/// 一个只读工具。
class AgentTool {
  const AgentTool({
    required this.name,
    required this.description,
    required this.permission,
    required this.params,
    required this.exec,
  });

  final String name;
  final String description;

  /// 权限级（预留字段；当前全部为 [AgentToolPermission.owner]）。
  final AgentToolPermission permission;
  final List<AgentToolParam> params;

  /// 执行体：返回 **JSON 字符串**（由各工具自己 jsonEncode）。永不抛异常。
  final Future<String> Function(Map<String, dynamic> args) exec;
}

/// 一个写入工具（会修改数据）。
///
/// 与 [AgentTool] 拆分：读工具由 dispatch 直接执行；写工具先走 [plan]
/// 生成 [AgentToolPlan]，经用户审批后由 [execute] 落地。[plan] 负责存在性
/// 校验与类型归一，[execute] 信任 [AgentToolPlan.args] 但仍对失败兜底。
class AgentWriteTool {
  const AgentWriteTool({
    required this.name,
    required this.description,
    required this.permission,
    required this.params,
    required this.plan,
    required this.execute,
  });

  final String name;
  final String description;
  final AgentToolPermission permission;
  final List<AgentToolParam> params;

  /// 规划：校验参数 / 存在性，生成给人看的计划。
  final Future<AgentToolPlan> Function(Map<String, dynamic> args) plan;

  /// 执行：真正写库，返回 JSON 结果串（永不抛异常）。
  final Future<String> Function(Map<String, dynamic> args) execute;
}

/// 工具循环的最大轮数（防模型反复调用工具不回答）。
const int kAgentToolMaxRounds = 3;

/// 单次工具结果进 prompt 前的截断长度。
const int _kMaxResultChars = 4000;

/// 文本截断（agent_page 回显工具结果时也用）。
String cutText(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

/// 知识库工具集：agent_page 持有，问答时按需 dispatch（读）或 plan/execute（写）。
class AgentToolset {
  AgentToolset._(this._repo, this._trees, this._groups, this._memory);

  final KnowledgeRepository _repo;
  final TreeRepository _trees;
  final GroupRepository? _groups;
  final AgentMemoryStore? _memory;

  static final AppLog _log = AppLog('agent_tools');

  /// 工厂：从 agent_page 已持有的依赖组装（不新建连接）。
  ///
  /// [groups] / [memory] 为写工具所需；不传时相关写工具会在 plan / execute
  /// 阶段返回「未初始化」错误（不影响只读工具与既有测试）。
  factory AgentToolset.create({
    required KnowledgeRepository repo,
    required TreeRepository trees,
    GroupRepository? groups,
    AgentMemoryStore? memory,
    List<AgentTool> extraTools = const <AgentTool>[],
  }) {
    final toolset = AgentToolset._(repo, trees, groups, memory);
    toolset._tools.addAll(<AgentTool>[
      toolset._listTrees(),
      toolset._listTreePoints(),
      toolset._getPoint(),
      toolset._findPoints(),
      toolset._listNotes(),
      toolset._getNote(),
      toolset._pointRelations(),
    ]);
    toolset._writeTools.addAll(<AgentWriteTool>[
      // 笔记
      toolset._createNote(),
      toolset._updateNote(),
      toolset._deleteNote(),
      // 知识点
      toolset._createKp(),
      toolset._updateKp(),
      toolset._setMastery(),
      toolset._softDeleteKp(),
      toolset._restoreKp(),
      toolset._purgeKp(),
      // 知识树
      toolset._createTree(),
      toolset._renameTree(),
      toolset._deleteTree(),
      toolset._addPointsToTree(),
      toolset._removePointsFromTree(),
      // 分组
      toolset._createGroup(),
      toolset._renameGroup(),
      toolset._addGroupMembers(),
      toolset._removeGroupMembers(),
      toolset._deleteGroup(),
      // 连线（知识点前置关系）
      toolset._addEdge(),
      toolset._deleteEdge(),
      // 记忆
      toolset._saveMemory(),
      toolset._deleteMemory(),
    ]);
    toolset._tools.addAll(extraTools);
    return toolset;
  }

  final List<AgentTool> _tools = <AgentTool>[];
  final List<AgentWriteTool> _writeTools = <AgentWriteTool>[];

  List<AgentTool> get tools => List.unmodifiable(_tools);
  List<AgentWriteTool> get writeTools => List.unmodifiable(_writeTools);

  AgentTool? _find(String name) {
    for (final t in _tools) {
      if (t.name == name) return t;
    }
    return null;
  }

  AgentWriteTool? _findWrite(String name) {
    for (final t in _writeTools) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// 公开查找写工具（agent_page 用其把工具调用区分为「读 / 写」两路）。
  AgentWriteTool? findWrite(String name) => _findWrite(name);

  // ===================== 协议文本 =====================

  /// 工具目录（进 prompt）：一行一个工具 + 参数；写工具标 [写入]。
  String catalogText() {
    final b = StringBuffer();
    for (final t in _tools) {
      final params = t.params
          .map((p) => '${p.name}:${p.type}${p.required ? '(必填)' : ''}')
          .join(', ');
      b.writeln('- ${t.name}($params)：${t.description}');
    }
    for (final t in _writeTools) {
      final params = t.params
          .map((p) => '${p.name}:${p.type}${p.required ? '(必填)' : ''}')
          .join(', ');
      b.writeln('- ${t.name}($params)：[写入] ${t.description}');
    }
    return b.toString().trimRight();
  }

  // ===================== 调度（读） =====================

  /// 执行一次只读工具调用。永不抛异常，失败以 JSON 错误串返回。
  Future<String> dispatch(String name, Map<String, dynamic> args) async {
    final tool = _find(name);
    if (tool == null) {
      return _err('unknown_tool', '工具不存在：$name（可用：${_tools.map((t) => t.name).join('、')}）');
    }
    if (tool.permission != AgentToolPermission.owner) {
      _log.w('工具 ${tool.name} 权限级 ${tool.permission.name} 未启用，已拒绝');
      return _err('permission_not_granted', '工具 ${tool.name} 需要 ${tool.permission.name} 权限，当前未启用');
    }
    try {
      final out = await tool.exec(args);
      return out.length > _kMaxResultChars
          ? '${out.substring(0, _kMaxResultChars)}…（结果已截断）'
          : out;
    } on Object catch (e, s) {
      _log.e('工具 $name 执行失败', error: e, stackTrace: s);
      return _err('tool_failed', '$name 执行失败：$e');
    }
  }

  // ===================== 调度（写） =====================

  /// 解析一次写工具调用对应的计划；未知 / 无权限 / 规划失败返回 [AgentToolPlan.isError]。
  Future<AgentToolPlan> planWrite(String name, Map<String, dynamic> args) async {
    final tool = _findWrite(name);
    if (tool == null) {
      return AgentToolPlan.errorPlan(name, '未知写入工具：$name');
    }
    if (tool.permission != AgentToolPermission.owner) {
      return AgentToolPlan.errorPlan(name, '工具 $name 需要 ${tool.permission.name} 权限，当前未启用');
    }
    try {
      return await tool.plan(args);
    } on Object catch (e, s) {
      _log.e('写入工具 $name 规划失败', error: e, stackTrace: s);
      return AgentToolPlan.errorPlan(name, '$name 规划失败：$e');
    }
  }

  /// 执行一次写工具调用（参数应来自已审批的 [AgentToolPlan.args]）。永不抛异常。
  Future<String> executeWrite(String name, Map<String, dynamic> args) async {
    final tool = _findWrite(name);
    if (tool == null) {
      return _err('unknown_tool', '未知写入工具：$name');
    }
    try {
      final out = await tool.execute(args);
      return out.length > _kMaxResultChars
          ? '${out.substring(0, _kMaxResultChars)}…（结果已截断）'
          : out;
    } on Object catch (e, s) {
      _log.e('写入工具 $name 执行失败', error: e, stackTrace: s);
      return _err('tool_failed', '$name 执行失败：$e');
    }
  }

  /// 把模型的一轮输出解析成工具调用；不是调用（或形状不对）返回 null。
  static AgentToolCall? parseCall(String raw) {
    final parsed = StructuredText.parse(raw);
    if (parsed is! Map) return null;
    final name = parsed['tool'];
    if (name is! String || name.trim().isEmpty) return null;
    final rawArgs = parsed['args'];
    final args = rawArgs is Map
        ? Map<String, dynamic>.from(rawArgs)
        : <String, dynamic>{};
    return AgentToolCall(name: name.trim(), args: args);
  }

  // ===================== 只读工具定义 =====================

  AgentTool _listTrees() => AgentTool(
        name: 'list_knowledge_trees',
        description: '列出用户的所有知识树（id / 名称 / 知识点数量）',
        permission: AgentToolPermission.owner,
        params: const [],
        exec: (args) async {
          final trees = await _trees.listTrees();
          final out = <Map<String, dynamic>>[];
          for (final t in trees.take(50)) {
            final ids = await _trees.memberPointIds(t.id);
            out.add({'id': t.id, 'name': t.name, 'point_count': ids.length});
          }
          return jsonEncode({'trees': out, 'truncated': trees.length > 50});
        },
      );

  AgentTool _listTreePoints() => AgentTool(
        name: 'list_tree_points',
        description: '列出某棵知识树里的知识点（id / 名称 / 类型 / 掌握度 / 定义摘要）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('tree_id', 'string', '知识树 id（来自 list_knowledge_trees）', required: true),
        ],
        exec: (args) async {
          final treeId = _strArg(args, 'tree_id');
          if (treeId == null) return _err('missing_arg', '缺少 tree_id');
          final tree = await _trees.getTree(treeId);
          if (tree == null) return _err('not_found', '知识树不存在：$treeId');
          final ids = await _trees.memberPointIds(treeId);
          final pts = await _repo.pointsByIds(ids);
          final out = pts.take(200).map((p) => _pointBrief(p)).toList();
          return jsonEncode({
            'tree': {'id': tree.id, 'name': tree.name},
            'points': out,
            'truncated': pts.length > 200,
          });
        },
      );

  AgentTool _getPoint() => AgentTool(
        name: 'get_knowledge_point',
        description: '查看单个知识点的完整定义、类型、掌握度与出处笔记',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('point_id', 'string', '知识点 id', required: true),
        ],
        exec: (args) async {
          final id = _strArg(args, 'point_id');
          if (id == null) return _err('missing_arg', '缺少 point_id');
          final pts = await _repo.pointsByIds([id]);
          if (pts.isEmpty) return _err('not_found', '知识点不存在：$id');
          final p = pts.first;
          return jsonEncode({
            'id': p.id,
            'name': p.name,
            'type': p.type.label,
            'mastery': p.mastery.label,
            'definition': _cut(p.definition, 500),
            'source_note_id': p.sourceNoteId,
          });
        },
      );

  AgentTool _findPoints() => AgentTool(
        name: 'find_knowledge_points',
        description: '按关键字搜索知识点（名称 / 定义包含该词，大小写不敏感）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('keyword', 'string', '搜索关键字', required: true),
          AgentToolParam('limit', 'integer', '最多返回几条（默认 20）'),
        ],
        exec: (args) async {
          final kw = _strArg(args, 'keyword');
          if (kw == null || kw.isEmpty) return _err('missing_arg', '缺少 keyword');
          final limit = _intArg(args, 'limit', 20).clamp(1, 50);
          final all = await _repo.allKnowledgePoints();
          final lower = kw.toLowerCase();
          final hits = all
              .where((p) =>
                  p.name.toLowerCase().contains(lower) ||
                  p.definition.toLowerCase().contains(lower))
              .take(limit)
              .map((p) => _pointBrief(p))
              .toList();
          return jsonEncode({'keyword': kw, 'hits': hits, 'total_scanned': all.length});
        },
      );

  AgentTool _listNotes() => AgentTool(
        name: 'list_notes',
        description: '列出用户的笔记（id / 标题 / 更新时间 / 摘要），按更新时间倒序',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('limit', 'integer', '最多返回几条（默认 20）'),
        ],
        exec: (args) async {
          final limit = _intArg(args, 'limit', 20).clamp(1, 50);
          final notes = await _repo.listNotes();
          final out = notes
              .take(limit)
              .map((n) => {
                    'id': n.id,
                    'title': n.title.isEmpty ? '(无标题)' : n.title,
                    'updated_at': n.updatedAt.toIso8601String(),
                    'excerpt': cutText(n.contentMd, 200),
                  })
              .toList();
          return jsonEncode({'notes': out, 'total': notes.length});
        },
      );

  AgentTool _getNote() => AgentTool(
        name: 'get_note',
        description: '读取某篇笔记的正文（Markdown，超长截断）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('note_id', 'string', '笔记 id（来自 list_notes）', required: true),
        ],
        exec: (args) async {
          final id = _strArg(args, 'note_id');
          if (id == null) return _err('missing_arg', '缺少 note_id');
          final note = await _repo.getNote(id);
          if (note == null) return _err('not_found', '笔记不存在：$id');
          return jsonEncode({
            'id': note.id,
            'title': note.title,
            'content': _cut(note.contentMd, 2000),
            'truncated': note.contentMd.length > 2000,
          });
        },
      );

  AgentTool _pointRelations() => AgentTool(
        name: 'get_point_relations',
        description: '查看某个知识点的前置与后继关系（带名称）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('point_id', 'string', '知识点 id', required: true),
        ],
        exec: (args) async {
          final id = _strArg(args, 'point_id');
          if (id == null) return _err('missing_arg', '缺少 point_id');
          final preIds = await _repo.prerequisitesOf(id);
          final sucIds = await _repo.successorsOf(id);
          final names = <String, String>{};
          for (final p in await _repo.pointsByIds([...preIds, ...sucIds])) {
            names[p.id] = p.name;
          }
          return jsonEncode({
            'point_id': id,
            'prerequisites': preIds.map((i) => {'id': i, 'name': names[i] ?? '?'}).toList(),
            'successors': sucIds.map((i) => {'id': i, 'name': names[i] ?? '?'}).toList(),
          });
        },
      );

  // ===================== 写入工具定义 =====================
  //
  // 每个写工具都有 plan + execute 两体。plan 做存在性校验与类型归一，生成
  // 给人看的 [AgentToolPlan]；execute 信任 plan 产出的 args 落库，并对失败兜底。
  // 危险操作（删树 / 彻底删 / 删笔记带删点）在 plan 里标注 risk=danger，
  // 审批面板据此高亮提醒。

  AgentWriteTool _createNote() => AgentWriteTool(
        name: 'create_note',
        description: '新建一篇笔记（标题 + Markdown 正文）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('title', 'string', '笔记标题', required: true),
          AgentToolParam('content_md', 'string', 'Markdown 正文', required: true),
        ],
        plan: (args) async {
          final title = _strArg(args, 'title');
          final content = _strArg(args, 'content_md');
          if (title == null || title.isEmpty) {
            return AgentToolPlan.errorPlan('create_note', '缺少 title');
          }
          if (content == null || content.isEmpty) {
            return AgentToolPlan.errorPlan('create_note', '缺少 content_md');
          }
          return AgentToolPlan(
            toolName: 'create_note',
            summary: '新建笔记「${_cut(title, 40)}」（正文 ${content.length} 字）',
            args: {'title': title, 'content_md': content},
          );
        },
        execute: (args) async {
          final note = Note(
            title: args['title'] as String,
            contentMd: args['content_md'] as String,
            deviceId: _repo.deviceId,
          );
          final res = await _repo.saveNote(note);
          return res.fold(
            (n) => jsonEncode({'ok': true, 'note_id': n.id, 'title': n.title}),
            (e, _) => _err('save_failed', '新建笔记失败：$e'),
          );
        },
      );

  AgentWriteTool _updateNote() => AgentWriteTool(
        name: 'update_note',
        description: '编辑已有笔记的标题或正文（按 note_id）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('note_id', 'string', '笔记 id（来自 list_notes）', required: true),
          AgentToolParam('title', 'string', '新标题（留空则不改）'),
          AgentToolParam('content_md', 'string', '新正文（留空则不改）'),
        ],
        plan: (args) async {
          final id = _strArg(args, 'note_id');
          if (id == null) return AgentToolPlan.errorPlan('update_note', '缺少 note_id');
          final note = await _repo.getNote(id);
          if (note == null) return AgentToolPlan.errorPlan('update_note', '笔记不存在：$id');
          final title = _strArg(args, 'title');
          final content = _strArg(args, 'content_md');
          if (title == null && content == null) {
            return AgentToolPlan.errorPlan('update_note', '至少需要提供 title 或 content_md 之一');
          }
          return AgentToolPlan(
            toolName: 'update_note',
            summary: '编辑笔记「${note.title.isEmpty ? '(无标题)' : _cut(note.title, 40)}」（id=$id）',
            args: {'note_id': id, 'title': title, 'content_md': content},
          );
        },
        execute: (args) async {
          final note = await _repo.getNote(args['note_id'] as String);
          if (note == null) return _err('not_found', '笔记不存在');
          final updated = note.copyWith(
            title: args['title'] != null ? args['title'] as String : note.title,
            contentMd: args['content_md'] != null ? args['content_md'] as String : note.contentMd,
          );
          final res = await _repo.saveNote(updated);
          return res.fold(
            (n) => jsonEncode({'ok': true, 'note_id': n.id}),
            (e, _) => _err('save_failed', '编辑笔记失败：$e'),
          );
        },
      );

  AgentWriteTool _deleteNote() => AgentWriteTool(
        name: 'delete_note',
        description: '删除一篇笔记（软删除）；可选项决定其知识点如何处理',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('note_id', 'string', '笔记 id', required: true),
          AgentToolParam('delete_points', 'boolean', 'true=连其知识点一起彻底删除（不可恢复）；false=仅删笔记、知识点保留为独立资产', required: true),
          AgentToolParam('remove_from_trees', 'list', 'delete_points=false 时，从这些树 id 里摘出该笔记的知识点'),
        ],
        plan: (args) async {
          final id = _strArg(args, 'note_id');
          if (id == null) return AgentToolPlan.errorPlan('delete_note', '缺少 note_id');
          final note = await _repo.getNote(id);
          if (note == null) return AgentToolPlan.errorPlan('delete_note', '笔记不存在：$id');
          final deletePoints = _boolArg(args, 'delete_points', false);
          final removeTrees = _strListArg(args, 'remove_from_trees');
          final kpCount = (await _repo.pointIdsOfNote(id)).length;
          final summary = deletePoints
              ? '删除笔记「${_cut(note.title.isEmpty ? '(无标题)' : note.title, 30)}」并彻底删除其 $kpCount 个知识点（不可恢复）'
              : '删除笔记「${_cut(note.title.isEmpty ? '(无标题)' : note.title, 30)}」；其 $kpCount 个知识点${removeTrees.isEmpty ? '保留为独立资产' : '从 ${removeTrees.length} 棵树中摘出'}';
          return AgentToolPlan(
            toolName: 'delete_note',
            summary: summary,
            args: {'note_id': id, 'delete_points': deletePoints, 'remove_from_trees': removeTrees},
            risk: AgentToolRisk.danger,
            riskNote: deletePoints ? '将永久删除 $kpCount 个知识点' : '笔记本体将被软删除，可恢复',
          );
        },
        execute: (args) async {
          final res = await _repo.deleteNote(
            noteId: args['note_id'] as String,
            deletePoints: args['delete_points'] as bool? ?? false,
            removeFromTrees: Set<String>.from(args['remove_from_trees'] as List? ?? const []),
          );
          return res.fold(
            (s) => jsonEncode({
              'ok': true,
              'points_deleted': s.pointsDeleted,
              'points_detached': s.pointsDetached,
              'trees_affected': s.treesAffected,
            }),
            (e, _) => _err('delete_failed', '删除笔记失败：$e'),
          );
        },
      );

  AgentWriteTool _createKp() => AgentWriteTool(
        name: 'create_knowledge_point',
        description: '手动新建一个知识点（名称 + 类型 + 定义）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('name', 'string', '知识点名称', required: true),
          AgentToolParam('type', 'string', '类型：概念/公式/定理/方法/事实/误区（默认 概念）'),
          AgentToolParam('definition', 'string', '定义 / 说明'),
          AgentToolParam('source_note_id', 'string', '来源笔记 id（可留空）'),
        ],
        plan: (args) async {
          final name = _strArg(args, 'name');
          if (name == null || name.isEmpty) {
            return AgentToolPlan.errorPlan('create_knowledge_point', '缺少 name');
          }
          final type = KnowledgePointType.parse(_strArg(args, 'type'));
          final def = _strArg(args, 'definition') ?? '';
          final src = _strArg(args, 'source_note_id') ?? '';
          return AgentToolPlan(
            toolName: 'create_knowledge_point',
            summary: '新建知识点「$name」（类型：${type.label}）',
            args: {'name': name, 'type': type.name, 'definition': def, 'source_note_id': src},
          );
        },
        execute: (args) async {
          final res = await _repo.createManualKnowledgePoint(
            name: args['name'] as String,
            type: KnowledgePointType.parse(args['type'] as String?),
            definition: args['definition'] as String? ?? '',
            sourceNoteId: args['source_note_id'] as String? ?? '',
          );
          return res.fold(
            (kp) => jsonEncode({'ok': true, 'point_id': kp.id, 'name': kp.name}),
            (e, _) => _err('create_failed', '新建知识点失败：$e'),
          );
        },
      );

  AgentWriteTool _updateKp() => AgentWriteTool(
        name: 'update_knowledge_point',
        description: '编辑知识点的名称 / 类型 / 定义',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('point_id', 'string', '知识点 id', required: true),
          AgentToolParam('name', 'string', '新名称'),
          AgentToolParam('type', 'string', '新类型：概念/公式/定理/方法/事实/误区'),
          AgentToolParam('definition', 'string', '新定义'),
        ],
        plan: (args) async {
          final id = _strArg(args, 'point_id');
          if (id == null) return AgentToolPlan.errorPlan('update_knowledge_point', '缺少 point_id');
          final pts = await _repo.pointsByIds([id]);
          if (pts.isEmpty) return AgentToolPlan.errorPlan('update_knowledge_point', '知识点不存在：$id');
          final name = _strArg(args, 'name');
          final typeRaw = _strArg(args, 'type');
          final def = _strArg(args, 'definition');
          if (name == null && typeRaw == null && def == null) {
            return AgentToolPlan.errorPlan('update_knowledge_point', '至少需要提供 name / type / definition 之一');
          }
          return AgentToolPlan(
            toolName: 'update_knowledge_point',
            summary: '编辑知识点「${pts.first.name}」（id=$id）',
            args: {'point_id': id, 'name': name, 'type': typeRaw, 'definition': def},
          );
        },
        execute: (args) async {
          final pts = await _repo.pointsByIds([args['point_id'] as String]);
          if (pts.isEmpty) return _err('not_found', '知识点不存在');
          final kp = pts.first;
          final updated = kp.copyWith(
            name: args['name'] != null ? args['name'] as String : kp.name,
            type: args['type'] != null ? KnowledgePointType.parse(args['type'] as String) : kp.type,
            definition: args['definition'] != null ? args['definition'] as String : kp.definition,
          );
          final res = await _repo.updateKpMeta(updated);
          return res.fold(
            (k) => jsonEncode({'ok': true, 'point_id': k.id}),
            (e, _) => _err('update_failed', '编辑知识点失败：$e'),
          );
        },
      );

  AgentWriteTool _setMastery() => AgentWriteTool(
        name: 'set_mastery',
        description: '设置某知识点的掌握度（未评估/未掌握/学习中/已掌握/已放弃）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('point_id', 'string', '知识点 id', required: true),
          AgentToolParam('mastery', 'string', '掌握度：未掌握/学习中/已掌握/未评估/已放弃（或英文）', required: true),
        ],
        plan: (args) async {
          final id = _strArg(args, 'point_id');
          if (id == null) return AgentToolPlan.errorPlan('set_mastery', '缺少 point_id');
          final pts = await _repo.pointsByIds([id]);
          if (pts.isEmpty) return AgentToolPlan.errorPlan('set_mastery', '知识点不存在：$id');
          final masteryRaw = _strArg(args, 'mastery');
          if (masteryRaw == null || masteryRaw.isEmpty) {
            return AgentToolPlan.errorPlan('set_mastery', '缺少 mastery');
          }
          final status = MasteryStatus.parse(masteryRaw);
          if (status == MasteryStatus.unknown && !_isMasteryRaw(masteryRaw)) {
            return AgentToolPlan.errorPlan('set_mastery',
                'mastery 取值无效：$masteryRaw（应为 未掌握/学习中/已掌握/已放弃 之一）');
          }
          final cascade = status == MasteryStatus.notMastered;
          return AgentToolPlan(
            toolName: 'set_mastery',
            summary: '将「${pts.first.name}」掌握度设为「${status.label}」${cascade ? '（将触发后继级联降级）' : ''}',
            args: {'point_id': id, 'mastery': status.name},
            risk: cascade ? AgentToolRisk.caution : AgentToolRisk.normal,
            riskNote: cascade ? '标「未掌握」会把它的所有后继知识点自动降一档' : null,
          );
        },
        execute: (args) async {
          final status = MasteryStatus.parse(args['mastery'] as String?);
          final res = await _repo.setMastery(args['point_id'] as String, status);
          return res.fold(
            (n) => jsonEncode({'ok': true, 'changed': n}),
            (e, _) => _err('set_failed', '设置掌握度失败：$e'),
          );
        },
      );

  AgentWriteTool _softDeleteKp() => AgentWriteTool(
        name: 'soft_delete_knowledge_point',
        description: '软删除一个知识点（进入回收站，可恢复；级联清其边/掌握/树成员）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('point_id', 'string', '知识点 id', required: true),
        ],
        plan: (args) async {
          final id = _strArg(args, 'point_id');
          if (id == null) return AgentToolPlan.errorPlan('soft_delete_knowledge_point', '缺少 point_id');
          final pts = await _repo.pointsByIds([id]);
          if (pts.isEmpty) {
            return AgentToolPlan.errorPlan('soft_delete_knowledge_point', '知识点不存在：$id');
          }
          return AgentToolPlan(
            toolName: 'soft_delete_knowledge_point',
            summary: '软删除知识点「${pts.first.name}」（可恢复）',
            args: {'point_id': id},
            risk: AgentToolRisk.caution,
            riskNote: '软删除后可从回收站恢复',
          );
        },
        execute: (args) async {
          final res = await _repo.softDeleteKnowledgePoint(args['point_id'] as String);
          return res.fold(
            (n) => jsonEncode({'ok': true, 'deleted': n}),
            (e, _) => _err('delete_failed', '软删除知识点失败：$e'),
          );
        },
      );

  AgentWriteTool _restoreKp() => AgentWriteTool(
        name: 'restore_knowledge_point',
        description: '从回收站恢复一个被软删除的知识点',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('point_id', 'string', '知识点 id', required: true),
        ],
        plan: (args) async {
          final id = _strArg(args, 'point_id');
          if (id == null) return AgentToolPlan.errorPlan('restore_knowledge_point', '缺少 point_id');
          return AgentToolPlan(
            toolName: 'restore_knowledge_point',
            summary: '恢复知识点（id=$id）',
            args: {'point_id': id},
          );
        },
        execute: (args) async {
          final res = await _repo.restoreKnowledgePoint(args['point_id'] as String);
          return res.fold(
            (kp) => jsonEncode({'ok': true, 'name': kp.name}),
            (e, _) => _err('restore_failed', '恢复知识点失败：$e'),
          );
        },
      );

  AgentWriteTool _purgeKp() => AgentWriteTool(
        name: 'purge_knowledge_point',
        description: '彻底删除一个知识点（物理删除，不可恢复；须先在回收站）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('point_id', 'string', '知识点 id', required: true),
        ],
        plan: (args) async {
          final id = _strArg(args, 'point_id');
          if (id == null) return AgentToolPlan.errorPlan('purge_knowledge_point', '缺少 point_id');
          final trash = await _repo.deletedKnowledgePoints();
          final target = trash.where((p) => p.id == id).toList();
          if (target.isEmpty) {
            return AgentToolPlan.errorPlan('purge_knowledge_point', '知识点 $id 不在回收站，无法彻底删除（请先软删除）');
          }
          return AgentToolPlan(
            toolName: 'purge_knowledge_point',
            summary: '彻底删除知识点「${target.first.name}」（不可恢复！）',
            args: {'point_id': id},
            risk: AgentToolRisk.danger,
            riskNote: '物理删除，不可恢复',
          );
        },
        execute: (args) async {
          final res = await _repo.purgeKnowledgePoint(args['point_id'] as String);
          return res.fold(
            (_) => jsonEncode({'ok': true}),
            (e, _) => _err('purge_failed', '彻底删除失败：$e'),
          );
        },
      );

  AgentWriteTool _createTree() => AgentWriteTool(
        name: 'create_knowledge_tree',
        description: '新建一棵知识树',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('name', 'string', '知识树名称', required: true),
        ],
        plan: (args) async {
          final name = _strArg(args, 'name');
          if (name == null || name.isEmpty) {
            return AgentToolPlan.errorPlan('create_knowledge_tree', '缺少 name');
          }
          return AgentToolPlan(
            toolName: 'create_knowledge_tree',
            summary: '新建知识树「${_cut(name, 40)}」',
            args: {'name': name},
          );
        },
        execute: (args) async {
          final res = await _trees.createTree(args['name'] as String);
          return res.fold(
            (t) => jsonEncode({'ok': true, 'tree_id': t.id, 'name': t.name}),
            (e, _) => _err('create_failed', '新建知识树失败：$e'),
          );
        },
      );

  AgentWriteTool _renameTree() => AgentWriteTool(
        name: 'rename_knowledge_tree',
        description: '重命名一棵知识树',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('tree_id', 'string', '知识树 id', required: true),
          AgentToolParam('name', 'string', '新名称', required: true),
        ],
        plan: (args) async {
          final id = _strArg(args, 'tree_id');
          if (id == null) return AgentToolPlan.errorPlan('rename_knowledge_tree', '缺少 tree_id');
          final tree = await _trees.getTree(id);
          if (tree == null) return AgentToolPlan.errorPlan('rename_knowledge_tree', '知识树不存在：$id');
          final name = _strArg(args, 'name');
          if (name == null || name.isEmpty) {
            return AgentToolPlan.errorPlan('rename_knowledge_tree', '缺少 name');
          }
          return AgentToolPlan(
            toolName: 'rename_knowledge_tree',
            summary: '把知识树「${tree.name}」重命名为「${_cut(name, 40)}」',
            args: {'tree_id': id, 'name': name},
          );
        },
        execute: (args) async {
          final res = await _trees.renameTree(args['tree_id'] as String, args['name'] as String);
          return res.fold(
            (_) => jsonEncode({'ok': true}),
            (e, _) => _err('rename_failed', '重命名知识树失败：$e'),
          );
        },
      );

  AgentWriteTool _deleteTree() => AgentWriteTool(
        name: 'delete_knowledge_tree',
        description: '删除一棵知识树（可选连其知识点一起彻底删除）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('tree_id', 'string', '知识树 id', required: true),
          AgentToolParam('delete_points', 'boolean', 'true=连树里的知识点一起彻底删除（不可恢复）；false=仅删树、知识点保留为独立资产'),
        ],
        plan: (args) async {
          final id = _strArg(args, 'tree_id');
          if (id == null) return AgentToolPlan.errorPlan('delete_knowledge_tree', '缺少 tree_id');
          final tree = await _trees.getTree(id);
          if (tree == null) return AgentToolPlan.errorPlan('delete_knowledge_tree', '知识树不存在：$id');
          final deletePoints = _boolArg(args, 'delete_points', false);
          final memberCount = (await _trees.memberPointIds(id)).length;
          return AgentToolPlan(
            toolName: 'delete_knowledge_tree',
            summary: '删除知识树「${tree.name}」${deletePoints ? '并彻底删除其 $memberCount 个知识点（不可恢复）' : '（仅解除关系，保留 $memberCount 个知识点为独立资产）'}',
            args: {'tree_id': id, 'delete_points': deletePoints},
            risk: AgentToolRisk.danger,
            riskNote: deletePoints ? '将永久删除 $memberCount 个知识点' : '知识树将被删除',
          );
        },
        execute: (args) async {
          final res = await _trees.deleteTree(
            args['tree_id'] as String,
            deletePoints: args['delete_points'] as bool? ?? false,
          );
          return res.fold(
            (_) => jsonEncode({'ok': true}),
            (e, _) => _err('delete_failed', '删除知识树失败：$e'),
          );
        },
      );

  AgentWriteTool _addPointsToTree() => AgentWriteTool(
        name: 'add_points_to_tree',
        description: '把若干知识点并入某棵知识树（幂等）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('tree_id', 'string', '知识树 id', required: true),
          AgentToolParam('point_ids', 'list', '知识点 id 列表', required: true),
        ],
        plan: (args) async {
          final id = _strArg(args, 'tree_id');
          if (id == null) return AgentToolPlan.errorPlan('add_points_to_tree', '缺少 tree_id');
          final tree = await _trees.getTree(id);
          if (tree == null) return AgentToolPlan.errorPlan('add_points_to_tree', '知识树不存在：$id');
          final ids = _strListArg(args, 'point_ids');
          if (ids.isEmpty) return AgentToolPlan.errorPlan('add_points_to_tree', 'point_ids 不能为空');
          final pts = await _repo.pointsByIds(ids);
          if (pts.isEmpty) {
            return AgentToolPlan.errorPlan('add_points_to_tree', '给定的 point_ids 均无匹配知识点');
          }
          return AgentToolPlan(
            toolName: 'add_points_to_tree',
            summary: '把 ${pts.length} 个知识点并入「${tree.name}」',
            args: {'tree_id': id, 'point_ids': pts.map((p) => p.id).toList()},
          );
        },
        execute: (args) async {
          final ids = List<String>.from(args['point_ids'] as List);
          final res = await _trees.addPoints(args['tree_id'] as String, ids);
          return res.fold(
            (n) => jsonEncode({'ok': true, 'added': n}),
            (e, _) => _err('add_failed', '并入知识树失败：$e'),
          );
        },
      );

  AgentWriteTool _removePointsFromTree() => AgentWriteTool(
        name: 'remove_points_from_tree',
        description: '从某棵知识树移除若干知识点（仅解除关系，知识点本身保留）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('tree_id', 'string', '知识树 id', required: true),
          AgentToolParam('point_ids', 'list', '知识点 id 列表', required: true),
        ],
        plan: (args) async {
          final id = _strArg(args, 'tree_id');
          if (id == null) return AgentToolPlan.errorPlan('remove_points_from_tree', '缺少 tree_id');
          final tree = await _trees.getTree(id);
          if (tree == null) return AgentToolPlan.errorPlan('remove_points_from_tree', '知识树不存在：$id');
          final ids = _strListArg(args, 'point_ids');
          if (ids.isEmpty) return AgentToolPlan.errorPlan('remove_points_from_tree', 'point_ids 不能为空');
          return AgentToolPlan(
            toolName: 'remove_points_from_tree',
            summary: '从「${tree.name}」移除 ${ids.length} 个知识点（知识点本身保留）',
            args: {'tree_id': id, 'point_ids': ids},
            risk: AgentToolRisk.caution,
            riskNote: '仅解除树关系，不删知识点',
          );
        },
        execute: (args) async {
          final ids = List<String>.from(args['point_ids'] as List);
          final res = await _trees.removePoints(args['tree_id'] as String, ids);
          return res.fold(
            (_) => jsonEncode({'ok': true}),
            (e, _) => _err('remove_failed', '移除失败：$e'),
          );
        },
      );

  AgentWriteTool _createGroup() => AgentWriteTool(
        name: 'create_group',
        description: '新建一个知识点分组（默认全局作用域；可指定 tree_id 作为树内分组）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('name', 'string', '分组名', required: true),
          AgentToolParam('scope', 'string', '作用域：留空或 "global" = 全局分组；tree_id = 该知识树内的分组'),
          AgentToolParam('point_ids', 'list', '初始成员知识点 id 列表'),
        ],
        plan: (args) async {
          if (_groups == null) return AgentToolPlan.errorPlan('create_group', '分组服务未初始化');
          final name = _strArg(args, 'name');
          if (name == null || name.isEmpty) {
            return AgentToolPlan.errorPlan('create_group', '缺少 name');
          }
          final scope = _strArg(args, 'scope') ?? '';
          final ids = _strListArg(args, 'point_ids');
          final scopeLabel = scope.isEmpty || scope == 'global' ? '全局' : '知识树 $scope 内';
          return AgentToolPlan(
            toolName: 'create_group',
            summary: '在$scopeLabel新建分组「${_cut(name, 40)}」${ids.isNotEmpty ? '（${ids.length} 个成员）' : ''}',
            args: {'name': name, 'scope': scope, 'point_ids': ids},
          );
        },
        execute: (args) async {
          if (_groups == null) return _err('not_ready', '分组服务未初始化');
          final name = args['name'] as String;
          final scope = args['scope'] as String? ?? '';
          final ids = List<String>.from(args['point_ids'] as List? ?? const []);
          final res = scope.isEmpty || scope == 'global'
              ? await _groups.createGlobalGroup(name: name, memberIds: ids)
              : await _groups.createGroup(
                  canvasId: scope,
                  name: name,
                  orderIndex: (await _groups.listGroups(scope)).length,
                  memberIds: ids,
                );
          return res.fold(
            (g) => jsonEncode({'ok': true, 'group_id': g.id, 'name': g.name}),
            (e, _) => _err('create_failed', '新建分组失败：$e'),
          );
        },
      );

  AgentWriteTool _renameGroup() => AgentWriteTool(
        name: 'rename_group',
        description: '重命名一个分组',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('group_id', 'string', '分组 id', required: true),
          AgentToolParam('name', 'string', '新名称', required: true),
        ],
        plan: (args) async {
          if (_groups == null) return AgentToolPlan.errorPlan('rename_group', '分组服务未初始化');
          final id = _strArg(args, 'group_id');
          if (id == null) return AgentToolPlan.errorPlan('rename_group', '缺少 group_id');
          final name = _strArg(args, 'name');
          if (name == null || name.isEmpty) {
            return AgentToolPlan.errorPlan('rename_group', '缺少 name');
          }
          return AgentToolPlan(
            toolName: 'rename_group',
            summary: '重命名分组（id=$id）为「${_cut(name, 40)}」',
            args: {'group_id': id, 'name': name},
          );
        },
        execute: (args) async {
          if (_groups == null) return _err('not_ready', '分组服务未初始化');
          final res = await _groups.renameGroup(args['group_id'] as String, args['name'] as String);
          return res.fold(
            (_) => jsonEncode({'ok': true}),
            (e, _) => _err('rename_failed', '重命名分组失败：$e'),
          );
        },
      );

  AgentWriteTool _addGroupMembers() => AgentWriteTool(
        name: 'add_group_members',
        description: '向分组添加若干知识点成员',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('group_id', 'string', '分组 id', required: true),
          AgentToolParam('point_ids', 'list', '知识点 id 列表', required: true),
        ],
        plan: (args) async {
          if (_groups == null) return AgentToolPlan.errorPlan('add_group_members', '分组服务未初始化');
          final id = _strArg(args, 'group_id');
          if (id == null) return AgentToolPlan.errorPlan('add_group_members', '缺少 group_id');
          final ids = _strListArg(args, 'point_ids');
          if (ids.isEmpty) return AgentToolPlan.errorPlan('add_group_members', 'point_ids 不能为空');
          return AgentToolPlan(
            toolName: 'add_group_members',
            summary: '向分组（id=$id）添加 ${ids.length} 个成员',
            args: {'group_id': id, 'point_ids': ids},
          );
        },
        execute: (args) async {
          if (_groups == null) return _err('not_ready', '分组服务未初始化');
          final ids = List<String>.from(args['point_ids'] as List);
          final res = await _groups.addMembers(args['group_id'] as String, ids);
          return res.fold(
            (_) => jsonEncode({'ok': true}),
            (e, _) => _err('add_failed', '添加成员失败：$e'),
          );
        },
      );

  AgentWriteTool _removeGroupMembers() => AgentWriteTool(
        name: 'remove_group_members',
        description: '从分组移除若干成员（仅解除归属，知识点本身保留）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('group_id', 'string', '分组 id', required: true),
          AgentToolParam('point_ids', 'list', '知识点 id 列表', required: true),
        ],
        plan: (args) async {
          if (_groups == null) return AgentToolPlan.errorPlan('remove_group_members', '分组服务未初始化');
          final id = _strArg(args, 'group_id');
          if (id == null) return AgentToolPlan.errorPlan('remove_group_members', '缺少 group_id');
          final ids = _strListArg(args, 'point_ids');
          if (ids.isEmpty) return AgentToolPlan.errorPlan('remove_group_members', 'point_ids 不能为空');
          return AgentToolPlan(
            toolName: 'remove_group_members',
            summary: '从分组（id=$id）移除 ${ids.length} 个成员（知识点本身保留）',
            args: {'group_id': id, 'point_ids': ids},
            risk: AgentToolRisk.caution,
            riskNote: '仅解除分组归属，不删知识点',
          );
        },
        execute: (args) async {
          if (_groups == null) return _err('not_ready', '分组服务未初始化');
          final ids = List<String>.from(args['point_ids'] as List);
          final res = await _groups.removeMembers(args['group_id'] as String, ids);
          return res.fold(
            (_) => jsonEncode({'ok': true}),
            (e, _) => _err('remove_failed', '移除成员失败：$e'),
          );
        },
      );

  AgentWriteTool _deleteGroup() => AgentWriteTool(
        name: 'delete_group',
        description: '删除一个分组（成员回到未分组，不删知识点）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('group_id', 'string', '分组 id', required: true),
        ],
        plan: (args) async {
          if (_groups == null) return AgentToolPlan.errorPlan('delete_group', '分组服务未初始化');
          final id = _strArg(args, 'group_id');
          if (id == null) return AgentToolPlan.errorPlan('delete_group', '缺少 group_id');
          return AgentToolPlan(
            toolName: 'delete_group',
            summary: '删除分组（id=$id，成员回到未分组）',
            args: {'group_id': id},
            risk: AgentToolRisk.caution,
            riskNote: '删组不删知识点，成员自动回到未分组',
          );
        },
        execute: (args) async {
          if (_groups == null) return _err('not_ready', '分组服务未初始化');
          final res = await _groups.deleteGroup(args['group_id'] as String);
          return res.fold(
            (_) => jsonEncode({'ok': true}),
            (e, _) => _err('delete_failed', '删除分组失败：$e'),
          );
        },
      );

  AgentWriteTool _addEdge() => AgentWriteTool(
        name: 'add_prerequisite_edge',
        description: '在两个知识点之间连一条前置关系（from 是 to 的前置）；自动防自连/防多后继/防环',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('from_id', 'string', '前置知识点 id', required: true),
          AgentToolParam('to_id', 'string', '后继知识点 id', required: true),
          AgentToolParam('reason', 'string', '连线理由（可选）'),
        ],
        plan: (args) async {
          final from = _strArg(args, 'from_id');
          final to = _strArg(args, 'to_id');
          if (from == null || to == null) {
            return AgentToolPlan.errorPlan('add_prerequisite_edge', '缺少 from_id / to_id');
          }
          if (from == to) {
            return AgentToolPlan.errorPlan('add_prerequisite_edge', '不能把知识点连接到它自己');
          }
          final pts = await _repo.pointsByIds([from, to]);
          if (pts.length < 2) {
            return AgentToolPlan.errorPlan('add_prerequisite_edge', 'from_id / to_id 至少有一个不是有效知识点');
          }
          final names = <String, String>{for (final p in pts) p.id: p.name};
          return AgentToolPlan(
            toolName: 'add_prerequisite_edge',
            summary: '连线：${names[from]} → ${names[to]}（${names[from]} 是前置）',
            args: {'from_id': from, 'to_id': to, 'reason': _strArg(args, 'reason') ?? ''},
          );
        },
        execute: (args) async {
          final res = await _repo.addManualPrerequisiteEdge(
            args['from_id'] as String,
            args['to_id'] as String,
            reason: args['reason'] as String? ?? '',
          );
          return res.fold(
            (e) => jsonEncode({'ok': true, 'edge_id': e.id, 'from': e.fromKpId, 'to': e.toKpId}),
            (e, _) => _err('edge_failed', '连线失败：$e'),
          );
        },
      );

  AgentWriteTool _deleteEdge() => AgentWriteTool(
        name: 'delete_prerequisite_edge',
        description: '删除一条知识点前置关系（按 from_id / to_id 定位）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('from_id', 'string', '前置知识点 id', required: true),
          AgentToolParam('to_id', 'string', '后继知识点 id', required: true),
        ],
        plan: (args) async {
          final from = _strArg(args, 'from_id');
          final to = _strArg(args, 'to_id');
          if (from == null || to == null) {
            return AgentToolPlan.errorPlan('delete_prerequisite_edge', '缺少 from_id / to_id');
          }
          final edges = await _repo.prerequisiteEdgesAmong([from, to]);
          final edge = edges.where((e) => e.fromKpId == from && e.toKpId == to).toList();
          if (edge.isEmpty) {
            return AgentToolPlan.errorPlan('delete_prerequisite_edge', '未找到 $from → $to 的边');
          }
          return AgentToolPlan(
            toolName: 'delete_prerequisite_edge',
            summary: '删除连线：$from → $to',
            args: {'edge_id': edge.first.id},
          );
        },
        execute: (args) async {
          final res = await _repo.deletePrerequisiteEdge(args['edge_id'] as String);
          return res.fold(
            (_) => jsonEncode({'ok': true}),
            (e, _) => _err('delete_failed', '删除连线失败：$e'),
          );
        },
      );

  AgentWriteTool _saveMemory() => AgentWriteTool(
        name: 'save_memory',
        description: '写入一条长期记忆（key + content）；记忆开启时才会真正保存',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('key', 'string', '记忆键（同一 key 覆盖更新）', required: true),
          AgentToolParam('content', 'string', '记忆内容', required: true),
        ],
        plan: (args) async {
          if (_memory == null) return AgentToolPlan.errorPlan('save_memory', '记忆服务未初始化');
          final key = _strArg(args, 'key');
          final content = _strArg(args, 'content');
          if (key == null || key.isEmpty) {
            return AgentToolPlan.errorPlan('save_memory', '缺少 key');
          }
          if (content == null || content.isEmpty) {
            return AgentToolPlan.errorPlan('save_memory', '缺少 content');
          }
          return AgentToolPlan(
            toolName: 'save_memory',
            summary: '写入记忆「${_cut(key, 30)}」',
            args: {'key': key, 'content': content},
          );
        },
        execute: (args) async {
          if (_memory == null) return _err('not_ready', '记忆服务未初始化');
          if (!_memory.enabled) {
            return _err('memory_disabled', '记忆功能已关闭，请先在设置中开启');
          }
          await _memory.upsert(args['key'] as String, args['content'] as String);
          return jsonEncode({'ok': true});
        },
      );

  AgentWriteTool _deleteMemory() => AgentWriteTool(
        name: 'delete_memory',
        description: '删除一条长期记忆（按 key）',
        permission: AgentToolPermission.owner,
        params: const [
          AgentToolParam('key', 'string', '记忆键', required: true),
        ],
        plan: (args) async {
          if (_memory == null) return AgentToolPlan.errorPlan('delete_memory', '记忆服务未初始化');
          final key = _strArg(args, 'key');
          if (key == null || key.isEmpty) {
            return AgentToolPlan.errorPlan('delete_memory', '缺少 key');
          }
          return AgentToolPlan(
            toolName: 'delete_memory',
            summary: '删除记忆「${_cut(key, 30)}」',
            args: {'key': key},
          );
        },
        execute: (args) async {
          if (_memory == null) return _err('not_ready', '记忆服务未初始化');
          if (!_memory.enabled) {
            return _err('memory_disabled', '记忆功能已关闭');
          }
          await _memory.remove(args['key'] as String);
          return jsonEncode({'ok': true});
        },
      );

  // ===================== 小工具 =====================

  Map<String, dynamic> _pointBrief(KnowledgePoint p) => {
        'id': p.id,
        'name': p.name,
        'type': p.type.label,
        'mastery': p.mastery.label,
        'definition': _cut(p.definition, 120),
      };

  static String? _strArg(Map<String, dynamic> args, String key) {
    final v = args[key];
    if (v is! String) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  static int _intArg(Map<String, dynamic> args, String key, int fallback) {
    final v = args[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static bool _boolArg(Map<String, dynamic> args, String key, bool fallback) {
    final v = args[key];
    if (v is bool) return v;
    if (v is String) return v == 'true' || v == '1' || v == '是' || v == 'yes';
    return fallback;
  }

  static List<String> _strListArg(Map<String, dynamic> args, String key) {
    final v = args[key];
    if (v is List) {
      return <String>[
        for (final e in v)
          if (e is String && e.trim().isNotEmpty) e.trim(),
      ];
    }
    if (v is String) {
      return v
          .split(RegExp(r'[\s,;]+'))
          .where((s) => s.trim().isNotEmpty)
          .toList();
    }
    return const <String>[];
  }

  /// mastery 参数显式给出但解析回落 unknown 时，判断用户是否真的给了有效词。
  static bool _isMasteryRaw(String raw) {
    final v = raw.trim();
    return MasteryStatus.values.any((e) => e.name == v) ||
        MasteryStatus.values.any((e) => e.label == v);
  }

  static String _cut(String s, int max) => cutText(s, max);

  static String _err(String code, String message) =>
      jsonEncode({'error': code, 'message': message});
}

/// AI 助手的「知识库只读工具」（agent_page 的 T5 问答可查询用户自己的数据）。
///
/// 设计铁律：
/// 1. **只读**：全部工具都是查询，没有任何写路径——AI 助手可以「看」用户的
///    知识树 / 知识点 / 笔记 / 前置关系，但绝不能改。
/// 2. **权限边界**：每个工具带 [AgentToolPermission]。当前只有 `owner`
///    （当前用户自己的数据——本机单用户应用，天然有权）是启用态；
///    `admin` / `shared` 是**预留字段**，为将来的权限划分（多人协作 /
///    共享库）占位。授权判定统一收口在 [AgentToolset.dispatch] 一处，
///    未来接权限系统时只改那一个函数。
/// 3. **执行全本地**：工具在 App 进程内经 Repository / Drift 直查本地
///    sqlite，不经过 LLM Server、不外发任何内容。
/// 4. **结果有界**：列表截断（≤50/≤200）、长文本截断（定义 ≤120、笔记
///    ≤2000 字符）、最终 JSON ≤4000 字符——防止把整个库塞进 prompt 把
///    本地模型（qwen3:8b-8k，8192 上下文）撑爆。
library;

import 'dart:convert';

import '../../data/models/knowledge_point.dart';
import '../../data/repositories/knowledge_repository.dart';
import '../../data/repositories/tree_repository.dart';
import '../core/logger.dart';
import 'structured_parse.dart';

/// 工具权限级。
enum AgentToolPermission {
  /// 当前用户自己的数据（**唯一启用的权限级**）。
  ///
  /// 本机单用户应用：本地 sqlite 里的内容就是当前用户自己的内容，
  /// 因此 `owner` 级工具天然有权读取。
  owner,

  /// 预留：管理员可见数据（未启用；将来权限划分落地前 dispatch 一律拒绝）。
  admin,

  /// 预留：协作共享数据（未启用；同上）。
  shared,
}

/// 一次工具调用请求（模型输出 → 解析 → dispatch）。
class AgentToolCall {
  const AgentToolCall({required this.name, required this.args});

  final String name;
  final Map<String, dynamic> args;
}

/// 工具参数声明（进 catalogText 给模型看）。
class AgentToolParam {
  const AgentToolParam(this.name, this.type, this.description, {this.required = false});

  final String name;

  /// `string` / `integer`（给模型看的松散类型，不做强校验）。
  final String type;
  final String description;
  final bool required;
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

  /// 执行体：返回 **JSON 字符串**（由各工具自己 jsonEncode）。
  /// 永不抛异常——dispatch 外层还有一道兜底。
  final Future<String> Function(Map<String, dynamic> args) exec;
}

/// 工具循环的最大轮数（防模型反复调用工具不回答）。
const int kAgentToolMaxRounds = 3;

/// 单次工具结果进 prompt 前的截断长度。
const int _kMaxResultChars = 4000;

/// 文本截断（agent_page 回显工具结果时也用）。
String cutText(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

/// 知识库工具集：agent_page 持有，问答时按需 dispatch。
class AgentToolset {
  AgentToolset._(this._tools, this._repo, this._trees);

  final List<AgentTool> _tools;
  final KnowledgeRepository _repo;
  final TreeRepository _trees;

  static final AppLog _log = AppLog('agent_tools');

  /// 工厂：从 agent_page 已持有的依赖组装（不新建连接）。
  ///
  /// [extraTools] 仅供测试 / 未来扩展追加工具（如验证权限闸）。
  factory AgentToolset.create({
    required KnowledgeRepository repo,
    required TreeRepository trees,
    List<AgentTool> extraTools = const <AgentTool>[],
  }) {
    final toolset = AgentToolset._(<AgentTool>[], repo, trees);
    toolset._tools.addAll([
      toolset._listTrees(),
      toolset._listTreePoints(),
      toolset._getPoint(),
      toolset._findPoints(),
      toolset._listNotes(),
      toolset._getNote(),
      toolset._pointRelations(),
    ]);
    toolset._tools.addAll(extraTools);
    return toolset;
  }

  List<AgentTool> get tools => List.unmodifiable(_tools);

  AgentTool? _find(String name) {
    for (final t in _tools) {
      if (t.name == name) return t;
    }
    return null;
  }

  // ===================== 协议文本 =====================

  /// 工具目录（进 prompt）：一行一个工具 + 参数。
  String catalogText() {
    final b = StringBuffer();
    for (final t in _tools) {
      final params = t.params
          .map((p) => '${p.name}:${p.type}${p.required ? '(必填)' : ''}')
          .join(', ');
      b.writeln('- ${t.name}($params)：${t.description}');
    }
    return b.toString().trimRight();
  }

  // ===================== 调度 =====================

  /// 执行一次工具调用。**永不抛异常**，任何失败都以 JSON 错误串返回
  /// （喂回给模型自我纠正，比中断整轮问答好）。
  ///
  /// 权限判定收口在这里：[AgentToolPermission] 非 `owner` 一律拒绝
  /// （预留权限启用前的硬闸）。
  Future<String> dispatch(String name, Map<String, dynamic> args) async {
    final tool = _find(name);
    if (tool == null) {
      return _err('unknown_tool', '工具不存在：$name（可用：${_tools.map((t) => t.name).join('、')}）');
    }
    if (tool.permission != AgentToolPermission.owner) {
      // 预留权限的硬闸：未启用前一律拒绝，绝不静默放行。
      _log.w('工具 ${tool.name} 权限级 ${tool.permission.name} 未启用，已拒绝');
      return _err('permission_not_granted',
          '工具 ${tool.name} 需要 ${tool.permission.name} 权限，当前未启用');
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

  /// 把模型的一轮输出解析成工具调用；不是调用（或形状不对）返回 null。
  ///
  /// 判定：整体能解出 JSON **对象**且含非空 `tool` 字符串键。
  /// 工具名未知也返回调用（由 dispatch 回错误让模型自我纠正）。
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

  // ===================== 工具定义 =====================

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

  static String _cut(String s, int max) => cutText(s, max);

  static String _err(String code, String message) =>
      jsonEncode({'error': code, 'message': message});
}

/// 自动知识图谱服务（用户诉求的「AI 能力」两轮之一）。
///
/// 三个能力（**只跑工作流，不做本地兜底**）：
/// 1. **自动连线**（T3 前置知识推断）：在知识树里自动推断「谁是谁的前置」并落库为
///    `PrerequisiteEdge`（`origin='ai'`，用户可在画布上删）。
/// 2. **按分组连线**（T3 + 分组）：把每个点所属的组名 / 组序 / 基础度作为附加字段
///    一并喂给 T3，让 AI 在「先掌握什么、后掌握什么」的前提下推断；客户端只保留
///    「低组 → 高组」的跨组正向边，落实「第一组 → 第二组 → …」的连线逻辑。
/// 3. **自动补前置（T4 深度补前置）**：针对**单个选中知识点**，按所选深度递归补出
///    「要理解它需要先懂什么」的前置链，以**建议**形态返回（不入库——没有可锚定的
///    原文就不编造，遵守 PRD 锚点硬规则）。
///
/// 失败策略（用户明确要求）：**只跑工作流**。Dify 不可用 / 超时 / 未配置 / 解析失败
/// 一律返回 [Failure]，绝不再回退本地启发式、不静默产出边，避免用户误以为「AI 连好了」。
library;

import 'dart:convert';

import 'ai_provider.dart';
import 'ai_service.dart';
import 'ai_task.dart';
import 'prereq_depth.dart';
import '../core/logger.dart';
import '../core/result.dart';
import '../data/models/knowledge_point.dart';
import '../data/models/kp_group.dart';
import '../data/models/suggested_prerequisite.dart';
import '../data/repositories/knowledge_repository.dart';
import '../data/repositories/tree_repository.dart';

/// AI 调用入口的可注入封装（测试时可替换为「必失败」实现以强制走本地兜底）。
typedef AiRun = Future<Result<AiTaskResult>> Function(
  AiTask task,
  Map<String, dynamic> inputs, {
  Duration timeout,
});

/// 自动连线结果。
class AutoLinkResult {
  const AutoLinkResult({
    required this.created,
    required this.total,
    required this.edges,
    required this.usedFallback,
    this.note = '',
  });

  /// 实际新建的边数量（去重 + 防环后）。
  final int created;

  /// AI / 兜底给出的候选边数量（去重前）。
  final int total;

  /// 候选边列表（含已存在/被环排除前的全部）。
  final List<PrerequisiteEdge> edges;

  /// true 表示最终用的是本地启发式（AI 不可用或解析失败）。
  final bool usedFallback;

  final String note;
}

/// 自动补前置结果。
class AutoPrereqResult {
  const AutoPrereqResult({
    required this.suggestions,
    required this.usedFallback,
  });

  /// 建议补的前置知识点（不入库），按 `level` 标记在链中的层级。
  final List<SuggestedPrerequisite> suggestions;

  final bool usedFallback;
}

/// T4 递归补前置的实时进度（UI 用来显示「第几层 / 本层完成几个」）。
class AutoPrereqProgress {
  const AutoPrereqProgress({
    required this.level,
    required this.totalLevels,
    required this.levelTotal,
    required this.levelDone,
  });

  /// 当前递归层（从 1 开始）。
  final int level;

  /// 总层数上限（由 [PrereqDepth] 决定）。
  final int totalLevels;

  /// 本层要请求的节点数（frontier 大小）。
  final int levelTotal;

  /// 本层已完成请求的节点数。
  final int levelDone;

  String get label =>
      '正在请求前置（第 $level/$totalLevels 层，本层已完成 $levelDone/$levelTotal）…';
}

/// 递归 frontier 中的单个待展开项（某层要喂给 T4 的前置候选）。
class _FrontierItem {
  const _FrontierItem({
    required this.name,
    required this.type,
    required this.definition,
  });

  final String name;
  final String type;
  final String definition;
}

class AutoGraphService {
  AutoGraphService({
    required this.ai,
    required this.repo,
    required this.trees,
    this.aiRun,
  });

  final AiService ai;
  final KnowledgeRepository repo;
  final TreeRepository trees;

  /// 覆盖默认 AI 调用（默认走 [ai.run]）。测试用。
  final AiRun? aiRun;

  static final AppLog _log = AppLog('auto_graph');

  AiRun get _run => aiRun ?? ai.run;

  // ============ 自动连线（T3） ============

  Future<Result<AutoLinkResult>> autoLink(String treeId) async {
    try {
      final kpIds = await trees.memberPointIds(treeId);
      final points = await repo.pointsByIds(kpIds);
      if (points.length < 2) {
        return Success(AutoLinkResult(
          created: 0,
          total: 0,
          edges: const <PrerequisiteEdge>[],
          usedFallback: false,
          note: '知识点不足 2 个，无法自动连线',
        ));
      }

      // T3 工作流的 `points` 输入字段是 string 类型（部署态），必须把知识点列表
      // 序列化成 JSON 字符串再发；直接发 List/Map 会被 Dify 输入表单以
      // "must be a string" 拒绝（400）。模型在 prompt 里能直接解析这段 JSON 文本。
      final inputs = <String, dynamic>{
        'points': jsonEncode([
          for (final p in points)
            {
              'id': p.id,
              'name': p.name,
              'type': p.type.name,
              'definition': p.definition,
            }
        ]),
      };

      final aiRes = await _run(AiTask.t3Prerequisite, inputs);
      if (aiRes is! Success<AiTaskResult> || aiRes.value.parsed is! Map) {
        // 工作流不可用 / 解析失败 → 直接报错，不静默走本地启发式（用户要求只跑工作流）。
        final why = switch (aiRes) {
          Success<AiTaskResult>(value: final v) =>
            'T3 输出解析失败（parsed 非 Map）：'
            '${v.content.length > 200 ? "${v.content.substring(0, 200)}…" : v.content}',
          Failure<AiTaskResult>(error: final e) => 'T3 调用失败：$e',
        };
        _log.w('T3 工作流失败，未启用本地兜底：$why');
        return Failure(StateError(why));
      }
      // 只接受工作流结果；AI 没给出边就返回空（不再本地启发式兜底）。
      final edges = _parsePrereqEdges(aiRes.value.parsed, points);
      final usedFallback = false;

      final created = await _mergeAndPersist(points, edges);
      return Success(AutoLinkResult(
        created: created,
        total: edges.length,
        edges: edges,
        usedFallback: usedFallback,
      ));
    } on Object catch (e, s) {
      _log.e('自动连线失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 按分组连线（用户诉求：先按逻辑分层，再按组序连线）。
  ///
  /// 把每个知识点所属的组名 / 组序 / 有效基础度作为**附加字段**塞进 T3 的
  /// `points`（points 已是 JSON 字符串），让 AI 在知道分组的前提下推断点→点前置；
  /// 再在客户端只保留「低组 → 高组」的跨组正向边（同组内 / 反向边一律丢弃），
  /// 从而落实「第一组 → 第二组 → 第三组」的连线逻辑。仅对**已分组**的点连线。
  ///
  /// 仍遵守「只跑工作流」：AI 不可用 / 解析失败即 [Failure]，不做本地兜底。
  Future<Result<AutoLinkResult>> autoLinkByGroups(
    String treeId,
    List<KpGroup> groups,
  ) async {
    try {
      final kpIds = await trees.memberPointIds(treeId);
      final allPoints = await repo.pointsByIds(kpIds);

      // kpId → (组序, 有效基础度, 组名)
      final orderOf = <String, int>{};
      final levelOf = <String, int>{};
      final groupNameOf = <String, String>{};
      for (final g in groups) {
        for (final m in g.members) {
          orderOf[m.kpId] = g.orderIndex;
          levelOf[m.kpId] = g.levelOf(m.kpId);
          groupNameOf[m.kpId] = g.name;
        }
      }
      // 只对「已分组」的知识点连线。
      final points =
          allPoints.where((p) => orderOf.containsKey(p.id)).toList();
      if (points.length < 2) {
        return Success(AutoLinkResult(
          created: 0,
          total: 0,
          edges: const <PrerequisiteEdge>[],
          usedFallback: false,
          note: '已分组的知识点不足 2 个，无法按组连线',
        ));
      }

      final inputs = <String, dynamic>{
        'points': jsonEncode([
          for (final p in points)
            {
              'id': p.id,
              'name': p.name,
              'type': p.type.name,
              'definition': p.definition,
              'group': groupNameOf[p.id] ?? '',
              'group_order': orderOf[p.id] ?? 0,
              'foundation_level': levelOf[p.id] ?? 0,
            }
        ]),
      };

      final aiRes = await _run(AiTask.t3Prerequisite, inputs);
      if (aiRes is! Success<AiTaskResult> || aiRes.value.parsed is! Map) {
        final why = switch (aiRes) {
          Success<AiTaskResult>(value: final v) =>
            'T3 输出解析失败（parsed 非 Map）：'
            '${v.content.length > 200 ? "${v.content.substring(0, 200)}…" : v.content}',
          Failure<AiTaskResult>(error: final e) => 'T3 调用失败：$e',
        };
        _log.w('T3（按组）工作流失败，未启用本地兜底：$why');
        return Failure(StateError(why));
      }

      // 只保留「低组 → 高组」的跨组正向边（组序严格递增）。
      final raw = _parsePrereqEdges(aiRes.value.parsed, points);
      final edges = <PrerequisiteEdge>[
        for (final e in raw)
          if ((orderOf[e.fromKpId] ?? 0) < (orderOf[e.toKpId] ?? 0)) e,
      ];

      final created = await _mergeAndPersist(points, edges);
      return Success(AutoLinkResult(
        created: created,
        total: edges.length,
        edges: edges,
        usedFallback: false,
      ));
    } on Object catch (e, s) {
      _log.e('按组连线失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 与已存在边合并去重 + 防环后落库，返回真正新建的边数。
  Future<int> _mergeAndPersist(
    List<KnowledgePoint> points,
    List<PrerequisiteEdge> edges,
  ) async {
    final existing =
        await repo.prerequisiteEdgesAmong(points.map((p) => p.id).toList());
    final adj = <String, Set<String>>{};
    final haveKeys = <String>{};
    for (final e in existing) {
      adj.putIfAbsent(e.fromKpId, () => <String>{}).add(e.toKpId);
      haveKeys.add('${e.fromKpId}->${e.toKpId}');
    }

    var created = 0;
    // 约束（用户诉求 2026-10-10）：每个知识点最多一个后继。同一 from 只保留第一条
    // 候选边（其余丢弃），让客户端行为确定、不依赖 AI 返回顺序的偶然。
    final capped = <String, PrerequisiteEdge>{};
    for (final e in edges) {
      if (e.fromKpId == e.toKpId) continue;
      if (capped.containsKey(e.fromKpId)) continue;
      capped[e.fromKpId] = e;
    }
    final cappedEdges = capped.values.toList();

    final dedup = <String>{};
    for (final e in cappedEdges) {
      final key = '${e.fromKpId}->${e.toKpId}';
      if (dedup.contains(key)) continue;
      dedup.add(key);
      // 已存在 → 跳过（不重复创建，也不计入 created）。
      if (haveKeys.contains(key)) continue;
      // 防环：加上 e 后不能让 to 能回到 from（即不能形成环）。
      if (_hasPath(adj, e.toKpId, e.fromKpId)) continue;
      final res = await repo.addManualPrerequisiteEdge(
        e.fromKpId,
        e.toKpId,
        reason: e.reason,
        origin: e.origin,
        confidence: e.confidence,
      );
      if (res is Success<PrerequisiteEdge>) {
        created++;
        adj.putIfAbsent(e.fromKpId, () => <String>{}).add(e.toKpId);
      }
    }
    return created;
  }

  // ============ 自动补前置（T4，递归深度补前置） ============

  /// 针对**单个选中知识点** [target]，按深度 [depth] 递归补出前置链（仅建议，不入库）。
  ///
  /// 递归由客户端驱动（Dify 单次只产一层）：对 frontier 中每个点调用一次 T4 工作流，
  /// 解析出的 gap 用 `maxBreadth` 截断、去重后作为下一层 frontier，直至 `maxLevels`
  /// 层或全部耗尽。任一层调用失败 → 直接返回 [Failure]（不再本地兜底，用户要求只跑工作流）。
  ///
  /// **锚点硬规则**：全程绝不 `new KnowledgePoint` / 写库。
  Future<Result<AutoPrereqResult>> autoPrerequisites(
    KnowledgePoint target,
    PrereqDepth depth, {
    String? customInstruction,
    void Function(AutoPrereqProgress)? onProgress,
  }) async {
    try {
      var maxLevels = depth.maxLevels;
      var maxBreadth = depth.maxBreadth;
      if (depth == PrereqDepth.custom) {
        final parsed = _parseCustomInstruction(customInstruction);
        maxLevels = parsed.maxLevels;
        maxBreadth = parsed.breadth;
      }

      final seenNames = <String>{target.name.toLowerCase()};
      var frontier = <_FrontierItem>[
        _FrontierItem(
          name: target.name,
          type: target.type.label,
          definition: target.definition,
        ),
      ];

      final suggestions = <SuggestedPrerequisite>[];
      var usedFallback = false;

      for (var level = 1; level <= maxLevels; level++) {
        if (frontier.isEmpty) break;
        final nextFrontier = <_FrontierItem>[];
        // 进入新的一层：先回调一次「本层还没开始请求」。
        onProgress?.call(AutoPrereqProgress(
          level: level,
          totalLevels: maxLevels,
          levelTotal: frontier.length,
          levelDone: 0,
        ));
        var done = 0;
        for (final item in frontier) {
          final inputs = <String, dynamic>{
            'target': '${item.name} | ${item.type} | ${item.definition}',
            'depth': depth.code,
            // 线上部署的 T4 工作流把 depth_instruction 设为必填（与本地 DSL 的
            // required:false 失同步），任何档位都必须带这个字段，否则 Dify 返回 400。
            // 非自定义档位用学段文案补足，custom 档位透传用户输入。
            'depth_instruction': _depthInstructionFor(depth, customInstruction),
          };
          final aiRes = await _run(AiTask.t4GapAnalysis, inputs);
          done++;
          // 本层每完成一个节点请求就回调一次，UI 据此刷新「第 X/Y 层，本层已完成 a/b」。
          onProgress?.call(AutoPrereqProgress(
            level: level,
            totalLevels: maxLevels,
            levelTotal: frontier.length,
            levelDone: done,
          ));
          if (aiRes is! Success<AiTaskResult> || aiRes.value.parsed is! Map) {
            // 任一层失败 → 直接报错，不静默走本地启发式（用户要求只跑工作流）。
            final why = switch (aiRes) {
              Success<AiTaskResult>(value: final v) =>
                'T4 输出解析失败（parsed 非 Map）：'
                'content=${v.content.length > 200 ? "${v.content.substring(0, 200)}…" : v.content}',
              Failure<AiTaskResult>(error: final e) => 'T4 调用失败：$e',
            };
            _log.w('T4 工作流失败，未启用本地兜底：$why');
            return Failure(StateError(why));
          }
          final gaps = _parseGaps(aiRes.value.parsed).take(maxBreadth);
          for (final g in gaps) {
            final lower = g.name.toLowerCase();
            if (seenNames.contains(lower)) continue; // 去重 / 锚点硬规则
            seenNames.add(lower);
            suggestions.add(SuggestedPrerequisite(
              name: g.name,
              type: g.type,
              definition: g.definition,
              reason: g.reason,
              level: level,
            ));
            nextFrontier.add(_FrontierItem(
              name: g.name,
              type: g.type,
              definition: g.definition,
            ));
          }
        }
        frontier = nextFrontier;
      }

      return Success(AutoPrereqResult(
        suggestions: suggestions,
        usedFallback: usedFallback,
      ));
    } on Object catch (e, s) {
      _log.e('自动补前置失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  // ============ AI 输出解析 ============

  List<PrerequisiteEdge> _parsePrereqEdges(
    Object? parsed,
    List<KnowledgePoint> points,
  ) {
    if (parsed is! Map) return const <PrerequisiteEdge>[];
    final list = parsed['prerequisites'];
    if (list is! List) return const <PrerequisiteEdge>[];

    String? resolve(dynamic v) {
      if (v == null) return null;
      final s = v.toString().trim();
      if (s.isEmpty) return null;
      for (final p in points) {
        if (p.id == s) return p.id;
      }
      final lower = s.toLowerCase();
      for (final p in points) {
        if (p.name.toLowerCase() == lower) return p.id;
      }
      for (final p in points) {
        if (p.name.toLowerCase().contains(lower)) return p.id;
      }
      return null;
    }

    final out = <PrerequisiteEdge>[];
    for (final e in list) {
      if (e is! Map) continue;
      final from = resolve(e['from']);
      final to = resolve(e['to']);
      if (from == null || to == null || from == to) continue;
      out.add(PrerequisiteEdge(
        fromKpId: from,
        toKpId: to,
        reason: (e['reason'] as String? ?? '').toString(),
        origin: 'ai',
        confidence: ((e['confidence'] as num?) ?? 0.8).toDouble(),
      ));
    }
    return out;
  }

  List<SuggestedPrerequisite> _parseGaps(Object? parsed) {
    if (parsed is! Map) return const <SuggestedPrerequisite>[];
    final list = parsed['gaps'];
    if (list is! List) return const <SuggestedPrerequisite>[];
    return [
      for (final e in list)
        if (e is Map)
          SuggestedPrerequisite(
            name: (e['name'] as String? ?? '').toString(),
            type: (e['type'] as String? ?? '').toString(),
            definition: (e['definition'] as String? ?? '').toString(),
            reason: (e['reason'] as String? ?? '').toString(),
            // Dify 工作流内部 level 恒为 1（相对直接前置）；绝对层级由递归循环累加。
            level: ((e['level'] as num?) ?? 1).toInt(),
          )
    ].where((s) => s.name.isNotEmpty).toList();
  }

  // ============ T4 输入构造 ============

  /// 构造 T4 工作流的 `depth_instruction`。
  ///
  /// 线上部署的 T4 工作流把该字段设为**必填**（与本地 DSL 的 `required:false`
  /// 失同步），所以低/中/高档位也要带一段与 [depth] 一致的学段文案，
  /// 避免 Dify 返回 400；自定义档位直接透传用户自由文本。
  static String _depthInstructionFor(PrereqDepth depth, String? custom) {
    return switch (depth) {
      PrereqDepth.low =>
        '${depth.schoolStage}：只列最近一层直接相关前置。',
      PrereqDepth.medium => '${depth.schoolStage}：列出中等基础的前置。',
      PrereqDepth.high => '${depth.schoolStage}：尽量补到最基础的概念。',
      PrereqDepth.custom =>
        (custom?.trim().isNotEmpty ?? false)
            ? custom!
            : '根据目标知识点的性质，自行判断合适的讲解深度与学段。',
    };
  }

  // ============ 自定义指令解析 ============

  /// 把自由文本 [text] 粗映射为递归层数 / 广度上限。
  ///
  /// 关键词映射：大学/本科 → medium(maxLevels=2)；高中/初中 → medium；
  /// 小学/常识/基础 → high(maxLevels=3)；一层/直接前置/最近一层 → maxLevels=1；
  /// 无法识别 → 回落 high。
  ({int maxLevels, int breadth}) _parseCustomInstruction(String? text) {
    final t = (text ?? '').toLowerCase();
    if (t.contains('大学') || t.contains('本科')) {
      return (maxLevels: 2, breadth: 4);
    }
    if (t.contains('高中') || t.contains('初中')) {
      return (maxLevels: 2, breadth: 4);
    }
    if (t.contains('小学') || t.contains('常识') || t.contains('基础')) {
      return (maxLevels: 3, breadth: 5);
    }
    if (t.contains('一层') ||
        t.contains('直接前置') ||
        t.contains('最近一层') ||
        t.contains('只要一层')) {
      return (maxLevels: 1, breadth: 3);
    }
    // 无法识别 → 回落 high。
    return (maxLevels: 3, breadth: 5);
  }

  // ============ 工具 ============

  /// 在邻接表 [adj] 中判断是否存在 u → … → v 的路径。
  bool _hasPath(Map<String, Set<String>> adj, String u, String v) {
    if (u == v) return true;
    final visited = <String>{};
    final stack = [u];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      if (n == v) return true;
      if (!visited.add(n)) continue;
      for (final nx in adj[n] ?? const <String>[]) {
        stack.add(nx);
      }
    }
    return false;
  }

}

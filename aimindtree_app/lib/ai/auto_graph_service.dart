/// 自动知识图谱服务（用户诉求的「AI 能力」两轮之一）。
///
/// 两个能力（**DSL 优先 + 本地兜底**）：
/// 1. **自动连线**（T3 前置知识推断）：在知识树里自动推断「谁是谁的前置」并落库为
///    `PrerequisiteEdge`（`origin='ai'`，用户可在画布上删）。
/// 2. **自动补前置（T4 深度补前置）**：针对**单个选中知识点**，按所选深度递归补出
///    「要理解它需要先懂什么」的前置链，以**建议**形态返回（不入库——没有可锚定的
///    原文就不编造，遵守 PRD 锚点硬规则）。
///
/// 降级策略：先尝试 Dify 工作流（DSL JSON），任一层调用失败 / 超时 / 未配置 → 自动回退
/// 到本地启发式。本地启发式保证**离线也能用**，是兜底也是缺 Dify 部署时的主力。
library;

import 'ai_provider.dart';
import 'ai_service.dart';
import 'ai_task.dart';
import 'prereq_depth.dart';
import '../core/logger.dart';
import '../core/result.dart';
import '../data/models/knowledge_point.dart';
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
          usedFallback: true,
          note: '知识点不足 2 个，无法自动连线',
        ));
      }

      final inputs = <String, dynamic>{
        'points': [
          for (final p in points)
            {
              'id': p.id,
              'name': p.name,
              'type': p.type.name,
              'definition': p.definition,
            }
        ],
      };

      List<PrerequisiteEdge> edges;
      var usedFallback = false;

      final aiRes = await _run(AiTask.t3Prerequisite, inputs);
      if (aiRes is Success<AiTaskResult> && aiRes.value.parsed is Map) {
        edges = _parsePrereqEdges(aiRes.value.parsed, points);
        // AI 没给出有效边 → 退回本地兜底，保证有结果。
        if (edges.isEmpty) {
          edges = _localInferEdges(points);
          usedFallback = true;
        }
      } else {
        _log.w('T3 AI 调用不可用，启用本地启发式兜底');
        edges = _localInferEdges(points);
        usedFallback = true;
      }

      // 与已存在边合并去重 + 防环，再落库。
      final existing = await repo.prerequisiteEdgesAmong(
        points.map((p) => p.id).toList(),
      );
      final adj = <String, Set<String>>{};
      final haveKeys = <String>{};
      for (final e in existing) {
        adj.putIfAbsent(e.fromKpId, () => <String>{}).add(e.toKpId);
        haveKeys.add('${e.fromKpId}->${e.toKpId}');
      }

      var created = 0;
      final dedup = <String>{};
      for (final e in edges) {
        if (e.fromKpId == e.toKpId) continue;
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

  // ============ 自动补前置（T4，递归深度补前置） ============

  /// 针对**单个选中知识点** [target]，按深度 [depth] 递归补出前置链（仅建议，不入库）。
  ///
  /// 递归由客户端驱动（Dify 单次只产一层）：对 frontier 中每个点调用一次 T4 工作流，
  /// 解析出的 gap 用 `maxBreadth` 截断、去重后作为下一层 frontier，直至 `maxLevels`
  /// 层或全部耗尽。任一层调用失败 → 立即转本地兜底 [ _localSuggestDepth ] 并停止递归。
  ///
  /// **锚点硬规则**：全程绝不 `new KnowledgePoint` / 写库。
  Future<Result<AutoPrereqResult>> autoPrerequisites(
    KnowledgePoint target,
    PrereqDepth depth, {
    String? customInstruction,
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
        for (final item in frontier) {
          final inputs = <String, dynamic>{
            'target': '${item.name} | ${item.type} | ${item.definition}',
            'depth': depth.code,
            if (depth == PrereqDepth.custom && customInstruction != null)
              'depth_instruction': customInstruction,
          };
          final aiRes = await _run(AiTask.t4GapAnalysis, inputs);
          if (aiRes is! Success<AiTaskResult> || aiRes.value.parsed is! Map) {
            // 任一层失败 → 立即转本地兜底，停止递归（绝不调用 T1 工作流）。
            usedFallback = true;
            suggestions.addAll(_localSuggestDepth(target, depth, customInstruction));
            return Success(AutoPrereqResult(
              suggestions: suggestions,
              usedFallback: usedFallback,
            ));
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

  // ============ 本地兜底启发式 ============

  /// 由名称/定义包含关系推断前置边：更「宽泛」的点指向更「具体」的点。
  ///
  /// 仅当单向包含成立时连线，避免双向歧义噪声；最后用 DAG 环检测剔除会成环的边。
  List<PrerequisiteEdge> _localInferEdges(List<KnowledgePoint> points) {
    final candidates = <(String, String)>[];
    for (final a in points) {
      for (final b in points) {
        if (a.id == b.id) continue;
        final aSub = _isSubsumed(a, b); // a 是 b 的「父类」
        final bSub = _isSubsumed(b, a);
        if (aSub && !bSub) {
          candidates.add((a.id, b.id));
        } else if (bSub && !aSub) {
          candidates.add((b.id, a.id));
        }
        // 双向都成立或都不成立：信息不足，跳过
      }
    }

    final seen = <String>{};
    final uniq = <(String, String)>[];
    for (final c in candidates) {
      final k = '${c.$1}->${c.$2}';
      if (seen.add(k)) uniq.add(c);
    }

    final adj = <String, Set<String>>{};
    final result = <PrerequisiteEdge>[];
    for (final (from, to) in uniq) {
      if (from == to) continue;
      if (_hasPath(adj, to, from)) continue; // 加这条会形成环
      adj.putIfAbsent(from, () => <String>{}).add(to);
      result.add(PrerequisiteEdge(
        fromKpId: from,
        toKpId: to,
        reason: '本地启发式：基于名称/定义包含关系推断',
        origin: 'ai_fallback',
        confidence: 0.5,
      ));
    }
    return result;
  }

  /// 单目标的深度本地兜底（离线 / Dify 不可用）：基于名称+定义分词，按深度产出层级。
  ///
  /// 复用 `_tokens` / `_segmentCjk` 对 `target.name + target.definition` 分词，剔除
  /// `_stopwords` 与目标自身名称；按 [depth] 控制层级：low/medium 仅 level=1，
  /// high/custom 多产一层 level=2 的弱伪递归。结果均标注 `usedFallback`。
  ///
  /// 明确这是**弱启发式**：本地无模型，无法真正理解语义，仅基于字面共现 / 词频近似。
  List<SuggestedPrerequisite> _localSuggestDepth(
    KnowledgePoint target,
    PrereqDepth depth,
    String? custom,
  ) {
    final targetName = target.name.toLowerCase();
    final text = '${target.name} ${target.definition}';
    final counts = <String, int>{};
    for (final tok in _tokens(text)) {
      final tl = tok.toLowerCase();
      if (tl.length < 2) continue;
      if (_stopwords.contains(tl)) continue;
      if (tl == targetName) continue;
      counts[tl] = (counts[tl] ?? 0) + 1;
    }
    final ranked = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final names = ranked.map((e) => e.key).toList();

    final out = <SuggestedPrerequisite>[];
    final taken = <String>{};

    void addTier(int level, Iterable<String> tierNames) {
      for (final n in tierNames) {
        final nl = n.toLowerCase();
        if (taken.contains(nl)) continue;
        taken.add(nl);
        out.add(SuggestedPrerequisite(
          name: n,
          reason: '本地启发式（离线兜底，弱近似）：从「${target.name}」的名称/定义中'
              '切出的候选前置概念，建议以 AI 结果为准自行确认。',
          level: level,
        ));
      }
    }

    final l1Count = switch (depth) {
      PrereqDepth.low => 3,
      PrereqDepth.medium => 4,
      PrereqDepth.high => 5,
      PrereqDepth.custom => _parseCustomInstruction(custom).breadth,
    };
    final l1 = names.take(l1Count).toList();
    addTier(1, l1);
    // high / custom（映射后层数≥2）做一层伪递归：把剩余候选作为更底层（level=2）。
    final produceLevel2 = depth == PrereqDepth.high ||
        (depth == PrereqDepth.custom &&
            _parseCustomInstruction(custom).maxLevels >= 2);
    if (produceLevel2) {
      final l2 = names.skip(l1Count).take(l1Count).toList();
      addTier(2, l2);
    }
    return out;
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

  bool _isSubsumed(KnowledgePoint general, KnowledgePoint specific) {
    final g = general.name.trim().toLowerCase();
    if (g.isEmpty) return false;
    if (specific.name.toLowerCase().contains(g)) return true;
    if (specific.definition.toLowerCase().contains(g)) return true;
    return false;
  }

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

  static final _latin = RegExp(r'[A-Za-z][A-Za-z0-9]{1,}'); // 拉丁词（≥2 字符）

  /// 中文里用于切词边界的功能词（启发式分词的低成本替代，非严谨分词）。
  /// 命中这些字就当作词与词之间的空格。
  static const _boundary = <String>{
    '的', '了', '和', '与', '及', '或', '并', '且', '也', '才', '又', '再', '就',
    '都', '却', '但', '是', '在', '着', '把', '被', '让', '使', '给', '对', '从',
    '到', '由', '用', '推', '出', '求', '得', '为', '作', '成', '种', '个', '些',
    '上', '下', '中', '内', '后', '前', '时', '当', '若', '则', '而', '等', '于',
    '其', '它', '他', '她', '这', '那', '该', '各', '能', '可', '会', '要', '需',
    '通过', '进行', '表示', '用来', '例如', '比如',
  };

  static bool _isCjk(String ch) {
    final code = ch.codeUnitAt(0);
    return code >= 0x4e00 && code <= 0x9fff;
  }

  /// 把一段中文按边界功能词切成候选概念（≥2 字），英文按单词。
  List<String> _segmentCjk(String s) {
    final out = <String>[];
    final buf = StringBuffer();
    void flush() {
      if (buf.length >= 2) out.add(buf.toString());
      buf.clear();
    }

    for (final ch in s.runes.map((r) => String.fromCharCode(r))) {
      if (!_isCjk(ch)) {
        flush();
      } else if (_boundary.contains(ch)) {
        flush();
      } else {
        buf.write(ch);
      }
    }
    flush();
    return out;
  }

  /// 把一段文本切成候选概念 token：中文按功能词切分、英文按单词。
  List<String> _tokens(String s) {
    final out = <String>[];
    out.addAll(_segmentCjk(s));
    out.addAll(_latin.allMatches(s).map((m) => m.group(0)!));
    return out;
  }

  static final _stopwords = {
    '的',
    '了',
    '和',
    '与',
    '及',
    '是',
    '在',
    '一种',
    '我们',
    '这个',
    '那个',
    '例如',
    '比如',
    '可以',
    '用来',
    '表示',
    '公式',
    '定理',
    '概念',
    '方法',
    '事实',
    '定义',
    '一个',
    '这些',
    '那些',
    '因为',
    '所以',
    '如果',
    '那么',
    '需要',
    '通过',
    '进行',
    '不同',
    '相同',
    '之间',
    '关于',
    '根据',
    '由于',
    '成为',
    '使得',
    '从而',
    '以及',
    '如何',
    '其中',
    '这种',
    '主要',
    '通常',
    '一般',
    '用于',
    '能够',
    '两个',
    '多个',
  };
}

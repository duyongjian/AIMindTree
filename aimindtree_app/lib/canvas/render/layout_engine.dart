/// 画布层级布局引擎（ARCHITECTURE T05）。
///
/// **约束**：纯函数、零 Flutter 依赖，便于单测；不存任何状态。
/// 输入：知识点 + 前置关系边，输出：每个 KP 的 (x, y) 屏幕坐标。
///
/// 策略：拓扑分层 DAG 布局——
/// - level(kp) = max(level(prereq) + 1)，无前置的 KP 为 0；
/// - 同层按名称稳定排序后均分 x；y 按层号 × 行高；
///   同层超过 [LayoutConfig.maxPerRow] 个就换行，避免无关联的 KP 横排成超宽一行。
/// - 边由 [Edge.id] 给出，调用方在 CustomPaint 里画。
library;

import 'package:aimindtree_app/data/models/knowledge_point.dart';

/// 布局后的节点位置。
class LaidOutNode {
  const LaidOutNode({
    required this.kpId,
    required this.x,
    required this.y,
    required this.level,
  });

  final String kpId;
  final double x;
  final double y;
  final int level;
}

/// 边（prereq → dependent）。
class LaidOutEdge {
  const LaidOutEdge(this.fromId, this.toId);
  final String fromId;
  final String toId;
}

/// 布局结果。
class LayoutResult {
  const LayoutResult({required this.nodes, required this.edges});

  final List<LaidOutNode> nodes;
  final List<LaidOutEdge> edges;

  double get maxX => nodes.isEmpty
      ? 0
      : nodes.map((n) => n.x).reduce((a, b) => a > b ? a : b);
  double get maxY => nodes.isEmpty
      ? 0
      : nodes.map((n) => n.y).reduce((a, b) => a > b ? a : b);
  int get levelCount => nodes.isEmpty
      ? 0
      : nodes.map((n) => n.level).reduce((a, b) => a > b ? a : b);
}

/// 布局参数。
class LayoutConfig {
  const LayoutConfig({
    this.nodeWidth = 220,
    // 卡片 = 14px 拖拽手柄 + 内容（标题行 + 类型行 + 2 行 definition + 掌握状态）。
    // 实测约 124px；90px 会 BOTTOM OVERFLOWED BY 24 PIXELS。
    this.nodeHeight = 136,
    this.hGap = 40,
    this.vGap = 40,
    // 同一层（同一个 level）一行最多放几个节点，超过就换行。
    // 无前置关系的 KP 全在 level 0，不换行的话 5 个就是 1300+ px 宽的一横条。
    this.maxPerRow = 3,
  });

  final double nodeWidth;
  final double nodeHeight;
  final double hGap;
  final double vGap;
  final int maxPerRow;

  /// 每行实际能放多少个（防御外部传 0 / 负数）。
  int get effectiveMaxPerRow => maxPerRow < 1 ? 1 : maxPerRow;
}

/// 拓扑分层布局。
///
/// [points] 要展示的 KP 集合；[edges] 前置关系边（from→to 表示 to 依赖 from）。
/// 边若指向 [points] 外的节点会被忽略（展示子图）。
LayoutResult layoutForest(
  List<KnowledgePoint> points,
  List<PrerequisiteEdge> edges, {
  LayoutConfig config = const LayoutConfig(),
}) {
  if (points.isEmpty) return const LayoutResult(nodes: [], edges: []);

  final ids = points.map((p) => p.id).toSet();
  final nameOf = {for (final p in points) p.id: p.name};

  // 邻接表（to 的前置们）
  final prereqsOf = <String, List<String>>{for (final p in points) p.id: []};
  final dependentsOf = <String, List<String>>{for (final p in points) p.id: []};
  for (final e in edges) {
    if (ids.contains(e.fromKpId) && ids.contains(e.toKpId)) {
      prereqsOf[e.toKpId]!.add(e.fromKpId);
      dependentsOf[e.fromKpId]!.add(e.toKpId);
    }
  }

  // 拓扑分层（带环保护：入度变 0 仍残留的置 0）
  final inDegree = {for (final p in points) p.id: prereqsOf[p.id]!.length};
  final level = <String, int>{};
  var frontier = <String>[
    for (final p in points)
      if (inDegree[p.id] == 0) p.id
  ];
  for (final id in frontier) {
    level[id] = 0;
  }
  // 广度式「relaxed level」: 每个点的 level = max(prereq.level) + 1; 用 BFS 推进
  final visited = frontier.toSet();
  while (frontier.isNotEmpty) {
    final next = <String>[];
    for (final id in frontier) {
      for (final dep in dependentsOf[id]!) {
        final newLevel = level[id]! + 1;
        final old = level[dep];
        if (old == null || newLevel > old) {
          level[dep] = newLevel;
        }
        inDegree[dep] = (inDegree[dep]! - 1).clamp(0, 1 << 30);
        if (!visited.contains(dep) && prereqsOf[dep]!.every((p) => level.containsKey(p))) {
          visited.add(dep);
          next.add(dep);
        }
      }
    }
    frontier = next;
  }
  // 处理环或孤立点（relaxed 后无 level 的）：全置 0
  for (final p in points) {
    level.putIfAbsent(p.id, () => 0);
  }

  // 同层按 KP 名称稳定排序后均分 x
  final byLevel = <int, List<String>>{};
  for (final id in ids) {
    byLevel.putIfAbsent(level[id]!, () => []).add(id);
  }
  for (final l in byLevel.values) {
    l.sort((a, b) => nameOf[a]!.compareTo(nameOf[b]!));
  }

  // 逐层（层号升序，保证 y 单调）放置；同层内按行优先排，每行最多
  // effectiveMaxPerRow 个。rowCursor 记录当前层起始的行号 —— 必须把上一层
  // 占掉的行数累加进来，否则下一层会压在换行的那一行上。
  final levels = byLevel.keys.toList()..sort();
  final perRow = config.effectiveMaxPerRow;
  final rowHeight = config.nodeHeight + config.vGap;
  final colWidth = config.nodeWidth + config.hGap;

  final laid = <LaidOutNode>[];
  var rowCursor = 0;
  for (final lv in levels) {
    final idsAtLevel = byLevel[lv]!;
    for (var i = 0; i < idsAtLevel.length; i++) {
      laid.add(LaidOutNode(
        kpId: idsAtLevel[i],
        x: (i % perRow) * colWidth,
        y: (rowCursor + i ~/ perRow) * rowHeight,
        level: lv,
      ));
    }
    rowCursor += (idsAtLevel.length + perRow - 1) ~/ perRow;
  }

  // 边（只保留展示子图内的）
  final drawn = <LaidOutEdge>[];
  for (final e in edges) {
    if (ids.contains(e.fromKpId) && ids.contains(e.toKpId)) {
      drawn.add(LaidOutEdge(e.fromKpId, e.toKpId));
    }
  }

  return LayoutResult(nodes: laid, edges: drawn);
}

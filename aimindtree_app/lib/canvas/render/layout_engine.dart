/// 画布层级布局引擎（ARCHITECTURE T05）。
///
/// **约束**：纯函数、零 Flutter 依赖，便于单测；不存任何状态。
/// 输入：知识点 + 前置关系边，输出：每个 KP 的 (x, y) 屏幕坐标。
///
/// 策略：拓扑分层 DAG 布局——
/// - level(kp) = max(level(prereq) + 1)，无前置的 KP 为 0；
/// - **每一层各占一行**（y = 层号 × 行高），层内节点横向铺开、**不设每行上限**；
/// - 层内顺序按「知识领域相近度」聚类：先按来源笔记分域，同域内按知识点类型归拢，
///   最后按名称稳定排序（见 [_sortWithinLevel]）。
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
    // 画布网格（场景单位）。拖动吸附 + 布局对齐共用此值；网格关闭（≤0）时拖动与布局均为自由（不吸附）。
    // 传 0 / 负数 = 关闭网格吸附。当前默认 20（开启吸附，松手仍对齐），可见线条由 [showGrid] 单独控制。
    this.gridSize = 20,
    // 是否绘制可见网格底纹。吸附（[gridSize]）与此**独立**：可隐藏线条但仍保留松手对齐。
    // 默认 false（不画线，空白画布外观）；true = 显示格子线。
    this.showGrid = false,
  });

  final double nodeWidth;
  final double nodeHeight;
  final double hGap;
  final double vGap;
  final double gridSize;
  /// 是否绘制可见网格底纹（与吸附无关，仅控制线条是否画出）。
  final bool showGrid;
}

/// 把 [value] 吸附到最近的网格交点；[grid] ≤ 0 时原样返回（关闭网格）。
///
/// 纯标量函数，只依赖 dart:core，便于单测；Offset 侧的吸附在调用处组合。
double snapToGrid(double value, double grid) {
  if (grid <= 0) return value;
  return (value / grid).roundToDouble() * grid;
}

/// 场景坐标系里的一个轴对齐矩形块（左上角 + 宽高）。
///
/// 供「新并入的点落位时避让已有节点」使用：坐标系与 [layoutForest] 一致
/// （内容左上角为原点，单位 = 场景像素）。纯几何值对象，零 Flutter 依赖。
class LayoutBox {
  const LayoutBox(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  /// 与 [o] 是否有**面积**重叠（仅边缘相接不算重叠）。
  bool overlaps(LayoutBox o) =>
      left < o.right && o.left < right && top < o.bottom && o.top < bottom;
}

/// 为一个 `[blockWidth] × [blockHeight]` 的块找一个**不与 [occupied] 任一矩形相交**
/// 的左上角坐标。
///
/// 策略（确定性、纯函数、零 Flutter 依赖）：
/// 1. 优先返回 `([preferredLeft], [preferredTop])`——若不与任何占用矩形相交；
/// 2. 否则把整块挪到「占用集合的下方且与占用集左缘对齐」：
///    `left = min(occupied.left)`，`top = max(occupied.bottom) + step`。
///    该位置的 y 严格大于所有占用矩形的下边，故保证不相交（与占用集合的绝对位置无关）；
/// 3. [occupied] 为空时直接返回 preferred。
///
/// 返回 `(left: ..., top: ...)` 记录（只依赖 [LayoutBox]，便于单测）。
({double left, double top}) findFreeBlockTopLeft({
  required double blockWidth,
  required double blockHeight,
  required List<LayoutBox> occupied,
  required double preferredLeft,
  required double preferredTop,
  double step = 20,
}) {
  if (occupied.isEmpty) {
    return (left: preferredLeft, top: preferredTop);
  }
  final candidate =
      LayoutBox(preferredLeft, preferredTop, blockWidth, blockHeight);
  if (!occupied.any(candidate.overlaps)) {
    return (left: preferredLeft, top: preferredTop);
  }
  // 整块下移：放到所有占用矩形下方，且左缘与占用集合的最左缘对齐。
  var minLeft = occupied.first.left;
  var maxBottom = occupied.first.bottom;
  for (final o in occupied) {
    if (o.left < minLeft) minLeft = o.left;
    if (o.bottom > maxBottom) maxBottom = o.bottom;
  }
  return (left: minLeft, top: maxBottom + step);
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

  // 同层分组排序：先按「知识领域相近度」聚类，组内再按名称（见 _sortWithinLevel）。
  final byLevel = <int, List<String>>{};
  for (final id in ids) {
    byLevel.putIfAbsent(level[id]!, () => []).add(id);
  }
  final domainOf = {for (final p in points) p.id: p.sourceNoteId};
  final typeOf = {for (final p in points) p.id: p.type};
  for (final l in byLevel.values) {
    _sortWithinLevel(l, nameOf, domainOf, typeOf);
  }

  // 逐层（层号升序，保证 y 单调）放置：**每层各占一行**，同层节点按分组顺序横向
  // 铺开，不再按每行上限换行（用户要求：很多「行」其实是同一层，无需限 3 个/行）。
  final levels = byLevel.keys.toList()..sort();
  // 行/列间距先对齐到网格再使用：否则 176 的原始行高在 20 的网格上会「有的行偏 4px、
  // 有的行偏 16px」，越往下越不齐（用户看到的「格子对不上」）。对齐后每行都精确
  // 落在格线上，且仍是常数间距。
  final rowHeight = snapToGrid(config.nodeHeight + config.vGap, config.gridSize);
  final colWidth = snapToGrid(config.nodeWidth + config.hGap, config.gridSize);
  final grid = config.gridSize;

  final laid = <LaidOutNode>[];
  var rowIndex = 0;
  for (final lv in levels) {
    final idsAtLevel = byLevel[lv]!;
    for (var i = 0; i < idsAtLevel.length; i++) {
      laid.add(LaidOutNode(
        kpId: idsAtLevel[i],
        x: snapToGrid(i * colWidth, grid),
        y: snapToGrid(rowIndex * rowHeight, grid),
        level: lv,
      ));
    }
    rowIndex += 1;
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

/// 同一层（同一个 level）内节点的**分组排序**（纯函数，便于单测）。
///
/// 「知识领域相近度」的近似：**来源笔记**（[KnowledgePoint.sourceNoteId]）相同的点
/// 视为同一领域 —— 同一篇笔记里抽出的知识点，主题天然相近。排序三级：
///   1. **领域分组**：同一 `sourceNoteId` 的排在一起；组与组之间按「组内名字最小者」
///      排序，使最左的一组以字典序最小的名字起头，顺序稳定、可预期；
///   2. **类型归拢**：组内按知识点类型（[KnowledgePointType]）聚拢，同类型相邻；
///   3. **名称排序**：同类型内按名称稳定排序。
///
/// 说明：模型目前无「领域/主题」字段，故以来源笔记近似；日后若新增领域字段，
/// 只需把调用处传入的 `domainOf` 换成该字段的映射即可，其余逻辑不变。
void _sortWithinLevel(
  List<String> levelIds,
  Map<String, String> nameOf,
  Map<String, String> domainOf,
  Map<String, KnowledgePointType> typeOf,
) {
  // 每个领域用其成员中「名字最小」者作为该领域的排序标签。
  final labelOf = <String, String>{};
  for (final id in levelIds) {
    final d = domainOf[id]!;
    final nm = nameOf[id]!;
    final prev = labelOf[d];
    if (prev == null || nm.compareTo(prev) < 0) labelOf[d] = nm;
  }
  final domains = labelOf.keys.toList()
    ..sort((a, b) => labelOf[a]!.compareTo(labelOf[b]!));
  final rank = {for (var i = 0; i < domains.length; i++) domains[i]: i};

  levelIds.sort((a, b) {
    final ra = rank[domainOf[a]!]!;
    final rb = rank[domainOf[b]!]!;
    if (ra != rb) return ra.compareTo(rb);
    final ta = typeOf[a]!.index;
    final tb = typeOf[b]!.index;
    if (ta != tb) return ta.compareTo(tb);
    return nameOf[a]!.compareTo(nameOf[b]!);
  });
}

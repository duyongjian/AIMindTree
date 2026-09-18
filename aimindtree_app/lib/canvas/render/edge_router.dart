/// 知识树画布的连线正交路由（ARCHITECTURE T05 画布连线的避障布线）。
///
/// **约束**：纯函数、零 Flutter widget 依赖 —— 只 import `dart:ui` 拿
/// [Offset] / [Rect] / [Size] 三个几何类型，任何 Dart/Flutter 测试都能直接跑。
///
/// ## 要解决的两个问题
///
/// 原来的连线是写死的「源底边中点 → 拐点 → 目标顶边中点」三段折线：
///
/// 1. **水平段贴着目标卡片的上边缘**：拐点的 y 就是 `to.dy`（目标顶边），
///    整条横线正好沿卡片边沿走，看着像画在了卡片上。
/// 2. **跨层连线竖直穿过中间节点**：布局是分层的，A→C 且 B→C 且 B 在中间层时，
///    A（第 0 行）→C（第 2 行）的竖直段要跨过第 1 行，直接从 B 卡片身上穿过去。
///    因为 CustomPaint 是 Stack 的第一个 child，线被卡片盖住，视觉上就是
///    「线穿过节点后断成几截」。
///
/// ## 策略
///
/// 为每条边生成一组**候选正交路径**，按「绕行代价」从低到高排序，取**第一条
/// 不与任何障碍物矩形相交的**；若全部相交，退化为**相交次数最少**（再按总长度
/// 最短）的那条 —— 绝不抛异常，也绝不出现「线画不出来」。
///
/// 复杂度：候选数固定（≤ 15），每条边 O(候选数 × 障碍数 × 段数)；画布规模
/// 几十个节点时每次布局几万次浮点比较，可以忽略。命中第一条无碰撞候选即返回，
/// 常见情况只算 1 条候选。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// 连线与障碍物之间要求的最小净空（逻辑像素）。
///
/// 线的 strokeWidth 是 1.4，留 2px 是为了让「贴着卡片边沿走」也被判定为相交
/// 从而淘汰掉 —— 用户明确反馈过这种贴边很难看。
const double kEdgeClearance = 2.0;

/// 绕行间距的上下限：`gap` 传入异常值（0 / 负数 / 巨大值）时兜底。
const double _minPad = 6.0;
const double _maxPad = 40.0;

/// 浮点点位比较阈值（逻辑像素），用于去掉重复点 / 共线点。
const double _eps = 0.5;

/// 一条边的路由结果。
class EdgeRoute {
  const EdgeRoute({
    required this.points,
    required this.obstacleHits,
  });

  /// 折线顶点（至少 2 个）。第 0 个是出线点，最后一个是箭头/圆点落点。
  final List<Offset> points;

  /// 相交的障碍物段数；0 表示这条路径完全避开了所有障碍物。
  final int obstacleHits;

  /// 是否完全无碰撞。
  bool get isClear => obstacleHits == 0;

  /// 出线点（源卡片边界上）。
  Offset get start => points.first;

  /// 终点（目标卡片边界上），箭头圆点画在这里。
  Offset get end => points.last;

  /// 折线的长度中点，删除按钮定位用。
  Offset get midpoint => polylineMidpoint(points);
}

/// 计算一条前置关系连线的正交折线。
///
/// - [from] / [to]：源 / 目标卡片**左上角**坐标（与布局引擎输出的 x/y 一致）。
/// - [nodeSize]：卡片尺寸（[LayoutConfig.nodeWidth] × [LayoutConfig.nodeHeight]）。
/// - [obstacles]：**除这条边的两个端点外**所有节点的矩形。端点自身的矩形必须
///   由调用方排除，否则起终点永远落在自己的矩形上、判定恒为相交。
/// - [gap]：行间距（[LayoutConfig.vGap]）—— 水平横带走两行之间空白带的中点。
/// - [clearance]：额外净空，见 [kEdgeClearance]。
///
/// 方向语义保持「前置在上、后继在下」：目标在下方时从源**底边**出、目标**顶边**
/// 进；目标被拖到上方时反过来从源**顶边**出、目标**底边**进。
List<Offset> routeEdge({
  required Offset from,
  required Offset to,
  required Size nodeSize,
  required List<Rect> obstacles,
  required double gap,
  double clearance = kEdgeClearance,
}) =>
    routeEdgeDetailed(
      from: from,
      to: to,
      nodeSize: nodeSize,
      obstacles: obstacles,
      gap: gap,
      clearance: clearance,
    ).points;

/// [routeEdge] 的完整版本，额外返回碰撞次数（调试 / 单测用）。
EdgeRoute routeEdgeDetailed({
  required Offset from,
  required Offset to,
  required Size nodeSize,
  required List<Rect> obstacles,
  required double gap,
  double clearance = kEdgeClearance,
}) {
  final w = nodeSize.width;
  final h = nodeSize.height;
  // 退化输入（宽高为 0 / NaN）兜底：直接连两个左上角，绝不抛异常。
  if (!(w > 0) || !(h > 0)) {
    return EdgeRoute(
      points: <Offset>[Offset(from.dx, from.dy), Offset(to.dx, to.dy)],
      obstacleHits: 0,
    );
  }

  final src = Rect.fromLTWH(from.dx, from.dy, w, h);
  final dst = Rect.fromLTWH(to.dx, to.dy, w, h);

  // 横带走两行之间空白带的中点，所以留一半行距就够了（gap=40 → 20px 净空）。
  final pad = _clamp(gap / 2, _minPad, _maxPad);
  final bounds = _boundsOf(src, dst, obstacles);
  final leftX = bounds.left - pad;
  final rightX = bounds.right + pad;
  final topY = bounds.top - pad;
  final botY = bounds.bottom + pad;

  final sx = src.center.dx;
  final ex = dst.center.dx;

  final candidates = <List<Offset>>[];

  // ── 候选组 0：两张卡片竖直方向有重叠（被用户拖成并排）→ 侧面直连 ──
  // 这种情况走「上出下进」会先向下再向上绕一大圈，反而更难看。
  if (src.top < dst.bottom && dst.top < src.bottom) {
    final cy =
        (math.max(src.top, dst.top) + math.min(src.bottom, dst.bottom)) / 2;
    final toRight = dst.center.dx >= src.center.dx;
    candidates.add(<Offset>[
      Offset(toRight ? src.right : src.left, cy),
      Offset(toRight ? dst.left : dst.right, cy),
    ]);
  }

  // 方向：目标整体不低于源 → 下出上进；否则上出下进。
  final downward = dst.top >= src.top;
  final double outY = downward ? src.bottom : src.top;
  final double inY = downward ? dst.top : dst.bottom;
  // 横带允许区间（开区间）：必须严格落在「离开源的 y」和「进入目标的 y」之间。
  final double lo = math.min(outY, inY);
  final double hi = math.max(outY, inY);

  // 三条横带：紧贴源 / 紧贴目标 / 正中。
  final bNear = _clampBand(downward ? outY + pad : outY - pad, lo, hi);
  final bFar = _clampBand(downward ? inY - pad : inY + pad, lo, hi);
  final bMid = _clampBand((outY + inY) / 2, lo, hi);

  // ── 候选组 1：单条横带走过去（3 段），代价最低 ──
  for (final b in _uniqueBands(<double>[bNear, bFar, bMid])) {
    candidates.add(_dedupe(<Offset>[
      Offset(sx, outY),
      Offset(sx, b),
      Offset(ex, b),
      Offset(ex, inY),
    ]));
  }

  // ── 候选组 2：从图的左侧 / 右侧绕行（5 段）──
  // 这是跨层连线的主力：A(第 0 行) → C(第 2 行) 且 B 在第 1 行同一列时，
  // 竖直段必然撞 B，只有绕到图外侧才干净。
  for (final vx in _sideOrder(leftX, rightX, sx)) {
    for (final pair in <(double, double)>[
      (bNear, bFar),
      (bNear, bMid),
      (bMid, bFar),
    ]) {
      candidates.add(_dedupe(<Offset>[
        Offset(sx, outY),
        Offset(sx, pair.$1),
        Offset(vx, pair.$1),
        Offset(vx, pair.$2),
        Offset(ex, pair.$2),
        Offset(ex, inY),
      ]));
    }
  }

  // ── 候选组 3：整张图上方 / 下方的大绕行（5 段，兜底）──
  // 用户把节点拖得七零八落时，前两组都可能撞，这两条沿 bbox 外侧走。
  for (final vx in _sideOrder(leftX, rightX, sx)) {
    // 绕上方：从源顶边出，翻到整图上方
    candidates.add(_dedupe(<Offset>[
      Offset(sx, src.top),
      Offset(sx, topY),
      Offset(vx, topY),
      Offset(vx, bFar),
      Offset(ex, bFar),
      Offset(ex, inY),
    ]));
    // 绕下方：从源底边出，沉到整图下方
    candidates.add(_dedupe(<Offset>[
      Offset(sx, src.bottom),
      Offset(sx, botY),
      Offset(vx, botY),
      Offset(vx, bFar),
      Offset(ex, bFar),
      Offset(ex, inY),
    ]));
  }

  // ── 择优：第一条无碰撞的；全都不行就取碰撞最少、其次总长最短的 ──
  List<Offset>? best;
  var bestHits = 1 << 30;
  var bestLen = double.infinity;
  for (final c in candidates) {
    if (c.length < 2) continue;
    final hits = countObstacleHits(c, obstacles, inflate: clearance);
    if (hits == 0) return EdgeRoute(points: c, obstacleHits: 0);
    final len = polylineLength(c);
    if (hits < bestHits || (hits == bestHits && len < bestLen)) {
      best = c;
      bestHits = hits;
      bestLen = len;
    }
  }
  if (best != null) {
    return EdgeRoute(points: best, obstacleHits: bestHits);
  }
  // 理论上到不了这里（候选组 1 恒非空），保底连一条直线。
  return EdgeRoute(
    points: <Offset>[Offset(sx, outY), Offset(ex, inY)],
    obstacleHits: 0,
  );
}

/// 统计折线 [points] 与 [obstacles] 相交的段数（一段与多个矩形相交算多次）。
///
/// ⚠️ 使用陷阱：[inflate] > 0 时**必须**把这条边两端的卡片从 [obstacles] 里
/// 排除，否则结果恒 ≥ 2 —— 头尾两段各扎进自己卡片 inflate 出来的那一圈里。
/// 这是 [segmentIntersectsRect]「端点落边界不算相交、但贴着边界走算相交」
/// 约定的直接推论。[routeEdge] 内部已经做了这个排除；外部拿本函数做复核 /
/// 写断言时要带**同样的排除逻辑**，否则会把干净的路由误报成碰撞。
int countObstacleHits(
  List<Offset> points,
  List<Rect> obstacles, {
  double inflate = 0.0,
}) {
  if (points.length < 2 || obstacles.isEmpty) return 0;
  final rects = inflate == 0.0
      ? obstacles
      : <Rect>[for (final r in obstacles) r.inflate(inflate)];
  final bounds = _polylineBounds(points);
  var hits = 0;
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    for (final r in rects) {
      // 先用整条折线的包围盒粗筛，避免每段都遍历全部障碍物。
      //
      // ⚠️ 这里不能写 `r.overlaps(bounds)`：Rect.overlaps 是**严格面积相交**
      // （`bottom <= other.top` 就判 false）。折线退化成一条水平线（包围盒
      // 高度为 0）且 y 正好等于矩形上边缘时，粗筛会直接把矩形漏掉，而
      // segmentIntersectsRect 认为它相交 —— 两个函数的判定就不一致了。
      // 改成「非严格分离」：只要没有完全错开就送进精确判定，宁可多算不可漏算。
      if (r.right < bounds.left ||
          bounds.right < r.left ||
          r.bottom < bounds.top ||
          bounds.bottom < r.top) {
        continue;
      }
      if (segmentIntersectsRect(a, b, r)) hits++;
    }
  }
  return hits;
}

/// 线段 a–b 是否与矩形 [r] 相交（Liang–Barsky 参数化裁剪）。
///
/// 约定：**端点恰好落在矩形边界上不算相交**（进入目标卡片的那一段一定会以
/// 边界点为终点，否则永远判定为碰撞）；而**整段贴着边界走算相交** —— 这正是
/// 要修的「水平段贴着目标上边缘」问题。
bool segmentIntersectsRect(Offset a, Offset b, Rect r) {
  var t0 = 0.0;
  var t1 = 1.0;
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;

  // x 方向 slab
  if (dx == 0.0) {
    if (a.dx < r.left || a.dx > r.right) return false;
  } else {
    var ta = (r.left - a.dx) / dx;
    var tb = (r.right - a.dx) / dx;
    if (ta > tb) {
      final t = ta;
      ta = tb;
      tb = t;
    }
    if (ta > t0) t0 = ta;
    if (tb < t1) t1 = tb;
    if (t0 > t1) return false;
  }

  // y 方向 slab
  if (dy == 0.0) {
    if (a.dy < r.top || a.dy > r.bottom) return false;
  } else {
    var ta = (r.top - a.dy) / dy;
    var tb = (r.bottom - a.dy) / dy;
    if (ta > tb) {
      final t = ta;
      ta = tb;
      tb = t;
    }
    if (ta > t0) t0 = ta;
    if (tb < t1) t1 = tb;
    if (t0 > t1) return false;
  }

  // t0 == t1 表示只在一个点上接触（端点落在边界），不算相交。
  return t1 > t0;
}

/// 折线总长度。
double polylineLength(List<Offset> points) {
  var total = 0.0;
  for (var i = 0; i < points.length - 1; i++) {
    total += (points[i + 1] - points[i]).distance;
  }
  return total;
}

/// 折线上「走过一半长度」的那个点，删除按钮定位用。
///
/// 用长度中点而不是顶点下标中点，否则一条很长的横带 + 很短的引入段会把按钮
/// 挤到拐角上。
Offset polylineMidpoint(List<Offset> points) {
  if (points.isEmpty) return Offset.zero;
  if (points.length == 1) return points.first;
  final half = polylineLength(points) / 2;
  var acc = 0.0;
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    final seg = (b - a).distance;
    if (seg <= 0) continue;
    if (acc + seg >= half) {
      final t = (half - acc) / seg;
      return Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t);
    }
    acc += seg;
  }
  return points.last;
}

// ================= 内部工具 =================

double _clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

/// 把横带 y 收敛到 (lo, hi) 开区间内；区间太窄（两端卡片几乎贴在一起）就取中点。
double _clampBand(double v, double lo, double hi) {
  if (hi - lo <= 2 * _eps) return (lo + hi) / 2;
  return _clamp(v, lo + _eps, hi - _eps);
}

/// 去重（相差不到 0.5px 视为同一条横带），保持原有顺序。
List<double> _uniqueBands(List<double> raw) {
  final out = <double>[];
  for (final v in raw) {
    if (!out.any((e) => (e - v).abs() < _eps)) out.add(v);
  }
  return out;
}

/// 先绕近的一侧，视觉上更短。
List<double> _sideOrder(double leftX, double rightX, double sx) {
  final toRight = (rightX - sx).abs();
  final toLeft = (sx - leftX).abs();
  return toRight <= toLeft
      ? <double>[rightX, leftX]
      : <double>[leftX, rightX];
}

Rect _boundsOf(Rect a, Rect b, List<Rect> rest) {
  var left = math.min(a.left, b.left);
  var top = math.min(a.top, b.top);
  var right = math.max(a.right, b.right);
  var bottom = math.max(a.bottom, b.bottom);
  for (final r in rest) {
    left = math.min(left, r.left);
    top = math.min(top, r.top);
    right = math.max(right, r.right);
    bottom = math.max(bottom, r.bottom);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

Rect _polylineBounds(List<Offset> points) {
  var left = points.first.dx;
  var top = points.first.dy;
  var right = points.first.dx;
  var bottom = points.first.dy;
  for (final p in points) {
    left = math.min(left, p.dx);
    top = math.min(top, p.dy);
    right = math.max(right, p.dx);
    bottom = math.max(bottom, p.dy);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// 去掉重复点和共线的中间点，得到最简折线。
List<Offset> _dedupe(List<Offset> pts) {
  final kept = <Offset>[];
  for (final p in pts) {
    if (kept.isEmpty ||
        (kept.last.dx - p.dx).abs() > _eps ||
        (kept.last.dy - p.dy).abs() > _eps) {
      kept.add(p);
    }
  }
  if (kept.length < 3) return kept;
  final out = <Offset>[kept.first];
  for (var i = 1; i < kept.length - 1; i++) {
    final a = out.last;
    final b = kept[i];
    final c = kept[i + 1];
    // 二维叉积：所有点都是正交生成的，非共线时叉积等于两段长度之积（很大）。
    final cross =
        (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
    if (cross.abs() > _eps) out.add(b);
  }
  out.add(kept.last);
  return out;
}

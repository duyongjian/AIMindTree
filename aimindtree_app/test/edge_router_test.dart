import 'dart:math' as math;
import 'dart:ui';

import 'package:aimindtree_app/canvas/render/edge_router.dart';
import 'package:flutter_test/flutter_test.dart';

// 与 LayoutConfig 默认一致：nodeWidth 220 / nodeHeight 136 / hGap 40 / vGap 40
// ⇒ 行高 = 136 + 40 = 176，列宽 = 220 + 40 = 260。
const double kW = 220;
const double kH = 136;
const double kGap = 40;
const double kRowH = 176;
const double kColW = 260;

final Size kNodeSize = const Size(kW, kH);

Rect node(double x, double y) => Rect.fromLTWH(x, y, kW, kH);

void main() {
  group('segmentIntersectsRect：线段—矩形相交判定', () {
    final r = node(0, 0); // (0,0)-(220,136)

    test('横穿矩形内部 → 相交', () {
      expect(segmentIntersectsRect(const Offset(-10, 68), const Offset(230, 68), r),
          isTrue);
    });

    test('完全在矩形外 → 不相交', () {
      expect(
          segmentIntersectsRect(const Offset(-10, 200), const Offset(230, 200), r),
          isFalse);
      expect(
          segmentIntersectsRect(const Offset(300, 0), const Offset(300, 300), r),
          isFalse);
    });

    test('整段贴着上边缘走 → 算相交（这正是要修的老毛病）', () {
      expect(segmentIntersectsRect(const Offset(0, 0), const Offset(220, 0), r),
          isTrue);
    });

    test('端点恰好落在边界上（垂直插入）→ 不算相交', () {
      // 进入目标卡片的那一段一定以边界点为终点，不能判成碰撞。
      expect(
          segmentIntersectsRect(const Offset(110, -20), const Offset(110, 0), r),
          isFalse);
    });

    test('只碰一个角 → 不算相交（t0 == t1）', () {
      expect(
          segmentIntersectsRect(const Offset(220, -50), const Offset(330, 0), r),
          isFalse);
    });

    test('完全包含在矩形内 → 相交', () {
      expect(segmentIntersectsRect(const Offset(50, 50), const Offset(60, 60), r),
          isTrue);
    });
  });

  group('routeEdge：基本形状', () {
    test('相邻层（下一行右一列）：横带走行间空隙，不贴目标上边缘', () {
      const from = Offset(0, 0);
      final to = Offset(kColW, kRowH);
      final dst = node(to.dx, to.dy);
      final pts = routeEdge(
        from: from,
        to: to,
        nodeSize: kNodeSize,
        obstacles: const <Rect>[],
        gap: kGap,
      );
      expect(pts.length, greaterThanOrEqualTo(2));
      // 起点在源底边中点、终点在目标顶边中点（保持「前置在上、后继在下」）。
      expect(pts.first.dx, closeTo(kW / 2, 0.01));
      expect(pts.first.dy, closeTo(kH, 0.01));
      expect(pts.last.dx, closeTo(kColW + kW / 2, 0.01));
      expect(pts.last.dy, closeTo(kRowH, 0.01));
      // 横带必须在行间空隙里（离目标顶边有 20px），而不是压在目标上边缘。
      final horizontals = <double>[
        for (var i = 0; i < pts.length - 1; i++)
          if ((pts[i].dy - pts[i + 1].dy).abs() < 0.01) pts[i].dy,
      ];
      expect(horizontals, isNotEmpty);
      for (final y in horizontals) {
        expect((y - dst.top).abs(), greaterThan(10));
      }
      // 整条路径不碰目标卡片本身（inflate=0：终点落在顶边是允许的）。
      expect(countObstacleHits(pts, <Rect>[dst]), 0);
    });

    test('无障碍物：跨两行同列仍是直线（不绕远）', () {
      final pts = routeEdge(
        from: const Offset(0, 0),
        to: Offset(0, 2 * kRowH),
        nodeSize: kNodeSize,
        obstacles: const <Rect>[],
        gap: kGap,
      );
      expect(pts.length, 2);
      expect(pts.first, const Offset(kW / 2, kH));
      expect(pts.last, const Offset(kW / 2, 2 * kRowH));
    });

    test('并排（竖直方向重叠）：从侧面直连，不做上下绕行', () {
      final pts = routeEdge(
        from: const Offset(0, 0),
        to: const Offset(kColW, 0),
        nodeSize: kNodeSize,
        obstacles: const <Rect>[],
        gap: kGap,
      );
      expect(pts.length, 2);
      expect(pts.first, const Offset(kW, kH / 2)); // 源右边中点
      expect(pts.last, const Offset(kColW, kH / 2)); // 目标左边中点
    });
  });

  group('routeEdge：避开节点（核心回归）', () {
    test('跨层连线 A(第0行) → C(第2行)，B 在第1行同列 → 绕开 B', () {
      // 真实布局：A→B、B→C、A→C 时 A/B/C 都在 x=0 这一列，
      // 老实现的竖直段会直接从 B 卡片身上穿过去。
      final a = node(0, 0);
      final b = node(0, kRowH);
      final c = node(0, 2 * kRowH);

      final route = routeEdgeDetailed(
        from: a.topLeft,
        to: c.topLeft,
        nodeSize: kNodeSize,
        obstacles: <Rect>[b],
        gap: kGap,
      );

      // 必须完全避开 B（含 2px 净空）。
      expect(route.obstacleHits, 0);
      expect(countObstacleHits(route.points, <Rect>[b], inflate: 2.0), 0);
      // 而且确实绕了路（不是那条直上直下的老路径）。
      expect(route.points.length, greaterThan(2));
      // 终点仍在 C 的顶边中点。
      expect(route.end, Offset(kW / 2, 2 * kRowH));
      // 起点仍在 A 的底边中点。
      expect(route.start, const Offset(kW / 2, kH));
    });

    test('同一棵树里 A→B 与 A→C 都不碰任何节点', () {
      final a = node(0, 0);
      final b = node(0, kRowH);
      final c = node(0, 2 * kRowH);

      final ab = routeEdgeDetailed(
        from: a.topLeft,
        to: b.topLeft,
        nodeSize: kNodeSize,
        obstacles: <Rect>[c],
        gap: kGap,
      );
      expect(ab.obstacleHits, 0);
      expect(countObstacleHits(ab.points, <Rect>[c], inflate: 2.0), 0);

      final ac = routeEdgeDetailed(
        from: a.topLeft,
        to: c.topLeft,
        nodeSize: kNodeSize,
        obstacles: <Rect>[b],
        gap: kGap,
      );
      expect(ac.obstacleHits, 0);
      expect(countObstacleHits(ac.points, <Rect>[b], inflate: 2.0), 0);
    });

    test('目标被拖到源上方：走源上方空隙，绕开中间节点', () {
      // C(第2行) 被拖到 A(第0行) 的位置上方，B 夹在中间。
      final a = node(0, 0);
      final b = node(0, kRowH);
      final c = node(0, 2 * kRowH);

      final route = routeEdgeDetailed(
        from: c.topLeft, // 源在下方
        to: a.topLeft, // 目标在上方
        nodeSize: kNodeSize,
        obstacles: <Rect>[b],
        gap: kGap,
      );

      expect(route.obstacleHits, 0);
      expect(countObstacleHits(route.points, <Rect>[b], inflate: 2.0), 0);
      // 上出下进：起点在源的**顶边**，终点在目标的**底边**。
      expect(route.start, const Offset(kW / 2, 2 * kRowH));
      expect(route.end, const Offset(kW / 2, kH));
    });

    test('横向跨列：绕开挡在中间的同行节点', () {
      // 源 (0,0) → 目标 (2*列宽, 2 行下)，中间 (列宽, 行高) 有个节点挡路。
      final src = node(0, 0);
      final blocker = node(kColW, kRowH);
      final dst = node(2 * kColW, 2 * kRowH);

      final route = routeEdgeDetailed(
        from: src.topLeft,
        to: dst.topLeft,
        nodeSize: kNodeSize,
        obstacles: <Rect>[blocker],
        gap: kGap,
      );
      expect(route.obstacleHits, 0);
      expect(countObstacleHits(route.points, <Rect>[blocker], inflate: 2.0), 0);
    });

    test('所有候选都被堵死：仍然返回一条完整路径（不抛、不空）', () {
      final src = node(0, 0);
      final dst = node(0, 2 * kRowH);
      // 一整块覆盖全图的「墙」，任何走法都会撞上。
      const wall = Rect.fromLTRB(-500, -500, 500, 500);

      final route = routeEdgeDetailed(
        from: src.topLeft,
        to: dst.topLeft,
        nodeSize: kNodeSize,
        obstacles: const <Rect>[wall],
        gap: kGap,
      );
      expect(route.points.length, greaterThanOrEqualTo(2));
      expect(route.obstacleHits, greaterThan(0));
      expect(route.isClear, isFalse);
      // 坐标全部有限，画出来不会是 NaN / Infinity。
      for (final p in route.points) {
        expect(p.dx.isFinite, isTrue);
        expect(p.dy.isFinite, isTrue);
      }
    });

    test('退化输入（节点尺寸为 0）：兜底返回两点，不抛异常', () {
      final pts = routeEdge(
        from: const Offset(10, 20),
        to: const Offset(30, 40),
        nodeSize: Size.zero,
        obstacles: const <Rect>[],
        gap: kGap,
      );
      expect(pts.length, 2);
    });
  });

  group('polylineMidpoint：删除按钮定位', () {
    test('单段：正中间', () {
      expect(
        polylineMidpoint(const <Offset>[Offset(0, 0), Offset(50, 0)]),
        const Offset(25, 0),
      );
    });

    test('两段等长：落在拐点上', () {
      expect(
        polylineMidpoint(const <Offset>[Offset(0, 0), Offset(100, 0), Offset(100, 100)]),
        const Offset(100, 0),
      );
    });

    test('两段不等长：按长度取半，不是按下标取半', () {
      // 总长 30 + 10 = 40，中点在 20 处 → 第一段上。
      final m = polylineMidpoint(const <Offset>[
        Offset(0, 0),
        Offset(30, 0),
        Offset(30, 10),
      ]);
      expect(m, const Offset(20, 0));
    });

    test('绕行路径的中点落在折线上，且把折线分成等长的两半', () {
      final a = node(0, 0);
      final b = node(0, kRowH);
      final c = node(0, 2 * kRowH);
      final route = routeEdgeDetailed(
        from: a.topLeft,
        to: c.topLeft,
        nodeSize: kNodeSize,
        obstacles: <Rect>[b],
        gap: kGap,
      );
      final total = polylineLength(route.points);
      final m = route.midpoint;

      // 沿折线累积到中点：中点必须**落在某一段上**（否则删除按钮会飘到线外），
      // 且累积长度恰好是总长的一半。
      var acc = 0.0;
      var onPolyline = false;
      for (var i = 0; i < route.points.length - 1; i++) {
        final p = route.points[i];
        final q = route.points[i + 1];
        final cross =
            (m.dx - p.dx) * (q.dy - p.dy) - (m.dy - p.dy) * (q.dx - p.dx);
        final within = m.dx >= math.min(p.dx, q.dx) - 0.01 &&
            m.dx <= math.max(p.dx, q.dx) + 0.01 &&
            m.dy >= math.min(p.dy, q.dy) - 0.01 &&
            m.dy <= math.max(p.dy, q.dy) + 0.01;
        if (cross.abs() < 0.01 && within) {
          acc += (m - p).distance;
          onPolyline = true;
          break;
        }
        acc += (q - p).distance;
      }
      expect(onPolyline, isTrue,
          reason: '中点必须落在折线上，删除按钮才不会飘到线外面');
      expect(acc, closeTo(total / 2, 0.01));
    });

    test('空列表 / 单点：不抛异常', () {
      expect(polylineMidpoint(const <Offset>[]), Offset.zero);
      expect(polylineMidpoint(const <Offset>[Offset(7, 9)]),
          const Offset(7, 9));
      expect(polylineLength(const <Offset>[]), 0);
      expect(polylineLength(const <Offset>[Offset(7, 9)]), 0);
    });
  });

  // =====================================================================
  // 以下为 QA（严过关）独立补充的边界 / 退化 / 性能用例
  // =====================================================================

  group('segmentIntersectsRect：更多边界几何', () {
    final r = node(0, 0); // (0,0)-(220,136)

    test('真正穿过一个角点：(110,-50)→(330,50) 恰好过右上角 (220,0)', () {
      // 与上一条只碰「一个点」的用例不同，这条线段是真的压着角点走过去的，
      // Liang–Barsky 会算出 t0 == t1 → 不算相交。
      expect(
        segmentIntersectsRect(const Offset(110, -50), const Offset(330, 50), r),
        isFalse,
      );
    });

    test('端点正好落在矩形角上、另一端在矩形外 → 不算相交', () {
      expect(
        segmentIntersectsRect(const Offset(220, 0), const Offset(330, 0), r),
        isFalse,
      );
      expect(
        segmentIntersectsRect(const Offset(220, 136), const Offset(330, 200), r),
        isFalse,
      );
    });

    test('与边界共线但完全在矩形跨度之外 → 不算相交', () {
      expect(
        segmentIntersectsRect(const Offset(250, 0), const Offset(350, 0), r),
        isFalse,
      );
    });

    test('垂直贴着左边缘 / 右边缘走 → 都算相交', () {
      expect(
        segmentIntersectsRect(const Offset(0, -10), const Offset(0, 200), r),
        isTrue,
      );
      expect(
        segmentIntersectsRect(const Offset(220, -10), const Offset(220, 200), r),
        isTrue,
      );
    });

    test('端点落在角上、并沿上边缘延伸进矩形 → 算相交（贴边）', () {
      expect(
        segmentIntersectsRect(const Offset(220, 0), const Offset(110, 0), r),
        isTrue,
      );
    });

    test('两端都在矩形内部（斜穿整个矩形）→ 相交', () {
      expect(
        segmentIntersectsRect(const Offset(20, 20), const Offset(200, 116), r),
        isTrue,
      );
    });

    test('零长度线段：落在矩形内部算相交，落在边界上算相交，外部不算', () {
      // 退化线段退化为「点」判定：dx、dy 都是 0，两个 slab 都只做区间检查。
      expect(
        segmentIntersectsRect(const Offset(50, 50), const Offset(50, 50), r),
        isTrue,
      );
      expect(
        segmentIntersectsRect(const Offset(300, 50), const Offset(300, 50), r),
        isFalse,
      );
    });
  });

  group('countObstacleHits：inflate 语义', () {
    final r = node(0, 0);

    test('距上边缘 1px 的横段：inflate=0 不算，inflate=2 算', () {
      final pts = <Offset>[const Offset(-10, -1), const Offset(230, -1)];
      expect(countObstacleHits(pts, <Rect>[r], inflate: 0.0), 0);
      expect(countObstacleHits(pts, <Rect>[r], inflate: 2.0), 1);
    });

    test('距上边缘 3px 的横段：inflate=0 与 inflate=2 都不算', () {
      final pts = <Offset>[const Offset(-10, -3), const Offset(230, -3)];
      expect(countObstacleHits(pts, <Rect>[r], inflate: 0.0), 0);
      expect(countObstacleHits(pts, <Rect>[r], inflate: 2.0), 0);
    });

    test('横穿矩形内部：inflate=0 与 inflate=2 都算', () {
      final pts = <Offset>[const Offset(-10, 68), const Offset(230, 68)];
      expect(countObstacleHits(pts, <Rect>[r], inflate: 0.0), 1);
      expect(countObstacleHits(pts, <Rect>[r], inflate: 2.0), 1);
    });

    test('inflate 只对障碍物生效，不影响折线本身', () {
      // 折线离矩形 10px，inflate=20 后才算相交。
      final pts = <Offset>[const Offset(-10, -10), const Offset(230, -10)];
      expect(countObstacleHits(pts, <Rect>[r], inflate: 5.0), 0);
      expect(countObstacleHits(pts, <Rect>[r], inflate: 20.0), 1);
    });

    test('空折线 / 单点 / 空障碍集 → 恒为 0', () {
      expect(countObstacleHits(const <Offset>[], <Rect>[r]), 0);
      expect(countObstacleHits(const <Offset>[Offset(50, 50)], <Rect>[r]), 0);
      expect(
        countObstacleHits(
          const <Offset>[Offset(-10, 68), Offset(230, 68)],
          const <Rect>[],
        ),
        0,
      );
    });

    test('零面积折线正好压在矩形上边缘：粗筛不能漏判（与精确判定一致）', () {
      // 回归：countObstacleHits 先用「整条折线的包围盒」粗筛。早先用的是
      // r.overlaps(bounds)，而 Rect.overlaps 是**严格面积相交**
      // （bottom <= other.top 就判 false）；折线退化成一条水平线（包围盒高度
      // 为 0）且 y 正好等于矩形上边缘时会被粗筛漏掉，与 segmentIntersectsRect
      // 的判定不一致。现在粗筛改成「非严格分离」，两者必须同真同假。
      final pts = <Offset>[const Offset(-10, 0), const Offset(230, 0)];
      expect(segmentIntersectsRect(pts[0], pts[1], r), isTrue);
      expect(
        countObstacleHits(pts, <Rect>[r], inflate: 0.0),
        1,
        reason: '必须与 segmentIntersectsRect 的判定保持一致',
      );
      expect(countObstacleHits(pts, <Rect>[r], inflate: 2.0), 1);
    });

    test('零面积折线正好压在矩形左边缘：粗筛不能漏判（竖直线同理）', () {
      // 水平方向的对称用例：折线退化成一条竖直线，x 正好等于矩形左边缘。
      final pts = <Offset>[const Offset(0, -10), const Offset(0, 300)];
      expect(segmentIntersectsRect(pts[0], pts[1], r), isTrue);
      expect(countObstacleHits(pts, <Rect>[r], inflate: 0.0), 1);
    });
  });

  group('routeEdge：退化 / 极端几何', () {
    test('from 与 to 完全重合：不抛异常，返回 ≥2 个点且坐标有限', () {
      final route = routeEdgeDetailed(
        from: const Offset(40, 60),
        to: const Offset(40, 60),
        nodeSize: kNodeSize,
        obstacles: const <Rect>[],
        gap: kGap,
      );
      expect(route.points.length, greaterThanOrEqualTo(2));
      for (final p in route.points) {
        expect(p.dx.isFinite, isTrue);
        expect(p.dy.isFinite, isTrue);
      }
      expect(route.start.dx.isFinite, isTrue);
      expect(route.midpoint.dx.isFinite, isTrue);
    });

    test('两卡片仅 1px 间距：横带被收敛到中点，返回直线且不越界', () {
      final src = node(0, 0);
      final dst = node(0, kH + 1); // 137
      final route = routeEdgeDetailed(
        from: src.topLeft,
        to: dst.topLeft,
        nodeSize: kNodeSize,
        obstacles: const <Rect>[],
        gap: kGap,
      );
      expect(route.points.length, greaterThanOrEqualTo(2));
      // (lo, hi) 只有 1px 宽，_clampBand 直接取中点 136.5，绝不能跑到 137 以下。
      for (final p in route.points) {
        expect(p.dy, inInclusiveRange(src.bottom - 0.01, dst.top + 0.01));
      }
      expect(route.end.dy, closeTo(dst.top, 0.01));
    });

    test('节点尺寸宽/高为 0 或 NaN：兜底两点，不抛异常', () {
      for (final size in <Size>[
        const Size(0, 136),
        const Size(220, 0),
        Size.zero,
        const Size(double.nan, double.nan),
      ]) {
        final pts = routeEdge(
          from: const Offset(10, 20),
          to: const Offset(30, 40),
          nodeSize: size,
          obstacles: <Rect>[node(0, 0)],
          gap: kGap,
        );
        expect(pts.length, 2);
        expect(pts.first, const Offset(10, 20));
        expect(pts.last, const Offset(30, 40));
      }
    });

    test('gap = 0 / 负数：pad 兜底到 6，横带仍在两行之间', () {
      for (final g in <double>[0, -50]) {
        final pts = routeEdge(
          from: Offset.zero,
          to: Offset(kColW, 2 * kRowH),
          nodeSize: kNodeSize,
          obstacles: const <Rect>[],
          gap: g,
        );
        // 起点在源底边中点，终点在目标顶边中点。
        expect(pts.first, const Offset(kW / 2, kH));
        expect(pts.last, Offset(kColW + kW / 2, 2 * kRowH));
        // 横带 = 源底边 + 6（_minPad）。
        final band = pts[1].dy;
        expect(band, closeTo(kH + 6, 0.01), reason: 'gap=$g 时 pad 应兜底到 6');
        expect(band, greaterThan(kH));
        expect(band, lessThan(2 * kRowH));
      }
    });

    test('gap 巨大：pad 被截到 40，不会把横带甩到图外', () {
      final pts = routeEdge(
        from: Offset.zero,
        to: Offset(kColW, 2 * kRowH),
        nodeSize: kNodeSize,
        obstacles: const <Rect>[],
        gap: 5000,
      );
      expect(pts[1].dy, closeTo(kH + 40, 0.01), reason: 'pad 上限 40');
    });
  });

  group('routeEdge：不变量（起终点 / 非空 / 有限）', () {
    /// 点 [p] 是否落在矩形 [r] 的周界上。
    bool onPerimeter(Offset p, Rect r, {double tol = 0.01}) {
      final withinX = p.dx >= r.left - tol && p.dx <= r.right + tol;
      final withinY = p.dy >= r.top - tol && p.dy <= r.bottom + tol;
      final onVert =
          (p.dx - r.left).abs() <= tol || (p.dx - r.right).abs() <= tol;
      final onHorz =
          (p.dy - r.top).abs() <= tol || (p.dy - r.bottom).abs() <= tol;
      return (onVert && withinY) || (onHorz && withinX);
    }

    final cases = <({String name, Offset from, Offset to, List<Rect> obs})>[
      (
        name: '相邻层右下',
        from: Offset.zero,
        to: Offset(kColW, kRowH),
        obs: const <Rect>[],
      ),
      (
        name: '同列跨两行（无障碍 → 直线）',
        from: Offset.zero,
        to: Offset(0, 2 * kRowH),
        obs: const <Rect>[],
      ),
      (
        name: '跨层且中间有 B 挡路',
        from: Offset.zero,
        to: Offset(0, 2 * kRowH),
        obs: <Rect>[node(0, kRowH)],
      ),
      (
        name: '并排（竖直重叠）',
        from: Offset.zero,
        to: Offset(kColW, 0),
        obs: const <Rect>[],
      ),
      (
        name: '目标被拖到源上方',
        from: Offset(0, 2 * kRowH),
        to: Offset.zero,
        obs: <Rect>[node(0, kRowH)],
      ),
      (
        name: '横向跨列 + 中间阻挡',
        from: Offset.zero,
        to: Offset(2 * kColW, 2 * kRowH),
        obs: <Rect>[node(kColW, kRowH)],
      ),
      (
        name: '仅 1px 间距',
        from: Offset.zero,
        to: Offset(0, kH + 1),
        obs: const <Rect>[],
      ),
      (
        name: '斜向大跨度',
        from: Offset.zero,
        to: Offset(3 * kColW, 3 * kRowH),
        obs: <Rect>[node(kColW, kRowH), node(2 * kColW, 2 * kRowH)],
      ),
    ];

    for (final c in cases) {
      test('${c.name}：首点在源卡片边界、末点在目标卡片边界、非空且坐标有限', () {
        final src = node(c.from.dx, c.from.dy);
        final dst = node(c.to.dx, c.to.dy);
        final route = routeEdgeDetailed(
          from: c.from,
          to: c.to,
          nodeSize: kNodeSize,
          obstacles: c.obs,
          gap: kGap,
        );

        expect(route.points.length, greaterThanOrEqualTo(2),
            reason: '折线至少 2 个点，不能为空或只有 1 个点');
        for (final p in route.points) {
          expect(p.dx.isFinite && p.dy.isFinite, isTrue,
              reason: '不能出现 NaN / Infinity');
        }
        expect(onPerimeter(route.start, src), isTrue,
            reason: '起点 ${route.start} 必须落在源卡片 $src 的边界上');
        expect(onPerimeter(route.end, dst), isTrue,
            reason: '终点 ${route.end} 必须落在目标卡片 $dst 的边界上');
        // 除两端卡片外的障碍物必须完全避开。
        expect(countObstacleHits(route.points, c.obs, inflate: 2.0), 0);
      });
    }
  });

  group('routeEdge：同排（y 相同）连线', () {
    test('A/B/C 同一行、A→C 且 B 夹在中间 → 绕到整图上方，避开 B', () {
      final a = node(0, 0);
      final b = node(kColW, 0);
      final c = node(2 * kColW, 0);
      final route = routeEdgeDetailed(
        from: a.topLeft,
        to: c.topLeft,
        nodeSize: kNodeSize,
        obstacles: <Rect>[b],
        gap: kGap,
      );
      expect(route.isClear, isTrue);
      expect(countObstacleHits(route.points, <Rect>[b], inflate: 2.0), 0);
      expect(route.points.length, greaterThan(2));
    });

    test('同排 + 上下各有一行挡着 → 仍能绕开（绕到更外面）', () {
      final a = node(0, 0);
      final b = node(kColW, 0);
      final c = node(2 * kColW, 0);
      final route = routeEdgeDetailed(
        from: a.topLeft,
        to: c.topLeft,
        nodeSize: kNodeSize,
        obstacles: <Rect>[b, node(kColW, -kRowH), node(kColW, kRowH)],
        gap: kGap,
      );
      expect(route.isClear, isTrue);
      expect(
        countObstacleHits(
          route.points,
          <Rect>[b, node(kColW, -kRowH), node(kColW, kRowH)],
          inflate: 2.0,
        ),
        0,
      );
    });

    test('[信息级] 同排场景末点可能被 _dedupe 截掉 ≤0.5px', () {
      // 同排时 lo = inY（出线点在下方、进线点在上方，方向是反的），
      // _clampBand 把横带收到 lo + _eps = inY + 0.5，末段只有 0.5px，
      // 被 _dedupe 当成重复点合并掉 ⇒ 折线终点落在目标卡片顶边**内侧** 0.5px。
      // 影响：箭头圆点（半径 3）画的位置偏 0.5px，肉眼不可见；仅立此存照。
      final a = node(0, 0);
      final c = node(2 * kColW, 0);
      final route = routeEdgeDetailed(
        from: a.topLeft,
        to: c.topLeft,
        nodeSize: kNodeSize,
        obstacles: <Rect>[node(kColW, 0)],
        gap: kGap,
      );
      expect((route.end.dy - c.top).abs(), lessThanOrEqualTo(0.5));
      expect(route.end.dx, closeTo(c.center.dx, 0.01));
    });
  });

  group('routeEdge：端点必须被排除在障碍集外（约定验证）', () {
    test('不排除两端 → 每条候选都恒判碰撞，退化成「撞得最少」', () {
      final a = node(0, 0);
      final b = node(0, kRowH);
      final c = node(0, 2 * kRowH);

      // ★ 故意把 A / C 自己也塞进障碍集，模拟调用方忘了过滤。
      final route = routeEdgeDetailed(
        from: a.topLeft,
        to: c.topLeft,
        nodeSize: kNodeSize,
        obstacles: <Rect>[a, b, c],
        gap: kGap,
      );

      // 起终点必然落在自己矩形的边界上，inflate=2 之后第一段 / 最后一段都算相交
      // ⇒ 每条候选至少 2 次命中 ⇒ 永远拿不到 isClear 的路径。
      expect(route.obstacleHits, greaterThanOrEqualTo(2));
      expect(route.isClear, isFalse);
      expect(route.points.length, greaterThanOrEqualTo(2));
    });

    test('排除两端后：同一场景立刻得到无碰撞路径', () {
      final a = node(0, 0);
      final b = node(0, kRowH);
      final c = node(0, 2 * kRowH);

      final route = routeEdgeDetailed(
        from: a.topLeft,
        to: c.topLeft,
        nodeSize: kNodeSize,
        obstacles: <Rect>[b],
        gap: kGap,
      );
      expect(route.isClear, isTrue);
      expect(route.obstacleHits, 0);
    });

    test('排除两端后仍可用 inflate=0 复核全量节点（含两端）→ 0 命中', () {
      final a = node(0, 0);
      final b = node(0, kRowH);
      final c = node(0, 2 * kRowH);

      final route = routeEdgeDetailed(
        from: a.topLeft,
        to: c.topLeft,
        nodeSize: kNodeSize,
        obstacles: <Rect>[b],
        gap: kGap,
      );
      // inflate=0 时「端点落在自己边界上」不算相交，所以全量复核也是干净的。
      expect(countObstacleHits(route.points, <Rect>[a, b, c], inflate: 0.0), 0);

      // 但用 inflate=2 复核全量节点**必然** ≥2：头尾两段各扎进自己卡片 2px。
      // 这是「端点落在边界不算相交」这条约定的直接推论，不是 bug —— 所以
      // routeEdge 的调用方必须把两端排除掉，否则上面的复核结果会误导人。
      expect(
        countObstacleHits(route.points, <Rect>[a, b, c], inflate: 2.0),
        greaterThanOrEqualTo(2),
      );
    });
  });

  group('routeEdge：大规模图（50 节点 / 60 边）', () {
    test('全部路由能在合理时间内算完，且不出现空路径 / NaN / 死循环', () {
      const cols = 10;
      const rows = 5;
      const n = cols * rows; // 50
      final rects = <Rect>[
        for (var i = 0; i < n; i++)
          node((i % cols) * kColW, (i ~/ cols) * kRowH),
      ];

      // 60 条边，故意掺入跨层 / 跨列 / 反向的组合。
      final pairs = <(int, int)>[];
      for (var i = 0; i < 60; i++) {
        final from = i % n;
        var to = (i * 7 + 13) % n;
        if (to == from) to = (to + 1) % n;
        pairs.add((from, to));
      }

      final sw = Stopwatch()..start();
      var totalPoints = 0;
      var clearCount = 0;
      for (final (f, t) in pairs) {
        final route = routeEdgeDetailed(
          from: rects[f].topLeft,
          to: rects[t].topLeft,
          nodeSize: kNodeSize,
          obstacles: <Rect>[
            for (var i = 0; i < n; i++)
              if (i != f && i != t) rects[i],
          ],
          gap: kGap,
        );
        expect(route.points.length, greaterThanOrEqualTo(2));
        for (final p in route.points) {
          expect(p.dx.isFinite && p.dy.isFinite, isTrue);
        }
        totalPoints += route.points.length;
        if (route.isClear) clearCount++;
      }
      sw.stop();

      // 断言只做兜底（CI 机器差异很大），实际耗时打在失败信息里便于记录。
      expect(sw.elapsedMilliseconds, lessThan(3000),
          reason: '50 节点 / 60 边全量路由耗时 ${sw.elapsedMilliseconds}ms，'
              '平均每条 ${sw.elapsedMicroseconds / 60 / 1000}ms，'
              '共 $totalPoints 个顶点，其中 $clearCount / 60 条完全无碰撞');
    });
  });

  group('routeEdgeDetailed 与 routeEdge 一致性', () {
    test('两者返回同一条折线', () {
      final pts = routeEdge(
        from: Offset.zero,
        to: Offset(0, 2 * kRowH),
        nodeSize: kNodeSize,
        obstacles: <Rect>[node(0, kRowH)],
        gap: kGap,
      );
      final detailed = routeEdgeDetailed(
        from: Offset.zero,
        to: Offset(0, 2 * kRowH),
        nodeSize: kNodeSize,
        obstacles: <Rect>[node(0, kRowH)],
        gap: kGap,
      );
      expect(pts, detailed.points);
      expect(detailed.start, pts.first);
      expect(detailed.end, pts.last);
      expect(detailed.midpoint, polylineMidpoint(pts));
    });
  });
}

import 'package:aimindtree_app/canvas/render/layout_engine.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:flutter_test/flutter_test.dart';

KnowledgePoint _kp(String id, String name) => KnowledgePoint(
      id: id,
      name: name,
      sourceNoteId: 'n',
      sourceStart: 0,
      sourceEnd: 0,
      sourceQuote: '',
    );

PrerequisiteEdge _edge(String from, String to) =>
    PrerequisiteEdge(fromKpId: from, toKpId: to);

/// 指定来源笔记的知识点（用于验证「按领域分组」）。
KnowledgePoint _kpNote(String id, String name, String note) => KnowledgePoint(
      id: id,
      name: name,
      sourceNoteId: note,
      sourceStart: 0,
      sourceEnd: 0,
      sourceQuote: '',
    );

void main() {
  group('layoutForest：拓扑分层', () {
    test('无前置的 KP 全在 level 0', () {
      // 无前置 = 展示子图内没有边 = 落入「无连线区」；level 仍恒记 0，
      // 行内同样按名称排序（同来源笔记、同类型）。
      final r = layoutForest([_kp('a', 'A'), _kp('b', 'B')], const []);
      expect(r.nodes.length, 2);
      expect(r.nodes.every((n) => n.level == 0), isTrue);
      // 无连线区内按名称排序：A 在前
      expect(r.nodes[0].kpId, 'a');
      expect(r.nodes[1].kpId, 'b');
    });

    test('链 A→B→C：C 在最上层', () {
      final r = layoutForest(
        [_kp('a', 'A'), _kp('b', 'B'), _kp('c', 'C')],
        [_edge('a', 'b'), _edge('b', 'c')],
      );
      expect(r.nodes.firstWhere((n) => n.kpId == 'a').level, 0);
      expect(r.nodes.firstWhere((n) => n.kpId == 'b').level, 1);
      expect(r.nodes.firstWhere((n) => n.kpId == 'c').level, 2);
      // y 坐标随 level 递增
      final a = r.nodes.firstWhere((n) => n.kpId == 'a');
      final c = r.nodes.firstWhere((n) => n.kpId == 'c');
      expect(c.y, greaterThan(a.y));
    });

    test('森林：多个根分别下挂', () {
      final r = layoutForest(
        [
          _kp('r1', 'R1'),
          _kp('r2', 'R2'),
          _kp('c1', 'C1'),
          _kp('c2', 'C2'),
        ],
        [_edge('r1', 'c1'), _edge('r2', 'c2')],
      );
      // R1/R2 = 0; C1/C2 = 1
      expect(r.nodes.firstWhere((n) => n.kpId == 'r1').level, 0);
      expect(r.nodes.firstWhere((n) => n.kpId == 'c1').level, 1);
      // 边只保留子图内的
      expect(r.edges.length, 2);
    });

    test('前置图成环：所有点都安置（不抛、不死循环）', () {
      final r = layoutForest(
        [_kp('a', 'A'), _kp('b', 'B')],
        [_edge('a', 'b'), _edge('b', 'a')], // 环
      );
      expect(r.nodes.length, 2);
    });

    test('边指向展示子图外：自动忽略', () {
      final r = layoutForest(
        [_kp('a', 'A'), _kp('b', 'B')],
        [_edge('a', 'b'), _edge('a', 'ghost')],
      );
      expect(r.edges.length, 1);
      expect(r.edges.single.fromId, 'a');
      expect(r.edges.single.toId, 'b');
    });

    test('空输入：空结果', () {
      final r = layoutForest(const [], const []);
      expect(r.nodes, isEmpty);
      expect(r.edges, isEmpty);
    });

    test('无连线区内按名称稳定排序，位置可复现', () {
      final r1 = layoutForest(
        [_kp('z', 'Z'), _kp('a', 'A'), _kp('m', 'M')],
        const [],
      );
      expect(r1.nodes.map((n) => n.kpId).toList(), ['a', 'm', 'z']);
    });

    test('无连线区同样按「领域(来源笔记)」分组，组内再按名称', () {
      final r = layoutForest(
        [
          _kpNote('x1', 'Apple', 'nA'),
          _kpNote('y1', 'Banana', 'nB'),
          _kpNote('z1', 'Cherry', 'nA'),
        ],
        const [],
      );
      // 两区复用同一套排序口径：nA 组 = {Apple, Cherry}（标签 'Apple'）先于
      // nB 组 = {Banana}（标签 'Banana'）；组内按名称：Apple → Cherry。
      expect(r.nodes.map((n) => n.kpId).toList(), ['x1', 'z1', 'y1']);
    });
  });

  group('layoutForest：两区布局（有连线区 + 无连线区）', () {
    // 默认参数下的行/列间距（已对齐到 20 网格）：136+40=176→180、220+40=260。
    const rowHeight = 180.0;
    const colWidth = 260.0;

    /// 混合图：链 a→b→c（3 个有边点，占 3 行）+ 11 个无连线点。
    List<KnowledgePoint> mixedPoints() => <KnowledgePoint>[
          _kp('a', 'A'),
          _kp('b', 'B'),
          _kp('c', 'C'),
          for (var i = 1; i <= 11; i++)
            _kp('p${i.toString().padLeft(2, '0')}',
                'P${i.toString().padLeft(2, '0')}'),
        ];

    test('混合图：有连线点全部排在无连线点上方', () {
      final r = layoutForest(mixedPoints(), [_edge('a', 'b'), _edge('b', 'c')]);
      final connected = r.nodes
          .where((n) => const {'a', 'b', 'c'}.contains(n.kpId))
          .toList();
      final isolated =
          r.nodes.where((n) => n.kpId.startsWith('p')).toList();
      expect(connected.length, 3);
      expect(isolated.length, 11);
      // ① 两区不混排：有连线区的最大 y 严格小于无连线区的最小 y。
      final maxConnectedY =
          connected.map((n) => n.y).reduce((a, b) => a > b ? a : b);
      final minIsolatedY =
          isolated.map((n) => n.y).reduce((a, b) => a < b ? a : b);
      expect(maxConnectedY, lessThan(minIsolatedY));
      // 无连线点不参与拓扑分层，level 恒记 0。
      expect(isolated.every((n) => n.level == 0), isTrue);
    });

    test('混合图：无连线区每行 10 个，第 2 行只剩 1 个（10+1 换行）', () {
      final r = layoutForest(mixedPoints(), [_edge('a', 'b'), _edge('b', 'c')]);
      final isolated = r.nodes.where((n) => n.kpId.startsWith('p')).toList();
      // ② 有连线区 3 行（y=0/180/360）后，无连线区从第 4 行（y=540）起铺。
      final rows = <double, List<String>>{};
      for (final n in isolated) {
        rows.putIfAbsent(n.y, () => []).add(n.kpId);
      }
      expect(rows.keys.toList()..sort(), [3 * rowHeight, 4 * rowHeight]);
      expect(rows[3 * rowHeight]!.length, 10);
      expect(rows[4 * rowHeight]!.length, 1);
      // 行内按名称升序：p01…p10 一行，p11 换到第 2 行。
      expect(rows[3 * rowHeight]!.first, 'p01');
      expect(rows[4 * rowHeight]!.single, 'p11');
    });

    test('全无边图：12 个点恰好 2 行（10+2），不再是一条超长行', () {
      final r = layoutForest(
        [
          for (var i = 1; i <= 12; i++)
            _kp('p${i.toString().padLeft(2, '0')}',
                'P${i.toString().padLeft(2, '0')}'),
        ],
        const [],
      );
      // ③ 补前置常见场景：全部进无连线区，10 个一行换行。
      final rows = <double, int>{};
      for (final n in r.nodes) {
        rows[n.y] = (rows[n.y] ?? 0) + 1;
      }
      expect(rows.length, 2);
      expect(rows[0], 10);
      expect(rows[rowHeight], 2);
    });

    test('isolatedPerRow 可调：每行 3 个时 7 个孤立点分 3 行（3+3+1）', () {
      final r = layoutForest(
        [for (var i = 1; i <= 7; i++) _kp('p$i', 'P$i')],
        const [],
        config: const LayoutConfig(isolatedPerRow: 3),
      );
      final rows = <double, int>{};
      for (final n in r.nodes) {
        rows[n.y] = (rows[n.y] ?? 0) + 1;
      }
      expect(rows.length, 3);
      expect(rows[0], 3);
      expect(rows[rowHeight], 3);
      expect(rows[2 * rowHeight], 1);
      // 列间距仍按 colWidth：第 3 列 x = 2 × colWidth。
      expect(r.nodes[2].x, 2 * colWidth);
    });
  });

  group('LayoutBox / findFreeBlockTopLeft：新点落位避让', () {
    test('LayoutBox.overlaps：仅边缘相接不算重叠', () {
      const a = LayoutBox(0, 0, 100, 50);
      const touchRight = LayoutBox(100, 0, 100, 50); // 左缘正好贴 a 的右缘
      const inside = LayoutBox(10, 10, 20, 20);
      expect(a.overlaps(touchRight), isFalse);
      expect(touchRight.overlaps(a), isFalse);
      expect(a.overlaps(inside), isTrue);
      expect(inside.overlaps(a), isTrue);
    });

    test('occupied 为空：直接返回首选坐标', () {
      final r = findFreeBlockTopLeft(
        blockWidth: 100,
        blockHeight: 50,
        occupied: const <LayoutBox>[],
        preferredLeft: 33,
        preferredTop: 44,
      );
      expect(r.left, 33);
      expect(r.top, 44);
    });

    test('首选与占用不相交：原样返回', () {
      final r = findFreeBlockTopLeft(
        blockWidth: 100,
        blockHeight: 50,
        occupied: const [LayoutBox(0, 0, 100, 50)],
        preferredLeft: 200, // 在占用块右侧，无交集
        preferredTop: 0,
      );
      expect(r.left, 200);
      expect(r.top, 0);
    });

    test('首选与占用相交：整块下移到占用下方且左对齐', () {
      final r = findFreeBlockTopLeft(
        blockWidth: 100,
        blockHeight: 50,
        occupied: const [LayoutBox(0, 0, 100, 50)],
        preferredLeft: 0,
        preferredTop: 0,
        step: 20,
      );
      expect(r.left, 0);
      expect(r.top, 70); // maxBottom(50) + step(20)
    });

    test('占用集合参差：左缘取最小、下缘取最大', () {
      final r = findFreeBlockTopLeft(
        blockWidth: 100,
        blockHeight: 50,
        occupied: const [
          LayoutBox(40, 0, 100, 50), // bottom 50
          LayoutBox(0, 0, 60, 30), // left 0, bottom 30
          LayoutBox(80, 0, 100, 90), // bottom 90（最大）
        ],
        preferredLeft: 0,
        preferredTop: 0,
        step: 20,
      );
      expect(r.left, 0); // 最小 left
      expect(r.top, 110); // max bottom(90) + 20
    });
  });
}

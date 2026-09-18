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

void main() {
  group('layoutForest：拓扑分层', () {
    test('无前置的 KP 全在 level 0', () {
      final r = layoutForest([_kp('a', 'A'), _kp('b', 'B')], const []);
      expect(r.nodes.length, 2);
      expect(r.nodes.every((n) => n.level == 0), isTrue);
      // 同一 level 内按名称排序：A 在前
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

    test('同层内按名称稳定排序，位置可复现', () {
      final r1 = layoutForest(
        [_kp('z', 'Z'), _kp('a', 'A'), _kp('m', 'M')],
        const [],
      );
      expect(r1.nodes.map((n) => n.kpId).toList(), ['a', 'm', 'z']);
    });
  });
}

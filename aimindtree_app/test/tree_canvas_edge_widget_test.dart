import 'package:aimindtree_app/canvas/render/edge_router.dart';
import 'package:aimindtree_app/canvas/render/tree_canvas.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 与 LayoutConfig 默认一致：220 × 136，vGap 40。
const double kW = 220;
const double kH = 136;
const double kGap = 40;
const double kRowH = 176;
const Size kNodeSize = Size(kW, kH);

Rect node(double x, double y) => Rect.fromLTWH(x, y, kW, kH);

KnowledgePoint kp(String id, String name) => KnowledgePoint(
      id: id,
      name: name,
      sourceNoteId: 'note-$id',
      sourceStart: 0,
      sourceEnd: 1,
      sourceQuote: 'quote-$id',
    );

/// A(第0行) → B(第1行) → C(第2行)，外加一条跨层的 A→C。
/// A→C 的老实现会竖直穿过 B，是本轮改造的核心场景。
List<KnowledgePoint> get _points => <KnowledgePoint>[kp('A', 'A'), kp('B', 'B'), kp('C', 'C')];

List<PrerequisiteEdge> get _edges => <PrerequisiteEdge>[
      PrerequisiteEdge(id: 'e-ab', fromKpId: 'A', toKpId: 'B'),
      PrerequisiteEdge(id: 'e-bc', fromKpId: 'B', toKpId: 'C'),
      PrerequisiteEdge(id: 'e-ac', fromKpId: 'A', toKpId: 'C'),
    ];

NodePositions _positions(Map<String, Offset> m) => <String, ({double x, double y})>{
      for (final e in m.entries) e.key: (x: e.value.dx, y: e.value.dy),
    };

/// 用与 build 完全相同的入参复算一遍路由，拿它的长度中点当期望值。
List<Offset> _expectedRoute(
  Map<String, Offset> pos,
  String fromId,
  String toId,
) =>
    routeEdge(
      from: pos[fromId]!,
      to: pos[toId]!,
      nodeSize: kNodeSize,
      obstacles: <Rect>[
        for (final e in pos.entries)
          if (e.key != fromId && e.key != toId) node(e.value.dx, e.value.dy),
      ],
      gap: kGap,
    );

Widget _host({
  required Map<String, Offset> pos,
  void Function(String, double, double)? onMoveNode,
  void Function(String)? onDeleteEdge,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(
          child: TreeCanvas(
            points: _points,
            edges: _edges,
            currentMastery: (_) => MasteryStatus.unknown,
            savedPositions: _positions(pos),
            onMoveNode: onMoveNode,
            onDeleteEdge: onDeleteEdge,
          ),
        ),
      ),
    );

void main() {
  testWidgets('三条边各有一个删除按钮，且落在**路由后**折线的中点上',
      (tester) async {
    final pos = <String, Offset>{
      'A': Offset.zero,
      'B': Offset(0, kRowH),
      'C': Offset(0, 2 * kRowH),
    };
    await tester.pumpWidget(_host(pos: pos));
    await tester.pumpAndSettle();

    // 三个删除按钮（节点卡片上没有 close 图标，_LinkHint 只在连线态出现）。
    final buttons = find.byIcon(Icons.close);
    expect(buttons, findsNWidgets(3));

    // 边的顺序与 widget.edges 一致：A→B、B→C、A→C。
    final pairs = <(String, String)>[('A', 'B'), ('B', 'C'), ('A', 'C')];
    for (var i = 0; i < pairs.length; i++) {
      final pts = _expectedRoute(pos, pairs[i].$1, pairs[i].$2);
      final expected = polylineMidpoint(pts);
      final actual = tester.getCenter(buttons.at(i));
      expect(actual.dx, closeTo(expected.dx, 1.0),
          reason: '${pairs[i].$1}→${pairs[i].$2} 删除按钮 x 应落在折线中点上');
      expect(actual.dy, closeTo(expected.dy, 1.0),
          reason: '${pairs[i].$1}→${pairs[i].$2} 删除按钮 y 应落在折线中点上');
    }

    // 非循环断言：跨层 A→C 的按钮必须明显偏离老实现的那条竖直直线
    // （老路径是 x=110 的一条竖线，中点约 (110, 244)），改造后应绕到图外侧。
    final ac = tester.getCenter(buttons.at(2));
    expect(ac.dx, greaterThan(200),
        reason: 'A→C 绕行后中点 x 应远在卡片右侧，而不是老实现的 x≈110');
    expect(ac.dy, closeTo(244, 1.0), reason: '绕行路径的长度中点 y');
  });

  testWidgets('拖动节点后连线跟着重算（删除按钮位置随之更新）', (tester) async {
    final pos = <String, Offset>{
      'A': Offset.zero,
      'B': Offset(0, kRowH),
      'C': Offset(0, 2 * kRowH),
    };
    final moved = <String, Offset>{};
    await tester.pumpWidget(_host(
      pos: pos,
      onMoveNode: (id, x, y) => moved[id] = Offset(x, y),
    ));
    await tester.pumpAndSettle();

    final before = tester.getCenter(find.byIcon(Icons.close).at(2));

    // 拖 A 的拖动手柄（卡片顶部 14px 那条）向右 200px。
    final handles = find.byIcon(Icons.drag_indicator);
    expect(handles, findsNWidgets(3));
    Offset? aHandle;
    for (var i = 0; i < 3; i++) {
      final c = tester.getCenter(handles.at(i));
      if (c.dy < 20) aHandle = c; // A 在最上面一行
    }
    expect(aHandle, isNotNull, reason: '应能定位到 A 的拖动手柄');

    // 分步移动：单次大 move 会被手势竞技场的「接受阈值」吃掉，onPanUpdate 拿不到，
    // 必须发多帧小位移，让 pan 在 accepted 之后还能收到 update。
    final gesture = await tester.startGesture(aHandle!);
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(40, 0));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    // 拖动确实被卡片接到了（onDragEnd → onMoveNode）。
    expect(moved.containsKey('A'), isTrue,
        reason: '拖动结束后应回调 onMoveNode 持久化新位置');
    expect(moved['A']!.dx, greaterThan(50.0),
        reason: 'A 应被明显拖到右边');

    // A→C 这条跨层连线重算后，删除按钮必须跟着移动到新路径的中点上。
    final after = tester.getCenter(find.byIcon(Icons.close).at(2));
    expect((after - before).distance, greaterThan(5.0),
        reason: '拖动后删除按钮位置必须变化，说明连线是跟着重算的');

    final newPos = <String, Offset>{...pos, 'A': moved['A']!};
    final expected = polylineMidpoint(_expectedRoute(newPos, 'A', 'C'));
    expect(after.dx, closeTo(expected.dx, 1.0));
    expect(after.dy, closeTo(expected.dy, 1.0));
  });

  testWidgets('父层换掉 savedPositions 后连线同样重算', (tester) async {
    final pos = <String, Offset>{
      'A': Offset.zero,
      'B': Offset(0, kRowH),
      'C': Offset(0, 2 * kRowH),
    };
    await tester.pumpWidget(_host(pos: pos));
    await tester.pumpAndSettle();
    final before = tester.getCenter(find.byIcon(Icons.close).at(2));

    // 模拟「拖动 → 写库 → 父层用新位置重建」这条路。
    await tester.pumpWidget(_host(pos: <String, Offset>{
      ...pos,
      'A': const Offset(200, 0),
    }));
    await tester.pumpAndSettle();

    final after = tester.getCenter(find.byIcon(Icons.close).at(2));
    expect((after - before).distance, greaterThan(5.0));
    final expected = polylineMidpoint(
      _expectedRoute(<String, Offset>{...pos, 'A': const Offset(200, 0)}, 'A', 'C'),
    );
    expect(after.dx, closeTo(expected.dx, 1.0));
    expect(after.dy, closeTo(expected.dy, 1.0));
  });

  testWidgets('点击删除按钮回传正确的 edge id', (tester) async {
    final pos = <String, Offset>{
      'A': Offset.zero,
      'B': Offset(0, kRowH),
      'C': Offset(0, 2 * kRowH),
    };
    final deleted = <String>[];
    await tester.pumpWidget(_host(
      pos: pos,
      onDeleteEdge: deleted.add,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close).at(2));
    await tester.pumpAndSettle();
    expect(deleted, <String>['e-ac']);
  });
}

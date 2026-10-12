import 'package:aimindtree_app/canvas/render/edge_router.dart';
import 'package:aimindtree_app/canvas/render/knowledge_node_card.dart';
import 'package:aimindtree_app/canvas/render/tree_canvas.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:flutter/gestures.dart';
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

/// 边的顺序与 widget.edges 一致：A→B、B→C、A→C。
const List<(String, String)> kPairs = <(String, String)>[
  ('A', 'B'),
  ('B', 'C'),
  ('A', 'C'),
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

/// 三条边的中点（顺序同 [kPairs]）。
List<Offset> _midpoints(Map<String, Offset> pos) => <Offset>[
      for (final p in kPairs)
        polylineMidpoint(_expectedRoute(pos, p.$1, p.$2)),
    ];

/// 断言两个坐标「基本重合」（1px 容差，吸收 Transform / layout 的舍入）。
void _expectNear(String what, Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, 1.0), reason: '$what：x 不一致');
  expect(actual.dy, closeTo(expected.dy, 1.0), reason: '$what：y 不一致');
}

/// 建一条**鼠标**手势并返回。
///
/// ⚠️ 必须是 mouse：删除叉是 hover 才显示的（MouseRegion 只认鼠标指针），
/// 用默认的 touch 手势收不到 PointerHoverEvent，叉永远不会出现。
Future<TestGesture> _startMouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await tester.pumpAndSettle();
  addTearDown(() async => gesture.removePointer());
  return gesture;
}

/// 把鼠标移到场景点 [target]（这些用例里 savedPositions 非空 ⇒ 不会自动 fit，
/// 于是 scale=1、translation=0，场景坐标 == 屏幕坐标）。
Future<void> _hoverOver(TestGesture mouse, WidgetTester tester, Offset target) async {
  await mouse.moveTo(target);
  await tester.pumpAndSettle();
}

/// 直接拖卡片：去 Ctrl 改造后，左键按住卡片即可拖动（无需修饰键）。
/// 这些用例里 savedPositions 非空 ⇒ 不会自动 fit，scale=1、translation=0，
/// 场景坐标 == 屏幕坐标。

Widget _host({
  required Map<String, Offset> pos,
  void Function(String, double, double)? onMoveNode,
  void Function(String)? onDeleteEdge,
  String? selectedKpId,
  void Function(KnowledgePoint)? onKpTap,
  void Function(String, String)? onCreateEdge,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(
          child: TreeCanvas(
            points: _points,
            edges: _edges,
            currentMastery: (_) => MasteryStatus.unknown,
            savedPositions: _positions(pos),
            selectedKpId: selectedKpId,
            onMoveNode: onMoveNode,
            onDeleteEdge: onDeleteEdge,
            onKpTap: onKpTap,
            onCreateEdge: onCreateEdge,
          ),
        ),
      ),
    );

/// A(0,0) / B(0,200) / C(0,400)，仅用于节点交互测试（不需要边）。
const Map<String, Offset> kNodePos = <String, Offset>{
  'A': Offset.zero,
  'B': Offset(0, 200),
  'C': Offset(0, 400),
};

/// 三条边呈竖直一列时用的位置（A 会被布局引擎重排到 (0,0) 附近）。
Map<String, Offset> get kColumnPos => <String, Offset>{
      'A': Offset.zero,
      'B': Offset(0, kRowH),
      'C': Offset(0, 2 * kRowH),
    };

void main() {
  testWidgets('删除叉默认不显示；鼠标移到哪条线上才在哪条线的中点浮现', (tester) async {
    final pos = kColumnPos;
    // ⚠️ 必须传 onDeleteEdge：画布只在「给了删除回调」时才渲染删除叉
    // （没有删除入口就不该冒叉）。少了它，下面的叉永远找不到，用例会假失败。
    await tester.pumpWidget(_host(pos: pos, onDeleteEdge: (_) {}));
    await tester.pumpAndSettle();

    // ① 初始状态：整张图一个叉都没有（需求②的核心诉求）。
    expect(find.byIcon(Icons.close), findsNothing,
        reason: '改造后删除叉必须在没有 hover 时完全隐藏');

    final mouse = await _startMouse(tester);
    final mids = _midpoints(pos);

    // ② 逐条悬停：任何时刻都**只有一个**叉，且落在这条线的折线中点上。
    for (var i = 0; i < mids.length; i++) {
      await _hoverOver(mouse, tester, mids[i]);
      final buttons = find.byIcon(Icons.close);
      expect(buttons, findsOneWidget,
          reason: '悬停第 $i 条线（${kPairs[i].$1}→${kPairs[i].$2}）时应只显示它自己的叉');
      _expectNear(
        '${kPairs[i].$1}→${kPairs[i].$2} 的删除叉落点',
        tester.getCenter(buttons),
        mids[i],
      );
    }

    // ③ 非循环断言：跨层 A→C 绕到图外侧后，叉也跟着跑到卡片右边。
    expect(mids[2].dx, greaterThan(200),
        reason: 'A→C 绕行后中点 x 应远在卡片右侧，而不是老实现的 x≈110');

    // ④ 鼠标移开到空白处 → 叉消失。
    await _hoverOver(mouse, tester, const Offset(680, 560));
    expect(find.byIcon(Icons.close), findsNothing,
        reason: '鼠标离开连线后叉必须收回去');
  });

  testWidgets('拖动节点后连线跟着重算（删除叉位置随之更新）', (tester) async {
    final pos = kColumnPos;
    final moved = <String, Offset>{};
    await tester.pumpWidget(_host(
      pos: pos,
      onMoveNode: (id, x, y) => moved[id] = Offset(x, y),
      // 同上：不给删除回调，删除叉压根不会渲染。
      onDeleteEdge: (_) {},
    ));
    await tester.pumpAndSettle();
    // 去 Ctrl 后无需修饰键，直接按卡片即可拖。

    final mouse = await _startMouse(tester);
    await _hoverOver(mouse, tester, _midpoints(pos)[2]);
    final before = tester.getCenter(find.byIcon(Icons.close));

    // 卡片顶部的 drag_indicator 图标（装饰条）用来定位；去 Ctrl 后整张卡片
    // 都是拖拽命中区（外层 ScaleRecognizer + 卡片 InkWell 同竞技场）。
    final handles = find.byIcon(Icons.drag_indicator);
    expect(handles, findsNWidgets(3));
    Offset? aHandle;
    for (var i = 0; i < 3; i++) {
      final c = tester.getCenter(handles.at(i));
      if (c.dy < 20) aHandle = c; // A 在最上面一行
    }
    expect(aHandle, isNotNull, reason: '应能定位到 A 的拖动定位点');

    // 分步移动：单次大 move 会被手势竞技场的「接受阈值」吃掉，update 拿不到，
    // 必须发多帧小位移，让 scale 在 accepted 之后还能收到 update。
    final gesture = await tester.startGesture(aHandle!);
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(40, 0));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    // 拖动确实被卡片接到了（onDragEnd → onMoveNode）。
    expect(moved.containsKey('A'), isTrue,
        reason: '拖动结束后应回调 onMoveNode 持久化新位置');
    expect(moved['A']!.dx, greaterThan(50.0), reason: 'A 应被明显拖到右边');

    // A→C 这条跨层连线重算后，把鼠标移到新的中点上，叉必须跟过去。
    final newPos = <String, Offset>{...pos, 'A': moved['A']!};
    final expected = polylineMidpoint(_expectedRoute(newPos, 'A', 'C'));
    await _hoverOver(mouse, tester, expected);
    final after = tester.getCenter(find.byIcon(Icons.close));
    expect((after - before).distance, greaterThan(5.0),
        reason: '拖动后删除叉位置必须变化，说明连线是跟着重算的');
    _expectNear('拖动后 A→C 的删除叉落点', after, expected);
  });

  testWidgets('父层换掉 savedPositions 后连线同样重算', (tester) async {
    final pos = kColumnPos;
    // ⚠️ 必须传 onDeleteEdge：画布只在「给了删除回调」时才渲染删除叉
    // （没有删除入口就不该冒叉）。少了它，下面的叉永远找不到，用例会假失败。
    await tester.pumpWidget(_host(pos: pos, onDeleteEdge: (_) {}));
    await tester.pumpAndSettle();

    final mouse = await _startMouse(tester);
    await _hoverOver(mouse, tester, _midpoints(pos)[2]);
    final before = tester.getCenter(find.byIcon(Icons.close));

    // 模拟「拖动 → 写库 → 父层用新位置重建」这条路。
    // ⚠️ 重建时必须把 onDeleteEdge 一并传回去：_host 默认不给删除回调，父层一
    // 换掉，画布就不再渲染叉，下面 getCenter 会「找不到控件」而不是断言失败。
    final moved = <String, Offset>{...pos, 'A': const Offset(200, 0)};
    await tester.pumpWidget(_host(pos: moved, onDeleteEdge: (_) {}));
    await tester.pumpAndSettle();

    final expected = polylineMidpoint(_expectedRoute(moved, 'A', 'C'));
    await _hoverOver(mouse, tester, expected);
    final after = tester.getCenter(find.byIcon(Icons.close));
    expect((after - before).distance, greaterThan(5.0));
    _expectNear('父层换位置后 A→C 的删除叉落点', after, expected);
  });

  testWidgets('点击删除叉回传正确的 edge id', (tester) async {
    final pos = kColumnPos;
    final deleted = <String>[];
    await tester.pumpWidget(_host(
      pos: pos,
      onDeleteEdge: deleted.add,
    ));
    await tester.pumpAndSettle();

    final mouse = await _startMouse(tester);
    // 悬停跨层的 A→C 那一条，再点它中点上唯一的那颗叉。
    await _hoverOver(mouse, tester, _midpoints(pos)[2]);
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(deleted, <String>['e-ac']);
  });

  testWidgets('selectedKpId 对应的 KnowledgeNodeCard 高亮(isSelected=true)', (tester) async {
    await tester.pumpWidget(_host(pos: kNodePos, selectedKpId: 'B'));
    await tester.pumpAndSettle();
    final cards =
        tester.widgetList<KnowledgeNodeCard>(find.byType(KnowledgeNodeCard));
    expect(cards.length, 3, reason: '应渲染 A/B/C 三张卡片');
    for (final c in cards) {
      expect(c.isSelected, c.kp.id == 'B',
          reason: '只有被画布点选的 B 应高亮蓝色边框');
    }
  });

  testWidgets('点击节点卡片主体触发 onKpTap 并回传正确知识点', (tester) async {
    KnowledgePoint? tapped;
    await tester.pumpWidget(_host(pos: kNodePos, onKpTap: (p) => tapped = p));
    await tester.pumpAndSettle();
    // 卡片标题文本在 InkWell 内，点它即命中卡片主体的 onTap。
    // ⚠️ 拖拽命中层只吃主体顶部 12px，标题行绝大部分仍在可点区域内。
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(tapped, isNotNull, reason: '点击卡片主体应触发 onKpTap');
    expect(tapped!.id, 'B');
  });

  testWidgets('直接拖模式下点「连接」按钮仍能进入连线态（防回归）',
      (tester) async {
    await tester.pumpWidget(_host(pos: kNodePos));
    await tester.pumpAndSettle();
    // 去 Ctrl 后拖动命中靠外层 ScaleRecognizer + 卡片 InkWell 竞技；
    // 静止点击时 Tap 胜出，「连接」按钮照常触发，不会被拖动吞掉。

    final bCard = find.byWidgetPredicate(
      (w) => w is KnowledgeNodeCard && w.kp.id == 'B',
    );
    final linkCenter =
        tester.getCenter(find.descendant(of: bCard, matching: find.byIcon(Icons.link)));
    final cardTop = tester.getRect(bCard).top;

    // 落点从**卡片结构常量**推出来，不要硬编码偏移。
    final buttonTop = cardTop + KnowledgeNodeCard.handleVisibleHeight + 6;
    final tapY = cardTop + KnowledgeNodeCard.handleVisibleHeight + 8;

    expect(tapY, greaterThan(buttonTop), reason: '落点必须仍在「连接」按钮内');
    expect(tapY, lessThan(buttonTop + 20));

    // 命中层若把事件吃掉，点击会被静默吞掉 —— 这条用例守它。
    await tester.tapAt(Offset(linkCenter.dx, tapY));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.link_off), findsOneWidget,
        reason: '直接拖模式下点击「连接」按钮仍能进连线态，不能被拖动手势吞掉');
  });

  testWidgets('连线模式：点 A 连接钮 → 点 B 连接钮 → onCreateEdge(A,B)',
      (tester) async {
    final created = <(String, String)>[];
    await tester.pumpWidget(_host(pos: kNodePos, onCreateEdge: (f, t) => created.add((f, t))));
    await tester.pumpAndSettle();

    final aCard = find.byWidgetPredicate(
      (w) => w is KnowledgeNodeCard && w.kp.id == 'A',
    );
    await tester.tap(find.descendant(of: aCard, matching: find.byIcon(Icons.link)));
    await tester.pumpAndSettle();

    // 进入连线态：起点 A 的按钮变成 link_off，并出现提示条。
    expect(find.byIcon(Icons.link_off), findsOneWidget,
        reason: '起点应显示为「取消连线」图标');
    expect(find.textContaining('再点一个知识点'), findsOneWidget,
        reason: '应出现连线提示条');

    final bCard = find.byWidgetPredicate(
      (w) => w is KnowledgeNodeCard && w.kp.id == 'B',
    );
    await tester.tap(find.descendant(of: bCard, matching: find.byIcon(Icons.link)));
    await tester.pumpAndSettle();

    expect(created, <(String, String)>[('A', 'B')],
        reason: '选 A 为起点、B 为目标应建出 A→B 前置边');
  });

  /// 卡片 A 的抓取带中心（可见灰条里的 drag_indicator 图标中心，必然落在抓取带内）。
  Future<Offset> _aStripCenter(WidgetTester tester) async {
    final handles = find.byIcon(Icons.drag_indicator);
    expect(handles, findsNWidgets(3), reason: 'A/B/C 三张卡片各有一个拖动手柄');
    for (var i = 0; i < 3; i++) {
      final c = tester.getCenter(handles.at(i));
      if (c.dy < 20) return c; // A 在最上面一行
    }
    throw StateError('没找到 A 的拖动手柄');
  }

  testWidgets('位移小于启动阈值时卡片不动（防误拖）', (tester) async {
    final moved = <String, Offset>{};
    await tester.pumpWidget(_host(
      pos: kNodePos,
      onMoveNode: (id, x, y) => moved[id] = Offset(x, y),
    ));
    await tester.pumpAndSettle();
    // 去 Ctrl 后直接按卡片即可拖。

    final strip = await _aStripCenter(tester);
    final gesture = await tester.startGesture(strip, kind: PointerDeviceKind.mouse);
    // 总共只挪 2px：低于 _dragStartThreshold(4px)，应被判成「点击」而不是拖动。
    await gesture.moveBy(const Offset(1, 0));
    await gesture.moveBy(const Offset(1, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(moved, isEmpty,
        reason: '手抖 2px 不该移动卡片，也不该产生一次无意义的落库');
  });

  testWidgets('置顶（拖拽开始即置顶）后仍然能拖动（防「置顶把拖拽搞坏」回归）',
      (tester) async {
    final moved = <String, Offset>{};
    await tester.pumpWidget(_host(
      pos: kNodePos,
      onMoveNode: (id, x, y) => moved[id] = Offset(x, y),
    ));
    await tester.pumpAndSettle();
    // 去 Ctrl 后直接按卡片即可拖。

    final strip = await _aStripCenter(tester);

    // 按下并拖动时，_onScaleStart 会先把被拖的卡片置顶（重排 Stack 子节点），
    // 再继续跟手移动。曾经的实现里，重排会让进行中的手势被绑到别的卡片上，
    // 拖拽直接失效 —— 这条用例专门守它（靠 Positioned 的 ValueKey 防止串台）。
    final mouse = await _startMouse(tester);
    await _hoverOver(mouse, tester, strip);

    final gesture = await tester.startGesture(strip, kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(30, 0));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(moved.containsKey('A'), isTrue,
        reason: '拖拽开始时置顶之后，卡片必须还能继续拖动，不能因为重排而失效');
    expect(moved['A']!.dx, greaterThan(50.0), reason: 'A 应被明显拖到右边');
  });
}

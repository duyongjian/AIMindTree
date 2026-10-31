/// 笔记卡片点击回归（问题7）：
///
/// 卡片必须自带命中的 [GestureDetector]，点卡片主体就触发 onTap，
/// 不再依赖外层画布按「场景坐标」换算命中点（旧实现取的是可能陈旧的
/// `_lastTapScene`，表现为点不中 / 有偏移）。
///
/// 反向约束：`onTap == null` 时**不得**创建 GestureDetector，
/// 否则会在框选 / 画笔 / 橡皮 / 连线模式下抢走外层画布手势。
library;

import 'package:aimindtree_app/canvas/render/canvas_text_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 220, height: 120, child: child),
        ),
      ),
    );

void main() {
  testWidgets('onTap 非空：点卡片主体即触发一次', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(_host(
      CanvasTextCard(
        title: '牛顿第一定律',
        body: '物体在不受外力时保持静止或匀速直线运动。',
        kind: 'note_card',
        linked: true,
        onTap: () => tapped++,
      ),
    ));

    expect(
      find.descendant(
        of: find.byType(CanvasTextCard),
        matching: find.byType(GestureDetector),
      ),
      findsOneWidget,
      reason: '卡片必须自带命中层',
    );

    // 点在卡片中心（即主体文字区域）——不经过任何坐标换算。
    await tester.tap(find.byType(CanvasTextCard));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('onTap 为空：纯展示，不创建 GestureDetector', (tester) async {
    await tester.pumpWidget(_host(
      const CanvasTextCard(
        title: '透明文本框',
        body: '',
        kind: 'text_box',
      ),
    ));

    expect(
      find.descendant(
        of: find.byType(CanvasTextCard),
        matching: find.byType(GestureDetector),
      ),
      findsNothing,
      reason: '无 onTap 时不得抢占外层画布手势',
    );
  });

  testWidgets('透明文本框空内容也算可点（opaque 命中区）', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(_host(
      CanvasTextCard(
        title: '',
        body: '',
        kind: 'text_box',
        onTap: () => tapped++,
      ),
    ));

    await tester.tap(find.byType(CanvasTextCard));
    await tester.pump();
    expect(tapped, 1, reason: '空文本框只有极淡边框提示，仍应整块可点');
  });
}

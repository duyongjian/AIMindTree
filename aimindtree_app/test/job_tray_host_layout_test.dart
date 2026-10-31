/// JobTrayHost 布局回归测试（2026-10-31，Windows 实机定位后补）。
///
/// 根因：任务托盘曾写成
///   `Column(children: [Overlay(initialEntries: [OverlayEntry(...JobTray)]), Expanded(...)])`
/// `Column` 给子节点的高度约束是**无穷大**，`_RenderTheater` 无法确定尺寸，抛
/// 「Overlay was given infinite constraints and cannot be sized by a suitable
/// child」→ 首帧布局中断 → 该帧不送入引擎 → 连带刷屏
/// 「debugFrameWasSentToEngine is not true」与「!semantics.parentDataDirty」
/// （实机日志刷了 16971 条）。
///
/// 修复：Overlay 作 `MaterialApp.builder` 的**根**（吃窗口有限约束），托盘与
/// 页面放进同一个 OverlayEntry 的 Column —— 见 `lib/ui/job_tray.dart` 的
/// `JobTrayHost`。本测试锁定两条不变量：
///   1. 托盘宿主能在有限窗口内完成布局，不抛异常；
///   2. 无任务时托盘高度 0 不占位；有在途任务时托盘占位、页面正文仍可见。
library;

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ui/job_tray.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(AiJobService jobs) => MaterialApp(
      builder: (context, child) => Directionality(
        textDirection: TextDirection.ltr,
        child: JobTrayHost(
          jobs: jobs,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      home: const Scaffold(body: Center(child: Text('页面正文'))),
    );

void main() {
  group('JobTrayHost 布局（防 Overlay 无穷高约束）', () {
    testWidgets('无任务：托盘高度 0，不占位，无异常', (tester) async {
      final jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');
      await tester.pumpWidget(_app(jobs));
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(find.text('页面正文'), findsOneWidget);
      expect(tester.getSize(find.byType(JobTray)).height, 0);
    });

    testWidgets('有在途任务：托盘占位并下推页面，无异常', (tester) async {
      final jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');
      final id = jobs.holdInteractive('kp:1', label: '老师模式');
      addTearDown(() => jobs.releaseInteractive(id));

      await tester.pumpWidget(_app(jobs));
      // revision 通知合流到微任务，多 pump 一帧让托盘监听者重建。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(find.text('页面正文'), findsOneWidget);
      expect(tester.getSize(find.byType(JobTray)).height, greaterThan(0));
      // 收起态摘要直接显示在途任务的 label。
      expect(find.text('老师模式'), findsWidgets);
    });
  });
}

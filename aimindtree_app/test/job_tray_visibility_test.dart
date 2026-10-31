/// 任务托盘行语义回归测试（用户报的「看不懂队列 / 两行同名 / 一直不动 / 假失败」）。
///
/// 锁定的四条不变量：
///   1. **交互会话行不画进度条**：它的 `status` 永远 running、`percent` 永远 0
///      （服务端压根没有这个 job），画 `progressOrNull == null` 的不确定进度条
///      就是一段永远播不完的动画 —— 用户眼里就是「卡住了」；
///   2. **折叠摘要取「最新推进」**的任务，而不是按 `submittedAt` 最早的那条
///      （旧实现让先开的「布置作业」会话一直霸占摘要）；
///   3. **离线行不是失败行**：橙色 `cloud_off` 标、不给重试按钮、行与资源锁都
///      还在（服务端任务还在跑，锁放开会让用户重提撞 409）；
///   4. **done 行保留可见一段时长**再消失（默认 10s，测试注入小值），否则用户
///      回头看不到「刚才那个成了没有」。
///
/// 另加一条纯数据断言：`AiJob.cancelRequested` 是**单调闩锁** —— 服务端可能不回显
/// `cancel_requested`，而不支持中断的任务被取消后仍会一路跑成 done，只有记住这个
/// 闩锁，终态文案才不会误报「已完成」。
library;

import 'dart:async';

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ui/job_tray.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _tray(AiJobService jobs, {Duration doneVisible = kJobTrayDoneVisible}) =>
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: JobTray(jobs: jobs, doneVisible: doneVisible),
        ),
      ),
    );

/// 展开托盘（收起态只有摘要，看不到行内细节）。
Future<void> _expand(WidgetTester tester) async {
  tester.state<JobTrayState>(find.byType(JobTray)).expand();
  await tester.pump();
}

void main() {
  group('任务托盘行语义', () {
    testWidgets('交互会话行：不画进度条、不显示百分比', (tester) async {
      final jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');
      final id = jobs.holdInteractive(
        'homework:new:1',
        label: '布置作业 · 编辑中（二叉树、堆）',
      );
      addTearDown(() => jobs.releaseInteractive(id));

      await tester.pumpWidget(_tray(jobs));
      await tester.pump(); // revision 通知合流在微任务里，多 pump 一帧
      await _expand(tester);

      expect(tester.takeException(), isNull);
      // 文案不再谎称「关闭页面即结束」：关闭只放资源锁，后台生成由 runDetached 继续。
      expect(find.text('会话已打开 · 后台任务不受影响'), findsOneWidget);
      // 折叠态那条 4px 总进度条也不该出现（只有交互会话 = 没有进度可言）。
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      // 交互行也不显示累加计时（它没有任务耗时语义，一直涨会被误读成「卡死」）。
      expect(find.textContaining(RegExp(r'^\d+s$')), findsNothing);
    });

    testWidgets('折叠摘要取「最新推进」的任务，而不是最早提交的', (tester) async {
      final jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');
      // 交互行只有 submittedAt（更早）；后台行有 startedAt（更晚）。
      final interactive = jobs.holdInteractive(
        'homework:new:1',
        label: '布置作业 · 编辑中（二叉树）',
      );
      final pending = Completer<void>();
      final task = jobs.runDetached(
        label: '出题中（2 个知识点）',
        body: (t) => pending.future,
      );
      addTearDown(() async {
        if (!pending.isCompleted) pending.complete();
        await jobs.cancel(task.id);
      });

      await tester.pumpWidget(_tray(jobs));
      await tester.pump();

      expect(
        find.text('2 个任务进行中（最新：出题中（2 个知识点））'),
        findsOneWidget,
      );
      // 列序仍是「提交顺序」（activeJobs 契约不变），只有摘要换了口吻。
      expect(jobs.activeJobs.first.label, '布置作业 · 编辑中（二叉树）');

      jobs.releaseInteractive(interactive);
    });

    testWidgets('离线行：橙色离线标、不给重试、行与锁都保留', (tester) async {
      final jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');
      final pending = Completer<void>();
      final task = jobs.runDetached(
        label: '出题中（2 个知识点）',
        resourceKey: 'homework:gen:b1',
        body: (t) => pending.future,
      );
      addTearDown(() async {
        if (!pending.isCompleted) pending.complete();
        await jobs.cancel(task.id);
      });

      await tester.pumpWidget(_tray(jobs));
      await tester.pump();

      // 复现「连续 5 次轮询失败」后的状态（service 侧 _scheduleBackoff 的产物）。
      final job = jobs.jobById(task.id)!;
      job.offline = true;
      task.progress(kAiJobOfflineMessage, percent: 0.4);
      await tester.pump();
      await _expand(tester);

      expect(find.text('离线'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsWidgets);
      expect(find.textContaining(kAiJobOfflineMessage), findsOneWidget);
      // 离线 ≠ 失败：没有重试按钮（它没失败，正在自己 5s 一次地重试）。
      expect(find.byTooltip('重试'), findsNothing);
      expect(find.byTooltip('移除'), findsNothing);
      // 锁还握着：服务端任务还在跑，放开会让用户重提并撞 409。
      expect(jobs.isLocked('homework:gen:b1'), isTrue);
      expect(find.textContaining('🔒 homework:gen:b1'), findsOneWidget);
    });

    testWidgets('done 行保留可见一段时长后自动消失', (tester) async {
      const window = Duration(milliseconds: 100);
      final jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');

      await tester.pumpWidget(_tray(jobs, doneVisible: window));
      await tester.pump();

      jobs.runDetached(
        label: '出题中（2 个知识点）',
        doneMessage: '作业已生成（2 份）',
        body: (t) async {},
      );
      await tester.pump(); // 执行体返回
      await tester.pump(); // 终态广播 + revision
      await _expand(tester);

      // 终态已落定，但行还在（用户回头要看得见「成了没有」）。
      expect(find.text('出题中（2 个知识点）'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsWidgets);

      // 真实时钟推进（runAsync 走的是墙上时间），再让假时钟走完保留窗口。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      expect(find.text('出题中（2 个知识点）'), findsNothing);
      expect(tester.getSize(find.byType(JobTray)).height, 0);

      // 收尾：让 SnackBar（3s）与自动折叠定时器都跑完，别留 pending timer。
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('取消闩锁（终态文案不误报「已完成」）', () {
    test('applyJson 对 cancel_requested 单调累积，服务端不回显也不清掉', () {
      final job = AiJob(
        id: 'j1',
        taskCode: 'T1',
        label: '批量补前置',
        resourceKey: 'tree:1',
      );
      expect(job.offline, isFalse);
      expect(job.finishedAt, isNull);

      job.applyJson(<String, dynamic>{'status': 'running', 'cancel_requested': true});
      expect(job.cancelRequested, isTrue);

      // 下一拍服务端不回显 cancel_requested：闩锁不能被清掉。
      job.applyJson(<String, dynamic>{
        'status': 'running',
        'stage': <String, dynamic>{'percent': 40, 'message': '还在跑'},
      });
      expect(job.cancelRequested, isTrue);
      expect(job.percent, closeTo(0.4, 1e-9));

      // T1/T3 不可中断：取消后仍会一路跑成 done —— 终态文案据此换成
      // 「已结束（该任务类型不支持中途取消）」。
      job.applyJson(<String, dynamic>{'status': 'done'});
      expect(job.status, AiJobStatus.done);
      expect(job.cancelRequested, isTrue);
    });
  });
}

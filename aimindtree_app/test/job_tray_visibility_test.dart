/// 任务托盘行语义回归测试（用户报的「看不懂队列 / 两行同名 / 一直不动 / 假失败」）。
///
/// 锁定的五条不变量：
///   1. **交互会话行不画进度条**，且**如实显示页面写进来的 message**
///      （旧实现把 `setInteractiveMessage` 的内容整段丢弃、硬编码一句
///      「会话已打开」→ AI 助手生成时托盘一个字都不动，用户判定「没在跑」）；
///   2. **折叠摘要 = 队列视图**：队首（带状态后缀）+「还有 N 个」（N 只数真实
///      任务；FIFO，只有真跑完一个才推进）+「会话：xxx」。交互会话不算队首
///      （它不排队、不占模型），但**必须被点名** —— 旧实现只给一句「另有会话
///      进行中」，用户看到的就是「一布置作业，前面开的会话全没了」；
///   3. **离线行不是失败行**：橙色 `cloud_off` 标、不给重试按钮、行与资源锁都
///      还在（服务端任务还在跑，锁放开会让用户重提撞 409）；
///   4. **done 行保留可见一段时长**再消失（默认 30s；测试注入小窗口 / 假时钟），
///      否则用户回头看不到「刚才那个成了没有」——10 秒太短，观感就是「任务
///      凭空消失」；
///   5. **「待启动」要说清在等谁**：点名通道当前持有者，而不是只写「第 N 位」。
///
/// 另加一条纯数据断言：`AiJob.cancelRequested` 是**单调闩锁** —— 服务端可能不回显
/// `cancel_requested`，而不支持中断的任务被取消后仍会一路跑成 done，只有记住这个
/// 闩锁，终态文案才不会误报「已完成」。
library;

import 'dart:async';

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ai/llm_channel.dart';
import 'package:aimindtree_app/ui/job_tray.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实时钟（[JobTray.now] 的默认值口径）。
DateTime _wallNow() => DateTime.now();

Widget _tray(
  AiJobService jobs, {
  Duration doneVisible = kJobTrayDoneVisible,
  DateTime Function()? now,
}) =>
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: JobTray(
            jobs: jobs,
            doneVisible: doneVisible,
            now: now ?? _wallNow,
          ),
        ),
      ),
    );

/// 展开托盘（收起态只有摘要，看不到行内细节）。
Future<void> _expand(WidgetTester tester) async {
  tester.state<JobTrayState>(find.byType(JobTray)).expand();
  await tester.pump();
}

void main() {
  // 通道是进程内单例，而每个 testWidgets 跑在各自的 FakeAsync zone 里：
  // 上一个用例挂起的执行体不会再有续体，会永久占住通道 → 后面的用例全卡在
  // 「排队中」。每条用例前复位。
  setUp(() {
    LlmChannel.instance.debugReset();
    // FakeAsync 里长 Timer 会被判成 pending timer → 关掉看门狗（仅为活性兜底，
    // 不影响本文件断言的任何行为）。
    LlmChannel.watchdogsEnabled = false;
  });

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

      // 页面写进去的话必须原样出现在托盘上（问题：AI 助手生成时托盘不动）。
      jobs.setInteractiveMessage(id, '第 1 轮：正在思考…');
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('第 1 轮：正在思考…'), findsOneWidget);
      // 旧实现那句硬编码文案必须彻底消失（它与实际状态无关）。
      expect(find.textContaining('会话已打开'), findsNothing);
      // 折叠态那条 4px 总进度条也不该出现（只有交互会话 = 没有进度可言）。
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      // 交互行也不显示累加计时（它没有任务耗时语义，一直涨会被误读成「卡死」）。
      expect(find.textContaining(RegExp(r'^\d+s$')), findsNothing);
    });

    testWidgets('折叠摘要 = 队首任务 + 会话点名（FIFO，不随状态跳）', (tester) async {
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
      await tester.pump();

      // 交互会话不算队首 → 队首是真正在跑的出题任务；会话另行**点名**。
      expect(find.textContaining('出题中（2 个知识点）'), findsOneWidget);
      expect(find.textContaining('会话：布置作业 · 编辑中（二叉树）'), findsOneWidget);
      // 旧实现那句不点名的空话必须彻底消失（它让用户以为会话没了）。
      expect(find.textContaining('另有会话进行中'), findsNothing);
      // 列序仍是「提交顺序」（activeJobs 契约不变），只有摘要换了口吻。
      expect(jobs.activeJobs.first.label, '布置作业 · 编辑中（二叉树）');

      jobs.releaseInteractive(interactive);
    });

    // 用户原话：「我一布置作业，托盘就不显示前面任务了，就显示现在这个作业，
    // 但是叫做待启动。」实际顺序：开老师模式 → 开 AI 助手 → 点「出题」。
    // 三个任务同时存在时，摘要必须让三样都看得见：队首、「待启动」、两个会话名。
    testWidgets('用户复现：两个会话 + 排队的出题任务，摘要三样都点名', (tester) async {
      final jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');
      final teacher = jobs.holdInteractive('kp:1', label: '老师模式：函数连续性');
      final agent = jobs.holdInteractive('agent:chat', label: 'AI 助手：回答中');
      addTearDown(() {
        jobs.releaseInteractive(teacher);
        jobs.releaseInteractive(agent);
      });
      // 通道被老师模式的生成占着 → 「出题」只能排队，状态就是「待启动」。
      final ticket =
          await LlmChannel.instance.acquire(label: '老师模式：正在生成讲解');
      addTearDown(ticket.release);
      final pending = Completer<void>();
      final task = jobs.runDetached(
        label: '出题中（1 个知识点）',
        body: (t) => pending.future,
      );
      addTearDown(() async {
        if (!pending.isCompleted) pending.complete();
        await jobs.cancel(task.id);
      });

      await tester.pumpWidget(_tray(jobs));
      await tester.pump();
      await tester.pump();

      // ① 队首（就是用户眼里「现在这个作业」）在；
      expect(find.textContaining('出题中（1 个知识点）'), findsOneWidget);
      // ② 它的状态后缀说清楚还没开跑；
      expect(find.textContaining('（待启动）'), findsOneWidget);
      // ③ **前面的两个会话没消失**，被点名叫出来了（旧实现这里只剩一句
      //    「另有会话进行中」，用户判定「前面的任务没了」）。
      expect(find.textContaining('老师模式：函数连续性'), findsOneWidget);
      expect(find.textContaining('AI 助手：回答中'), findsOneWidget);
      expect(find.textContaining('会话：'), findsOneWidget);
      expect(find.textContaining('另有会话进行中'), findsNothing);
      // 只有一个真实任务 → 不写「还有 0 个」。
      expect(find.textContaining('还有'), findsNothing);
    });

    testWidgets('折叠摘要：只有交互会话时点名它们，而不是空白', (tester) async {
      final jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');
      final teacher = jobs.holdInteractive('kp:1', label: '老师模式：函数连续性');
      final agent = jobs.holdInteractive('agent:chat', label: 'AI 助手：回答中');
      addTearDown(() {
        jobs.releaseInteractive(teacher);
        jobs.releaseInteractive(agent);
      });

      await tester.pumpWidget(_tray(jobs));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('进行中：'), findsOneWidget);
      expect(find.textContaining('老师模式：函数连续性'), findsOneWidget);
      expect(find.textContaining('AI 助手：回答中'), findsOneWidget);
      expect(find.textContaining('另有会话进行中'), findsNothing);
    });

    testWidgets('折叠摘要：「还有 N 个」只数真实任务，会话不混进计数', (tester) async {
      final jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');
      final session = jobs.holdInteractive('kp:1', label: '老师模式：函数连续性');
      addTearDown(() => jobs.releaseInteractive(session));
      final ticket = await LlmChannel.instance.acquire(label: '前一个任务');
      addTearDown(ticket.release);
      // 3 个真实任务全在队里（通道被手工占住，谁都不许开跑）。
      for (var i = 1; i <= 3; i++) {
        final gate = Completer<void>();
        final task = jobs.runDetached(
          label: '出题中（$i 个知识点）',
          body: (t) => gate.future,
        );
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          await jobs.cancel(task.id);
        });
      }

      await tester.pumpWidget(_tray(jobs));
      await tester.pump();
      await tester.pump();

      // 队首 + 还有 2 个（不含那 1 个会话）+ 会话点名。
      expect(find.textContaining('出题中（1 个知识点）（待启动）'), findsOneWidget);
      expect(find.textContaining('还有 2 个'), findsOneWidget);
      expect(find.textContaining('会话：老师模式：函数连续性'), findsOneWidget);
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

    testWidgets('任务排队：后提交的是「待启动 · 第 1 位」，前一个跑完才开跑', (tester) async {
      final jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');
      final gate = Completer<void>();
      var secondStarted = false;
      final first = jobs.runDetached(label: '任务A', body: (t) => gate.future);
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await jobs.cancel(first.id);
      });
      await tester.pump(); // A 拿到通道
      expect(jobs.jobById(first.id)!.status, AiJobStatus.running);

      final second = jobs.runDetached(
        label: '任务B',
        body: (t) async => secondStarted = true,
      );
      addTearDown(() => jobs.cancel(second.id));
      await tester.pump();

      // ② 后提交的**不跑**，先排队（这就是「不挤占前一个」）
      expect(secondStarted, isFalse);
      expect(jobs.jobById(second.id)!.status, AiJobStatus.queued);

      await tester.pumpWidget(_tray(jobs));
      await tester.pump();
      await _expand(tester);
      expect(find.text('待启动'), findsOneWidget);
      // 「待启动」必须说清在等谁：持有者（跑着的那条）的名字要出现在文案里。
      expect(find.textContaining('待启动 · 第 1 位（等「任务A」用完模型）'),
          findsOneWidget);

      // ③ 前一个放行 → 后一个自动开跑
      gate.complete();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(secondStarted, isTrue);
      expect(jobs.jobById(second.id)!.status, AiJobStatus.done);
    });

    testWidgets('排队行说清在等谁：点名通道当前持有者', (tester) async {
      final jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');
      // 手工占住通道（等价于「老师模式正在分析对话中的知识点建议」占着模型）。
      // 只借 acquire/release 这对公开 API，不碰通道的私有状态。
      final ticket =
          await LlmChannel.instance.acquire(label: '分析对话中的知识点建议');
      addTearDown(ticket.release);

      final gate = Completer<void>();
      final task = jobs.runDetached(
        label: '出题中（1 个知识点）',
        body: (t) => gate.future,
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await jobs.cancel(task.id);
      });
      await tester.pump();
      expect(jobs.jobById(task.id)!.status, AiJobStatus.queued);

      await tester.pumpWidget(_tray(jobs));
      await tester.pump();
      await _expand(tester);

      expect(find.textContaining('第 1 位'), findsOneWidget);
      expect(
        find.textContaining('等「分析对话中的知识点建议」用完模型'),
        findsOneWidget,
      );
      // 拿不到持有者名字时才退回旧文案 —— 这里不该出现。
      expect(find.textContaining('等前面的任务用完模型'), findsNothing);
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

    // 10 秒太短：用户被 SnackBar 引开一眼、回神时那一行已经没了 → 观感就是
    // 「任务消失了」。这里锁定 30 秒窗口，并显式验证「越过 10 秒仍在、越过
    // 30 秒才消失」。
    //
    // 时钟注入口的存在理由：`pump(Duration)` 推的是 FakeAsync 假时钟，而生产
    // 代码直接用 `DateTime.now()`（墙上时间）—— 两者不同步，否则这一条测试得
    // 真等 31 秒墙钟。注入 `now` 后，「读到的现在」与 pump 一起走。
    testWidgets('done 行默认保留 30 秒：越过 10 秒仍在，30 秒后才消失', (tester) async {
      expect(kJobTrayDoneVisible, const Duration(seconds: 30));

      var fakeNow = DateTime.now();
      final jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');

      await tester.pumpWidget(_tray(jobs, now: () => fakeNow));
      await tester.pump();

      jobs.runDetached(
        label: '出题中（2 个知识点）',
        doneMessage: '作业已生成（2 份）',
        body: (t) async {},
      );
      await tester.pump(); // 执行体返回
      await tester.pump(); // 终态广播 + revision
      await _expand(tester);
      expect(find.text('出题中（2 个知识点）'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);

      // 12 秒：旧窗口（10s）下这里已经消失 —— 用户报的「任务没了」就是这个点。
      fakeNow = fakeNow.add(const Duration(seconds: 12));
      await tester.pump(const Duration(seconds: 12));
      expect(find.text('出题中（2 个知识点）'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);

      // 29 秒：仍在窗口内。
      fakeNow = fakeNow.add(const Duration(seconds: 17));
      await tester.pump(const Duration(seconds: 17));
      expect(find.text('出题中（2 个知识点）'), findsOneWidget);

      // 31 秒（越过 30 秒窗口）：行消失、托盘收起成 0 高。
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
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

/// 全局 LLM 单通道验收测试。
///
/// 锁定的不变量（用户报「一个任务提出就把前一个挤掉 / 托盘一下这个一下那个」）：
///   1. **同一时刻只有一个真实请求打到模型**：两个 `ai.chat` 并发发起时，
///      provider 侧观测到的最大并发数必须恒为 1（改造前会是 2 —— llama.cpp
///      只有一个 slot，两路一起发就是互相拖慢、更容易超时）；
///   2. **FIFO**：先来先放行，后到的排队等前面释放，不会被"插队"或"顶掉"；
///   3. **排队位次可查**：托盘据此显示「排队中 · 第 N 位」；
///   4. **取消排队**：任务还在队尾时被取消 → 立刻出队，不占位次；
///   5. **后台任务 zone 免二次排队**：`runDetached` 执行体内部再调 `ai.chat`
///      不会自己把自己锁死（否则每个后台任务都会永久卡在排队）。
///
/// 这些断言都在**旧实现**上结构性地不可能通过：旧 `AiService.chat` 没有任何
/// 互斥，两个并发调用的 provider 并发数会是 2。
library;

import 'dart:async';

import 'package:aimindtree_app/ai/ai_provider.dart';
import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/llm_channel.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录并发数的假 Provider。
///
/// 每次 `streamChat` 开始时 `active++`、结束时 `active--`；`maxActive` 是
/// 整个测试期间同时进行的最大请求数 —— 这就是「有没有同时打模型」的直接证据。
class _ConcurrencyProbe implements AiProvider {
  _ConcurrencyProbe({this.holdMs = 20});

  /// 每个请求人为占用这么久，制造确定的重叠窗口。
  final int holdMs;

  int active = 0;
  int maxActive = 0;
  int started = 0;
  final List<String> order = <String>[];

  @override
  String get id => 'probe';

  @override
  String get protocol => 'probe';

  @override
  Stream<AiChunk> streamChat(
    String query, {
    String? conversationId,
    String? user,
    Duration timeout = const Duration(seconds: 900),
    AiTask? task,
    String? variant,
    String? jobId,
  }) async* {
    started++;
    active++;
    if (active > maxActive) maxActive = active;
    order.add(query);
    try {
      await Future<void>.delayed(Duration(milliseconds: holdMs));
      yield AiChunk(delta: 'ok:$query', done: true);
    } finally {
      active--;
    }
  }

  @override
  Future<AiTaskResult> runTask(
    AiTask task,
    Map<String, dynamic> inputs, {
    String? user,
    Duration timeout = const Duration(seconds: 900),
    String? variant,
  }) async =>
      const AiTaskResult(content: '{}');

  @override
  void dispose() {}
}

AiService _service(_ConcurrencyProbe probe) => AiService(
      router: AiTaskRouter(providers: const {}, fallback: probe),
    );

/// 把一条 chat 流抽干，返回拼起来的正文。
Future<String> _drain(Stream<AiChunk> stream) async {
  final buf = StringBuffer();
  await for (final c in stream) {
    if (c.delta != null) buf.write(c.delta);
  }
  return buf.toString();
}

void main() {
  setUp(() {
    LlmChannel.instance.debugReset();
    LlmChannel.watchdogsEnabled = false;
  });
  tearDown(() {
    LlmChannel.instance.debugReset();
    LlmChannel.watchdogsEnabled = true;
  });

  test('两个并发 chat 不会同时打到模型（maxActive 恒为 1）', () async {
    final probe = _ConcurrencyProbe(holdMs: 30);
    final ai = _service(probe);

    Future<String> run(String q) async {
      final buf = StringBuffer();
      await for (final c in ai.chat(AiTask.t5Ask, q)) {
        if (c.delta != null) buf.write(c.delta);
      }
      return buf.toString();
    }

    // 同时发起两个请求（旧实现这里会 maxActive == 2）。
    final results = await Future.wait(<Future<String>>[run('甲'), run('乙')]);

    expect(probe.maxActive, 1, reason: '同一时刻只能有一个请求在模型上');
    expect(probe.started, 2);
    expect(results, <String>['ok:甲', 'ok:乙']); // FIFO：先发起的先跑完
    expect(probe.order, <String>['甲', '乙']);
  });

  test('排队位次可查：第二个请求在队列里是第 1 位', () async {
    final probe = _ConcurrencyProbe(holdMs: 40);
    final ai = _service(probe);

    final first = ai.chat(AiTask.t5Ask, '甲').toList();
    // 让第一个请求先进入 provider（拿到通道）。
    await Future<void>.delayed(const Duration(milliseconds: 5));

    final second = ai.chat(AiTask.t5Ask, '乙').toList();
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(LlmChannel.instance.isBusy, isTrue);
    expect(LlmChannel.instance.waitingCount, 1);

    await first;
    await second;
    expect(probe.maxActive, 1);
  });

  test('后台任务 zone 内再调 ai.chat 不会自锁（免二次排队）', () async {
    final probe = _ConcurrencyProbe(holdMs: 10);
    final ai = _service(probe);

    // 模拟 runDetached：外层执行体已经拿到通道。
    final outer =
        await LlmChannel.instance.acquire(label: '作业生成', jobId: 'job-a');
    expect(outer.granted, isTrue);
    expect(LlmChannel.instance.isBusy, isTrue);

    // 执行体跑在带 zone 标记的 zone 里 —— 它内部再调 ai.chat 必须立刻放行，
    // 否则就是「持有通道的人排队等自己释放」→ 永久死锁（旧改造最易踩的坑）。
    final inner = await runZoned(
      () => _drain(ai.chat(AiTask.t5Ask, '内层')),
      zoneValues: <Object, Object>{kLlmChannelZoneKey: 'job-a'},
    );
    expect(inner, 'ok:内层');
    expect(LlmChannel.instance.waitingCount, 0, reason: 'zone 内不该产生等待者');
    expect(probe.maxActive, 1);

    outer.release();
    expect(LlmChannel.instance.isBusy, isFalse);
  });

  test('排队中被取消：立刻出队且不占位次', () async {
    final probe = _ConcurrencyProbe(holdMs: 30);
    final ai = _service(probe);

    // 第一个请求先占住通道。
    final first = _drain(ai.chat(AiTask.t5Ask, '甲'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(LlmChannel.instance.isBusy, isTrue);

    // 不 await：这张票要等第一个请求释放才可能被放行，先只观察位次。
    final pending =
        LlmChannel.instance.acquire(label: '任务B', jobId: 'job-b');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(LlmChannel.instance.positionOf('job-b'), 1);

    LlmChannel.instance.cancelWait('job-b');
    expect(LlmChannel.instance.positionOf('job-b'), isNull);

    // 被取消的等待者会被唤醒（不会悬挂），且拿到的票没有真正占用通道。
    final ticket = await pending;
    expect(ticket.granted, isFalse);
    ticket.release();

    expect(await first, 'ok:甲');
    expect(LlmChannel.instance.isBusy, isFalse);
    expect(LlmChannel.instance.waitingCount, 0);
  });
}

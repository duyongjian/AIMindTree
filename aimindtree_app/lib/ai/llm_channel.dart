/// 全局 LLM 单通道（FIFO）：一次只放行**一个**真实请求到模型。
///
/// 为什么需要它：llama.cpp 只有一个可用 slot（`config.yaml` `concurrency: 1`，
/// 27B 权重已经把 8GB 显存吃满），但 App 侧此前有三条互不相识的通路会同时
/// 向 `/chat` 发请求：
/// 1. `runDetached` 的后台执行体（作业、提取、延伸讲解）—— 登记即开跑；
/// 2. 页面里的裸流（AI 助手问答、老师模式追问）—— 直接 `await for`；
/// 3. 服务端队列任务（`/v1/jobs`，由服务端 worker 执行）。
///
/// 三路并发压同一个模型 → 每路都变慢、更容易超时，用户观感就是「新任务把
/// 前一个挤掉了」。本类把 1、2 两路（以及 3 的**在跑**状态）统一到一条
/// FIFO 通道上：先来先跑，后来的显示「排队中 · 第 N 位」，前一个放行后
/// 才开始发请求。
///
/// 约定：
/// - 通道只在 `AiService.chat` / `AiService.run` 的真实请求期间持有（
///   工具执行、审批弹框、写库这些不占模型的时间不占通道）；
/// - `runDetached` 的执行体内部调用 `ai.chat` 时，凭 [kLlmChannelZoneKey]
///   的 zone 标记**跳过二次排队**（否则自己把自己锁死）；
/// - 值一律是「观测用」的：[revision] 变化只影响托盘重绘。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/logger.dart';

/// zone 标记：值为持有通道的 job id。
///
/// `runDetached` 的执行体跑在这个 zone 里，于是它内部的 `ai.chat` 知道
/// 「通道已经由本任务持有」，不必也不能再排一次队。
const Object kLlmChannelZoneKey = #aimindtreeLlmChannel;

/// 等通道的最长时限：超过就直接放行并在日志里留痕。
///
/// 这是**活性兜底**，不是策略：正常情况下服务端任务都有超时，通道一定会被
/// 放行；万一 [LlmChannel.externalBusy] 因为状态没刷新而假占，没有这道闸
/// 就会把用户所有对话永久卡在「排队中」。
const Duration kLlmChannelMaxWait = Duration(minutes: 10);

/// 单个请求最长持有通道的时间：超过就强制放行并留痕。
///
/// 同样是活性兜底。真实风险是「持有者卡住永不释放」（执行体挂在某个永不
/// 完成的 Future 上、或所在 zone 已销毁），那会把后来所有请求永久堵死。
/// 15 分钟的模型请求超时（`AiService` 默认 timeout=900s）远小于这个值。
const Duration kLlmChannelMaxHold = Duration(minutes: 40);

/// 一次通行证。[release] 必须且只能调用一次（放行下一个）。
class LlmTicket {
  LlmTicket._(this._channel, this._waiter);

  final LlmChannel _channel;
  final _Waiter? _waiter;
  bool _released = false;

  /// true = 真的拿到了通道；false = 天然免排队（已在任务 zone 内）。
  bool get granted => _waiter?.granted ?? true;

  void release() {
    if (_released) return;
    _released = true;
    _channel._release(this);
  }
}

class _Waiter {
  _Waiter({
    required this.ticket,
    required this.label,
    required this.jobId,
  });

  final int ticket;
  final String label;
  final String? jobId;
  final Completer<void> completer = Completer<void>();
  bool granted = false;
  bool canceled = false;
  Timer? deadline;
}

/// 通道本体（进程内单例）。
class LlmChannel {
  LlmChannel._();

  static final LlmChannel instance = LlmChannel._();

  /// 是否启用两个活性看门狗（等待超时 / 持有超时）。
  ///
  /// 测试里必须关掉：widget 测试跑在 FakeAsync 中，一个 40 分钟的 `Timer`
  /// 会被判成 "pending timer" 直接让用例失败。生产恒为 true。
  static bool watchdogsEnabled = true;

  static final AppLog _log = AppLog('llm_channel');

  final List<_Waiter> _queue = <_Waiter>[];
  _Waiter? _holder;
  Timer? _holdWatchdog;
  int _seq = 0;

  /// 任何队列变化（入队 / 放行 / 释放 / 外部占用变化）+1。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 外部占用探测：由 [AiJobService] 注入 —— 服务端队列任务是否正在跑。
  ///
  /// 服务端任务在服务端执行，本进程看不见它的执行体，只能靠轮询到的
  /// `status == running` 判断「模型此刻被它占着」。
  bool Function()? externalBusy;

  /// 当前是否有请求真正跑在模型上。
  bool get isBusy => _holder != null;

  /// 正在跑的请求名（托盘展示「当前：xxx」）。
  String? get holderLabel => _holder?.label;

  /// 排队等待的数量（不含正在跑的）。
  int get waitingCount => _queue.length;

  /// 某个 job 的排队位次（1 = 下一个放行）；不在队里返回 null。
  int? positionOf(String jobId) {
    if (jobId.isEmpty) return null;
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].jobId == jobId) return i + 1;
    }
    return null;
  }

  /// 申请通道。返回的 [LlmTicket] 必须在 finally 里 release。
  ///
  /// [jobId] 非空时可在托盘上反查位次，也可被 [cancelWait] 取消。
  Future<LlmTicket> acquire({
    required String label,
    String? jobId,
  }) async {
    // 已经在某个后台任务的 zone 里 → 通道本来就是它持有的，直接给票。
    if (Zone.current[kLlmChannelZoneKey] != null) {
      return LlmTicket._(this, null);
    }
    _seq++;
    final w = _Waiter(ticket: _seq, label: label, jobId: jobId);
    _queue.add(w);
    if (watchdogsEnabled) w.deadline = Timer(kLlmChannelMaxWait, () {
      if (w.granted || w.canceled) return;
      _queue.remove(w);
      _log.w('等通道超过 ${kLlmChannelMaxWait.inMinutes} 分钟，强制放行：${w.label}');
      _grant(w);
    });
    _notify();
    _pump();
    await w.completer.future;
    return LlmTicket._(this, w);
  }

  /// 取消某个 job 的排队（任务在被放行前就被用户取消）。
  void cancelWait(String jobId) {
    if (jobId.isEmpty) return;
    final i = _queue.indexWhere((w) => w.jobId == jobId);
    if (i < 0) return;
    final w = _queue.removeAt(i);
    w.canceled = true;
    w.deadline?.cancel();
    if (!w.completer.isCompleted) w.completer.complete();
    _notify();
    _pump();
  }

  /// 服务端任务状态变化后调用，让被它挡住的本进程请求重新评估。
  void notifyExternalChanged() {
    _notify();
    _pump();
  }

  // ---- 内部 ----

  bool _externallyBusy() {
    final probe = externalBusy;
    if (probe == null) return false;
    try {
      return probe();
    } on Object {
      return false;
    }
  }

  void _pump() {
    if (_holder != null) return;
    if (_queue.isEmpty) return;
    if (_externallyBusy()) return;
    final w = _queue.removeAt(0);
    if (w.canceled) {
      _pump();
      return;
    }
    _grant(w);
  }

  void _grant(_Waiter w) {
    w.deadline?.cancel();
    w.deadline = null;
    w.granted = true;
    _holder = w;
    _holdWatchdog?.cancel();
    if (watchdogsEnabled) {
      _holdWatchdog = Timer(kLlmChannelMaxHold, () {
        if (!identical(_holder, w)) return;
        _log.w('通道持有超 ${kLlmChannelMaxHold.inMinutes} 分钟，强制放行：${w.label}');
        _holder = null;
        _notify();
        _pump();
      });
    }
    if (!w.completer.isCompleted) w.completer.complete();
    _notify();
  }

  void _release(LlmTicket ticket) {
    final w = ticket._waiter;
    if (w == null) return; // 免排队票，没有占用真实通道
    if (identical(_holder, w)) {
      _holder = null;
      _holdWatchdog?.cancel();
      _holdWatchdog = null;
    }
    _notify();
    _pump();
  }

  /// 仅测试用：清空队列与持有者。
  ///
  /// 单例跨 `testWidgets` 存活，而每个 widget 测试跑在各自的 FakeAsync zone
  /// 里 —— 上一个测试挂起的执行体不会再有续体，通道会被永久占住，后续用例
  /// 全部卡在「排队中」。测试 `setUp` 调它做隔离。
  @visibleForTesting
  void debugReset() {
    for (final w in _queue) {
      w.deadline?.cancel();
      if (!w.completer.isCompleted) w.completer.complete();
    }
    _queue.clear();
    _holder = null;
    _holdWatchdog?.cancel();
    _holdWatchdog = null;
    revision.value = revision.value + 1;
  }

  void _notify() {
    // 合流到微任务：通道常在 build 阶段被 acquire（页面 initState 里发请求），
    // 同步 notifyListeners 会触发「setState during build」。
    scheduleMicrotask(() {
      revision.value = revision.value + 1;
    });
  }
}

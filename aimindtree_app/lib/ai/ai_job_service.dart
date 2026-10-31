/// AI 任务队列客户端（服务端 ``POST /v1/jobs``，方案 docs/TASK_QUEUE_PLAN.md）。
///
/// 解决「点一个 AI 功能就被钉在界面里等 18 秒」：提交即返回，进度靠 800ms
/// 轮询推进，结果经 ``onDone/onError`` 回投；资源锁（``tree:{id}`` 等）在
/// 提交时占用、终态释放，互斥判定只此一处（方案 §6.4）。
///
/// 三条边界：
/// - **开关**：``kAiJobQueueEnabled=false`` → 所有 ``submit`` 返回 null，
///   调用方退回原同步阻塞路径（零数据迁移回滚，方案 §8.4）；
/// - **降级**：提交抛异常（服务没起）→ 调用方自行决定同步兜底或报错；
///   轮询连续失败 5 次 → 进**离线态**（``offline=true``、锁继续持有、5s 固定
///   间隔一直重试到恢复，**不判终态**）；轮到 404 → 标
///   ``failed(服务已重启，请重试)``（方案 §8.2/8.3）；
/// - **密钥边界**：只走本地 ``127.0.0.1:8787``，请求体不带任何密钥字段。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ai_provider.dart';
import 'clients/llm_server_client.dart' show LlmServerException;
import '../core/logger.dart';

/// 队列总开关：false = 全部调用点退回同步阻塞路径（回滚用）。
const bool kAiJobQueueEnabled = true;

/// 进行中轮询间隔（方案 §5.1）。
const Duration kAiJobPollInterval = Duration(milliseconds: 800);

/// 轮询失败退避序列（封顶 5s）。
const List<Duration> kAiJobPollBackoff = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
];

/// 连续轮询失败上限 → 进**离线态**（不是失败）。
///
/// 判死会把「网络抖一下」变成「任务没了 + 锁释放 + 重提 409」的假失败：
/// 服务端那边任务其实还在跑。所以达上限只改「怎么等」，不改「还在不在」。
const int kAiJobMaxPollFailures = 5;

/// 离线态的重试间隔：不再退避，固定 5s 一直试到恢复或服务端明确 404。
const Duration kAiJobOfflineRetryInterval = Duration(seconds: 5);

/// 离线态固定文案（托盘原样展示；恢复后由服务端快照覆盖）。
const String kAiJobOfflineMessage = '与服务端失联，重试中…';

/// App 侧终态保留条数（托盘历史；服务端另有 200 条环）。
const int kAiJobMaxRecent = 50;

/// 把 T1/T3 job 的 ``result`` payload 转成 [AiTaskResult]（服务端
/// ``/v1/task`` 同构字段：content / parsed / usage / latency_ms / model_id）。
AiTaskResult aiTaskResultFromJob(Map<String, dynamic> result) {
  final usage = result['usage'];
  return AiTaskResult(
    content: (result['content'] as String?) ?? '',
    parsed: result['parsed'],
    usage: usage is Map ? Map<String, dynamic>.from(usage) : null,
    latencyMs: (result['latency_ms'] as num?)?.toInt() ?? 0,
    modelId: result['model_id'] as String?,
  );
}

/// 任务被用户取消（[DetachedTask.throwIfCanceled] 抛出）。
///
/// 执行体一律**不要**捕获它当作失败：`_runDetachedBody` 会看
/// `job.cancelRequested` 把它归类成 canceled 而非 failed。
class TaskCanceledException implements Exception {
  const TaskCanceledException();

  @override
  String toString() => '任务已取消';
}

enum AiJobStatus { queued, running, done, failed, canceled;

  bool get isActive => this == AiJobStatus.queued || this == AiJobStatus.running;

  static AiJobStatus parse(String? raw) => switch (raw) {
        'running' => AiJobStatus.running,
        'done' => AiJobStatus.done,
        'failed' => AiJobStatus.failed,
        'canceled' => AiJobStatus.canceled,
        _ => AiJobStatus.queued,
      };
}

/// 一个异步 AI 任务（App 侧视图 + 原始提交参数，retry 用）。
class AiJob {
  AiJob({
    required this.id,
    required this.taskCode,
    required this.label,
    required this.resourceKey,
    this.inputs = const <String, dynamic>{},
    this.query,
    this.variant,
    this.stages = const <String>[],
    this.keepLockOnDone = false,
    this.silent = false,
    this.interactive = false,
    this.detached = false,
    this.doneMessage,
    this.onDone,
    this.onError,
    this.onCancel,
  });

  /// 从服务端快照重建（冷启动对账用；**无回调**，完成只进托盘）。
  factory AiJob.fromJson(Map<String, dynamic> json) {
    return AiJob(
      id: (json['job_id'] as String?) ?? '',
      taskCode: (json['task'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      resourceKey: (json['resource_key'] as String?) ?? '',
    )..applyJson(json);
  }

  final String id;
  final String taskCode;
  final String label;
  final String resourceKey;

  /// 原始提交参数（retry 原样重放）。
  final Map<String, dynamic> inputs;
  final String? query;
  final String? variant;
  final List<String> stages;

  /// true = done 时不释放资源锁（复合流水线的中间 job，方案 §11.1）。
  final bool keepLockOnDone;

  /// true = 静默任务（如对话检测）：托盘可见计时与锁徽标，但终态不弹
  /// SnackBar（增强型后台功能不打扰主流程，方案 §5.3 C4）。
  final bool silent;

  /// true = 交互通道会话（B4：T6/T7/T8 流式，不走队列）合成的托盘行：
  /// 无服务端 id、锁随会话页生命周期持有。「取消」由页面注册的
  /// [interrupt] 处理（页面已销毁时取消是空操作，锁随页面释放）。
  final bool interactive;

  /// true = App 侧执行体的后台任务（[AiJobService.runDetached] 登记）：
  /// 无服务端 id，取消靠 [DetachedTask.isCanceled] 让执行体自己收尾，
  /// 结果由执行体写库 —— **页面销毁不影响它跑完**。
  final bool detached;

  /// 服务端**外部任务** id（[AiJobService.registerExternal] 登记后回填）。
  /// 用于让服务端持有这个 App 本地驱动任务的状态实体 + 心跳看门狗
  /// （App 被强杀 → 服务端超时标 failed，不再「人間蒸发」）。空 = 未登记
  /// （老服务不支持 / 服务没起，本地流程不受影响）。
  String? serverJobId;

  /// 托盘「取消」调用的中断回调（交互会话 / 后台任务用；队列任务走服务端）。
  VoidCallback? interrupt;

  /// App 侧回调（页面还活着就刷新；页面已销毁则只进托盘）。
  final void Function(AiJob)? onDone;
  final void Function(Object error)? onError;
  final VoidCallback? onCancel;

  /// 完成时托盘/SnackBar 展示的摘要（调用方生成，如「已收录 3 个知识点」）。
  /// 可变：onDone 回调里可以补写最终摘要（如「已收录 3 个，连线 2 条」），
  /// 托盘在终态广播时读取。
  String? doneMessage;

  AiJobStatus status = AiJobStatus.queued;
  int stageIndex = 1;
  int stageTotal = 1;
  String stageTask = '';
  double percent = 0; // 0..1
  String message = '排队中…';
  bool cancelRequested = false;
  Map<String, dynamic>? result;
  String? errorCode;
  String? errorMessage;
  bool retryable = false;
  DateTime submittedAt = DateTime.now();
  DateTime? startedAt;

  /// 终态落定时刻（[AiJobService._onTerminal] 写入）。
  ///
  /// 托盘据此把 done 行**再保留 10 秒**（``kJobTrayDoneVisible``）—— 用户回头
  /// 才看得见「刚才那个成了没有」，否则 done 一落地行就消失，等于没有反馈。
  DateTime? finishedAt;

  /// 轮询连续失败达上限后的「离线」标记。
  ///
  /// **任务仍在服务端跑**，只是本机暂时拿不到快照：true 时托盘显示橙色离线标
  /// （不是失败红条、不给重试按钮）、资源锁继续持有、轮询以
  /// [kAiJobOfflineRetryInterval] 固定 5s 继续重试；任一次成功即恢复。
  bool offline = false;

  bool get isActive => status.isActive;

  /// 已用时长（本地计时，服务重启后从 startedAt 续）。
  Duration get elapsed {
    final from = startedAt ?? submittedAt;
    return DateTime.now().difference(from);
  }

  String get elapsedText {
    final s = elapsed.inSeconds;
    return s < 60 ? '${s}s' : '${s ~/ 60}m${(s % 60).toString().padLeft(2, '0')}s';
  }

  /// 进度条取值：null = 不确定态（等模型的阶段只走计时，不假报，方案 §4.4 铁律）。
  double? get progressOrNull =>
      status == AiJobStatus.done ? 1.0 : (percent > 0 ? percent : null);

  void applyJson(Map<String, dynamic> json) {
    status = AiJobStatus.parse(json['status'] as String?);
    final stage = json['stage'];
    if (stage is Map) {
      stageIndex = (stage['index'] as num?)?.toInt() ?? 1;
      stageTotal = (stage['total'] as num?)?.toInt() ?? 1;
      stageTask = (stage['task'] as String?) ?? taskCode;
      percent = ((stage['percent'] as num?)?.toDouble() ?? 0) / 100.0;
      message = (stage['message'] as String?) ?? message;
    }
    // 「用户点过取消」是**单调闩锁**：服务端可能不回显 cancel_requested，
    // 而 T1/T3 这类不可中断的任务被取消后仍会一路跑成 done —— 只有记住
    // 这个闩锁，终态文案才不会误报「已完成」（见 job_tray 的 _onTerminal）。
    if (json['cancel_requested'] == true) cancelRequested = true;
    final res = json['result'];
    result = res is Map ? Map<String, dynamic>.from(res) : null;
    final err = json['error'];
    if (err is Map) {
      errorCode = err['code'] as String?;
      errorMessage = err['message'] as String?;
      retryable = err['retryable'] == true;
    }
    final started = json['started_at'];
    if (started is num && startedAt == null) {
      startedAt = DateTime.fromMillisecondsSinceEpoch((started * 1000).toInt());
    }
  }
}

/// 任务队列服务（单例，bootstrap 装配，AppShell 挂托盘）。
class AiJobService {
  AiJobService({required this.baseUrl, HttpClient? client})
      // 只与本机 llm_server 通信：强制不走系统代理（否则本机 HTTP_PROXY 会
      // 把 127.0.0.1 请求发往代理而「假连不上」，队列提交失败→回落同步→
      // 后台 M10 看不到任务）。对齐服务端 trust_env=false。
      : _client = client ?? (HttpClient()..findProxy = (Uri uri) => 'DIRECT');

  /// 形如 ``http://127.0.0.1:8787``（来自 llm_server provider 行 / 内置默认）。
  final String baseUrl;
  final HttpClient _client;

  static final AppLog _log = AppLog('ai_jobs');

  /// 未终态 job（含对账收养的）。
  final Map<String, AiJob> _jobs = <String, AiJob>{};

  /// 终态 job（新的在前，封顶 [kAiJobMaxRecent]）。
  final List<AiJob> _recent = <AiJob>[];

  /// 资源锁表：resourceKey → jobId（队列通道）。
  final Map<String, String> _locks = <String, String>{};

  /// 交互通道锁（B4：T6/T8 流式会话登记），resourceKey → holderId。
  final Map<String, String> _interactive = <String, String>{};

  final Map<String, Timer> _timers = <String, Timer>{};
  final Map<String, int> _failCount = <String, int>{};

  /// 修订号：任何 job 状态变化 +1（托盘 / 页面内联进度订阅它）。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 通知合流锁：把修订号 +1 延后到微任务，避免在 build 阶段（如
  /// ``TeacherPage.initState`` 调 ``holdInteractive``）同步 ``setState`` 触发
  /// 「setState during build」断言（P0-1 黑屏根因）。托盘内容读 ``_jobs``
  /// 映射而非 ``revision.value``，所以延后一帧无语义损失。
  bool _notifyScheduled = false;

  /// 终态广播（托盘据此弹 SnackBar）。
  final StreamController<AiJob> _terminal =
      StreamController<AiJob>.broadcast();
  Stream<AiJob> get terminalStream => _terminal.stream;

  /// 托盘展开请求（AppShell 的 JobTray 挂上；被挡操作的「查看任务」用）。
  void Function()? onExpandTray;
  void requestExpandTray() => onExpandTray?.call();

  String get _apiBase =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  // ==================== 提交 / 取消 / 重试 ====================

  /// 提交任务。返回 null = 资源锁被占（调用方提示「有任务在进行」）；
  /// 抛异常 = 服务不可达（调用方走同步兜底或报错）。
  Future<AiJob?> submit({
    required String task,
    required String resourceKey,
    required String label,
    List<String> stages = const <String>[],
    Map<String, dynamic> inputs = const <String, dynamic>{},
    String? query,
    String? variant,
    bool keepLockOnDone = false,
    bool silent = false,
    String? doneMessage,
    void Function(AiJob)? onDone,
    void Function(Object error)? onError,
    VoidCallback? onCancel,
  }) async {
    if (!kAiJobQueueEnabled) return null;
    final key = resourceKey.trim();
    if (key.isNotEmpty && isLocked(key)) {
      _log.i('资源锁被占，拒绝提交：$key（$label）');
      return null;
    }
    final body = <String, dynamic>{
      'task': task,
      'label': label,
      'resource_key': key,
      'idempotency_key': _uuid(),
      'user': 'aimindtree-app',
      if (stages.isNotEmpty) 'stages': stages,
      if (inputs.isNotEmpty) 'inputs': inputs,
      if (query != null && query.isNotEmpty) 'query': query,
      if (variant != null && variant.isNotEmpty) 'variant': variant,
    };
    final json = await _post('/v1/jobs', body);
    final job = AiJob(
      id: (json['job_id'] as String?) ?? '',
      taskCode: task,
      label: label,
      resourceKey: key,
      inputs: inputs,
      query: query,
      variant: variant,
      stages: stages,
      keepLockOnDone: keepLockOnDone,
      silent: silent,
      doneMessage: doneMessage,
      onDone: onDone,
      onError: onError,
      onCancel: onCancel,
    );
    _jobs[job.id] = job;
    if (key.isNotEmpty) _locks[key] = job.id;
    _startPolling(job);
    _notify();
    _log.i('已提交 $task：${job.id}（$label，key=$key）');
    return job;
  }

  /// 取消任务。三种通道分开走：
  ///
  /// - **队列任务**：`POST /v1/jobs/{id}/cancel`，running 在服务端检查点生效；
  /// - **交互会话 / 后台任务**：无服务端 id，置 `cancelRequested` 并回调
  ///   [AiJob.interrupt]（流式循环逐块检查、后台执行体自己收尾）；
  /// - **已终态（含失败可重试）**：直接 [dismiss] 从托盘历史移除 —— 用户要的
  ///   「失败任务也要能取消」就是这一步，否则那条红行永远赖着。
  Future<void> cancel(String jobId) async {
    final job = _jobs[jobId] ?? _findRecent(jobId);
    if (job == null) return;
    if (!job.isActive) {
      dismiss(jobId);
      return;
    }
    if (job.interactive || job.detached) {
      job.cancelRequested = true;
      job.message = '正在取消…';
      try {
        job.interrupt?.call();
      } on Object catch (e) {
        _log.w('中断回调异常（$jobId）：$e');
      }
      // 执行体可能已经跑完（取消太晚）→ 让它自己的收尾逻辑走终态。
      _notify();
      return;
    }
    try {
      final json = await _post('/v1/jobs/$jobId/cancel', const <String, dynamic>{});
      job.applyJson(json);
      // 服务端对 T1/T3 这类任务**不可中断**：cancel 只登记，任务会一路跑成
      // done。本地把闩锁按下，终态文案才敢说「该任务类型不支持中途取消」。
      if (job.isActive) job.cancelRequested = true;
      if (!job.isActive) _onTerminal(job);
      _notify();
    } on Object catch (e) {
      _log.w('取消失败（$jobId）：$e');
    }
  }

  /// 把一条**已终态**任务从托盘历史里彻底移除（失败红条的「知道了」）。
  ///
  /// 在途任务不走这里（先 [cancel]），避免执行体成孤儿继续跑却看不见。
  void dismiss(String jobId) {
    final job = _jobs[jobId];
    if (job != null && job.isActive) return;
    _timers.remove(jobId)?.cancel();
    _failCount.remove(jobId);
    _recent.removeWhere((j) => j.id == jobId);
    _jobs.remove(jobId);
    if (job != null &&
        job.resourceKey.isNotEmpty &&
        _locks[job.resourceKey] == jobId) {
      _locks.remove(job.resourceKey);
    }
    _notify();
  }

  /// 用原参数（含原回调）重新提交。
  ///
  /// 交互会话与后台任务**不可重试**：前者没有服务端任务，后者的执行体是闭包、
  /// 出了 `runDetached` 就没了 —— 重试只能由调用方重新发起。
  Future<AiJob?> retry(String jobId) async {
    final old = _jobs[jobId] ?? _findRecent(jobId);
    if (old == null || old.interactive || old.detached) return null;
    return submit(
      task: old.taskCode,
      resourceKey: old.resourceKey,
      label: old.label,
      stages: old.stages,
      inputs: old.inputs,
      query: old.query,
      variant: old.variant,
      keepLockOnDone: old.keepLockOnDone,
      silent: old.silent,
      doneMessage: old.doneMessage,
      onDone: old.onDone,
      onError: old.onError,
      onCancel: old.onCancel,
    );
  }

  // ==================== 锁 ====================

  /// 唯一互斥判定入口（方案 §6.4）：队列 job 或交互会话占着 key 即真。
  bool isLocked(String resourceKey) {
    final key = resourceKey.trim();
    if (key.isEmpty) return false;
    return _locks.containsKey(key) || _interactive.containsKey(key);
  }

  /// 交互通道占锁（B4：T6/T7/T8 流式会话，不走队列但要互斥 + 托盘计时）。
  ///
  /// 同时做两件事：① 在 [_interactive] 登记资源锁（[isLocked] 据此互斥，
  /// 如「同点重复开老师模式」）；② 合成一个 running 态的 [AiJob]
  /// （``interactive=true``）进托盘，全局可见「会话在进行、占了哪个锁、
  /// 已进行多久」。返回会话 id（[releaseInteractive] 用）。
  ///
  /// 幂等：同 key 已占 → 复用既有行（不再建第二行），避免重复托盘行 +
  /// 旧行孤儿化泄漏（一个入口被连点两次也不会炸）。
  String holdInteractive(
    String resourceKey, {
    required String label,
    VoidCallback? onCancel,
  }) {
    final key = resourceKey.trim();
    if (key.isEmpty) return '';
    final existing = _interactive[key];
    if (existing != null && existing.isNotEmpty) return existing;
    final id = 'ix-$_uuid()';
    _interactive[key] = id;
    final job = AiJob(
      id: id,
      taskCode: 'SESSION',
      label: label,
      resourceKey: key,
      silent: true,
      interactive: true,
    )
      ..status = AiJobStatus.running
      ..message = '会话进行中'
      ..interrupt = onCancel;
    _jobs[id] = job;
    if (key.isNotEmpty) _locks[key] = id;
    // 服务端登记外部任务（让托盘/管理后台能看见这个会话 + 心跳看门狗兜底）。
    // 失败（老服务 / 服务没起）只影响服务端可观测性，不动本地流程。
    unawaited(
      registerExternal(task: 'SESSION', label: label, resourceKey: key)
          .then((sid) {
        if (sid != null) job.serverJobId = sid;
      }),
    );
    _notify();
    return id;
  }

  /// 交互通道放锁 + 撤托盘行（sessionId 由 [holdInteractive] 返回）。
  ///
  /// ⚠️ 必须同步清掉 [_locks] 里这一行：否则 [holdInteractive] 占的 `kp:{id}`
  /// / `homework:...` 锁会残留成「僵尸锁」，下次打开同一入口被 [isLocked]
  /// 拦下、报「该知识点的老师模式会话已打开」（P1 根因：退出页面后锁没清）。
  void releaseInteractive(String sessionId) {
    if (sessionId.isEmpty) return;
    // 先按 holder 反查 resourceKey，再清锁 + 清交互表，避免留下僵尸锁。
    String? lockedKey;
    _interactive.removeWhere((k, holder) {
      if (holder == sessionId) {
        lockedKey = k;
        return true;
      }
      return false;
    });
    if (lockedKey != null && lockedKey!.isNotEmpty) {
      _locks.remove(lockedKey);
    }
    final job = _jobs.remove(sessionId);
    if (job != null) {
      if (job.serverJobId != null) {
        unawaited(finishExternal(job.serverJobId!, status: 'canceled'));
      }
      _notify();
    }
  }

  /// 更新交互会话的托盘文案（如「正在生成讲解…」↔「会话进行中」）。
  void setInteractiveMessage(String sessionId, String message) {
    final job = _jobs[sessionId];
    if (job == null || !job.interactive) return;
    job.message = message;
    _notify();
  }

  /// 手动放锁（复合流水线第二段提交失败等异常路径用）。
  void releaseLock(String resourceKey) {
    _locks.remove(resourceKey.trim());
    _notify();
  }

  // ==================== 后台任务（页面销毁不中断） ====================

  /// 登记一个**App 侧执行体**的后台任务，立即返回 [DetachedTask]。
  ///
  /// 三条边界：
  /// - **不随页面销毁中断**：[body] 的 Future 由本服务持有，页面 `dispose`
  ///   只影响 UI；终态副作用一律写在 body 内（写库 / 落消息），**禁止碰
  ///   `BuildContext`**——页面可能已经没了；
  /// - **托盘可见**：登记即进 `activeJobs`（与队列任务同列），进度经
  ///   [DetachedTask.progress] 刷新，取消经 [cancel] → `interrupt`；
  /// - **不占服务端 job**：`/v1/jobs` 里查不到它，冷启动对账也不收养，
  ///   所以 App 被杀 = 任务丢失（可接受：结果本来就随下次重跑重建）。
  ///
  /// [resourceKey] 非空则占锁（与队列任务同一张锁表，[isLocked] 据此互斥）。
  DetachedTask runDetached({
    required String label,
    String resourceKey = '',
    bool silent = false,
    String? doneMessage,
    required Future<void> Function(DetachedTask task) body,
  }) {
    final key = resourceKey.trim();
    final job = AiJob(
      id: 'bg-$_uuid()',
      taskCode: 'BACKGROUND',
      label: label,
      resourceKey: key,
      silent: silent,
      detached: true,
      doneMessage: doneMessage,
    )
      ..status = AiJobStatus.running
      ..startedAt = DateTime.now()
      ..message = '进行中…';
    _jobs[job.id] = job;
    if (key.isNotEmpty) _locks[key] = job.id;
    final task = DetachedTask._(this, job);
    job.interrupt = task._interruptFromTray;
    // 服务端登记外部任务（看门狗兜底：App 被强杀也能超时标 failed）。
    unawaited(
      registerExternal(task: 'BACKGROUND', label: label, resourceKey: key)
          .then((sid) {
        if (sid != null) job.serverJobId = sid;
      }),
    );
    _notify();
    _log.i('已登记后台任务 ${job.id}（$label）');
    unawaited(_runDetachedBody(task, body));
    return task;
  }

  Future<void> _runDetachedBody(
    DetachedTask task,
    Future<void> Function(DetachedTask task) body,
  ) async {
    final job = task.job;
    try {
      await body(task);
      if (job.cancelRequested) {
        job.status = AiJobStatus.canceled;
        job.message = '已取消';
      } else {
        job.status = AiJobStatus.done;
        job.percent = 1;
        job.message = job.doneMessage ?? '已完成';
      }
    } on Object catch (e, s) {
      if (job.cancelRequested) {
        job.status = AiJobStatus.canceled;
        job.message = '已取消';
      } else {
        _log.e('后台任务失败（${job.id}）', error: e, stackTrace: s);
        job.status = AiJobStatus.failed;
        job.errorCode = 'background_error';
        job.errorMessage = e.toString();
        job.retryable = true;
        job.message = '失败';
      }
    } finally {
      // 先叫醒等待方再走终态广播：等的人要的是「可以继续了」。
      if (!task._done.isCompleted) task._done.complete();
    }
    if (job.serverJobId != null) {
      final status = job.status == AiJobStatus.failed
          ? 'failed'
          : job.status == AiJobStatus.canceled
              ? 'canceled'
              : 'done';
      unawaited(finishExternal(
        job.serverJobId!,
        status: status,
        result: job.result,
        message: job.doneMessage ?? job.message,
      ));
    }
    _onTerminal(job);
  }

  // ==================== 外部任务登记（服务端可观测 + 心跳看门狗） ====================

  /// 向服务端登记一个**外部驱动**任务，拿回服务端 job_id（回填到
  /// [AiJob.serverJobId]）。App 本地的后台体 / 交互会话 / 流式会话经此在
  /// 服务端留下状态实体，心跳看门狗据此判断「客户端是否还活着」。
  ///
  /// 失败（老服务不支持 / 服务没起）一律返回 null，**绝不**影响本地流程。
  Future<String?> registerExternal({
    required String task,
    required String label,
    String resourceKey = '',
    double? heartbeatS,
  }) async {
    try {
      final json = await _post('/v1/jobs/register', <String, dynamic>{
        'task': task,
        'label': label,
        if (resourceKey.isNotEmpty) 'resource_key': resourceKey,
        if (heartbeatS != null) 'heartbeat_s': heartbeatS,
      });
      final id = json['job_id'];
      return id is String && id.isNotEmpty ? id : null;
    } on Object catch (e) {
      _log.w('外部任务登记失败（$task/$label）：$e');
      return null;
    }
  }

  /// 上报外部任务进度（同时续服务端心跳）。失败静默。
  Future<void> reportExternal(
    String serverJobId, {
    String? message,
    double? percent,
  }) async {
    if (serverJobId.isEmpty) return;
    try {
      await _post('/v1/jobs/$serverJobId/progress', <String, dynamic>{
        if (message != null) 'message': message,
        if (percent != null)
          'percent': (percent * 100).clamp(0, 100).round(),
      });
    } on Object catch (e) {
      _log.w('外部任务进度上报失败（$serverJobId）：$e');
    }
  }

  /// 外部任务终态（done / failed / canceled）。失败静默。
  Future<void> finishExternal(
    String serverJobId, {
    required String status,
    Map<String, dynamic>? result,
    String? message,
  }) async {
    if (serverJobId.isEmpty) return;
    try {
      await _post('/v1/jobs/$serverJobId/finish', <String, dynamic>{
        'status': status,
        if (result != null) 'result': result,
        if (message != null) 'message': message,
      });
    } on Object catch (e) {
      _log.w('外部任务终态失败（$serverJobId/$status）：$e');
    }
  }

  // ==================== 查询 ====================

  List<AiJob> get activeJobs {
    final list = _jobs.values.where((j) => j.isActive).toList()
      ..sort((a, b) => a.submittedAt.compareTo(b.submittedAt));
    return list;
  }

  List<AiJob> get recentJobs => List<AiJob>.unmodifiable(_recent);

  AiJob? jobById(String jobId) => _jobs[jobId] ?? _findRecent(jobId);

  // ==================== 冷启动对账（方案 §8.3） ====================

  /// 收养服务端仍在跑的 job（App 被杀过；服务没重启的话任务还在跑）。
  Future<void> reconcile() async {
    try {
      final json = await _get('/v1/jobs?status=queued,running&limit=50');
      final list = (json['jobs'] as List?) ?? const <dynamic>[];
      var adopted = 0;
      for (final raw in list) {
        if (raw is! Map) continue;
        // 外部任务（App 本地驱动）不收养：避免和本地已存在的 ix-/bg- 行重复显示。
        if ((raw['external'] as bool?) == true) continue;
        final id = (raw['job_id'] as String?) ?? '';
        if (id.isEmpty || _jobs.containsKey(id)) continue;
        final job = AiJob.fromJson(Map<String, dynamic>.from(raw));
        _jobs[job.id] = job;
        if (job.resourceKey.isNotEmpty) _locks[job.resourceKey] = job.id;
        _startPolling(job);
        adopted++;
      }
      if (adopted > 0) _log.i('对账收养 $adopted 个在途任务');
      _notify();
    } on Object catch (e) {
      // 服务没起 / 老服务没有 /v1/jobs：静默（本轮没有在途任务可收养）。
      _log.w('任务对账跳过：$e');
    }
  }

  // ==================== 轮询 ====================

  void _startPolling(AiJob job) {
    _timers.remove(job.id)?.cancel();
    _failCount[job.id] = 0;
    _timers[job.id] = Timer(kAiJobPollInterval, () => _poll(job.id));
  }

  Future<void> _poll(String jobId) async {
    final job = _jobs[jobId];
    if (job == null || !job.isActive) return;
    try {
      final json = await _get('/v1/jobs/$jobId');
      final wasOffline = job.offline;
      job.applyJson(json);
      _failCount[jobId] = 0;
      if (wasOffline) {
        // 恢复：退出离线态 → 回到 800ms 正常轮询（下面 isActive 分支照旧）。
        job.offline = false;
        if (job.message == kAiJobOfflineMessage) {
          job.message = '连接已恢复，继续推进…';
        }
        _log.i('轮询已恢复（$jobId）');
      }
      // 用户点过取消、但该任务类型不支持中断（服务端会一路跑成 done）：
      // 行内先说清楚，终态 SnackBar 由托盘按 cancelRequested 换词。
      if (job.status == AiJobStatus.done && job.cancelRequested) {
        job.message = '已结束（该任务类型不支持中途取消）';
      }
      if (!job.isActive) {
        _onTerminal(job);
      }
      _notify();
      if (job.isActive) {
        _timers[jobId] = Timer(kAiJobPollInterval, () => _poll(jobId));
      }
    } on LlmServerException catch (e) {
      if (e.statusCode == 404) {
        _markFailed(job, '服务已重启，请重试', code: 'service_restarted');
        return;
      }
      _scheduleBackoff(job);
    } on Object catch (e) {
      _log.w('轮询失败（$jobId）：$e');
      _scheduleBackoff(job);
    }
  }

  /// 轮询失败处理：未达上限先按 [kAiJobPollBackoff] 退避；达上限后**不判死**，
  /// 转离线态（保住托盘行、保住资源锁），以 [kAiJobOfflineRetryInterval] 固定
  /// 5s 一直重试到恢复 —— 服务端那边任务还在跑，App 这边凭什么替它判终态。
  void _scheduleBackoff(AiJob job) {
    final n = (_failCount[job.id] ?? 0) + 1;
    _failCount[job.id] = n;
    if (n >= kAiJobMaxPollFailures) {
      if (!job.offline) {
        // percent 原样保留：网络断了不代表进度回退，别把用户看到的进度清零。
        job.offline = true;
        job.message = kAiJobOfflineMessage;
        _log.w('轮询连续失败 $n 次（${job.id}）→ 离线重试；行与锁保留');
        _notify();
      }
      _timers[job.id] = Timer(kAiJobOfflineRetryInterval, () => _poll(job.id));
      return;
    }
    final delay = kAiJobPollBackoff[(n - 1).clamp(0, kAiJobPollBackoff.length - 1)];
    _timers[job.id] = Timer(delay, () => _poll(job.id));
  }

  void _markFailed(AiJob job, String message, {required String code}) {
    job.status = AiJobStatus.failed;
    job.message = message;
    job.errorCode = code;
    job.errorMessage = message;
    _onTerminal(job);
  }

  void _onTerminal(AiJob job) {
    // 终态落定时刻：托盘据此把 done 行再保留 10 秒（见 job_tray 的可见集合）。
    job.finishedAt = DateTime.now();
    job.offline = false; // 终态优先：离线标不能挂在一条已结束的行上。
    _timers.remove(job.id)?.cancel();
    _failCount.remove(job.id);
    // 锁释放：终态即放；done 且 keepLockOnDone（复合流水线中间段）不放，
    // 由下一段提交继续持有或调用方手动 releaseLock。
    final shouldRelease =
        job.resourceKey.isNotEmpty && _locks[job.resourceKey] == job.id &&
            !(job.status == AiJobStatus.done && job.keepLockOnDone);
    if (shouldRelease) _locks.remove(job.resourceKey);
    _jobs.remove(job.id);
    _recent.removeWhere((j) => j.id == job.id);
    _recent.insert(0, job);
    if (_recent.length > kAiJobMaxRecent) {
      _recent.removeRange(kAiJobMaxRecent, _recent.length);
    }
    _notify();
    // 回调（页面活着才刷新；异常一律吞掉，不能把托盘搞挂）。
    try {
      switch (job.status) {
        case AiJobStatus.done:
          job.onDone?.call(job);
        case AiJobStatus.failed:
          job.onError?.call(job.errorMessage ?? job.message);
        case AiJobStatus.canceled:
          job.onCancel?.call();
        case AiJobStatus.queued:
        case AiJobStatus.running:
          break;
      }
    } on Object catch (e, s) {
      _log.e('任务回调异常（${job.id}）', error: e, stackTrace: s);
    }
    if (!_terminal.isClosed) _terminal.add(job);
  }

  void _notify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      // ValueNotifier.value 的 setter 在值变化时才通知监听者；无监听者时
      // 仅改一个 int，零开销。合流（_notifyScheduled）已避免每帧多次 +1。
      revision.value++;
    });
  }

  AiJob? _findRecent(String jobId) {
    for (final j in _recent) {
      if (j.id == jobId) return j;
    }
    return null;
  }

  // ==================== HTTP 底层 ====================

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final req = await _client
        .postUrl(Uri.parse('$_apiBase$path'))
        .timeout(const Duration(seconds: 10));
    req.headers.set('Content-Type', 'application/json; charset=utf-8');
    req.headers.set('Accept', 'application/json');
    req.add(utf8.encode(jsonEncode(body)));
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw _errorFrom(resp.statusCode, text);
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw LlmServerException('AI 服务返回非 JSON 对象', statusCode: resp.statusCode);
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final req = await _client
        .getUrl(Uri.parse('$_apiBase$path'))
        .timeout(const Duration(seconds: 10));
    req.headers.set('Accept', 'application/json');
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw _errorFrom(resp.statusCode, text);
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw LlmServerException('AI 服务返回非 JSON 对象', statusCode: resp.statusCode);
    }
    return decoded;
  }

  /// 统一错误结构 ``{error:{code,message,retryable}}`` → 异常（不甩原始报文）。
  static LlmServerException _errorFrom(int status, String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map && decoded['error'] is Map) {
        final e = decoded['error'] as Map;
        return LlmServerException(
          (e['message'] as String?) ?? payload,
          code: (e['code'] as String?) ?? 'upstream_error',
          retryable: e['retryable'] == true,
          statusCode: status,
        );
      }
    } on Object {
      // 落统一兜底。
    }
    final preview =
        payload.length <= 200 ? payload : '${payload.substring(0, 200)}…';
    return LlmServerException(
      payload.isEmpty ? 'AI 服务返回 HTTP $status' : 'AI 服务返回 HTTP $status：$preview',
      statusCode: status,
    );
  }

  static String _uuid() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return hex(bytes);
  }

  static String hex(List<int> bytes) {
    const hexDigits = '0123456789abcdef';
    return bytes.map((b) => hexDigits[b >> 4] + hexDigits[b & 0xF]).join();
  }

  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _terminal.close();
    revision.dispose();
  }
}

/// 后台任务句柄（[AiJobService.runDetached] 返回）。
///
/// 执行体的唯一契约：**先查 [isCanceled] 再干活**；流式循环逐块检查，
/// 用户点托盘「取消」后下一块就退出，别硬跑完。
class DetachedTask {
  DetachedTask._(this._service, this.job);

  final AiJobService _service;
  final AiJob job;

  /// 执行体完结信号（done / failed / canceled 都会 complete，不抛）。
  ///
  /// 给「调用方必须等结果才能继续，但不能因为页面关了就中断」的场景用
  /// （如老师模式点了「开始老师讲解」后，页面要等讲解落库才刷新消息流）。
  final Completer<void> _done = Completer<void>();
  Future<void> get done => _done.future;

  /// 执行体自己注册的「立刻中断」回调（如 `sub.cancel()`），可空。
  VoidCallback? _interruptExtra;

  String get id => job.id;

  /// 用户已请求取消（托盘「取消」或服务侧 cancel）。
  bool get isCanceled =>
      job.cancelRequested || job.status == AiJobStatus.canceled;

  /// 上报进度（托盘每帧可见）。[percent] 0..1，null = 不确定态。
  void progress(
    String message, {
    double? percent,
    int? stageIndex,
    int? stageTotal,
  }) {
    job.message = message;
    if (percent != null) job.percent = percent.clamp(0.0, 1.0);
    if (stageIndex != null) job.stageIndex = stageIndex;
    if (stageTotal != null) job.stageTotal = stageTotal;
    // 同步续服务端心跳（让看门狗知道这个后台任务还活着）。
    if (job.serverJobId != null) {
      unawaited(
        _service.reportExternal(job.serverJobId!, message: message, percent: percent),
      );
    }
    _service._notify();
  }

  /// 覆盖终态摘要（如「已生成 3 份作业」）。
  void setDoneMessage(String message) => job.doneMessage = message;

  /// 注册「立刻中断」回调（流式任务传 `() => sub.cancel()` 最灵）。
  ///
  /// 取消优先走这个（不必等下一块数据到达）；不注册就只能等循环检查
  /// [isCanceled]，模型长时间不出字时会有延迟。
  void setInterrupt(VoidCallback? cb) => _interruptExtra = cb;

  /// 取消即抛（执行体里让取消走异常快速退出这几层嵌套时用）。
  void throwIfCanceled() {
    if (isCanceled) throw const TaskCanceledException();
  }

  void _interruptFromTray() {
    job.cancelRequested = true;
    _interruptExtra?.call();
  }
}


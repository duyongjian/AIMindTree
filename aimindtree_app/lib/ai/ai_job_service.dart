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
///   轮询连续失败 5 次 → 标 ``failed(网络中断)``；轮到 404 → 标
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

/// 连续轮询失败上限 → 标 ``failed(网络中断)``。
const int kAiJobMaxPollFailures = 5;

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
  /// 无服务端 id、不可取消/重试，锁随会话页生命周期持有。
  final bool interactive;

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
    cancelRequested = json['cancel_requested'] == true;
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

  /// 取消任务（queued 即消；running 在服务端检查点生效，UI 已明示）。
  /// 交互会话（interactive）由页面自行中断，不走服务端取消。
  Future<void> cancel(String jobId) async {
    final job = _jobs[jobId];
    if (job == null || !job.isActive) return;
    if (job.interactive) return;
    try {
      final json = await _post('/v1/jobs/$jobId/cancel', const <String, dynamic>{});
      job.applyJson(json);
      if (!job.isActive) _onTerminal(job);
      _notify();
    } on Object catch (e) {
      _log.w('取消失败（$jobId）：$e');
    }
  }

  /// 用原参数（含原回调）重新提交。交互会话无服务端任务，不重试。
  Future<AiJob?> retry(String jobId) async {
    final old = _jobs[jobId] ?? _findRecent(jobId);
    if (old == null || old.interactive) return null;
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
  String holdInteractive(String resourceKey, {required String label}) {
    final key = resourceKey.trim();
    if (key.isEmpty) return '';
    final id = 'ix-$_uuid()';
    _interactive[key] = id;
    _jobs[id] = AiJob(
      id: id,
      taskCode: 'SESSION',
      label: label,
      resourceKey: key,
      silent: true,
      interactive: true,
    )
      ..status = AiJobStatus.running
      ..message = '会话进行中';
    _notify();
    return id;
  }

  /// 交互通道放锁 + 撤托盘行（sessionId 由 [holdInteractive] 返回）。
  void releaseInteractive(String sessionId) {
    if (sessionId.isEmpty) return;
    _interactive.removeWhere((_, holder) => holder == sessionId);
    if (_jobs.remove(sessionId) != null) _notify();
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
      job.applyJson(json);
      _failCount[jobId] = 0;
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

  void _scheduleBackoff(AiJob job) {
    final n = (_failCount[job.id] ?? 0) + 1;
    _failCount[job.id] = n;
    if (n >= kAiJobMaxPollFailures) {
      _markFailed(job, '网络中断（连续 $n 次轮询失败）', code: 'network_lost');
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

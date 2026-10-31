/// 全局任务托盘（方案 §5.2）：挂在 AppShell，5 个 Tab 常驻可见。
///
/// - **折叠态**（默认，Q3 决策）：4px 细进度条 + 「N 个任务进行中」+ 展开按钮，
///   不挡内容；
/// - **展开态**：每个 job 一行——label、百分比 / 阶段文案、已用时间、取消按钮、
///   所占资源锁徽标（让用户知道「为什么某个按钮点不了」）；交互会话（老师
///   模式 / 作业出题，B4）、后台任务（D：离开页面继续跑）同样登记为行；
///   在途一律可取消，失败行给「重试 + 移除」两个动作；
/// - **终态**：done → SnackBar 摘要 + **行再保留 10 秒**（[kJobTrayDoneVisible]，
///   让用户回头看得见「成了没有」）+ 3s 后自动折叠；failed → 红条 + 重试；
///   canceled → 直接从托盘消失；``silent`` 任务（如对话检测）只留托盘行，
///   终态不弹 SnackBar。
/// - **三类行要能分清**：队列任务（服务端 job，800ms 轮询推进）、交互会话
///   （``interactive``：只是一个开着的页面，**不画进度条**，永远 running）、
///   后台任务（``detached``：本地执行体，自己报进度）；``offline`` 行是「服务
///   端还在跑、本机断了」——橙色离线标，不是失败红条。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/ai_job_service.dart';

/// 托盘宿主：把「托盘 + 整个页面栈」一起放进一个**铺满窗口**的 Overlay。
///
/// 为什么需要它（2026-10-31 在 Windows 上实测定位）：
/// 托盘必须挂在 Navigator 之上，否则 push 出来的页面（老师模式 / 作业历史 /
/// 回收站）会整屏盖住它 —— 所以在 `MaterialApp.builder` 里装配。同时托盘里的
/// `IconButton.tooltip` 需要一个 Overlay 祖先，否则抛「No Overlay widget found」。
/// 但**不能**把 `Overlay` 直接塞进 `Column`：`Column` 给子节点的高度约束是
/// 无穷大，`_RenderTheater` 无法确定自身尺寸，直接抛
/// 「Overlay was given infinite constraints and cannot be sized by a suitable
/// child」→ 首帧布局中断 → 该帧不送入引擎 → 连带刷屏
/// 「debugFrameWasSentToEngine is not true」与「!semantics.parentDataDirty」。
///
/// 正确做法（与 WidgetsApp 自身结构一致，见 SDK overlay.dart 的
/// `_OverlayEntryWidget` 用法）：Overlay 作 builder 的根，吃窗口的**有限**约束；
/// 托盘与 `child` 放进同一个 OverlayEntry 的 Column —— 托盘无任务时高度 0 不
/// 占位，有任务时把孩子一起下推，语义与改动前完全相同。
class JobTrayHost extends StatefulWidget {
  const JobTrayHost({super.key, required this.jobs, required this.child});

  final AiJobService jobs;
  final Widget child;

  @override
  State<JobTrayHost> createState() => _JobTrayHostState();
}

class _JobTrayHostState extends State<JobTrayHost> {
  /// entry 只建一次：`Overlay.initialEntries` 仅在 initState 里 insert 一次，
  /// 每次 build 新建 entry 既不会被插入，又会让已插入的旧 entry 继续持有
  /// **过期的 child**（旧 Navigator）。
  late final OverlayEntry _entry = OverlayEntry(builder: _buildEntry);

  Widget _buildEntry(BuildContext context) => Column(
        children: [
          JobTray(jobs: widget.jobs),
          Expanded(child: widget.child),
        ],
      );

  @override
  void didUpdateWidget(covariant JobTrayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    // entry 的 builder 闭包读的是 widget.*，必须显式让它重建才能看到新值。
    if (!identical(widget.child, oldWidget.child) ||
        !identical(widget.jobs, oldWidget.jobs)) {
      _entry.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    // 与 SDK overlay.dart:962 的写法一致：先摘除再释放。
    _entry
      ..remove()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: <OverlayEntry>[_entry]);
}

class JobTray extends StatefulWidget {
  const JobTray({
    super.key,
    required this.jobs,
    this.doneVisible = kJobTrayDoneVisible,
  });

  final AiJobService jobs;

  /// done 行保留可见的时长（默认 [kJobTrayDoneVisible]）。
  ///
  /// 做成参数只为测试能把它调小（见 `test/job_tray_visibility_test.dart`），
  /// 生产路径一律用默认值。
  final Duration doneVisible;

  @override
  State<JobTray> createState() => JobTrayState();
}

/// done 行在托盘里的**保留时长**：终态落定后仍可见这么久。
///
/// 立刻消失等于没有反馈 —— 用户回头看不到「刚才那个成了没有」。
const Duration kJobTrayDoneVisible = Duration(seconds: 10);

/// 离线标记色（失联 ≠ 失败，所以不用 error 红）。
const Color kJobTrayOfflineColor = Color(0xFFEF6C00);

/// 完成标记色。
const Color kJobTrayDoneColor = Color(0xFF2E7D32);

class JobTrayState extends State<JobTray> {
  bool _expanded = false;
  Timer? _autoCollapse;

  /// 终态订阅句柄：**必须持有**。裸 `listen(...)` 丢掉返回值 → dispose 里
  /// 取消不了 → 托盘销毁后回调仍会跑（对已 unmount 的 context 取
  /// `ScaffoldMessenger`），且每次重建泄漏一条订阅。
  StreamSubscription<AiJob>? _terminalSub;

  /// done 行过期（超过 [kJobTrayDoneVisible]）时的到点重建定时器。
  Timer? _doneSweep;

  @override
  void initState() {
    super.initState();
    widget.jobs.revision.addListener(_onRevision);
    _terminalSub = widget.jobs.terminalStream.listen(_onTerminal);
    // 冷启动对账：收养服务端仍在跑的 job（App 被杀过）。
    widget.jobs.reconcile();
    // 「查看任务」动作（被挡操作的 SnackBar）→ 展开托盘。
    widget.jobs.onExpandTray = expand;
  }

  @override
  void dispose() {
    widget.jobs.revision.removeListener(_onRevision);
    _terminalSub?.cancel();
    _terminalSub = null;
    widget.jobs.onExpandTray = null;
    _autoCollapse?.cancel();
    _doneSweep?.cancel();
    super.dispose();
  }

  void _onRevision() {
    if (!mounted) return;
    setState(() {});
    // 每次状态变化顺带校准 done 行的过期时刻（成本极低：最多几条）。
    _ensureDoneSweep();
  }

  void _onTerminal(AiJob job) {
    if (!mounted) return;
    // done 行还要亮 10 秒 → 需要一次「到点」重建。
    if (job.status == AiJobStatus.done) _ensureDoneSweep();
    // 静默任务（如对话检测）：托盘行/红条/重试已给足可见性，不弹 SnackBar。
    if (job.silent) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (job.status) {
      case AiJobStatus.done:
        // 用户点过取消但任务类型不支持中途取消（服务端非 T4，会一路跑成
        // done）→ 不能报「已完成」，否则用户以为取消生效了。
        final canceledMidway = job.cancelRequested;
        messenger.showSnackBar(SnackBar(
          content: Text(canceledMidway
              ? '「${job.label}」已结束（该任务类型不支持中途取消）'
              : (job.doneMessage ?? '「${job.label}」已完成')),
          duration: const Duration(seconds: 3),
        ));
        _scheduleAutoCollapse();
      case AiJobStatus.failed:
        messenger.showSnackBar(SnackBar(
          content: Text('「${job.label}」失败：${job.errorMessage ?? job.message}'),
          duration: const Duration(seconds: 6),
          // 交互会话 / 后台任务重试不了（执行体不在队列里）→ 不给假按钮。
          action: (job.detached || job.interactive)
              ? null
              : SnackBarAction(
                  label: '重试',
                  onPressed: () => widget.jobs.retry(job.id),
                ),
        ));
      case AiJobStatus.canceled:
        break; // 用户自己取消的，不打扰
      case AiJobStatus.queued:
      case AiJobStatus.running:
        break;
    }
  }

  /// done 且终态在 [JobTray.doneVisible] 内的行（`recentJobs` 里新的在前）。
  ///
  /// 没有 `finishedAt` 的行（冷启动对账收养的历史行）不进集合：它们不是
  /// 「刚完成」，进来只会让托盘一开机就挂一堆绿条。
  List<AiJob> _visibleDone() {
    final now = DateTime.now();
    final out = <AiJob>[];
    for (final job in widget.jobs.recentJobs) {
      if (job.status != AiJobStatus.done) continue;
      final at = job.finishedAt;
      if (at == null) continue;
      if (now.difference(at) < widget.doneVisible) out.add(job);
    }
    return out;
  }

  /// 给**最早过期**的那条 done 行排一次到点重建，到点后再排下一条。
  ///
  /// 只维护一个 Timer（不是每行一个）：托盘同时挂的 done 行最多几条，重建一次
  /// 的成本远低于维护 N 个 Timer。
  void _ensureDoneSweep() {
    _doneSweep?.cancel();
    _doneSweep = null;
    final done = _visibleDone();
    if (done.isEmpty) return;
    var earliest = done.first.finishedAt!;
    for (final job in done) {
      final at = job.finishedAt!;
      if (at.isBefore(earliest)) earliest = at;
    }
    var wait = earliest.add(widget.doneVisible).difference(DateTime.now());
    if (wait.isNegative) wait = Duration.zero;
    // 至少隔一帧：避免定时器早触发几毫秒 → 立刻重排 → 空转。
    if (wait < const Duration(milliseconds: 16)) {
      wait = const Duration(milliseconds: 16);
    }
    _doneSweep = Timer(wait, () {
      _doneSweep = null;
      if (!mounted) return;
      setState(() {});
      _ensureDoneSweep();
    });
  }

  void _scheduleAutoCollapse() {
    _autoCollapse?.cancel();
    _autoCollapse = Timer(const Duration(seconds: 3), () {
      if (mounted && widget.jobs.activeJobs.isEmpty) {
        setState(() => _expanded = false);
      }
    });
  }

  void expand() {
    if (mounted) setState(() => _expanded = true);
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.jobs.activeJobs;
    // 失败行不再只显示 3 条（用户报「看不见全部 / 消失了」）：全列，靠展开区
    // 自身的 260px 上限滚动兜住。
    final failed = widget.jobs.recentJobs
        .where((j) => j.status == AiJobStatus.failed)
        .toList();
    // done 行保留 10 秒（[kJobTrayDoneVisible]）：用户回头才看得见「成了没有」。
    final done = _visibleDone();
    if (active.isEmpty && failed.isEmpty && done.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 总进度只算**有进度语义**的行：交互会话永远是 0%（没有任何东西能推进它），
    // 把它算进均值只会拉低数字、并把进度条拖成不确定态。
    final progressable = active.where((j) => !j.interactive).toList();
    final percents = progressable
        .where((j) => j.progressOrNull != null)
        .map((j) => j.progressOrNull!);
    final overall =
        percents.isEmpty ? null : percents.reduce((a, b) => a + b) / percents.length;
    final hasFailed = failed.isNotEmpty;
    final hasOffline = active.any((j) => j.offline);
    // 只有交互会话在跑时没有「总进度」可言 → 不画那条一直在动的 4px 条。
    final showOverallBar = progressable.isNotEmpty;
    final overallText = overall != null
        ? '${(overall * 100).round()}%'
        : (showOverallBar ? '排队/等待中' : null);

    return Material(
      color: hasFailed
          ? colorScheme.errorContainer.withValues(alpha: 0.35)
          : colorScheme.surfaceContainerHighest,
      elevation: 2,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ---- 折叠态：细条 + 汇总（点击展开）----
          InkWell(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
              child: Row(
                children: [
                  Icon(
                    hasFailed
                        ? Icons.error_outline
                        : hasOffline
                            ? Icons.cloud_off
                            : (active.isEmpty
                                ? Icons.check_circle_outline
                                : Icons.pending_outlined),
                    size: 16,
                    color: hasFailed
                        ? colorScheme.error
                        : hasOffline
                            ? kJobTrayOfflineColor
                            : (active.isEmpty
                                ? kJobTrayDoneColor
                                : colorScheme.primary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _summaryText(active, failed, done),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (overallText != null) ...[
                    Text(overallText, style: theme.textTheme.bodySmall),
                    const SizedBox(width: 4),
                  ],
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18),
                ],
              ),
            ),
          ),
          // ---- 4px 总进度条（只有失败行 / 只剩交互会话时不画，画了就是
          //      「正在跑」的假象）----
          if (showOverallBar)
            SizedBox(
              height: 4,
              child: overall == null
                  ? LinearProgressIndicator(
                      minHeight: 4,
                      valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                    )
                  : LinearProgressIndicator(
                      minHeight: 4,
                      value: overall,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          hasOffline ? kJobTrayOfflineColor : colorScheme.primary),
                    ),
            ),
          // ---- 展开态：每 job 一行 ----
          if (_expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final job in active) _jobRow(context, job),
                  for (final job in failed) _jobRow(context, job),
                  for (final job in done) _jobRow(context, job),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 折叠态摘要：说「谁在推进」，而不是「谁最早提交」。
  ///
  /// 旧实现取 `active.first`（按 submittedAt 升序 = **最早**提交的那条），于是
  /// 「布置作业」这种先开的交互会话会一直霸占摘要，正在出题的后台行永远不上名。
  String _summaryText(List<AiJob> active, List<AiJob> failed, List<AiJob> done) {
    if (active.isNotEmpty) {
      final n = active.length;
      final latest = _latestActive(active);
      if (n == 1) return latest.label;
      return '$n 个任务进行中（最新：${latest.label}）';
    }
    if (failed.isNotEmpty) {
      // 只有带「重试」按钮的行才叫「可重试」：交互会话 / 后台任务重试不了，
      // 把它们算进「可重试」是空头支票。
      final retryable =
          failed.where((j) => !j.detached && !j.interactive).length;
      if (retryable > 0) return '$retryable 个任务失败，可重试';
      return '${failed.length} 个任务异常，展开查看';
    }
    if (done.isNotEmpty) {
      return done.length == 1
          ? '「${done.first.label}」已完成'
          : '${done.length} 个任务已完成';
    }
    return '';
  }

  /// 「最新推进」的那条：优先 `startedAt`（真正开始跑的时刻），没有就看
  /// `submittedAt`。交互会话只有 submittedAt，所以它不会盖过后开的真实任务。
  AiJob _latestActive(List<AiJob> active) {
    DateTime keyOf(AiJob j) => j.startedAt ?? j.submittedAt;
    var best = active.first;
    for (final job in active.skip(1)) {
      final cmp = keyOf(job).compareTo(keyOf(best));
      if (cmp > 0) {
        best = job;
      } else if (cmp == 0 && job.startedAt != null && best.startedAt == null) {
        // 时间戳打平（Windows 时钟粒度 ~1ms，先开会话再点出题极易落在同一格）：
        // 优先「真正开始跑」的那条 —— 交互会话是页面，不该盖过真实任务。
        best = job;
      }
    }
    return best;
  }

  Widget _jobRow(BuildContext context, AiJob job) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isFailed = job.status == AiJobStatus.failed;
    final isDone = job.status == AiJobStatus.done;
    final isInteractive = job.interactive;
    // 离线 ≠ 失败：行还活着、锁还握着、随时可能恢复，所以不给红条也不给重试。
    final isOffline = job.offline && !isFailed && !isDone;
    final progress = job.progressOrNull;
    // 交互会话行**不画进度条**：它的 status 永远 running（服务端压根没有这个
    // job，没有任何东西能推进它），画 `progressOrNull == null` 的不确定进度条
    // 就是在播一段永远播不完的动画。这里改成纯文字，说清楚它是什么。
    final messageText = isInteractive
        ? '会话打开中 · 关闭页面即结束'
        : '${job.message}'
            '${(progress != null && !isDone) ? '（${(progress * 100).round()}%）' : ''}';
    final messageColor = isFailed
        ? colorScheme.error
        : (isOffline ? kJobTrayOfflineColor : null);
    final barColor = isFailed
        ? colorScheme.error
        : (isOffline ? kJobTrayOfflineColor : colorScheme.primary);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 状态标（完成 / 已结束 / 离线）在 label 前：一眼知道这行是
                    // 「还在跑」「刚成了」还是「断线重试中」。
                    if (isDone) ...[
                      Icon(
                        job.cancelRequested
                            ? Icons.do_not_disturb_on_outlined
                            : Icons.check_circle_outline,
                        size: 14,
                        color: job.cancelRequested
                            ? kJobTrayOfflineColor
                            : kJobTrayDoneColor,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        job.cancelRequested ? '已结束' : '已完成',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 10,
                          color: job.cancelRequested
                              ? kJobTrayOfflineColor
                              : kJobTrayDoneColor,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (isOffline) ...[
                      const Icon(Icons.cloud_off,
                          size: 14, color: kJobTrayOfflineColor),
                      const SizedBox(width: 3),
                      Text(
                        '离线',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 10,
                          color: kJobTrayOfflineColor,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        job.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(job.elapsedText, style: theme.textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (!isInteractive && job.stageTotal > 1)
                      Text(
                        '阶段 ${job.stageIndex}/${job.stageTotal} · ',
                        style: theme.textTheme.bodySmall,
                      ),
                    Expanded(
                      child: Text(
                        messageText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: messageColor),
                      ),
                    ),
                  ],
                ),
                // 进度条：交互会话（无进度语义）与已完成（进度条已满，没有信息量）
                // 一律不画。
                if (!isInteractive && !isDone) ...[
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: 3,
                      child: (progress == null && !isOffline)
                          ? LinearProgressIndicator(
                              minHeight: 3,
                              valueColor: AlwaysStoppedAnimation<Color>(barColor),
                            )
                          : LinearProgressIndicator(
                              minHeight: 3,
                              // 离线时服务端快照不再更新 → 画**静态**条（不播动画），
                              // 停在最后一次拿到的进度上。
                              value: progress ?? 0,
                              valueColor: AlwaysStoppedAnimation<Color>(barColor),
                            ),
                    ),
                  ),
                ],
                if (job.resourceKey.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '🔒 ${job.resourceKey}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 10,
                        color: colorScheme.outline,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 在途任务一律可取消：队列任务走服务端 cancel；交互会话与后台任务
          // 走页面 / 执行体自己注册的中断回调（B4 + D）。离线行同样是「在途」，
          // 用户可以主动放弃 —— 但**不给重试**（它没失败，正在自己重试）。
          if (job.isActive)
            IconButton(
              tooltip: job.interactive ? '结束会话' : '取消任务',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => widget.jobs.cancel(job.id),
            ),
          if (isFailed) ...[
            // 后台任务 / 交互会话没有可重放的服务端任务 → 只给「移除」。
            if (!job.detached && !job.interactive)
              IconButton(
                tooltip: '重试',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: () => widget.jobs.retry(job.id),
              ),
            // 失败但不想重试 → 移除这条红行（否则会一直赖在托盘里）。
            IconButton(
              tooltip: '移除',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () => widget.jobs.dismiss(job.id),
            ),
          ],
        ],
      ),
    );
  }
}

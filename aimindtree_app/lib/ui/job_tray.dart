/// 全局任务托盘（方案 §5.2）：挂在 AppShell，5 个 Tab 常驻可见。
///
/// - **折叠态**（默认，Q3 决策）：4px 细进度条 + 「N 个任务进行中」+ 展开按钮，
///   不挡内容；摘要是一条**队列视图**：队首（+ 状态后缀）+「还有 N 个」+
///   「会话：xxx」（交互会话必须被点名，见 [_JobTrayState._summaryText]）；
/// - **展开态**：每个 job 一行——label、百分比 / 阶段文案、已用时间、取消按钮、
///   所占资源锁徽标（让用户知道「为什么某个按钮点不了」）；交互会话（老师
///   模式 / 作业出题，B4）、后台任务（D：离开页面继续跑）同样登记为行；
///   在途一律可取消，失败行给「重试 + 移除」两个动作；
/// - **终态**：done → SnackBar 摘要 + **行再保留 30 秒**（[kJobTrayDoneVisible]，
///   让用户回头看得见「成了没有」）+ 3s 后自动折叠；failed → 红条 + 重试；
///   canceled → 直接从托盘消失；``silent`` 任务（如对话检测）只留托盘行，
///   终态不弹 SnackBar。
/// - **三类行要能分清**：队列任务（服务端 job，800ms 轮询推进）、交互会话
///   （``interactive``：只是一个开着的页面，**不画进度条**、**也不显示耗时**
///   ——它没有任务耗时语义，一直涨的计时会被误读成「卡死了」；永远 running）、
///   后台任务（``detached``：本地执行体，自己报进度）；``offline`` 行是「服务
///   端还在跑、本机断了」——橙色离线标，不是失败红条。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/ai_job_service.dart';
import '../ai/llm_channel.dart';

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
    this.now = _systemNow,
  });

  final AiJobService jobs;

  /// done 行保留可见的时长（默认 [kJobTrayDoneVisible]）。
  ///
  /// 做成参数只为测试能把它调小（见 `test/job_tray_visibility_test.dart`），
  /// 生产路径一律用默认值。
  final Duration doneVisible;

  /// 「现在几点」的取值口（判断 done 行是否已过期）。
  ///
  /// 生产路径恒为真实时钟（[_systemNow]）；做成可注入**只为测试**：widget 测试
  /// 里 `pump(Duration)` 推的是 FakeAsync 假时钟，而 `DateTime.now()` 走墙上
  /// 时间 —— 两者不同步，验一个 30 秒窗口就得真等 30 秒墙钟。注入之后测试可以
  /// 让「读到的现在」与 `pump` 同步推进，窗口语义就能在毫秒内验完。
  final DateTime Function() now;

  @override
  State<JobTray> createState() => JobTrayState();
}

/// 生产时钟（[JobTray.now] 的默认值，顶层函数引用是编译期常量）。
DateTime _systemNow() => DateTime.now();

/// done 行在托盘里的**保留时长**：终态落定后仍可见这么久。
///
/// 立刻消失等于没有反馈 —— 用户回头看不到「刚才那个成了没有」。10 秒太短：
/// 用户被 SnackBar 引开一眼、回神时那一行已经没了，观感就成了「任务消失了」；
/// 30 秒足够他回头看明白，又不会把托盘长期占住。
const Duration kJobTrayDoneVisible = Duration(seconds: 30);

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
    // 通道排队位次变化（前一个跑完、后面的位次前移）也要重绘。
    LlmChannel.instance.revision.addListener(_onRevision);
    _terminalSub = widget.jobs.terminalStream.listen(_onTerminal);
    // 冷启动对账：收养服务端仍在跑的 job（App 被杀过）。
    widget.jobs.reconcile();
    // 「查看任务」动作（被挡操作的 SnackBar）→ 展开托盘。
    widget.jobs.onExpandTray = expand;
  }

  @override
  void dispose() {
    widget.jobs.revision.removeListener(_onRevision);
    LlmChannel.instance.revision.removeListener(_onRevision);
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
    // done 行还要亮 30 秒 → 需要一次「到点」重建。
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
    final now = widget.now();
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
    var wait = earliest.add(widget.doneVisible).difference(widget.now());
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
      // 还有「刚完成」的行（[kJobTrayDoneVisible] 窗口内）没过期 → 别收起：
      // 用户刚展开看完成结果，3 秒后整条消失就是「任务凭空没了」的观感（用户
      // 已报）。窗口过期后 [build] 自然返回 0 高，无需这里强收。
      if (mounted &&
          widget.jobs.activeJobs.isEmpty &&
          _visibleDone().isEmpty) {
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
    // done 行保留 30 秒（[kJobTrayDoneVisible]）：用户回头才看得见「成了没有」。
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
                  for (final job in active) _jobRow(context, job, active),
                  for (final job in failed) _jobRow(context, job, active),
                  for (final job in done) _jobRow(context, job, active),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 折叠态摘要：**队列视图**（队首 + 还有几个 + 会话点名）。
  ///
  /// 旧实现取「最新推进」的那条（`startedAt ?? submittedAt` 最大），任务从
  /// queued 转 running 时 key 一变摘要就换人 —— 用户观感是「一下这个一下那个」，
  /// 完全看不出这是一个队列。现在恒取 `tasks.first`（`activeJobs` 已按
  /// submittedAt 升序），只有真正跑完一个才会推进，和队列语义一致。
  ///
  /// **2026-11 用户报**：「一布置作业，托盘就不显示前面任务了，只显示现在这个
  /// 作业（待启动）」—— 他当时开着老师模式 + AI 助手会话，再点「出题」，三个
  /// 任务同时存在。根因是旧实现把交互会话整段过滤成一句「另有会话进行中」，
  /// **不点名**：老师模式和 AI 助手在他的眼里就是「前面的任务」，被那半句话
  /// 吞掉了。现在：
  /// - 队首 + 「还有 N 个」，`N` 只数真实任务（交互会话不排队、不占模型，
  ///   混进计数会把「还有几个要等」说错）；
  /// - 交互会话**必须被点名**（最多 2 个，超出写「等 N 个」）：用户一眼看得见
  ///   「前面那些没消失，在最后一句里」；
  /// - 只有会话开着、没有排队任务时，摘要点名会话，而不是退回一句空话 / 空白。
  String _summaryText(List<AiJob> active, List<AiJob> failed, List<AiJob> done) {
    // 队首只看**真实任务**：交互会话是「页面开着」，它不排队、也不占模型，
    // 让它当队首会让「布置作业编辑中」永远盖住正在排队的出题任务。
    final tasks = active.where((j) => !j.interactive).toList();
    final sessions = active.where((j) => j.interactive).toList();
    final sessionText = _nameList(sessions.map((j) => j.label));
    if (tasks.isNotEmpty) {
      final head = tasks.first;
      final headText = head.status == AiJobStatus.running
          ? head.label
          : '${head.label}（待启动）';
      // 「还有 N 个」= 队首之外的真实任务数；0 个时整句省略（不要「还有 0 个」）。
      final rest = tasks.length - 1;
      final base = rest <= 0 ? headText : '$headText · 还有 $rest 个';
      return sessionText == null ? base : '$base · 会话：$sessionText';
    }
    if (sessions.isNotEmpty) {
      // 没有排队任务，只有会话开着 —— 点名它们（旧实现这里只剩一句
      // 「另有会话进行中」或直接空白，用户以为任务丢了）。
      return '进行中：${sessionText ?? '${sessions.length} 个会话'}';
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

  /// 把若干名字拼成「A、B」；超过 [max] 个时只列前 [max] 个，其余写「等 N 个」。
  ///
  /// 折叠条只有一行（`maxLines: 1` + 省略号）—— 全列会被截断成「看不到是谁」；
  /// 但**一个都不列**更糟：用户会以为那些任务凭空消失了（这正是本次用户报的
  /// 现象）。返回 null = 没有任何可用名字（调用方自行兜底）。
  String? _nameList(Iterable<String> names, {int max = 2}) {
    final list = names.where((n) => n.trim().isNotEmpty).toList();
    if (list.isEmpty) return null;
    if (list.length <= max) return list.join('、');
    return '${list.take(max).join('、')} 等 ${list.length} 个';
  }

  /// 排队行的第二行文案：**说清在等谁**。
  ///
  /// 旧文案「排队中 · 第 N 位（等前面的任务用完模型）」只承认「前面有东西」，
  /// 用户不知道是谁；折叠条上的「（待启动）」更是连位次都没有。现在把通道当前
  /// 持有者（[LlmChannel.holderLabel]，public getter，只读）点名出来。
  ///
  /// 三种情况：
  /// 1. 在通道队里 + 拿得到持有者 → 「待启动 · 第 N 位（等「xxx」用完模型）」；
  /// 2. 不在队里但通道确实被占（服务端队列任务在跑 → 本进程请求还没入队，或
  ///    刚刚被放行的瞬间）→「待启动 · 等「xxx」用完模型」（兜底路径）；
  /// 3. 连持有者都拿不到 → 退回原文案，**不编造**谁在跑。
  ///
  /// 返回 '' = 按普通 message 渲染。
  String _queuedMessageText(int? queuePos) {
    final holder = LlmChannel.instance.holderLabel;
    final hasHolder = LlmChannel.instance.isBusy &&
        holder != null &&
        holder.trim().isNotEmpty;
    if (queuePos != null) {
      return hasHolder
          ? '待启动 · 第 $queuePos 位（等「$holder」用完模型）'
          : '排队中 · 第 $queuePos 位（等前面的任务用完模型）';
    }
    if (hasHolder) return '待启动 · 等「$holder」用完模型';
    return '';
  }

  Widget _jobRow(BuildContext context, AiJob job, List<AiJob> active) {
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
    //
    // **也**不显示累加计时（见下方计时行的 `if (!isInteractive)`）：交互行不是
    // 任务，没有「耗时」语义，一直涨的计时会让用户误以为「卡了很久却没在调用
    // AI」。文案也不承诺「空闲 / 关闭即结束」——关闭页面只释放资源锁，正在进行的
    // 生成由 runDetached 后台任务继续跑完并落库，所以写「后台任务不受影响」是陈述
    // 事实、而非误导。老师模式：交互行锁 `kp:{id}`，该点的生成任务锁 `kp:{id}:chat`
    // → 前缀匹配即可判断「这一点是不是真在生成」。其它入口（作业 `homework:*`、
    // AI 助手 `agent:chat`）判断不了，就走中性文案，不承诺「空闲」以免误导。
    // 托盘文案 = job.message 原文，不再按行种类硬编码覆盖。
    //
    // 旧实现给交互会话行写死「会话已打开 · 后台任务不受影响」，把页面真正
    // 写进去的话（setInteractiveMessage：'第 2 轮：正在思考…'）整段丢掉，
    // 那一行没有一个字在动 → 用户判定「没在生成」（AI 助手报的就是这个）。
    // 现在谁在干什么就显示什么，托盘只负责如实转述。
    final isQueued = job.status == AiJobStatus.queued;
    final queuePos = isQueued ? LlmChannel.instance.positionOf(job.id) : null;
    // 「待启动」必须说清在等谁：只写「排队中 · 第 N 位（等前面的任务用完
    // 模型）」，用户完全不知道是谁占着模型，只能猜「是不是坏了」。
    final queuedText = isQueued ? _queuedMessageText(queuePos) : '';
    final messageText = queuedText.isNotEmpty
        ? queuedText
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
                    if (isQueued) ...[
                      Icon(Icons.hourglass_empty,
                          size: 14, color: colorScheme.outline),
                      const SizedBox(width: 3),
                      Text(
                        '待启动',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 10,
                          color: colorScheme.outline,
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
                    if (!isInteractive) Text(job.elapsedText, style: theme.textTheme.bodySmall),
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
                if (!isInteractive && !isDone && !isQueued) ...[
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

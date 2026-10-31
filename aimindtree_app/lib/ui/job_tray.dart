/// 全局任务托盘（方案 §5.2）：挂在 AppShell，5 个 Tab 常驻可见。
///
/// - **折叠态**（默认，Q3 决策）：4px 细进度条 + 「N 个任务进行中」+ 展开按钮，
///   不挡内容；
/// - **展开态**：每个 job 一行——label、百分比 / 阶段文案、已用时间、取消按钮、
///   所占资源锁徽标（让用户知道「为什么某个按钮点不了」）；交互会话（老师
///   模式 / 作业出题，B4）、后台任务（D：离开页面继续跑）同样登记为行；
///   在途一律可取消，失败行给「重试 + 移除」两个动作；
/// - **终态**：done → SnackBar 摘要 + 3s 后自动折叠；failed → 红条 + 重试；
///   canceled → 直接从托盘消失；``silent`` 任务（如对话检测）只留托盘行，
///   终态不弹 SnackBar。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/ai_job_service.dart';

class JobTray extends StatefulWidget {
  const JobTray({super.key, required this.jobs});

  final AiJobService jobs;

  @override
  State<JobTray> createState() => JobTrayState();
}

class JobTrayState extends State<JobTray> {
  bool _expanded = false;
  Timer? _autoCollapse;

  @override
  void initState() {
    super.initState();
    widget.jobs.revision.addListener(_onRevision);
    widget.jobs.terminalStream.listen(_onTerminal);
    // 冷启动对账：收养服务端仍在跑的 job（App 被杀过）。
    widget.jobs.reconcile();
    // 「查看任务」动作（被挡操作的 SnackBar）→ 展开托盘。
    widget.jobs.onExpandTray = expand;
  }

  @override
  void dispose() {
    widget.jobs.revision.removeListener(_onRevision);
    widget.jobs.onExpandTray = null;
    _autoCollapse?.cancel();
    super.dispose();
  }

  void _onRevision() {
    if (mounted) setState(() {});
  }

  void _onTerminal(AiJob job) {
    if (!mounted) return;
    // 静默任务（如对话检测）：托盘行/红条/重试已给足可见性，不弹 SnackBar。
    if (job.silent) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (job.status) {
      case AiJobStatus.done:
        messenger.showSnackBar(SnackBar(
          content: Text(job.doneMessage ?? '「${job.label}」已完成'),
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
    if (active.isEmpty && failed.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 总进度：有确定性进度的 job 取均值；全在排队/等模型 → 不确定态。
    final percents =
        active.where((j) => j.progressOrNull != null).map((j) => j.progressOrNull!);
    final overall = percents.isEmpty ? null : percents.reduce((a, b) => a + b) / percents.length;
    final hasFailed = failed.isNotEmpty;

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
                        : (active.isEmpty ? Icons.history : Icons.pending_outlined),
                    size: 16,
                    color: hasFailed ? colorScheme.error : colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _summaryText(active, failed),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (active.isNotEmpty) ...[
                    Text(
                      overall == null ? '排队/等待中' : '${(overall * 100).round()}%',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18),
                ],
              ),
            ),
          ),
          // ---- 4px 总进度条（只有失败行时不画进度，画了就是「正在跑」的假象）----
          if (active.isNotEmpty)
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
                      valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
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
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _summaryText(List<AiJob> active, List<AiJob> failed) {
    if (active.isNotEmpty) {
      final n = active.length;
      final first = active.first.label;
      return n == 1 ? first : '$n 个任务进行中（$first 等）';
    }
    if (failed.isNotEmpty) {
      return '${failed.length} 个任务失败，可重试';
    }
    return '';
  }

  Widget _jobRow(BuildContext context, AiJob job) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isFailed = job.status == AiJobStatus.failed;
    final progress = job.progressOrNull;
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
                    if (job.stageTotal > 1)
                      Text(
                        '阶段 ${job.stageIndex}/${job.stageTotal} · ',
                        style: theme.textTheme.bodySmall,
                      ),
                    Expanded(
                      child: Text(
                        '${job.message}${progress != null ? '（${(progress * 100).round()}%）' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isFailed ? colorScheme.error : null,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: SizedBox(
                    height: 3,
                    child: progress == null
                        ? LinearProgressIndicator(
                            minHeight: 3,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                isFailed ? colorScheme.error : colorScheme.primary),
                          )
                        : LinearProgressIndicator(
                            minHeight: 3,
                            value: progress,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                isFailed ? colorScheme.error : colorScheme.primary),
                          ),
                  ),
                ),
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
          // 走页面 / 执行体自己注册的中断回调（B4 + D）。
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

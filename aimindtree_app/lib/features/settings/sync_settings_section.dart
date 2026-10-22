/// SettingsPage 中的「同步」分区（T03 + 任务 B：系统级字段改管理后台下发）。
///
/// 同步为**手动**模式（自动调度已下线）：提供两个独立按钮——
/// 「上传本地到管理端（push）」与「拉取管理端到本地（pull）」。
///
/// 包含：
/// - Base URL / Token：**由管理后台统一下发**（任务 B）——
///   - Base URL 有值时只读展示（标注「由管理后台配置」）；无下发值时保留
///     原手动输入作兜底；
///   - Token 不再手输，展示「Token 由管理后台配置（本机 SecretStore 保存）」；
/// - 上传 / 拉取按钮（分别调 SyncEngine.push / SyncEngine.pull）；
/// - 测试连接按钮；
/// - 状态显示：上次 push/pull 时间 + 待推条数 + 最近错误。
library;

import 'package:flutter/material.dart';

import '../../core/secret_store.dart';
import '../../data/sync/sync_api.dart';
import '../../data/sync/sync_config.dart';
import '../../data/sync/sync_outbox.dart';
import '../../data/sync/sync_scheduler.dart';
import '../../data/sync/sync_status.dart';

class SyncSettingsSection extends StatefulWidget {
  const SyncSettingsSection({
    super.key,
    required this.config,
    required this.statusStore,
    required this.scheduler,
    required this.outbox,
    required this.secretStore,
  });

  final SyncConfig config;
  final SyncStatusStore statusStore;
  final SyncScheduler scheduler;
  final SyncOutboxRepo outbox;
  final SecretStore secretStore;

  @override
  State<SyncSettingsSection> createState() => _SyncSettingsSectionState();
}

class _SyncSettingsSectionState extends State<SyncSettingsSection> {
  late final TextEditingController _url;
  int _pending = 0;
  int _failed = 0;
  String _status = 'idle';

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.config.baseUrl ?? '');
    _status = widget.statusStore.status;
    _refreshCounters();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _refreshCounters() async {
    final p = await widget.outbox.pendingCount();
    final f = await widget.outbox.failedCount();
    if (!mounted) return;
    setState(() {
      _pending = p;
      _failed = f;
      _status = widget.statusStore.status;
    });
  }

  /// 兜底保存：仅「无下发值」时可手动填 Base URL（任务 B）。
  /// Token 一律不手输（由管理后台下发，本机 SecretStore 保存）。
  Future<void> _save() async {
    final url = _url.text.trim();
    await widget.config.setBaseUrl(url);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('同步配置已保存（重启 App 后生效）。')),
    );
  }

  Future<void> _pushNow() async {
    if (!widget.config.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('尚未收到管理后台下发的同步配置。')),
      );
      return;
    }
    _warnIfStaleApi();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在上传…')),
    );
    await widget.statusStore.setStatus('syncing');
    try {
      final report = await widget.scheduler.engine.push();
      await widget.statusStore.setLastPushAt(DateTime.now().toUtc());
      await widget.statusStore.setStatus('ok');
      await _refreshCounters();
      if (!mounted) return;
      final failedNote = report.failed > 0 ? '，失败 ${report.failed} 条' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('上传完成：推送 ${report.pushed} 条$failedNote'),
          backgroundColor: report.failed > 0 ? Colors.red : Colors.green,
        ),
      );
    } on Object catch (e) {
      await widget.statusStore.setStatus('error:$e');
      await _refreshCounters();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('上传失败：$e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _pullNow() async {
    if (!widget.config.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('尚未收到管理后台下发的同步配置。')),
      );
      return;
    }
    _warnIfStaleApi();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在拉取…')),
    );
    await widget.statusStore.setStatus('syncing');
    try {
      final report = await widget.scheduler.engine.pull();
      await widget.statusStore.setLastPulledAt(report.serverTime);
      await widget.statusStore.setStatus('ok');
      await _refreshCounters();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('拉取完成：应用 ${report.applied} 条变更'),
          backgroundColor: Colors.green,
        ),
      );
    } on Object catch (e) {
      await widget.statusStore.setStatus('error:$e');
      await _refreshCounters();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('拉取失败：$e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// stale api 防护：HttpSyncApi 在 bootstrap 一次性构建，管理后台运行时改
  /// Base URL 不会热更新到已构造实例。比对当前配置与实例地址，不一致时
  /// 提醒重启 App（不重构 bootstrap）。
  void _warnIfStaleApi() {
    final api = widget.scheduler.api;
    if (api is! HttpSyncApi) return; // MockSyncApi 占位：无真实地址可比
    final configured = (widget.config.baseUrl ?? '').trim();
    final actual = api.baseUrl.trim();
    if (configured.isNotEmpty && configured != actual) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('同步地址已在管理后台变更，重启 App 后生效')),
      );
    }
  }

  Future<void> _testConnection() async {
    if (!widget.config.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('尚未收到管理后台下发的同步配置。')),
      );
      return;
    }
    final err = await widget.scheduler.testConnection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(err == null ? '连接成功' : '连接失败：$err'),
        backgroundColor: err == null ? Colors.green : Colors.red,
      ),
    );
  }

  String _formatTime(DateTime? t) {
    if (t == null) return '从未';
    final l = t.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, "0")}-${l.day.toString().padLeft(2, "0")} '
        '${l.hour.toString().padLeft(2, "0")}:${l.minute.toString().padLeft(2, "0")}';
  }

  @override
  Widget build(BuildContext context) {
    final baseUrl = (widget.config.baseUrl ?? '').trim();
    final hasBaseUrl = baseUrl.isNotEmpty;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            '同步（Supabase ai-proxy）',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Base URL：有下发值 → 只读展示；无下发值 → 保留手动输入兜底。
              if (hasBaseUrl)
                _ReadOnlyField(
                  label: 'Base URL',
                  value: baseUrl,
                  note: '由管理后台配置',
                )
              else
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    helperText: '形如 https://xxx.supabase.co/functions/v1/ai-proxy',
                  ),
                ),
              const SizedBox(height: 8),
              // Token：不手输，展示后台下发状态（本体在 SecretStore）。
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Token 由管理后台配置（本机 SecretStore 保存）',
                    style: TextStyle(fontSize: 13),
                  ),
                  Text(
                    widget.config.tokenRef == null
                        ? '（未配置）'
                        : '（已保存，引用名 ${widget.config.tokenRef}）',
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 兜底模式才需要「保存配置」；只读模式下没有可手改的字段。
              if (!hasBaseUrl)
                Row(
                  children: [
                    FilledButton.tonal(
                      onPressed: _save,
                      child: const Text('保存配置'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _testConnection,
                      child: const Text('测试连接'),
                    ),
                  ],
                )
              else
                OutlinedButton(
                  onPressed: _testConnection,
                  child: const Text('测试连接'),
                ),
              const SizedBox(height: 8),
              // 手动同步（自动调度已下线）：push / pull 各自独立触发。
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _pushNow,
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('上传本地到管理端'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _pullNow,
                      icon: const Icon(Icons.cloud_download_outlined),
                      label: const Text('拉取管理端到本地'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _StatusLine(
                status: _status,
                pending: _pending,
                failed: _failed,
                lastPush: widget.statusStore.lastPushAt,
                lastPull: widget.statusStore.lastPulledAt,
                formatTime: _formatTime,
              ),
              const SizedBox(height: 8),
              Text(
                '• Base URL / Token 由管理后台统一下发，本机不可修改；\n'
                '• Token 仅本机 SecretStore 保存，不入 DB；\n'
                '• 同步为手动：上传 = 本地 → 管理端，拉取 = 管理端 → 本地；\n'
                '• 跨设备冲突用 LWW（version 大者赢），自回声自动过滤。',
                style: TextStyle(
                  color: theme.disabledColor,
                  fontSize: 11,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 只读字段（任务 B）：系统级配置由管理后台下发，本机只展示。
class _ReadOnlyField extends StatelessWidget {
  const _ReadOnlyField({
    required this.label,
    required this.value,
    required this.note,
  });

  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: theme.hintColor, fontSize: 12)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 2),
          Text(note, style: TextStyle(color: theme.hintColor, fontSize: 11)),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.status,
    required this.pending,
    required this.failed,
    required this.lastPush,
    required this.lastPull,
    required this.formatTime,
  });

  final String status;
  final int pending;
  final int failed;
  final DateTime? lastPush;
  final DateTime? lastPull;
  final String Function(DateTime?) formatTime;

  @override
  Widget build(BuildContext context) {
    final isError = status.startsWith('error');
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isError ? Colors.red.shade50 : Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '状态：$status',
            style: TextStyle(
              fontSize: 12,
              color: isError ? Colors.red : Colors.blueGrey.shade800,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '待推：$pending 条　失败：$failed 条\n'
            '上次 push：${formatTime(lastPush)}\n'
            '上次 pull：${formatTime(lastPull)}',
            style: const TextStyle(fontSize: 11, color: Colors.black87),
          ),
        ],
      ),
    );
  }
}

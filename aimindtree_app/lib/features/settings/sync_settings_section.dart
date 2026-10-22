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
import '../../data/sync/sync_account.dart';
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
  late final TextEditingController _cfUrl;
  late final TextEditingController _cfUser;
  late final TextEditingController _cfPass;
  int _pending = 0;
  int _failed = 0;
  String _status = 'idle';

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.config.baseUrl ?? '');
    _cfUrl = TextEditingController(text: widget.config.cfUrl ?? '');
    _cfUser = TextEditingController(text: widget.config.cfUsername ?? '');
    _cfPass = TextEditingController();
    _status = widget.statusStore.status;
    _refreshCounters();
  }

  @override
  void dispose() {
    _url.dispose();
    _cfUrl.dispose();
    _cfUser.dispose();
    _cfPass.dispose();
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

  Future<void> _saveCf() async {
    await widget.config.setCfUrl(_cfUrl.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('CF 同步配置已保存（重启 App 后生效）。')),
    );
  }

  /// 登录/注册 CF 账号（方案 B 多租户）：成功后保存每用户令牌，普通用户无需填共享 token。
  Future<void> _account({required bool register}) async {
    final url = widget.config.cfUrl?.trim();
    if (url == null || url.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写 CF Worker URL。')),
      );
      return;
    }
    final username = _cfUser.text.trim();
    final password = _cfPass.text;
    if (username.isEmpty || password.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入用户名和密码。')),
      );
      return;
    }
    final api = SyncAccountApi(baseUrl: url);
    try {
      final session =
          register ? await api.register(username, password) : await api.login(username, password);
      await widget.config.setCfUsername(username);
      await widget.config.setCfUserToken(session.token);
      _cfPass.clear();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(register ? '注册并登录成功：$username' : '登录成功：$username'),
          backgroundColor: Colors.green,
        ),
      );
    } on SyncAccountApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${register ? '注册' : '登录'}失败：${e.message}'), backgroundColor: Colors.red),
      );
    } finally {
      api.close();
    }
  }

  /// 退出 CF 账号：清本地用户名与每用户令牌。
  Future<void> _logoutCf() async {
    await widget.config.setCfUserToken(null);
    await widget.config.setCfUsername(null);
    _cfUser.clear();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已退出 CF 账号。')),
    );
  }

  /// 开发期手动同步：按目标（llm / CF）× 方向（上传 / 拉取）触发。
  ///
  /// 复用 [widget.scheduler.engine] 的本地 outbox / deviceId，仅覆盖其 [api]
  /// 指向对应后端。拉取前强制游标归零（dev 期两个后端共用游标，避免漏拉）。
  Future<void> _runSync({required bool toCf, required bool push}) async {
    final url = toCf ? widget.config.cfUrl : widget.config.llmUrl;
    if (url == null || url.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(toCf ? '未配置 CF 同步地址。' : '未配置 llm_server 同步地址。'),
        ),
      );
      return;
    }
    String? token;
    if (toCf) {
      // CF 走账号登录（多租户）：取每用户令牌；未登录则提示先登录/注册。
      final userToken = await widget.config.resolveCfUserToken();
      if (userToken == null || userToken.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在 Cloudflare 账号卡片登录/注册。')),
        );
        return;
      }
      token = userToken;
    } else {
      token = await widget.config.resolveToken(); // 可能为空（relay 开发期免 token）
    }

    final api = HttpSyncApi(baseUrl: url.trim(), userToken: token ?? '');
    final engine = widget.scheduler.engine;
    if (!push) {
      engine.updateLastPulledAt(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(push ? '正在上传…' : '正在拉取…')),
    );
    await widget.statusStore.setStatus('syncing');
    try {
      if (push) {
        final report = await engine.push(api: api);
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
      } else {
        final report = await engine.pull(api: api);
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
      }
    } on Object catch (e) {
      await widget.statusStore.setStatus('error:$e');
      await _refreshCounters();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(push ? '上传失败：$e' : '拉取失败：$e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Cloudflare 账号卡片：已登录显示只读状态 + 退出；未登录显示用户名/密码 + 登录/注册。
  Widget _cfAccountCard() {
    final username = widget.config.cfUsername;
    final loggedIn = username != null && username.isNotEmpty;
    if (loggedIn) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ReadOnlyField(
            label: 'Cloudflare 账号',
            value: username,
            note: '已登录（每用户令牌本机 SecretStore 保存）',
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: _logoutCf,
            child: const Text('退出登录'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _cfUser,
          decoration: const InputDecoration(labelText: '用户名'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _cfPass,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '密码',
            helperText: '自助注册：用户名≥3、密码≥8',
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: () => _account(register: false),
                child: const Text('登录'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _account(register: true),
                child: const Text('注册'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _testConnection() async {
    if (!widget.config.isLlmConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('尚未配置 llm_server 同步地址。')),
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
            '同步（可指向 llm_server / Cloudflare）',
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
              // ---- Cloudflare 目标（方案 B，可选）----
              const Divider(),
              const Text(
                'Cloudflare 目标（方案 B）',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _cfUrl,
                decoration: const InputDecoration(
                  labelText: 'CF Worker URL',
                  helperText: '形如 https://<subdomain>.workers.dev',
                ),
              ),
              const SizedBox(height: 8),
              // ---- Cloudflare 账号（方案 B 多租户）----
              // 普通用户自助注册/登录，无需填写任何共享 token；登录后令牌本机保存。
              _cfAccountCard(),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: _saveCf,
                child: const Text('保存 CF 配置'),
              ),
              const SizedBox(height: 8),
              // 开发期手动同步：两个目标 × 上传 / 拉取 = 4 个按钮。
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _runSync(toCf: false, push: true),
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('上传到 llmserver'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _runSync(toCf: true, push: true),
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('上传到 CF'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _runSync(toCf: false, push: false),
                      icon: const Icon(Icons.cloud_download_outlined),
                      label: const Text('从 llmserver 拉取'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _runSync(toCf: true, push: false),
                      icon: const Icon(Icons.cloud_download_outlined),
                      label: const Text('从 CF 拉取'),
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
                '• 默认指向本机 llm_server（127.0.0.1:8787）；CF 需先填 URL 并登录/注册账号；\n'
                '• 普通用户用用户名+密码自助注册，无需填写任何共享 token；\n'
                '• 每用户令牌仅本机 SecretStore 保存，按账号隔离数据，不入 DB；\n'
                '• 同步为手动：上传 = 本地 → 目标，拉取 = 目标 → 本地；\n'
                '• 跨设备冲突用 LWW（version 大者赢），自回声自动过滤；\n'
                '• 上传会消费本地 outbox（标记 done）；同一份数据传两个后端请先清空 outbox 或换库。',
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

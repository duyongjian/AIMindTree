/// SettingsPage 中的「同步」分区。
///
/// 精简版 UI：标题「同步」+ 登录卡片（CF 自助注册/登录）+ 四个按钮
/// （llm_server / CF × 上传 / 拉取）。CF Worker 地址已内置，用户无需填写。
library;

import 'package:flutter/material.dart';

import '../../core/secret_store.dart';
import '../../data/sync/http_proxy.dart';
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
  late final TextEditingController _cfUser;
  late final TextEditingController _cfPass;

  @override
  void initState() {
    super.initState();
    _cfUser = TextEditingController(text: widget.config.cfUsername ?? '');
    _cfPass = TextEditingController();
  }

  @override
  void dispose() {
    _cfUser.dispose();
    _cfPass.dispose();
    super.dispose();
  }

  /// 登录/注册 CF 账号（方案 B 多租户）：成功后保存每用户令牌，普通用户无需填共享 token。
  Future<void> _account({required bool register}) async {
    // 地址内置，用户无需填写（方案 B 已部署的 Worker）。
    final url = widget.config.cfUrlResolved;
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
    } on Object catch (e) {
      // 兜底：任何未预期异常都要变成可见提示，不能静默（否则「点了没反应」）。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${register ? '注册' : '登录'}失败：$e'), backgroundColor: Colors.red),
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
    final url = toCf ? widget.config.cfUrlResolved : widget.config.llmUrl;
    if (url.trim().isEmpty) {
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
        // 先增量（outbox 里的变更语义，含墓碑），再全量快照（历史存量对齐）。
        // 只跑增量的话，同步接线之前创建的数据一条都发不出去
        //（用户实测现象：「提示上传成功，但是 0 条」）。
        final inc = await engine.push(api: api);
        final snap = await engine.pushAll(api: api);
        final total = inc.pushed + snap.pushed;
        final failed = inc.failed + snap.failed;
        await widget.statusStore.setLastPushAt(DateTime.now().toUtc());
        await widget.statusStore.setStatus('ok');
        if (!mounted) return;
        final failedNote = failed > 0 ? '，失败 $failed 条' : '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '上传完成：增量 ${inc.pushed} 条 + 快照 ${snap.pushed} 条，'
              '共 $total 条$failedNote',
            ),
            backgroundColor: failed > 0 ? Colors.red : Colors.green,
          ),
        );
      } else {
        final report = await engine.pull(api: api);
        await widget.statusStore.setLastPulledAt(report.serverTime);
        await widget.statusStore.setStatus('ok');
        if (!mounted) return;
        // skipped 也是证据：它 = 「服务端确实存有本机自己上传的行」。
        // 只报 applied 的话，自己刚传上去的数据拉回来会显示「应用 0 条」，
        // 让人误以为拉取失败。
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '拉取完成：应用 ${report.applied} 条变更，'
              '跳过 ${report.skipped} 条（本机自己上传的）',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } on Object catch (e) {
      await widget.statusStore.setStatus('error:$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(push ? '上传失败：$e' : '拉取失败：$e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// 「我的账号」卡片：顶部状态徽章（已登录/未登录）+ 账号信息 / 登录注册表单。
  ///
  /// 登录/注册成功后 `setState` 触发重建 → 徽章由灰「未登录」变绿「已登录」
  /// 并显示用户名，状态切换肉眼可辨；失败则该卡片保持「未登录」+ 红条提示。
  Widget _cfAccountCard() {
    final username = widget.config.cfUsername;
    final loggedIn = username != null && username.isNotEmpty;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.account_circle_outlined,
                color: theme.colorScheme.primary,
                size: 22,
              ),
              const SizedBox(width: 6),
              const Text(
                '我的账号',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const Spacer(),
              _StatusChip(
                text: loggedIn ? '已登录' : '未登录',
                ok: loggedIn,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (loggedIn) ...[
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
          ] else ...[
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
            const SizedBox(height: 4),
            Text(
              '首次使用点「注册」，成功后徽章会变成绿色「已登录」。',
              style: TextStyle(color: theme.hintColor, fontSize: 11),
            ),
          ],
          // 网络通道诊断（直连 / 代理）：注册失败时先看这一行。
          _networkLine(),
        ],
      ),
    );
  }

  /// 网络通道诊断行。
  ///
  /// Dart 的 HttpClient 默认直连、不读系统代理，这正是此前「点注册没反应」
  /// （SocketException errno 121）的根因。启动时已自动探测代理，这里把结果
  /// 显式写出来，出问题一眼能分清是「没走代理」还是「代理也不通」。
  Widget _networkLine() {
    final proxy = detectedSystemProxy;
    final viaProxy = proxy != null && proxy.isNotEmpty;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            viaProxy ? Icons.shield_outlined : Icons.wifi,
            size: 13,
            color: theme.hintColor,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              viaProxy ? '网络通道：经由代理 $proxy' : '网络通道：直连（未探测到系统代理）',
              style: TextStyle(color: theme.hintColor, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            '同步',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 登录卡片（Cloudflare 自助注册 / 登录）
              _cfAccountCard(),
              const SizedBox(height: 16),
              // 手动同步：两个目标 × 上传 / 拉取 = 四个按钮
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
            ],
          ),
        ),
      ],
    );
  }
}

/// 状态徽章：ok=true 绿色「已登录」，false 灰色「未登录」。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text, required this.ok});

  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? Colors.green : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
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

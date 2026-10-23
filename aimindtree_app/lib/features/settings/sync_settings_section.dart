/// SettingsPage 中的「同步」分区。
///
/// 精简版 UI：标题「同步」+ 登录卡片（CF 自助注册/登录）+ 四个按钮
/// （llm_server / CF × 上传 / 拉取）+ 「服务器与网络」卡片（自定义同步地址
/// 与 HTTP 代理）。CF Worker 地址已内置，用户无需填写即可开箱即用；
/// 换中继 / 走代理都在这张卡里配，不必重新编译 App。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/secret_store.dart';
import '../../data/sync/direct_connect.dart';
import '../../data/sync/http_proxy.dart';
import '../../data/sync/sync_api.dart';
import '../../data/sync/sync_account.dart';
import '../../data/sync/sync_config.dart';
import '../../data/sync/sync_outbox.dart';
import '../../data/sync/sync_scheduler.dart';
import '../../data/sync/sync_status.dart';

/// 「测试连接」的单次请求预算：够绕过一次 DNS + TLS 握手，又不让用户干等。
const Duration _kTestTimeout = Duration(seconds: 15);

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
  late final TextEditingController _endpoint;
  late final TextEditingController _proxy;

  /// 保存 / 测试连接进行中：置灰按钮，防重复点击。
  bool _busy = false;

  /// 最近一次「测试连接」的结果；null 表示还没测过。
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _cfUser = TextEditingController(text: widget.config.cfUsername ?? '');
    _cfPass = TextEditingController();
    // 地址回显用 cfUrl（用户自己的覆盖值）而不是 cfUrlResolved，否则会把
    // 内置默认显示成「用户填过的值」，用户以为自己改过。
    _endpoint = TextEditingController(text: widget.config.cfUrl?.trim() ?? '');
    _proxy = TextEditingController(text: widget.config.cfProxy ?? '');
  }

  @override
  void dispose() {
    _cfUser.dispose();
    _cfPass.dispose();
    _endpoint.dispose();
    _proxy.dispose();
    super.dispose();
  }

  void _snack(String text, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
  }

  /// 校验「同步服务器地址」；返回 null 表示通过，否则返回错误文案。
  String? _validateEndpoint(String raw) {
    final url = raw.trim();
    if (url.isEmpty) return null; // 留空 = 用内置默认
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return '同步地址需以 http:// 或 https:// 开头';
    }
    if (Uri.tryParse(url) == null) return '同步地址格式不正确';
    return null;
  }

  /// 校验「HTTP 代理」；返回 null 表示通过，否则返回错误文案。
  String? _validateProxy(String raw) {
    final p = raw.trim();
    if (p.isEmpty) return null; // 留空 = 直连 / 自动探测
    final idx = p.lastIndexOf(':');
    if (idx <= 0 || idx == p.length - 1) return '代理格式应为 host:port';
    final port = int.tryParse(p.substring(idx + 1).trim());
    if (port == null || port <= 0 || port > 65535) return '代理端口不合法';
    return null;
  }

  /// 保存地址与代理。
  ///
  /// 同步 API 在 bootstrap 里一次性装配，改完不会自动重建（项目里已有
  /// `_warnIfStaleApi` 处理这种情况），所以这里明确提示需重启。
  Future<void> _saveEndpoint() async {
    final urlError = _validateEndpoint(_endpoint.text);
    if (urlError != null) {
      _snack(urlError, ok: false);
      return;
    }
    final proxyError = _validateProxy(_proxy.text);
    if (proxyError != null) {
      _snack(proxyError, ok: false);
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.config.setCfUrl(_endpoint.text.trim());
      final proxy = _proxy.text.trim();
      await widget.config.setCfProxy(proxy);
      // 让当前进程立即生效（重启后由 bootstrap 从 prefs 读）。
      setUserProxy(proxy.isEmpty ? null : proxy);
      if (!mounted) return;
      setState(() {});
      _snack('已保存，需重启应用后完全生效');
    } on Object catch (e) {
      _snack('保存失败：$e', ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 用当前输入框里的地址发一个 GET / 探测连通性。
  ///
  /// 客户端走 [createDirectHttpClient]（DoH / 代理 / 探测逻辑与真实同步链路
  /// 完全一致），测出来的结论才有意义；换一个普通 HttpClient 会得到不一样
  /// 的结果，用户据此判断会走偏。
  Future<void> _testEndpoint() async {
    final urlError = _validateEndpoint(_endpoint.text);
    if (urlError != null) {
      _snack(urlError, ok: false);
      return;
    }
    final proxyError = _validateProxy(_proxy.text);
    if (proxyError != null) {
      _snack(proxyError, ok: false);
      return;
    }

    setState(() {
      _busy = true;
      _testResult = null;
    });

    final typed = _endpoint.text.trim();
    final url = typed.isEmpty ? widget.config.cfUrlResolved : typed;
    final typedProxy = _proxy.text.trim();
    final savedProxy = widget.config.cfProxy;
    // 测的就是「此刻输入框里的值」：代理同样临时套用，测完复原为已保存值。
    setUserProxy(typedProxy.isEmpty ? null : typedProxy);

    HttpClient? client;
    final sw = Stopwatch()..start();
    try {
      client = await createDirectHttpClient(url);
      final root = Uri.parse(url.endsWith('/') ? url : '$url/');
      final req = await client.getUrl(root).timeout(_kTestTimeout);
      final resp = await req.close().timeout(_kTestTimeout);
      if (!mounted) return;
      setState(
        () => _testResult =
            'HTTP ${resp.statusCode}（${sw.elapsedMilliseconds}ms）',
      );
    } on TimeoutException catch (e) {
      if (!mounted) return;
      setState(() => _testResult = '超时（${sw.elapsedMilliseconds}ms）：$e');
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _testResult = '连接失败：$e');
    } finally {
      client?.close(force: true);
      setUserProxy(savedProxy);
      if (mounted) setState(() => _busy = false);
    }
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
        //
        // 增量用 pushDrain 而不是单次 push：单次 push 只推 100 条，积压超过
        // 100 时用户会连续几次看到同样的「增量 100 条」，像卡住（实测就是
        // 「增量 100 条 + 快照 159 条」）；而且 pending 占满 limit 后失败行
        // 永远轮不到重试。pushDrain 会循环到 outbox 排空为止。
        final inc = await engine.pushDrain(api: api);
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

  /// 「服务器与网络」卡片：自定义同步地址 + 自定义 HTTP 代理。
  ///
  /// 存在的理由：实测有用户线路既被 DNS 投毒（返回黑洞 IP），又把 Cloudflare
  /// 的 IP 段整个封掉——连 DoH 拿到的真 IP 也 TCP 超时。这种环境里，换国内
  /// 中继（改地址）或走代理出国（填代理）是唯二出路，都应该**不用重新编译
  /// App** 就能配。
  Widget _serverNetworkCard() {
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
              Icon(Icons.dns_outlined, color: theme.colorScheme.primary, size: 22),
              const SizedBox(width: 6),
              const Text(
                '服务器与网络',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _endpoint,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: '同步服务器地址',
              helperText:
                  '留空则使用内置默认：${SyncConfig.kSyncCfDefaultBaseUrl}',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _proxy,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'HTTP 代理',
              helperText: '例如 127.0.0.1:7890，留空则直连/自动探测',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _saveEndpoint,
                  child: const Text('保存'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _testEndpoint,
                  child: const Text('测试连接'),
                ),
              ),
            ],
          ),
          if (_testResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '结果：$_testResult',
                style: TextStyle(color: theme.hintColor, fontSize: 11),
              ),
            ),
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
    final manual = userProxyOverride;
    final viaProxy = manual != null && manual.isNotEmpty
        ? manual
        : (proxy != null && proxy.isNotEmpty ? proxy : null);
    final theme = Theme.of(context);
    String text;
    if (viaProxy != null) {
      text = manual != null && manual.isNotEmpty
          ? '网络通道：经由手动代理 $manual'
          : '网络通道：经由代理 $proxy';
    } else {
      text = '网络通道：直连（未探测到系统代理）';
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            viaProxy != null ? Icons.shield_outlined : Icons.wifi,
            size: 13,
            color: theme.hintColor,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
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
              // 「服务器与网络」卡片（自定义同步地址 / HTTP 代理）
              _serverNetworkCard(),
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

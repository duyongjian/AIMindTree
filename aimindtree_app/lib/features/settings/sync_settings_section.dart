/// SettingsPage 中的「同步」分区。
///
/// 多后端 UI（Cloudflare / 腾讯云 CloudBase / Vercel / EdgeOne Pages / Netlify
/// 五选一；原 llm_server 目标已移除）：顶部后端选择器 → 当前后端的账号卡片
/// （自助注册/登录）→ 上传/拉取按钮 → 「服务器与网络」卡片（自定义地址 +
/// HTTP 代理 + 测试连接）。
///
/// 要点：
/// - 五个中继的 HTTP 契约逐字一致，App 侧只换地址；五个后端的账号体系
///   **互相独立**（同一用户在 CF 与 CloudBase 上是不同账号），用户名/令牌
///   按后端隔离存储（见 [SyncConfig]）；
/// - CF / CloudBase 地址已内置，用户无需填写即可开箱即用；Vercel（已填部署
///   域名）/ EdgeOne / Netlify 中选未回填的会明确提示「待配置」，不会静默失败；
/// - EdgeOne Pages 是国内永久免费链路，但请求体 1MB 硬限；CloudBase 的 HTTP
///   访问服务网关同样实测 ~1MB 请求体硬限（413）。两者的推送预算都收紧到
///   850KB，大图片附件（note_assets）会被本机切批逻辑标记失败，建议这类数据
///   走 CF / Netlify；
/// - Netlify 为海外/备份链路（函数跑美/欧单区，国内直连可达性差），非国内首选；
/// - 换中继 / 走代理都在「服务器与网络」卡里配，不必重新编译 App。
library;

import 'dart:async';
import 'dart:convert';
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
import '../../data/sync/sync_url.dart';

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
  /// 当前选中的后端（表单 / 按钮都跟着它走）。
  late SyncBackend _backend;

  late final TextEditingController _user;
  late final TextEditingController _pass;
  late final TextEditingController _endpoint;
  late final TextEditingController _proxy;

  /// 当前后端是否已登录（用户名 + 每用户令牌都在）。
  bool _loggedIn = false;

  /// 保存 / 测试连接进行中：置灰按钮，防重复点击。
  bool _busy = false;

  /// 最近一次「测试连接」的结果；null 表示还没测过。
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _backend = widget.config.selectedBackend;
    _user = TextEditingController(text: widget.config.usernameOf(_backend) ?? '');
    _pass = TextEditingController();
    // 地址回显用 urlOverrideOf（用户自己的覆盖值）而不是 urlOf，否则会把
    // 内置默认显示成「用户填过的值」，用户以为自己改过。
    _endpoint =
        TextEditingController(text: widget.config.urlOverrideOf(_backend)?.trim() ?? '');
    _proxy = TextEditingController(text: widget.config.cfProxy ?? '');
    _refreshLoginState();
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _endpoint.dispose();
    _proxy.dispose();
    super.dispose();
  }

  /// 重读当前后端的登录态（登录 / 登出 / 切后端后调用）。
  Future<void> _refreshLoginState() async {
    final ok = await widget.config.isLoggedIn(_backend);
    if (!mounted) return;
    setState(() => _loggedIn = ok);
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

  /// 切换同步后端：写回 [SyncConfig.selectedBackend]，表单 / 地址回显 /
  /// 登录态全部换成该后端的数据（三个后端账号互相独立，不共用）。
  Future<void> _selectBackend(SyncBackend b) async {
    if (b == _backend) return;
    await widget.config.setSelectedBackend(b);
    if (!mounted) return;
    setState(() {
      _backend = b;
      _user.text = widget.config.usernameOf(b) ?? '';
      _pass.clear();
      _endpoint.text = widget.config.urlOverrideOf(b)?.trim() ?? '';
      _testResult = null; // 上一个后端的测试结果不适用
    });
    await _refreshLoginState();
  }

  /// 保存地址与代理。
  ///
  /// 同步 API 在 bootstrap 里一次性装配，改完不会自动重建（保存后明确提示
  /// 需重启），所以这里必须说清楚。
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
      await widget.config.setUrl(_backend, _endpoint.text.trim());
      final proxy = _proxy.text.trim();
      await widget.config.setCfProxy(proxy);
      // 让当前进程立即生效（重启后由 bootstrap 从 prefs 读）。
      setUserProxy(proxy.isEmpty ? null : proxy);
      if (!mounted) return;
      setState(() {});
      // Vercel 防呆：手填 *.vercel.app 裸域名时 normalizeSyncBaseUrl 会自动补
      // /api（Vercel 平台把 api/ 函数挂在 /api/* 下，缺前缀在平台层 404，
      // 实测「注册失败：auth auth/register 返回 404」即此）。明确告知补过，
      // 避免「填的 A、实际请求 B」的困惑。
      final typedUrl = _endpoint.text.trim();
      final normalized = normalizeSyncBaseUrl(typedUrl);
      if (normalized.isNotEmpty && normalized != typedUrl) {
        _snack('已自动为 Vercel 地址补充 /api 前缀：$normalized');
      } else {
        _snack('已保存，需重启应用后完全生效');
      }
    } on Object catch (e) {
      _snack('保存失败：$e', ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 用当前输入框里的地址探测连通性（测当前选中后端）。
  ///
  /// 探针是**无令牌** `GET <base>/sync/manifest`：五个中继的契约逐字一致，
  /// `/sync/*` 缺少/无效令牌一律返回 `401 {"error":"unauthorized"}`。因此
  /// 「401 + 这个 JSON 形状」是强连通证据——它同时证明了 DNS/TLS/代理链路、
  /// 平台路由（没有把请求落到静态 404 上）和业务函数的鉴权层都在工作。
  ///
  /// 之所以不探测根路径 `/`：CF Worker 对 `/` 固定 404，而平台级 404（地址填错、
  /// 少前缀）与业务 404 无法从状态码区分——旧实现「任意状态码判通」就把填错
  /// 地址显示的 404 报成了「已连通」（Vercel 裸域名事故即此）。
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

    final typed = _endpoint.text.trim();
    final url = typed.isEmpty ? widget.config.urlOf(_backend) : typed;
    if (url.isEmpty) {
      _snack('${_backend.label} 尚未配置地址：请先填写完整地址再测试。', ok: false);
      return;
    }
    final typedProxy = _proxy.text.trim();
    final savedProxy = widget.config.cfProxy;
    // 测的就是「此刻输入框里的值」：代理同样临时套用，测完复原为已保存值。
    setUserProxy(typedProxy.isEmpty ? null : typedProxy);

    setState(() {
      _busy = true;
      _testResult = null;
    });

    HttpClient? client;
    final sw = Stopwatch()..start();
    try {
      client = await createDirectHttpClient(url);
      // 无令牌探针：去结尾斜杠后拼 /sync/manifest（App 侧同款拼接规则）。
      final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
      final probe = Uri.parse('$base/sync/manifest');
      final req = await client.getUrl(probe).timeout(_kTestTimeout);
      final resp = await req.close().timeout(_kTestTimeout);
      final status = resp.statusCode;
      final payload = await resp.transform(utf8.decoder).join();

      // 判定表：只有 200、或「401 + JSON + error==unauthorized」判连通；
      // 其余（平台 404 HTML / 503 / 其他）只报状态码，不判连通。
      var connected = false;
      String? note;
      if (status == 200) {
        connected = true;
      } else if (status == 401) {
        String? relayError;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map && decoded['error'] is String) {
            relayError = decoded['error'] as String;
          }
        } on Object {
          // 非 JSON 响应体（平台错误页 / 网关拦截页）：不作为连通证据。
        }
        if (relayError == 'unauthorized') {
          connected = true;
          note = '（中继在线，鉴权正常）';
        }
      }
      final verdict = connected ? '已连通$note' : '';
      if (!mounted) return;
      setState(
        () => _testResult =
            'HTTP $status（${sw.elapsedMilliseconds}ms）$verdict',
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

  /// 登录/注册当前后端的账号（多租户）：成功后保存每用户令牌，普通用户无需填共享 token。
  Future<void> _account({required bool register}) async {
    final url = widget.config.urlOf(_backend).trim();
    if (url.isEmpty) {
      _snack('${_backend.label} 尚未配置地址，无法登录/注册。', ok: false);
      return;
    }
    final username = _user.text.trim();
    final password = _pass.text;
    if (username.isEmpty || password.isEmpty) {
      _snack('请输入用户名和密码。', ok: false);
      return;
    }
    final api = SyncAccountApi(baseUrl: url);
    try {
      final session =
          register ? await api.register(username, password) : await api.login(username, password);
      await widget.config.setUsername(_backend, username);
      await widget.config.setUserToken(_backend, session.token);
      _pass.clear();
      if (!mounted) return;
      setState(() {});
      await _refreshLoginState();
      _snack(register ? '注册并登录成功：$username' : '登录成功：$username');
    } on SyncAccountApiException catch (e) {
      _snack('${register ? '注册' : '登录'}失败：${e.message}', ok: false);
    } on Object catch (e) {
      // 兜底：任何未预期异常都要变成可见提示，不能静默（否则「点了没反应」）。
      _snack('${register ? '注册' : '登录'}失败：$e', ok: false);
    } finally {
      api.close();
    }
  }

  /// 退出当前后端账号：清本地用户名与每用户令牌（不影响其他后端）。
  Future<void> _logout() async {
    await widget.config.setUserToken(_backend, null);
    await widget.config.setUsername(_backend, null);
    _user.clear();
    _pass.clear();
    if (!mounted) return;
    setState(() {});
    await _refreshLoginState();
    _snack('已退出 ${_backend.label} 账号。');
  }

  /// 开发期手动同步：对当前选中后端触发上传 / 拉取。
  ///
  /// 复用 [widget.scheduler.engine] 的本地 outbox / deviceId，仅覆盖其 [api]
  /// 指向对应后端。拉取前强制游标归零（dev 期各后端共用游标，避免漏拉）。
  Future<void> _runSync({required bool push}) async {
    final backend = _backend;
    final url = widget.config.urlOf(backend).trim();
    if (url.isEmpty) {
      _snack('${backend.label} 尚未配置地址，无法同步。', ok: false);
      return;
    }
    // 每用户令牌按后端隔离取；未登录则提示先登录/注册。
    final token = await widget.config.resolveUserToken(backend);
    if (token == null || token.isEmpty) {
      _snack('请先在 ${backend.label} 账号卡片登录/注册。', ok: false);
      return;
    }

    final api = HttpSyncApi(baseUrl: url, userToken: token, backend: backend);
    final engine = widget.scheduler.engine;
    if (!push) {
      engine.updateLastPulledAt(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    }
    _snack(push ? '正在上传…' : '正在拉取…');
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
        _snack(
          '上传到 ${backend.label} 完成：增量 ${inc.pushed} 条 + 快照 ${snap.pushed} 条，'
          '共 $total 条$failedNote',
          ok: failed == 0,
        );
      } else {
        final report = await engine.pull(api: api);
        await widget.statusStore.setLastPulledAt(report.serverTime);
        await widget.statusStore.setStatus('ok');
        if (!mounted) return;
        // skipped 也是证据：它 = 「服务端确实存有本机自己上传的行」。
        // 只报 applied 的话，自己刚传上去的数据拉回来会显示「应用 0 条」，
        // 让人误以为拉取失败。
        _snack(
          '从 ${backend.label} 拉取完成：应用 ${report.applied} 条变更，'
          '跳过 ${report.skipped} 条（本机自己上传的）',
        );
      }
    } on Object catch (e) {
      await widget.statusStore.setStatus('error:$e');
      if (!mounted) return;
      _snack(push ? '上传失败：$e' : '拉取失败：$e', ok: false);
    }
  }

  /// 后端选择器：三个后端一行 Chip（Wrap 防窄屏溢出），选中态明显。
  Widget _backendSelector() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.swap_horiz_outlined,
                color: theme.colorScheme.primary, size: 20),
            const SizedBox(width: 6),
            const Text(
              '同步后端',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final b in SyncBackend.values)
              ChoiceChip(
                label: Text(_chipLabel(b)),
                selected: b == _backend,
                onSelected: (_) => _selectBackend(b),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '当前：${_backend.label} · '
          '${_resolvedUrlText()}',
          style: TextStyle(color: theme.hintColor, fontSize: 11),
        ),
      ],
    );
  }

  /// Chip 文案；Vercel / EdgeOne 内置域名还没回填时加「（待配置）」提示，
  /// 回填后该提示自动消失（域名是编译期常量）。
  String _chipLabel(SyncBackend b) {
    final builtInEmpty = switch (b) {
      SyncBackend.vercel => SyncConfig.kSyncVercelDefaultBaseUrl.isEmpty,
      SyncBackend.edgeone => SyncConfig.kSyncEoDefaultBaseUrl.isEmpty,
      SyncBackend.netlify => SyncConfig.kSyncNetlifyDefaultBaseUrl.isEmpty,
      _ => false,
    };
    if (builtInEmpty) return '${b.label}（待配置）';
    return b.label;
  }

  String _resolvedUrlText() {
    final url = widget.config.urlOf(_backend).trim();
    return url.isEmpty ? '地址未配置' : url;
  }

  /// 「我的账号」卡片：顶部状态徽章（已登录/未登录）+ 账号信息 / 登录注册表单。
  ///
  /// 登录/注册成功后 `setState` 触发重建 → 徽章由灰「未登录」变绿「已登录」
  /// 并显示用户名，状态切换肉眼可辨；失败则该卡片保持「未登录」+ 红条提示。
  Widget _accountCard() {
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
              Text(
                '${_backend.label} 账号',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const Spacer(),
              _StatusChip(
                text: _loggedIn ? '已登录' : '未登录',
                ok: _loggedIn,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_loggedIn) ...[
            _ReadOnlyField(
              label: '已登录账号',
              value: widget.config.usernameOf(_backend) ?? '',
              note: '每用户令牌本机 SecretStore 保存（各后端账号互相独立）',
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _logout,
              child: const Text('退出登录'),
            ),
          ] else ...[
            TextField(
              controller: _user,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pass,
              enabled: !_busy,
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
                    onPressed: _busy ? null : () => _account(register: false),
                    child: const Text('登录'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _account(register: true),
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

  /// 上传 / 拉取按钮（对当前选中后端）。
  ///
  /// 后端没配地址时按钮禁用并给出明确原因——Vercel 域名待部署回填就是典型
  /// 场景，不能静默失败。
  Widget _syncButtons() {
    final theme = Theme.of(context);
    final urlReady = widget.config.urlOf(_backend).trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: urlReady ? () => _runSync(push: true) : null,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: Text('上传本地到 ${_backend.label}'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: urlReady ? () => _runSync(push: false) : null,
                icon: const Icon(Icons.cloud_download_outlined),
                label: Text('从 ${_backend.label} 拉取'),
              ),
            ),
          ],
        ),
        if (!urlReady)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${_backend.label} 尚未配置地址，暂不能同步'
              '（Vercel / EdgeOne 域名待部署完成后回填，其他后端可在下方自定义地址）。',
              style: TextStyle(color: theme.hintColor, fontSize: 11),
            ),
          ),
      ],
    );
  }

  /// 「服务器与网络」卡片：自定义同步地址 + 自定义 HTTP 代理。
  ///
  /// 存在的理由：实测有用户线路既被 DNS 投毒（返回黑洞 IP），又把 Cloudflare
  /// 的 IP 段整个封掉——连 DoH 拿到的真 IP 也 TCP 超时。这种环境里，换国内
  /// 中继（改地址）或走代理出国（填代理）是唯二出路，都应该**不用重新编译
  /// App** 就能配。地址编辑的是当前选中后端。
  Widget _serverNetworkCard() {
    final theme = Theme.of(context);
    final fallback = widget.config.urlOf(_backend).trim();
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
              labelText: '同步服务器地址（${_backend.label}）',
              helperText: fallback.isEmpty
                  ? '该后端暂无内置默认地址，请填写完整地址'
                  : '留空则使用内置默认：$fallback',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _proxy,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'HTTP 代理',
              helperText: '例如 127.0.0.1:7890，留空则直连/自动探测（全局生效）',
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
              // 顶部：后端选择器（三选一，记住上次选择）
              _backendSelector(),
              const SizedBox(height: 16),
              // 当前后端的账号卡片（自助注册 / 登录，各后端互相独立）
              _accountCard(),
              const SizedBox(height: 16),
              // 上传 / 拉取（对当前选中后端）
              _syncButtons(),
              const SizedBox(height: 16),
              // 「服务器与网络」卡片（自定义同步地址 / HTTP 代理）
              _serverNetworkCard(),
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

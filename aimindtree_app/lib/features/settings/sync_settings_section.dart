/// SettingsPage 中的「同步」分区。
///
/// 多后端 UI（Cloudflare / EdgeOne Pages / Netlify 三选一；原 llm_server
/// 目标已移除）：顶部后端选择器 → 当前后端的账号卡片（自助注册/登录）→
/// 上传/拉取按钮 → 「服务器与网络」卡片（自定义地址 + HTTP 代理 + 测试连接）。
///
/// 要点：
/// - 「数据版本」卡并列显示**本机 / 服务器**的记录数与最大版本号，让用户一眼
///   看出两端差多少（对比口径见 SyncOverview / SyncManifest 的文档注释）；
/// - 三个中继的 HTTP 契约逐字一致，App 侧只换地址；三个后端的账号体系
///   **互相独立**（同一用户在 CF 与 Netlify 上是不同账号），用户名/令牌
///   按后端隔离存储（见 [SyncConfig]）；
/// - Cloudflare 地址已内置，用户无需填写即可开箱即用；EdgeOne Pages 域名待部署
///   回填、Netlify 已部署，未回填的会明确提示「待配置」，不会静默失败；
/// - EdgeOne Pages 是国内永久免费链路，但请求体 1MB 硬限，推送预算收紧到
///   850KB，大图片附件（note_assets）会被本机切批逻辑标记失败，建议这类数据
///   走 CF / Netlify；
/// - Netlify 为海外/备份链路（函数跑美/欧单区，国内直连可达性差），非国内首选；
/// - 换中继 / 走代理都在「服务器与网络」卡里配，不必重新编译 App。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/logger.dart';
import '../../core/secret_store.dart';
import '../../data/sync/direct_connect.dart';
import '../../data/sync/http_proxy.dart';
import '../../data/sync/sync_api.dart';
import '../../data/sync/sync_account.dart';
import '../../data/sync/sync_config.dart';
import '../../data/sync/sync_engine.dart';
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
  static final AppLog _log = AppLog('sync_settings');

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

  /// 本机同步数据总览（16 张同步表的行数 / 最大版本）；null = 还没查过。
  SyncOverview? _localOverview;

  /// 服务器数据总览；null = 没取到（未登录 / 没地址 / 网络失败 / 旧中继）。
  SyncManifest? _serverManifest;

  /// 取不到服务器总览时的原因（人类可读，直接显示在本卡里）。
  String? _serverError;

  /// 正在查服务器总览（刷新按钮转圈 + 防重复点击）。
  bool _manifestLoading = false;

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
    // 进页面就查一次：本机走本地库（快），服务器走一次 manifest（可能慢，
    // 所以异步不阻塞首帧，失败也只是显示「—」）。
    _refreshVersions();
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

  /// 刷新「数据版本」卡：本机 + 服务器各查一次。
  ///
  /// 两侧互不影响：服务器查失败只清空服务器那一栏，本机数字照常显示。
  /// 同步（上传 / 拉取）完成后也会调它，让数字立刻跟上。
  Future<void> _refreshVersions() async {
    await Future.wait([_loadLocalOverview(), _loadServerManifest()]);
  }

  /// 本机总览：走 [SyncEngine.localOverview]（16 张同步表的聚合查询）。
  ///
  /// 本地库查询理论上不会失败，但仍兜底——设置页不能因为一次查询异常整页崩。
  Future<void> _loadLocalOverview() async {
    try {
      final overview = await widget.scheduler.engine.localOverview();
      if (!mounted) return;
      setState(() => _localOverview = overview);
    } on Object catch (e) {
      _log.w('本机数据总览查询失败：$e');
    }
  }

  /// 服务器总览：带令牌 GET `<base>/sync/manifest`。
  ///
  /// 三种「查不到」都只写 [_serverError] 并清空 [_serverManifest]，UI 显示
  /// 「—」+ 原因，**不弹 SnackBar**（进页面自动查一次，弹窗会打扰）：
  /// - 后端暂不可用 / 地址未配置；
  /// - 未登录（没有该后端的用户令牌）；
  /// - 网络失败或旧中继不认识该端点。
  Future<void> _loadServerManifest() async {
    final backend = _backend;
    final disabled = backend.disabledReason;
    if (disabled != null) {
      _setServerUnavailable('${backend.label}$disabled');
      return;
    }
    final url = widget.config.urlOf(backend).trim();
    if (url.isEmpty) {
      _setServerUnavailable('${backend.label} 地址未配置');
      return;
    }
    final token = await widget.config.resolveUserToken(backend);
    if (token == null || token.isEmpty) {
      _setServerUnavailable('未登录 ${backend.label} 账号');
      return;
    }

    if (mounted) setState(() => _manifestLoading = true);
    final api = HttpSyncApi(baseUrl: url, userToken: token, backend: backend);
    try {
      final result = await api.fetchManifest();
      if (!mounted) return;
      setState(() {
        _serverManifest = result.manifest;
        _serverError = result.error;
      });
    } finally {
      api.close();
      if (mounted) setState(() => _manifestLoading = false);
    }
  }

  void _setServerUnavailable(String reason) {
    if (!mounted) return;
    setState(() {
      _serverManifest = null;
      _serverError = reason;
    });
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
      // 账号体系互相独立 → 服务器那栏的旧数字不适用，立刻重查。
      _serverManifest = null;
      _serverError = null;
    });
    await _refreshLoginState();
    await _loadServerManifest();
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
      _snack('已保存，需重启应用后完全生效');
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
  /// 地址显示的 404 报成了「已连通」（这正是当初踩过的坑）。
  ///
  /// 客户端走 [createDirectHttpClient]（DoH / 代理 / 探测逻辑与真实同步链路
  /// 完全一致），测出来的结论才有意义；换一个普通 HttpClient 会得到不一样
  /// 的结果，用户据此判断会走偏。
  Future<void> _testEndpoint() async {
    final disabled = _backend.disabledReason;
    if (disabled != null) {
      _snack('${_backend.label}$disabled', ok: false);
      return;
    }
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
    // 暂不可用后端双保险：按钮虽已置灰，入口再拦一次（禁用的 chip 选不中，
    // 但历史选中态可能在禁用名单变更后残留）。
    final disabled = _backend.disabledReason;
    if (disabled != null) {
      _snack('${_backend.label}$disabled', ok: false);
      return;
    }
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
      // 拿到令牌了 → 服务器那栏可以从「未登录」变成真实数字。
      await _loadServerManifest();
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
    // 令牌已清 → 服务器那栏回落成「未登录」提示。
    await _loadServerManifest();
    _snack('已退出 ${_backend.label} 账号。');
  }

  /// 开发期手动同步：对当前选中后端触发上传 / 拉取。
  ///
  /// 复用 [widget.scheduler.engine] 的本地 outbox / deviceId，仅覆盖其 [api]
  /// 指向对应后端。拉取前强制游标归零（dev 期各后端共用游标，避免漏拉）。
  Future<void> _runSync({required bool push}) async {
    final backend = _backend;
    final disabled = backend.disabledReason;
    if (disabled != null) {
      _snack('${backend.label}$disabled', ok: false);
      return;
    }
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
        // skipped = 服务端「防陈旧覆盖」守卫跳过、未真正落库的条数。
        // 既不能算进成功数，也不能一律承诺「待重推」：pushAll 快照不经
        // outbox、没有重推路径，正确动作是执行「拉取」对齐云端。
        final skipped = inc.skipped + snap.skipped;
        await widget.statusStore.setLastPushAt(DateTime.now().toUtc());
        await widget.statusStore.setStatus('ok');
        if (!mounted) return;
        final failedNote = failed > 0 ? '，失败 $failed 条' : '';
        final skippedNote = skipped > 0
            ? '，跳过 $skipped 条（云端版本较新，未覆盖；请执行「拉取」对齐）'
            : '';
        _snack(
          '上传到 ${backend.label} 完成：增量 ${inc.pushed} 条 + 快照 ${snap.pushed} 条，'
          '共 $total 条$failedNote$skippedNote',
          ok: failed == 0 && skipped == 0,
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
          'LWW 保留 ${report.keptLocal} 条，'
          '跳过 ${report.skipped} 条（本机自己上传的）',
        );
      }
    } on Object catch (e) {
      await widget.statusStore.setStatus('error:$e');
      if (!mounted) return;
      _snack(push ? '上传失败：$e' : '拉取失败：$e', ok: false);
    } finally {
      // 同步完（成功或失败）都刷新「数据版本」卡：成功时数字跟上，失败时至少
      // 把上次同步时间刷新出来。失败也不影响上面的 SnackBar 提示。
      await _refreshVersions();
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
              Tooltip(
                // 禁用后端置灰不可点，原因经 Tooltip 可见（见
                // [SyncBackend.disabledReason]，当前三个后端均可用）。
                message: b.disabledReason ?? b.label,
                child: ChoiceChip(
                  label: Text(_chipLabel(b)),
                  selected: b == _backend,
                  onSelected: b.disabledReason != null
                      ? null
                      : (_) => _selectBackend(b),
                ),
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

  /// Chip 文案；EdgeOne 内置域名还没回填时加「（待配置）」提示，回填后该提示
  /// 自动消失（域名是编译期常量）；暂不可用的后端加「（暂不可用）」。
  String _chipLabel(SyncBackend b) {
    if (b.disabledReason != null) return '${b.label}（暂不可用）';
    final builtInEmpty = switch (b) {
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
    final disabledReason = _backend.disabledReason;
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
          // 暂不可用后端：红条说明原因 + 引导切换（用户 2026-10-24 拍板置灰）。
          if (disabledReason case final reason?) ...[
            Container(
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(Icons.block_outlined,
                      size: 16, color: theme.colorScheme.onErrorContainer),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${_backend.label}$reason，请切换到其他后端',
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
                    onPressed: _busy || disabledReason != null
                        ? null
                        : () => _account(register: false),
                    child: const Text('登录'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy || disabledReason != null
                        ? null
                        : () => _account(register: true),
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
  /// 后端没配地址时按钮禁用并给出明确原因——EdgeOne Pages 域名待部署回填就是
  /// 典型场景，不能静默失败。
  Widget _syncButtons() {
    final theme = Theme.of(context);
    final disabledReason = _backend.disabledReason;
    final urlReady = widget.config.urlOf(_backend).trim().isNotEmpty;
    final ready = urlReady && disabledReason == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: ready ? () => _runSync(push: true) : null,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: Text('上传本地到 ${_backend.label}'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: ready ? () => _runSync(push: false) : null,
                icon: const Icon(Icons.cloud_download_outlined),
                label: Text('从 ${_backend.label} 拉取'),
              ),
            ),
          ],
        ),
        if (disabledReason case final reason?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${_backend.label}$reason，请切换到其他后端',
              style: TextStyle(color: theme.colorScheme.error, fontSize: 11),
            ),
          )
        else if (!urlReady)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${_backend.label} 尚未配置地址，暂不能同步'
              '（EdgeOne Pages 域名待部署完成后回填，其他后端可在下方自定义地址）。',
              style: TextStyle(color: theme.hintColor, fontSize: 11),
            ),
          ),
      ],
    );
  }

  /// 「数据版本」卡片：本机 / 服务器各自的**记录数 + 最大版本**。
  ///
  /// 存在的理由：用户看不到本地和云端差多少，只能靠「上传/拉取完成 N 条」的
  /// 提示猜。这里把两侧的总览并排列出来，一眼能看出「本机比服务器多/少多少」。
  ///
  /// 降级策略（所有失败路径都只显示「—」+ 一行原因，**不弹窗、不卡 UI**）：
  /// - 未登录 / 地址未配置 / 后端暂不可用 → 服务器那栏「—」+ 原因；
  /// - 网络失败或旧中继不返回 `max_version` → 同上（后者靠
  ///   [HttpSyncApi.parseManifest] 的缺字段容错回落 0）。
  Widget _dataVersionCard() {
    final theme = Theme.of(context);
    final local = _localOverview;
    final server = _serverManifest;
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
              Icon(Icons.numbers_outlined,
                  color: theme.colorScheme.primary, size: 22),
              const SizedBox(width: 6),
              const Text(
                '数据版本',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const Spacer(),
              // 刷新只重查两侧；加载中把按钮换成小转圈，防重复点击。
              _manifestLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : OutlinedButton.icon(
                      onPressed: _refreshVersions,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('刷新'),
                    ),
            ],
          ),
          const SizedBox(height: 10),
          // 表头 + 两行数据：列宽用 Expanded 平分，窄屏也不会溢出。
          Row(
            children: [
              const SizedBox(width: 72),
              Expanded(
                child: Text(
                  '记录数',
                  textAlign: TextAlign.end,
                  style: TextStyle(color: theme.hintColor, fontSize: 12),
                ),
              ),
              Expanded(
                child: Text(
                  '最大版本',
                  textAlign: TextAlign.end,
                  style: TextStyle(color: theme.hintColor, fontSize: 12),
                ),
              ),
            ],
          ),
          const Divider(height: 12),
          _versionRow(
            label: '本机',
            count: local?.count,
            maxVersion: local?.maxVersion,
            fallback: '统计中…',
          ),
          const SizedBox(height: 6),
          _versionRow(
            label: '服务器',
            count: server?.count,
            maxVersion: server?.maxVersion,
            fallback: '—',
          ),
          if (_serverError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _serverError!,
                style: TextStyle(color: theme.hintColor, fontSize: 11),
              ),
            ),
          const Divider(height: 16),
          // 上次同步时间：SyncStatusStore 里一直有值，但此前界面上看不到。
          _lastSyncLine('上次上传', widget.statusStore.lastPushAt),
          const SizedBox(height: 2),
          _lastSyncLine('上次拉取', widget.statusStore.lastPulledAt),
          const SizedBox(height: 8),
          Text(
            '记录数含软删墓碑；版本是逐实体修订号（不是全局版本号），'
            '每次上传都会让服务端版本递增，故两边数字不必然相等。',
            style: TextStyle(color: theme.hintColor, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// 总览表里的一行：标签 + 记录数 + 最大版本；查不到时整行显示 [fallback]。
  Widget _versionRow({
    required String label,
    required int? count,
    required int? maxVersion,
    required String fallback,
  }) {
    final theme = Theme.of(context);
    final known = count != null && maxVersion != null;
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        if (!known)
          Expanded(
            child: Text(
              fallback,
              style: TextStyle(color: theme.hintColor, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          )
        else ...[
          Expanded(
            child: Text(
              '$count',
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              '$maxVersion',
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ],
    );
  }

  /// 「上次上传 / 上次拉取」一行；没记录时显示「从未」。
  Widget _lastSyncLine(String label, DateTime? time) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).hintColor,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Text(
            time == null ? '从未' : _formatTime(time),
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// 本地时区 `YYYY-MM-DD HH:mm`（服务器时间存的是 UTC，转成本地更好读）。
  String _formatTime(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
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
              // 「数据版本」卡片（本机 / 服务器 记录数 + 最大版本）
              _dataVersionCard(),
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

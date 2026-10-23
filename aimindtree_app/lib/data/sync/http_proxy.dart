/// 系统代理自动识别。
///
/// Dart 的 `HttpClient` **不读**操作系统的「系统代理」设置（Windows WinINET /
/// 注册表），也不读 Android/iOS 的 WiFi 代理，而是直连——所以浏览器能打开的
/// 站点，App 里可能因 DNS 污染/被墙而连不上。
///
/// 这里在启动时探测一次代理并缓存，供 `HttpClient.findProxy` 同步读取：
/// 1. 环境变量 `HTTPS_PROXY / HTTP_PROXY / ALL_PROXY`（桌面 shell 启动时常见）；
/// 2. Windows 系统代理注册表 `Internet Settings\ProxyServer`；
/// 3. 常见本地代理端口探测（Clash 7897/7890、v2rayN 10809/10808、8080、8889）。
///
/// 此外用户可在设置里手动指定代理（[setUserProxy]），其优先级高于上述全部
/// 自动探测结果——见 [syncFindProxy]。
///
/// 手机端（Android/iOS）通常用 VPN 的 TUN/全局模式在系统层接管，无需本逻辑；
/// 若未探测到，返回 DIRECT（与改前一致）。
library;

import 'dart:async';
import 'dart:io';

String? _detectedProxy;

/// 当前探测到的代理（`host:port`），null 表示不走代理（供调试/展示用）。
String? get detectedSystemProxy => _detectedProxy;

/// 用户在设置里手动指定的代理（`host:port`），null 表示未指定。
///
/// 优先级高于自动探测结果——自动探测可能误判（本地 7890 端口在听但实际
/// 并不通），用户手动填的才是准的。
String? _userProxy;

/// 用户手动代理（已归一化为 `host:port`），null 表示未设置（供界面回显）。
String? get userProxyOverride => _userProxy;

/// 设置/清空用户手动代理：`http://127.0.0.1:7890` 之类的写法会被归一化成
/// `127.0.0.1:7890`；null 或空白表示清空（回落自动探测 / 直连）。
void setUserProxy(String? hostPort) {
  final s = hostPort == null ? null : _stripScheme(hostPort);
  final trimmed = s?.trim() ?? '';
  _userProxy = trimmed.isEmpty ? null : trimmed;
}

/// 启动时调用一次：确定代理并缓存。幂等、绝不抛异常。
Future<void> initSystemProxy() async {
  if (_detectedProxy != null) return;
  // 环境变量声明的代理先验证端口可连（防止残留的死代理把请求带崩）。
  _detectedProxy = await _validated(_proxyFromEnvVars());
  if (_detectedProxy != null) return;
  // 再探测常见本地端口（无子进程、最快；Clash 默认就监听这些端口）。
  _detectedProxy = await _probeCommonLocalProxyPorts();
  if (_detectedProxy != null) return;
  // 最后读 Windows 系统代理注册表兜底。
  if (Platform.isWindows) {
    _detectedProxy = await _validated(await _proxyFromWindowsRegistry());
  }
}

/// 验证 `host:port` 可连接；不可连返回 null。
Future<String?> _validated(String? hostPort) async {
  if (hostPort == null || hostPort.isEmpty) return null;
  final idx = hostPort.lastIndexOf(':');
  if (idx <= 0) return null;
  final host = hostPort.substring(0, idx);
  final port = int.tryParse(hostPort.substring(idx + 1));
  if (port == null) return null;
  try {
    final s = await Socket.connect(
      host,
      port,
      timeout: const Duration(milliseconds: 200),
    );
    s.destroy();
    return hostPort;
  } on Object {
    return null;
  }
}

/// 供 `HttpClient.findProxy` 用的同步回调。
///
/// 优先级（从高到低）：
/// 1. 回环地址（localhost / 127.0.0.1 / ::1）→ 恒 `DIRECT`：本机服务必须
///    直连，否则 llm_server 也会去挤代理；
/// 2. 用户手动代理（[setUserProxy] / [userProxyOverride]）→ `PROXY host:port`；
/// 3. 自动探测代理（[initSystemProxy] 的结果）→ `PROXY host:port`；
/// 4. 都没有 → `DIRECT`（与「不识别代理」时的现状一致）。
String syncFindProxy(Uri uri) {
  final host = uri.host;
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
    return 'DIRECT';
  }
  final user = _userProxy;
  if (user != null && user.isNotEmpty) return 'PROXY $user';
  final p = _detectedProxy;
  if (p == null || p.isEmpty) return 'DIRECT';
  return 'PROXY $p';
}

String? _proxyFromEnvVars() {
  final env = Platform.environment;
  final raw = env['HTTPS_PROXY'] ??
      env['https_proxy'] ??
      env['HTTP_PROXY'] ??
      env['http_proxy'] ??
      env['ALL_PROXY'] ??
      env['all_proxy'];
  if (raw == null || raw.trim().isEmpty) return null;
  return _stripScheme(raw);
}

/// 去掉 `http://` / `socks5://` 等 scheme，只留 `host:port`。
String? _stripScheme(String raw) {
  final s = raw.trim().replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
  return s.isEmpty ? null : s;
}

/// 读 Windows 系统代理（`HKCU\...\Internet Settings\ProxyServer`）。
/// 值可能形如 `127.0.0.1:7897` 或 `http=...;https=...`。
Future<String?> _proxyFromWindowsRegistry() async {
  try {
    final r = await Process.run(
      'reg',
      <String>[
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        '/v',
        'ProxyServer',
      ],
      runInShell: false,
    );
    if (r.exitCode != 0) return null;
    final out = (r.stdout as String);
    final m = RegExp(r'REG_SZ\s+(\S+)').firstMatch(out);
    if (m == null) return null;
    final raw = m.group(1)!.trim();
    if (raw.isEmpty) return null;
    if (raw.contains('=')) {
      // http=host:port;https=host:port → 优先 https，其次 http
      String? http;
      for (final seg in raw.split(';')) {
        final kv = seg.split('=');
        if (kv.length != 2) continue;
        final scheme = kv[0].trim().toLowerCase();
        final hp = kv[1].trim();
        if (hp.isEmpty) continue;
        if (scheme == 'https') return hp;
        if (scheme == 'http') http ??= hp;
      }
      return http;
    }
    return _stripScheme(raw);
  } on Object {
    return null;
  }
}

/// 探测常见本地代理端口：能连上就认为是 Clash/v2ray 等代理的混合端口。
Future<String?> _probeCommonLocalProxyPorts() async {
  const ports = <int>[7897, 7890, 10809, 10808, 1080, 8889];
  for (final port in ports) {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 120),
      );
      socket.destroy();
      return '127.0.0.1:$port';
    } on Object {
      // 未监听，试下一个
    }
  }
  return null;
}

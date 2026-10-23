/// 直连 HttpClient：**先探测**本机能否直连 `*.workers.dev:443`，能连就完全
/// 不改道（行为 100% 等于改造前）；连不上才用 DoH 拿真实 IP，再以原域名为
/// SNI 建 TLS 连接，绕开国内 DNS 投毒；任何失败都安静回退普通 HttpClient。
///
/// 为什么是「探测式」而不是「无条件改道」：上一版对 `*.workers.dev` 无条件
/// 启用 DoH 直连，把本来完全正常的 PC 端（系统 DNS/TCP 无碍）也强制改道，
/// 一旦 DoH 拿到假 IP 或某个 CF IP 不可达，每条新连接都要先耗尽
/// [kDirectTotalBudget]（12s）才回退，同步表现为超时/失败。探测（3s 内
/// TCP 建连 + TLS 握手 + 证书校验）把「能不能直连」变成显式判据：能连 →
/// 走默认通路，零副作用。
///
/// 实现说明（与 Dart 3.13 dart:io API 对齐）：
/// - `SecureSocket.connect(ip, 443, host: 域名)` 的 `host` 命名参数在当前
///   SDK 已不存在，取而代之的是两步：`Socket.connect(ip, port)` 建 TCP，
///   再 `SecureSocket.secure(socket, host: 域名)`——`host` 同时用于 SNI 与
///   证书校验，语义与需求一致；
/// - socket 注入连接池不用（已不存在的）`pullSocketToHttpClient`，改用
///   `HttpClient.connectionFactory`：每条新连接经工厂创建，天然并入
///   HttpClient 连接池（按 host/port 复用），且失败时可在工厂内直接回退
///   到默认连接逻辑。
///
/// 核心约束：任何失败路径都必须退化成现状行为——探测失败/抛异常（保守按
/// 「不能直连」处理，因为无法证明能直连）、DoH 失败/超时/返回空、全部 IP
/// 建连失败，全部安静回退普通 client，绝不抛异常；能直连的 PC 端（本机
/// DNS 正常）根本不安装 `connectionFactory`，行为完全不变。
library;

import 'dart:async';
import 'dart:io';

import 'doh_resolver.dart';
import 'http_proxy.dart';

/// 走 DoH 直连的域名后缀（Cloudflare Workers 默认域名）。
const String kWorkersDevSuffix = '.workers.dev';

/// 单个 IP 的 TCP 连接 / TLS 握手超时。
const Duration kDirectSocketTimeout = Duration(seconds: 3);

/// 「DoH + 建连」整个尝试的总预算：超时即回退默认通路，把剩余时间留给
/// 回退路径（调用方 connectionTimeout 默认 20s）。
const Duration kDirectTotalBudget = Duration(seconds: 12);

/// 直连可达性探测的预算：一次 **TCP 建连 + TLS 握手（SNI + 证书校验）**，
/// 每个阶段各自最多 3s（共用这个常量），任一阶段超时就认为「不能直连」，
/// 从而启用 DoH。
///
/// 为什么不再只看 TCP：DNS 投毒常返回一个**真实存在的外网 IP**（实测
/// 31.13.67.41 就是 Facebook 的地址，443 端口照常接受 TCP），TCP-only 探测
/// 会误判成「能直连」，于是跳过 DoH 改道、同步照旧失败。要求握手成功且
/// 证书能验到目标域名，sinkhole / 假 IP 必然失败，判据才成立。
///
/// 计时细节：建连与握手各自 `.timeout(timeout)`，即「每一阶段最多 3s」，
/// 最坏情况下总耗时约 2×timeout（6s），仍远小于 [kDirectTotalBudget]，且
/// 只在进程内首次探测该 host 时发生一次。
///
/// 取值权衡：太短会在弱网下误判（把能直连的 PC 端错误改道到 DoH），
/// 太长会拖慢首连。
const Duration kReachabilityProbeTimeout = Duration(seconds: 3);

/// IP 解析器契约（测试可注入假实现）。
typedef IpResolver = Future<List<String>> Function(String host);

/// 直连可达性探测契约（测试可注入假实现）。
///
/// 返回 true 表示本机可直连 `host:port`（默认实现要求 TCP + TLS 握手 +
/// 证书校验全部通过）；任何异常/超时都应视为 false。
typedef ReachabilityProbe = Future<bool> Function(
  String host,
  int port,
  Duration timeout,
);

/// 探测本机能否直连 `host:port`——**必须**完成 TLS 握手且证书校验通过。
///
/// 判据：TCP 建连 → `SecureSocket.secure(raw, host: host)`（`host` 同时用于
/// SNI 与证书校验）握手成功 → 销毁 socket 并返回 true；任何一步失败 / 超时
/// （含 DNS 失败、对端只接受 TCP 却不做 TLS、证书链或域名不匹配）→ 返回
/// false（不抛）。
///
/// 为什么不能只看 TCP：见 [kReachabilityProbeTimeout] 的注释。
///
/// [onBadCertificate] 仅供测试注入（让用例能把探测指向本地自签 TLS 服务），
/// 生产调用点一律不传 —— 不传即走平台真实证书校验。
Future<bool> canReachDirect(
  String host,
  int port,
  Duration timeout, {
  bool Function(X509Certificate certificate)? onBadCertificate,
}) async {
  Socket? raw;
  Socket? secure;
  try {
    raw = await Socket.connect(host, port, timeout: timeout);
    // 复用 DoH 直连路径的握手实现：超时后握手若仍在后台完成，由它负责销毁。
    secure = await _secureHandshake(
      raw,
      host: host,
      onBadCertificate: onBadCertificate,
      timeout: timeout,
    );
    raw = null; // 所有权已移交 secure
    return true;
  } on Object {
    return false;
  } finally {
    _destroyQuietly(secure);
    _destroyQuietly(raw);
  }
}

/// host → 是否可直连的进程内缓存。
///
/// 为什么缓存：同一 host 在一次进程生命周期内只探测一次——探测本身要花
/// 最多 [kReachabilityProbeTimeout]，而 DNS 投毒是**网络级**状态（运营商/
/// 代理链路决定），短期内不会来回切换；进程重启后重新探测即可。
/// 缓存方向是安全的：误判成 true 时行为等于改造前（默认通路，本来就能用），
/// 误判成 false 时最多多用一条 DoH 快路径且仍有安静回退。
final Map<String, bool> _reachabilityCache = <String, bool>{};

/// host 是否为回环/私网/保留地址——此类地址绝不走 DoH、也绝不外网直连。
///
/// 覆盖：`localhost`、`::1`、`127.0.0.0/8`、`10.0.0.0/8`、`172.16.0.0/12`、
/// `192.168.0.0/16`、`169.254.0.0/16`（link-local）、`100.64.0.0/10`
/// （CGNAT）、`0.0.0.0/8`、`224.0.0.0` 及以上（组播/保留）。
bool isPrivateOrLoopbackHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return true;
  if (h == 'localhost' || h == 'localhost.') return true;
  if (h == '::1' || h == '[::1]' || h == '0:0:0:0:0:0:0:1') return true;
  final m = _ipv4Re.firstMatch(h);
  if (m == null) return false;
  final a = int.parse(m.group(1)!);
  final b = int.parse(m.group(2)!);
  if (a == 0) return true; // 0.0.0.0/8
  if (a == 10) return true; // 10.0.0.0/8
  if (a == 127) return true; // 127.0.0.0/8 回环
  if (a == 169 && b == 254) return true; // 169.254.0.0/16
  if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
  if (a == 192 && b == 168) return true; // 192.168.0.0/16
  if (a == 100 && b >= 64 && b <= 127) return true; // 100.64.0.0/10
  if (a >= 224) return true; // 组播 / 保留 / 广播
  return false;
}

final RegExp _ipv4Re = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

/// host 是否需要走 DoH 直连：`*.workers.dev` 且非回环/私网。
bool _needsDoHDirect(String host) =>
    host.toLowerCase().endsWith(kWorkersDevSuffix) &&
    !isPrivateOrLoopbackHost(host);

/// 创建 HttpClient；`*.workers.dev` 域名在**探测确认不可直连**时启用
/// 「DoH 真实 IP + 原域名 SNI」直连。
///
/// 行为矩阵：
/// - baseUrl 畸形 / host 为空 → 普通 client；
/// - host 非 `.workers.dev` 结尾，或是回环/私网地址 → 普通 client（不走 DoH）；
/// - host 命中 `.workers.dev`：**先探测**本机能否直连该 `host:端口`
///   （[kReachabilityProbeTimeout] 预算；TCP + TLS 握手 + 证书校验全过才算
///   可直连）：
///   - 能直连（true）→ 直接返回普通 client，**不安装** `connectionFactory`，
///     行为 100% 等于改造前（PC 端正常场景就走这条，零改道、零延迟）；
///   - 不能直连（false，含探测抛异常）→ 先经 DoH 预解析一次（失败/超时/
///     返回空 → 普通 client，安静回退）；成功则给 client 安装
///     `connectionFactory`：之后每条新连接都经 DoH 拿 IP 列表（缓存命中不
///     重复发请求），逐个 `Socket.connect(ip, port)` +
///     `SecureSocket.secure(socket, host: 原域名)` 建连（host 同时用于 SNI
///     与证书校验），全部失败回退默认连接逻辑（= 现状：本机 DNS 解析 +
///     普通 TLS）。
///
/// [probe] 默认 [canReachDirect]；探测结果按 host 进程内缓存，同一 host
/// 只探测一次（见 `_reachabilityCache`）。
///
/// [onBadCertificate] 仅供测试 / 自建 CA 场景注入；生产代码切勿传——
/// 不传即保持与现状一致的严格证书校验。
Future<HttpClient> createDirectHttpClient(
  String baseUrl, {
  Duration connectionTimeout = const Duration(seconds: 20),
  IpResolver? ipResolver,
  ReachabilityProbe? probe,
  Duration socketTimeout = kDirectSocketTimeout,
  bool Function(X509Certificate certificate)? onBadCertificate,
}) async {
  final client = HttpClient()
    ..connectionTimeout = connectionTimeout
    ..findProxy = syncFindProxy;

  final uri = Uri.tryParse(baseUrl);
  if (uri == null) return client;
  final host = uri.host.toLowerCase();
  if (host.isEmpty || !_needsDoHDirect(host)) return client;

  // 探测式启用：先问本机「能直连吗」。生产 baseUrl 是 https，端口恒为 443；
  // 这里取 uri 的实际端口，兼容显式端口的用法（如测试里的本地 TLS 端口）。
  final port = uri.hasPort ? uri.port : 443;
  if (await _isDirectReachable(host: host, port: port, probe: probe)) {
    // 能直连 → 完全不改道：不装 connectionFactory，等价于改造前行为。
    return client;
  }

  final resolve = ipResolver ?? sharedDoHResolver.resolveViaDoH;
  // 预解析：DoH 失败 / 超时 / 返回空 → 安静回退普通 client（现状行为）。
  List<String> ips;
  try {
    ips = await resolve(host);
  } on Object {
    return client;
  }
  if (ips.isEmpty) return client;

  client.connectionFactory =
      (Uri requestUri, String? proxyHost, int? proxyPort) async {
    // 走代理时与默认行为一致：连到代理的明文 socket（CONNECT 隧道由
    // HttpClient 自建），不做 DoH——代理侧解析不受本地 DNS 投毒影响。
    if (proxyHost != null) {
      return Socket.startConnect(proxyHost, proxyPort!);
    }
    // 非本 baseUrl 的 https 请求（其他 host/port/scheme）：默认通路。
    if (requestUri.scheme != 'https' ||
        requestUri.host.toLowerCase() != host ||
        requestUri.port != port) {
      return _defaultDirectConnection(requestUri);
    }
    // DoH 直连；总预算内任何失败都回退默认通路（现状行为）。
    try {
      return await _directConnectionTask(
        resolve: resolve,
        host: host,
        port: requestUri.port,
        socketTimeout: socketTimeout,
        onBadCertificate: onBadCertificate,
      ).timeout(kDirectTotalBudget);
    } on Object {
      return _defaultDirectConnection(requestUri);
    }
  };
  return client;
}

/// 判断 `host:port` 是否可直连；结果按 host 进程内缓存。
///
/// 说明：探测抛异常时**保守按 false 处理**（即启用 DoH 快路径），因为异常
/// 只说明「无法证明能直连」，并不等于「能直连」；按 false 处理仍保有
/// 「DoH 失败 → 安静回退默认通路」的兜底，不会比改造前更差。
Future<bool> _isDirectReachable({
  required String host,
  required int port,
  required ReachabilityProbe? probe,
}) async {
  final cached = _reachabilityCache[host];
  if (cached != null) return cached;
  bool reachable;
  try {
    reachable =
        await (probe ?? canReachDirect)(host, port, kReachabilityProbeTimeout);
  } on Object {
    reachable = false;
  }
  _reachabilityCache[host] = reachable;
  return reachable;
}

/// 复刻 dart:io HttpClient 的默认连接逻辑（回退路径用）。
Future<ConnectionTask<Socket>> _defaultDirectConnection(Uri uri) {
  if (uri.scheme == 'https') {
    return SecureSocket.startConnect(uri.host, uri.port);
  }
  return Socket.startConnect(uri.host, uri.port);
}

/// DoH 解析 + 逐个 IP 建 TLS 连，返回可并入 HttpClient 连接池的
/// [ConnectionTask]；全部 IP 失败抛异常（由调用方回退默认通路）。
Future<ConnectionTask<Socket>> _directConnectionTask({
  required IpResolver resolve,
  required String host,
  required int port,
  required Duration socketTimeout,
  required bool Function(X509Certificate certificate)? onBadCertificate,
}) async {
  final ips = await resolve(host);
  for (final ip in ips) {
    try {
      final raw = await Socket.connect(ip, port, timeout: socketTimeout);
      final secure = await _secureHandshake(
        raw,
        host: host,
        onBadCertificate: onBadCertificate,
        timeout: socketTimeout,
      );
      return ConnectionTask.fromSocket<SecureSocket>(
        Future.value(secure),
        () => _destroyQuietly(secure),
      );
    } on Object {
      // 该 IP 不可用（拒绝 / 超时 / 证书错）：换下一个。
    }
  }
  throw SocketException('all DoH-resolved IPs failed for $host:$port');
}

/// TLS 握手（带超时）；超时后若握手在后台完成，负责销毁，避免孤儿 socket。
Future<SecureSocket> _secureHandshake(
  Socket raw, {
  required String host,
  required bool Function(X509Certificate certificate)? onBadCertificate,
  required Duration timeout,
}) async {
  final pending =
      SecureSocket.secure(raw, host: host, onBadCertificate: onBadCertificate);
  try {
    return await pending.timeout(timeout);
  } on Object {
    // 超时/失败：握手可能仍在后台继续，稍后完成时销毁，避免泄漏。
    pending.then(
      (s) => _destroyQuietly(s),
      onError: (Object _) {},
    );
    rethrow;
  }
}

/// 销毁 socket；已关闭 / 已 detach 时静默忽略。
void _destroyQuietly(Socket? socket) {
  if (socket == null) return;
  try {
    socket.destroy();
  } on Object {
    // 已关闭：忽略。
  }
}

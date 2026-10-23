/// 直连 HttpClient：`*.workers.dev` 域名先经 DoH 拿真实 IP，再以原域名为
/// SNI 建 TLS 连接，绕开国内 DNS 投毒；任何失败都安静回退普通 HttpClient。
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
/// 核心约束：任何失败路径都必须退化成现状行为——DoH 失败/超时/返回空、
/// 全部 IP 建连失败，全部安静回退普通 client，绝不抛异常；不依赖 DoH 的
/// PC 端（本机 DNS 正常）行为完全不变。
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

/// IP 解析器契约（测试可注入假实现）。
typedef IpResolver = Future<List<String>> Function(String host);

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

/// 创建 HttpClient；对 `*.workers.dev` 域名启用「DoH 真实 IP + 原域名 SNI」直连。
///
/// 行为矩阵：
/// - baseUrl 畸形 / host 为空 → 普通 client；
/// - host 非 `.workers.dev` 结尾，或是回环/私网地址 → 普通 client（不走 DoH）；
/// - host 命中 `.workers.dev`：先经 DoH 预解析一次（失败/超时/返回空 →
///   普通 client，安静回退）；成功则给 client 安装 `connectionFactory`：
///   之后每条新连接都经 DoH 拿 IP 列表（缓存命中不重复发请求），逐个
///   `Socket.connect(ip, port)` + `SecureSocket.secure(socket, host: 原域名)`
///   建连（host 同时用于 SNI 与证书校验），全部失败回退默认连接逻辑
///   （= 现状：本机 DNS 解析 + 普通 TLS）。
///
/// [onBadCertificate] 仅供测试 / 自建 CA 场景注入；生产代码切勿传——
/// 不传即保持与现状一致的严格证书校验。
Future<HttpClient> createDirectHttpClient(
  String baseUrl, {
  Duration connectionTimeout = const Duration(seconds: 20),
  IpResolver? ipResolver,
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

  final resolve = ipResolver ?? sharedDoHResolver.resolveViaDoH;
  // 预解析：DoH 失败 / 超时 / 返回空 → 安静回退普通 client（现状行为）。
  List<String> ips;
  try {
    ips = await resolve(host);
  } on Object {
    return client;
  }
  if (ips.isEmpty) return client;

  final port = uri.hasPort ? uri.port : 443;
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

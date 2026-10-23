/// DoH（DNS over HTTPS）解析：绕开国内 DNS 投毒，拿 `*.workers.dev` 的真实 IP。
///
/// 背景：`aimindtree-sync-relay.tuanx.workers.dev` 等 Cloudflare Workers 域名
/// 在国内被 DNS 投毒——本机 DNS 返回假 IP（非 Cloudflare 段），TCP 连不通、
/// TLS 更无从谈起；而真实 IP（CF 官方段 104.21.x / 172.67.x）经 DoH 查询可以
/// 拿到，TCP 层可达。拿到真 IP 后由 `direct_connect.dart` 以原域名为 SNI
/// 建 TLS 连接。
///
/// 本文件只负责「域名 → IPv4 列表」：
/// - [parseDoHJson]：DoH JSON 解析纯函数（不依赖网络，可单测）；
/// - [DoHResolver.resolveViaDoH]：带内存缓存的解析入口，按端点顺序尝试；
/// - [sharedDoHResolver]：进程内共享实例（缓存跨 HttpClient 复用）。
///
/// 注意：DoH 请求**强制直连**（见 [dohDirectProxy]），绝不走系统代理——
/// 经代理转发反而会被污染/拖慢，实测会返回假 IP。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 单个 DoH 端点的请求超时（含建连与响应体读取）。
///
/// 预算说明：默认 2 个端点 → 最坏 8s；加上直连的 TCP/握手各 3s 与
/// `direct_connect.dart` 的 12s 总预算，保证在调用方
/// `connectionTimeout`（默认 20s）之前完成或回退。
const Duration kDoHRequestTimeout = Duration(seconds: 4);

/// 缓存 TTL 夹取下界：DNS TTL 可能为 0/1，夹到 60s 防止打爆 DoH 端点。
const Duration kDoHCacheTtlMin = Duration(seconds: 60);

/// 缓存 TTL 夹取上界：DNS TTL 可能极大（3600+），夹到 10min 保证及时刷新。
const Duration kDoHCacheTtlMax = Duration(minutes: 10);

/// 响应缺 TTL 字段时的默认缓存时长。
const Duration kDoHCacheTtlDefault = Duration(minutes: 5);

/// DoH 解析失败（网络错误 / Status 非 0 / 畸形响应 / 全部端点失败）。
class DoHResolveException implements Exception {
  const DoHResolveException(this.message);
  final String message;

  @override
  String toString() => 'DoHResolveException: $message';
}

/// [parseDoHJson] 的解析结果。
class DoHAnswer {
  const DoHAnswer({required this.ips, this.ttlSeconds});

  /// A 记录（`type == 1`）的 `data` 字段，保序去重；可能为空
  /// （NOERROR 但无记录 / 仅 AAAA 等）。
  final List<String> ips;

  /// 首个 A 记录的 `TTL`（秒）；缺失/非法为 null（调用方取默认值）。
  final int? ttlSeconds;
}

/// 解析 DoH JSON（`Accept: application/dns-json`）响应体——纯函数，可单测。
///
/// 契约：
/// - `Status == 0`：返回 `Answer[]` 中 `type == 1`（A 记录）的 `data` 列表
///   （保序去重）；`Answer` 缺失或为空数组 → 空列表（不抛）；
/// - `Status != 0`（NXDOMAIN / SERVFAIL…）→ 抛 [DoHResolveException]；
/// - JSON 畸形 / 根非对象 / `Answer` 非数组 → 抛 [DoHResolveException]；
/// - 仅 AAAA（`type == 28`）等非 A 记录 → 空列表（不抛）。
DoHAnswer parseDoHJson(String body) {
  final Object? root;
  try {
    root = jsonDecode(body);
  } on Object catch (e) {
    throw DoHResolveException('DoH response is not valid JSON: $e');
  }
  if (root is! Map<String, dynamic>) {
    throw DoHResolveException('DoH response root is not a JSON object');
  }
  final status = root['Status'];
  if (status is! num || status.toInt() != 0) {
    throw DoHResolveException('DoH Status=$status (expected 0)');
  }
  final answers = root['Answer'];
  if (answers == null) {
    return const DoHAnswer(ips: <String>[]);
  }
  if (answers is! List<dynamic>) {
    throw DoHResolveException('DoH "Answer" is not a list');
  }
  final ips = <String>[];
  int? ttl;
  for (final entry in answers) {
    if (entry is! Map) continue;
    final type = entry['type'];
    if (type is! num || type.toInt() != 1) continue; // 只要 A 记录
    final data = entry['data'];
    if (data is! String || data.isEmpty) continue;
    if (!ips.contains(data)) ips.add(data);
    final t = entry['TTL'];
    if (ttl == null && t is num && t.isFinite) ttl = t.toInt();
  }
  return DoHAnswer(ips: ips, ttlSeconds: ttl);
}

/// DoH 请求专用的 `HttpClient.findProxy`：**恒定 DIRECT**，永不走系统代理。
///
/// 为什么不用 `syncFindProxy`（见 `http_proxy.dart`）：
/// DoH 端点 `doh.pub` / `dns.alidns.com` 本身国内直达，无需代理；而经代理
/// 转发时，代理会把这个「明文 HTTP 语义」的 DoH 流量一并按它自己的解析结果
/// 处理，实测会拿到 Facebook 段假 IP（31.13.67.41），与系统 DNS 被投毒的
/// 结果同源——DoH 因此完全失去意义，还会被代理链路额外拖慢。
///
/// 副作用面：只影响本模块自建的 client，且仅用于访问 DoH 端点；
/// 业务请求的 client（`direct_connect.dart`）仍用 `syncFindProxy`，
/// 代理设置行为不变。
String dohDirectProxy(Uri uri) => 'DIRECT';

/// 带内存缓存的 DoH 解析器。
///
/// - 端点按 [kDefaultDoHEndpoints] 顺序尝试（当前仅 doh.pub，取舍依据见
///   该常量的实测注释）；
/// - 命中缓存（host → (ips, expiresAt)）直接返回，不发请求；
/// - TTL 取 DNS 返回的 TTL，夹在 [kDoHCacheTtlMin] ~ [kDoHCacheTtlMax]；
/// - 失败（网络 / 超时 / Status 非 0 / 空 Answer）不写缓存；全部端点失败
///   抛 [DoHResolveException]。
///
/// 调用方需保证 [resolveViaDoH] 的 host 不是回环/私网地址——此类地址绝不走
/// DoH（见 `direct_connect.dart` 的 `isPrivateOrLoopbackHost`）。
class DoHResolver {
  DoHResolver({
    HttpClient? client,
    DateTime Function()? clock,
    List<String>? endpoints,
  })  : _injectedClient = client,
        _clock = clock ?? DateTime.now,
        _endpoints = endpoints ?? kDefaultDoHEndpoints;

  /// 默认端点：**仅** DNSPod（腾讯）doh.pub。
  ///
  /// 2026-10-24 国内线路实测（当时本机系统 DNS 对 workers.dev 投毒）：
  /// - `doh.pub` JSON 模式返回 workers.dev 的真实 CF IP（172.67.x / 104.21.x），
  ///   可用；
  /// - `dns.alidns.com/dns-query`、`doh.360.cn/dns-query` **只认 RFC 8484
  ///   wire format**（`dns=` 参数），传 JSON 参数直接报
  ///   "no 'dns' query parameter found"——当备用端点永远失败；
  /// - `dns.alidns.com/resolve`（JSON）虽能应答，但对 workers.dev 返回的是
  ///   **污染 IP**（104.244.43.182，Twitter 段 sinkhole），比不答更危险；
  /// - `dns.baidu.com/dns-query` 无响应；`1.1.1.1` / `cloudflare-dns.com` /
  ///   `dns.google` 本机直连与经代理均不通。
  ///
  /// 因此刻意不做「多端点冗余」：doh.pub 失败时安静回退默认通路（= 改造前
  /// 行为），也绝不把污染 IP 当答案用。未来要加端点，先按上述口径实测再进
  /// 列表。
  static const List<String> kDefaultDoHEndpoints = <String>[
    'https://doh.pub/dns-query',
  ];

  final HttpClient? _injectedClient;
  final DateTime Function() _clock;
  final List<String> _endpoints;
  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  /// 自建 client（未注入时懒创建，进程生命周期内复用）。
  HttpClient? _ownClient;

  HttpClient get _client {
    final injected = _injectedClient;
    if (injected != null) return injected;
    return _ownClient ??= HttpClient()
      ..connectionTimeout = kDoHRequestTimeout
      // 强制直连（不走系统代理）：DoH 端点（doh.pub / dns.alidns.com）在
      // 国内可直达，经代理反而被污染或拖慢——实测本机 `https_proxy=
      // http://127.0.0.1:5282` 时，DoH 查询 `*.workers.dev` 返回
      // 31.13.67.41（Facebook 段假 IP），与系统 DNS 返回的
      // 69.171.247.71（同为假 IP）同源：代理把 DoH 的明文 HTTP 流量也污染
      // 了。DoH 存在的意义就是绕开这条被污染的链路，因此它自己必须绕过
      // 代理。见 [dohDirectProxy]。
      ..findProxy = dohDirectProxy;
  }

  /// 解析 [host] 的 IPv4 列表（成功时非空）。
  ///
  /// 契约：命中缓存直接返回；否则按端点顺序查询，任一端点返回非空 A 记录即
  /// 写入缓存并返回；全部端点失败/超时/返回空 → 抛 [DoHResolveException]
  /// （失败不缓存，下次仍会重试）。
  Future<List<String>> resolveViaDoH(String host) async {
    final h = host.trim().toLowerCase();
    if (h.isEmpty) {
      throw const DoHResolveException('empty host');
    }
    final now = _clock();
    final cached = _cache[h];
    if (cached != null && now.isBefore(cached.expiresAt)) {
      return cached.ips;
    }
    DoHResolveException? lastError;
    for (final endpoint in _endpoints) {
      try {
        final answer = await _queryEndpoint(endpoint, h);
        if (answer.ips.isNotEmpty) {
          final entry = _CacheEntry(
            ips: List<String>.unmodifiable(answer.ips),
            expiresAt: now.add(_clampTtl(answer.ttlSeconds)),
          );
          _cache[h] = entry;
          return entry.ips;
        }
        // NOERROR 但无 A 记录：视作失败，不缓存，换下一个端点。
        lastError ??= const DoHResolveException('DoH returned no A records');
      } on DoHResolveException catch (e) {
        lastError = e;
      } on Object catch (e) {
        lastError = DoHResolveException('DoH request failed: $e');
      }
    }
    throw DoHResolveException(
      'all DoH endpoints failed for $h (${lastError?.message ?? 'unknown'})',
    );
  }

  /// 清空内存缓存（测试 / 热重适用）。
  void clearCache() => _cache.clear();

  /// 向单个端点发一次查询；任何失败都抛 [DoHResolveException]。
  Future<DoHAnswer> _queryEndpoint(String endpoint, String host) async {
    final uri = Uri.parse(endpoint).replace(
      queryParameters: <String, String>{'name': host, 'type': 'A'},
    );
    final client = _client;
    final req = await client.getUrl(uri).timeout(kDoHRequestTimeout);
    req.headers.set('Accept', 'application/dns-json');
    final resp = await req.close().timeout(kDoHRequestTimeout);
    try {
      if (resp.statusCode != 200) {
        throw DoHResolveException(
          '$endpoint returned HTTP ${resp.statusCode}',
        );
      }
      final body = await resp.transform(utf8.decoder).join();
      return parseDoHJson(body);
    } finally {
      await _drainQuietly(resp);
    }
  }

  /// TTL 夹取：缺失/非法 → 默认；越界 → 夹到 [min, max]。
  Duration _clampTtl(int? seconds) {
    if (seconds == null || seconds <= 0) return kDoHCacheTtlDefault;
    if (seconds < kDoHCacheTtlMin.inSeconds) return kDoHCacheTtlMin;
    if (seconds > kDoHCacheTtlMax.inSeconds) return kDoHCacheTtlMax;
    return Duration(seconds: seconds);
  }
}

/// 排空响应体以尽快释放连接；失败静默（不影响主流程）。
Future<void> _drainQuietly(HttpClientResponse resp) async {
  try {
    await resp.drain<void>();
  } on Object {
    // 连接已断或响应体读取失败：忽略。
  }
}

class _CacheEntry {
  const _CacheEntry({required this.ips, required this.expiresAt});

  final List<String> ips;
  final DateTime expiresAt;
}

/// 进程内共享的 DoH 解析器（缓存跨 HttpClient 复用）。
final DoHResolver sharedDoHResolver = DoHResolver();

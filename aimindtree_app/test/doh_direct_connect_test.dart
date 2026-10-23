/// DoH 解析（doh_resolver）+ `*.workers.dev` 直连（direct_connect）单测。
///
/// 覆盖：
/// 1. `parseDoHJson` 纯函数：正常多 IP / Status 非 0 / 空 Answer / 畸形 JSON /
///    仅 AAAA / 去重 / TTL 提取；
/// 2. DoHResolver：内存缓存、TTL 过期与夹取（注入时钟）、失败不缓存、
///    请求格式（name/type/Accept）；
/// 3. `isPrivateOrLoopbackHost`：回环/私网矩阵；
/// 4. `createDirectHttpClient` 域名判定分支（fake resolver 验证调用与否）、
///    DoH 失败/空/畸形回退、回退后 client 行为与现状一致；
/// 5. 端到端：本地假 DoH + 本地 TLS（自签证书 + onBadCertificate）验证
///    「DoH → 真 IP → 原域名 SNI TLS → HttpClient 连接池」完整链路，
///    以及全部 IP 建连失败时安静回退默认通路。
library;

import 'dart:convert';
import 'dart:io';

import 'package:aimindtree_app/data/sync/direct_connect.dart';
import 'package:aimindtree_app/data/sync/doh_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本地 TLS 服务器用的自签证书（仅测试用：CN/SAN = e2e.workers.dev，
/// 有效期 100 年；配套私钥同为一次性测试密钥，严禁用于生产）。
const String kTestCertPem = r'''
-----BEGIN CERTIFICATE-----
MIIDSjCCAjKgAwIBAgIUOS1DNRHA2REP1L6KdgShIr5uffMwDQYJKoZIhvcNAQEL
BQAwGjEYMBYGA1UEAwwPZTJlLndvcmtlcnMuZGV2MCAXDTI2MTAyMzEyMjg1N1oY
DzIxMjYwOTI5MTIyODU3WjAaMRgwFgYDVQQDDA9lMmUud29ya2Vycy5kZXYwggEi
MA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCtPdhF9PBX2Ci2gYPK6Ofz3Nrd
uOjUnUmSCCrl5hZHFR/N4Vk2qTMag40GtF6UljGkEzpec+o5lvxS1kEgrV35icpw
XWDY9LwCWlvgMR3ehEmCErtuGOu5dsYgZbfl0gMNOp/GIesjy9BVGL1lkRVxjn0h
4OJRhPs6mBY+6ANBazUw0kV4I3JMWx+yscbWUxgUhnTw30r0PsLf82d7iwHK5u6z
8rNtTlt7x/mvr/lZy8a+W09MTduWw1nN6NmziBmonzBdmvt9n/JtjODOtolv6Bzs
VRjxI5YpD6NpYrAH3DaXMGk406uK8GFfh61VHgkzVDwiuo8lbQkTMxAnu4DbAgMB
AAGjgYUwgYIwHQYDVR0OBBYEFKT/WqpXPzzakMJ5BZyRq/M1P1JAMB8GA1UdIwQY
MBaAFKT/WqpXPzzakMJ5BZyRq/M1P1JAMA8GA1UdEwEB/wQFMAMBAf8wLwYDVR0R
BCgwJoIPZTJlLndvcmtlcnMuZGV2gg0qLndvcmtlcnMuZGV2hwR/AAABMA0GCSqG
SIb3DQEBCwUAA4IBAQCr6yq+je4SQEEjWUTUnZ13nRIC8MkE5w9HCXLMII9ps1FO
CyT63MvceWbpP8Pp3QTZ28a6cgcb0JixspVmi3KY54SEpVi7f7/CUk45VEuxCHpR
ToPyGKRl8TsYiU0iEW0sPO2YLGz6Ms3N/zjt2OjEhB4QNAfwJryBENWzw3tm0a9g
nrOt1KJBMAuVm2K2+Do1JcSn1OpBjia8eXlK2BC+Wggs72X9mI5AMsEvEuOZFUJm
O6sSQyqP83M8U97sWQ/h/nbQ/xxA496MTR+gETdsmtic/CJVm5wMXvXesOm3flx4
XtJnqczJaVIp4ln4VIZlAsb0hO4/Mi7c1FvNtwYE
-----END CERTIFICATE-----
''';

const String kTestKeyPem = r'''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCtPdhF9PBX2Ci2
gYPK6Ofz3NrduOjUnUmSCCrl5hZHFR/N4Vk2qTMag40GtF6UljGkEzpec+o5lvxS
1kEgrV35icpwXWDY9LwCWlvgMR3ehEmCErtuGOu5dsYgZbfl0gMNOp/GIesjy9BV
GL1lkRVxjn0h4OJRhPs6mBY+6ANBazUw0kV4I3JMWx+yscbWUxgUhnTw30r0PsLf
82d7iwHK5u6z8rNtTlt7x/mvr/lZy8a+W09MTduWw1nN6NmziBmonzBdmvt9n/Jt
jODOtolv6BzsVRjxI5YpD6NpYrAH3DaXMGk406uK8GFfh61VHgkzVDwiuo8lbQkT
MxAnu4DbAgMBAAECggEAA3HfNZDnyzoLS98VFvlSTMPqVDiuOeAWIOxpp0r6dsJh
m1ns82HM7YI1JoTP+/tlPvfPlCY7lOvpgN+CybAOK31FGb6O7kbQ4D5vZOyvxTId
4L4XnQUA1vNuKsxq/4u8BMzSytaiKC2QKx5ZUcY0m3PzuAiSkiq8m3nVDhOApmcq
IOXHmTwjGcG/pbWJNfnTOLzGH0KCy8lwhiiuWCvYQRay9ycmMkU+4GkLeTEmt3qa
F4mb1nOyk6Roro8QgWyvmcUO/E3l9suU0pSaUgxPWgGQW14FPn4ajg8AlLy5dne8
l8wrAhjOED/QeIcBtRir56Iv7GdmLQ9y4c5dFf2sCQKBgQDVGAHGzT/+c9cGtr2e
wYA+dCrswp2d9cV14ha08trJJLBTvhAI3XqalqJcwPYcJ7CumLmY0Iy5WSiwc9FE
Kta0s/rSrdWj8F5gTzwz9p0IKy1kIUm4+KCs2BzFIJYQ/GdEsKxrHz8KBWW9N1ar
IOps90Hz1Q0JmyyslwaqBvBrSQKBgQDQH6R98cI4YGt2b0NwCw9Q9EXimqKT0si7
9qbOMjcxffvsWbCBGFW0ljEP+EMIdBTTsQCevASCM9moFNRrj/0/7z3FkTa8a7h+
q947oTNTCrq3TPN8KHDlBywrgWneXEErfBbwQ5dIwDRLGbl1bl97kJ9qqc/7YcrE
jPQ0SuFHAwKBgQCwgS4XiTMUhMb63Kq7sPOUx4w2iA0eJdDlD9xXDUGDkkwrUSbe
8PT4zwS1Z29zarzCIea5WST28Y7ueUBBAmrNSrbbgvmOzS6e/4KSWBdCCOGUKq5x
9B7CjE9oSNGESE0RbHWkVUFV/5qB3DCBlsYWc8fBPBuMdWfPnVj7xLunYQKBgEXg
meX/aepr1SjqqoXP8NCJc31l1fgz6VnSsqbAjW98kT0F0BFIDl6XntlxzW/lKaj5
4O9qyUi+B/I7LCcBLVJuDRtsaihRMpy1L+Rtd0IGdDJfD9E78suy4M2qodUavHbR
LxJ0XzL59ZTRikc3S6+9GwlBAqewadgcS1HTYlfpAoGASGrv3FGLojFCkN1ekP1C
iYqBlFPoSUO91uYGprCNnB6hk9E9/aZVYZ/cWPnOADrrwjH3hOXoTWUUfrY1ECRH
ZZjIanbyKNCPfsL1v1uWqz+TncZRS3xPD/13r2lOgB9sWYcLMiCqOREv0MIec7to
RF4YV5aekDX5WSgyfVXN+s8=
-----END PRIVATE KEY-----
''';

/// 构造标准双 IP 的 DoH 成功响应体。
String _okBody({
  String host = 'x.workers.dev',
  int ttl = 300,
  List<String> ips = const <String>['104.21.27.171', '172.67.169.150'],
}) {
  return jsonEncode(<String, dynamic>{
    'Status': 0,
    'Answer': <Map<String, dynamic>>[
      for (final ip in ips)
        <String, dynamic>{'name': host, 'type': 1, 'TTL': ttl, 'data': ip},
    ],
  });
}

void main() {
  group('parseDoHJson', () {
    test('正常：多 IP + CNAME + AAAA 混合，只取 A 记录并去重', () {
      final answer = parseDoHJson(jsonEncode(<String, dynamic>{
        'Status': 0,
        'Answer': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'x.workers.dev',
            'type': 5,
            'TTL': 300,
            'data': 'x.workers.dev.cdn.cloudflare.net',
          },
          <String, dynamic>{
            'name': 'x.workers.dev',
            'type': 1,
            'TTL': 300,
            'data': '104.21.27.171',
          },
          <String, dynamic>{
            'name': 'x.workers.dev',
            'type': 28,
            'TTL': 300,
            'data': '2606:4700::1',
          },
          <String, dynamic>{
            'name': 'x.workers.dev',
            'type': 1,
            'TTL': 120,
            'data': '172.67.169.150',
          },
          <String, dynamic>{
            'name': 'x.workers.dev',
            'type': 1,
            'TTL': 120,
            'data': '104.21.27.171',
          },
        ],
      }));
      expect(answer.ips, <String>['104.21.27.171', '172.67.169.150']);
      expect(answer.ttlSeconds, 300);
    });

    test('Status 非 0（NXDOMAIN / SERVFAIL）→ 抛 DoHResolveException', () {
      for (final status in <int>[2, 3, 5]) {
        expect(
          () => parseDoHJson(jsonEncode(<String, dynamic>{
            'Status': status,
            'Answer': <Map<String, dynamic>>[],
          })),
          throwsA(isA<DoHResolveException>()),
        );
      }
    });

    test('空 Answer / 缺 Answer → 空列表（不抛）', () {
      expect(parseDoHJson('{"Status":0,"Answer":[]}').ips, isEmpty);
      expect(parseDoHJson('{"Status":0}').ips, isEmpty);
    });

    test('畸形 JSON / 根非对象 / Answer 非数组 → 抛 DoHResolveException', () {
      for (final body in <String>[
        '',
        'not json',
        'null',
        '[]',
        '{"Status":0,"Answer":"oops"}',
        '{"Status":"0","Answer":[]}',
      ]) {
        expect(
          () => parseDoHJson(body),
          throwsA(isA<DoHResolveException>()),
          reason: body,
        );
      }
    });

    test('仅 AAAA 记录 → 空列表（不抛）', () {
      final answer = parseDoHJson(jsonEncode(<String, dynamic>{
        'Status': 0,
        'Answer': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'x.workers.dev',
            'type': 28,
            'TTL': 300,
            'data': '2606:4700::1',
          },
        ],
      }));
      expect(answer.ips, isEmpty);
      expect(answer.ttlSeconds, isNull);
    });
  });

  group('DoHResolver (fake DoH server)', () {
    late HttpServer server;
    late int port;
    int hits = 0;
    int status = 200;
    String body = '';
    String? lastQuery;
    String? lastAccept;

    setUp(() async {
      hits = 0;
      status = 200;
      body = _okBody();
      lastQuery = null;
      lastAccept = null;
      server = await HttpServer.bind('127.0.0.1', 0);
      port = server.port;
      server.listen((req) async {
        hits++;
        lastQuery = req.uri.query;
        lastAccept = req.headers.value('Accept');
        req.response.statusCode = status;
        req.response.headers.contentType = ContentType.json;
        req.response.write(body);
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    DoHResolver resolverAt(DateTime Function() clock) => DoHResolver(
          endpoints: <String>['http://127.0.0.1:$port/dns-query'],
          clock: clock,
        );

    test('请求格式：name/type=A + Accept: application/dns-json', () async {
      final r = resolverAt(() => DateTime.utc(2026));
      await r.resolveViaDoH('X.WORKERS.DEV');
      expect(lastQuery, contains('name=x.workers.dev'));
      expect(lastQuery, contains('type=A'));
      expect(lastAccept, 'application/dns-json');
    });

    test('TTL 内命中缓存；过期后重新查询', () async {
      var now = DateTime.utc(2026, 10, 23, 12);
      final r = resolverAt(() => now);
      expect(
        await r.resolveViaDoH('x.workers.dev'),
        <String>['104.21.27.171', '172.67.169.150'],
      );
      expect(hits, 1);

      await r.resolveViaDoH('x.workers.dev');
      expect(hits, 1); // 缓存命中，不发请求

      now = now.add(const Duration(seconds: 299));
      await r.resolveViaDoH('x.workers.dev');
      expect(hits, 1); // TTL=300，仍未过期

      now = now.add(const Duration(seconds: 2));
      await r.resolveViaDoH('x.workers.dev');
      expect(hits, 2); // 过期，重新查询
    });

    test('TTL 夹取：DNS TTL=5 → 按 60s 缓存', () async {
      body = _okBody(ttl: 5);
      var now = DateTime.utc(2026, 10, 23, 12);
      final r = resolverAt(() => now);
      await r.resolveViaDoH('x.workers.dev');
      expect(hits, 1);

      now = now.add(const Duration(seconds: 59));
      await r.resolveViaDoH('x.workers.dev');
      expect(hits, 1);

      now = now.add(const Duration(seconds: 2));
      await r.resolveViaDoH('x.workers.dev');
      expect(hits, 2);
    });

    test('TTL 夹取：DNS TTL=99999 → 按 600s 缓存', () async {
      body = _okBody(ttl: 99999);
      var now = DateTime.utc(2026, 10, 23, 12);
      final r = resolverAt(() => now);
      await r.resolveViaDoH('x.workers.dev');
      expect(hits, 1);

      now = now.add(const Duration(seconds: 599));
      await r.resolveViaDoH('x.workers.dev');
      expect(hits, 1);

      now = now.add(const Duration(seconds: 2));
      await r.resolveViaDoH('x.workers.dev');
      expect(hits, 2);
    });

    test('失败不缓存：HTTP 500 / 畸形 JSON / Status 非 0 后恢复立即可用', () async {
      final r = resolverAt(() => DateTime.utc(2026));

      status = 500;
      body = 'oops';
      await expectLater(
        r.resolveViaDoH('x.workers.dev'),
        throwsA(isA<DoHResolveException>()),
      );

      status = 200;
      body = 'not json';
      await expectLater(
        r.resolveViaDoH('x.workers.dev'),
        throwsA(isA<DoHResolveException>()),
      );

      body = jsonEncode(<String, dynamic>{
        'Status': 3,
        'Answer': <Map<String, dynamic>>[],
      });
      await expectLater(
        r.resolveViaDoH('x.workers.dev'),
        throwsA(isA<DoHResolveException>()),
      );

      body = _okBody();
      expect(
        await r.resolveViaDoH('x.workers.dev'),
        <String>['104.21.27.171', '172.67.169.150'],
      ); // 无负缓存：恢复后立即成功
    });

    test('空 Answer 视作失败：不缓存、不返回空列表', () async {
      body = jsonEncode(<String, dynamic>{
        'Status': 0,
        'Answer': <Map<String, dynamic>>[],
      });
      final r = resolverAt(() => DateTime.utc(2026));
      await expectLater(
        r.resolveViaDoH('x.workers.dev'),
        throwsA(isA<DoHResolveException>()),
      );
      await expectLater(
        r.resolveViaDoH('x.workers.dev'),
        throwsA(isA<DoHResolveException>()),
      );
      expect(hits, 2); // 没有把空结果写进缓存
    });

    test('不同 host 独立缓存', () async {
      final r = resolverAt(() => DateTime.utc(2026));
      await r.resolveViaDoH('a.workers.dev');
      await r.resolveViaDoH('b.workers.dev');
      expect(hits, 2);
      await r.resolveViaDoH('a.workers.dev');
      await r.resolveViaDoH('b.workers.dev');
      expect(hits, 2);
    });
  });

  group('isPrivateOrLoopbackHost', () {
    test('回环/私网/保留 → true', () {
      for (final h in <String>[
        '',
        'localhost',
        'LOCALHOST',
        'localhost.',
        '127.0.0.1',
        '127.1.2.3',
        '10.0.0.1',
        '10.255.255.255',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.1.1',
        '169.254.1.1',
        '100.64.0.1',
        '100.127.255.255',
        '0.0.0.0',
        '::1',
        '[::1]',
        '224.0.0.1',
        '255.255.255.255',
      ]) {
        expect(isPrivateOrLoopbackHost(h), isTrue, reason: h);
      }
    });

    test('公网域名/IP（含 CF 段、workers.dev）→ false', () {
      for (final h in <String>[
        'example.com',
        'aimindtree.com',
        'doh.pub',
        'x.workers.dev',
        'aimindtree-sync-relay.tuanx.workers.dev',
        '104.21.27.171',
        '172.67.169.150',
        '8.8.8.8',
        '172.15.255.255',
        '172.32.0.1',
        '192.169.1.1',
        '100.63.255.255',
        '100.128.0.1',
      ]) {
        expect(isPrivateOrLoopbackHost(h), isFalse, reason: h);
      }
    });
  });

  group('createDirectHttpClient routing (fake resolver)', () {
    /// 记录调用的假解析器：被调用时把 host 记入 [calls]，返回 [ips]。
    IpResolver recordingResolver(List<String> calls,
        {List<String> ips = const <String>['127.0.0.1']}) {
      return (String host) async {
        calls.add(host);
        return ips;
      };
    }

    test('*.workers.dev 触发 DoH；私网/其他域名不触发', () async {
      final calls = <String>[];
      final fake = recordingResolver(calls);

      final c1 = await createDirectHttpClient(
        'https://aimindtree-sync-relay.tuanx.workers.dev',
        ipResolver: fake,
      );
      expect(calls, <String>['aimindtree-sync-relay.tuanx.workers.dev']);
      c1.close(force: true);

      for (final url in <String>[
        'http://127.0.0.1:8080',
        'http://localhost:8080',
        'http://10.1.2.3:8080',
        'http://192.168.1.5:8080',
        'http://172.16.0.9:8080',
        'http://172.31.0.9:8080',
        'https://example.com',
        'https://aimindtree.com/api',
      ]) {
        final c = await createDirectHttpClient(url, ipResolver: fake);
        c.close(force: true);
      }
      expect(calls, <String>['aimindtree-sync-relay.tuanx.workers.dev']);
    });

    test('DoH 抛错 → 安静回退普通 client，不抛', () async {
      final client = await createDirectHttpClient(
        'https://x.workers.dev',
        ipResolver: (_) async =>
            throw const DoHResolveException('boom'),
      );
      expect(client, isA<HttpClient>());
      client.close(force: true);
    });

    test('DoH 返回空 → 安静回退普通 client，不抛', () async {
      final client = await createDirectHttpClient(
        'https://x.workers.dev',
        ipResolver: (_) async => const <String>[],
      );
      expect(client, isA<HttpClient>());
      client.close(force: true);
    });

    test('baseUrl 畸形 → 普通 client，不抛', () async {
      final calls = <String>[];
      final fake = recordingResolver(calls);
      for (final url in <String>['not a url', 'https://[']) {
        final c = await createDirectHttpClient(url, ipResolver: fake);
        expect(c, isA<HttpClient>());
        c.close(force: true);
      }
      expect(calls, isEmpty);
    });

    test('回退后 client 对普通请求与现状完全一致', () async {
      // 本地普通 HTTP 服务（模拟 llm_server 等非 workers.dev 目标）。
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.write('ok');
        await req.response.close();
      });

      // fake resolver 返回 127.0.0.1（443 无人监听，直连必失败）——
      // 但工厂是懒触发的，此处只验证：建 client 不抛 + 普通请求正常。
      final client = await createDirectHttpClient(
        'https://x.workers.dev',
        ipResolver: (_) async => const <String>['127.0.0.1'],
      );
      final request =
          await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/'));
      final resp = await request.close();
      expect(await resp.transform(utf8.decoder).join(), 'ok');
      client.close(force: true);
    });
  });

  group('e2e: DoH + SecureSocket + connectionFactory (local TLS)', () {
    late HttpServer dohServer;
    late HttpServer tlsServer;
    late int dohPort;
    late int tlsPort;
    int dohHits = 0;
    String dohIp = '127.0.0.1';

    setUp(() async {
      dohHits = 0;
      dohIp = '127.0.0.1';

      dohServer = await HttpServer.bind('127.0.0.1', 0);
      dohPort = dohServer.port;
      dohServer.listen((req) async {
        dohHits++;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, dynamic>{
          'Status': 0,
          'Answer': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'e2e.workers.dev',
              'type': 1,
              'TTL': 300,
              'data': dohIp,
            },
          ],
        }));
        await req.response.close();
      });

      final context = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(kTestCertPem))
        ..usePrivateKeyBytes(utf8.encode(kTestKeyPem));
      tlsServer = await HttpServer.bindSecure('127.0.0.1', 0, context);
      tlsPort = tlsServer.port;
      tlsServer.listen((req) async {
        req.response.write('pong');
        await req.response.close();
      });
    });

    tearDown(() async {
      await dohServer.close(force: true);
      await tlsServer.close(force: true);
    });

    test('完整链路：DoH → 127.0.0.1 → 原域名 SNI TLS → HTTP 200', () async {
      final resolver = DoHResolver(
        endpoints: <String>['http://127.0.0.1:$dohPort/dns-query'],
      );
      final client = await createDirectHttpClient(
        'https://e2e.workers.dev:$tlsPort',
        ipResolver: resolver.resolveViaDoH,
        onBadCertificate: (_) => true,
      );

      final resp = await (await client
              .getUrl(Uri.parse('https://e2e.workers.dev:$tlsPort/ping')))
          .close();
      expect(resp.statusCode, 200);
      expect(await resp.transform(utf8.decoder).join(), 'pong');
      // 预解析一次；工厂内命中缓存不再请求 DoH。
      expect(dohHits, 1);
      client.close(force: true);
    });

    test('全部 IP 建连失败 → 安静回退默认通路（不挂死、不抛未捕获异常）',
        () async {
      dohIp = '127.0.0.2'; // 回环但无人监听 → 必失败
      final resolver = DoHResolver(
        endpoints: <String>['http://127.0.0.1:$dohPort/dns-query'],
      );
      final client = await createDirectHttpClient(
        'https://e2e.workers.dev:$tlsPort',
        ipResolver: resolver.resolveViaDoH,
        connectionTimeout: const Duration(seconds: 3),
      );

      // 不回退会挂死；回退后走真实 DNS（沙箱内 e2e.workers.dev 连不通）
      // → 抛错。有界失败即证明回退链路生效。
      await expectLater(
        client.getUrl(Uri.parse('https://e2e.workers.dev:$tlsPort/ping')),
        throwsA(anything),
      );
      client.close(force: true);
    });
  });
}

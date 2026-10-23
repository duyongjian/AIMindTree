/// 「同步地址 + HTTP 代理」自定义入口（逃生舱）的纯逻辑单测。
///
/// 覆盖：
/// 1. `SyncConfig.cfProxy` 读写：空串视为未设置、`setCfProxy(null)` 清干净、
///    `clear()` 一并复位；
/// 2. `setUserProxy` 归一化：`http://host:port` → `host:port`、空白 → null；
/// 3. `syncFindProxy` 优先级：回环直连 > 用户手动代理 > 自动探测 > DIRECT；
/// 4. `createDirectHttpClient` 的非 workers.dev 回退分支确实带上了
///    `syncFindProxy`（用本地假代理的行为观测：能出结果就证明走了代理）；
/// 5. 源码守卫：设置页「保存」必须同时改 prefs 与进程内代理。
library;

import 'dart:convert';
import 'dart:io';

import 'package:aimindtree_app/core/secret_store.dart';
import 'package:aimindtree_app/data/sync/direct_connect.dart';
import 'package:aimindtree_app/data/sync/http_proxy.dart';
import 'package:aimindtree_app/data/sync/sync_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「没设用户代理时」syncFindProxy 的回落值：本环境通常没有自动探测结果 →
/// DIRECT；万一探测到了就是 PROXY $detectedSystemProxy（测试要两者都对）。
String _fallback() =>
    detectedSystemProxy == null ? 'DIRECT' : 'PROXY $detectedSystemProxy';

void main() {
  group('SyncConfig.cfProxy 读写', () {
    late SharedPreferences prefs;
    late SyncConfig config;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      prefs = await SharedPreferences.getInstance();
      config = SyncConfig(prefs: prefs, secretStore: InMemorySecretStore());
    });

    test('默认未设置 → null', () {
      expect(config.cfProxy, isNull);
    });

    test('保存后可读回', () async {
      await config.setCfProxy('127.0.0.1:7890');
      expect(config.cfProxy, '127.0.0.1:7890');
      await config.setCfProxy('192.168.1.9:10808');
      expect(config.cfProxy, '192.168.1.9:10808');
    });

    test('空串 / 纯空白视为未设置（null）', () async {
      await config.setCfProxy('127.0.0.1:7890');
      await config.setCfProxy('');
      expect(config.cfProxy, isNull);

      await config.setCfProxy('127.0.0.1:7890');
      await config.setCfProxy('   ');
      expect(config.cfProxy, isNull);
    });

    test('setCfProxy(null) 清干净（pref 里不留痕迹）', () async {
      await config.setCfProxy('127.0.0.1:7890');
      await config.setCfProxy(null);
      expect(config.cfProxy, isNull);
      expect(prefs.containsKey('aimindtree.sync.cf_proxy'), isFalse);
    });

    test('写入时两侧空白被 trim', () async {
      await config.setCfProxy('  127.0.0.1:7890  ');
      expect(config.cfProxy, '127.0.0.1:7890');
    });

    test('clear() 一并复位 cfProxy（含地址 / 每用户令牌）', () async {
      await config.setUrl(
          SyncBackend.cloudflare, 'https://my-relay.example.com');
      await config.setCfProxy('127.0.0.1:7890');
      await config.setUserToken(SyncBackend.cloudflare, 't');
      expect(config.cfProxy, '127.0.0.1:7890');

      await config.clear();
      expect(config.cfProxy, isNull);
      expect(config.urlOverrideOf(SyncBackend.cloudflare), isNull);
      expect(await config.resolveUserToken(SyncBackend.cloudflare), isNull);
      // 地址清空后回落到内置默认（用户「什么都没配」的开箱体验）。
      expect(
        config.urlOf(SyncBackend.cloudflare),
        SyncConfig.kSyncCfDefaultBaseUrl,
      );
    });
  });

  group('setUserProxy 归一化', () {
    // 模块级单例状态：每个用例结束后清干净，避免污染其他测试文件。
    setUp(() => setUserProxy(null));
    tearDown(() => setUserProxy(null));

    test('http://127.0.0.1:7890 → 127.0.0.1:7890', () {
      setUserProxy('http://127.0.0.1:7890');
      expect(userProxyOverride, '127.0.0.1:7890');
    });

    test('socks5://192.168.1.5:10808 → 192.168.1.5:10808', () {
      setUserProxy('socks5://192.168.1.5:10808');
      expect(userProxyOverride, '192.168.1.5:10808');
    });

    test('https:// + 两侧空白 → 去掉 scheme 与空白', () {
      setUserProxy('  https://proxy.example.com:8080  ');
      expect(userProxyOverride, 'proxy.example.com:8080');
    });

    test('原本就是 host:port 时原样保留', () {
      setUserProxy('127.0.0.1:7897');
      expect(userProxyOverride, '127.0.0.1:7897');
    });

    test('空串 / 纯空白 / null → null（回落自动探测或直连）', () {
      setUserProxy('127.0.0.1:7890');
      setUserProxy('');
      expect(userProxyOverride, isNull);

      setUserProxy('127.0.0.1:7890');
      setUserProxy('   ');
      expect(userProxyOverride, isNull);

      setUserProxy(null);
      expect(userProxyOverride, isNull);
    });
  });

  group('syncFindProxy 优先级', () {
    setUp(() => setUserProxy(null));
    tearDown(() => setUserProxy(null));

    test('回环地址恒 DIRECT（即使用户填了代理）', () {
      setUserProxy('127.0.0.1:7890');
      for (final host in <String>['localhost', '127.0.0.1']) {
        expect(
          syncFindProxy(Uri.parse('http://$host:8787/')),
          'DIRECT',
          reason: host,
        );
      }
    });

    test('用户手动代理优先于自动探测：外网 host → PROXY host:port', () {
      setUserProxy('proxy.example.com:8080');
      expect(
        syncFindProxy(Uri.parse('https://aimindtree-sync-relay.tuanx.workers.dev/')),
        'PROXY proxy.example.com:8080',
      );
      expect(
        syncFindProxy(Uri.parse('http://example.com/')),
        'PROXY proxy.example.com:8080',
      );
    });

    test('清空用户代理后回落（本环境无自动探测结果 → DIRECT）', () {
      setUserProxy('127.0.0.1:7890');
      expect(syncFindProxy(Uri.parse('https://example.com/')), 'PROXY 127.0.0.1:7890');
      setUserProxy(null);
      expect(
        syncFindProxy(Uri.parse('https://example.com/')),
        detectedSystemProxy == null
            ? 'DIRECT'
            : 'PROXY $detectedSystemProxy',
      );
    });
  });

  group('createDirectHttpClient 的非 workers.dev 分支带 findProxy', () {
    late HttpServer proxyServer;

    setUp(() async {
      setUserProxy(null);
      // 一个只会回固定内容的假代理：请求真的发到它这儿，就说明 HttpClient
      // 用了 syncFindProxy（否则会直接去解析那个根本不存在的域名）。
      proxyServer = await HttpServer.bind('127.0.0.1', 0);
      proxyServer.listen((HttpRequest req) async {
        req.response.write('via-proxy');
        await req.response.close();
      });
    });

    tearDown(() async {
      setUserProxy(null);
      await proxyServer.close(force: true);
    });

    test('非 workers.dev 主机：设了手动代理请求就经代理出去', () async {
      setUserProxy('127.0.0.1:${proxyServer.port}');
      final client = await createDirectHttpClient(
        'https://plain.example.com',
        connectionTimeout: const Duration(seconds: 5),
      );
      // 目标域名不存在：只有在「走了代理」的情况下才拿得到响应。
      // 这里刻意用 http 目标——https 目标会走 CONNECT 隧道（要代理支持才行），
      // 而「是否使用代理」这件事本身与 scheme 无关。
      final req = await client
          .getUrl(Uri.parse('http://no-such-relay.invalid/'))
          .timeout(const Duration(seconds: 10));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      expect(await resp.transform(utf8.decoder).join(), 'via-proxy');
      client.close(force: true);
    });

    test('对照：不设代理时同一请求直连必失败（证明上一条的差异来自代理）',
        () async {
      final client = await createDirectHttpClient(
        'https://plain.example.com',
        connectionTimeout: const Duration(seconds: 5),
      );
      await expectLater(
        client
            .getUrl(Uri.parse('http://no-such-relay.invalid/'))
            .timeout(const Duration(seconds: 20)),
        throwsA(anything),
      );
      client.close(force: true);
    });
  });

  group('启动时从 prefs 还原用户代理（bootstrap 重放）', () {
    setUp(() => setUserProxy(null));
    tearDown(() => setUserProxy(null));

    test('prefs 里有 cf_proxy → 还原后外网走该代理，回环仍直连', () async {
      // 模拟「用户上次配了代理，然后重启了 App」。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'aimindtree.sync.cf_proxy': '127.0.0.1:7890',
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = SyncConfig(prefs: prefs, secretStore: InMemorySecretStore());

      // bootstrap 里那一行（extraction_service.dart）
      setUserProxy(cfg.cfProxy);

      expect(userProxyOverride, '127.0.0.1:7890');
      expect(
        syncFindProxy(Uri.parse('https://aimindtree-sync-relay.tuanx.workers.dev/')),
        'PROXY 127.0.0.1:7890',
      );
      expect(
        syncFindProxy(Uri.parse('https://example.com/')),
        'PROXY 127.0.0.1:7890',
      );
      // 回环优先级最高：本机 llm_server 不能被代理拐走。
      expect(syncFindProxy(Uri.parse('http://127.0.0.1:8787/')), 'DIRECT');
      expect(syncFindProxy(Uri.parse('http://localhost:8787/')), 'DIRECT');
    });

    test('prefs 里的值带空白 → 还原后被 trim 成干净的 host:port', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'aimindtree.sync.cf_proxy': '  http://proxy.home:8080  ',
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = SyncConfig(prefs: prefs, secretStore: InMemorySecretStore());

      setUserProxy(cfg.cfProxy);
      expect(userProxyOverride, 'proxy.home:8080');
      expect(
        syncFindProxy(Uri.parse('https://example.com/')),
        'PROXY proxy.home:8080',
      );
    });

    test('prefs 里没有该 key：读到 null → 已有覆盖被清掉，回落到原逻辑', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final cfg = SyncConfig(prefs: prefs, secretStore: InMemorySecretStore());

      // 先假装进程里残留着上一次会话的覆盖。
      setUserProxy('127.0.0.1:7890');
      expect(userProxyOverride, '127.0.0.1:7890');
      expect(syncFindProxy(Uri.parse('https://example.com/')), 'PROXY 127.0.0.1:7890');

      setUserProxy(cfg.cfProxy); // prefs 未设置 → null
      expect(userProxyOverride, isNull);
      expect(syncFindProxy(Uri.parse('https://example.com/')), _fallback());
      expect(syncFindProxy(Uri.parse('http://127.0.0.1:8787/')), 'DIRECT');
    });

    test('prefs 里是空白串（等价于未设置）→ 同样回落，不会变成 PROXY 空串',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'aimindtree.sync.cf_proxy': '   ',
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = SyncConfig(prefs: prefs, secretStore: InMemorySecretStore());

      setUserProxy(cfg.cfProxy);
      expect(userProxyOverride, isNull);
      // 关键：绝不能出现 'PROXY ' 这种让 HttpClient 直接崩掉的脏值。
      expect(syncFindProxy(Uri.parse('https://example.com/')), _fallback());
    });

    test('装配守卫：bootstrap 在拿到 prefs 后、发包前重放代理', () {
      final source = File('lib/ai/extraction_service.dart').readAsStringSync();
      expect(source, contains('setUserProxy(syncConfig.cfProxy)'));
      // 顺序要求：重放必须早于任何会建 HttpClient 的动作（这里是最早的下发
      // 拉取），否则那部分请求仍会漏掉用户代理。
      final replay = source.indexOf('setUserProxy(syncConfig.cfProxy)');
      final firstHttp = source.indexOf('AppConfigService.fetchAndApply');
      expect(replay, greaterThan(0));
      expect(firstHttp, greaterThan(0));
      expect(replay, lessThan(firstHttp));
    });
  });

  group('设置页接线（源码守卫）', () {
    test('保存动作同时写 prefs 与进程内代理（两者缺一都算没接好）', () {
      final source =
          File('lib/features/settings/sync_settings_section.dart').readAsStringSync();
      expect(source, contains('setCfProxy'));
      expect(source, contains('setUserProxy'));
      expect(source, contains('setUrl('));
      expect(source, contains('createDirectHttpClient'));
    });
  });
}

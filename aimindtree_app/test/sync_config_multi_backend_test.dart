/// SyncConfig 多后端（Cloudflare / 腾讯云 CloudBase / Vercel）单元测试。
///
/// 覆盖：三后端默认/覆盖地址、cloudflare 沿用旧 key（老用户数据零迁移）、
/// selectedBackend 持久化、每后端账号独立隔离、clear() 清所有后端、
/// Vercel 内置默认为空串时 urlOf 返回空。
library;

import 'package:aimindtree_app/core/secret_store.dart';
import 'package:aimindtree_app/data/sync/sync_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SyncConfig 多后端', () {
    late SharedPreferences prefs;
    late InMemorySecretStore store;
    late SyncConfig config;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      prefs = await SharedPreferences.getInstance();
      store = InMemorySecretStore();
      config = SyncConfig(prefs: prefs, secretStore: store);
    });

    test('枚举展示名与 pref key 后缀稳定', () {
      expect(SyncBackend.cloudflare.label, 'Cloudflare');
      expect(SyncBackend.cloudbase.label, '腾讯云 CloudBase');
      expect(SyncBackend.vercel.label, 'Vercel');
      expect(
        SyncBackend.values.map((b) => b.keySuffix).toList(),
        <String>['cf', 'cb', 'vc'],
      );
    });

    test('三个后端各自读内置默认地址', () {
      expect(
        config.urlOf(SyncBackend.cloudflare),
        SyncConfig.kSyncCfDefaultBaseUrl,
      );
      expect(
        config.urlOf(SyncBackend.cloudbase),
        SyncConfig.kSyncCbDefaultBaseUrl,
      );
      // Vercel 域名待部署回填：内置默认为空串。
      expect(SyncConfig.kSyncVercelDefaultBaseUrl, '');
      expect(config.urlOf(SyncBackend.vercel), '');
    });

    test('每个后端可独立覆盖地址（trim；空串=清除覆盖回落默认）', () async {
      await config.setUrl(
        SyncBackend.cloudbase,
        '  https://cb.example.com/  ',
      );
      expect(
        config.urlOf(SyncBackend.cloudbase),
        'https://cb.example.com/',
      );
      expect(
        config.urlOverrideOf(SyncBackend.cloudbase),
        'https://cb.example.com/',
      );
      // 互不影响：其他后端仍是各自默认。
      expect(
        config.urlOf(SyncBackend.cloudflare),
        SyncConfig.kSyncCfDefaultBaseUrl,
      );
      expect(config.urlOf(SyncBackend.vercel), '');

      // 空串 → 清除覆盖 → 回落内置默认。
      await config.setUrl(SyncBackend.cloudbase, '   ');
      expect(config.urlOverrideOf(SyncBackend.cloudbase), isNull);
      expect(
        config.urlOf(SyncBackend.cloudbase),
        SyncConfig.kSyncCbDefaultBaseUrl,
      );
    });

    test('Vercel 内置默认为空时 urlOf 返回空；用户手填后返回手填值', () async {
      expect(config.urlOf(SyncBackend.vercel), '');
      await config.setUrl(
        SyncBackend.vercel,
        'https://mindtree-sync.vercel.app',
      );
      expect(
        config.urlOf(SyncBackend.vercel),
        'https://mindtree-sync.vercel.app',
      );
    });

    test('cloudflare 沿用旧 pref key（老用户数据零迁移）', () async {
      // 模拟老版本写下的 prefs / SecretStore（key 与新版本 cloudflare 一致）。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'aimindtree.sync.cf_url': 'https://legacy-relay.example.com',
        'aimindtree.sync.cf_username': 'legacy-user',
      });
      prefs = await SharedPreferences.getInstance();
      config = SyncConfig(prefs: prefs, secretStore: store);
      await store.set('aimindtree.sync.cf_user_token', 'legacy-token');

      expect(
        config.urlOf(SyncBackend.cloudflare),
        'https://legacy-relay.example.com',
      );
      expect(
        config.usernameOf(SyncBackend.cloudflare),
        'legacy-user',
      );
      expect(
        await config.resolveUserToken(SyncBackend.cloudflare),
        'legacy-token',
      );
      expect(await config.isLoggedIn(SyncBackend.cloudflare), isTrue);
    });

    test('selectedBackend 持久化（存枚举 name；默认 cloudflare）', () async {
      expect(config.selectedBackend, SyncBackend.cloudflare);
      expect(prefs.getString('aimindtree.sync.backend'), isNull);

      await config.setSelectedBackend(SyncBackend.cloudbase);
      expect(config.selectedBackend, SyncBackend.cloudbase);
      expect(prefs.getString('aimindtree.sync.backend'), 'cloudbase');

      // 新实例（模拟重启 App）读回同一选择。
      final reloaded = SyncConfig(prefs: prefs, secretStore: store);
      expect(reloaded.selectedBackend, SyncBackend.cloudbase);

      // 脏值回落 cloudflare。
      await prefs.setString('aimindtree.sync.backend', 'no-such-backend');
      expect(config.selectedBackend, SyncBackend.cloudflare);
    });

    test('三个后端账号互相独立（A 登录不影响 B）', () async {
      await config.setUsername(SyncBackend.cloudflare, 'alice');
      await config.setUserToken(SyncBackend.cloudflare, 'cf-token');

      expect(await config.isLoggedIn(SyncBackend.cloudflare), isTrue);
      expect(config.usernameOf(SyncBackend.cloudbase), isNull);
      expect(await config.resolveUserToken(SyncBackend.cloudbase), isNull);
      expect(await config.isLoggedIn(SyncBackend.cloudbase), isFalse);
      expect(await config.isLoggedIn(SyncBackend.vercel), isFalse);

      // key 也按后缀隔离（cf / cb / vc）。
      expect(prefs.getString('aimindtree.sync.cf_username'), 'alice');
      expect(prefs.getString('aimindtree.sync.cb_username'), isNull);
      expect(prefs.getString('aimindtree.sync.vc_username'), isNull);
      expect(await store.get('aimindtree.sync.cb_user_token'), isNull);
    });

    test('setUsername(null)/空串 清除；setUserToken(null) 登出', () async {
      await config.setUsername(SyncBackend.vercel, 'bob');
      await config.setUserToken(SyncBackend.vercel, 'vc-token');
      expect(await config.isLoggedIn(SyncBackend.vercel), isTrue);

      await config.setUsername(SyncBackend.vercel, '  ');
      expect(config.usernameOf(SyncBackend.vercel), isNull);

      await config.setUsername(SyncBackend.vercel, 'bob');
      await config.setUserToken(SyncBackend.vercel, null);
      expect(await config.isLoggedIn(SyncBackend.vercel), isFalse);
      expect(await config.resolveUserToken(SyncBackend.vercel), isNull);
    });

    test('clear() 清所有后端（含选中项与代理）', () async {
      await config.setUrl(
        SyncBackend.cloudflare,
        'https://cf.example.com',
      );
      await config.setUrl(
        SyncBackend.cloudbase,
        'https://cb.example.com',
      );
      await config.setUrl(
        SyncBackend.vercel,
        'https://vc.example.com',
      );
      await config.setUsername(SyncBackend.cloudflare, 'alice');
      await config.setUsername(SyncBackend.cloudbase, 'bob');
      await config.setUsername(SyncBackend.vercel, 'carol');
      await config.setUserToken(SyncBackend.cloudflare, 't1');
      await config.setUserToken(SyncBackend.cloudbase, 't2');
      await config.setUserToken(SyncBackend.vercel, 't3');
      await config.setSelectedBackend(SyncBackend.vercel);
      await config.setCfProxy('127.0.0.1:7890');

      await config.clear();

      for (final b in SyncBackend.values) {
        expect(config.urlOverrideOf(b), isNull);
        expect(config.usernameOf(b), isNull);
        expect(await config.resolveUserToken(b), isNull);
      }
      // 选中项回落默认 cloudflare，代理清掉。
      expect(config.selectedBackend, SyncBackend.cloudflare);
      expect(config.cfProxy, isNull);
      // 地址清空后回落到内置默认（CF/CB 有默认，Vercel 为空）。
      expect(
        config.urlOf(SyncBackend.cloudflare),
        SyncConfig.kSyncCfDefaultBaseUrl,
      );
      expect(config.urlOf(SyncBackend.vercel), '');
    });

    test('clear() 顺带清掉历史遗留 key（llm 目标 / CF 直存共享 token）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'aimindtree.sync.base_url': 'http://127.0.0.1:8787',
        'aimindtree.sync.token_ref': 'sync_x',
        'aimindtree.sync.enabled': true,
        'aimindtree.sync.cf_token': 'direct-token',
        'aimindtree.sync.cf_token_ref': 'cf-ref',
      });
      prefs = await SharedPreferences.getInstance();
      config = SyncConfig(prefs: prefs, secretStore: store);

      await config.clear();

      expect(prefs.getString('aimindtree.sync.base_url'), isNull);
      expect(prefs.getString('aimindtree.sync.token_ref'), isNull);
      expect(prefs.getBool('aimindtree.sync.enabled'), isNull);
      expect(prefs.getString('aimindtree.sync.cf_token'), isNull);
      expect(prefs.getString('aimindtree.sync.cf_token_ref'), isNull);
    });
  });
}

/// SyncConfig 多后端（Cloudflare / EdgeOne Pages / Netlify）单元测试。
///
/// 覆盖：三后端默认/覆盖地址、cloudflare 沿用旧 key（老用户数据零迁移）、
/// selectedBackend 持久化、每后端账号独立隔离、clear() 清所有后端、
/// Netlify / EdgeOne 已部署/待回填域名（EdgeOne 未填时 urlOf 返回空）、
/// 各后端 push 字节预算取值。
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
      expect(SyncBackend.edgeone.label, 'EdgeOne Pages');
      expect(SyncBackend.netlify.label, 'Netlify');
      expect(
        SyncBackend.values.map((b) => b.keySuffix).toList(),
        <String>['cf', 'eo', 'nf'],
      );
    });

    test('三个后端各自读内置默认地址', () {
      expect(
        config.urlOf(SyncBackend.cloudflare),
        SyncConfig.kSyncCfDefaultBaseUrl,
      );
      // Netlify 已部署，内置默认非空（只需根域名）；EdgeOne 待回填，空串。
      expect(
        config.urlOf(SyncBackend.netlify),
        SyncConfig.kSyncNetlifyDefaultBaseUrl,
      );
      expect(
        SyncConfig.kSyncNetlifyDefaultBaseUrl,
        'https://aimindtree-sync-relay.netlify.app',
      );
      expect(SyncConfig.kSyncEoDefaultBaseUrl, '');
      expect(config.urlOf(SyncBackend.edgeone), '');
    });

    test('push 字节预算 / 单条硬上限按后端取值（edgeone 收紧 850KB）', () {
      // 默认（CF / Netlify）：4MB / 6MB。
      for (final b in [
        SyncBackend.cloudflare,
        SyncBackend.netlify,
      ]) {
        expect(b.pushBatchBudgetBytes, SyncConfig.kSyncPushBatchBudgetBytes);
        expect(b.maxEnvelopeBytes, SyncConfig.kSyncMaxEnvelopeBytes);
      }
      // edgeone：受平台请求体 1MB 硬限约束，预算与硬上限都取 850KB。
      expect(SyncBackend.edgeone.pushBatchBudgetBytes,
          SyncConfig.kSyncEoPushBudgetBytes);
      expect(SyncBackend.edgeone.maxEnvelopeBytes,
          SyncConfig.kSyncEoPushBudgetBytes);
      expect(SyncConfig.kSyncEoPushBudgetBytes, 850 * 1024);
    });

    test('当前三个后端均可用（disabledReason 全部为 null）', () {
      expect(SyncBackend.cloudflare.disabledReason, isNull);
      expect(SyncBackend.edgeone.disabledReason, isNull);
      expect(SyncBackend.netlify.disabledReason, isNull);
    });

    test('每个后端可独立覆盖地址（trim；空串=清除覆盖回落默认）', () async {
      await config.setUrl(
        SyncBackend.edgeone,
        '  https://eo.example.com/  ',
      );
      expect(
        config.urlOf(SyncBackend.edgeone),
        'https://eo.example.com/',
      );
      expect(
        config.urlOverrideOf(SyncBackend.edgeone),
        'https://eo.example.com/',
      );
      // 互不影响：其他后端仍是各自默认（Netlify 已部署）。
      expect(
        config.urlOf(SyncBackend.cloudflare),
        SyncConfig.kSyncCfDefaultBaseUrl,
      );
      expect(
        config.urlOf(SyncBackend.netlify),
        SyncConfig.kSyncNetlifyDefaultBaseUrl,
      );

      // 空串 → 清除覆盖 → 回落内置默认（EdgeOne 内置为空串）。
      await config.setUrl(SyncBackend.edgeone, '   ');
      expect(config.urlOverrideOf(SyncBackend.edgeone), isNull);
      expect(config.urlOf(SyncBackend.edgeone), '');
    });

    test('EdgeOne 内置默认待回填（空串）；用户手填覆盖优先', () async {
      expect(config.urlOf(SyncBackend.edgeone), '');
      await config.setUrl(
        SyncBackend.edgeone,
        'https://my-override.pages.dev',
      );
      expect(
        config.urlOf(SyncBackend.edgeone),
        'https://my-override.pages.dev',
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

      await config.setSelectedBackend(SyncBackend.edgeone);
      expect(config.selectedBackend, SyncBackend.edgeone);
      expect(prefs.getString('aimindtree.sync.backend'), 'edgeone');

      // 新实例（模拟重启 App）读回同一选择。
      final reloaded = SyncConfig(prefs: prefs, secretStore: store);
      expect(reloaded.selectedBackend, SyncBackend.edgeone);

      // 脏值回落 cloudflare。
      await prefs.setString('aimindtree.sync.backend', 'no-such-backend');
      expect(config.selectedBackend, SyncBackend.cloudflare);
    });

    test('后端账号互相独立（A 登录不影响 B/C）', () async {
      await config.setUsername(SyncBackend.cloudflare, 'alice');
      await config.setUserToken(SyncBackend.cloudflare, 'cf-token');

      expect(await config.isLoggedIn(SyncBackend.cloudflare), isTrue);
      expect(config.usernameOf(SyncBackend.edgeone), isNull);
      expect(await config.resolveUserToken(SyncBackend.edgeone), isNull);
      expect(await config.isLoggedIn(SyncBackend.edgeone), isFalse);
      expect(await config.isLoggedIn(SyncBackend.netlify), isFalse);

      // key 也按后缀隔离（cf / eo / nf）。
      expect(prefs.getString('aimindtree.sync.cf_username'), 'alice');
      expect(prefs.getString('aimindtree.sync.eo_username'), isNull);
      expect(prefs.getString('aimindtree.sync.nf_username'), isNull);
      expect(await store.get('aimindtree.sync.eo_user_token'), isNull);
    });

    test('setUsername(null)/空串 清除；setUserToken(null) 登出', () async {
      await config.setUsername(SyncBackend.edgeone, 'bob');
      await config.setUserToken(SyncBackend.edgeone, 'eo-token');
      expect(await config.isLoggedIn(SyncBackend.edgeone), isTrue);

      await config.setUsername(SyncBackend.edgeone, '  ');
      expect(config.usernameOf(SyncBackend.edgeone), isNull);

      await config.setUsername(SyncBackend.edgeone, 'bob');
      await config.setUserToken(SyncBackend.edgeone, null);
      expect(await config.isLoggedIn(SyncBackend.edgeone), isFalse);
      expect(await config.resolveUserToken(SyncBackend.edgeone), isNull);
    });

    test('clear() 清所有后端（含选中项与代理）', () async {
      await config.setUrl(
        SyncBackend.cloudflare,
        'https://cf.example.com',
      );
      await config.setUrl(
        SyncBackend.edgeone,
        'https://eo.example.com',
      );
      await config.setUrl(
        SyncBackend.netlify,
        'https://nf.example.com',
      );
      await config.setUsername(SyncBackend.cloudflare, 'alice');
      await config.setUsername(SyncBackend.edgeone, 'bob');
      await config.setUsername(SyncBackend.netlify, 'carol');
      await config.setUserToken(SyncBackend.cloudflare, 't1');
      await config.setUserToken(SyncBackend.edgeone, 't2');
      await config.setUserToken(SyncBackend.netlify, 't3');
      await config.setSelectedBackend(SyncBackend.netlify);
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
      // 地址清空后回落到内置默认（Cloudflare / Netlify 均有默认；EdgeOne 为空串）。
      expect(
        config.urlOf(SyncBackend.cloudflare),
        SyncConfig.kSyncCfDefaultBaseUrl,
      );
      expect(
        config.urlOf(SyncBackend.netlify),
        SyncConfig.kSyncNetlifyDefaultBaseUrl,
      );
      expect(config.urlOf(SyncBackend.edgeone), '');
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

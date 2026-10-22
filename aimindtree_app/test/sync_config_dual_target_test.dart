/// SyncConfig 双目标（llm_server / Cloudflare）getter 单元测试（任务 B）。
///
/// 覆盖：默认 llmUrl 指向本机、isLlmConfigured 永远可用、cf 配置存取、
/// isCfConfigured 判定、resolveCfToken 优先级（token_ref > 直存）、clear 复位。
library;

import 'package:aimindtree_app/core/secret_store.dart';
import 'package:aimindtree_app/data/sync/sync_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SyncConfig 双目标', () {
    late SharedPreferences prefs;
    late InMemorySecretStore store;
    late SyncConfig config;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      prefs = await SharedPreferences.getInstance();
      store = InMemorySecretStore();
      config = SyncConfig(prefs: prefs, secretStore: store);
    });

    test('llmUrl 默认指向本机 llm_server（127.0.0.1:8787）', () {
      expect(config.llmUrl, SyncConfig.kSyncLlmServerDefaultBaseUrl);
    });

    test('isLlmConfigured 默认 true（默认指向 localhost）', () {
      expect(config.isLlmConfigured, isTrue);
    });

    test('baseUrl 有值时 llmUrl 返回 baseUrl', () async {
      await config.setBaseUrl('https://example.com/sync');
      expect(config.llmUrl, 'https://example.com/sync');
    });

    test('isConfigured（旧单目标）需 baseUrl + tokenRef 都非空', () async {
      expect(config.isConfigured, isFalse);
      await config.setBaseUrl('https://x.com');
      expect(config.isConfigured, isFalse);
      await config.setTokenRef('ref-a');
      expect(config.isConfigured, isTrue);
    });

    test('cfUrl / cfToken 存取', () async {
      expect(config.cfUrl, isNull);
      expect(config.cfToken, isNull);
      await config.setCfUrl('https://cf.workers.dev');
      await config.setCfToken('cf-token-123');
      expect(config.cfUrl, 'https://cf.workers.dev');
      expect(config.cfToken, 'cf-token-123');
    });

    test('isCfConfigured 需 cfUrl + (cfTokenRef | cfToken)', () async {
      expect(config.isCfConfigured, isFalse);
      await config.setCfUrl('https://cf.workers.dev');
      expect(config.isCfConfigured, isFalse);
      // 仅直存 token
      await config.setCfToken('cf-token-123');
      expect(config.isCfConfigured, isTrue);
      // 清掉直存 token，改用 token_ref
      await config.setCfToken(null);
      expect(config.isCfConfigured, isFalse);
      await config.setCfTokenRef('cf-ref');
      expect(config.isCfConfigured, isTrue);
    });

    test('resolveCfToken 优先 token_ref（SecretStore），回退直存 token', () async {
      // 仅直存 token
      await config.setCfToken('direct-token');
      expect(await config.resolveCfToken(), 'direct-token');

      // 同时设 token_ref（指向 SecretStore 中的值）→ 优先返回 store 值
      await store.set('cf-ref', 'store-token');
      await config.setCfTokenRef('cf-ref');
      expect(await config.resolveCfToken(), 'store-token');

      // store 值空时回退直存 token
      await store.set('cf-ref', '');
      expect(await config.resolveCfToken(), 'direct-token');

      // 两者皆无 → 空串（开放部署：Worker 未设 SYNC_TOKEN 时直接放行，
      // 普通用户因此无需填写 token 也能与官方/个人开放中继互通）
      await config.setCfTokenRef(null);
      await config.setCfToken(null);
      expect(await config.resolveCfToken(), '');
    });

    test('clear 复位全部字段（含 cf）', () async {
      await config.setBaseUrl('https://x.com');
      await config.setTokenRef('ref-a');
      await config.setCfUrl('https://cf.dev');
      await config.setCfToken('t');
      await config.setCfTokenRef('ref-cf');
      await config.clear();

      expect(config.baseUrl, isNull);
      expect(config.tokenRef, isNull);
      expect(config.cfUrl, isNull);
      expect(config.cfToken, isNull);
      expect(config.cfTokenRef, isNull);
    });
  });
}

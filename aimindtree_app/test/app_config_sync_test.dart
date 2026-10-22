/// 任务 B / 任务 I 测试：
///
/// B. `AppConfigService` 消费管理后台下发的同步配置（`GET /v1/app/config`
///    的 `sync` 段）：
///    ① 带 sync{base_url, enabled:true, token:'tok'} → SyncConfig.base_url
///       写入、enabled pref=true、SecretStore 有 token；
///    ② 无 sync 段（旧服务）→ 本地值分毫不动（优雅降级）；
///    ③ token 为 null 但 token_set=true → 不动本地 token。
///
/// I. `formatProbeError` 超时文案人话化（纯函数）。
///
/// 需要 sqlite3 native assets（内存库）+ 本机 HttpServer mock
/// `/v1/app/config`；沙箱里 native 不可用时 group 整体 skip（与
/// settings_repository_test 同口径）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:aimindtree_app/ai/app_config_service.dart';
import 'package:aimindtree_app/core/secret_store.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/repositories/settings_repository.dart';
import 'package:aimindtree_app/data/sync/sync_config.dart';
import 'package:aimindtree_app/features/settings/ai_service_status_section.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 探测 sqlite3 native 是否可用（沙箱/CI 返回 false 让 group 整体 skip）。
bool _probeSqlite() {
  try {
    NativeDatabase.memory();
    return true;
  } on Object {
    return false;
  }
}

void main() {
  final canRun = _probeSqlite();

  group(
    'AppConfigService 消费下发的 sync 段（任务 B）',
    skip: !canRun,
    () {
      late AppDatabase db;
      late SettingsRepository repo;
      late InMemorySecretStore store;
      late SharedPreferences prefs;
      late SyncConfig syncConfig;
      HttpServer? server;

      setUp(() async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        prefs = await SharedPreferences.getInstance();
        db = AppDatabase(NativeDatabase.memory());
        store = InMemorySecretStore();
        repo = SettingsRepository(db, secretStore: store);
        syncConfig = SyncConfig(prefs: prefs, secretStore: store);
      });

      tearDown(() async {
        await server?.close(force: true);
        server = null;
        await db.close();
        // 静态单例复位，避免污染其它测试文件。
        AppConfigService.last = null;
        AppConfigService.lastSource = AppConfigSource.unreachable;
      });

      /// 起一个 mock `GET /v1/app/config`，返回给定 payload。
      Future<String> _startConfig(Map<String, Object?> payload) async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server!.listen((req) async {
          if (req.uri.path == '/v1/app/config') {
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(payload));
          } else {
            req.response.statusCode = 404;
          }
          await req.response.close();
        });
        return 'http://127.0.0.1:${server!.port}';
      }

      /// 构造一份合法下发 payload；[sync] 为 null = 旧服务（无 sync 段）。
      Map<String, Object?> _payload(Map<String, Object?>? sync) {
        return <String, Object?>{
          'schema': 1,
          'server_version': '0.1.0',
          'service_name': 'AIMindTree AI 服务',
          'protocol': 'llm_server',
          'base_url': 'http://127.0.0.1:8787',
          'backend': 'ollama',
          'model': '',
          'console_url': 'http://127.0.0.1:8787/admin',
          'timeouts': <String, Object?>{
            'structured_s': 120,
            'chat_s': 120,
            'connect_s': 10,
          },
          'task_backends': <String, Object?>{},
          if (sync != null) 'sync': sync,
          'config_sha1': 'sha1-sync-test-001',
          'updated_at': '2026-10-21T16:00:00+08:00',
        };
      }

      test('① 带 sync{base_url,enabled:true,token} → 写 SyncConfig/prefs/SecretStore',
          () async {
        final base = await _startConfig(_payload(<String, Object?>{
          'base_url': 'https://sync.example.com/functions/v1/ai-proxy',
          'enabled': true,
          'token': 'tok',
          'token_set': true,
        }));

        await AppConfigService.fetch(candidates: <String>[base]);
        expect(AppConfigService.lastSource, AppConfigSource.pushed);
        await AppConfigService.apply(
          repo,
          prefs,
          syncConfig: syncConfig,
          secretStore: store,
        );

        // base_url 写入 prefs（SyncConfig.base_url）。
        expect(
          syncConfig.baseUrl,
          'https://sync.example.com/functions/v1/ai-proxy',
        );
        // enabled 作为默认写 aimindtree.sync.enabled。
        expect(prefs.getBool('aimindtree.sync.enabled'), isTrue);
        expect(syncConfig.enabled, isTrue);
        // token 存入 SecretStore 并设 token_ref（sync_<ulid> 机制）。
        final ref = syncConfig.tokenRef;
        expect(ref, isNotNull);
        expect(ref, startsWith('sync_'));
        expect(await store.get(ref!), 'tok');
      });

      test('② 无 sync 段（旧服务）→ 本地值不动', () async {
        // 预置本地值。
        await syncConfig.setBaseUrl('http://local-sync:9999');
        await syncConfig.setEnabled(false);
        await store.set('sync_local', 'local-tok');
        await syncConfig.setTokenRef('sync_local');

        final base = await _startConfig(_payload(null));
        await AppConfigService.fetch(candidates: <String>[base]);
        expect(AppConfigService.lastSource, AppConfigSource.pushed);
        await AppConfigService.apply(
          repo,
          prefs,
          syncConfig: syncConfig,
          secretStore: store,
        );

        expect(syncConfig.baseUrl, 'http://local-sync:9999');
        expect(prefs.getBool('aimindtree.sync.enabled'), isFalse);
        expect(syncConfig.tokenRef, 'sync_local');
        expect(await store.get('sync_local'), 'local-tok');
      });

      test('③ token 为 null 但 token_set=true → 不动本地 token；base_url 空不覆盖',
          () async {
        await syncConfig.setBaseUrl('http://local-sync:9999');
        await store.set('sync_local', 'local-tok');
        await syncConfig.setTokenRef('sync_local');

        final base = await _startConfig(_payload(<String, Object?>{
          'base_url': '',
          'enabled': false,
          'token': null,
          'token_set': true,
        }));
        await AppConfigService.fetch(candidates: <String>[base]);
        await AppConfigService.apply(
          repo,
          prefs,
          syncConfig: syncConfig,
          secretStore: store,
        );

        // base_url 下发为空 → 保留本地值。
        expect(syncConfig.baseUrl, 'http://local-sync:9999');
        // token_set=true 但无明文 → 本地 token 原样保留。
        expect(syncConfig.tokenRef, 'sync_local');
        expect(await store.get('sync_local'), 'local-tok');
      });
    },
  );

  group('formatProbeError 超时文案人话化（任务 I）', () {
    test('TimeoutException → 「N 秒内无响应」', () {
      expect(
        formatProbeError(
            'TimeoutException after 0:00:05.000000: Future not completed'),
        '5 秒内无响应：服务可能未启动或在加载模型',
      );
      expect(
        formatProbeError(
            'TimeoutException after 0:00:03.000000: Future not completed'),
        contains('3 秒内无响应'),
      );
      expect(
        formatProbeError(
            'TimeoutException after 1:02:03.500000: Future not completed'),
        contains('3724 秒内无响应'),
      );
    });

    test('HTTP 码 / 后端不可达文案原样返回', () {
      expect(formatProbeError('HTTP 502'), 'HTTP 502');
      expect(
        formatProbeError('服务已启动，但默认后端「ollama」不可达（请在管理后台检查）。'),
        contains('默认后端'),
      );
      expect(formatProbeError(null), '未知错误');
      expect(formatProbeError(''), '未知错误');
    });
  });
}

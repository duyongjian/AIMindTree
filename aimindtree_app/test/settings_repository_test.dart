/// SettingsRepository 集成测试（T07）。
///
/// 需要 sqlite3 native assets；沙箱里 path_provider / sqlite3.dll 不可用，
/// 跑前会抛 MissingPluginException 或 502，故加 `skip` 在真机启用。
library;

import 'package:aimindtree_app/ai/extraction_service.dart';
import 'package:aimindtree_app/core/secret_store.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/repositories/settings_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 真机启用；沙箱/CI 默认跳过（sqlite3 native assets 缺失）。
  final canRun = _probeSqlite();
  final shouldSkip = !canRun;

  group('SettingsRepository（seed + add + resolve + delete）', skip: shouldSkip, () {
    late AppDatabase db;
    late SettingsRepository repo;
    late InMemorySecretStore store;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      store = InMemorySecretStore();
      repo = SettingsRepository(db, secretStore: store);
    });

    tearDown(() async {
      await db.close();
    });

    test('首次启动 seedFromLocalIfEmpty 写入默认 Dify provider', () async {
      await repo.seedFromLocalIfEmpty(const LocalAiConfig(
        baseUrl: 'http://localhost:8080',
        appApiKey: 'app-seed-key',
      ));
      final all = await repo.allProviders();
      expect(all.length, 1);
      expect(all.first.protocol, 'dify');
      expect(all.first.baseUrl, 'http://localhost:8080');
      expect(all.first.enabled, isTrue);
      // 密钥确实落到了 SecretStore
      final key = await store.get(all.first.apiKeyRef);
      expect(key, 'app-seed-key');
    });

    test('再次 seedFromLocalIfEmpty 不会重复写入', () async {
      await repo.seedFromLocalIfEmpty(const LocalAiConfig(
        baseUrl: 'http://localhost:8080',
        appApiKey: 'app-seed-key',
      ));
      await repo.seedFromLocalIfEmpty(const LocalAiConfig(
        baseUrl: 'http://other:9000',
        appApiKey: 'app-other-key',
      ));
      final all = await repo.allProviders();
      expect(all.length, 1, reason: '已存在 Dify provider 时不再 seed');
      expect(all.first.baseUrl, 'http://localhost:8080');
    });

    test('addDifyProvider 写密钥 + 入表', () async {
      final row = await repo.addDifyProvider(
        displayName: '云端 Dify',
        baseUrl: 'https://dify.example.com',
        apiKey: 'app-xyz',
      );
      expect(row.name, '云端 Dify');
      expect(row.baseUrl, 'https://dify.example.com');
      expect(row.enabled, isTrue);

      final back = await store.get(row.apiKeyRef);
      expect(back, 'app-xyz');
    });

    test('resolveApiKey 返回原密钥', () async {
      final row = await repo.addDifyProvider(
        displayName: 'P',
        baseUrl: 'http://h',
        apiKey: 'k1',
      );
      expect(await repo.resolveApiKey(row.apiKeyRef), 'k1');
    });

    test('setEnabled 切换 enabled', () async {
      final row = await repo.addDifyProvider(
        displayName: 'P',
        baseUrl: 'http://h',
        apiKey: 'k',
      );
      await repo.setEnabled(row.id, false);
      final after = (await repo.allProviders()).first;
      expect(after.enabled, isFalse);
      await repo.setEnabled(row.id, true);
      final restored = (await repo.allProviders()).first;
      expect(restored.enabled, isTrue);
    });

    test('deleteProvider 同步清理 SecretStore', () async {
      final row = await repo.addDifyProvider(
        displayName: 'P',
        baseUrl: 'http://h',
        apiKey: 'k',
      );
      expect(await store.get(row.apiKeyRef), 'k');
      await repo.deleteProvider(row.id);
      expect(await store.get(row.apiKeyRef), isNull);
      expect(await repo.allProviders(), isEmpty);
    });

    test('enabledProviders 只返回 enabled=true 的行', () async {
      final a = await repo.addDifyProvider(
        displayName: 'A', baseUrl: 'http://a', apiKey: 'ka',
      );
      await repo.addDifyProvider(
        displayName: 'B', baseUrl: 'http://b', apiKey: 'kb',
      );
      await repo.setEnabled(a.id, false);
      final enabled = await repo.enabledProviders();
      expect(enabled.length, 1);
      expect(enabled.first.name, 'B');
    });
  });
}

/// 探测 sqlite3 native 是否可用。沙箱/CI 返回 false 让 group 整体 skip。
bool _probeSqlite() {
  try {
    // NativeDatabase.memory() 会触发 sqlite3 native load；
    // 包在 try 里只检查构造是否抛错（不实际打开）。
    NativeDatabase.memory();
    return true;
  } on Object {
    return false;
  }
}
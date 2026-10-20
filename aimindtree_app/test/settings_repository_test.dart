/// SettingsRepository 集成测试（T07）。
///
/// 需要 sqlite3 native assets；沙箱里 path_provider / sqlite3.dll 不可用，
/// 跑前会抛 MissingPluginException 或 502，故加 `skip` 在真机启用。
library;

import 'package:aimindtree_app/ai/ai_task.dart';
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

  group(
    'SettingsRepository（seed + add + resolve + delete）',
    skip: shouldSkip,
    () {
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

      test('首次启动 seedFromLocalIfEmpty 写入默认 LLM 服务 provider', () async {
        await repo.seedFromLocalIfEmpty(
          const LocalAiConfig(baseUrl: 'http://127.0.0.1:8787'),
        );
        final all = await repo.allProviders();
        expect(all.length, 1);
        expect(all.first.protocol, 'llm_server');
        expect(all.first.baseUrl, 'http://127.0.0.1:8787');
        expect(all.first.enabled, isTrue);
        // 密钥边界（C4）：llm_server 不落任何密钥，api_key_ref 恒空串。
        expect(all.first.apiKeyRef, '');
        expect(await store.get(all.first.apiKeyRef), isNull);
      });

      test('再次 seedFromLocalIfEmpty 不会重复写入', () async {
        await repo.seedFromLocalIfEmpty(
          const LocalAiConfig(baseUrl: 'http://127.0.0.1:8787'),
        );
        await repo.seedFromLocalIfEmpty(
          const LocalAiConfig(baseUrl: 'http://other:9000'),
        );
        final all = await repo.allProviders();
        expect(all.length, 1, reason: '已存在 LLM 服务 provider 时不再 seed');
        expect(all.first.baseUrl, 'http://127.0.0.1:8787');
      });

      test('addLlmServerProvider 入表且不写 SecretStore', () async {
        final row = await repo.addLlmServerProvider(
          displayName: '本地 Ollama',
          baseUrl: 'http://127.0.0.1:8787',
          backend: 'ollama',
          model: 'qwen2.5:7b',
          setDefault: true,
        );
        expect(row.name, '本地 Ollama');
        expect(row.protocol, 'llm_server');
        expect(row.type, 'ollama', reason: 'backend 复用 type 列');
        expect(row.models, '["qwen2.5:7b"]', reason: 'model 复用 models 列');
        expect(row.apiKeyRef, '');
        expect(row.isDefault, isTrue);
        expect(row.enabled, isTrue);
        expect(await store.get(row.apiKeyRef), isNull);
      });

      test('updateLlmServerProvider 改 backend / model', () async {
        final row = await repo.addLlmServerProvider(
          displayName: 'P',
          baseUrl: 'http://127.0.0.1:8787',
        );
        expect(row.models, '[]', reason: '未指定 model → 用后端默认');
        final updated = await repo.updateLlmServerProvider(
          row.id,
          backend: 'minimax',
          model: 'MiniMax-Text-01',
        );
        expect(updated, isNotNull);
        expect(updated!.type, 'minimax');
        expect(updated.models, '["MiniMax-Text-01"]');
        expect(updated.baseUrl, 'http://127.0.0.1:8787',
            reason: '没传 baseUrl 就不该动它');
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

      test('bindTask 写入路由，重复绑定 = 覆盖', () async {
        final t3 = await repo.addDifyProvider(
          displayName: 'T3 工作流',
          baseUrl: 'http://h',
          apiKey: 'k3',
        );
        final t4 = await repo.addDifyProvider(
          displayName: 'T4 工作流',
          baseUrl: 'http://h',
          apiKey: 'k4',
        );

        await repo.bindTask(AiTask.t3Prerequisite, t3.id);
        var routes = await repo.allRoutes();
        expect(routes.length, 1);
        expect(routes.single.aiTask, 'T3');
        expect(routes.single.providerId, t3.id);

        // 同任务再绑一次：仍是 1 行，且指向新 provider
        await repo.bindTask(AiTask.t3Prerequisite, t4.id);
        routes = await repo.allRoutes();
        expect(routes.length, 1, reason: 'bind 是先删后插，不能出现重复行');
        expect(routes.single.providerId, t4.id);
      });

      test('unbindTask 只清指定任务', () async {
        final p = await repo.addDifyProvider(
          displayName: 'P',
          baseUrl: 'http://h',
          apiKey: 'k',
        );
        await repo.bindTask(AiTask.t3Prerequisite, p.id);
        await repo.bindTask(AiTask.t4GapAnalysis, p.id);
        expect((await repo.allRoutes()).length, 2);

        await repo.unbindTask(AiTask.t3Prerequisite);
        final routes = await repo.allRoutes();
        expect(routes.length, 1);
        expect(routes.single.aiTask, 'T4');
      });

      test('deleteProvider 连带解绑路由，返回解绑数量', () async {
        final p = await repo.addDifyProvider(
          displayName: 'P',
          baseUrl: 'http://h',
          apiKey: 'k',
        );
        final other = await repo.addDifyProvider(
          displayName: 'O',
          baseUrl: 'http://h',
          apiKey: 'ko',
        );
        await repo.bindTask(AiTask.t3Prerequisite, p.id);
        await repo.bindTask(AiTask.t4GapAnalysis, p.id);
        await repo.bindTask(AiTask.t1Extract, other.id);

        final unbound = await repo.deleteProvider(p.id);
        expect(unbound, 2, reason: 'T3/T4 指向 p，应一起解绑');

        final routes = await repo.allRoutes();
        expect(routes.length, 1, reason: '指向 other 的 T1 路由不受影响');
        expect(routes.single.aiTask, 'T1');
        expect(routes.single.providerId, other.id);
      });

      test('updateProvider 只改显示名，不动 baseUrl 和密钥', () async {
        final row = await repo.addDifyProvider(
          displayName: '我的 Dify',
          baseUrl: 'http://a',
          apiKey: 'k-origin',
        );
        final updated = await repo.updateProvider(row.id, name: 'Dify T4 缺口分析');
        expect(updated, isNotNull);
        expect(updated!.name, 'Dify T4 缺口分析');
        expect(updated.baseUrl, 'http://a', reason: '没传 baseUrl 就不该动它');
        expect(await store.get(row.apiKeyRef), 'k-origin');
      });

      test('updateProvider 改 Base URL', () async {
        final row = await repo.addDifyProvider(
          displayName: 'P',
          baseUrl: 'http://old',
          apiKey: 'k',
        );
        final updated = await repo.updateProvider(
          row.id,
          baseUrl: 'http://new',
        );
        expect(updated!.baseUrl, 'http://new');
        expect(updated.name, 'P', reason: '没传 name 就不该动它');
      });

      test('updateProvider 传了 apiKey 才覆盖 SecretStore', () async {
        final row = await repo.addDifyProvider(
          displayName: 'P',
          baseUrl: 'http://a',
          apiKey: 'k-old',
        );
        // 留空 → 不动
        await repo.updateProvider(row.id, name: 'Q');
        expect(await store.get(row.apiKeyRef), 'k-old');
        // 非空 → 覆盖（引用名不变）
        await repo.updateProvider(row.id, apiKey: 'k-new');
        expect(await store.get(row.apiKeyRef), 'k-new');
        expect((await repo.allProviders()).first.apiKeyRef, row.apiKeyRef);
      });

      test('updateProvider 对不存在的 id 返回 null', () async {
        expect(await repo.updateProvider('no-such-id', name: 'x'), isNull);
      });

      test('enabledProviders 只返回 enabled=true 的行', () async {
        final a = await repo.addDifyProvider(
          displayName: 'A',
          baseUrl: 'http://a',
          apiKey: 'ka',
        );
        await repo.addDifyProvider(
          displayName: 'B',
          baseUrl: 'http://b',
          apiKey: 'kb',
        );
        await repo.setEnabled(a.id, false);
        final enabled = await repo.enabledProviders();
        expect(enabled.length, 1);
        expect(enabled.first.name, 'B');
      });
    },
  );
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

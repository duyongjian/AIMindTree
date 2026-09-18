/// AI Provider 配置仓储（T07：让 Dify Key 不再硬编码）。
///
/// - Provider 记录在 `ai_providers` 表；密钥在 [SecretStore] 里。
/// - `api_key_ref` 是**引用名**（如 `dify_<ulid>`），不是密钥本身。
/// - P0 启动会从 [LocalAiConfig] seed 一个 Dify provider，开箱即用。
library;

import 'dart:io';

import 'package:drift/drift.dart';

import '../../ai/extraction_service.dart';
import '../../core/id.dart';
import '../../core/logger.dart';
import '../../core/secret_store.dart';
import '../db/drift_database.dart';

class SettingsRepository {
  SettingsRepository(this._db, {required this.secretStore});
  final AppDatabase _db;
  final SecretStore secretStore;
  static final AppLog _log = AppLog('settings_repo');

  // ============ 查询 ============

  Future<List<AiProviderRow>> allProviders() =>
      _db.select(_db.aiProviders).get();

  Future<List<AiProviderRow>> enabledProviders() =>
      (_db.select(_db.aiProviders)..where((t) => t.enabled.equals(true))).get();

  Future<AiProviderRow?> firstEnabled() async {
    final rows = await enabledProviders();
    return rows.isEmpty ? null : rows.first;
  }

  // ============ Dify Provider CRUD ============

  /// 新增一个 Dify provider：密钥写入 SecretStore，引用名入表。
  Future<AiProviderRow> addDifyProvider({
    required String displayName,
    required String baseUrl,
    required String apiKey,
  }) async {
    final id = newUlid();
    final refName = 'dify_$id';
    await secretStore.set(refName, apiKey);
    await _db.into(_db.aiProviders).insert(AiProvidersCompanion(
          id: Value(id),
          name: Value(displayName),
          type: Value('dify'),
          protocol: Value('dify'),
          baseUrl: Value(baseUrl),
          apiKeyRef: Value(refName),
          models: const Value('[]'),
          isDefault: const Value(false),
          enabled: const Value(true),
        ));
    return AiProviderRow(
      id: id,
      name: displayName,
      type: 'dify',
      protocol: 'dify',
      baseUrl: baseUrl,
      apiKeyRef: refName,
      models: '[]',
      isDefault: false,
      enabled: true,
      // 无相关字段，留 null
    );
  }

  /// 启用/停用。
  Future<void> setEnabled(String id, bool enabled) async {
    await (_db.update(_db.aiProviders)..where((t) => t.id.equals(id)))
        .write(AiProvidersCompanion(enabled: Value(enabled)));
  }

  /// 删除：连带清理 SecretStore。
  Future<void> deleteProvider(String id) async {
    final row = await (_db.select(_db.aiProviders)
          ..where((t) => t.id.equals(id))
          ..limit(1))
        .getSingleOrNull();
    if (row != null) await secretStore.delete(row.apiKeyRef);
    await (_db.delete(_db.aiProviders)..where((t) => t.id.equals(id))).go();
  }

  /// 取密钥（仅内部/Provider 构造用）。
  Future<String?> resolveApiKey(String apiKeyRef) =>
      secretStore.get(apiKeyRef);

  // ============ Seed ============

  /// 首次启动：若没有 Dify provider，从 [LocalAiConfig] seed 一个。
  Future<void> seedFromLocalIfEmpty(LocalAiConfig cfg) async {
    final existing = await allProviders();
    final hasDify = existing.any((p) => p.protocol == 'dify');
    if (hasDify) return;
    _log.i('首次启动：seed Dify provider from LocalAiConfig');
    await addDifyProvider(
      displayName: '本地 Dify（默认）',
      baseUrl: cfg.baseUrl,
      apiKey: cfg.appApiKey,
    );
  }

  // ============ 连接测试 ============

  /// 用 (baseUrl, apiKey) 试连 Dify 的 setup 接口（无需 auth），返回 null = OK。
  Future<String?> testDify(String baseUrl, String apiKey,
      {Duration timeout = const Duration(seconds: 8)}) async {
    try {
      final client = HttpClient()..connectionTimeout = timeout;
      final url = Uri.parse('$baseUrl/console/api/setup');
      final req = await client.getUrl(url);
      final resp = await req.close().timeout(timeout);
      await resp.drain<void>();
      client.close(force: true);
      if (resp.statusCode == 200) return null;
      return 'HTTP ${resp.statusCode}';
    } on Object catch (e) {
      return e.toString();
    }
  }
}

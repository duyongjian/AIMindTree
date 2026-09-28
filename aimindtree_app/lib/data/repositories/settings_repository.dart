/// AI Provider 配置仓储（T07：让 Dify Key 不再硬编码）。
///
/// - Provider 记录在 `ai_providers` 表；密钥在 [SecretStore] 里。
/// - `api_key_ref` 是**引用名**（如 `dify_<ulid>`），不是密钥本身。
/// - P0 启动会从 [LocalAiConfig] seed 一个 Dify provider，开箱即用。
library;

import 'dart:io';

import 'package:drift/drift.dart';

import '../../ai/ai_task.dart';
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
    await _db
        .into(_db.aiProviders)
        .insert(
          AiProvidersCompanion(
            id: Value(id),
            name: Value(displayName),
            type: Value('dify'),
            protocol: Value('dify'),
            baseUrl: Value(baseUrl),
            apiKeyRef: Value(refName),
            models: const Value('[]'),
            isDefault: const Value(false),
            enabled: const Value(true),
          ),
        );
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
    await (_db.update(_db.aiProviders)..where((t) => t.id.equals(id))).write(
      AiProvidersCompanion(enabled: Value(enabled)),
    );
  }

  /// 删除：连带清理 SecretStore + 指向它的任务路由。
  ///
  /// 返回被解除绑定的任务数（用于 UI 提示）。
  Future<int> deleteProvider(String id) async {
    final row =
        await (_db.select(_db.aiProviders)
              ..where((t) => t.id.equals(id))
              ..limit(1))
            .getSingleOrNull();
    if (row != null) await secretStore.delete(row.apiKeyRef);
    final unbound = await _db.aiTaskRouteDao.unbindProvider(id);
    await (_db.delete(_db.aiProviders)..where((t) => t.id.equals(id))).go();
    return unbound;
  }

  // ============ 任务级路由绑定 ============

  /// 全部路由行（`ai_task` code → provider）。
  Future<List<AiTaskRouteRow>> allRoutes() => _db.aiTaskRouteDao.all();

  /// 绑定任务 → provider（同任务重复绑定 = 覆盖）。
  ///
  /// Dify 的 Key 按「应用」签发，一个工作流 = 一个 Key = 一个 Provider，
  /// 所以 T3 / T4 必须各自绑到自己的 Provider 上；不绑就走本地兜底（AI 不跑）。
  Future<void> bindTask(AiTask task, String providerId) =>
      _db.aiTaskRouteDao.bind(task: task, providerId: providerId);

  /// 解绑：通用任务回落默认 Provider；T3/T4 走本地兜底。
  Future<void> unbindTask(AiTask task) => _db.aiTaskRouteDao.unbind(task);

  /// 取密钥（仅内部/Provider 构造用）。
  Future<String?> resolveApiKey(String apiKeyRef) => secretStore.get(apiKeyRef);

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
  Future<String?> testDify(
    String baseUrl,
    String apiKey, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
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

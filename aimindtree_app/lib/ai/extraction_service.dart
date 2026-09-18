/// T1 知识点提取服务（T04 合并双轨后的正式版）。
///
/// 链路：用户笔记 → [AiService] (T1) → 路由到 Dify 工作流 → 结构化解析
/// → [KnowledgeRepository.saveExtracted]（锚点校验，幻觉剔除）→ 落库。
///
/// 旧原型（FileKnowledgeStore + 直连 DifyClient）已被本版取代并删除。
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../core/logger.dart';
import '../core/result.dart';
import '../core/secret_store.dart';
import '../data/db/drift_database.dart';
import '../data/models/knowledge_point.dart';
import '../data/repositories/knowledge_repository.dart';
import '../data/repositories/tree_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/sync/sync_api.dart';
import '../data/sync/sync_config.dart';
import '../data/sync/sync_context.dart';
import '../data/sync/sync_engine.dart';
import '../data/sync/sync_outbox.dart';
import '../data/sync/sync_scheduler.dart';
import '../data/sync/sync_status.dart';
import 'ai_provider.dart';
import 'ai_service.dart';
import 'ai_task.dart';
import 'ai_task_router.dart';
import 'clients/dify_client.dart';

/// 本地 Dify 开发配置（P0 引导用）。
///
/// ⚠️ 仅本地开发期：正式应从 `ai_providers` 表读取（设置页配置，S4 不同步）。
/// 已验证可用的 T1 应用 Key 直接内置，开箱即跑。
class LocalAiConfig {
  const LocalAiConfig({
    this.baseUrl = 'http://localhost:8080',
    this.appApiKey = 'app-fhXwVvHFfVbVWRq3tRMOX8fd',
  });

  final String baseUrl;
  final String appApiKey;
}

class ExtractionService {
  ExtractionService({
    required this.repo,
    required this.ai,
    required this.trees,
  });

  final KnowledgeRepository repo;
  final TreeRepository trees;
  final AiService ai;

  static final AppLog _log = AppLog('extraction');

  /// 对一段笔记原文执行完整 T1 流程，返回入库结果（含被剔除的幻觉点）。
  Future<Result<ExtractionSaveResult>> extract(
    String noteContent, {
    String? notebookId,
  }) async {
    final content = noteContent.trim();
    if (content.isEmpty) {
      return Failure(ArgumentError('笔记内容为空'));
    }

    // 1) 存笔记
    final note = Note(
      contentMd: content,
      title: _deriveTitle(content),
      deviceId: repo.deviceId,
    );
    final savedNote = await repo.saveNote(note);
    if (savedNote is Failure<Note>) {
      return Failure(savedNote.error, savedNote.stackTrace);
    }
    final noteId = (savedNote as Success<Note>).value.id;

    // 2) 调 T1（AiService → 路由 → Dify 工作流）
    final aiRes = await ai.run(AiTask.t1Extract, {'note_text': content});
    if (aiRes is Failure<AiTaskResult>) {
      return Failure(aiRes.error, aiRes.stackTrace);
    }
    final result = (aiRes as Success<AiTaskResult>).value;

    // 3) 映射为待校验的原始知识点
    final rawPoints = _mapToRaw(result.parsed);
    if (rawPoints == null) {
      return Failure(StateError(
          'T1 返回结构无法解析为知识点列表：${_preview(result.content)}'));
    }
    if (rawPoints.isEmpty) {
      _log.w('T1 提取结果为空');
    }

    // 4) 锚点校验 + 落库
    return repo.saveExtracted(
      noteId: noteId,
      noteContent: content,
      rawPoints: rawPoints,
      notebookId: notebookId,
    );
  }

  /// 把 AiTaskResult.parsed（`{knowledge_points: [...]}` 或裸数组）映射为原始点。
  List<RawKnowledgePoint>? _mapToRaw(Object? parsed) {
    List<dynamic> list;
    if (parsed is Map && parsed['knowledge_points'] is List) {
      list = parsed['knowledge_points'] as List<dynamic>;
    } else if (parsed is List) {
      list = parsed;
    } else {
      return null;
    }
    return list
        .map((e) {
          if (e is! Map) return null;
          final m = e;
          return RawKnowledgePoint(
            name: (m['name'] as String?) ?? '',
            type: (m['type'] as String?) ?? '',
            definition: (m['definition'] as String?) ?? '',
            sourceQuote: (m['source_quote'] as String?) ??
                (m['sourceQuote'] as String? ?? ''),
            prerequisites: (m['prerequisites'] as List<dynamic>?)
                    ?.map((p) => p as String)
                    .toList() ??
                const <String>[],
            confidence: (m['confidence'] as num?) ?? 0,
          );
        })
        .whereType<RawKnowledgePoint>()
        .toList();
  }

  String _deriveTitle(String content) {
    final firstLine = content.split('\n').first;
    return firstLine.length > 40
        ? '${firstLine.substring(0, 40)}…'
        : firstLine;
  }

  static String _preview(String s) =>
      s.length <= 120 ? s : '${s.substring(0, 120)}…';

  /// P0 开发引导：组装整套依赖。
  ///
  /// 流程：
  /// 1) 初始化 DB / SecretStore / SettingsRepository / SyncContext；
  /// 2) 首次启动则从 [LocalAiConfig] seed 一个 Dify provider（开箱即用）；
  /// 3) 读 `ai_providers` 表里所有启用的 provider → 实例化并注入 Router；
  /// 4) 装配 SyncContext（SyncApi / Outbox / Engine / Scheduler）；
  /// 5) 返回五元组 (service, db, router, settings, sync)。
  ///
  /// 注：P0 启动时一次性装载所有 provider；后续在设置页改动 provider
  /// 后需要重启 App 才生效（响应式监听留作 T09+ 增量）。
  static Future<(ExtractionService, AppDatabase, AiTaskRouter, SettingsRepository,
      SyncContext)> bootstrap({
    AppDatabase? db,
    SecretStore? secretStore,
    LocalAiConfig config = const LocalAiConfig(),
    String? deviceId,
  }) async {
    final database = db ?? AppDatabase();
    final store = secretStore ?? await FileSecretStore.defaultInstance();
    final did = deviceId ?? 'local-dev';

    // === Settings ===
    final settings = SettingsRepository(database, secretStore: store);
    await settings.seedFromLocalIfEmpty(config);

    // === AI Provider ===
    final enabledRows = await settings.enabledProviders();
    final Map<String, AiProvider> providers = <String, AiProvider>{};
    AiProvider? fallback;
    for (final row in enabledRows) {
      if (row.protocol == 'dify') {
        final apiKey = await settings.resolveApiKey(row.apiKeyRef);
        if (apiKey == null || apiKey.isEmpty) {
          _log.w('Provider ${row.id} (${row.name}) 密钥缺失，已跳过');
          continue;
        }
        final isLocal = row.baseUrl.contains('localhost') ||
            row.baseUrl.contains('127.0.0.1');
        final dify = DifyClient(
          id: row.id,
          baseUrl: row.baseUrl,
          appApiKey: apiKey,
          isLocal: isLocal,
        );
        providers[dify.id] = dify;
        fallback ??= dify;
      } else {
        _log.w('暂不支持的 provider 协议：${row.protocol}（id=${row.id}）');
      }
    }

    if (fallback == null) {
      throw StateError(
          '没有可用的 AI provider。请到「设置」页添加并启用一个 Dify 提供商。');
    }

    final router = AiTaskRouter(
      db: database,
      providers: providers,
      fallback: fallback,
    );
    final ai = AiService(router: router);
    final repo = KnowledgeRepository(database, deviceId: did);
    final trees = TreeRepository(database, deviceId: did);

    // === Sync（T03）===
    final outbox = SyncOutboxRepo(database, deviceId: did);
    final prefs = await SharedPreferences.getInstance();
    final statusStore = SyncStatusStore(prefs);
    final syncConfig = SyncConfig(prefs: prefs, secretStore: store);

    SyncApi api;
    if (syncConfig.isConfigured) {
      final token = await syncConfig.resolveToken();
      if (token == null || token.isEmpty) {
        _log.w('sync 配置了 token_ref 但 SecretStore 取不到，使用 Mock');
        api = MockSyncApi();
      } else {
        api = HttpSyncApi(baseUrl: syncConfig.baseUrl!, userToken: token);
      }
    } else {
      _log.i('sync 未配置（首次启动？），使用 MockSyncApi 占位');
      api = MockSyncApi();
    }
    final engine = SyncEngine(
      db: database,
      api: api,
      outbox: outbox,
      deviceId: did,
    );
    engine.bootstrapLastPulledAt(statusStore.lastPulledAt);
    final scheduler = SyncScheduler(
      engine: engine,
      api: api,
      statusStore: statusStore,
    );
    final sync = SyncContext(
      outbox: outbox,
      config: syncConfig,
      statusStore: statusStore,
      scheduler: scheduler,
      api: api,
    );

    // 若配置启用则启动自动同步
    if (syncConfig.enabled) {
      scheduler.start();
    }

    return (
      ExtractionService(repo: repo, ai: ai, trees: trees),
      database,
      router,
      settings,
      sync,
    );
  }
}

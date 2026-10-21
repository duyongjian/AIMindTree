/// T1 知识点提取服务（T04 合并双轨后的正式版）。
///
/// 链路：用户笔记 → [AiService] (T1) → 路由到 LLM Server → 结构化解析
/// → [KnowledgeRepository.saveExtracted]（锚点校验，幻觉剔除）→ 落库。
///
/// 旧原型（FileKnowledgeStore + 直连 DifyClient）已被本版取代并删除；
/// DifyClient 本身随自研 LLM Server 上线而停用（文件整段注释保留，可回退）。
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../core/logger.dart';
import '../core/result.dart';
import '../core/secret_store.dart';
import '../data/db/drift_database.dart';
import '../data/models/knowledge_point.dart';
import '../data/repositories/group_repository.dart';
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
import 'app_config_service.dart';
import 'clients/llm_server_client.dart';
import 'unavailable_ai_provider.dart';

/// 本地 LLM 服务配置（P0 引导用，开箱即跑）。
///
/// ⚠️ 仅本地开发期：正式应从 `ai_providers` 表读取（设置页配置，S4 不同步）。
///
/// **无密钥字段**：密钥由服务端 `llm_server/.env` 持有（密钥边界 C4）。
/// （旧版本这里硬编码过 Dify 应用 Key，已随 Dify 方案停用一并清除；
///  作为「过时方案」保留回溯，切勿在客户端下发或复用：
///  appApiKey = 'app-fhXwVvHFfVbVWRq3tRMOX8fd'  // 历史 Dify 应用级 Key，现统一由 llm_server/.env 持有）
class LocalAiConfig {
  const LocalAiConfig({
    this.baseUrl = kLlmServerDefaultBaseUrl,
    this.backend = 'auto',
    this.model = '',
  });

  /// LLM Server 地址，默认 `http://127.0.0.1:8787`。
  final String baseUrl;

  /// `auto` = 跟随服务端 `config.yaml` 的 `default_backend`。
  final String backend;

  /// 空 = 用后端默认模型。
  final String model;
}

class ExtractionService {
  ExtractionService({
    required this.repo,
    required this.ai,
    required this.trees,
    required this.groups,
  });

  final KnowledgeRepository repo;
  final TreeRepository trees;
  final GroupRepository groups;
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

    // 2) 调 T1（AiService → 路由 → LLM Server /v1/task/T1）
    final aiRes = await ai.run(AiTask.t1Extract, {'note_text': content});
    if (aiRes is Failure<AiTaskResult>) {
      return Failure(aiRes.error, aiRes.stackTrace);
    }
    final result = (aiRes as Success<AiTaskResult>).value;

    // 3) 映射为待校验的原始知识点
    final rawPoints = _mapToRaw(result.parsed);
    if (rawPoints == null) {
      return Failure(
        StateError('T1 返回结构无法解析为知识点列表：${_preview(result.content)}'),
      );
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
            sourceQuote:
                (m['source_quote'] as String?) ??
                (m['sourceQuote'] as String? ?? ''),
            prerequisites:
                (m['prerequisites'] as List<dynamic>?)
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
    return firstLine.length > 40 ? '${firstLine.substring(0, 40)}…' : firstLine;
  }

  static String _preview(String s) =>
      s.length <= 120 ? s : '${s.substring(0, 120)}…';

  /// P0 开发引导：组装整套依赖。
  ///
  /// 流程：
  /// 1) 初始化 DB / SecretStore / SettingsRepository / SyncContext；
  /// 2) 首次启动则从 [LocalAiConfig] seed 一个 LLM 服务 provider（开箱即用）；
  /// 3) 读 `ai_providers` 表里所有启用的 provider → 实例化并注入 Router；
  /// 4) 装配 SyncContext（SyncApi / Outbox / Engine / Scheduler）；
  /// 5) 返回五元组 (service, db, router, settings, sync)。
  ///
  /// 注：P0 启动时一次性装载所有 provider；后续在设置页改动 provider
  /// 后需要重启 App 才生效（响应式监听留作 T09+ 增量）。
  static Future<
    (
      ExtractionService,
      AppDatabase,
      AiTaskRouter,
      SettingsRepository,
      SyncContext,
    )
  >
  bootstrap({
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

    // === App 下发配置（AC-16/17）：拉一次 + 幂等落库，永不抛异常 ===
    // 放在 seedFromLocalIfEmpty 之前：下发的地址/后端/模型先落库，seed 才会
    // 发现「已有 llm_server 行」而不再塞一条内置默认行。
    final prefs = await SharedPreferences.getInstance();
    await AppConfigService.fetchAndApply(settings, prefs);

    await settings.seedFromLocalIfEmpty(config);

    // === AI Provider ===
    final enabledRows = await settings.enabledProviders();

    // 任务级绑定（ai_task_routes）。T3 / T4 的 Key 是各自工作流应用签发的，
    // 用它们当通用回落会导致 T1 / T5「调错工作流」，所以这里要把它们排除掉。
    final routeRows = await database.aiTaskRouteDao.all();
    final dedicatedIds = <String>{
      for (final r in routeRows)
        if (r.aiTask == AiTask.t3Prerequisite.code ||
            r.aiTask == AiTask.t4GapAnalysis.code)
          r.providerId,
    };
    if (routeRows.isEmpty) {
      _log.w('ai_task_routes 为空：T3/T4 未绑定，将走本地兜底（AI 不参与）');
    } else {
      _log.i(
        '任务路由：${routeRows.map((r) => '${r.aiTask}→${r.providerId}').join(', ')}',
      );
    }

    final Map<String, AiProvider> providers = <String, AiProvider>{};
    final List<AiProviderRow> instantiated = <AiProviderRow>[];
    for (final row in enabledRows) {
      if (row.protocol == kLlmServerProtocol) {
        // llm_server 无客户端密钥：**不调用** resolveApiKey（与旧 dify 分支的
        // 关键差别，C4）。后端与模型由服务端 config.yaml / 本行覆盖共同决定。
        // ⚠️ 必须走 helper：直接读 row.type 会绕过白名单容错，
        // 非法值原样传给服务端 → backend_unknown 400。
        final client = LlmServerClient(
          id: row.id,
          baseUrl: row.baseUrl,
          backend: backendOf(row.type),
          model: firstModel(row.models),
        );
        providers[client.id] = client;
        instantiated.add(row);
      } else {
        _log.w('暂不支持的 provider 协议：${row.protocol}（id=${row.id}）');
      }
    }

    // 通用回落优先级：① isDefault ② 未被 T3/T4 专属绑定 ③ 第一个可用的。
    AiProvider? pickFallback() {
      for (final p in instantiated) {
        if (p.isDefault) return providers[p.id];
      }
      for (final p in instantiated) {
        if (!dedicatedIds.contains(p.id)) return providers[p.id];
      }
      for (final p in instantiated) {
        return providers[p.id];
      }
      return null;
    }

    // 没有可用行 → 用空对象（Null Object，D5）：**不抛 StateError**，
    // bootstrap 照常返回五元组，App 照常可用，AI 入口走 Failure 分支。
    final fallback = pickFallback() ?? UnavailableAiProvider();
    if (fallback is UnavailableAiProvider) {
      _log.w('AI 降级态：没有可用的 llm_server provider'
          '（source=${AppConfigService.lastSource}），'
          '笔记/画布/同步照常可用，AI 入口会提示未连接');
    }

    final router = AiTaskRouter(
      db: database,
      providers: providers,
      fallback: fallback,
    );
    final ai = AiService(router: router);
    final repo = KnowledgeRepository(database, deviceId: did);
    final trees = TreeRepository(database, deviceId: did);
    final groups = GroupRepository(database, deviceId: did);

    // === Sync（T03）===
    final outbox = SyncOutboxRepo(database, deviceId: did);
    // prefs 已在上面取过（bootstrap 前置的下发拉取也用它存 sha1），此处复用。
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
      ExtractionService(repo: repo, ai: ai, trees: trees, groups: groups),
      database,
      router,
      settings,
      sync,
    );
  }
}

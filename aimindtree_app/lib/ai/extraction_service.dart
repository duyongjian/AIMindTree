/// T1 知识点提取服务（T04 合并双轨后的正式版）。
///
/// 链路：用户笔记 → [AiService] (T1) → 路由到 LLM Server → 结构化解析
/// → [KnowledgeRepository.saveExtracted]（锚点校验，幻觉剔除）→ 落库。
///
/// 旧原型（FileKnowledgeStore + 直连 DifyClient）已被本版取代并删除；
/// DifyClient 本身随自研 LLM Server 上线而停用（文件整段注释保留，可回退）。
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../core/id.dart';
import '../core/logger.dart';
import '../core/remote_log_forwarder.dart';
import '../core/result.dart';
import '../core/secret_store.dart';
import '../data/db/drift_database.dart';
import '../data/models/knowledge_point.dart';
import '../data/repositories/group_repository.dart';
import '../data/repositories/knowledge_repository.dart';
import '../data/repositories/notebook_repository.dart';
import '../data/repositories/note_asset_repository.dart';
import '../data/repositories/tree_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/sync/http_proxy.dart';
import '../data/sync/sync_api.dart';
import '../data/sync/sync_config.dart';
import '../data/sync/sync_context.dart';
import '../data/sync/sync_engine.dart';
import '../data/sync/sync_outbox.dart';
import '../data/sync/sync_scheduler.dart';
import '../data/sync/sync_status.dart';
import 'ai_provider.dart';
import 'ai_job_service.dart';
import 'ai_service.dart';
import 'extraction_batching.dart';
import 'ai_task.dart';
import 'ai_task_router.dart';
import 'app_config_service.dart';
import 'clients/llm_server_client.dart';
import 'unavailable_ai_provider.dart';
import '../features/knowledge/kp_dedup.dart';

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
    required this.jobs,
    required this.assets,
    required this.notebooks,
  });

  final KnowledgeRepository repo;
  final TreeRepository trees;
  final GroupRepository groups;
  final AiService ai;

  /// 笔记文件夹（笔记本）仓储：文件夹增删改查与置顶。
  final NotebookRepository notebooks;

  /// AI 任务队列（/v1/jobs）：批量型 AI 功能走这里，提交即返回。
  final AiJobService jobs;

  /// 笔记内嵌图片（`note_assets`）：编辑器插入图片 / 渲染解析 / 孤儿清理。
  /// 与笔记分开同步，base64 唯一权威存储（见仓储头注释）。
  final NoteAssetRepository assets;

  static final AppLog _log = AppLog('extraction');

  /// 对一段笔记原文执行完整 T1 流程（**同步路径**：取笔记 → 调 T1 → 落库）。
  ///
  /// 队列路径（默认，方案 B1）请用三段式：
  /// [stageSaveNote] → 提交 T1 job → [stagePersist]，中间不干等。
  ///
  /// [existingNote]：调用方已持有「当前正在编辑/已保存」的笔记时传入
  /// （编辑器路径）——直接复用它做知识点归属，**不再新建笔记**。否则
  /// （粘贴提取等无主场景）才走 [stageSaveNote] 存一篇新笔记。
  /// 2026-10-24 用户实测 bug：编辑器提取时没传当前笔记，知识点全挂到
  /// 空降的新笔记上，原笔记「本笔记提取的知识点」区永远空白。
  ///
  /// [variant]：T1 的提示词变体（用户勾选的提取模式），三态映射：
  /// - 空串（默认）= 仅提取知识点 → 不传 variant，服务端走 `t1_extract.md`；
  /// - `'keypoints'` = 仅提取要点重点 → `t1_extract__keypoints.md`；
  /// - `'both'` = 两者都要 → `t1_extract__both.md`。
  ///
  /// 变体走 **body 穿透**（`run(variant: ...)` → `runTask(variant: ...)` →
  /// POST body），**不是**新任务码：服务端按 `(task, variant)` 二元组检索
  /// 提示词，URL 始终是 `/v1/task/T1`。
  Future<Result<ExtractionSaveResult>> extract(
    String noteContent, {
    String? notebookId,
    Note? existingNote,
    String variant = '',
  }) async {
    final content = noteContent.trim();
    if (content.isEmpty) {
      return Failure(ArgumentError('笔记内容为空'));
    }

    // 1) 取笔记：有当前笔记就复用（知识点归它），无主场景才新建。
    Note note;
    final existing = existingNote;
    if (existing != null) {
      note = existing;
    } else {
      final saved = await stageSaveNote(content);
      if (saved is Failure<Note>) {
        return Failure(saved.error, saved.stackTrace);
      }
      note = (saved as Success<Note>).value;
    }

    // 2) 分块提取（AiService → 路由 → LLM Server /v1/task/T1）。
    //    [variant] 由调用方按用户勾选的模式传（'' / 'keypoints' / 'both'）。
    //    空串 = 不带变体（客户端只在 variant 非空时写进 body，保旧行为）。
    //    长文按边界分块、携带「前文摘要」防重复，避免单次调用被 token 上限
    //    截断而遗漏知识点（遗漏/omission）；短文本退化为单次调用，等价旧行为。
    final t1Raw = await _runT1Batched(content, variant: variant);
    if (t1Raw is Failure<List<RawKnowledgePoint>>) {
      return Failure(t1Raw.error, t1Raw.stackTrace);
    }
    final t1Result = AiTaskResult(
      content: '',
      parsed: (t1Raw as Success<List<RawKnowledgePoint>>)
          .value
          .map(_rawToMap)
          .toList(),
    );

    // 3) 锚点校验 + 落库
    return stagePersist(
      note: note,
      noteContent: content,
      t1: t1Result,
      notebookId: notebookId,
    );
  }

  /// T1 分块提取：短文本单次调用（与旧行为完全一致）；长文本按边界分块，
  /// 逐块携带「前文摘要」防止重复提取，最后按归一化名称去重合并。
  ///
  /// 返回 [Result]<[List]<[RawKnowledgePoint]>>：失败透传 [AiService] 的 [Failure]。
  Future<Result<List<RawKnowledgePoint>>> _runT1Batched(
    String content, {
    String variant = '',
  }) async {
    const maxChars = 3000;

    // 短文本：单次调用，等价于改造前的 extract。
    if (content.length <= maxChars) {
      final res = await ai.run(
        AiTask.t1Extract,
        {'note_text': content},
        variant: variant,
      );
      if (res is Failure<AiTaskResult>) {
        return Failure(res.error, res.stackTrace);
      }
      final parsed = (res as Success<AiTaskResult>).value;
      return Success(_mapToRaw(parsed.parsed) ?? const <RawKnowledgePoint>[]);
    }

    // 长文本：分块 + 运行摘要 + 去重。
    final chunks = splitForBatching(content, maxChars: maxChars);
    final merged = <RawKnowledgePoint>[];
    String? summary;
    for (final chunk in chunks) {
      // 若已有前文摘要，则在正文前插入明确标识的「防重复」提示块。
      final noteText = summary == null
          ? chunk
          : '\n【前文摘要（仅供参考，不要重复提取，只提取下方正文中的新知识点）】\n'
              '$summary\n【待提取正文】\n$chunk';
      final res = await ai.run(
        AiTask.t1Extract,
        {'note_text': noteText},
        variant: variant,
      );
      if (res is Failure<AiTaskResult>) {
        return Failure(res.error, res.stackTrace);
      }
      final parsed = (res as Success<AiTaskResult>).value;
      final pts = _mapToRaw(parsed.parsed) ?? const <RawKnowledgePoint>[];
      merged.addAll(pts);
      // 更新运行摘要（基于已合并的全部点），喂给下一块防重复。
      summary = summarizePoints(merged, maxChars: 600);
    }
    return Success(dedupePoints(merged));
  }

  /// 把 [RawKnowledgePoint] 还原为 T1 契约的 Map（裸数组形态），供 [stagePersist]
  /// 的 [_mapToRaw] 再次解析（与 LLM 返回结构口径一致，保持落库链路不变）。
  Map<String, dynamic> _rawToMap(RawKnowledgePoint p) => <String, dynamic>{
        'name': p.name,
        'type': p.type,
        'definition': p.definition,
        'source_quote': p.sourceQuote,
        'prerequisites': p.prerequisites,
        'confidence': p.confidence,
      };

  /// 划词提取（T15）：把正文中选中文字提炼成一个完整知识点，归属 [note]。
  ///
  /// 用户场景：在编辑器里选中一段文字 → 一键生成知识点。其余字段
  /// （name / type / definition / prerequisites）由 LLM 结合整篇笔记判断，
  /// 客户端只权威覆盖 **source_quote = 选中文字**：
  /// - 选中文字必然逐字出现在原文中 → 锚点校验天然通过；
  /// - LLM 改字 / 扩写 quote 也不会造成锚点漂移（幻觉防护）。
  ///
  /// 单条入库复用 [KnowledgeRepository.saveExtracted]（锚点校验 + PRD 铁律），
  /// 成功后 fire-and-forget 触发一轮 T14 查重（与粘贴提取的 `_applyT1` 同款：
  /// 划词也是「创建知识点」路径）。
  Future<Result<KnowledgePoint>> extractFromSelection({
    required Note note,
    required String selection,
  }) async {
    final quote = selection.trim();
    if (quote.isEmpty) {
      return Failure(ArgumentError('选中的文字为空'));
    }

    // 1) 调 T15（单对象输出：{"knowledge_point": {...}}）
    final aiRes = await ai.run(
      AiTask.t15KpFromSelection,
      <String, dynamic>{
        'selection': quote,
        'note_text': note.contentMd,
      },
    );
    if (aiRes is Failure<AiTaskResult>) {
      return Failure(aiRes.error, aiRes.stackTrace);
    }
    final aiResult = (aiRes as Success<AiTaskResult>).value;

    // 2) 解析单对象（_mapToRaw 只认数组，这里先包一层，不改动它的口径）。
    final raw = _mapSingleToRaw(aiResult);
    if (raw == null) {
      return Failure(
        StateError('T15 返回结构无法解析为知识点：${_preview(aiResult.content)}'),
      );
    }

    // 3) source_quote 无条件覆盖为选中文字（客户端权威，防 LLM 改字）。
    final forced = RawKnowledgePoint(
      name: raw.name,
      type: raw.type,
      definition: raw.definition,
      sourceQuote: quote,
      prerequisites: raw.prerequisites,
      confidence: raw.confidence,
    );

    // 4) 单条入库（锚点校验 + 落库 + 同步入队都在里面）。
    final saved = await repo.saveExtracted(
      noteId: note.id,
      noteContent: note.contentMd,
      rawPoints: <RawKnowledgePoint>[forced],
    );
    if (saved is Failure<ExtractionSaveResult>) {
      return Failure(saved.error, saved.stackTrace);
    }
    final result = (saved as Success<ExtractionSaveResult>).value;
    if (result.saved.isEmpty) {
      // 锚点校验失败（选中文字不在原文里）/ 名称为空 → 带原因回传。
      final reason = result.rejected.isEmpty
          ? '未入库（原因未知）'
          : result.rejected.first.reason;
      return Failure(StateError(reason));
    }

    // 5) 划词也是「创建知识点」路径：后台跑一轮查重（fire-and-forget）。
    kpDedupSchedule(repo: repo, jobs: jobs);
    return Success(result.saved.first);
  }

  /// 队列路径 · 第一步：存笔记，拿 noteId（资源锁 ``note:{id}`` 的依据）。
  Future<Result<Note>> stageSaveNote(String noteContent) async {
    final content = noteContent.trim();
    if (content.isEmpty) {
      return Failure(ArgumentError('笔记内容为空'));
    }
    final note = Note(
      contentMd: content,
      title: _deriveTitle(content),
      deviceId: repo.deviceId,
    );
    return repo.saveNote(note);
  }

  /// 队列路径 · 第三步：锚点校验 + 落库（[t1] 为 T1 job 的 result 转来）。
  Future<Result<ExtractionSaveResult>> stagePersist({
    required Note note,
    required String noteContent,
    required AiTaskResult t1,
    String? notebookId,
  }) async {
    final content = noteContent.trim();

    // 映射为待校验的原始知识点
    final rawPoints = _mapToRaw(t1.parsed);
    if (rawPoints == null) {
      return Failure(
        StateError('T1 返回结构无法解析为知识点列表：${_preview(t1.content)}'),
      );
    }
    if (rawPoints.isEmpty) {
      _log.w('T1 提取结果为空');
    }

    // 锚点校验 + 落库
    return repo.saveExtracted(
      noteId: note.id,
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

  /// 把 T15 的单对象输出映射为一条原始知识点。
  ///
  /// 认三种形态（容错，服务端提示词偶尔会走样）：
  /// 1. `{"knowledge_point": {...}}`（契约形态）；
  /// 2. `{"knowledge_points": [ {...} ]}`（误用了 T1 的数组契约）→ 取第一条；
  /// 3. 裸对象 `{...}` / 裸数组 `[...]` → 取第一条。
  /// 解析不出来返回 null（由调用方转 Failure）。
  RawKnowledgePoint? _mapSingleToRaw(AiTaskResult result) {
    final parsed = result.parsed;
    List<dynamic>? list;
    if (parsed is Map) {
      final single = parsed['knowledge_point'];
      if (single is Map) {
        list = <dynamic>[single];
      } else {
        final many = parsed['knowledge_points'];
        if (many is List) {
          list = many;
        } else if (parsed['name'] is String) {
          list = <dynamic>[parsed]; // 裸对象
        }
      }
    } else if (parsed is List) {
      list = parsed; // 裸数组
    }
    if (list == null || list.isEmpty) return null;
    final raws = _mapToRaw(list) ?? const <RawKnowledgePoint>[];
    return raws.isEmpty ? null : raws.first;
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
    // 同步设备号：**必须**是「每台设备唯一且持久化」的值（[DeviceId] 存 prefs
    // 的 ULID）。这里曾用常量 local-dev 兜底，而 main.dart 又是无参调用
    // bootstrap，结果 PC 与手机拿到**同一个**号码 → pull 的自回声过滤
    // （`sync_engine.dart` 的 `env.deviceId == deviceId`）把服务端**所有**行都
    // 当成「本机自己上传的」跳过，表现为「应用变更 0 条，跳过 N 条」，
    // 且换任何中继后端都一模一样（2026-10-24 用户实测）。
    final did = deviceId ?? await DeviceId.get();
    _log.i('同步设备号 = $did（自回声过滤依据，跨设备必须唯一）');

    // === Settings ===
    final settings = SettingsRepository(database, secretStore: store);

    // === App 下发配置（AC-16/17）：拉一次 + 幂等落库，永不抛异常 ===
    // 放在 seedFromLocalIfEmpty 之前：下发的地址/后端/模型先落库，seed 才会
    // 发现「已有 llm_server 行」而不再塞一条内置默认行。
    final prefs = await SharedPreferences.getInstance();
    // prefs 已在上面取过（bootstrap 前置的下发拉取也用它存 sha1），此处复用。
    final syncConfig = SyncConfig(prefs: prefs, secretStore: store);
    // === 用户手动代理：必须在任何 HttpClient 建出来之前灌回 http_proxy ===
    // `initSystemProxy()`（main.dart 里启动时探测一次）不知道用户在设置页手
    // 动填的代理——那个值只存在 prefs 里。不在这里重放，`syncFindProxy` 会
    // 静默回落到「直连/自动探测」，表现为「设置里填了代理，重启后似乎没生效」，
    // 这类问题在用户侧极难自查。放在这里（而不是更靠下的 Sync 装配处）是因为
    // 紧接着的下发拉取也会发 HTTP 请求，同样需要走代理；且这里是 bootstrap
    // 里最早能拿到 prefs 的位置，路径上没有任何提前 return。
    setUserProxy(syncConfig.cfProxy);
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
    // 记住 llm_server 行的地址：任务队列（/v1/jobs）复用同一信任域。
    // 没有 llm_server 行（全 dify / 降级态）→ 用内置默认地址。
    String? llmServerBaseUrl;
    for (final row in enabledRows) {
      if (row.protocol == kLlmServerProtocol) {
        llmServerBaseUrl = row.baseUrl;
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
    final notebooks = NotebookRepository(database, deviceId: did);

    // === Sync（T03）===
    final outbox = SyncOutboxRepo(database, deviceId: did);
    // 全局接线点：仓储层（KnowledgeRepository / TreeRepository /
    // AiSessionRepository）写完本地库后就用它入队，实现「本地 → 服务端」
    // 上行同步。测试里默认为 null → 仓储不入队、也不崩。
    SyncOutboxRepo.current = outbox;
    final statusStore = SyncStatusStore(prefs);

    SyncApi api;
    // 多后端（Cloudflare / EdgeOne Pages / Netlify）：按用户选中的后端装配，
    // 地址与每用户令牌都按后端隔离。未配地址（如 EdgeOne Pages 域名待回填）
    // 或未登录（没有每用户令牌）时退 MockSyncApi 占位——自动同步暂不可用，
    // 用户仍可在设置页选后端、登录后手动上传/拉取。
    final syncBackend = syncConfig.selectedBackend;
    final syncBaseUrl = syncConfig.urlOf(syncBackend);
    final syncToken = await syncConfig.resolveUserToken(syncBackend);
    if (syncBaseUrl.isNotEmpty && syncToken != null && syncToken.isNotEmpty) {
      api = HttpSyncApi(
        baseUrl: syncBaseUrl,
        userToken: syncToken,
        backend: syncBackend,
      );
    } else {
      _log.i('sync 后端未就绪（$syncBackend：地址或登录令牌缺失），'
          '使用 MockSyncApi 占位');
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

    // 任务队列：与 llm_server 同一信任域（只走本地 127.0.0.1）。
    final jobs = AiJobService(
      baseUrl: llmServerBaseUrl ?? kLlmServerDefaultBaseUrl,
    );

    // P0-5：把 App 侧日志抄送到本机 llm_server，使管理后台 M7 能看到 App 日志。
    // 只与本机通信；服务未启动 / 代理异常一律 best-effort 吞掉，不影响业务。
    AppLog.forwarder = RemoteLogForwarder(
      llmServerBaseUrl ?? kLlmServerDefaultBaseUrl,
    );

    return (
      ExtractionService(
        repo: repo,
        ai: ai,
        trees: trees,
        groups: groups,
        jobs: jobs,
        assets: NoteAssetRepository(database, deviceId: did),
        notebooks: notebooks,
      ),
      database,
      router,
      settings,
      sync,
    );
  }
}

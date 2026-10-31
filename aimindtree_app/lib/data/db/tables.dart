/// Drift 表定义（ARCHITECTURE §5.1：Supabase Postgres 与本地 Drift 镜像）。
///
/// 约定：
/// - 主键一律 **ULID**（text），不用自增 ID、不用 uuid（§11）。
/// - 同步表统一带 `version / updated_at / device_id / deleted_at`(tombstone)，由 [SyncMeta] mixin 提供。
/// - `ai_providers` / `ai_task_routes` 是 **S4 本地表**（API Key 不同步），不带同步元数据。
/// - `sync_outbox` 仅本地，不上云。
/// - 枚举统一存 `name` 文本，转换在 Repository 层做。
library;

import 'package:drift/drift.dart';

/// 同步表的公共元数据列（T02/T03 依赖）。
mixin SyncMeta on Table {
  /// ULID 主键。
  TextColumn get id => text().named('id')();

  /// 本地递增版本号，服务端接管后用于 LWW 冲突判定。
  IntColumn get version => integer().named('version').withDefault(const Constant(1))();

  DateTimeColumn get updatedAt => dateTime().named('updated_at')();

  /// 产生该次变更的设备，用于同步自回声过滤。
  TextColumn get deviceId => text().named('device_id')();

  /// tombstone 软删除：非空即删除，删除靠它传播，不物理删（§11）。
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();

  @override
  Set<Column>? get primaryKey => {id};
}

/// 笔记本（层级目录）。
@DataClassName('NotebookRow')
class Notebooks extends Table with SyncMeta {
  TextColumn get name => text().named('name')();
  TextColumn get parentId => text().named('parent_id').nullable()();
  IntColumn get sortOrder => integer().named('sort_order').withDefault(const Constant(0))();
}

/// 笔记正文（Markdown 源码 + 分屏预览，PRD §5.10）。
@DataClassName('NoteRow')
class Notes extends Table with SyncMeta {
  TextColumn get notebookId => text().named('notebook_id').nullable()();
  TextColumn get title => text().named('title').withDefault(const Constant(''))();
  TextColumn get contentMd => text().named('content_md').withDefault(const Constant(''))();

  /// 内容哈希，用于快速判断是否有实质变更 / 同步校验和。
  TextColumn get contentHash => text().named('content_hash').withDefault(const Constant(''))();
}

/// 笔记附件（图片）——与笔记分开同步，避免笔记 payload 被 base64 撑爆。
@DataClassName('NoteAssetRow')
class NoteAssets extends Table with SyncMeta {
  TextColumn get noteId => text().named('note_id')();
  TextColumn get name => text().named('name').withDefault(const Constant(''))();
  TextColumn get mime => text().named('mime').withDefault(const Constant('image/png'))();

  /// 原图字节的 SHA-1，用于**同一笔记内**去重。
  TextColumn get sha1 => text().named('sha1').withDefault(const Constant(''))();

  /// 原图字节数（插入时上限校验用）。
  IntColumn get bytes => integer().named('bytes').withDefault(const Constant(0))();

  /// base64 正文（唯一权威存储；磁盘只做可选缓存）。
  TextColumn get dataBase64 => text().named('data_base64')();
}

/// 知识点（★产品强约束：必带来源锚点，无锚点视为幻觉禁止入库）。
@DataClassName('KnowledgePointRow')
class KnowledgePoints extends Table with SyncMeta {
  TextColumn get notebookId => text().named('notebook_id').nullable()();
  TextColumn get name => text().named('name')();

  /// 枚举 concept/formula/theorem/method/fact/myth 的 name。
  TextColumn get type => text().named('type')();

  TextColumn get definition => text().named('definition').withDefault(const Constant(''))();

  // ---- 来源锚点四件套（★幻觉防护，Repository 入库前必校验）----
  TextColumn get sourceNoteId => text().named('source_note_id')();
  IntColumn get sourceStart => integer().named('source_start')();
  IntColumn get sourceEnd => integer().named('source_end')();
  TextColumn get sourceQuote => text().named('source_quote')();

  /// 来源：ai_extract / user_manual / tutor 等。
  TextColumn get origin => text().named('origin').withDefault(const Constant('ai_extract'))();

  RealColumn get confidence => real().named('confidence').withDefault(const Constant(0.0))();

  /// 置顶：true 的知识点恒排在列表最前（用户诉求：控制哪些知识点排在上面）。
  BoolColumn get pinned =>
      boolean().named('pinned').withDefault(const Constant(false))();

  /// 创建时间（nullable：历史行由 v5 迁移回填为 updated_at，读取时兜底 createdAt ?? updatedAt）。
  DateTimeColumn get createdAt => dateTime().named('created_at').nullable()();
}

/// 前置关系边（知识点之间的依赖，构成前置知识树/图）。
@DataClassName('PrerequisiteEdgeRow')
class PrerequisiteEdges extends Table with SyncMeta {
  /// 前置知识点（先学的）。
  TextColumn get fromKpId => text().named('from_kp_id')();

  /// 后继知识点（依赖 from 的）。
  TextColumn get toKpId => text().named('to_kp_id')();

  TextColumn get reason => text().named('reason').withDefault(const Constant(''))();
  TextColumn get origin => text().named('origin').withDefault(const Constant('ai'))();
  RealColumn get confidence => real().named('confidence').withDefault(const Constant(0.0))();
}

/// 掌握状态记录（★级联降级的数据基础）。
@DataClassName('MasteryRecordRow')
class MasteryRecords extends Table with SyncMeta {
  TextColumn get kpId => text().named('kp_id')();

  /// unknown/not_mastered/learning/mastered/abandoned。
  TextColumn get status => text().named('status')();

  /// self/ai/tutor_cascade（级联降级产生）。
  TextColumn get source => text().named('source').withDefault(const Constant('self'))();
}

/// 卡片（★append-only：内容不可变，「重新生成」= 新建并填 regenerated_from_id）。
@DataClassName('CardRow')
class Cards extends Table with SyncMeta {
  /// qna/explanation/exercise/tutor_note/summary。
  TextColumn get type => text().named('type')();

  /// 引用来源：{type, id} 的 JSON（source_ref）。
  TextColumn get sourceRef => text().named('source_ref').withDefault(const Constant('{}'))();

  TextColumn get parentCardId => text().named('parent_card_id').nullable()();
  TextColumn get regeneratedFromId => text().named('regenerated_from_id').nullable()();
  TextColumn get contentMd => text().named('content_md').withDefault(const Constant(''))();
  TextColumn get sessionId => text().named('session_id').nullable()();
  TextColumn get modelId => text().named('model_id').nullable()();
}

/// 画布（一个笔记本可有多张画布）。
@DataClassName('CanvasRow')
class Canvases extends Table with SyncMeta {
  TextColumn get notebookId => text().named('notebook_id').nullable()();
  TextColumn get name => text().named('name').withDefault(const Constant(''))();

  /// 视口 {x,y,zoom} 的 JSON。
  TextColumn get viewport => text().named('viewport').withDefault(const Constant('{"x":0,"y":0,"zoom":1}'))();
}

/// 画布节点（★视图，严禁内嵌内容字段；内容经 target_id 回查实体表）。
@DataClassName('CanvasNodeRow')
class CanvasNodes extends Table with SyncMeta {
  TextColumn get canvasId => text().named('canvas_id')();

  /// note/kp/card/group。
  TextColumn get targetType => text().named('target_type')();
  TextColumn get targetId => text().named('target_id')();

  RealColumn get x => real().named('x').withDefault(const Constant(0))();
  RealColumn get y => real().named('y').withDefault(const Constant(0))();
  RealColumn get w => real().named('w').withDefault(const Constant(200))();
  RealColumn get h => real().named('h').withDefault(const Constant(120))();
  IntColumn get z => integer().named('z').withDefault(const Constant(0))();
  BoolColumn get collapsed =>
      boolean().named('collapsed').withDefault(const Constant(false))();

  /// 是否锁定：true = 用户拖过 / 已固化，结构变化（增删边）的自动重排**不**移动它；
  /// false = 浮动节点，结构变化时由布局引擎自动重新铺位。
  /// 默认 true（历史数据 + 手动固化都按「已锁定」处理，除非显式置 false）。
  BoolColumn get pinned =>
      boolean().named('pinned').withDefault(const Constant(true))();
}

/// 画布连线。
@DataClassName('CanvasEdgeRow')
class CanvasEdges extends Table with SyncMeta {
  TextColumn get canvasId => text().named('canvas_id')();
  TextColumn get fromNodeId => text().named('from_node_id')();
  TextColumn get toNodeId => text().named('to_node_id')();

  /// semantic_prereq/attachment/manual。
  TextColumn get edgeType => text().named('edge_type').withDefault(const Constant('manual'))();
  TextColumn get prereqEdgeId => text().named('prereq_edge_id').nullable()();
}

/// 画布自由文本卡片（★2.0.0 新增：丰富知识树无限画布）。
///
/// 同时承载两种 UI：
/// - 「笔记卡片」——关联某条笔记，标题+摘要由该笔记自动派生（可覆盖）；
/// - 「透明文本框」——纯自由文本，可随意移动、手填标题/备注。
///
/// 二者共用同一张内容表，靠 [styleJson] 里的 `kind` 区分
/// （`note_card` / `text_box`）。**位置/尺寸/层级不在这里**——
/// 由 [CanvasNodes]（`target_type='card'` + `targetId` 回指本表 id）统一管理，
/// 与该表已有的 `kp` 节点走同一套渲染/拖动/网格吸附逻辑。
@DataClassName('CanvasCardRow')
class CanvasCards extends Table with SyncMeta {
  /// 关联笔记 id（笔记卡片用）：非空时标题+摘要由该笔记自动派生；
  /// 为空 = 纯自由卡片（标题/正文手填）。
  TextColumn get noteId => text().named('note_id').nullable()();

  /// 卡片标题（自由卡片手填；关联笔记时默认取笔记标题，可覆盖）。
  TextColumn get title => text().named('title').withDefault(const Constant(''))();

  /// 卡片正文（自由卡片的备注/摘要；关联笔记时默认取笔记摘要，可覆盖）。
  TextColumn get body => text().named('body').withDefault(const Constant(''))();

  /// 样式预设 JSON：`{"kind":"note_card"|"text_box","bg":"#fff","opacity":1.0}`。
  /// 同步层只搬运不解析（解析归卡片仓储/UI）。
  TextColumn get styleJson =>
      text().named('style_json').withDefault(const Constant('{}'))();
}

/// 画布手写笔迹（★2.0.0 新增：圆珠笔手写 + 橡皮擦除）。
///
/// 一条记录 = 一笔（从落笔到抬笔采到的所有点）。橡皮为「整笔擦除」：
/// 命中哪条笔迹就整条删除（不像素级局部擦）。
///
/// 笔迹坐标存**画布坐标系**（与节点 x/y 同一套），渲染时随 pan/zoom 变换。
/// 属于画布层级内容，直接挂 [canvasId]（不走 [CanvasNodes]，因为笔迹
/// 不是可拖拽节点，而是连续墨迹）。
@DataClassName('CanvasStrokeRow')
class CanvasStrokes extends Table with SyncMeta {
  TextColumn get canvasId => text().named('canvas_id')();

  /// 点序列 JSON：`[{"x":12.3,"y":45.6}, ...]`（画布坐标系）。
  TextColumn get pointsJson =>
      text().named('points_json').withDefault(const Constant('[]'))();

  /// 墨色（hex 字符串）。
  TextColumn get color =>
      text().named('color').withDefault(const Constant('#1a1a1a'))();

  /// 笔宽（像素，画布坐标系）。
  RealColumn get width =>
      real().named('width').withDefault(const Constant(3.0))();
}

/// 知识点分组（「分组」UI：框选知识点成一组成员，可命名 + 标基础度）。
///
/// 组序 [orderIndex] 越小越基础；[foundationalLevel] 是**组级**基础度，
/// 成员可在 [membersJson] 里各自覆盖。
@DataClassName('KpGroupRow')
class KpGroups extends Table with SyncMeta {
  /// 所属知识树（canvases.id）。
  TextColumn get canvasId => text().named('canvas_id')();

  TextColumn get name => text().named('name').withDefault(const Constant(''))();

  /// 组序（第几组），从 0 开始；越小越基础（越先掌握）。
  IntColumn get orderIndex =>
      integer().named('order_index').withDefault(const Constant(0))();

  /// 组级基础度（0 = 最基础）。成员未单独标注时用它。
  IntColumn get foundationalLevel =>
      integer().named('foundational_level').withDefault(const Constant(0))();

  /// 成员 JSON：`[{"kpId":"...","level":1}]`；`level` 是点级基础度覆盖（缺省用组级）。
  TextColumn get membersJson =>
      text().named('members_json').withDefault(const Constant('[]'))();
}

/// 作业（「作业模式」的产物：一批薄弱点 + 给它们出的题）。
///
/// 题目以 JSON 整体存在 [Homeworks.itemsJson]，而不是拆成子表：
/// 作业是一次性草稿、编辑时整体覆写，没有「按题查询 / 单题统计」的需求，
/// 拆表只会多一次 join 和多一张要手写的 drift 生成类（本仓库 build_runner
/// 不可用时，每张表的 .g.dart 都要手工复刻）。
@DataClassName('HomeworkRow')
class Homeworks extends Table with SyncMeta {
  /// 所属知识树（canvases.id）。
  TextColumn get canvasId => text().named('canvas_id')();

  /// 作业标题。
  TextColumn get title => text().named('title').withDefault(const Constant(''))();

  /// 布置时选中的薄弱点 id（快照：日后知识点改名不影响历史作业的可读性）。
  TextColumn get kpIdsJson =>
      text().named('kp_ids_json').withDefault(const Constant('[]'))();

  /// 题目 JSON：`[{"kpId","kpName","type","question","answer","difficulty"}]`。
  TextColumn get itemsJson =>
      text().named('items_json').withDefault(const Constant('[]'))();

  /// 主关联知识点外键（→ knowledge_points.id）；「进某知识点看其作业」用。
  /// 一对多：一个知识点下可有多个作业行，批量布置时每行各带一个 [kpId]。
  TextColumn get kpId => text().named('kp_id').nullable()();

  /// 批量布置聚合键：一次框选布置 N 个知识点共享同一 [batchId]（N 行归类）。
  TextColumn get batchId => text().named('batch_id').nullable()();

  /// 作业状态：assigned / draft / done（生命周期展示用）。
  TextColumn get status =>
      text().named('status').withDefault(const Constant('assigned'))();

  /// 截止时间（可选）。
  DateTimeColumn get dueAt => dateTime().named('due_at').nullable()();
}

/// AI 会话（聊天 / 老师模式）。
@DataClassName('AiSessionRow')
class AiSessions extends Table with SyncMeta {
  /// chat/tutor。
  TextColumn get type => text().named('type').withDefault(const Constant('chat'))();
  TextColumn get targetRef => text().named('target_ref').withDefault(const Constant(''))();
  TextColumn get title => text().named('title').withDefault(const Constant(''))();

  /// 绑定知识点（老师模式）。
  TextColumn get kpId => text().named('kp_id').nullable()();

  TextColumn get modelId => text().named('model_id').nullable()();

  /// 老师模式状态机（JSON）。
  TextColumn get tutorState => text().named('tutor_state').withDefault(const Constant('{}'))();
  TextColumn get difficulty => text().named('difficulty').nullable()();
}

/// AI 消息明细。
@DataClassName('AiMessageRow')
class AiMessages extends Table with SyncMeta {
  TextColumn get sessionId => text().named('session_id')();

  /// user/assistant/system。
  TextColumn get role => text().named('role')();
  TextColumn get contentMd => text().named('content_md').withDefault(const Constant(''))();
  IntColumn get tokens => integer().named('tokens').nullable()();
  IntColumn get latencyMs => integer().named('latency_ms').nullable()();
  TextColumn get modelId => text().named('model_id').nullable()();
}

/// AI 供应商配置（**S4 本地表，默认不同步**）。
///
/// Dify 场景：**一个 Dify 应用 = 一行**（不同应用各自 app-api-key）。
/// llm_server 场景：一条记录 = 一个 LLM Server 实例（服务端持密钥，本表不存密钥）。
@DataClassName('AiProviderRow')
class AiProviders extends Table {
  TextColumn get id => text().named('id')();
  TextColumn get name => text().named('name')();

  /// 厂商类型：openai/anthropic/ollama/dify/minimax/local。
  /// llm_server 场景复用为 backend 名（auto/ollama/minimax/openai_compat）。
  /// ⚠️ 表结构不可改（Drift 依赖 build_runner 生成 .g.dart）；此处只加注释。
  TextColumn get type => text().named('type')();

  /// 端点协议：openai / anthropic / dify（已停用）/ llm_server。
  TextColumn get protocol => text().named('protocol')();

  TextColumn get baseUrl => text().named('base_url').withDefault(const Constant(''))();

  /// 密钥**引用**（指向 SecretStore），绝不明文入表（§5.1）。
  TextColumn get apiKeyRef => text().named('api_key_ref').withDefault(const Constant(''))();

  /// 可选模型列表 JSON。
  /// llm_server 场景：JSON 数组，最多 1 个元素 = model 覆盖，`[]` = 用后端默认。
  TextColumn get models => text().named('models').withDefault(const Constant('[]'))();

  BoolColumn get isDefault => boolean().named('is_default').withDefault(const Constant(false))();
  BoolColumn get enabled => boolean().named('enabled').withDefault(const Constant(true))();

  @override
  Set<Column>? get primaryKey => {id};
}

/// AI 任务级路由（**S4 本地表**，起因：Dify Key 按应用签发）。
///
/// 把 T1–T13 每个任务路由到具体 provider（及可选的 key/endpoint 覆盖）。
@DataClassName('AiTaskRouteRow')
class AiTaskRoutes extends Table {
  TextColumn get id => text().named('id')();

  /// 任务枚举名，如 `T1_EXTRACT`。
  TextColumn get aiTask => text().named('ai_task')();

  TextColumn get providerId => text().named('provider_id')();
  TextColumn get apiKeyRefOverride => text().named('api_key_ref_override').nullable()();
  TextColumn get endpointOverride => text().named('endpoint_override').nullable()();

  @override
  Set<Column>? get primaryKey => {id};
}

/// 同步 Outbox（**仅本地 Drift，不上云**）。
///
/// 记录「实体最终态」的 upsert，不记每步细粒度操作（§5.2）。
@DataClassName('SyncOutboxRow')
class SyncOutbox extends Table {
  /// 自增本地序号（不参与同步，故可用自增）。
  IntColumn get id => integer().named('id').autoIncrement()();

  TextColumn get entityTable => text().named('entity_table')();
  TextColumn get entityId => text().named('entity_id')();

  /// upsert / delete。
  TextColumn get op => text().named('op')();

  /// 实体最终态 JSON。
  TextColumn get payloadJson => text().named('payload_json')();
  TextColumn get deviceId => text().named('device_id')();
  IntColumn get baseVersion => integer().named('base_version').withDefault(const Constant(0))();
  IntColumn get retryCount => integer().named('retry_count').withDefault(const Constant(0))();

  /// pending / sending / failed / done。
  TextColumn get status => text().named('status').withDefault(const Constant('pending'))();

  DateTimeColumn get createdAt => dateTime().named('created_at')();
}

# AIMindTree 老师模式会话化 —— 测试方案

| 项目 | 内容 |
| --- | --- |
| 文档类型 | **测试方案**（不写测试代码；只定义「测什么 / 怎么测 / 断言什么」） |
| 版本 | **v1.2** —— 对齐架构师 21:27 更新版设计文档：方法名 `getPrimaryForKp` / `listTeacherSessions`、纯函数新增 `at`/`id` 字段与双分支排序、`newDerivedUlid` 派生 id；规格 A 保持 10 条 / 5 轮；规格 B 记录为**待拍板**并把测试做成对两种排序键口径都稳健 |
| 作者 | Edward（QA 工程师） |
| 被测对象 | 老师模式会话化重构（PRD：`docs/TEACHER_SESSION_PRD.md` v1.3 终稿；设计：`docs/TEACHER_SESSION_DESIGN.md`） |
| 代码基线 | `aimindtree_app/lib/features/teacher/teacher_page.dart`（510 行）、`aimindtree_app/lib/data/repositories/ai_session_repository.dart`（261 行） |
| 门禁基线 | `flutter test` **598/598 通过**（2026-10-24 实测）；`tool/analyze_inproc.dart` **132 文件 → 0 error / 0 warning / 3 info**（实测） |
| v1.1 变更 | ① API 命名统一为**设计文档**口径；② L2 注入规模改为 **10 条 / 5 轮 + ≤4000 字符**（规格 A）；③ 消息排序键改为**纯 `id ASC`**（规格 B）；④ `ChatMessage.modelId` 明确为**可选 / 允许 null**；⑤ 测试文件改为设计文档 §7.3 的 **3 个文件名**；⑥ 新增隐患 **R-0**（`AiSessionRepository` 的 `deviceId` 参数必须可选） |
| v1.2 变更 | ① 方法名按架构师 21:27 定稿改为 `getPrimaryForKp` / `listTeacherSessions`；② 纯函数签名更新为含 `at`/`id` 的记录类型，并新增**双分支排序契约**（§3.1.1.1）；③ 规格 B 记录为**待 team-lead 拍板**（PRD D2 逐字要 `updated_at ASC, id ASC`，team-lead 规格 B 要纯 `id ASC`）→ **M8 夹具做成对两者都稳健**，拍板后无需改测试；④ 边界用例补 E18 / E19；⑤ 合并矩阵补 **M11**（`newDerivedUlid` 双射性）；⑥ 风险点补 P27 / P28 / P29 |

> **本文档所有行号均已逐条打开文件核对**（见 §0.4），未凭印象书写。设计文档的行号引用同此。

---

## 0. 命名与规格对齐表（v1.1）

### 0.1 API 命名 —— 一律以设计文档为准

| 用途 | **最终名称（设计文档口径）** | 签名 | 设计文档位置 |
| --- | --- | --- | --- |
| 老师模式会话列表 | **`listTeacherSessions`**（见 §0.5 的待澄清项） | `Future<List<AiSessionRow>> listTeacherSessions(String kpId)` | 设计文档 §2.3 ④ `:436` |
| 主会话判定 | **`getPrimaryForKp`** | `Future<AiSessionRow?> getPrimaryForKp(String kpId)` | 设计文档 §2.3 ④ `:443` / §2.4 |
| 新建老师模式会话 | `createSessionForKp` | `Future<AiSessionRow> createSessionForKp(String kpId, {String title = ''})` | 设计文档 §2.3 ④ |
| 老数据合并 | **`mergeLegacyExplain`** | `Future<LegacyMergeResult> mergeLegacyExplain(String kpId)` | 设计文档 §2.3 ⑤ |
| 合并结果 | `LegacyMergeResult` / `LegacyMergeOutcome` | `outcome`(`merged`/`skippedNoLegacy`/`failed`)、`chatSessionId`、`explainSessionId`、`movedMessages`、`normalizedOnly`、`error` | 设计文档 §2.3 ⑤ |
| L2 历史组装（**纯函数**） | **`buildSessionContext`** | `String buildSessionContext(List<({String role, String content, DateTime? at, String? id})> turns, {int maxMessages = 12, int maxChars = 0, String header = '【本会话前文】（同一会话内此前的问答，请参考上下文）'})`<br>⚠️ 记录类型**新增 `at`（时间戳）与 `id`（排序用）两个可空字段** → 决定纯函数的**排序分支**（见 §3.1.1） | 设计文档 §4.2 `:906-910`；文件 `lib/features/shared/session_context.dart` |
| 标题派生 | `deriveSessionTitle` | `String deriveSessionTitle({required String storedTitle, required List<ChatMessage> messages, String fallbackTitle = '新对话'})` | 设计文档 §3.5 |
| 讲解消息判别（**唯一判别点**） | `isExplainMessage` | `bool isExplainMessage(ChatMessage m) => m.modelId == 'dify-t6';` | 设计文档 §3.2 / 裁决 15 |
| 消息模型 | `ChatMessage`（**新增可选** `modelId`） | `this.modelId`（**null 合法**：`'dify-t6'`=讲解 / `'dify-t5'`=追问 / `null`=普通） | 设计文档 §2.3 ③ |
| 控制器编排 | `TeacherSessionController` | `bootstrap()` / `createUserSession()` / `ensurePrimarySession()` / `createPrimarySessionWithExplain()` | 设计文档 §2.4 / §3.1 |
| 文案同源常量 | `teacher_session_copy.dart` | 三处删除主会话文案由**同一常量**生成（PRD C11） | 设计文档 §2.4 末 |
| 确定性派生 id | `newDerivedUlid` | `String newDerivedUlid(String sourceId, int millis)` —— 源 id 的**时间部分** + 源 id 随机尾巴**逐字节 +1**（双射 → 必异于源、不同源不撞）→ 合并**天然幂等**（主键冲突即跳过） | 设计文档 §2.6 / §10-G10；`lib/core/id.dart` |

### 0.2 规格 A —— L2 注入规模（team-lead 裁决）

```dart
// 老师模式的取值（唯一常量，可切换）
buildSessionContext(turns, maxMessages: 10, maxChars: 4000, header: <默认>)
```

- **「1 轮」= 1 条 user + 1 条 assistant** → **10 条 = 5 轮**；
- **截断规则**（设计文档 §4.2 伪码 844-863 **已定义**，不再是待确认项）：
  1. 只取 `role ∈ {user, assistant}`；
  2. 条数超限 → **从最老**整条丢弃，保留最近 `maxMessages` 条；
  3. 长度超限 → **从最老的一条开始丢**；
  4. **至少保留最新一条**；若最新一条单独就超预算 → **截断它的内容**（不是整条丢弃）；
  5. **本轮用户问题不在 `turns` 内**（由调用方单独追加）→ **永不裁剪**。
- 预算口径：`budget = maxChars - header.length - 1`（设计文档伪码 852）。
- ⚠️ **设计文档当前有 4 处仍写 12**：`kTeacherContextMaxMessages = 12`（`:290`）、§4.2 末「取 **12**」（`:934`）、时序图（`:219`）、§7.3.1 示例（`:1229`）；而**同文档的调用时序（`:983`）写的是 `maxMessages: 10`** → **设计文档自相矛盾**。本方案按 **team-lead 裁决 = 10** 写；**请架构师把 4 处统一为 10**（改 1 个常量 + 3 处文档字面量，零代码影响）。

### 0.3 规格 B —— 消息排序键（**待 team-lead 最终拍板**；测试已写成对两种口径都稳健）

| 口径 | 排序键 | 出处 | 立场 |
| --- | --- | --- | --- |
| **口径 ①** | `ORDER BY updated_at ASC, id ASC` | **PRD §9 验收 D2（终稿逐字）**：「D2 `explain` → `chat` 合并后，原讲解内容**一条不少**地出现在 `chat` 会话中，且**每条消息保留其原始时间戳**、顺序确定（`updated_at ASC` + `id ASC`）。」<br>设计文档 §2.3 ② `:390` 当前取此口径 | PRD 是**冻结的验收标准**；设计文档按 PRD 口径 |
| **口径 ②** | `ORDER BY id ASC`（**纯 id**） | **team-lead 规格 B 裁决**：「排序键 = 纯 `id ASC`（不是 updatedAt + id 次级）」，理由：**跨端 `updated_at` 不可信**（增量推送用 outbox 创建时间覆盖 envelope 的 `updated_at`，`sync_engine.dart:183`；pull 时 `_hydrate` `sync_engine.dart:744-751` 再覆盖对端行）→ ULID 的毫秒位在 id 内部，**跨端天然一致** | 理由成立；设计文档 §2.3 ② 末与 §10-Q5 已把它列为「**一行改动**」的备选 |

> **两条口径的实际差异只在一种场景出现**：**跨端 pull 之后**看「迁移来的讲解」的位置。
> 口径 ① 依赖 `updated_at` 作主键 → 对端该行 `updated_at` 已被覆盖成**迁移时刻** → 迁移块会**排到流末尾**（块内相对顺序仍正确）；口径 ② 用 id → 两端**完全一致**。
> 本地场景两者**等价**（正常写入路径 `updated_at` 恒由插入时刻派生，与 id 内嵌毫秒同源）。
> → **测试方案的处置：夹具让 `updated_at` 与 `id` 两个序严格一致**，则 M8 在两种口径下**都绿、都有效**；最终口径由 team-lead 拍板后**无需再改测试**（见 §5 M8）。

> ⚠️ **这是本文档唯一一处「PRD 冻结验收标准」与「后裁决」正面冲突**，已上报 team-lead 拍板。**PRD D2 的目的句是「顺序确定」**（deterministic），两种排序键在本地都满足；差异只在跨端 → **建议按口径 ②（`id ASC`）**，并由 team-lead 同步修订 PRD D2 的字面表述。

### 0.4 关键代码锚点（已逐行核对）

| 位置 | 事实 | 影响的测试 |
| --- | --- | --- |
| `teacher_page.dart:78-97` | `_bootstrap()`：读出 `explainMsgs`（`:84`）但 `setState`（`:87-92`）**只写** `_askSessionId`/`_explainSessionId`/`_askMessages`/`_mastery`，**从未回填 `_explainText`** → 讲解「丢失」根因 | T2 |
| `teacher_page.dart:63` | `String _explainText = '';` —— UI 唯一的讲解数据源 | T2 |
| `teacher_page.dart:94-96` | `if (explainMsgs.where((x) => x.role == 'assistant').isEmpty) { _generateExplain(); }` | T2（不重复自动讲解） |
| `teacher_page.dart:154-157` | `final fullQuery = '$ctx\n\n用户问题：$text';` —— **不带任何历史** → 多轮无记忆根因 | **T6（首要目标）** |
| `teacher_page.dart:79-84` | `_bootstrap()` 先 `getOrCreateForKp(t5Ask)`（`:79`）后 `getOrCreateForKp(t6Explain)`（`:82`）—— **两个独立会话** | T3 / T7 |
| `teacher_page.dart:125-130` | 讲解落库 `modelId: 'dify-t6'` | T8 / T11 / N4 |
| `teacher_page.dart:186-191` | 追问落库 `modelId: 'dify-t5'` | T11 |
| `teacher_page.dart:243-249` | `TabBar`「讲解 (T6)」「追问 (T5)」双 Tab | N5（人工 M-03） |
| `teacher_page.dart:313` | 按钮文案 `const Text('重新生成')` → 改为「再讲一次」 | T8 |
| `teacher_page.dart:342` | 空态文案 `'暂无讲解，点「重新生成」。'` → 改为「暂无讲解，点『再讲一次』」 | T2 |
| `teacher_page.dart:483-510` | `_MessageBubble` **只吃 `role` + `content`** → 现结构无法渲染「讲解」标签 | N4 / T11 |
| `ai_session_repository.dart:21-34` | `ChatMessage` 只有 `id/sessionId/role/content/createdAt`，**无 `modelId`** | T11 / N4（关键缺口，已由设计文档 §2.3 ③ 补齐） |
| `ai_session_repository.dart:55-58` | `getOrCreateForKp` 查询：`where(kpId==? & type==?)` + `limit(1)`，**①漏 `deletedAt.isNull()` ②无 `ORDER BY`** | T1 / T3 |
| `ai_session_repository.dart:119` | `listMessages` 排序 `orderBy([OrderingTerm.asc(t.updatedAt)])`，**无 id 次级排序** → 本次补 `id` 次级键（排序键最终口径见 **§0.3**） | T11 / M8 / R-3 |
| `ai_session_repository.dart:172-184` | `listAgentSessions`：`type='chat' AND kp_id IS NULL AND deleted_at IS NULL`，排序 `updatedAt DESC, id DESC` | T7 / T12 |
| `ai_session_repository.dart:189-202` | `renameSession`（写 `title` 列 + `_sync.upsertAiSession`） | T9 |
| `ai_session_repository.dart:205-220` | `clearMessages`（消息软删，**逐条** `upsertAiMessage`） | T9 |
| `ai_session_repository.dart:223-237` | `deleteSession`（会话软删 + `upsertAiSession` + `clearMessages`） | T9 |
| `ai_session_repository.dart:253-260` | `_sessionTypeFor`：T7→`'tutor'`、T5→`'chat'`、T6→`'explain'` | R-2 |
| `agent_page.dart:182-195` | `deriveSessionTitle({storedTitle, messages})`，**:194 兜底硬编码 `return '新对话';`** | **T10 / IC1** |
| `agent_page.dart:722-735` | `_buildSessionContext()`：**:726 取最近 12 条**、**:728 header**、:730 `用户：/AI：` ← **L2 的行为范本**（将被抽成公共纯函数） | **T6 纯函数层** |
| `tables.dart:21` | `DateTimeColumn get updatedAt => dateTime().named('updated_at')();` → Drift 默认 **秒级**精度 | 全部时间断言（§4） |
| `tables.dart:236-250` | `AiSessions` 列：`type/target_ref/title/kp_id(nullable)/model_id(nullable)/tutor_state/difficulty` + SyncMeta；**无 `created_at`** | T3 / R-7 |
| `tables.dart:254-263` | `AiMessages` 列：`session_id/role/content_md/tokens/latency_ms/model_id(nullable)` + SyncMeta；**全库零索引** | T11 |
| `sync_row_map.dart:149-159` | `aiSessionRowToMap`：**含** `type`/`title`/`kp_id`/`deleted_at`；**不含** `model_id`/`tutor_state` | T9 / R-6 |
| `sync_row_map.dart:162-174` | `aiMessageRowToMap`：**含** `model_id`/`updated_at`/`deleted_at` | T9 / T11 |
| `sync_outbox_writer.dart:101-116` | 只有 `upsertAiSession` / `upsertAiMessage`；**全文无 `tombstoneAiSession` / `tombstoneAiMessage`** | T9 / IC5 / G8 |
| `sync_outbox_writer.dart:231-237` | 未接线或**库不一致**时**静默跳过入队** | T9（必须接线同一 db） |
| `ai_provider.dart:59-102` | `AiProvider` 抽象：`id`/`protocol`/`runTask`/`streamChat(query,{conversationId,user,timeout,task,variant})`/`dispose` | **假 Provider** |
| `ai_task_router.dart:57-60` | 非专属任务（T5/T6）**回落 `fallback`** | 假 Provider 接线 |
| `ai_service.dart:82` | `final provider = await router.resolve(task) ?? fallback;` | 假 Provider 接线 |
| `test/agent_features_test.dart:40` | `sessions = AiSessionRepository(db);` —— **若 `deviceId` 改成必填命名参数 → 本行编译失败 → 连带 15 条全红** | **★ R-0（v1.1 新增）** |
| `test/agent_features_test.dart:304` | group `'H：会话管理（仓储）'` | 回归锚点 |
| `test/agent_features_test.dart:305 / 319 / 342 / 359 / 375 / 393 / 408` | H 组 **7 条**用例 | 回归锚点 |
| `test/agent_features_test.dart:311-313` | `getOrCreateForKp(kpId:'kp-1', task: AiTask.t5Ask)` + `listAgentSessions()` 断言 | **§6 R-1 重点复核** |
| `test/agent_features_test.dart:320-321` | 注释：「Drift 的 updated_at 是**秒级**精度，跨秒才能稳定区分先后」→ 用 1.1s 步进 | 时间断言规范 |
| `test/agent_features_test.dart:359-373` | `deriveSessionTitle` 既有行为锁定（无消息→`'新对话'`；超长→长度 25 + 结尾 `'…'`） | **T10 / IC1** |
| `test/ai_task_route_test.dart:38-52` | 仓库既有假 Provider 范式（`_FakeProvider` implements `AiProvider`，**文件内私有**） | **假 Provider 写法范本** |
| `test/ai_job_service_notify_test.dart` | 2 条（P0-1 通知合流，防黑屏） | 回归锚点 |

### 0.5 ⚠️ 一处待澄清（需 team-lead 拍板）

| 项 | 情况 |
| --- | --- |
| 老师模式会话列表方法名 | **设计文档（2026-10-24 21:27 更新版，架构师已定稿）写作 `listTeacherSessions(kpId)`**（`:436`、`:77`、`:152`、`:274`/IC7、`:453`、`:798`、`:1182`）——即**采纳了我原方案的名字**；<br>但 **team-lead 上一条消息的裁决表写 `listSessionsForKp(kpId)`**。<br>→ **本文档按设计文档写 `listTeacherSessions`**（设计文档是实现的唯一依据、且已定稿；若文档与实现不一致 → **测试编译失败**）。<br>→ **请 team-lead 确认**：是把裁决表更新为 `listTeacherSessions`（与设计文档一致），还是要求设计文档改回 `listSessionsForKp`？**二选一，不改测试**。 |
| 主会话判定方法名 | ✅ **已一致**：设计文档 `:443` = `getPrimaryForKp(kpId)`，与 team-lead 裁决表的 `getPrimaryForKp` **方向相反但结论相同**（裁决表是「我的建议 → 设计文档名」，设计文档现取我的建议名）→ **无冲突** |
| 消息排序键 | ⚠️ 见 **§0.3**：PRD D2（冻结）= `updated_at ASC, id ASC`；team-lead 规格 B = 纯 `id ASC`；设计文档现取 PRD 口径。**测试已写成对两者都稳健** → 拍板后**无需改测试** |
| L2 注入规模 | ⚠️ team-lead 规格 A = **10 条 / 5 轮**；设计文档有 4 处仍写 12（`:290`/`:934`/`:219`/`:1229`），其调用时序 `:983` 写 10 → **自相矛盾**，请架构师统一为 10 |
| M6 失败注入接缝 | ⚠️ 设计文档的 `mergeLegacyExplain` 内部 try/catch 返回 `failed`，但**没有可注入失败的接缝** → 「迁移失败」用例不可测。建议把「写入一条新消息」抽成**可覆写的公开方法**（见 §5 M6 末尾建议） |

---

## 1. 测试策略总览

### 1.1 分层设计

本次改造跨三层，且**核心价值（L2 历史注入）横跨纯函数与 UI 两层**，必须分层测试。

| 层 | 测什么 | 为什么放这层 | 覆盖用例 |
| --- | --- | --- | --- |
| **L-A 仓储单测**<br>`test/teacher_session_repo_test.dart` | SQL 过滤语义、软删墓碑过滤、主会话判定、合并迁移的数据正确性、outbox 登记 | 纯数据规则，与 UI/Provider 无关；内存库（`NativeDatabase.memory()`）跑，**毫秒级、可重复、无外部依赖**。合并的字段级不变量（`model_id`/`role`/`content_md`/`updated_at`）在这里才能**逐字段**断言——UI 层看不到这些 | T1, T3, T4, T5, T7, T9, T11, T12 + N3, N8 |
| **L-B 纯函数单测**<br>`test/teacher_session_context_test.dart` | `buildSessionContext`（L2 组装 + 裁剪）、`deriveSessionTitle`（标题派生） | 这两个是**纯函数**（无 DB、无 widget 依赖），才能对「历史是否真的被带上」「裁剪顺序」做**内容级**断言。`buildSessionContext` 被 Agent 与老师模式**共用**（设计文档 §4），纯函数层还要锁住**Agent 侧输出逐字等价**（N2） | **T6 纯函数层**、T10、N1、N2 + §4 全部边界用例 |
| **L-C widget 测试**<br>`test/teacher_page_widget_test.dart` | 页面渲染：历史回填、讲解标签、多轮记忆端到端、「再讲一次」追加、主会话删除接续 | 必须真的跑 `TeacherPage` 的 `initState`/`build`，才能证明「退出重进讲解仍在」（问题 A）这类**状态生命周期**行为。widget 层是唯一能验证「自动讲解不重复触发」「删除主会话自动顺延/补建」的层次 | T2, T3(补建部分), T5(页面序), **T6 端到端层**, T8 + N4, N5, N6, N7 |
| **L-D 人工验收** | 文案逐字一致、交互手势、滚动流畅度、真实模型的连贯性 | 自动化测不了「这句话读起来对不对」「滚得顺不顺」「真模型答得好不好」 | §7 清单 |

### 1.2 必须自动化 vs 适合人工

| 必须自动化（**缺一不可**） | 适合人工（自动化是补充） |
| --- | --- |
| **T6 多轮记忆**（★首要目标）——必须用假 provider 在无真实 Provider 环境下证明「第 3 轮引用第 1 轮」 | 真机连真实模型观察**回答质量/连贯性**（自动化只能证明「历史确实送达」，证明不了「模型答得好」） |
| T1–T5、T7–T12（数据规则，判据明确） | 删除主会话确认弹窗的**逐字文案**（含「下一个会话标题」插值后的整句） |
| 合并迁移的字段级不变量（`model_id`/`role`/`content_md`/`updated_at` 原样保留） | 消息流滚动流畅度（`ListView.builder` 虚拟化的体感） |
| 幂等（重复进入不重复迁移；派生 id 相同 → 主键冲突跳过） | 资源锁「同点另开老师模式」的挡下提示 |
| outbox 逐条登记 + 墓碑 payload 带 `deleted_at` | 托盘计时文案联动 |
| 标题规则三档优先级 | 迁移失败时的 toast 文案与 AppLog 可读性 |
| `model_id` 为 null / 异常值不崩（N4 / IC6 / G13） | 三处删除文案的手感一致性 |

> **判定原则**：**凡是用「能判定真假」的判据，都写进自动化**；凡是需要「人眼看」的（文案好不好、顺不顺），留给人工。

### 1.3 测试文件清单（3 个 + 0 个支撑文件）

**文件名与 T→文件映射完全对齐设计文档 §7.3**（`:1110-1136`），避免工程师按设计文档找文件时对不上。

| # | 路径 | 职责 | 覆盖 | 预计条数 |
| --- | --- | --- | --- | --- |
| 1 | `aimindtree_app/test/teacher_session_repo_test.dart` | 老师模式会话**仓储层 + 老数据合并**：墓碑过滤、主会话判定、列表隔离、合并矩阵、outbox 登记 | T1, T3, T4, T5, T7, T9, T11, T12 + N3, N8 | ~28 |
| 2 | `aimindtree_app/test/teacher_session_context_test.dart` | **纯函数层**：`buildSessionContext`（L2 组装 + 规模裁剪 + 边界）+ `deriveSessionTitle`（标题派生） | **T6 纯函数层**、T10 + N1, N2 + §4 边界 | ~24 |
| 3 | `aimindtree_app/test/teacher_page_widget_test.dart` | **老师模式页 widget**：历史回填、讲解标签容错、多轮记忆端到端、「再讲一次」追加、主会话删除接续 | T2, T3(补建), T5(页面序), **T6 端到端层**, T8 + N4, N5, N6, N7 | ~14 |

**不新建 `test/support/` 目录**：仓库既有假 Provider 一律是**文件内私有**（`test/ai_task_route_test.dart:38-52` 的 `_FakeProvider`、`test/note_editor_selection_test.dart:94`、`test/t15_selection_extract_test.dart:61`）→ 本方案沿用该约定，把 `_FakeProvider` 直接写在 `teacher_page_widget_test.dart` 内（**只有这一个文件需要它**）。

---

## 2. T1–T12 逐条落地表

> 图例：🧪 仓储单测 ｜ 🧬 纯函数单测 ｜ 🖥 widget 测试 ｜ 👤 人工

### T1 — 软删会话后 `getOrCreateForKp` 返回**新会话**（非墓碑行）

| 项 | 内容 |
| --- | --- |
| 层级 | 🧪 仓储单测 |
| 文件 | `test/teacher_session_repo_test.dart` |
| 准备数据 | ① `getOrCreateForKp(kpId:'kp-t1', task: AiTask.t5Ask)` 建一条会话；② `addMessage` 写 1 条消息；③ `deleteSession(id)` 软删（会话行 + 消息行都进墓碑）；④ 再调 `getOrCreateForKp(kpId:'kp-t1', task: AiTask.t5Ask)` |
| 断言点 | ① 返回行 `deletedAt == null`；② 返回行 **`id != 已删会话 id`**（是新会话，不是墓碑）；③ `type == 'chat'`；④ `db.select(db.aiSessions)` 中 `kpId=='kp-t1'` 共 2 行，**恰好 1 行 `deletedAt == null`**；⑤ 新会话 `listMessages` 为空（没有复用已删会话的旧消息）；⑥ `listTeacherSessions('kp-t1')` 只返回新会话 1 条 |
| 依赖 | `getOrCreateForKp` 的查询改为 `WHERE kp_id=? AND type=? AND deleted_at IS NULL ORDER BY id ASC LIMIT 1`（设计文档 §2.3 ① `:311-315`）。**签名 `{required String kpId, required AiTask task}` 必须保持不变**（§6 R-1/H-1） |

### T2 — 同一会话二次进入 → 渲染历史讲解（不经内存变量）

| 项 | 内容 |
| --- | --- |
| 层级 | 🖥 widget 测试 |
| 文件 | `test/teacher_page_widget_test.dart` |
| 准备数据 | 内存库 + `_FakeProvider`（T6 任务返回固定讲解正文 `'讲解正文XYZ'`）；`pumpWidget(TeacherPage(...))` → `pumpAndSettle`；**随后 `pumpWidget` 一个全新的 `TeacherPage` 实例**（同一 db、同一 kp、同一 fake provider） |
| 断言点 | ① 第一个实例：`find.text('讲解正文XYZ')` `findsOne`；② **第二个实例：`find.text('讲解正文XYZ')` 仍 `findsOne`**（现状必然失败：`_explainText` 从不回填）；③ 第二个实例 **`find.textContaining('暂无讲解')` `findsNothing`**（`teacher_page.dart:342`，文案改为「暂无讲解，点『再讲一次』」）；④ `fake.t6Calls` 在第二次进入后**不增加**（锁 A6「主会话已有 assistant 消息时不重复自动讲解」）；⑤ **负对照**：把该会话消息全部软删后第三次进入 → 讲解**不出现**（证明第②条是「从库里读」而非「内存残留」） |
| 依赖 | UI 改为以「会话消息流」为唯一数据源；空态文案改为「暂无讲解，点『再讲一次』」 |

### T3 — 主会话判定：多会话取 `id` 最小者；删主会话后顺延；全删后新建 + 自动讲解

| 项 | 内容 |
| --- | --- |
| 层级 | 🧪 仓储单测（判定）+ 🖥 widget 测试（补建自动讲解） |
| 文件 | `teacher_session_repo_test.dart`（判定）<br>`teacher_page_widget_test.dart`（补建） |
| 准备数据 | 造 **3 条** `kpId='kp-t3'`、`type='chat'` 会话，**id 显式指定**为 `'01AAAA…' < '01BBBB…' < '01CCCC…'`（可控大小）；再逐条软删 |
| 断言点 | ① 3 条时 `getPrimaryForKp('kp-t3')` == `'01AAAA…'`；② 软删 A 后 == `'01BBBB…'`（顺延）；③ 再软删 B 后 == `'01CCCC…'`；④ 全删后返回 `null`；⑤ widget 层：全删后重新进入 → **自动新建一条会话**（`createSessionForKp`）且 **自动生成一条讲解消息**（库中该会话有 1 条 `model_id=='dify-t6'` 的 assistant 消息）；⑥ **反向断言**：`getPrimaryForKp` 与 `getOrCreateForKp` **必须是两个不同方法**（防止用无序查询冒充主会话判定） |
| 依赖 | `getPrimaryForKp(String kpId)`（设计文档 §2.3 ④ / §2.4）；`createSessionForKp`；自动讲解落在 **controller 层**（`TeacherSessionController.ensurePrimarySession()` / `createPrimarySessionWithExplain()`，设计文档 §2.4） |

### T4 — explain→chat 合并：消息全迁、时间戳保留、幂等、失败回退、仅 explain 时 type 归一

| 项 | 内容 |
| --- | --- |
| 层级 | 🧪 仓储单测 |
| 文件 | `test/teacher_session_repo_test.dart` |
| 准备数据 | 见 **§5 合并矩阵** M1–M9 |
| 断言点 | 见 §5 |
| 依赖 | `mergeLegacyExplain(String kpId)` → `Future<LegacyMergeResult>`（设计文档 §2.3 ⑤）；`LegacyMergeOutcome.merged` / `skippedNoLegacy` / `failed` |

### T5 — 加载顺序：先合并后取主会话（explain 行 `id` 更小也不抢主会话）

| 项 | 内容 |
| --- | --- |
| 层级 | 🧪 仓储单测（控制器级编排）+ 🖥 widget 测试（页面真实顺序） |
| 文件 | `teacher_session_repo_test.dart`（控制器级）<br>`teacher_page_widget_test.dart`（页面） |
| 准备数据 | explain 会话 E（**id 更小** `'01AAAA…'`、`type='explain'`、1 条讲解消息）+ chat 会话 C（`id='01BBBB…'`、`type='chat'`、1 条追问消息） |
| 断言点 | ① 进入老师模式后，**主会话 = C**（**不是 E**）——「explain 抢走主会话」的**反证**；② E 的讲解消息已迁入 C；③ E 行 `deletedAt != null`；④ C 的消息流 = `[讲解(更早), 追问(更晚)]` 按 `id ASC` 排序；⑤ widget 层：进入页面后消息流里同时能看到**讲解**与**追问**两条气泡，列表只剩 1 条会话；⑥ **反向断言**：若把「取主会话」写在「合并」之前，④ 会变成「主会话 = E」→ 用例必须红 |
| 依赖 | 编排落在 **`TeacherSessionController.bootstrap()`**：① `mergeLegacyExplain(kpId)` → ② `getPrimaryForKp(kpId)`（设计文档 §2.4 / 时序图 `:164-201`，**顺序硬约束**）。⚠️ 设计文档 §7.3 把 T5 的仓库级用例标在 `teacher_session_repo_test.dart`（「控制器级」）→ 若编排只在 widget 里，仓储层**无法**直接断言顺序 → **建议 controller 的 `bootstrap()` 可被直接驱动**（纯 Dart 类，不依赖 `BuildContext`，设计文档 §2.4 理由 3） |

### T6 — 🔴【最高优先级硬验收】多轮记忆：第 3 轮能引用第 1 轮

> **完整方案见 §3**（本节只给落地摘要）

| 项 | 内容 |
| --- | --- |
| 层级 | 🧬 纯函数单测（主）+ 🖥 widget 端到端（闭环） |
| 文件 | `teacher_session_context_test.dart`（纯函数层）<br>`teacher_page_widget_test.dart`（端到端层） |
| 准备数据 | 3 轮真实对话（6 条消息）作为 `turns`；「记忆锚点」由假 provider **只在第 1 轮**产出 |
| 断言点 | 纯函数层：`turns` 中的**逐字内容**出现在 L2 块里；**本轮问题不在块内**；`turns: []` 时**不含**该内容（负对照）<br>端到端层：第 3 轮的 assistant 气泡**包含锚点**，且**不含**「未携带历史」标记 |
| 依赖 | `buildSessionContext(turns, {maxMessages: 10, maxChars: 4000, header})`（设计文档 §4.2） |

### T7 — 会话隔离：老师模式列表不含 Agent 会话，反之亦然

| 项 | 内容 |
| --- | --- |
| 层级 | 🧪 仓储单测 |
| 文件 | `test/teacher_session_repo_test.dart` |
| 准备数据 | 造 2 条 Agent 会话（`kpId=null`、`type='chat'`）+ 2 条老师会话（`kpId='kp-7'`、`type='chat'`）+ 1 条老师 **explain 残留**（`kpId='kp-7'`、`type='explain'`，模拟合并失败残留）+ 1 条软删的 Agent 会话 |
| 断言点 | ① `listAgentSessions()` 返回**恰好 2 条**（未删的 Agent 会话），每条 `kpId == null && type == 'chat' && deletedAt == null`；② `listTeacherSessions('kp-7')` 返回**恰好 3 条**——含 explain 残留行（**不按 `type` 过滤**，PRD §4.1 / D8），每条 `kpId == 'kp-7' && deletedAt == null`；③ `listTeacherSessions` **不含**任何 Agent 会话；④ 两个列表**交集为空**；⑤ 排序：`updated_at DESC` + `id DESC` 兜底（与 `listAgentSessions` 同口径，设计文档 §2.3 ④ SQL）；⑥ 软删的 Agent 会话不在 `listAgentSessions()` 里 |
| 依赖 | `listTeacherSessions(String kpId)`（**注意 §0.5 的命名待澄清**）；`listAgentSessions()` **一行不改**（IC7 / G20） |

### T8 — 「再讲一次」为追加，历史讲解不被覆盖

| 项 | 内容 |
| --- | --- |
| 层级 | 🖥 widget 测试 |
| 文件 | `test/teacher_page_widget_test.dart` |
| 准备数据 | 预置主会话 + 1 条历史讲解消息（`model_id='dify-t6'`、`content='旧讲解'`）；假 provider 对 T6 任务返回 `'新讲解'` |
| 断言点 | ① 库里该会话的 assistant 消息数 **1 → 2**（**追加**，不是覆盖）；② 两条内容**都在**（`'旧讲解'` 仍可读出，UI 上仍可见）；③ 新消息 `model_id == 'dify-t6'`；④ 新消息写入**当前会话**（当当前会话是**用户自建**会话时也如此——PRD §6 / 设计文档 §3.6）；⑤ 旧消息的 `content_md` / `updated_at` **未被改写**（读原始行比对）；⑥ UI：存在文案为「再讲一次」的按钮，且**不存在**「重新生成」（`teacher_page.dart:313`） |
| 依赖 | 按钮文案改为「再讲一次」；位置在**消息流底部、与输入框同区**、靠右（设计文档 §3.6） |

### T9 — 会话写操作（重命名 / 清空 / 删除 / 迁移）均登记 outbox

| 项 | 内容 |
| --- | --- |
| 层级 | 🧪 仓储单测 |
| 文件 | `test/teacher_session_repo_test.dart` |
| 准备数据 | `SyncOutboxRepo.current = SyncOutboxRepo(db, deviceId: 'test-device')`（**必须与仓储同一个 `db` 实例**，否则 writer 静默跳过 —— `sync_outbox_writer.dart:231-237`）；`tearDown` 里复位 `null` |
| 断言点 | ① `renameSession` → 1 条 `ai_sessions` upsert，payload 含 `title`；② `clearMessages`（2 条消息）→ **2 条** `ai_messages` upsert（**逐条**，不是 1 条）；③ `deleteSession` → 1 条 `ai_sessions` upsert（**payload 含非空 `deleted_at`**）+ 每条消息 1 条 `ai_messages` upsert；④ 合并迁移 N 条 → **N 条** `ai_messages` upsert **+** explain 行 1 条 `ai_sessions` upsert（type 归一**必须走 `upsertAiSession`**，G19）；⑤ payload 键名逐一核对（`sync_row_map.dart:149-174`）：会话 → `id/type/target_ref/title/kp_id/updated_at/version/device_id/deleted_at`；消息 → `id/session_id/role/content_md/tokens/latency_ms/model_id/updated_at/version/device_id/deleted_at`；⑥ ⚠️ **不存在** `tombstoneAiSession`/`tombstoneAiMessage`（G8 明令「禁止臆造这两个 API」）→ 软删传播靠 **upsert payload 里的 `deleted_at`**，断言应是 `op == SyncOp.upsert` 且 `payload['deleted_at'] != null`，**不要**去找 delete op |
| 依赖 | `SyncOutboxRepo.current` 接线（同库约束）；合并流程逐条 `upsertAiMessage`（IC4） |

### T10 — `deriveSessionTitle` 扩展为新增可选参数后，Agent 侧既有行为**原样通过**

| 项 | 内容 |
| --- | --- |
| 层级 | 🧬 纯函数单测 |
| 文件 | `test/teacher_session_context_test.dart` |
| 准备数据 | 无（纯函数） |
| 断言点 | ① `deriveSessionTitle(storedTitle: '', messages: const [])` **== `'新对话'`**（默认兜底不变，`agent_page.dart:194`）；② 新增可选参数 `fallbackTitle: 'X 讲解'` → 返回 `'X 讲解'`；③ **不传** `fallbackTitle` 时仍 `'新对话'`（默认行为**逐字等价**，IC1 / G11）；④ `storedTitle` 非空 → **优先返回它**（即使也传了 `fallbackTitle`）；⑤ 首条 user 消息 >24 字 → 长度 25 且 `endsWith('…')`；⑥ 多行消息只取**首行**；⑦ 老师模式侧 `fallbackTitle: '${kp.name} 讲解'`（设计文档 §3.5 `:777`）；⑧ 合并失败残留的 explain 会话 → 回落 `'${kp.name} 讲解（历史）'`（设计文档 §10-Q3 `:1261`）；⑨ `test/agent_features_test.dart:359-373` **原样通过** |
| 依赖 | `String deriveSessionTitle({required String storedTitle, required List<ChatMessage> messages, String fallbackTitle = '新对话'})`（设计文档 §3.5 `:754`）。⚠️ **只允许新增可选参数；签名与默认行为不得改**（IC1 / G11） |

### T11 — 合并时被移动消息的 `model_id` / `role` / `content_md` / `updated_at` **原样保留**（**可容忍 null**）

| 项 | 内容 |
| --- | --- |
| 层级 | 🧪 仓储单测 |
| 文件 | `test/teacher_session_repo_test.dart` |
| 准备数据 | explain 会话下 3 条消息：`user` / `assistant(model_id='dify-t6')` / `assistant(model_id='dify-t5')`；**另加 1 条 `model_id` 为 `null` 的消息**（模拟老数据 / 非本模块写入） |
| 断言点 | ① 迁移后在 chat 会话下查到 4 条**新**消息；② **逐字段相等**：`role` / `content_md` / `updated_at` 与原行**完全一致**；③ ★ `model_id == 'dify-t6'` 的那条**迁移后仍是 `'dify-t6'`**（**不是**被改成 `'dify-t5'`）；④ ★ **`model_id` 为 `null` 的那条，迁移后仍为 `null`** —— 断言写成**可容忍 null** 的形式：`expect(newRow.modelId, sourceRow.modelId)`（**不要**写成 `expect(newRow.modelId, isNotNull)` 或 `expect(newRow.modelId, 'dify-t5')`）；⑤ 新行 `session_id == chatSessionId` 且 **`id != 原行 id`**（**复制 + 软删原行**，不是改 `session_id` —— PRD R1）；⑥ 原行 `deletedAt != null`（软删）且**行仍在库**（行数不变）；⑦ 迁移后 chat 会话的消息流按 **`id ASC`** 排序稳定；⑧ **`isExplainMessage` 容错**：对 `modelId == null` 的消息调用 `isExplainMessage` → 返回 `false` 且**不抛异常**（IC6 / G13） |
| 依赖 | `ChatMessage.modelId` 为**可选**字段（`this.modelId`，null 合法，设计文档 §2.3 ③）；`isExplainMessage` 是**全仓唯一判别点**（设计文档 §3.2 `:682`）。⚠️ `ChatMessage` 的**既有构造参数必须全部保持可选/默认值**（§6 R-4） |

### T12 — `listAgentSessions()` 过滤语义与返回结果**零变化**；老师模式走新增的 `listTeacherSessions(kpId)`

| 项 | 内容 |
| --- | --- |
| 层级 | 🧪 仓储单测 |
| 文件 | `test/teacher_session_repo_test.dart` |
| 准备数据 | 4 类行：① Agent 会话（`kpId=null`,`chat`）×2；② 老师会话（`kpId='kp-12'`,`chat`）；③ 老师 **explain 残留**（`kpId='kp-12'`,`explain`）；④ 软删的 Agent 会话 |
| 断言点 | ① `listAgentSessions()` 返回**恰好 2 条**，且每条满足 `type=='chat' && kpId==null && deletedAt==null`；② **显式断言** explain 残留行**不在** Agent 列表里（因 `kp_id` 非空）；③ `listTeacherSessions('kp-12')` 返回**恰好 2 条**（chat + explain 残留），且**不含** Agent 会话；④ `listTeacherSessions('kp-12')` **不含**软删行；⑤ 两个列表**交集为空**；⑥ `listAgentSessions()` 的**排序**仍是 `updated_at DESC, id DESC`；⑦ 回归锚点：`test/agent_features_test.dart` 的 7 条 H 组用例**原样通过** |
| 依赖 | `listTeacherSessions(String kpId)`（**注意 §0.5 命名待澄清**）；`listAgentSessions()` **一行不改**（IC7 / G20） |

---

## 3. ★ T6 详细验证方案（本次改造的核心价值）

> **PRD §1.4 价值定位**：本次改造的真正价值 = **补上多轮记忆**。「合并两个 Tab」只是表象。**T6 不通过，其余用例全绿也不算本次改造成功。**
> **设计文档 §7.3.1**：T6 **必须两层都写**，缺任一层都算未覆盖。

### 3.1 纯函数层（🧬 `test/teacher_session_context_test.dart`）

#### 3.1.1 前提：L2 组装必须是**可单测的纯函数**

设计文档 §4.2 已定契约（文件 `lib/features/shared/session_context.dart`）：

```dart
String buildSessionContext(
  List<({String role, String content, DateTime? at, String? id})> turns, {
  int maxMessages = 12,     // 老师模式传 10（规格 A：5 轮）
  int maxChars = 0,         // 老师模式传 4000（规格 A）
  String header = '【本会话前文】（同一会话内此前的问答，请参考上下文）',
});
```

- `turns` = 当前会话**此前**的 user/assistant 消息，**不含本轮问题** → 本轮问题**永不裁剪**；
- **历史快照必须在写入本轮 user 消息之前取**（设计文档 T02 要点 ⑤）→ 否则本轮问题会同时出现在前文块与 query 里；
- Agent 侧调用保持默认 `maxMessages=12, maxChars=0` → **输出与现状逐字相同**（N2 锁）。

#### 3.1.1.1 排序分支契约（架构师新增的 `at` / `id` 两个可空字段）

纯函数的记录类型新增了 `at`（时间戳）与 `id`（排序用），由此产生**两个分支**：

| 输入 | 行为 | 为什么 | 谁走这条分支 |
| --- | --- | --- | --- |
| **所有**条目的 `at` 都非空 | 函数内部按 **`(at ASC, id ASC)` 自行排序** | 老师模式的数据来自 `listMessages`（已排好序且带 `at`/`id`）→ **自排幂等** | 老师模式 |
| 存在任一条目 `at == null` | **保持传入顺序**（不排序） | Agent 侧的内部消息类型 `_Msg`（`agent_page.dart:260-264`）**没有时间戳字段** → 必然 `at == null` → **Agent 现状行为逐字不变**（控制 Agent 回归风险，设计文档 §9.1-R2） | Agent |

> **这条契约对测试的直接要求**：E10 必须写成**两条分支各一条断言**（见 §4 E10），否则「Agent 兼容分支」无人守护 → 将来有人把纯函数改成**无条件排序**，Agent 侧历史顺序会静默改变，而现有测试**测不出来**。

#### 3.1.2 断言「历史确实被带上」——**内容特征，不是字符串长度**

老师模式取值：`maxMessages: 10, maxChars: 4000`。

| # | 断言 | 写法要点 | 防的是什么 |
| --- | --- | --- | --- |
| A1 | **逐字包含**第 1 轮**用户原文** | `expect(l2, contains('反向传播的例子里有数字 7.5'))` —— 用**完整原句**，不要用 `'7.5'`（`7.5` 可能出现在 L1 定义里） | 只断言长度 / 只断言 L1 里也有的词 |
| A2 | **逐字包含**第 1 轮**AI 回答原文** | `expect(l2, contains('梯度由链式法则逐层计算'))` | 只断言用户侧，漏了 assistant 侧 |
| A3 | ★ **本轮问题不在前文块内** | `expect(l2, isNot(contains('刚才那个数是多少')));` | 本轮问题既在前文块又被裁（设计文档 §7.3.1 `:1155` 同款断言） |
| A4 | **角色标注**：`用户：` / `AI：` | `expect(RegExp(r'^用户：', multiLine: true).allMatches(l2).length, userCount)`；`RegExp(r'^AI：', multiLine: true).allMatches(l2).length == assistantCount` | 历史内容塞进无法区分角色的纯文本 |
| A5 | **前文块 header 存在** | `expect(l2, startsWith('【本会话前文】'))` | 注入块缺失 / 格式漂移 |
| A6 | ★ **负对照（关键，防假阳性）** | 同样 header、同样 `maxMessages/maxChars`，但 `turns: []` → `expect(l2, isEmpty)`（设计文档伪码第 3 步：`picked.isEmpty → return ''`） | 证明「带上历史」**确实是 turns 造成的**，不是 L1/提示词/巧合里有同样的字 |
| A7 | **多轮可见** | 把 3 轮共 6 条消息当 `turns` → 第 1 轮内容**仍在** l2 里（10 条窗口内） | 只测 1 轮就以为多轮成立 |
| A8 | **越老越先被丢** | 造 20 条 `turns` → `expect(l2, isNot(contains('OLDEST-MARK'))); expect(l2, contains('NEWEST-MARK'));` | 裁剪方向反了（从最近开始丢） |
| A9 | **长度上限** | `expect(l2.length, lessThanOrEqualTo(4000 + header.length));`（设计文档 §7.3.1 `:1156`） | 裁剪完全没生效 |

> **判定原则**：A1–A9 全部是**内容级**断言。**禁止**用 `expect(l2.length, greaterThan(200))` 作为「历史被带上」的证据——长度可以由 header + 角色前缀撑起来。

#### 3.1.3 规模与裁剪的精确断言（规格 A）

| 场景 | 断言 |
| --- | --- |
| `turns` 恰好 **10 条**（5 轮） | **全部保留**（`≤` 含边界）；`OLDEST-MARK` 在 |
| `turns` **11 条** | 保留最近 10 条；**最老 1 条被丢**（`isNot(contains)`） |
| `turns` **20 条** | 只保留最近 **10 条**；`用户：` 行数 == 10 条里的 user 条数 |
| 总长恰好 **4000** | **全部保留** |
| 总长 **4001** | **最老的一条被丢** |
| **最新一条单独就超 4000** | **截断它的内容**（不是整条丢弃）→ 该条**仍以 `AI：`/`用户：` 开头存在**；`l2.length <= 4000 + header.length`（设计文档伪码 858-860） |
| `turns` 含 **system 角色** | **不注入** system（伪码第 1 步：`role ∈ {user, assistant}`）→ system 内容 `isNot(contains)` |
| `turns` 含**空内容**消息 | **不抛异常**；该条要么被跳过、要么输出为空行（**待设计确认**：伪码未定义空内容过滤）→ 断言「不抛异常」+ 「不出现连续两个空 `用户：` 行」 |
| **排序分支**（`at` / `id`） | ① `at` 全非空 + 乱序传入 → 输出按 `(at ASC, id ASC)` **自排**；② 存在 `at == null` → **保持传入顺序**（Agent 兼容分支）→ 详见 §3.1.1.1 与 §4 E13 / E18 / E19 |

### 3.2 端到端层（🖥 `test/teacher_page_widget_test.dart`）

#### 3.2.1 假 Provider（文件内私有，沿用仓库既有范式）

仓库既有假 Provider 范式见 `test/ai_task_route_test.dart:38-52`（`_FakeProvider` implements `AiProvider`）、`test/note_editor_selection_test.dart:94`、`test/t15_selection_extract_test.dart:61`。

**核心设计**：「记忆锚点」**只由假 Provider 在第 1 轮产出**，第 3 轮能不能复述它，就等价于「第 1 轮内容有没有进到第 3 轮的 query」。

```dart
/// 假 AI Provider：记录收到的 query；并按「记忆锚点」回显。
///
/// 锚点只能由本 Provider 在第 1 轮的回答里产出 —— 因此「第 3 轮气泡里
/// 出现锚点」严格等价于「第 1 轮内容被注入进了第 3 轮的 query」。
class _FakeProvider implements AiProvider {
  _FakeProvider({this.explainText = '讲解正文XYZ'});

  /// 按顺序记录每次收到的 query（T6 讲解 + T5 追问混在一起）。
  final List<String> queries = [];
  int t6Calls = 0;
  int t5Calls = 0;
  String explainText;

  /// 「记忆锚点」：只会出现在第 1 轮本 Provider 产出的回答里。
  static const String anchor = 'ALPHA-7.5';

  @override
  String get id => 'fake';
  @override
  String get protocol => 'fake';

  @override
  Stream<AiChunk> streamChat(
    String query, {
    String? conversationId,
    String? user,
    Duration timeout = const Duration(seconds: 120),
    AiTask? task,
    String? variant,
  }) async* {
    queries.add(query);
    if (task == AiTask.t6Explain) {
      t6Calls++;
      yield AiChunk(delta: explainText, done: true);
      return;
    }
    t5Calls++;
    // 只有当本轮 query 里真的带着锚点时，才「记得」——否则明说没带。
    final hit = query.contains(anchor);
    yield AiChunk(
      delta: hit ? '我记得你说过 $anchor' : '（本轮未携带历史）',
      done: true,
    );
  }

  @override
  Future<AiTaskResult> runTask(
    AiTask task,
    Map<String, dynamic> inputs, {
    String? user,
    Duration timeout = const Duration(seconds: 120),
    String? variant,
  }) async =>
      const AiTaskResult(content: '{}');

  @override
  void dispose() {}
}
```

**接线**（`ai_task_router.dart:57-60` 对 T5/T6 回落 `fallback`；`ai_service.dart:82` 再兜一层）：

```dart
final fake = _FakeProvider();
final ai = AiService(router: AiTaskRouter(providers: const {}, fallback: fake));
```

> ⚠️ `AiService.run()` 路径（T1/T3 结构化任务）本方案不涉及；`runTask` 返回空串即可。**不需要**真实 HTTP、**不需要** llm_server、**不需要**任何 Provider 配置。

#### 3.2.2 端到端断言写法

```dart
testWidgets('T6：第 3 轮能引用第 1 轮的内容（多轮记忆生效）', (tester) async {
  final fake = _FakeProvider();
  await tester.pumpWidget(MaterialApp(home: TeacherPage(
    kp: kp, sessions: sessions,
    ai: AiService(router: AiTaskRouter(providers: const {}, fallback: fake)),
    repo: repo, jobs: jobs,
  )));
  await tester.pumpAndSettle();

  // —— 第 1 轮 ——
  await tester.enterText(find.byType(TextField), '给我一个反向传播的例子');
  await tester.tap(find.byTooltip('发送'));
  await tester.pumpAndSettle();
  // 假 Provider 在第 1 轮的回答里种下「记忆锚点」
  expect(find.textContaining(_FakeProvider.anchor), findsOne);

  // —— 第 2 轮 ——
  await tester.enterText(find.byType(TextField), '那它的梯度怎么回传');
  await tester.tap(find.byTooltip('发送'));
  await tester.pumpAndSettle();

  // —— 第 3 轮：问「刚才那个数是多少」（本身不含锚点）——
  await tester.enterText(find.byType(TextField), '刚才那个数是多少');
  await tester.tap(find.byTooltip('发送'));
  await tester.pumpAndSettle();

  // ★ 断言 A（直接、无歧义）：第 3 轮的 query 逐字带着第 1 轮的内容
  final q3 = fake.queries.last;
  expect(q3, contains(_FakeProvider.anchor));
  // ★ 断言 A'：前文块确实注入了
  expect(q3, contains('【本会话前文】'));
  // ★ 断言 A''：本轮问题也在 query 里
  expect(q3, contains('刚才那个数是多少'));

  // ★ 断言 B（端到端语义）：第 3 轮的 assistant 气泡真的复述了锚点
  expect(find.textContaining(_FakeProvider.anchor), findsNWidgets(2));

  // ★ 断言 C（负对照）：不是「没带历史」的兜底回答
  expect(find.textContaining('本轮未携带历史'), findsNothing);
});
```

**为什么这套断言是「证明」而不是「迹象」**（因果链闭合）：

1. `ALPHA-7.5` 这个字符串**全仓库只有假 Provider 会在第 1 轮产出**；
2. 它的唯一传播路径是：假 Provider 第 1 轮回答 → 落库为 assistant 消息 → 第 2/3 轮发问时被 L2 注入进 query；
3. 因此「第 3 轮气泡出现 `ALPHA-7.5`」 ⟺ 「第 1 轮内容进入了第 3 轮的 query」；
4. **当前实现下必然失败**：`teacher_page.dart:154-157` 只发 L1 + 当前问题 → 第 3 轮 query 里没有锚点 → 气泡只会是「（本轮未携带历史）」→ **断言 B/C 红**。

**配套的「反向证据」用例（强烈建议同文件再加一条）**：
用一个「丢弃历史」的假 Provider（`query.contains(anchor)` 恒为 false，或把 `maxMessages` 设为 0）跑同样的三轮 → 断言第 3 轮气泡**必须**是「（本轮未携带历史）」。⇒ 证明断言 B **不是恒真的**。

**⚠️ 集成层的前置条件**（设计文档 §7.3.1 `:1175-1176`）：控制器/页面必须把 `AiService` 的调用点**收敛成唯一一处**（`TeacherSessionController` 或页面的 `_chat`），否则集成层无法稳定断言「每轮发出的 query」。

#### 3.2.3 ⚠️ 为什么**只靠真机手测无法证明** T6

| 现象 | 真机手测能否判定 |
| --- | --- |
| 「AI 答得挺好、好像记得」 | ❌ **不能**。模型可能**碰巧猜对**、可能只是泛泛而谈、可能用户在提问里自己带了数字 |
| 「App 确实把历史发出去了」 | ❌ **不能**。真机上看不到发给 provider 的 query；llm_server 无状态（`llm_server/routers/chat.py:36-38`），回包也不回显前文 |
| 「第 3 轮引用了第 1 轮的 7.5」 | ❌ **不能证明因果**。无法排除「模型蒙对」「提示词模板里恰好含 7.5」「用户第 3 轮自己写了 7.5」 |
| 「第 1 轮内容确实进了第 3 轮的 query」 | ✅ **能**——但只能靠假 Provider 记录 query 来判定 |

**结论**：**T6 必须自动化**。真机手测只能作为**补充观察**（真实模型的连贯性、措辞质量），**不能**作为 T6 的验收依据。PRD §9.2 的 🔴 标注在这一点上是成立的：**「T6 不通过，其余用例全绿也不算本次改造成功」**。

### 3.3 T6 的三层落点汇总

| 层 | 用例 | 判据 |
| --- | --- | --- |
| 🧬 纯函数 | `buildSessionContext(turns, maxMessages: 10, maxChars: 4000)` 内容级断言 A1–A9 + §3.1.3 规模断言 | 「历史确实被带上了」被**证明** |
| 🖥 端到端（假 Provider） | 3 轮对话 + 锚点回显 | 「第 3 轮能引用第 1 轮」被**证明**（因果闭合） |
| 👤 人工 | 真机 3 轮追问 | 真实模型**答得好不好**（补充观察，非验收依据） |

---

## 4. 历史注入的边界用例清单（L2 注入）

> 全部落在 `test/teacher_session_context_test.dart`（🧬 纯函数层）。
> **时间/长度断言规范**：`updated_at` 是**秒级**精度（`tables.dart:21` + `agent_features_test.dart:320-321`）→ 消息顺序断言**改用 `id ASC`**（规格 B）即可**免等待**（设计文档 G17：「新测试遵守 1.1s 时间步进规则（**或改用 `id` 排序免等待**）」）；会话列表排序（`updated_at DESC`）仍需 1.1s 步进。

| # | 边界 | 输入 | 期望结果（可判定） |
| --- | --- | --- | --- |
| E1 | **历史为空** | `turns: []` | 返回 **`''`**（空串，不产生空的前文段落——设计文档伪码第 3 步）；调用方据此**不注入** L2 段（query = L1 + 指令，与今天等价） |
| E2 | **条数超 N** | 20 条，`maxMessages: 10` | 只保留**最近 10 条**；`isNot(contains('OLDEST-MARK'))` 且 `contains('NEWEST-MARK')`；`用户：` 行数 == 10 条中的 user 条数 |
| E3 | **恰好等于 N** | 10 条 | **全部保留**（`≤` 含边界） |
| E4 | **N+1 条** | 11 条 | 保留最近 10 条；**最老 1 条被丢**（off-by-one 防线） |
| E5 | **总长超 4000** | 10 条 × 1000 字 | 从**最老**整条丢弃，直到 ≤4000；`l2.length <= 4000 + header.length`；最老的不在；最近的连续若干条在 |
| E6 | **恰好 4000 / 4001** | 两组 | 4000 → **全部保留**；4001 → **最老一条被丢** |
| E7 | **最新一条单独超限** | 1 条 8000 字 | **截断它的内容**（不是整条丢弃，设计文档伪码 858-860）→ 该条**仍存在**（以 `用户：`/`AI：` 开头）；`l2.length <= 4000 + header.length` |
| E8 | **本轮问题超长** | 本轮问题 5000 字 | **本轮问题永不被裁**（它**不在 `turns` 内**）；此时历史被裁到 0；断言 query 侧 `contains(question)` 完整 |
| E9 | **历史含空消息** | `content = ''` 或 `'   '` | **不抛异常**；**待设计确认**（伪码未定义空内容过滤）→ 断言「不抛异常」+「不出现连续两个空 `用户：` 行」 |
| E10 | **历史含 system 角色** | `role = 'system'` | **不注入** system（伪码第 1 步）；断言 system 内容 `isNot(contains)` |
| E11 | **`model_id` 为空 / 异常值** | `modelId = null` / `'gpt-4o'` / `'unknown'` | **不影响历史注入**（判别只看 `role`）；断言 query 正常拼装、**不抛异常**；且该消息在 UI 上**不**被渲染成「讲解」标签（N4） |
| E12 | **老数据合并后的消息序列作为历史** | 合并后消息流 = `[讲解(assistant,dify-t6), user, assistant(dify-t5), user, assistant]` | 注入时**包含**那条讲解消息（PRD B3「AI 能引用自己刚讲过的内容」）；断言 l2 含**讲解正文原文** |
| E13 | **历史未按时间序传入**（两条分支） | ① `at` 全非空的**乱序**历史<br>② `at == null` 的历史 | ① **`at` 全非空** → 输出按 `(at ASC, id ASC)` **自行排序**（乱序传入也稳定）→ 断言：`indexOf(第2条) < indexOf(第1条)`（按时间序）；<br>② **存在 `at == null`** → **保持传入顺序**（不排序）→ 断言：`indexOf(第1条) < indexOf(第2条)`（与传入顺序一致）<br>⚠️ **第②条是 Agent 兼容分支的护栏**（`agent_page.dart:260-264` 的 `_Msg` 无时间戳字段）→ 少了它，将来有人改成「无条件排序」会静默改变 Agent 侧历史顺序而测不出来 |
| E14 | **历史与本轮问题重复** | 本轮问题 == 历史某条 | 本轮问题**不在 `turns` 内** → l2 里只有 1 份；query 里出现 2 份（前文块 + 当前问题段）→ 断言 `l2` 中该内容出现 1 次 |
| E15 | **L1 本身超长** | `kp.definition` = 3000 字 | **L1 永不裁**（L1 不在 `buildSessionContext` 的职责内）；历史被裁到 0；断言 `kp.definition` **完整**在 query 里 |
| E16 | **角色标注格式** | 任意 | 与 `agent_page._buildSessionContext()` 同形：`用户：xxx` / `AI：xxx`，每行一条；断言两个 `RegExp` 命中数 == 对应消息条数 |
| E17 | **Agent 侧等价性**（N2） | `buildSessionContext(turns)`（默认 12 / 不限长） | 输出与迁移前 `agent_page._buildSessionContext()` **逐字相同**（把旧实现作为测试内参考实现）→ 断言两个字符串 `==` |
| E18 | **`at` / `id` 字段缺失不崩** | 条目只给 `role` + `content`（`at`/`id` 均 null） | **不抛异常**；输出按「保持传入顺序」分支生成；断言：内容齐全 + 顺序 == 传入顺序 |
| E19 | **`at` 全非空但 `id` 为 null** | `at` 有值、`id` 为 null | **不抛异常**；排序退化为**只按 `at`**（同 `at` 时保持稳定）；断言：不同 `at` 的条目仍按时间序 |

---

## 5. 老数据合并的专项测试矩阵

> 全部落在 `test/teacher_session_repo_test.dart`（🧪 仓储单测）。
> 造数要点：会话 id **显式指定**（`'01AAAA…' < '01BBBB…'`）；消息 id **显式指定或用 `newDerivedUlid`**；消息顺序断言用 **`id ASC`**（规格 B）。

| # | 场景 | 前置数据 | 期望结果（断言） |
| --- | --- | --- | --- |
| **M1** | **explain-only**（只有 explain 没有 chat） | `kpId='kp-m1'` 唯一一条 `type='explain'` 会话，1 条 `model_id='dify-t6'` 的讲解消息 | ① `outcome == LegacyMergeOutcome.merged` 且 `normalizedOnly == 1`（**仅做 type 归一**，设计文档 §2.5 伪码 487-489）；② 该行 `type` **归一为 `'chat'`**、`version` +1，登记 1 条 `ai_sessions` outbox（**G19：归一必须走 `upsertAiSession` 入队**，否则对端永远停在 `type='explain'`）；③ **不做消息迁移**（讲解消息仍在原行、仍是 1 条）；④ `getPrimaryForKp('kp-m1')` == 该行；⑤ `listTeacherSessions('kp-m1')` 返回 **1 条**；⑥ 讲解消息的 `model_id` 仍为 `'dify-t6'` |
| **M2** | **chat-only** | `kpId='kp-m2'` 唯一一条 `type='chat'` 会话，2 条消息 | ① `outcome == LegacyMergeOutcome.skippedNoLegacy`；② **零写入**（outbox 长度**不变**）；③ 消息数仍 2；④ `getPrimaryForKp` == 该行；⑤ `listTeacherSessions` 返回 1 条 |
| **M3** | ★ **两者都有，且 explain 的 `id` 更小** | E：`id='01AAAA…'`、`type='explain'`、1 条讲解消息（`id` 更早）；C：`id='01BBBB…'`、`type='chat'`、1 条追问消息（`id` 更晚） | ① E 的消息**复制**迁入 C（**新行 id != 原行 id**）；② E 原消息行 `deletedAt != null` 且**行仍在库**（行数不变）；③ E 会话行 `deletedAt != null`；④ ★ **主会话 = C**（**不是 E**）——「explain 抢走主会话」的**反证**；⑤ `listTeacherSessions('kp-m1')` 只返回 **C 一条**；⑥ C 的消息流 = `[讲解, 追问]` 按 **`id ASC`** 排序（讲解在前）；⑦ 每条被移动消息**单独**登记 `ai_messages` outbox（1 条消息 → 1 条 outbox）；⑧ `outcome == merged`、`movedMessages == 1`、`chatSessionId == C.id`、`explainSessionId == E.id` |
| **M4** | **两者都有，且 chat 的 `id` 更小**（现状默认：`_bootstrap()` 先 T5 后 T6 → chat 更早创建，见 `teacher_page.dart:79-83`） | C：`id='01AAAA…'`、`chat`、1 条追问；E：`id='01BBBB…'`、`explain`、1 条讲解 | 合并结果与 M3 **一致**：主会话 = C；消息迁入 C；E 软删。⇒ 证明**合并方向只看 `type`，与 id 大小无关**（M3 + M4 一起才构成完整覆盖） |
| **M5** | ★ **幂等：已合并过**（E 已软删） | 在 **M3 执行后**的状态上再次调用 `mergeLegacyExplain` | ① `outcome == LegacyMergeOutcome.skippedNoLegacy`（**无未删 explain 行 → 直接返回**，设计文档伪码 481-482）；② **消息 id 集合完全相同**：`expect(idsAfter, equals(idsBefore))`；③ E 仍 `deletedAt != null`；④ **不产生新的 outbox 记录**（长度不变）；⑤ 主会话仍是 C；⑥ 消息内容与顺序不变 |
| **M6** | ★ **迁移失败** | 注入一个会让迁移抛异常的条件（**待设计确认**：见下方「测试注入点」建议） | ① `outcome == LegacyMergeOutcome.failed` 且 `error != null`（**不抛异常**，设计文档 §2.3 ⑤「失败不抛异常、不删数据」）；② **不丢数据**：E 行仍在库、`deletedAt == null`、其消息仍在、内容不变；③ **不阻断进入**：主会话仍能取到（建议 = C）；④ ★ E **仍出现在 `listTeacherSessions`**（PRD D8：残留行必须可见、可点进去看原讲解）；⑤ 有**可检索日志** + **用户提示**（日志可断言 `AppLog`；toast 走人工验收 M-17）；⑥ **不产生半截数据**：不得出现「消息已复制但 E 未软删」的中间态 |
| **M7** | ★ **消息带 `model_id='dify-t6'`** | M3 的讲解消息 | 迁移后该消息 **`model_id` 仍为 `'dify-t6'`**（**不是**被改成 `'dify-t5'`）；UI 上渲染「讲解」标签（widget 层配合断言 N4） |
| **M8** | ★ **消息顺序（排序键口径待拍板 → 夹具做成对两者都稳健）** | E 下 3 条消息，**`id` 显式指定**为 A<B<C（字典序递增）**且 `updated_at` 也显式指定为同一递增序**（两序**一致**） | 迁移后 chat 会话的 `listMessages` 顺序 == `['A','B','C']`；<br>① **新派生的 id 严格递增**（`newDerivedUlid` 保证，设计文档 §2.5 伪码 502-505）；<br>② **每条新消息的 `updated_at` == 对应源行的 `updated_at`**（原样保留，IC3 / D9）；<br>③ 因为**夹具让 `updated_at` 与 `id` 两个序严格一致**，本用例在 **§0.3 的两种排序键口径下都成立**（`updated_at ASC, id ASC` 与纯 `id ASC` 结果相同）→ **team-lead 拍板哪个口径都无需改测试**；<br>④ ⚠️ **禁止**只指定 `id` 而让 `updated_at` 相同或乱序 —— 那样断言在两种口径下**结果不同**，会变成「口径赌注」而非回归网 |
| **M11** | ★ **派生 id 的双射性**（`newDerivedUlid`） | 2 条源消息 | ① 派生 id **必异于源 id**（不撞源行）；② **不同源派生出不同 id**（不撞车）；③ 派生 id 的**时间部分** == 源 id 的时间部分（毫秒同源，跨端一致，设计文档 §2.6）；④ 同一源 id + 同一毫秒 → **两次派生结果完全相同**（确定性 → 合并幂等的前提，设计文档 §10-G10） |
| **M9** | **explain 行已是墓碑** | `E.deletedAt != null`、C 存在 | ① `outcome == skippedNoLegacy`；② **不触发迁移**（不产生新行）；③ 不产生新 outbox；④ 主会话 = C；⑤ `listTeacherSessions` 只返回 C |
| **M10** | **N3 · 合并幂等（崩溃重试）** | 同一批源消息**合并两次**（模拟第一次崩溃后重试） | 派生 id **确定性相同**（设计文档 G10：双射 +1 变换）→ 第二次走 `if NOT EXISTS(...)` 分支**跳过**（伪码 506）；断言：chat 会话消息条数**不变**、id 集合**完全相同**、**无重复行** |

> **M6 的「测试注入点」建议（待设计确认）**：设计文档的 `mergeLegacyExplain` 内部 try/catch 并返回 `failed`，但**没有留出可注入失败的接缝** → M6 难以稳定构造。**建议**把「写入一条新消息」抽成**可覆写的公开方法**，例如
> `Future<void> insertMessageRow(AiMessagesCompanion c)`（或 `Future<String> copyMessageToSession({required AiMessageRow source, required String targetSessionId})`），
> 测试用子类覆写抛错。**若不提供接缝**，M6 只能靠「构造必然失败的输入」间接触发（SQLite 对 `content_md` 无长度限制 → 很难触发 DB 约束失败），**该用例将退化为不可测** → **请在实现前确认这一接缝**。

---

## 6. 回归与安全网清单

### 6.1 必须**原样通过**（零改动，不得因重构而变红）

| 文件 / 范围 | 条数 | 说明 |
| --- | --- | --- |
| `test/agent_features_test.dart` 全文件 | **15**（实测） | D 组 3 + G 组 5 + **H 组 7** |
| └ `test/agent_features_test.dart:304-418` group `'H：会话管理（仓储）'` | **7**（:305/:319/:342/:359/:375/:393/:408） | 会话管理仓储行为的既有安全网 |
| `test/ai_job_service_notify_test.dart` | **2**（实测） | P0-1 通知合流（防 `setState during build` 黑屏）—— 老师模式页仍会调 `holdInteractive` |
| `test/sync_outbox_wiring_test.dart` | 全文件 | 上行接线（T9 的基础设施） |
| `test/sync_row_map_test.dart` | 全文件 | 同步 payload 结构不变（PRD F3） |
| `test/schema_migration_test.dart` | 全文件 | **未新增表结构变更**（PRD F4） |
| **全量 `flutter test`** | **598/598 通过**（2026-10-24 实测） | 改造后必须 **≥ 598 + 新增条数**，且 **0 失败**；且 **不新增 INFO**（设计文档 G17） |

### 6.2 可能因语义变更需要**复核**的既有测试（重点结论）

#### ★ R-0（v1.1 新增）`AiSessionRepository` 的 `deviceId` 参数必须**可选**

- 设计文档裁决 11（G15）：`deviceId` 用真实设备 id，兜底**空串 `''`**，**禁止再出现 `'local-dev'` 字面量**；设计文档 §7.2 写明「**T04 改 1 行**：`AiSessionRepository(db)` → `AiSessionRepository(db, deviceId: 'test-device')`」。
- ⚠️ **风险**：若把 `deviceId` 做成**必填命名参数** → `test/agent_features_test.dart:40` 的 `AiSessionRepository(db)` **编译不过** → **该文件 15 条用例全部连带失败**（含与本次无关的 D 组、G 组）。
- **结论/约束**：`AiSessionRepository(AppDatabase db, {String deviceId = ''})` —— **`deviceId` 必须是带默认值的可选命名参数**。这样既有测试**一行不改**也能编译通过，与「既有测试原样通过」口径一致；若工程师坚持必填，则**必须**同步改 `agent_features_test.dart:40`（并在提交信息里注明这 1 行改动的原因）。

#### ★ R-1 `getOrCreateForKp` 语义变更对 `agent_features_test.dart:311-313` 的影响

**该用例原文**（`test/agent_features_test.dart:305-317`）：

```
:311   await sessions.getOrCreateForKp(kpId: 'kp-1', task: AiTask.t5Ask);
:313   final list = await sessions.listAgentSessions();
:314   expect(list.map((s) => s.id), <String>[b.id, a.id]);
:315   expect(list.every((s) => s.kpId == null), isTrue);
:316   expect(list.every((s) => s.deletedAt == null), isTrue);
```

**结论：✅ 不受影响，可以原样通过。** 理由三条：

1. 该断言过滤的是 **`listAgentSessions()`**（`ai_session_repository.dart:172-184`），过滤条件是 `type='chat' AND kp_id IS NULL AND deleted_at IS NULL`。老师模式会话 `kp_id='kp-1'` **天然被 `kp_id IS NULL` 排除** → 与 `getOrCreateForKp` 内部怎么改**完全无关**。
2. 给 `getOrCreateForKp` 的查询补 `deleted_at IS NULL`，只是让它**不再捞回墓碑行**；`:311` 调用时该 kp 下根本不存在任何行（更不存在墓碑），行为与修复前**逐字节一致** → 仍新建一条 kp 会话。
3. 即便按设计文档把它改成「同 kp 下任意 `type` 复用 / `ORDER BY id ASC`」，`:311` 那次调用仍只产生 1 行、仍被 Agent 列表排除。

**但有两条隐患，必须在改造中守住（这才是本节的价值）**：

| 隐患 | 描述 | 后果 | 约束 |
| --- | --- | --- | --- |
| **H-1（签名）** | 若改造动了 `getOrCreateForKp` 的**签名**（去掉 `task` 参数 / 把 `task` 换成 `type` 字符串 / 改成必填参数） | `agent_features_test.dart:311` **编译不过** → **整个文件 15 条用例全部连带失败**（含 D 组、G 组），远超本次改造的影响面 | **`getOrCreateForKp({required String kpId, required AiTask task})` 的签名必须保持不变**；新的主会话查询 / 老师模式会话 API 必须是**新增方法**（`getPrimaryForKp` / `listTeacherSessions` / `mergeLegacyExplain`） |
| **H-2（排序）** ✅ **已由设计文档消解** | `getOrCreateForKp` 现有查询（`:55-58`）**没有 ORDER BY**，只有 `where` + `limit(1)` → SQLite 返回哪一行**未定义** | 若直接把它复用为**主会话判定**，多会话时主会话**随机**（用户表现为「退出重进换了条会话」） | **设计文档 §2.3 ① 已给出 `ORDER BY id ASC LIMIT 1`**（`:311-315`）→ 隐患已被消解。**测试仍要用 3 条可控 id 的会话锁死这一点**（单条会话测不出来）——见 T3 断言 ⑥ |

#### R-2 `_sessionTypeFor`（`ai_session_repository.dart:253-260`）

- 若把 `t6Explain → 'explain'` 改成 `'chat'`（D4 要求的「T5/T6 共用同一行」），则 `getOrCreateForJp(kp, task: t6Explain)` 与 `task: t5Ask` 返回**同一行** → 正是 D4 想要的效果。
- 既有测试只用 `t5Ask`（`:311`）→ **不受影响**。
- ⚠️ `_sessionTypeFor` 同时服务 `t7Socratic → 'tutor'`（`:256`）→ **不要动 T7 语义**（PRD §8.1 非目标 5）。

#### R-3 `listMessages` 排序键补 `id` 次级（**最终口径见 §0.3，待 team-lead 拍板**）

- **改动原因**（跨端 `updated_at` 不可信）：增量推送用 outbox 创建时间覆盖 envelope 的 `updated_at`（`sync_engine.dart:183`），pull 时 `_hydrate`（`sync_engine.dart:744-751`）再用它覆盖对端行 → 对端上「迁移来的讲解」`updated_at` = **迁移时刻** → 若按 `updated_at` 作主键排序会把它**排到流末尾**。
- **对既有测试的影响**：`test/agent_features_test.dart:328-333` 断言两条同秒消息顺序为 `['user','assistant']` → 补 `id` 次级键后，两条 `updated_at` 虽相同，但 **id 递增（ULID 单调）→ 顺序仍是 `['user','assistant']`** ✅ **不受影响**。设计文档 §9.2-R8 已论证等价。
- **结论：安全，且属必修**（否则跨端顺序不一致、M8 无法通过）。**必须由 M8 显式锁死。**
- ⚠️ **口径待拍板**：`updated_at ASC, id ASC`（PRD D2 逐字）vs 纯 `id ASC`（team-lead 规格 B）→ 见 **§0.3**。**测试已做成对两者都稳健**（夹具让两序一致），拍板后**无需改测试**。
- ⚠️ **连带影响**：`ChatMessage.createdAt` 仍来自 `r.updatedAt`（`ai_session_repository.dart:127`）—— 排序键换了但**时间戳字段没换** → 跨端「最近活跃时间」显示为迁移时刻是**已知偏差**（设计文档 §5.3 末行「可接受偏差」，已登记为已知限制）。

#### R-4 `ChatMessage` 结构变更（`ai_session_repository.dart:21-34`）

- 设计文档 §2.3 ③：新增 `this.modelId`（**可选、null 合法**）。
- **加可选字段安全**：`agent_features_test.dart:362` 传的是 `messages: const []`（空 const list，不构造任何 `ChatMessage`）→ 不受影响。
- ⚠️ **若把既有构造参数改成必填** → `agent_features_test.dart` 编译失败 → 连带 15 条全红。**约束：`ChatMessage` 的既有参数必须全部保持可选/默认值。**
- ⚠️ **`modelId` 必须是可选的**（null 合法）→ T11 的断言必须写成**可容忍 null** 的形式（`expect(newRow.modelId, sourceRow.modelId)`），**不得**假设它一定非空；N4 也必须覆盖 `modelId == null` 的容错渲染。

#### R-5 `deriveSessionTitle`（`agent_page.dart:182-195`）

- 只能**新增可选参数** `String fallbackTitle = '新对话'`，默认值仍 `'新对话'`（`:194`）。
- 既有测试 `agent_features_test.dart:359-373` 锁定：无消息 → `'新对话'`；超长 → 长度 25 + 结尾 `'…'`。加可选参数**不影响**它原样通过 → T10 专项锁死。
- ⚠️ 若 `agent_page.dart` 的搬迁（设计文档 T01：`deriveSessionTitle` 用 `import` + `export` 搬到共享位置）导致 `test/agent_features_test.dart` 出现 import 错误 → **优先用 `export` 解决（保持 import 路径不变）**，**不得**改测试的 import 路径（那会掩盖公共 API 的破坏，设计文档 §7.2 末条）。

#### R-6 同步 payload 结构（`sync_row_map.dart:149-174`）

- PRD F3 要求 payload 结构不变 → `test/sync_row_map_test.dart` 必须原样通过。
- 好消息：`aiMessageRowToMap` **已含** `model_id` → 迁移后 `dify-t6` 能随同步传播；`aiSessionRowToMap` **含** `type` → type 归一后的 `'chat'` 能传播（G19）；**不含** `model_id`/`tutor_state` → 本次不涉及。
- ⚠️ 合并迁移**不得**为了传播迁移结果而新增 payload 字段。

#### R-7 `ai_sessions` 无 `created_at`

- 主会话判定依赖 **ULID 单调性**（`core/id.dart:8` 的 `newUlid()`），**不得**给表加 `created_at` 列（PRD §3.2 / F4；设计文档 §2.4 末段「防止后人误加列」）。
- `test/schema_migration_test.dart` 会守住「表结构未变」。

#### R-8 `AiService` / `AiTaskRouter` 调用点收敛（设计文档 §7.3.1 `:1176`）

- 老师模式页面的 `AiService` 调用点必须**收敛成唯一一处**（`TeacherSessionController` 或页面的 `_chat`），否则集成层无法稳定断言「每轮发出的 query」→ **T6 端到端层会不稳定**。
- 建议在 T6 集成用例里加一条辅助断言：`expect(fake.queries.length, 3)`（恰好 3 次调用）——若将来有人加了第二个调用点，这条会红。

---

## 7. 人工验收清单（UI 层，自动化覆盖不到）

> 逐条写成「**操作 → 期望可见现象**」。凡带 ★ 的为本改造的关键可见差异。

| # | 操作 | 期望可见现象 |
| --- | --- | --- |
| M-01 | ★ 首次进入某知识点 | 顶部出现主会话标题「**{知识点名} 讲解**」；消息流里出现一条带「**讲解**」小标签的 assistant 气泡（流式增长）；输入框可用；**没有**「暂无讲解」空态 |
| M-02 | ★ 退出老师模式，再进入同一知识点 | **直接看到上次的讲解正文**；**不出现**「暂无讲解」；**不重复**自动生成第二份讲解（消息条数不增） |
| M-03 | ★ 看 AppBar | **不再有**「讲解 (T6)」「追问 (T5)」两个 Tab；只有一个会话流；AppBar 可见「新建会话」与「会话列表」入口 |
| M-04 | 打开「会话列表」 | 看到该知识点下的会话条目：**标题 / 消息条数 / 最近活跃时间（MM-dd HH:mm）/ 最后一条内容预览**；主会话行带「**默认**」标签；**不含** AI 助手的会话 |
| M-05 | ★ 点「新建会话」 | 出现语义提示「**新会话从提问开始，不会自动讲解**」；新会话被选中、消息流**为空**（**没有**自动讲解）；该会话在列表**置顶** |
| M-06 | 在新会话里提问 | 正常得到回答并落在**新会话**；切回原会话，两边消息**互不串** |
| M-07 | 连续追问 3 轮，第 3 轮问「刚才那个数是多少」 | 第 3 轮回答**确实引用**第 1 轮的数字（真机观察模型连贯性）。⚠️ **此项只作补充观察；T6 的验收依据是自动化用例（§3）** |
| M-08 | ★ 点「再讲一次」 | 按钮文案是「**再讲一次**」（不是「重新生成」）；点击后**流末尾新增**一条带「讲解」标签的气泡；**旧讲解仍在**、可与新讲解对比；生成中按钮禁用并显示 loading |
| M-09 | 「再讲一次」按钮位置 | 位于**消息流底部、与输入框同区**（输入框上方一行，靠右对齐）；**不占 Tab**、**不在** AppBar 顶级入口 |
| M-10 | 「⋮」→「重命名会话」 | 弹出输入框**预填**当前派生标题；输入新名 → 确定 → **无二次确认**；列表标题立即变化；**退出重进仍保留** |
| M-11 | 「⋮」→「清空消息」 | 二次确认文案「**会话会保留，消息不可恢复**」；确认后消息数归零、**会话行仍在列表**、**主会话身份不变** |
| M-12 | 「⋮」→「删除该会话」（非主会话） | 二次确认文案「**连同消息一起删除，不可恢复**」；确认后该会话从列表消失；其消息在**任何界面都不复现** |
| M-13 | ★ 「⋮」→「删除该会话」（**主会话**） | 二次确认文案**逐字**为：「这是该知识点的默认会话。删除后将自动切换到『{下一个会话标题}』；若无其它会话，将新建一条并自动生成一次讲解。确定删除？」；确认后**自动切换**到下一条会话 + 提示「已切换到会话『X』」 |
| M-14 | ★ 删掉该知识点下**最后一个**会话 | 自动新建一条会话并**自动生成一次讲解**（消息流出现带「讲解」标签的气泡）+ 提示「已新建一条并自动生成一次讲解」 |
| M-15 | ★ 文案一致性 | 删除主会话的确认弹窗、删除后的顺延/补建提示、会话列表菜单 —— 三处**逐字一致**（同一常量 `teacher_session_copy.dart`，不是三份拷贝） |
| M-16 | ★ 在一个**旧数据**知识点上首次进入 | 原来两条会话（讲解 + 追问）→ 只剩**一条**；原讲解作为一条消息按**原时间顺序**混排在流里；内容**一字不差** |
| M-17 | 迁移失败场景（老库里造出会迁移失败的 explain 会话） | **不阻断进入**；explain 会话**仍出现在会话列表**里、可点进去看原讲解；有提示「历史讲解迁移失败，已保留为独立会话」；AppLog 里可检索到失败记录 |
| M-18 | 消息流里混入 `model_id` 为空 / 异常值的消息 | **按普通消息渲染**（**无**「讲解」标签）；页面**不崩**、无异常弹窗 |
| M-19 | 长会话滚动 | 消息流滚动**流畅**无卡顿（`ListView.builder` 虚拟化生效）；消息条数**不设上限**（G18） |
| M-20 | 知识点头部 | 掌握状态显示与改动前**一致**（`setMastery` 级联降级行为不变） |
| M-21 | 从两个入口同时打开同一知识点 | 入口处被资源锁挡下（`holdInteractive('kp:{id}')` 语义不变），提示与托盘计时联动正常 |

---

## 8. 门禁与执行顺序

### 8.1 基线数字（2026-10-24 **实测**）

| 门禁 | 基线 | 实测命令输出 |
| --- | --- | --- |
| `flutter test` | **598 通过 / 0 失败** | `00:14 +598: All tests passed!` |
| `test/agent_features_test.dart` | **15 条** | 与 `ai_job_service_notify_test.dart` 合计 `+17: All tests passed!` |
| `test/ai_job_service_notify_test.dart` | **2 条** | 同上 |
| `tool/analyze_inproc.dart` | **132 文件 → 0 error / 0 warning / 3 info** | `Analyzed 132 file(s) → 0 error(s), 0 warning(s), 3 info(s)` + `No issues found!` |

> ⚠️ **PRD §12 写的「flutter test 213/213」是旧基线**（PRD 撰写时）。仓库已增长到 **598**。门禁口径应以 **598** 为准，**不是 213**。
> ⚠️ 门禁还要求 **不新增 INFO**（设计文档 G17）——当前 3 条 info 是存量（`agent_page.dart:1718`、`knowledge_manage_page.dart:957`/`:1001` 的 `withOpacity` 弃用）。

### 8.2 执行顺序（改造完成后依次跑）

```bash
# ── 步骤 0：清代理环境（本机 llm_server 走 127.0.0.1，系统代理会制造「假连不上」）
#    Git Bash 语法：
#    export HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy=

# ── 步骤 1：定向跑本次新增的 3 个测试文件（最快反馈，先看红绿）
cd aimindtree_app && HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= \
  D:/DevTools/flutter/bin/flutter.bat test \
    test/teacher_session_repo_test.dart \
    test/teacher_session_context_test.dart \
    test/teacher_page_widget_test.dart
# 期望：全部通过，0 失败；**T6 所在文件必须全绿**（T6 红 = 本次改造未达成核心目标）

# ── 步骤 2：定向跑受影响的既有测试（确认没打破既有行为）
cd aimindtree_app && HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= \
  D:/DevTools/flutter/bin/flutter.bat test \
    test/agent_features_test.dart \
    test/ai_job_service_notify_test.dart \
    test/sync_outbox_wiring_test.dart \
    test/sync_row_map_test.dart \
    test/schema_migration_test.dart
# 期望：17 条以上全绿；**agent_features_test.dart 的 7 条 H 组用例必须原样通过**

# ── 步骤 3：全量测试（门禁）
cd aimindtree_app && HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= \
  D:/DevTools/flutter/bin/flutter.bat test
# 期望：**≥ 598 + 新增条数**，0 失败，0 编译错误

# ── 步骤 4：Dart 静态门禁（error 与 warning **都算失败**；flutter analyze 不作门禁，存量有 info）
cd aimindtree_app && D:/DevTools/flutter/bin/cache/dart-sdk/bin/dart.exe tool/analyze_inproc.dart
# 期望：0 error(s), 0 warning(s)，**info 不新增**（存量 3 条），输出 "No issues found!"

# ── 步骤 5：人工验收（见 §7 的 M-01 ~ M-21）
```

### 8.3 改造后目标条数

| 文件 | 规划条数 |
| --- | --- |
| `teacher_session_repo_test.dart` | ~28 |
| `teacher_session_context_test.dart` | ~24 |
| `teacher_page_widget_test.dart` | ~14 |
| **新增小计** | **~66** |
| **全量目标** | **≥ 664**（598 + 66），0 失败 |

> 条数为规划值，实际以实现落地为准。**门禁的硬口径是「不低于 598 且 0 失败 + 3 个新增文件全绿」**；条数少于 66 时需说明是哪些用例被合并/省略。

---

## 9. 风险点提示（最容易写出假阳性的地方）

> 下列每一条都是「代码可以完全不实现该需求、测试却能绿」的写法。**写测试时逐条自查。**

| # | 假阳性写法 | 为什么假阳性 | 更强的断言建议 |
| --- | --- | --- | --- |
| **P1** | `expect(() => send(), returnsNormally)` / 只断言「没抛异常」 | **L2 注入完全没做**，query 只有 L1 + 当前问题，代码照样正常返回 → 测试全绿但 T6 未实现 | 断言假 Provider 收到的 **query 内容**：`expect(fake.queries.last, contains('ALPHA-7.5'))` —— 内容级、逐字 |
| **P2** | `expect(l2.length, greaterThan(200))` | 长度可以**全靠 header + 角色前缀**撑起来；也可能靠一句废话凑够 → 历史根本没带上 | 断言**特定历史内容的逐字出现** + **本轮问题不在块内** + `turns:[]` 的负对照 |
| **P3** | 断言 `query.contains('7.5')` | 历史 / L1 定义 / 本轮问题里**都可能有** 7.5 → 断言可能因错误的原因通过 | 用**只出现在历史里的唯一锚点**（`'ALPHA-7.5'`）+ **负对照**（`turns:[]` 时不含它） |
| **P4** | 只断言「第 3 轮回答里出现了 7.5」（真模型/真机） | 模型可能**蒙对**；提示词里可能碰巧含 7.5；用户第 3 轮可能自己写了 7.5 → **无法区分「记住」与「蒙对」** | 用假 Provider：锚点**只由假 Provider 在第 1 轮产出** → 第 3 轮气泡出现它 ⟺ 第 1 轮内容进了第 3 轮 query（因果闭合） |
| **P5** | 只断言「第 3 轮也落库了一条 assistant 消息」 | 当前实现也会落库 → 与历史注入无关 | **同时**断言假 Provider 收到的第 3 次 query 内容；并加 `expect(fake.queries.length, 3)`（恰好 3 次调用，锁「调用点收敛」） |
| **P6** | 合并测试只断言「消息条数没变」 | 可能**既没迁也没删**（什么都没做）→ 断言碰巧成立 | 同时断言：chat 会话消息数 == 原 chat + 原 explain；explain 行 `deletedAt != null`；explain 原消息行 `deletedAt != null`；**新行 id != 原行 id** |
| **P7** | 幂等测试只断言「再次调用不抛异常」 | 重复迁移也能不抛异常 | 断言**消息 id 集合完全相同**：`expect(idsAfter, equals(idsBefore))` —— 派生 id 相同 → 主键冲突跳过；一旦实现改成「新 id 派生」就会立刻暴露 |
| **P8** | 主会话测试只造**一条**会话 | 单条时任何查询都返回它 → **有没有 ORDER BY 都测不出来** | 造 **≥3 条**（id 可控），断言返回的是 **id 最小**那条；并断言主会话查询与 `getOrCreateForKp` 是**两个不同方法** |
| **P9** | 时间断言用 `DateTime.now()` + 几毫秒差 | Drift `updated_at` 是**秒级**精度 → 同秒写入顺序不稳定 → **偶发红 / 偶发绿** | 消息顺序断言改用 **`id ASC`**（规格 B）→ **免等待**；会话列表排序（`updated_at DESC`）仍须 **1.1s 步进**（`agent_features_test.dart:320-321`）；或直接**显式写库指定 `updated_at`** |
| **P10** | 只断言 `deletedAt != null` 就认为「软删生效」 | 若实现**物理删行**，`deletedAt` 自然读不到 → 断言会因「抛异常/读不到」而红或被改弱 | 同时断言 `db.select(db.aiSessions)` **行数不变** + 该行 `deletedAt != null`（墓碑在库） |
| **P11** | widget 测试只断言「页面上有 Text 组件」 | 可能命中**输入框的 hint** 或其它同名文案 | 用**唯一内容**（`'ALPHA-7.5'`、`'讲解正文XYZ'`）并断言 `findsOne` / `findsNothing`；必要时 `find.descendant` 限定在气泡子树内 |
| **P12** | widget 测试 `pumpAndSettle` 后立刻断言 | 流式生成未完成 → **偶发红** | 先 `await tester.pumpAndSettle()`，必要时 `await tester.pump(const Duration(milliseconds: 50))` 推进流；假 Provider 建议**一次性 yield 完整 delta**（不模拟分片） |
| **P13** | 断言「讲解消息带标签」用 `find.text('讲解')` | 可能命中其它文案（如「再讲一次」按钮附近文字） | 用 `find.byWidgetPredicate` 定位标签 widget，或 `find.descendant(of: bubbleFinder, matching: find.text('讲解'))` |
| **P14** | 合并测试恰好构造了「chat 的 id 更小」，断言「主会话 == chatId」 | 恰好通过 → **掩盖了「explain 抢主会话」的缺陷** | **必须同时构造** M3（explain id 更小）与 M4（chat id 更小），断言结果**一致** |
| **P15** | outbox 测试只断言 `pendingCount > 0` | 分不清是哪个操作入的队、也不知道是 upsert 还是 delete | 断言 `entityTable` / `entityId` / `op` / `payload` 的**键与值**（照 `sync_row_map.dart:149-174`）；并断言**逐条**（迁移 N 条 → N 条 outbox，不是 1 条）；墓碑靠 **upsert payload 的 `deleted_at`**（**不得**去找不存在的 tombstone API，G8） |
| **P16** | 同步测试未接线 outbox 却断言「已入队」 | `SyncOutboxRepo.current == null` 时 writer **静默跳过**（`sync_outbox_writer.dart:231-232`）→ 断言要么红、要么被改成「不强断言」而失去意义 | 必须先 `SyncOutboxRepo.current = SyncOutboxRepo(db, deviceId: 'test-device')`（**同一个 db 实例**，否则 writer 跳过并记 warning）；`tearDown` 复位 `null` |
| **P17** | T2 只断言「重新进入后有讲解」 | 可能是**内存残留/单例**把第一次的 `_explainText` 带过去了，而非从库里读 | 用**两个独立的 `TeacherPage` 实例**；再补**负对照**：把该会话消息软删后第三次进入 → 讲解**应消失** |
| **P18** | 纯函数测试只断言「输出包含固定字符串 `'AI：'`」 | 格式微调就假红；且只断言了**有**格式行、没断言**条数** | 断言 `RegExp(r'^用户：', multiLine: true).allMatches(l2).length == userCount`（角色前缀语义稳定即可，不锁死整段格式） |
| **P19** | 边界用例只测「超长」不测「刚好等于上限」 | off-by-one 溜过 | 补 E3 / E4 / E6 三条：恰好 10 条 / 11 条 / 恰好 4000 字符 / 4001 字符 |
| **P20** | 把「截断后总长 ≤ 4000」直接断言在**整个 query** 上 | L1 + 当前问题也占长度 → 断言要么永远红、要么被改弱 | 只对 **L2 块**断言长度：`expect(l2.length, lessThanOrEqualTo(4000 + header.length))` |
| **P21** | 只断言「消息被复制到 chat 会话」，不查**原行是否软删** | 可能**复制了但没删原行** → 用户在 explain 会话里仍能看到同一份讲解（重复内容） | 同时断言原行 `deletedAt != null` **且** `db.select(db.aiMessages)` 行数 == 原数 + 迁出数（复制语义） |
| **P22** | 迁移实现直接改 `session_id`（而非「复制 + 软删」），测试只断言「内容在 chat 会话里」 | PRD R1 明确要求复制语义（避免在途同步回声覆盖） | 断言**新行 id != 原行 id** 且**原行 `deletedAt != null`** |
| **P23** | widget 测试只验证「点了发送有反应」，不验证「第 3 轮 query 内容」 | 任何实现都能「有反应」 | 断言假 Provider 记录的 `queries.length == 3` 且 `queries[2]` 含锚点 —— 同时锁住「发了 3 次」和「第 3 次带历史」 |
| **P24** | T11 断言 `expect(newRow.modelId, 'dify-t5')` 或 `isNotNull` | `model_id` **可以是 null**（老数据 / 非本模块写入，设计文档 §2.3 ③）→ 断言假设非空会**假红**，也可能被改成弱断言 | 用**逐字段对照**：`expect(newRow.modelId, sourceRow.modelId)` —— null 进 null 出，一视同仁；另加一条 `modelId == null` 的容错渲染用例（N4） |
| **P25** | T11 只断言 `content_md` 一致，漏掉 `updated_at` | PRD IC3 / D9 要求**逐字段**原样保留；漏 `updated_at` 会让「时间戳被重写」这类缺陷溜过 | 断言 `role` / `content_md` / `updated_at` / `model_id` **四个字段全部**逐条对照源行 |
| **P26** | M8 只断言「合并后消息数对」，不断言**顺序** | 排序键补 `id` 次级后，若派生 id 没保持严格递增，讲解会被排到追问**后面** | 断言迁移后 3 条的 `id` **严格递增**且 `content_md` 顺序 == 原顺序 |
| **P27** | M8 的夹具**只指定 `id`**、让 `updated_at` 相同或乱序 | 排序键口径（§0.3）在 `updated_at ASC, id ASC` 与纯 `id ASC` 之间**未定** → 同一夹具在两种口径下**结果不同** → 断言变成「口径赌注」：口径一变，用例要么假红要么假绿 | 夹具**同时**显式指定 `updated_at` 与 `id`，且**两者递增序一致** → 两种口径下 M8 都绿、都有效；口径拍板后**无需改测试** |
| **P28** | E10 只测「`at` 非空时自行排序」一条分支 | 漏掉「存在 `at == null` → **保持传入顺序**」这条 **Agent 兼容分支** → 将来有人把纯函数改成「无条件排序」，Agent 侧历史顺序会静默改变，而**现有测试测不出来** | 写成**两条分支各一条断言**：`at` 全非空 → 按时间序；存在 `at == null` → 顺序 == 传入顺序 |
| **P29** | T11 只断言「迁移后内容还在」，不比对 `model_id` 逐条对应 | 多条消息时可能**张冠李戴**（讲解的 `model_id` 落到追问上）而断言仍成立 | 按**源行 id → 目标行 id** 建立映射后**逐条**比对 `model_id`/`role`/`content_md`/`updated_at` 四个字段 |

---

## 10. 交付前自检清单（QA 提给工程师）

- [ ] 3 个测试文件全部新建，文件名与设计文档 §7.3 一致（`teacher_session_repo_test.dart` / `teacher_session_context_test.dart` / `teacher_page_widget_test.dart`）
- [ ] 假 Provider 用**文件内私有** `_FakeProvider`（沿用 `test/ai_task_route_test.dart:38-52` 范式），**不新建** `test/support/` 目录
- [ ] **T6 的假 Provider 已实现**，且第 3 轮气泡断言用的是**内容**而非长度
- [ ] T6 有一条**反向证据**用例（证明断言不是恒真）
- [ ] T6 纯函数层按 **10 条 / 5 轮 + ≤4000 字符** 写（规格 A）
- [ ] 消息顺序断言用 **`id ASC`**（规格 B），会话列表排序断言仍用 **1.1s 步进**
- [ ] **M8 夹具同时显式指定 `updated_at` 与 `id`，且两者递增序一致**（对 §0.3 两种排序键口径都稳健）
- [ ] **E10 写成两条分支**（`at` 全非空 → 自排；存在 `at == null` → 保序）
- [ ] `getOrCreateForKp` **签名未变**（否则 `agent_features_test.dart` 全文件编译失败）
- [ ] `AiSessionRepository` 的 `deviceId` 是**可选命名参数**（否则 `agent_features_test.dart:40` 编译失败 → 连带 15 条全红）
- [ ] `ChatMessage` 的既有构造参数**全部保持可选**；`modelId` 为**可选 / 允许 null**
- [ ] T11 的 `model_id` 断言写成**逐字段对照**（可容忍 null），**不假设非空**
- [ ] `deriveSessionTitle` 只**新增可选参数**，默认值仍 `'新对话'`
- [ ] `listAgentSessions()` **一行未改**（IC7 / G20）
- [ ] 合并实现是「**复制 + 软删原行**」，派生 id **确定性相同**，且每条消息**单独** `upsertAiMessage`
- [ ] type 归一**必须走 `upsertAiSession` 入队**（G19）
- [ ] 软删传播靠 **upsert payload 的 `deleted_at`**（**没有**去调不存在的 `tombstoneAiSession`，G8）
- [ ] **M6 有可注入的失败接缝**（否则该用例不可测 —— 见 §5 末尾建议）
- [ ] `listTeacherSessions` / `getPrimaryForKp` 与设计文档 §2.3 命名**一致**（§0.5 待 team-lead 确认裁决表方向）
- [ ] `AiService` 调用点**收敛成唯一一处**（否则 T6 集成层不稳定）
- [ ] 步骤 1–4 的四条门禁命令**全部执行并留档**
- [ ] 人工验收 M-01 ~ M-21 全部走查完毕（M-02 / M-13 / M-15 / M-16 为重点）

# 增量 PRD：自研 LLM Server 替换 Dify 直连

| 项 | 内容 |
| --- | --- |
| 文档类型 | **增量 PRD**（只描述变更部分，不重写全量 PRD） |
| 关联文档 | `docs/PRD.md`（全量）、`docs/ARCHITECTURE.md §6`、`docs/DIFY_WORKFLOW_BUILD_GUIDE.md` |
| 项目 | AIMindTree（Flutter + Drift，Windows 桌面优先） |
| 工作区根 | `D:\AndroidStudioProjects\AIMindTree` |
| 发起人 | 道源（用户） |
| 撰写 | 许清楚（产品经理） |
| 状态 | 待评审（约束与决策已拍板，开放项见 §9） |

> **阅读顺序**：§1 变更目标 → §3 硬约束（**工程师必读，不可违反**）→ §4 需求池 → §7 目录规范 → §9 待确认。

---

## 1. 变更目标

**一句话**：把 AI 调用链路从「App 直连用户手工搭建的 Dify 工作流」改为「App 直连一个随仓库自带的 Python 自研 LLM Server，由它按任务装载提示词并转发到 Ollama / MiniMax / OpenAI 兼容端点」，让用户不再手工搭 Dify、改提示词只改一个文件、换模型只点一下开关，同时把 Dify 代码整段注释保留以便随时回退。

### 1.1 变更前后对比

| 维度 | 变更前（现状） | 变更后（本次） |
| --- | --- | --- |
| 调用链路 | App → Dify（`/v1/workflows/run`、`/v1/chat-messages`） | App → **自研 LLM Server**（`127.0.0.1:8787`）→ LLM 后端 |
| 部署负担 | 用户需自行 Docker 起 Dify、建 13 个应用、逐个选模型、逐个发布、逐个生成 Key | **零部署**：仓库自带，一行命令起服务 |
| 提示词位置 | 写在 Dify 控制台的 LLM 节点里（UI 编辑，不在仓库） | 集中在 `llm_server/prompts/*.md`，**一个任务一个文件**，可热更新 |
| 提示词版本 | 不受 Git 管控 | 进 Git，可 diff / 回滚 |
| 后端模型 | 由 Dify 控制台给每个应用单独配 | 服务端 `config.yaml` 配多 backend，**运行时按任务 / 全局开关切换** |
| 支持后端 | 仅 Dify 已接入的模型 | Ollama（本地）+ MiniMax Coding Plan + OpenAI 兼容自定义端点，**三个都要** |
| 协议实现 | `DifyClient`（唯一实际实现） | 新增 `LlmServerClient`（`protocol='llm_server'`）；`DifyClient` 整段注释保留 |
| 设置页 UI | 「添加 Dify」+ Dify 专属文案 | 新增 `llm_server` 配置项（Base URL / Backend / Model），**Dify 选项整体隐藏** |
| 上层业务代码 | — | **完全不动**（提取页 / 画布 / Agent 页 / 作业页 / 老师模式） |

### 1.2 变更范围边界

**要改（客户端）**

| 文件 | 改动 |
| --- | --- |
| `aimindtree_app/lib/ai/clients/llm_server_client.dart` | **新增**：`implements AiProvider`，`protocol='llm_server'` |
| `aimindtree_app/lib/ai/structured_parse.dart` | **新增**：结构化文本解析器（从 `DifyResult.parseStructured` 抽出，两协议共用） |
| `aimindtree_app/lib/ai/ai_provider.dart` | `streamChat` 增加可选参数 `AiTask? task` 与 `String? variant`（见 C3）；注释补充第四协议 |
| `aimindtree_app/lib/ai/ai_service.dart` | **极小改动（§1.2 例外）**：`chat()` 形参加 `String? variant`，调用处补 `task: task, variant: variant` —— **共 2 行**，只为透传 task；统一入口 / 重试 / 路由逻辑不动 |
| `aimindtree_app/lib/features/agent/agent_page.dart` | **1 行**：`ai.chat(AiTask.t5Ask, prompt)` 补 `variant: 'detect'`（见 C3 / Q2）；prompt 拼装逻辑**不动** |
| `aimindtree_app/lib/ai/clients/dify_client.dart` | **整段注释**（文件保留，顶部写回退说明） |
| `aimindtree_app/lib/ai/extraction_service.dart` | `bootstrap` 增加 `llm_server` 分支；`LocalAiConfig` 改为 LLM Server 默认值（见 C4） |
| `aimindtree_app/lib/data/repositories/settings_repository.dart` | 新增 `addLlmServerProvider`；`seedFromLocalIfEmpty` 改 seed llm_server；`testLlmServer` 探 `/health`；**既有 `addDifyProvider` / `testDify` 保留代码 + 停用注释（§C7 口径 B）** |
| `aimindtree_app/lib/features/settings/settings_page.dart` | FAB 改「添加 LLM 服务」；隐藏 Dify 入口；说明文案改版 |
| `aimindtree_app/lib/features/settings/llm_server_add_dialog.dart` / `llm_server_edit_dialog.dart` | **新增**（字段见 §6）；`dify_add_dialog.dart` / `dify_edit_dialog.dart` 整段注释 |
| `aimindtree_app/lib/data/db/tables.dart` | **仅注释**：`protocol` 取值补 `llm_server`；`type` / `models` 复用语义白名单（§C6）（**表结构不变，无需 migration**） |
| `aimindtree_app/test/dify_parse_structured_test.dart` | 改指向 `StructuredText.parse`（或同步注释） |

**不改**（`ai_service.dart` 见上表例外）：`ai_task.dart`（13 任务枚举 / `structured` 标志）、`ai_task_router.dart`（路由与 T3/T4 专属逻辑）、`auto_graph_service.dart`、`teacher_page.dart`、`homework_page.dart`、`canvas_page.dart`、其余全部 UI 业务页。

> **§1.2 例外说明**：`ai_service.dart` 与 `agent_page.dart` 的改动仅是把 `task` / `variant` **透传**下去（各 1–2 行，均为新增可选参数），不触碰任何既有分支逻辑。§C3 是本 PRD 的最高优先级约束，与「不改」清单冲突时**以 §C3 为准**。

**要新增（服务端）**：`llm_server/`（见 §7）。

---

## 2. 用户故事

| # | 角色 | 故事 | 验收要点 |
| --- | --- | --- | --- |
| US-1 | 不想再手工搭 Dify 的用户 | As a 用户，I want 装好 App 后**不需要在 Dify 控制台建任何工作流**，so that 打开就能用 AI 提取 / 连线 / 讲解 | 全新环境：拉代码 → 一行命令起服务 → App 直接跑通 T1；全程不打开 Dify |
| US-2 | 想调提示词的产品/用户 | As a 用户，I want 改某个任务的提示词时**只改 `llm_server/prompts/` 下那一个文件**，so that 不用进 UI 点十几层、不用重新发布应用 | 改 `t1_extract.md` 保存 → 不重启服务或点一次「重载提示词」→ 下次 T1 立即生效 |
| US-3 | 想控成本 / 想更准的用户 | As a 用户，I want 在设置页一键切换 **本地 Ollama（省钱离线）/ 云端 MiniMax（更准）/ 自定义 OpenAI 端点**，so that 按场景权衡成本与质量 | 设置页切换 Backend 下拉 → 立即生效；`GET /health` 显示各后端可达性与模型列表 |
| US-4 | 想随时回退的用户 | As a 用户，I want Dify 方案被完整保留（不删文件），so that 新方案出问题时能原样切回去 | `dify_client.dart` 及两个 dialog 以注释态保留；按附录 B 三步即可恢复 |
| US-5 | 关心隐私的用户 | As a 用户，I want 本地模式下**笔记正文不出本机**，so that 敏感内容不上传 | Backend=ollama + `base_url=127.0.0.1` 时，抓包确认无任何外网请求 |

---

## 3. 硬约束（工程师必读）

### C1 · 契约一致性：13 任务的输入/输出字段名必须与 App 端解析器**逐字一致**

下列契约由 `extraction_service.dart` / `auto_graph_service.dart` / `homework_page.dart` / `agent_page.dart` 的反序列化代码反推得出。**任何字段改名都会导致静默解析失败**（上层会表现为「AI 没跑」而不是报错，极难排查）。

| 任务 | structured | 输入字段（App → 服务端） | 输出契约（服务端 → App） |
| --- | --- | --- | --- |
| T1 提取 | ✅ | `note_text`（笔记原文全文） | `{"knowledge_points":[{"name","type","definition","source_quote","prerequisites":[],"confidence"}]}` |
| T2 规范化 | ✅ | `kps`（**JSON 字符串**） | `{"normalized":[{"name","type","definition","merged_from"}]}` |
| T3 前置推断 | ✅ | `points`（**JSON 字符串**，元素含 `{id,name,type,definition}`，按组连线时追加 `{group,group_order,foundation_level}`） | `{"prerequisites":[{"from","to","reason"}]}`；`from/to` 用输入里的 `id` 或 `name`，App 会做 id→name→contains 三级解析 |
| T4 缺口分析 | ✅ | `target`（形如 `"<name> \| <type> \| <definition>"`）、`depth`（`low/medium/high/custom`）、`depth_instruction`（**必填**，非 custom 档也要带学段文案） | `{"gaps":[{"name","type","definition","reason","level"}]}`；`level` 恒为 1（递归由客户端驱动） |
| T5 追问 | ❌ | `query`（纯文本，含完整上下文） | **双形态**：① 自由问答 → 纯文本；② 薄弱点检测 → `{"needed":[{"name","definition","reason"}],"weak":[...]}` |
| T6 讲解 | ❌ | `query`（含知识点名称/定义/原文） | 纯文本 |
| T7 苏格拉底 | ❌ | `query` | 纯文本 |
| T8 出题 | ❌ | `query` | **JSON 数组**：`[{"kpName","type","question","answer","difficulty"}]`；`type ∈ choice\|fill\|short\|calc\|proof`；`difficulty ∈ 1\|2\|3` |
| T9 批改 | ✅ | `question`、`answer`、`user_answer` | `{"correct","reason","misconception","suggestion"}` |
| T10 讲义 | ❌ | `query` | Markdown 文本 |
| T11 总结 | ❌ | `query` | 纯文本 |
| T12 标题标签 | ✅ | `content` | `{"title","tags":[]}` |
| T13 相似度 | ✅ | `pairs`（**JSON 字符串**，形如 `[[a,b],…]`） | `{"similarities":[{"a","b","score"}]}` |

> **⚠️ 三个「chat 类却要求结构化输出」的特例：T5-检测、T8。** 它们走 `/v1/chat`，但 App 会用 JSON 解析整段缓冲。服务端对这两个 variant 必须同样走 §C2 的 JSON 容错链路，且**不得**在流式文本前后夹带解释性文字。

### C2 · 推理模型 `<think>` 容错：服务端必须提供**不低于** App 端现有水平的能力

现状：`DifyResult.parseStructured`（`dify_client.dart:61`）有四层容错，注释里明确写了「不要用首 `{` → 末 `}` 硬切」的踩坑结论：

1. 整体直接 `jsonDecode`；
2. 剥离**闭合**的 `<think>…</think>`（大小写不敏感、跨行）后再解；
3. 剥离 ` ```json … ``` ` 围栏后再解；
4. **括号配对扫描**：对每个 `{` / `[` 起点做字符串/转义感知的配对，找到第一个「能配对且能解码」的片段（这样即使前面挂着**未闭合**的思考块也不会被带偏）；
5. **截断抢救**：配对失败时，从尾部回退到最后一个完整元素，补上未闭合括号再解；**绝不补全或编造内容**；
6. 最后才退回首尾硬切。

**新服务端必须 1:1 移植这套逻辑到 `llm_server/core/json_repair.py`**，并至少再覆盖 `<think>` / `<thinking>` / `<reasoning>` 三种标记（含未闭合形态）。理由：DeepSeek-R1 / Qwen 等推理模型在 T1/T3/T4 上必吐思考块，容错不对等 = 结构化任务大面积解析失败。

>Dart 侧同款逻辑由 `structured_parse.dart` 保留，作为**双保险**：服务端已剥干净最好，没剥干净 App 端再兜一次。

### C3 · chat 类任务目前拿不到 `AiTask`（接口缺口，必须补）

`AiService.chat(AiTask task, String query, …)` 有 `task`，但它调用 `provider.streamChat(query, …)` 时**没有把 task 传下去**（`ai_service.dart:74`）。而 `AiProvider.streamChat` 的签名里也确实没有 task 参数。

→ 服务端 `/v1/chat` 若不改造就**无法知道当前是 T5 还是 T6 还是 T8**，也就无法装载对应提示词。

**因此 P0 必须给 `AiProvider.streamChat` 增加可选参数**：

```dart
Stream<AiChunk> streamChat(
  String query, {
  String? conversationId,
  String? user,
  Duration timeout = const Duration(seconds: 120),
  AiTask? task,      // 新增：可选，Dify 实现忽略
  String? variant,   // 新增：可选，目前唯一取值 'detect'（T5 薄弱点检测）
});
```

- `AiService.chat` 把 `task` / `variant` 透传下去（+2 行）。
- **可选参数保证不破坏任何既有调用点**：`teacher_page` / `homework_page` **零改动**；`agent_page` 只需在检测调用处补 `variant: 'detect'`（1 行）。
- **variant 收敛到唯一取值**：只有 T5 有变体。
  - `variant='detect'` → 服务端装载 `t5_ask__detect.md`（`{"needed":…,"weak":…}` JSON）。
  - **T8 不设 variant**：T8 的 JSON 契约（`[{"kpName",…}]`）**继续留在 App 端 `_buildPrompt()` 拼的 query 里**，服务端 `t8_quiz.md` 的 `# USER` 为 `{{query}}` + JSON-only 收尾段即可。
  - **降级安全**：即使 `variant` 传错或服务端未识别，`t5_ask__detect.md` 与 `t8_quiz.md` 的 `# USER` 都只是 `{{query}}` 透传 + JSON-only 收尾，输出形状**不会退化**——最坏情况等于「不加服务端提示词」，不会出现「自由问答被污染成 JSON」或反之。

### C6 · 表结构禁止改动：Backend / Model 复用既有列（本轮硬约束）

本轮**禁止修改 `ai_providers` 表结构**——项目 `build_runner` 不可运行，改表 = `drift_database.g.dart` 无法重生成 = 编译不过（见附录 A）。

而 §6.2 的对话框需要持久化 Backend 与 Model。方案：**复用当前无任何业务逻辑读取的两列**（已核实：全仓除 `settings_repository.dart` 写入外无任何读取点）：

| 列 | 复用语义 | 取值 |
| --- | --- | --- |
| `type` | **Backend** | `auto`（跟随服务端默认）/ `ollama` / `minimax` / `openai_compat` |
| `models` | **Model 覆盖**（JSON 数组） | `[]` = 用后端默认模型；`["qwen2.5:7b"]` = 覆盖（最多 1 个元素） |
| `api_key_ref` | 恒空字符串 | 见 C4（密钥由服务端持有） |
| `protocol` | `llm_server` | 新增取值，不改列 |

- 语义必须在 `tables.dart` 的 `AiProviders` 注释里写成**白名单**（`type` 的 4 个取值 + `models` 长度 ≤1），否则后来者会误读。
- **技术债登记**：若后续 `build_runner` 可用，应改为真正新增 `backend` / `model` 两列并去掉复用。（见 §9 Q15）

### C7 · Dify 代码「停用」的两种口径（按文件区分）

`test/settings_repository_test.dart` 里有 **14 处** `addDifyProvider` 调用，因此 Dify 代码的处置**不能一刀切**：

| 口径 | 适用文件 | 理由 |
| --- | --- | --- |
| **A：整段注释**（代码以注释形式保留，文件头写回退说明） | `ai/clients/dify_client.dart`、`features/settings/dify_add_dialog.dart`、`features/settings/dify_edit_dialog.dart` | 这三个文件**无测试依赖**，注释后 `analyze_inproc` 仍通过 |
| **B：保留代码 + 停用注释**（不加 `@Deprecated`） | `data/repositories/settings_repository.dart` 的 `addDifyProvider` / `testDify` | 注释掉 → 14 处测试调用编译失败；加 `@Deprecated` → 触发门禁 warning 失败。**只加「已停用，勿在新代码中调用」的普通 `//` 注释** |

> §4 需求池 A-09 的「整段注释」**仅指口径 A 的三个文件**，与口径 B 不冲突。

### C4 · 密钥边界：密钥不入库，App 侧只存引用名

- `ai_providers.api_key_ref` **只存引用名**（如 `llmserver_<ulid>`），密钥本体在 `SecretStore`；这张表是 S4 本地表、不同步（沿用 `tables.dart` 既有约定）。
- **P0 决策：LLM 后端密钥由服务端持有**，写在 `llm_server/.env`（**必须加进 `.gitignore`**），App 侧 llm_server provider 的 `api_key_ref` 留空、设置页**不显示** Key 输入框。理由：本机服务、不跨网，App 传 Key 反而多一份泄露面；也省掉 App 侧 SecretStore 改动。
- **必须修掉的现存问题**：`extraction_service.dart:37-45` 的 `LocalAiConfig` 里硬编码了 Dify App Key `app-fhXwVvHFfVbVWRq3tRMOX8fd`，已提交进 Git。本次改为 LLM Server 默认配置（`baseUrl='http://127.0.0.1:8787'`、`apiKey=''`），**该 Key 一并作废/从历史文案中移除**。

### C5 · 门禁与运行环境

见附录 A：**唯一门禁是 `aimindtree_app/tool/analyze_inproc.dart`**（error + warning 都算失败）。`flutter` / `dart analyze` / `build_runner` / `flutter test` 在本沙箱被拦截，不可作为验收手段。

---

## 4. 需求池

> 优先级：**P0 = 必须有（不做则变更不成立）**；P1 = 应该有；P2 = 锦上添花。

### 4.1 服务端（`llm_server/`）

| 编号 | 需求 | 优先级 | 验收标准 |
| --- | --- | --- | --- |
| S-01 | **结构化任务端点**：`POST /v1/task/{task_code}`（`T1`…`T13`，大小写不敏感）。请求 `{inputs:{...}, backend?, model?, user?, timeout_s?}`；响应 `{task, content, parsed, backend, model_id, latency_ms, usage}` | P0 | T1/T3/T4 用真实 Ollama 跑通；`parsed` 字段能被 App 直接消费，字段名与 §C1 表逐字一致 |
| S-02 | **任务注册表**：`prompts/index.yaml` 声明每个任务的 `structured` 标志、输入变量清单、`output_key`、`temperature`、`preferred_backend`；未知 task_code 返回 400 + `unknown_task` | P0 | 传 `T99` 返回归一化错误；传 T1 缺 `note_text` 返回 400 + `missing_input` 并点名缺哪个字段 |
| S-03 | **聊任务端点（SSE）**：`POST /v1/chat`，请求 `{task?, variant?, query, conversation_id?, backend?, model?}`，响应 `text/event-stream`，事件 `data: {"delta":"…"}` → `data: {"done":true,"conversation_id":"…","usage":{...}}` | P0 | 老师模式 / AI 助手能**逐字流式**输出；`conversation_id` 能回传续聊 |
| S-04 | 同一 `/v1/chat` 支持 `stream:false` 返回一次性 JSON（冒烟与降级用） | P1 | `stream:false` 时返回 `{content, conversation_id, usage}`，与流式内容一致 |
| S-05 | **多后端抽象**：`LLMBackend` 基类 + `OllamaBackend` / `MiniMaxBackend` / `OpenAICompatBackend`，统一 `complete(messages, temperature, max_tokens, json_mode)` 与 `stream_complete(...)` | P0 | 三个 backend 均实现两套方法；新增第四个 backend 只需加一个文件 + 一行注册 |
| S-06 | **运行时切换**：`config.yaml` 配 `default_backend` 与 `task_backends`（按任务覆盖）；请求体 `backend` 可临时覆盖；`GET /health` 返回各 backend 可达性 | P0 | 改 `default_backend` 后无需重启即可生效（配置热加载或端点切换）；T1 走 ollama、T5 走 minimax 可并存 |
| S-07 | **提示词加载**：启动时扫描 `prompts/*.md`，解析 front-matter（`task` / `structured` / `temperature` / `inputs` / `output_key` / `variant`）+ `# SYSTEM` / `# USER` 两节正文 | P0 | 13 个任务全部加载成功；缺文件/缺 front-matter 时启动日志明确报错并跳过该任务（不整体崩溃） |
| S-08 | **提示词热更新**：`POST /v1/prompts/reload` 重扫目录；`GET /v1/prompts` 列出各任务的 `file / mtime / size / sha1` | P0 | 改一个 md 文件 → 不重启 → 调 reload → 下一次调用立即用新提示词 |
| S-09 | **提示词管理接口**：`GET /v1/prompts/{task}` 取原文；`PUT /v1/prompts/{task}` 写回文件（可选 `?reload=true`） | P1 | 能在不打开文件管理器的情况下查看与覆盖某个任务的提示词；写回后 reload 生效 |
| S-10 | **健康检查**：`GET /health` → `{status, version, uptime_s, backends:[{name, reachable, base_url, models:[...]}], prompts_loaded:N}` | P0 | 服务端没起时 App「测试连接」按钮给出明确失败；Ollama 没起时 `reachable:false` 但服务本身 `status:ok` |
| S-11 | **错误归一化**：统一 `{error:{code, message, backend, retryable}}`；code ∈ `unknown_task` / `missing_input` / `prompt_not_found` / `backend_unreachable` / `backend_timeout` / `auth_failed` / `rate_limited` / `bad_json` / `upstream_error` / `internal`；message 为中文可操作文案 | P0 | 任一类错误都**不**把上游原始 HTML/JSON 甩给用户；`retryable` 字段准确（超时/限流=true，参数错=false） |
| S-12 | **`<think>` 剥离 + JSON 容错**（`core/json_repair.py`）：完整移植 §C2 的 6 层逻辑，并覆盖 `<think>`/`<thinking>`/`<reasoning>` 含未闭合形态 | P0 | 构造 6 个坏样本（闭合 think / 未闭合 think / json 围栏 / 前后杂文 / 截断 / 纯 JSON）→ 6 个全部解析成功；截断样本不得产生形状不对的内层片段 |
| S-13 | 结构化任务**服务端重试**：`parsed` 为 null 时原地重跑一次（`temperature` 不变，附加「上次输出不是合法 JSON」提示） | P1 | 首次胡说、第二次说对的场景下最终成功；重试次数体现在响应 `attempts` 字段 |
| S-14 | **超时与并发**：结构化默认 120s 对齐 App 侧 `timeout`；单请求超时后返回 `backend_timeout` 而非挂死 | P0 | 人为让后端 sleep 200s → 服务端 120s 返回 `backend_timeout`，进程仍可服务后续请求 |
| S-15 | **日志**：结构化请求落一行 `task, backend, model, latency_ms, ok, error_code`；可开关 `--verbose` 打印完整 prompt/response | P1 | 能从日志定位「哪次调用用了哪个后端、成没成」 |
| S-16 | **依赖收敛**：只依赖 `fastapi` / `uvicorn` / `httpx` / `pyyaml`；LangChain 仅作**可选适配层预留**（不进 `requirements.txt`，接口留出 `backends/langchain_adapter.py` 占位注释） | P0 | `requirements.txt` 只有 4 行（含注释）；`pip install` 不需要编译工具链 |

### 4.2 客户端（Flutter）

| 编号 | 需求 | 优先级 | 验收标准 |
| --- | --- | --- | --- |
| A-01 | **新增 `LlmServerClient implements AiProvider`**，`protocol='llm_server'`；`runTask` → `POST /v1/task/{code}`；`streamChat` → SSE | P0 | 实现两个方法与 `dispose()`；`protocol` getter 返回 `llm_server` |
| A-02 | **抽出 `lib/ai/structured_parse.dart`**：把 `DifyResult.parseStructured` 的全部逻辑（含 `_scanJson` / `_salvage` / `_matchEnd` / `_stackAt`）搬过来，暴露 `StructuredText.parse(String)` | P0 | **在注释 dify_client 之前完成**；`LlmServerClient` 用它做兜底解析；原 `test/dify_parse_structured_test.dart` 的 6 个坏样本断言全部在新类上复跑通过 |
| A-03 | **SSE 客户端**：`dart:io` HttpClient 读 `text/event-stream`，解析 `data:` 行，产 `AiChunk(delta:)`，终态产 `AiChunk(done:true, conversationId:, usage:)` | P0 | 老师模式讲解逐字出现；断流时抛可理解异常而非静默空串。（**降级方案**：P0 若 SSE 卡住，可先退回 blocking 单块——与现状持平，记为已知缺口 P1 补齐） |
| A-04 | **`streamChat` 增加可选参数** `AiTask? task` / `String? variant`；`AiService.chat` 透传 `task` 与 `variant`（+2 行，属 §1.2 例外） | P0 | 见 §C3；`analyze_inproc` 无 warning（不使用新增字段的类不得产生 lint） |
| A-13 | **`agent_page.dart` 检测调用补 `variant: 'detect'`**（1 行）；**prompt 拼装逻辑不动**（JSON 契约留在 query 里） | P0 | 见 §C3 / Q2；`variant` 传错时输出形状不退化（降级安全） |
| A-05 | **装配处切换**：`ExtractionService.bootstrap` 增加 `row.protocol == 'llm_server'` 分支并实例化 `LlmServerClient`；`LocalAiConfig` 默认值改为 `http://127.0.0.1:8787` | P0 | 首次启动 seed 出 llm_server provider；App 能直接跑通 T1（不依赖 Dify） |
| A-06 | **`settings_repository`**：新增 `addLlmServerProvider`（`protocol='llm_server'`；`type` 存 backend、`models` 存 model 覆盖、`api_key_ref` 恒空 —— 见 §C6）；`seedFromLocalIfEmpty` 改判 `protocol=='llm_server'`；新增 `testLlmServer(baseUrl)` 探 `/health`。**既有 `addDifyProvider` / `testDify` 保留代码 + 停用注释（口径 B，勿删勿加 `@Deprecated`）** | P0 | 「测试连接」在服务端没起时给出「无法连接 http://127.0.0.1:8787」，起了显示「连接成功」；`test/settings_repository_test.dart` 的 14 处调用仍能编译 |
| A-07 | **设置页隐藏 Dify**：FAB 文案改「添加 LLM 服务」；路由区说明文案去掉「一个工作流 = 一个 Key」的 Dify 表述；Provider 列表不再出现 Dify 专属引导 | P0 | 全文搜索设置页，无面向用户的 "Dify" 字样 |
| A-08 | **新增 `LlmServerAddDialog` / `LlmServerEditDialog`**（字段见 §6） | P0 | 新增一个 provider 后重启 App 即可用；改 Base URL / Backend / Model 后提示需重启（沿用既有语义） |
| A-09 | **Dify 代码整段注释（口径 A，仅这三个文件）**：`dify_client.dart`、`dify_add_dialog.dart`、`dify_edit_dialog.dart` 全部代码以注释形式保留，文件头写明「已停用，回退步骤见 `docs/PRD_LLM_SERVER.md` 附录 B」 | P0 | 三个文件 `dart` 解析通过（注释态）；`analyze_inproc` 通过 |
| A-10 | `tables.dart` 注释补 `llm_server` 取值 + **`type` / `models` 复用语义白名单**（§C6）；**表结构不变、无 migration** | P0 | 老库升级不报错；注释里能读到 `type ∈ {auto,ollama,minimax,openai_compat}` 与 `models.length ≤ 1` |
| A-11 | 全局文案清理：错误提示 / 说明里出现的 "Dify" 改为「LLM 服务」（涉及 `ui/extract_screen.dart`、`features/teacher/teacher_page.dart`、`features/agent/agent_page.dart`、`features/notes/note_editor_page.dart`、`features/canvas/canvas_page.dart`） | P1 | 面向用户的字符串无 "Dify"；代码注释里允许保留（作为历史说明） |
| A-12 | 回退开关：编译期常量 `kEnableDify`（默认 `false`）+ 环境变量 `AIMINDTREE_AI_PROTOCOL`，改一处即可切回 | P2 | 改常量 + 反注释 → `analyze_inproc` 通过 → Dify 链路可用 |

### 4.3 提示词资产

| 编号 | 需求 | 优先级 | 验收标准 |
| --- | --- | --- | --- |
| P-01 | **目录唯一**：所有提示词集中在 `llm_server/prompts/`，**不允许**散落在其他目录或写在 Python/Dart 代码里 | P0 | 全仓搜索 `你是` / `请提取` 等提示词正文，只出现在 `prompts/` 下 |
| P-02 | **命名规范**：`<t小写>_<英文名>.md`，共 13 个：`t1_extract.md` `t2_normalize.md` `t3_prerequisite.md` `t4_gap_analysis.md` `t5_ask.md` `t6_explain.md` `t7_socratic.md` `t8_quiz.md` `t9_grade.md` `t10_lecture.md` `t11_summary.md` `t12_title_tags.md` `t13_similarity.md`；T5 检测变体另存 `t5_ask__detect.md`（双下划线表 variant） | P0 | 文件名与 `AiTask.code` 一一对应；服务端按映射表加载，改名即失效（有启动日志告警） |
| P-03 | **文件格式**：YAML front-matter（`task` / `structured` / `variant` / `temperature` / `max_tokens` / `inputs[]` / `output_key` / `preferred_backend`）+ 正文 `# SYSTEM` 与 `# USER` 两节；`{{变量名}}` 占位 | P0 | 13 个文件格式统一；`{{}}` 占位符与 `inputs[]` 声明一一对应 |
| P-04 | **内容来源搬运**：T1/T3/T4 从 `scripts/dify_t1_knowledge_extraction.yaml` / `dify_t3_prerequisite.yaml` / `dify_t4_gap_analysis.yaml` 的 `prompt_template` 原样搬运；T5 检测从 `agent_page.dart:197-203`、T8 从 `homework_page.dart:99-123` 的 Dart 硬编码模板搬运；T6/T7/T9/T10/T11/T12/T13 依据 `DIFY_WORKFLOW_BUILD_GUIDE.md` §4 契约新撰 | P0 | 搬运后**输出契约字段逐字不变**；T1 的 `source_quote` 锚点要求、`type` 枚举（概念/公式/定理/方法/事实/误区）原文保留 |
| P-05 | 每个提示词文件末尾固定附加「只输出 JSON，不要思考过程、不要 ```json 围栏」的收尾段（仅 structured 任务 + T5-detect + T8） | P0 | 与 §C2 容错形成双保险 |
| P-06 | `prompts/README.md`：写清「改哪个文件影响哪个功能」「如何热更新」「如何新增一个任务提示词」 | P1 | 新人按 README 能独立完成一次改提示词 + 验证 |

### 4.4 文档

| 编号 | 需求 | 优先级 | 验收标准 |
| --- | --- | --- | --- |
| D-01 | `llm_server/README.md`：安装、一行启动、config.yaml 字段说明、curl 冒烟示例、常见问题 | P0 | 照 README 从零跑通 T1 |
| D-02 | `docs/ARCHITECTURE.md` §6 增量更新：新增「LLM Server（第四协议）」小节；说明 `protocol` 取值变为 `openai / anthropic / dify / llm_server`；标注 Dify 为**已停用保留**状态 | P0 | §6 读起来能反映当前真实链路；原 Dify 小节打「已停用」标记而非删除 |
| D-03 | 本 PRD 附录 B「Dify 回退步骤」保持可用 | P0 | 三步可执行 |
| D-04 | `scripts/run_llm_server.bat`（Windows 双击启动） | P1 | 双击即起，端口 8787 |

---

## 5. 非功能需求

| 编号 | 需求 | 验收标准 |
| --- | --- | --- |
| N-1 | **本地离线可用** | Backend=ollama 且 `base_url=127.0.0.1` 时，断网后 T1/T3/T4/T5/T6 全部可用 |
| N-2 | **零外部服务依赖** | 除 LLM 后端本身外不需要 Docker / Redis / Dify / 任何云服务；进程数为 1（+ 可选 Ollama） |
| N-3 | **一行可跑** | `python llm_server/run.py`（默认 `127.0.0.1:8787`）即可；Windows 另提供 `.bat`。首次安装只需一条 `pip install -r` |
| N-4 | **密钥不入库** | 密钥不写进 Drift、不写进 Git；`.env` 进 `.gitignore`；App 侧 `api_key_ref` 只存引用名（llm_server 场景留空） |
| N-5 | **契约一致性** | §C1 表 13 行逐条有对应用例（至少 T1/T3/T4/T8/T5-detect 有真实端到端冒烟） |
| N-6 | **推理模型容错对等** | §C2 六层逻辑 6 个坏样本全通过（服务端 + Dart 双保险） |
| N-7 | **启动性能** | 服务启动（不含模型加载）< 3s；`GET /health` 响应 < 200ms（backend 探测可异步） |
| N-8 | **超时对齐** | 结构化任务默认超时 120s，与 App 侧 `AiProvider.runTask.timeout` 一致 |
| N-9 | **可观测** | 每一次任务调用在服务端日志有一行；App 侧 `AiTaskResult.latencyMs` / `modelId` 有值 |
| N-10 | **可回退** | 全程不删除任何 Dify 文件；回退见附录 B |

---

## 6. UI 设计稿（文字版）—— 设置页 AI Provider 配置区

### 6.1 Provider 卡片（列表项，改版后）

```
┌──────────────────────────────────────────────────────────────────────┐
│ ⚡  本地 LLM 服务                              [开关] [✏️] [🌐] [🗑]   │
│     http://127.0.0.1:8787 · ollama · qwen2.5:7b                      │
└──────────────────────────────────────────────────────────────────────┘
```
- 副标题三段：`base_url` · `backend` · `model`（model 为空时显示「后端默认」）。
- 🌐 = 测试连接（探 `GET /health`）；✏️ = 编辑；🗑 = 删除（连带清 SecretStore + 解绑路由，沿用既有逻辑）。
- 空态文案：`还没有 AI 服务。点右下角「添加 LLM 服务」创建一个。`

### 6.2 新增 / 编辑对话框字段布局

| 顺序 | 字段 | 控件 | 默认 / 取值 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | 显示名称 | TextField | `本地 LLM 服务` | 仅展示用 |
| 2 | Base URL | TextField | `http://127.0.0.1:8787` | 校验：必须 `http://` 或 `https://` 开头 |
| 3 | 后端 Backend | DropdownButton | `跟随服务端默认` / `ollama` / `minimax` / `openai_compat` | 选「跟随服务端默认」则不传 `backend`，由服务端 `config.yaml` 决定 |
| 4 | 模型 Model | TextField（可空） | 空 | 留空 = 用后端默认模型；填了则覆盖（如 `qwen2.5:7b` / `MiniMax-Text-01`） |
| 5 | 设为默认 | Switch | 新增时 true | 对应 `is_default`，决定通用任务回落 |
| — | ~~API Key~~ | **不显示** | — | 见 §C4：P0 密钥由服务端持有，App 不传 |

**持久化映射（受 §C6 约束，不改表结构）**：
- 字段 3 Backend → 写入 `ai_providers.type`（`auto` / `ollama` / `minimax` / `openai_compat`）
- 字段 4 Model → 写入 `ai_providers.models`（`[]` 或 `["<model>"]`，长度 ≤ 1）
- `api_key_ref` 恒为空字符串；`protocol = 'llm_server'`
- 读取时按同一映射反序列化；`type` 出现白名单外的值按 `auto` 处理，`models` 元素 >1 只取第 0 个

对话框底部固定提示条：
> 后端与模型在服务端 `llm_server/config.yaml` 也可配置；此处为按 Provider 覆盖。改 Base URL / Backend / Model 后需重启 App 生效。

### 6.3 AI 任务路由区（保留，仅改文案）

- 可绑定任务仍为 `T1 / T3 / T4`（`kRoutableTasks` 不变，与协议无关）。
- 说明文案改为：
  > 把任务绑到指定的 LLM 服务实例；T3 / T4 不绑就走本地兜底（AI 不参与）。绑定即时生效；新增 / 启用 Provider 仍需重启 App。
- 移除原「Dify 的 Key 是按应用签发的」段落。

### 6.4 底部说明区（改版后）

```
• 密钥仅保存在本机 SecretStore / 服务端 .env，不写入数据库；
• 增删 / 启停 Provider 后需重启 App 才生效；
• 任务路由绑定即时生效，无需重启；
• 本地服务（127.0.0.1）仅本机可用；公网场景请使用已配置 CORS 的代理。
```

---

## 7. 服务端目录与文件规范

```
llm_server/
├── run.py                 # 一行启动入口（默认 127.0.0.1:8787）
├── server.py              # FastAPI app 装配
├── requirements.txt       # fastapi / uvicorn / httpx / pyyaml（4 行）
├── .env.example           # MINIMAX_API_KEY= / OPENAI_API_KEY= / OLLAMA_BASE_URL=
├── .gitignore             # 忽略 .env
├── config.yaml            # default_backend / task_backends / backends.* / timeouts
├── README.md              # D-01
├── core/
│   ├── config.py          # config.yaml + .env 加载，热加载
│   ├── json_repair.py     # ★ §C2 六层容错移植
│   ├── errors.py          # ★ S-11 错误归一化
│   └── prompt_store.py    # ★ S-07/S-08/S-09 提示词加载 + 热更新
├── backends/
│   ├── base.py            # LLMBackend 抽象（complete / stream_complete / health）
│   ├── ollama.py
│   ├── minimax.py
│   ├── openai_compat.py
│   └── langchain_adapter.py   # 仅占位注释，不实现、不引入依赖
├── routers/
│   ├── tasks.py           # POST /v1/task/{code}
│   ├── chat.py            # POST /v1/chat（SSE）
│   ├── prompts.py         # GET/PUT /v1/prompts, POST reload
│   └── health.py          # GET /health
└── prompts/
    ├── index.yaml         # 任务 → 文件 映射 + 元信息
    ├── README.md
    ├── t1_extract.md  t2_normalize.md  t3_prerequisite.md  t4_gap_analysis.md
    ├── t5_ask.md  t5_ask__detect.md  t6_explain.md  t7_socratic.md  t8_quiz.md
    ├── t9_grade.md  t10_lecture.md  t11_summary.md  t12_title_tags.md
    └── t13_similarity.md
```

**端口约定**：`8787`（避免与 Ollama 11434 / Dify 8080 冲突）。

**提示词文件示例（`t1_extract.md`）**

```markdown
---
task: T1
structured: true
temperature: 0.2
max_tokens: 4096
inputs: [note_text]
output_key: knowledge_points
preferred_backend: ollama
---

# SYSTEM
你是一名严谨的「知识点提取器」，服务于一款叫 AIMindTree 的 AI 知识笔记 App。
你的唯一任务：把用户给出的一段学习笔记，拆解为独立、可复用的「知识点」。

# USER
请提取下面这段笔记中的知识点。

# 笔记原文
{{note_text}}

# 输出要求（严格遵守）
1. 只输出一个 JSON 对象，不要任何解释、前后缀或 Markdown 代码块标记。
2. 结构固定为：
   {"knowledge_points":[{"name":"…","type":"概念|公式|定理|方法|事实|误区",
    "definition":"…","source_quote":"…","prerequisites":["…"],"confidence":0.0}]}
3. source_quote 必须逐字出现在原文里；否则给空字符串 ""，但知识点仍可保留。
4. 不要编造原文没有的定义；无法确认的在 definition 里标注「（待确认）」。
5. prerequisites 只写名称，不要写解释。
```

---

## 8. 验收与门禁

| 层级 | 手段 | 说明 |
| --- | --- | --- |
| 服务端 | `python -m pytest`（若环境可用）或 `python llm_server/selftest.py` | 至少覆盖 §C2 的 6 个坏样本 + 13 个任务的契约字段校验 |
| 服务端 | `docs/PRD_LLM_SERVER.md` D-01 的 curl 冒烟 | T1/T3/T4 各一条 |
| 客户端 | **`aimindtree_app/tool/analyze_inproc.dart`（唯一门禁）** | error **和 warning** 都算失败，见附录 A |
| 端到端 | `aimindtree_app/tool/smoke_ai_service.dart`（改指向 llm_server） | T1 真实跑通并落库 |

---

## 9. 待确认问题（需工程师 / 架构师拍板）

| # | 问题 | 我的建议 | 影响 |
| --- | --- | --- | --- |
| Q1 | `AiProvider.streamChat` 增加可选参数 `AiTask? task` / `String? variant` 是否接受？ | **已裁决：接受**。可选参数 → `teacher_page` / `homework_page` 零改动；`ai_service.dart` +2 行透传（§1.2 例外），`agent_page.dart` +1 行 | **阻塞** T5/T6/T8 按任务装载提示词（§C3） |
| Q2 | T5 双形态（自由问答 vs JSON 检测）如何区分？ | **已裁决**：`variant` 唯一取值 `'detect'` → `t5_ask__detect.md`；**T8 不设 variant**，其 JSON 契约继续留在 App 端拼的 query 里，服务端 `t8_quiz.md` `# USER` 只做 `{{query}}` 透传 + JSON-only 收尾 | 收敛后 variant 只有一个取值，传错也不退化（§C3 降级安全） |
| Q3 | 密钥归属：P0 是否接受「服务端持 Key、App 不传」？ | 接受（§C4） | 若坚持 App 传，需改 SecretStore 链路 + 设置页增 Key 字段 |
| Q4 | 多轮会话历史由谁维护？ | P0 服务端**无状态**，历史由 App 拼进 `query`（与现状一致），`conversation_id` 由服务端生成回显 | 若要做服务端历史需新增存储，本 PRD 不覆盖 |
| Q5 | 服务进程如何拉起？手动 / App 内 spawn 子进程 / 开机自启？ | P0 手动（README + .bat）；P2 再考虑 App 内拉起 | 影响 N-3「一行可跑」的用户体感 |
| Q6 | 端口 8787 是否冲突？是否需可配置？ | 8787，且 `config.yaml` 与 `run.py --port` 可改 | 冲突则 App 侧默认 Base URL 需同步改 |
| Q7 | `LocalAiConfig` 里的硬编码 Dify Key 是否本次一并删除并作废？ | **是**（§C4） | 不处理 = 已泄露的 Key 继续留在代码里 |
| Q8 | `test/dify_parse_structured_test.dart` 与 `tool/smoke_ai_service.dart` 的处置？ | 前者改指向 `StructuredText.parse`（或改名 `structured_parse_test.dart`）；后者改指向 llm_server | 直接删除会丢失 §C2 的回归保护 |
| Q9 | MiniMax Coding Plan 走哪套端点/鉴权？（Anthropic 兼容 `/anthropic` vs OpenAI 兼容 `/v1`，见 ARCH §6 末尾） | 需用户提供 Key 与实际文档后确认；**httpx 转发 OpenAI 兼容优先**，Anthropic 形态放 P1 | 决定 `MiniMaxBackend` 的实现形态 |
| Q10 | 结构化输出是否启用 JSON Mode / `response_format={"type":"json_object"}`（Ollama 支持 `format=json`）？ | P0 先**不依赖**（ARCH §6 明确「架构上不依赖原生结构化输出」），靠提示词 + §C2 容错；P1 再加 | 启用会显著降容错压力，但部分端点不支持 |
| Q11 | `parsed` 由服务端解析还是 App 端再解析一次？ | **双保险**：服务端解析并回填 `parsed`，App 端对 `content` 再跑一次 `StructuredText.parse` 兜底 | 只做单边会在某一环失效时静默降级 |
| Q12 | Ollama 本地 7B 模型 JSON 遵循差，是否按任务强制走云端（ARCH §6 建议 T1/T3/T8 强制云端）？ | `config.yaml` 用 `task_backends` 表达，默认 T1/T3/T8 → minimax，其余 → ollama；用户可改 | 影响默认体验与成本 |
| Q13 | 是否需要服务端用量统计落盘 / 成本视图？ | P2，不在本次范围 | — |
| Q14 | Dify 相关文档（`DIFY_WORKFLOW_BUILD_GUIDE.md` 等）是否保留？ | **全部保留**，在文件头加「已停用，仅供回退参考」标记 | 与「保留 Dify 技术方案」决策一致 |
| Q15 | Backend / Model 复用 `type` / `models` 列（§C6）是否接受为临时方案？ | **已裁决：接受**（本轮禁止改表，`build_runner` 不可用）。语义白名单写进 `tables.dart` 注释；`build_runner` 可用后应改为真正新增 `backend` / `model` 两列 | 技术债；不改表则无 migration 风险 |
| Q16 | Dify 代码「停用」两种口径（§C7）是否确认？ | **已裁决：确认**。三个 UI/客户端文件整段注释（口径 A）；`settings_repository.dart` 的 `addDifyProvider` / `testDify` 保留代码 + 普通停用注释（口径 B，因 14 处测试调用，且 `@Deprecated` 会触发门禁 warning） | 一刀切注释会导致测试编译失败或门禁 warning 失败 |

---

## 附录 A · 环境约束

- **操作系统**：Windows；用户 Python 为托管版
  `C:\Users\ASUS\.workbuddy\binaries\python\versions\3.13.12\python.exe`
- **安装依赖（一行）**
  `C:\Users\ASUS\.workbuddy\binaries\python\versions\3.13.12\python.exe -m pip install -r llm_server\requirements.txt`
- **启动服务（一行）**
  `C:\Users\ASUS\.workbuddy\binaries\python\versions\3.13.12\python.exe llm_server\run.py`
- **Flutter 侧门禁**：本沙箱 `flutter` / `dart analyze` / `build_runner` / `flutter test` 均被 WSL 黑名单拦截。
  **唯一可用门禁**是同进程 analyzer 脚本（error + warning 都算 fail）：

  ```bash
  cd aimindtree_app && D:/DevTools/flutter/bin/cache/dart-sdk/bin/dart.exe tool/analyze_inproc.dart
  ```

- **Bash 参数中文会触发沙箱异常**：所有脚本 / 命令参数一律使用 ASCII，中文只出现在文件内容里。
- 服务端建议同时提供 `scripts/run_llm_server.bat`，双击即可启动（内部调用上面的 Python 路径）。

---

## 附录 B · Dify 回退步骤（三步）

1. 反注释**口径 A** 的三个文件（§C7）：`aimindtree_app/lib/ai/clients/dify_client.dart`、
   `aimindtree_app/lib/features/settings/dify_add_dialog.dart`、
   `aimindtree_app/lib/features/settings/dify_edit_dialog.dart`（均为整段注释态，去掉注释符号即可）。
   —— **口径 B** 的 `settings_repository.dart`（`addDifyProvider` / `testDify`）本来就保留着可用代码，只需去掉停用注释。
2. `ExtractionService.bootstrap` 中把 `protocol == 'llm_server'` 分支切回 `protocol == 'dify'`
   （启用 P2 的 `kEnableDify` 常量后只需改常量 + 环境变量 `AIMINDTREE_AI_PROTOCOL=dify`）。
3. `settings_repository.seedFromLocalIfEmpty` 切回 seed `dify` 行；设置页恢复「添加 Dify」入口；
   移除 `agent_page.dart` 的 `variant: 'detect'`（可选：服务端若已下线，该参数无害）。

> 回退后需在 Dify 控制台重新发布工作流并把 Key 填回设置页（Key 已于 §C4 作废，需重新生成）。
> 提示词可从 `llm_server/prompts/*.md` 复制回 Dify 的 LLM 节点，内容完全兼容。

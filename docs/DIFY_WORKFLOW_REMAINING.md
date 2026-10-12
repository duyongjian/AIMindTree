# Dify 工作流 · 剩余工作清单（可执行版）

> 来源：对当前代码库 + `scripts/*.yaml` + `docs/*` 的只读盘点（2026-10-12）。  
> 用途：照着这份清单，在本地 Dify（`http://localhost:8080`）把还没做的工作流补齐。

---

## 一、机制速览（先看这 3 条，其余都好懂）

1. **13 类任务 T1–T13**，两类端点：
   - `structured = true` → `POST /v1/workflows/run`（**工作流应用**，读 `data.outputs`）
   - `structured = false` → `POST /v1/chat-messages`（**聊天应用**，读 `answer`）
2. **路由优先级**：`ai_task_routes` 专属绑定 → provider；**只有 T3/T4 走专属路由**，未绑定即 `Failure`（无本地兜底）；其它任务未绑定则回落到「默认 provider」。
3. **一个 Dify 应用 = `ai_providers` 一行**，API Key 存 SecretStore。所以在 Dify 里建几个应用，App 侧就要加几条 provider 并按需绑定。

---

## 二、现状总表

| 任务  | 名称    | 类型       | 端点            | DSL 文件                                      | 部署 | App 可用    | 说明                                                                                                                  |
| --- | ----- | -------- | ------------- | ------------------------------------------- | -- | --------- | ------------------------------------------------------------------------------------------------------------------- |
| T1  | 知识提取  | workflow | workflows/run | `scripts/dify_t1_knowledge_extraction.yaml` | ✅  | ✅         | inputs `{note_text: <段落>}`，End 输出 **`knowledge_points`**。已端到端验证，提取 tab 在跑 |
| T2  | 规范化   | workflow | workflows/run | ❌                                           | ❌  | ❌         | App 有枚举，**无 UI 调用**                                                                                                 |
| T3  | 前置推断  | workflow | workflows/run | `scripts/dify_t3_prerequisite.yaml`         | ✅  | ✅         | **专属**，inputs `{points: <JSON 字符串>}`，End 输出 **`prerequisites`**                                                     |
| T4  | 缺口分析  | workflow | workflows/run | `scripts/dify_t4_gap_analysis.yaml`         | ✅  | ✅         | **专属**，inputs `{target, depth, depth_instruction}`，End 输出 **`gaps`**                                                |
| T5  | 追问/对话 | chat     | chat-messages | ❌                                           | ❌  | ⚠️**跑不通** | 走聊天端点，但默认 provider 是 T1 的**工作流应用** → 会报错。见 P0                                                                       |
| T6  | 讲解    | chat     | chat-messages | ❌                                           | ❌  | ⚠️**跑不通** | 同上                                                                                                                  |
| T7  | 苏格拉底  | chat     | chat-messages | ❌                                           | ❌  | ❌         | 无 UI                                                                                                                |
| T8  | 出题    | chat     | chat-messages | ❌                                           | ❌  | ⚠️**跑不通** | 作业页已调 T8，但同 P0 不可用                                                                                                  |
| T9  | 批改    | workflow | workflows/run | ❌                                           | ❌  | ❌         | 无 UI                                                                                                                |
| T10 | 讲义    | chat     | chat-messages | ❌                                           | ❌  | ❌         | 无 UI                                                                                                                |
| T11 | 总结    | chat     | chat-messages | ❌                                           | ❌  | ❌         | 无 UI                                                                                                                |
| T12 | 标题/标签 | workflow | workflows/run | ❌                                           | ❌  | ❌         | 无 UI                                                                                                                |
| T13 | 相似度   | workflow | workflows/run | ❌                                           | ❌  | ❌         | 无 UI                                                                                                                |

---

## 三、剩余工作（按优先级）

### 🔴 P0 —— 让「聊天类」任务真正能跑（T5 / T6 / T8）

**问题根因**：T5/T6/T8 走 `/v1/chat-messages`，但当前默认/回落 provider 是 **T1 的工作流应用**，调聊天端点必然报错 → 现在这三个功能实际不可用。T5/T6/T8 **不在可路由任务集**里（只有 T3/T4 能单独绑），所以只能靠「默认 provider」或「fallback 指向聊天应用」。

**要做的**：

1. 在 Dify 建一个 **Chat 应用**（例如「AI MindTree 问答 / 出题 / 讲解」）。
2. 把它的 API Key 作为一个新 provider 加进 App（设置页），并**设为默认 provider**（`isDefault = true`），或让 fallback 指向它。
3. 契约（App 侧 `runTask` 取回 chat 的 `answer` 文本）：

| 任务 | 端点            | 输入（App 实际发送）                        | 期望输出                                                     |
| -- | ------------- | ----------------------------------- | -------------------------------------------------------- |
| T5 | chat-messages | `query` = 纯文本（用户问题，或「检测」提示词）        | 纯文本 `answer`；「检测」场景期望 **JSON** `{"needed":[],"weak":[]}` |
| T6 | chat-messages | `query` = 含「知识点名称 / 定义 / 原文引用」的纯文本  | 纯文本 `answer`                                             |
| T8 | chat-messages | `query` = 含「薄弱点 + 难度 / 数量 / 要求」的纯文本 | 文本，App 解析出 `[{kpName,type,question,answer,difficulty}]`  |



> **更干净的替代方案（可选）**：改 Flutter 侧把 T5/T6/T8 也纳入「可路由任务」，各绑独立应用，就不必共享一个 chat 应用。这属于代码改动（`ai_task.dart` + 路由白名单）。

### 🟡 P1 —— 核对 T1 / T3 / T4（已可用，仅需确认绑定）

- **T1**：`scripts/dify_t1_knowledge_extraction.yaml`；inputs `{note_text: <段落>}`；End 输出变量 **`knowledge_points`**。**已部署可用**（`note_text` 须为「段落」类型，短文本 256 上限会 400）。
- **T3**：`scripts/dify_t3_prerequisite.yaml`；inputs `{points: "<JSON 字符串>"}`（⚠️ 是 **string**，不是数组）；End 输出 **`prerequisites`**。**专属绑定**。
- **T4**：`scripts/dify_t4_gap_analysis.yaml`；inputs `{target, depth, depth_instruction}`（⚠️ `depth_instruction` **必填**，缺了返回 400）；End 输出 **`gaps`**。**专属绑定**。
- **确认项**：设置页里 **T3 / T4 各自绑定到一个 provider**，否则画布「自动连线 / 补前置」会直接失败。

### 🟢 P2 —— 未接线任务（先改 Flutter，再建 Dify）

**T2 / T7 / T9 / T10 / T11 / T12 / T13 目前没有任何 UI 调用**（App 里有枚举、无使用者）。  
要落地必须两步走：

1. **先在 Flutter 侧接入**（加 UI 入口 + 调 `runTask` + 解析输出 + 落库/展示）；
2. 再在 Dify 建对应应用（T2/T9/T12/T13 → 工作流应用；T7/T10/T11 → 聊天应用），并把 End 输出变量名对齐 App 解析器。

> 只建 Dify 不改 App，这些任务不会被触发。

---

## 四、三个必踩的坑（务必对照自检）

1. **fallback 是工作流应用** → 所有聊天类任务（T5/T6/T8/T7/T10/T11）跑不通。见 P0。
2. **T3/T4 未绑定 = 直接失败**（无本地启发式兜底）。设置页绑定即可。
3. **DSL 导入后的两件事**：① 记得**发布**工作流；② 每个 LLM 节点要**手动选实际模型**（DSL 里是占位的 `ollama/llama3`），否则调用报错。

补充：Dify 结构化输出对推理模型的 `<think>…</think>` 包裹有容错（App 三层解析），但**End 节点输出变量名**必须与上表一致，否则字段取不到。

---

## 五、逐工作流「输入 → 输出」契约明细

| 任务  | 端点            | 请求关键字段                                      | 响应取值路径         | 输出变量名（End 节点）                        | 若缺失的后果        |
| --- | ------------- | ------------------------------------------- | -------------- | ------------------------------------ | ------------- |
| T1  | workflows/run | `inputs.note_text`                          | `data.outputs` | `knowledge_points`                   | 提取不出知识点       |
| T2  | workflows/run | `inputs.*`                                  | `data.outputs` | 约定名（未接线）                             | —             |
| T3  | workflows/run | `inputs.points`（**JSON 字符串**）               | `data.outputs` | `prerequisites`                      | 自动连线失败        |
| T4  | workflows/run | `inputs.target / depth / depth_instruction` | `data.outputs` | `gaps`                               | 补前置失败（400 或空） |
| T5  | chat-messages | `query`                                     | `answer`       | —（文本）                                | 追问/检测失败       |
| T6  | chat-messages | `query`                                     | `answer`       | —（文本）                                | 讲解失败          |
| T7  | chat-messages | `query`                                     | `answer`       | —（文本）                                | 未接线           |
| T8  | chat-messages | `query`                                     | `answer`       | —（文本，内含 JSON）                        | 出题失败          |
| T9  | workflows/run | `inputs.*`                                  | `data.outputs` | 约定名（未接线）                             | —             |
| T10 | chat-messages | `query`                                     | `answer`       | —（文本）                                | 未接线           |
| T11 | chat-messages | `query`                                     | `answer`       | —（文本）                                | 未接线           |
| T12 | workflows/run | `inputs.*`                                  | `data.outputs` | 约定名（未接线）                             | —             |
| T13 | workflows/run | `inputs.*`                                  | `data.outputs` | 约定名（未接线）                             | —             |

> 说明：`runTask` 对**非 T1/T3/T4** 的 workflow 任务，取 `outputs` 的**第一个值**作为文本；T1/T3/T4 有专用解析器。

---

## 六、建议的动手顺序

1. **P0**：建 1 个 Chat 应用 → 加 provider → 设默认 → 验证 T5/T6/T8 能出文本。
2. **P1**：确认 T3/T4 已在设置页绑定（各一个 provider）。
3. **P2**：与需求方确认 T2/T7/T9–T13 哪些要做，先补 Flutter 接线，再建 Dify 应用。

---

## 七、参考位置

- DSL 样例：`scripts/dify_t1_knowledge_extraction.yaml`、`scripts/dify_t3_prerequisite.yaml`、`scripts/dify_t4_gap_analysis.yaml`
- 冒烟脚本：`scripts/test_dify_t3_t4.sh`、`scripts/test_dify_workflow.sh|ps1`
- 文档：`docs/WORKFLOW_T3_T4_GUIDE.md`、`docs/DIFY_KNOWLEDGE_WORKFLOW.md`、`docs/PRD_T4_DEPTH_SUPPLEMENT.md`、`docs/ARCH_T4_DEPTH_SUPPLEMENT.md`
- App 侧任务定义与路由：`aimindtree_app/lib/ai/ai_task.dart`、`lib/ai/ai_task_router.dart`（映射表）、`lib/ai/ai_service.dart`、`lib/ai/extraction_service.dart`、`lib/ai/auto_graph_service.dart`
- 绑定与 provider 表：`aimindtree_app/lib/data/db/tables.dart`（`ai_providers` / `ai_task_routes`）

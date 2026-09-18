# Dify 后端：知识点提取工作流（T1）

> 对应 `ARCHITECTURE.md` 的任务路由：T1 提取 / T2 规范化 / T3 前置推断 / T8 出题 / T9 批改 → **Dify Workflow**（`/v1/workflows/run`，blocking，结构化 outputs）。

本文件是「先跑通 Dify 后端」这一步的**交接单**。你只需在浏览器里照做 4 步，剩下由我（在拿到 API Key 后）用 curl 验证并写进 App。

---

## 0. 前置（一次性）

1. 打开 **Docker Desktop**（本机重启后它没自启，必须手动开）。
2. 在 `D:\dify\docker` 执行：
   ```bash
   docker-compose up -d
   ```
   > 迁移已在上一轮修好并持久化（`alembic_version=f051706725cc`），**不会**再出现 Internal server error / 500。
3. 浏览器打开 `http://localhost:8080/install` → 创建管理员账号（邮箱+密码随意，本地用）。
4. 登录后进入控制台。

---

## 0.5 方式二：DSL 一键导入（推荐，省去拖节点）

已备好可直接导入的工作流定义：`scripts/dify_t1_knowledge_extraction.yaml`。

1. 控制台右上角 **「创建应用」** → **「导入 DSL」**（或「创建应用」弹窗里的「导入 DSL 文件」）。
2. 选择 `scripts/dify_t1_knowledge_extraction.yaml` → 确认导入。
3. **导入后必须做两件事**：
   - 打开 **LLM 提取** 节点 → 在「模型」里选一个你已配置的模型（DSL 里的 `provider: ollama / name: llama3` 是占位符，需改成你实际配置的模型，否则节点报错）。
   - 点右上角 **「发布 / 更新发布」**（不发布则 `/v1/workflows/run` 返回 404）。
4. 进入该应用 → **「访问 API」** → 生成 API Key（见 §4）。

> 想完全手动照抄节点也行，见下方 §1–§4；两者结果等价。

---

## 1. 新建 Workflow 应用（手动方式，与 §0.5 二选一）

- 控制台右上角 **「创建应用」** → 选择 **「工作流 / Workflow」** → 命名 `AIMindTree 知识点提取`（英文 slug 随意）。
- 进入编排画布。

## 2. 节点配置（照抄）

### ① 开始节点（Start）
添加**输入变量**：
| 变量名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `note_text` | String(Paragraph) | 是 | 用户一条笔记/段落原文 |

### ② LLM 节点
- Model：选你已配置的供应商模型（本地 Ollama 或云端均可；建议用支持 JSON 输出的模型）。
- **System 提示词**：
```
你是一名严谨的「知识点提取器」，服务于一款叫 AIMindTree 的 AI 知识笔记 App。
你的唯一任务：把用户给出的一段学习笔记，拆解为独立、可复用的「知识点」。
```
- **User 提示词**（用 `{{#start.note_text#}}` 引用输入）：
```
请提取下面这段笔记中的知识点。

# 笔记原文
{{#start.note_text#}}

# 输出要求（严格遵守）
1. 只输出一个 JSON 对象，不要任何解释、前后缀或 Markdown 代码块标记。
2. 结构固定为：
{
  "knowledge_points": [
    {
      "name": "知识点名称（名词短语，≤ 20 字）",
      "type": "概念|公式|定理|方法|事实|误区",
      "definition": "一句话清晰定义（≤ 60 字）",
      "source_quote": "从原文中逐字摘抄的、能支撑该知识点的原句（必须能在原文中找到，否则留空字符串）",
      "prerequisites": ["学习本知识点前应先掌握的 0~3 个前置知识点名称，没有则为空数组"],
      "confidence": 0.0~1.0 的小数，表示你对这条提取的把握
    }
  ]
}
3. source_quote 必须逐字出现在原文里；若原文没有明确支撑句，source_quote 给空字符串 ""，但知识点仍可保留。
4. 不要编造原文没有的定义；无法确认的放在 definition 里标注「（待确认）」。
5. prerequisites 只写「名称」，不要写解释。
```

### ③ 结束节点（End）
- 输出变量名：`knowledge_points`（类型 Text）
- 值：引用 LLM 节点的**文本输出**（即上面那段 JSON 字符串）。
- 这样 `/v1/workflows/run` 返回的 `outputs.knowledge_points` 就是那段 JSON，App 端 `jsonDecode` 即可。

> 可选增强（P1 再做）：在 LLM 后加一个「直接回复 / 代码执行」节点用 `json.loads` 校验，失败则让 LLM 重答。P0 先不复杂化。

## 3. 发布（⚠️ 关键，漏了 API 必 404/失败）

编排完必须点画布右上角 **「发布」→「更新发布」**（或「运行」旁的下拉）。**只有在「已发布」状态下，`/v1/workflows/run` 才能调用**，否则返回 `app not found / 404`。

## 4. 拿到 API Key

- 进入该应用 → 顶部 **「访问 API」** 标签页。
- 点 **「API Key」→「生成」**，复制那一串 `app-xxxx...`。
- 这就是 `DifyClient.appApiKey`（**应用级 Key，不是 Dify 账号 Key**）。

把 Key 发给我（或自己先存好），下一步我来：
- 用 `scripts/test_dify_workflow.sh` 跑通 `POST /v1/workflows/run`；
- 把 Key 配置进 App 的 `ai_providers`（本地安全存储，S4 不跨端同步）。

---

## 5. 接口契约（与 App 端 `DifyClient.runWorkflow` 对齐）

```
POST http://localhost:8080/v1/workflows/run
Headers:
  Authorization: Bearer <APP_API_KEY>
  Content-Type: application/json
Body:
{
  "inputs": { "note_text": "（笔记原文）" },
  "response_mode": "blocking",
  "user": "aimindtree-app"   // ⚠️ 必填，Dify 用它做调用追踪；缺了直接 400 "Arg user must be provided."
}
Response.data.outputs.knowledge_points: "<JSON 字符串>"
```

- `base_url` = `http://localhost:8080`（nginx 对外端口，不是容器 5001）。
- 桌面端开发期可直连本地 Dify；**公网/云端 Key 一律走 supabase 代理**（ARCHITECTURE §9.1 安全边界）。

---

## 6. 验证脚本

见 `scripts/test_dify_workflow.sh`（PowerShell 见同目录 `.ps1`）。填好 Key 后：

```bash
DIFY_API_KEY="app-xxxx..." bash scripts/test_dify_workflow.sh
# 或
$env:DIFY_API_KEY="app-xxxx..."; pwsh scripts/test_dify_workflow.ps1
```

期望输出包含 `knowledge_points` 且能 `jsonDecode` 成功 → 后端跑通。

---

## 7. 排错（实测踩坑）

### 7.1 `400 "Arg user must be provided."`
`/v1/workflows/run` 必须带 `user` 字段（任意非空字符串，用于调用追踪）。验证脚本已默认补 `aimindtree-test`；App 端 `DifyClient.runWorkflow` 调用时也务必带上。

### 7.2 `HTTP 200` 但 `data.status: "failed"`，`error: "Variable #start.note_text# not found"`
**现象**：`/v1/parameters` 显示 Start 节点确实有 `note_text`（text-input, required），但 LLM 节点运行报「变量找不到」。
**根因**：LLM 节点 prompt 里的 `{{#start.note_text#}}` 是**手写进去的纯文本**，没走变量选择器，所以没被登记进节点变量表；运行时变量解析器只认「登记过的引用」，于是报 not found。
**修法（在 Dify 控制台，手动）**：
1. 打开 T1 工作流 → 点 **LLM 提取** 节点。
2. 把 prompt 里手写的 `{{#start.note_text#}}` **删掉**。
3. 点 prompt 框下方的 **`{}` 变量插入按钮**（或在输入框里敲 `/` 唤起选择器），从 `start` 下选 **`note_text`** —— 让它自动插入 `{{#start.note_text#}}`。
4. 点右上角 **「发布 / 更新发布」**（否则还是跑旧的已发布图）。
5. 用脚本重跑：`DIFY_API_KEY="app-..." bash scripts/test_dify_workflow.sh`，应返回 `✅ 知识点提取成功，条数 = N`。

> 同理，若 End 节点的 `knowledge_points` 没正确引用 LLM 文本输出，也会在 End 阶段报类似 not found —— 同样用变量选择器重选一次再发布即可。

### 7.3 返回 200 但 JSON 解析失败（推理模型 `<think>` 块）
**现象**：`status: "succeeded"`、`outputs.knowledge_points` 有值，但 App 端 `jsonDecode` 抛异常 / 验证脚本报 `Expecting value: line 1 column 1`。
**根因**：选了**推理模型**（DeepSeek-R1 / Qwen 等），模型在 JSON 前吐了 `<think>...</think>` 思考块（或偶尔用 ` ```json ` 代码块包裹），把契约要求的纯 JSON 包住了。
**修法**：
- 验证脚本已自动剥离 `<think>` / 代码块再解析（`scripts/test_dify_workflow.sh` 与 `.ps1`）。
- Flutter 端 `DifyClient.DifyResult.fromRaw` 已内置 `_parseStructured`：统一去 `<think>`、去代码块、截取最外层 `{…}`/`[…]` 再 `jsonDecode`，推理模型也不崩。
- 若想从根上干净：换非推理模型（如普通 chat 模型），或在 LLM 节点提示词末尾强制「禁止输出任何思考过程，只输出 JSON」；但**客户端容错剥离是必做的**，不依赖模型听话。

### 7.4 中文笔记直接崩：`Invalid argument (string): Contains invalid characters.`
**现象**：App 端/Dart 脚本调用 T1 提取中文笔记时抛异常，异常里能看到拼好的 body 字符串。
**根因**：`HttpClientRequest.write(String)` 默认按 **latin1** 编码写 body，遇到中文（非 latin1 字符）直接抛 `Invalid argument`。**curl 测试不会暴露**（curl 走 UTF-8），所以只有真跑 Dart 端到端才会炸。
**修法（已修进 `DifyClient`）**：
- 用 **UTF-8 字节写入**：`req.add(utf8.encode(body))`，不要用 `req.write(body)`；
- 请求头声明 charset：`'Content-Type': 'application/json; charset=utf-8'`。
- 影响面：`runWorkflow` 与 `chatMessages` 两处都改（本 App 全是中文语料，属必改项）。
> **教训**：凡是「请求体能出现非 ASCII」的接口，客户端一律显式 UTF-8 编码 + 声明 charset。端到端冒烟脚本 `tool/smoke_extract.dart` 就是为抓这类问题而存在的——静态分析和 curl 都发现不了。


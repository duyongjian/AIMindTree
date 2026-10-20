# 提示词资产（改这里 = 改 AI 的行为，不用重启服务）

> 本目录是「AI 说什么」的**唯一真相源**。改完 md 不用重启进程：
>
> ```bash
> curl -X POST http://127.0.0.1:8787/v1/prompts/reload
> ```
>
> 或直接 `PUT /v1/prompts/T1?reload=true` 写回（body: `{"content": "<完整 md>"}`）。

---

## 1. 改哪个文件影响哪个功能

| 文件 | 任务 | 触发位置（App 侧） | 输出形状 |
| --- | --- | --- | --- |
| `t1_extract.md` | T1 知识点提取 | 笔记页「AI 提取」→ `ExtractionService.extract` | `{knowledge_points:[{name,type,definition,source_quote,prerequisites[],confidence}]}` |
| `t2_normalize.md` | T2 知识点规范化 | 预留（P2） | `{normalized:[{name,type,definition,merged_from[]}]}` |
| `t3_prerequisite.md` | T3 前置知识推断 | 知识树自动连线（`ai_task_routes` 专属绑定） | `{prerequisites:[{from,to,reason}]}` |
| `t4_gap_analysis.md` | T4 知识缺口分析 | 知识点详情「补前置」（专属绑定） | `{gaps:[{name,type,definition,reason,level}]}`（`level` 恒 1） |
| `t5_ask.md` | T5 追问 / 自由问答（**主形态，无 variant**） | `agent_page` 问答、`teacher_page` 追问 | 纯文本 |
| `t5_ask__detect.md` | T5 薄弱点检测变体（`variant='detect'`） | `agent_page._runDetection` | `{needed:[…],weak:[…]}` |
| `t6_explain.md` | T6 讲解 | `teacher_page` 讲解 Tab | 纯文本 |
| `t7_socratic.md` | T7 苏格拉底引导 | 预留（P2） | 纯文本 |
| `t8_quiz.md` | T8 出题 | `homework_page._buildPrompt()` | JSON **数组** `[{kpName,type,question,answer,difficulty}]` |
| `t9_grade.md` | T9 批改与误区 | 预留（P2） | `{correct,reason,misconception,suggestion}` |
| `t10_lecture.md` | T10 讲义生成 | 预留（P2） | Markdown |
| `t11_summary.md` | T11 总结 | 预留（P2） | 纯文本 |
| `t12_title_tags.md` | T12 标题与标签 | 预留（P2） | `{title,tags[]}` |
| `t13_similarity.md` | T13 知识点相似度 | 预留（P2） | `{similarities:[{a,b,score}]}` |

---

## 2. 文件格式

````markdown
---
task: T1                 # 必填，大小写不敏感（服务端统一 upper）
variant: detect          # 可选，变体名（主形态省略）
structured: true         # 必填，true → /v1/task/{code}；false → /v1/chat
json_output: true        # 必填，structured 任务恒 true；T5-detect / T8 也 true
temperature: 0.2         # 必填
max_tokens: 4096         # 必填
inputs: [note_text]      # 必填，占位符名清单
output_key: knowledge_points   # 可选，结构化输出的顶层 key（仅校验与日志用）
preferred_backend: ollama      # 可选，P0 不强制（D11）
---

# SYSTEM
（系统人格，映射到 messages[0].role='system'）

# USER
（用户消息，{{占位符}} 会被渲染）
````

规则：

- 正文**必须且只能**有 `# SYSTEM` 与 `# USER` 两个一级标题（大小写敏感）。
- `{{name}}` 必须与 `inputs[]` 一一对应；多一个 / 少一个会在 `GET /v1/prompts`
  里标 `placeholders_mismatch: true`，并打 WARN 日志。
- 渲染是**纯字符串替换**（不转义、不递归），所以原文里的 `{{` 不会被二次解析。
- **structured 任务 + T5-detect + T8** 的末尾必须有第 6 条
  「只输出 JSON，不要输出思考过程，不要用 ```json 围栏包裹」。

### 2.1 ⚠️ 两个「透传」文件：不要在里面重复编写要求

`t8_quiz.md` 与 `t5_ask__detect.md` 是**唯一的两个例外**——App 端已经把
完整 prompt 拼好放在 `query` 里了：

| 文件 | App 侧拼装位置 |
| --- | --- |
| `t8_quiz.md` | `features/homework/homework_page.dart` 的 `_buildPrompt()`（薄弱点清单 + 题型 + 难度 + JSON 数组格式） |
| `t5_ask__detect.md` | `features/agent/agent_page.dart` 的 `_runDetection()`（对话记录 + `{needed,weak}` 结构要求） |

所以这两个文件的 `# USER` **只做 `{{query}}` 透传 + 一句 JSON-only 收尾**。
**绝对不要**把出题要求 / 检测要求再写一遍——两段要求叠加会让模型输出混乱。

其余 12 个任务服务端是**唯一提示词来源**，必须写完整。

### 2.2 variant：唯一取值 `detect`，且传错不会污染输出

- variant 的**唯一取值就是 `detect`**，不要为其它任务设计 variant。
- 服务端按 variant **精确匹配、不做任何内容嗅探**（不根据 query 里有没有
  "JSON" 猜意图）。
- `/v1/chat` 上若变体未加载 / variant 传错 → **回退到主形态** `t5_ask.md`，
  不抛 `unknown_task`、不打断会话。于是最坏情况 =「没加载服务端变体提示词」：
  - 自由问答**绝不会**被污染成 JSON（主形态默认自然语言）；
  - 检测场景退化成自由文本，客户端 `agent_page._parseDetection` 解析失败后
    静默忽略，不会崩。
- `/v1/task/{code}`（结构化任务）上 variant 未命中**不回退**，直接
  `unknown_task` 400 —— 结构化任务回退会改变输出形状，显式报错比给错形状安全。

---

## 3. 如何新增一个任务

1. 新建 `<任务小写>_<英文名>.md`（变体用 `<任务小写>_<英文名>__<variant>.md`）；
2. 按上面模板写 front-matter 与 `# SYSTEM` / `# USER`；
3. 在 `index.yaml` 加一行 `T14: t14_xxx.md`；
4. `python llm_server/selftest.py` 校验契约；
5. `curl -X POST http://127.0.0.1:8787/v1/prompts/reload`（不用重启服务）。

---

## 4. 排查「AI 输出的形状不对」

1. `curl http://127.0.0.1:8787/v1/prompts` 看 `placeholders_mismatch` 与 `errors`；
2. `python llm_server/selftest.py` 跑六层容错 + 契约；
3. 用 `--verbose` 起服务（`scripts/run_llm_server.bat --verbose`），
   日志里会打印完整 prompt 与模型原始输出；
4. 若模型稳定输出 `<think>` / ```json 围栏，`core/json_repair.py` 已覆盖，
   不用改提示词；若输出被截断，调大 `max_tokens` 或换更强的模型。

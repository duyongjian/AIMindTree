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
| `t5_ask.md` | T5 追问 / 自由问答 | `agent_page` 问答、`teacher_page` 追问 | 纯文本 |
| `t5_ask__detect.md` | T5 薄弱点检测变体 | `agent_page._runDetection`（`variant:'detect'`） | `{needed:[…],weak:[…]}` |
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

> T5 / T8 的 JSON 契约目前在 App 侧也被拼进了 `query` 里（历史实现），
> 提示词里再强调一次是**幂等**的，不会冲突；即使 `variant` 传错，输出形状也不会退化。

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

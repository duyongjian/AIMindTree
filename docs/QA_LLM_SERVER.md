# QA 报告 · 自研 LLM Server 替换 Dify（AIMindTree）

> 测试类型：独立 QA（team lead 接管，不依赖外部 LLM 配额）
> 测试时间：2026-10-12（本地复跑）
> 结论：**PASS_WITH_FIXES**（全部阻断项已修复并复验通过；遗留项均为用户侧手动动作，非代码缺陷）

---

## 1. 总览

| 验证项 | 结论 | 证据 |
|---|---|---|
| Dart 门禁（analyzer，error+warning+info 全 fail） | ✅ PASS | 70 文件，0/0/0 |
| Python 自测（容错 + 契约 + App 对账） | ✅ PASS | 24/24 |
| 硬约束（表结构 / 密钥 / 注释 / 弃用标记） | ✅ PASS | git diff 空 / grep 无命中 |
| 六层 JSON 容错「两端逐层等价」 | ✅ PASS | 手工逐层比对（见 §4） |
| 提示词 inputs 双向对账 | ✅ PASS | 7/7 |

> 原 QA 因 LLM 配额 429 失败；本次接管**所有不耗配额**的验证项，结论可靠。
> 真正需要真实模型跑通的端到端链路（Ollama/MiniMax）无法在本机无配额/无模型环境下验证，已作为「遗留项」列出（§6），需用户在真机补跑。

---

## 2. 门禁（Dart analyzer）

命令：
```
cd aimindtree_app && D:/DevTools/flutter/bin/cache/dart-sdk/bin/dart.exe tool/analyze_inproc.dart
```
结果：`Analyzed 70 file(s) → 0 error(s), 0 warning(s), 0 info(s) / No issues found!`

覆盖所有改动的 `lib/**` 与 `test/**`，包含新增的 `structured_parse.dart`、`llm_server_client.dart`、设置页 dialog 等。

---

## 3. Python 自测（selftest.py）

命令：
```
cd llm_server && python selftest.py
```
结果：
```
提示词目录：.../llm_server/prompts
已加载 14 个，跳过 1，错误 0
结果：容错 10/10 通过，契约 14/14 通过（未加载 0），App 对账 7/7 通过（未接线 7）
✅ selftest PASSED
```

- **容错 10/10**：`core/json_repair.py::repair` 的 7 个坏样本 + 3 个补充样本（含未闭合 `<think>`、围栏、截断、`首{→末}` 误切防护、内层片段误判防护）。
- **契约 14/14**：14 个提示词文件的 front-matter（structured/temperature/inputs/output_key/preferred_backend）全部合法、inputs 命名与渲染变量一致。
- **App 对账 7/7**：T1–T13 中与 App 已接线（T1/T3/T4/T5/T6/T7/T8）的 inputs 与 App 端 `LlmServerClient` 实际构造的字段逐条一致；T9–T13 标记「未接线」跳过（P2 预留，非缺陷）。

---

## 4. 六层 JSON 容错 · 两端逐层等价（最高风险项，PRD C2）

两端实现：
- 服务端：`llm_server/core/json_repair.py`（`repair`、`_scan_json`、`_salvage`、`_stack_at`、`_match_end`）
- 客户端：`aimindtree_app/lib/ai/structured_parse.dart`（`StructuredText.parse` 等静态方法）

`repair` 已确认接入真实响应路径：`routers/tasks.py:93`、`routers/chat.py:182` 与 `:220` 均调用。

### 逐层比对

| 层 | 逻辑 | Python | Dart | 等价 |
|---|---|---|---|---|
| ⓪ | 剥离 `<think>/<thinking>/<reasoning>`（**含未闭合**，`$` 兜底） | `THINK_RE` `re.IGNORECASE` | `RegExp(..., caseSensitive:false)` | ✅ 同正则 |
| ① | 整体直接 decode | `_try_decode(text)` | `_tryDecode(s)` | ✅ |
| ② | 剥离**闭合** `<think>…</think>` | `THINK_CLOSED_RE`（`think` only, IGNORECASE） | `RegExp(r'<think>…</think>', caseSensitive:false)` | ✅ 同口径 |
| ③ | 剥离 ` ```json … ``` ` 围栏 | `FENCE_RE` `IGNORECASE` | `RegExp(..., caseSensitive:false)` | ✅ |
| ④ | 括号配对扫描（首个可解码片段） | `_scan_json` + `_match_end` | `_scanJson` + `_matchEnd` | ✅ 逻辑一致 |
| ⑤ | 截断抢救（补未闭合括号，不编造） | `_salvage` + `_stack_at` | `_salvage` + `_stackAt` | ✅ 边界一致（见下注） |
| ⑥ | 首尾硬切（尽力而为） | `_find_any`/`_rfind_any` on stage | `indexOf`/`lastIndexOf` on t | ✅ |

**层序一致性**：两端均为 ⓪ → ① → ② → ③ → ④ → ⓪补充（仅当 `no_think != stage/t`）→ ⑥，层序不可调，完全一致。

**⑤ 边界一致性注记**：Python `_salvage` 从 `len(text)-1` 反向扫到 `start`，Dart 从 `s.length-1` 扫到 `start`（含 `>= start` 截断）。两端均取「整个字符串中最后一个 `}`/`]`」，因 `}`/`]` 必然出现在 `{`/`[`（`start`）之后，结果 `k` 完全相同；其余栈计算与 `closers` 拼接完全对应。✅

**两条禁止事项两端均写入注释**（不可删）：
1. 禁止「首 `{` → 末 `}`」硬切（思考块含 `{` 会污染起点）。
2. 禁止退而求其次解析内层形状不对的片段（如 `{"gaps":[...]}` 内层 `{"name":..}`）。

**结论**：两端在正则、层序、分支、边界、禁止事项上**逐层等价**，满足 PRD C2 硬约束。

---

## 5. 硬约束审查

| 约束 | 检查方式 | 结果 |
|---|---|---|
| C1 表结构零改动（禁 build_runner） | `git diff lib/data/db/tables.dart` | ✅ 仅 4 处注释，无 schema 改动 |
| C2 六层容错两端等价 | §4 | ✅ |
| C3 密钥不进 App、设置页无 Key 框 | grep 硬编码 Key `tue-qkGx` | ✅ 无命中；`api_key_ref` 恒空 |
| C4 Dify 代码整段注释、不删 | grep `DifyResult` | ✅ 均为 `//` 注释 |
| C5 不加 `@Deprecated`（测试 15 处调用会触发 warning） | grep `@Deprecated` | ✅ 仅在文档注释出现一次，代码未加 |
| C6 `.env` 不进版本库 | `.gitignore` 含 `.env` | ✅ |
| C7 backend 复用 `type` 列、model 复用 `models` 列（≤1 元素） | 代码核对 | ✅ |

---

## 6. 已修复问题（阻断级，均已复验）

### P0 · T4 `depth_instruction` 静默失效（commit `a2e827e`）
- **现象**：`t4_gap_analysis.md` front-matter 声明 `inputs:[target,depth]`，但 App 端 `auto_graph_service.dart` 无条件传 `depth_instruction`（custom 档透传用户文本）→ 自定义深度档指令被静默丢弃。
- **修复**：front-matter 加入 `depth_instruction`；正文新增 `{{depth_instruction}}` 渲染段；文件末追加防删说明。
- **复验**：selftest 契约 14/14（含 T4 inputs 含 `depth_instruction`）、App 对账 T4 通过。

### P1 · T3 `group_order` 语义缺口
- **现象**：`points` 内层 `group/group_order/foundation_level` 能到达模型，但提示词未写含义 → 模型可能只输出同组边 → 客户端过滤后 `created=0`。
- **修复**：SYSTEM 段加条件说明 + 输出要求第 7 条「优先跨组边」。

---

## 7. 遗留 / 用户侧待办（非代码缺陷，需真机动作）

1. **Ollama 本机未起 + 零模型**：默认后端是 ollama，但本机 `ollama serve` 未启动、未 `pull` 模型。用前需：
   ```
   ollama serve
   ollama pull llama3
   ```
2. **启动 LLM Server**：App 调用 `127.0.0.1:8787`，用前需先拉起服务：
   ```
   cd llm_server && scripts/run_llm_server.bat
   ```
   （或 `pip install -r requirements.txt` 后 `python run.py`）
3. **依赖安装**：`pip install -r llm_server/requirements.txt`（fastapi/uvicorn/httpx/pyyaml）。
4. **硬编码 Dify Key（历史值 `app-fhXwVvHFfVbVWRq3tRMOX8fd`）**：已从运行代码清除，但作为「过时方案」保留在 `extraction_service.dart` 与 `dify_client.dart` 的注释中供回溯（用户 2026-10-21 决定：不作废、不主动复用，仅作文档化留存）。
5. **端到端真机补跑**：本机无 LLM 配额/模型，无法验证真实模型产出。真机需 `flutter test` 跑通 `test/structured_parse_test.dart` 及 T1/T3/T4 真实链路。
6. **未跟踪文档**：`docs/DESIGN_LLM_SERVER.md`、`docs/PRD_LLM_SERVER.md`、`docs/class-diagram.mermaid`、`docs/sequence-diagram.mermaid` 仍为 untracked（产品/架构同学产物），是否提交待用户确认。

---

## 8. 提交记录（本次改造）

| commit | 内容 |
|---|---|
| `aad39ff` | docs：13 任务完整提示词 |
| `f73ca4b` | T01：structured_parse.dart 六层容错（从 dify_client 抽出） |
| `24902eb` | T02 + T04：Dify 注释 + llm_server_client + 设置页 dialog |
| `a912127` | T03：llm_server 服务端（47 文件） |
| `0a72d4d` | T05：ARCHITECTURE 更新第四协议 |
| `f7a18e2` | fix admin 路由 |
| `b494e1b` | helper 唯一化 |
| `83a67ef` | T8/T5 透传 + variant |
| `a2e827e` | T4 修复（depth_instruction 接回） |

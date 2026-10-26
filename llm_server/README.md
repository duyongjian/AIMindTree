# AIMindTree LLM Server

自研本地 LLM 服务（FastAPI，默认 `http://127.0.0.1:8787`）。
把 **提示词装载 / 密钥 / JSON 容错** 三件事从 Flutter 客户端收回服务端，
取代「App 直连 Dify」。App 侧只认一个地址，不传任何密钥。

设计文档：`docs/DESIGN_LLM_SERVER.md` ｜ 需求：`docs/PRD_LLM_SERVER.md`

---

## 1. 安装（一次性）

```bat
REM Windows（仓库根目录）
python -m venv .venv
.venv\Scripts\pip install -r llm_server\requirements.txt
```

依赖只有 4 个（纯 wheel，不需要编译工具链）：`fastapi` / `uvicorn` / `httpx` / `pyyaml`。

> 若用托管 Python：
> `C:\Users\ASUS\.workbuddy\binaries\python\versions\3.13.12\python.exe -m pip install -r llm_server\requirements.txt`

## 2. 一行启动

```bat
REM 方式一：双击（推荐）
scripts\run_llm_server.bat

REM 方式二：命令行
python llm_server/run.py

REM 常用参数
python llm_server/run.py --port 8788 --verbose
```

启动后自检：

```bat
curl http://127.0.0.1:8787/health
curl http://127.0.0.1:8787/v1/prompts
python llm_server/selftest.py
```

> ⚠️ 本机若有代理（`HTTP_PROXY` / `HTTPS_PROXY`），`curl` 要加 `--noproxy '*'`，
> 否则 127.0.0.1 的请求会被代理拦掉，表现为「连不上」的假故障。服务端内部
> 默认已 `trust_env=False`（见 `config.yaml` 的 `server.trust_env_proxy`）。

## 3. 目录说明

```
llm_server/
├── run.py                  一行启动入口（argparse → uvicorn.run）
├── server.py               FastAPI 装配：4 个 router + 全局异常处理器 + CORS
├── config.yaml             默认后端 / 按任务覆盖 / 三后端连接参数 / 超时 / 端口
├── .env.example            密钥模板（复制成 .env；.env 已被 .gitignore 忽略）
├── requirements.txt        4 行依赖白名单
├── selftest.py             无外网依赖自检（六层容错 + 14 任务契约）
├── core/
│   ├── config.py           config.yaml + .env 加载、mtime 热加载、密钥解析
│   ├── errors.py           ★ LlmError + 12 个错误码 → 统一 {error:{...}}
│   ├── json_repair.py      ★ 六层 JSON 容错（与 Flutter 侧逐层等价）
│   ├── prompt_store.py     ★ prompts/*.md 扫描、front-matter 解析、热更新
│   ├── registry.py         ★ 任务注册表（输入校验 / output_key / 后端选择）
│   └── logging.py          结构化一行日志，--verbose 打印完整 prompt/response
├── backends/
│   ├── base.py             LLMBackend 抽象 + Message/Completion/BackendHealth
│   ├── protocols/
│   │   ├── openai_compat.py    协议一：/v1/chat/completions（REST + SSE）
│   │   └── anthropic_compat.py 协议二：/v1/messages（x-api-key + version）
│   ├── ollama.py           Ollama（= openai_compat + /api/tags 探活 + format=json）
│   ├── minimax.py          MiniMax（按 config.protocol 二选一，默认 anthropic）
│   ├── openai_compat.py    任意 OpenAI 兼容端点（DeepSeek/通义/Kimi/硅基流动…）
│   └── langchain_adapter.py    仅占位注释，不实现、不引入依赖
├── routers/
│   ├── tasks.py            POST /v1/task/{T1..T13}（结构化任务）
│   ├── chat.py             POST /v1/chat（SSE 或一次性）
│   ├── prompts.py          GET/PUT /v1/prompts · reload
│   ├── health.py           GET /health
│   └── admin.py            POST /v1/admin/reload（config 热加载）
└── prompts/
    ├── index.yaml          任务 → 文件 映射（元信息以 md 的 front-matter 为准）
    ├── README.md           改哪个文件影响哪个功能 / 如何热更新 / 如何新增任务
    └── t*.md               14 个提示词（含 t5_ask__detect.md 变体）
```

## 3.5 使用本地 llama.cpp（llama-server，**当前默认后端**）

> 2026-10-27 起项目不再使用 Ollama，推理后端改为本地 **llama.cpp 的 llama-server**
> （监听 `127.0.0.1:8085`）。Ollama 配置段保留但已弃用，仅作回退。

```bat
REM ① 只起推理服务（这个窗口别关）
scripts\run_llama_server.bat

REM ② 或者：起「llama-server + Python 服务端」一条龙（日常推荐这个）
REM    它会自动探测 8085，没跑就拉起，并轮询等 /health 就绪
scripts\run_llm_server.bat

REM ③ 也可以直接双击 llama.cpp 目录下的 启动.bat
D:/Local_Llama/llama-b9993-bin-win-cuda-13.3-x64/启动.bat
```

固定用的两个文件（**不要换**）：

| 用途 | 文件 |
|---|---|
| 主模型（自带 MTP 投机解码 draft） | `models\Qwen3.8-27B-GSQ-RCO-IQ2_XS-mtp.gguf`（8.77 GB） |
| 多模态投影 | `models\mmproj-Qwen3.8-27B-BF16.gguf`（931 MB，`--mmproj` 挂载） |

自检：

```bat
curl --noproxy '*' http://127.0.0.1:8085/health      REM {"status":"ok"}
curl --noproxy '*' http://127.0.0.1:8085/v1/models   REM id = Qwen3.8-27B-Uncensored
curl --noproxy '*' http://127.0.0.1:8787/health      REM llama_cpp: reachable=true
```

### ⚠️ 关键坑一：`--alias` 必须与 config.yaml 逐字一致

`/v1/models` 返回的 id 就是启动参数 `--alias`（`-a`）的值。
`llm_server/config.yaml` 里 `backends.llama_cpp` 的 `default_model` / `models`
必须和它**逐字相同**，否则报「模型不存在」。

```yaml
backends:
  llama_cpp:
    default_model: Qwen3.8-27B-Uncensored    # ← 必须与 --alias 一致
    models: [Qwen3.8-27B-Uncensored]
```

### ⚠️ 关键坑二：显存 8GB 装不下 27B，别让 `--fit` 自动挑层数

本机 RTX 4060 Laptop **8 GB** 显存，模型 8.77 GB + mmproj 0.93 GB，本来就装不下。
实测（i7-13650HX + 4060 Laptop，llama.cpp b9993）：

| 配置 | 每 slot 上下文 | 实测 tg |
|---|---|---|
| `-ngl 99`（全量上显卡，装不下的溢出到 CPU） | 32768 | **≈ 8 tok/s** |
| 不写 `-ngl`、让 `--fit on` 自动挑层数 | 16384 | 1.5–2.3 tok/s（慢 3–5 倍） |

所以脚本里**显式写死 `-ngl 99`**：宁可让少量层溢出到 CPU，也别让 `--fit` 保守退层。
（副作用：显式给了 `-ngl` 后 `--fit on` 会失效，llama.cpp 会打一条 warning 并跳过。）

另两个实测有效的提速项：

- `--no-mmproj-offload`：视觉投影留 CPU，给主模型腾约 950 MB 显存 → 快 20%–30%；
- `-ctk q8_0 -ctv q8_0`：KV 缓存量化到 8bit，占用减半。

### ⚠️ 关键坑三：27B 很慢，超时必须放宽

本机实测 **tg ≈ 8 tok/s、pp ≈ 11 tok/s**。T1 一次抽几十个知识点的大 JSON
很容易超过原来的 120 s，所以 `config.yaml` 的 `timeouts` 已放宽：

```yaml
timeouts:
  structured_s: 900     # 结构化任务（T1/T3/T4/T13/T14）
  chat_s: 900           # 对话（T6 老师模式等长文本）
```

> App 侧 `AiProvider.runTask.timeout` 也要跟着放宽，否则 App 先超时、
> 服务端宽限多少都没用。

### 为什么默认关闭思考（`--reasoning off`）

Qwen3 默认输出思考。实测开启时「60 字回答要配 400+ 字思考」——
思考会吃掉大半 `max_tokens`，长 JSON 任务基本跑不完；关掉后**有效内容吞吐约高 5 倍**。

App 侧 `structured_parse.dart` 本身有 `<think>` 容错解析，所以开着也安全；
要开就把 `--reasoning off` 改成 `auto`（或 `on`），并配 `--reasoning-budget N` 限制思考长度。

## 4. 切换后端

改 `llm_server/config.yaml` 一行即可（**不用重启进程**，改完 `POST /v1/admin/reload`）：

```yaml
default_backend: llama_cpp   # ← 改成 minimax / ollama / openai_compat
```

| backend | 默认 protocol | 端点 | 前置条件 |
| --- | --- | --- | --- |
| `llama_cpp` | `openai_compat` | `http://127.0.0.1:8085/v1/chat/completions` | llama-server 在跑（见 §3.5） |
| `ollama`（已弃用，仅回退） | `openai_compat` | `http://127.0.0.1:11434/v1/chat/completions` | `ollama serve` + `ollama pull llama3` |
| `minimax` | `anthropic_compat` | `https://api.minimaxi.com/anthropic/v1/messages` | `.env` 里填 `MINIMAX_API_KEY` |
| `openai_compat` | `openai_compat` | 你填的 `base_url` + `/v1/chat/completions` | `.env` 里填 `OPENAI_API_KEY` |

> `llama_cpp` 只是**逻辑后端名**，底层复用现成的 `type: openai_compat`
> （llama-server 原生暴露 `/v1`），没有新增 Python 后端类。

**MiniMax 切到 OpenAI 形态**：把 `backends.minimax.protocol` 改成 `openai_compat`。
**按任务单独指定后端**（可选）：

```yaml
task_backends:
  T1: minimax
  T5: minimax
```

**本地后端是可选的**：没起 llama-server 也能正常启动，`/health` 里该项
`reachable=false`，只要把 `default_backend` 指向一个可用端点即可。
## 5. 密钥

```bat
copy llm_server\.env.example llm_server\.env
REM 然后编辑 .env，填入你的 Key
```

`.env` 已被 `.gitignore` 忽略，`api_key_env` 里只写**环境变量名**。
App 侧不存、不传任何密钥（设置页也没有 Key 输入框）。

## 6. 改提示词（不用重启）

编辑 `llm_server/prompts/*.md`，然后：

```bat
curl -X POST http://127.0.0.1:8787/v1/prompts/reload
```

或用 `PUT /v1/prompts/T1?reload=true`（body `{"content": "<完整 md>"}`）直接写回。
详见 `prompts/README.md`。

## 7. 故障排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 启动报 `FastAPIError: Invalid args for response field` | 路由返回值注解被当成响应模型 | 已在 `/v1/chat` 加 `response_model=None`，勿删 |
| `/health` 里 llama_cpp `reachable=false` | llama-server 没起 | 跑 `scripts\run_llama_server.bat`，或双击 llama.cpp 目录下的 `启动.bat`；确认 `curl http://127.0.0.1:8085/health` 返回 `{"status":"ok"}` |
| 报 `backend_unreachable` 但 8085 明明通 | 本机 `HTTP_PROXY` 把 127.0.0.1 请求发给代理了 | 服务端已默认 `trust_env_proxy: false`；`curl` 要加 `--noproxy '*'` |
| 真实调用报「模型不存在」 | `--alias` 与 config.yaml 的 `default_model` 不一致 | 两边对齐为同一个字符串（见 §3.5 坑一） |
| `backend_timeout`（504） | 27B 本地推理慢（约 8 tok/s），120 s 不够 | 已把 `timeouts.structured_s/chat_s` 放宽到 900；App 侧超时也要同步放宽 |
| `/health` 里 ollama `reachable=false` | Ollama 没起 / 没拉模型（**Ollama 已弃用，仅回退**） | 换 `default_backend`；真要回退就 `ollama serve` + `ollama pull qwen3:8b-8k` |
| `bad_json`（502） | 模型输出不是合法 JSON | 换更强模型 / 在 config 把该任务切到 `minimax`；调大 `max_tokens` |
| `auth_failed`（401） | `.env` 里没填对应 Key | 填 `MINIMAX_API_KEY` / `OPENAI_API_KEY` 后 `POST /v1/admin/reload` |
| 端口占用 | 8787 被占 | `run_llm_server.bat --port 8788`（同时改 App 默认 Base URL） |
| 提示词改了没生效 | 没 reload | `POST /v1/prompts/reload`，或 `--verbose` 看加载日志 |

看完整 prompt / 模型原始输出：

```bat
scripts\run_llm_server.bat --verbose
```

## 8. curl 冒烟

```bat
curl --noproxy '*' http://127.0.0.1:8787/health

curl --noproxy '*' -X POST http://127.0.0.1:8787/v1/task/T1 ^
  -H "Content-Type: application/json" ^
  -d "{\"inputs\":{\"note_text\":\"牛顿第二定律：F=ma\"}}"

curl --noproxy '*' -N -X POST http://127.0.0.1:8787/v1/chat ^
  -H "Content-Type: application/json" ^
  -d "{\"task\":\"T5\",\"query\":\"什么是惯性？\",\"stream\":true}"
```

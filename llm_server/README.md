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

## 3.5 使用本地 Ollama（当前默认后端）

```bat
REM ① 起服务（默认监听 http://127.0.0.1:11434，这个窗口别关）
ollama serve

REM ② 确认模型（没拉过就 pull）
ollama list
```

然后把 `llm_server/config.yaml` 的模型位对齐你 `ollama list` 看到的名字：

```yaml
backends:
  ollama:
    default_model: qwen3:8b-8k                 # ← 必须是 ollama list 里的完整 NAME（含 tag）
    models: [qwen3:8b-8k, qwen3:8b, qwen2.5:0.5b]
```

自检：

```bat
curl --noproxy '*' http://127.0.0.1:11434/api/tags     REM Ollama 自己活着 + 有模型
curl --noproxy '*' http://127.0.0.1:8787/health        REM ollama: reachable=true
```

### ⚠️ 关键坑：`num_ctx` 撑爆显存 → 慢 150 倍

Ollama 的 OpenAI 兼容端点（`/v1/chat/completions`）**不接受 `num_ctx` 参数**，
上下文只能吃模型自带默认值。`qwen3:8b` 出厂默认 `num_ctx=40960`，加载后占 11 GB，
超出显存 → Ollama 退化成 CPU/GPU 混合推理。

本机实测（i7-13650HX + 独显，`ollama ps` 核对）：

| 模型 | 上下文 | 设备 | 实测速度 |
|---|---|---|---|
| `qwen3:8b`（原厂） | 40960 | 46% CPU / 54% GPU | **0.3 tok/s**（51 token 花 176 s，不可用） |
| `qwen3:8b-8k`（派生） | 8192 | **100% GPU** | **≈ 46 tok/s** |
| `qwen2.5:0.5b` | 32768 | 100% GPU | ≈ 111 tok/s（能力太弱，见下） |

解决办法 = 用派生模型把上下文固定住（不改一行代码）：

```bat
ollama create qwen3:8b-8k -f llm_server/ollama/Modelfile.qwen3-8k
ollama rm qwen3:8b-8k        REM 还原
```

### 模型选型实测（T1 知识点抽取，同一段「梯度下降」笔记）

| 模型 | 耗时 | 结果 | 可用性 |
|---|---|---|---|
| `qwen3:8b-8k` | 18–22 s | 3 条；`type` 合法、`source_quote` **100% 命中原文** | ✅ 默认 |
| `qwen2.5:0.5b` | 0.5–1.7 s | 1 条；`type` 原样回抄 `概念\|公式\|…`、`source_quote` 恒空 | ❌ 只适合冒烟 |

> 0.5B 会把 JSON schema 当模板抄回来，**过不了 PRD 锚点铁律**
> （`source_quote` 空 = 幻觉，客户端直接丢弃），别拿它做真实抽取。

> ⚠️ **只 `serve` 不 `pull`**：`/health` 仍然 200（`reachable=true`），
> 但首次真实请求会报「模型不存在」。**先 pull 再调**。
>
> 不想用 Ollama 也完全没问题：把 `default_backend` 改成 `minimax` 或 `openai_compat`
> 即可（见下一节），Ollama 只是三个可切换后端之一。

## 4. 切换后端

改 `llm_server/config.yaml` 一行即可（**不用重启进程**，改完 `POST /v1/admin/reload`）：

```yaml
default_backend: ollama      # ← 改成 minimax / openai_compat
```

| backend | 默认 protocol | 端点 | 前置条件 |
| --- | --- | --- | --- |
| `ollama` | `openai_compat` | `http://127.0.0.1:11434/v1/chat/completions` | `ollama serve` + `ollama pull llama3`（见 §3.5） |
| `minimax` | `anthropic_compat` | `https://api.minimaxi.com/anthropic/v1/messages` | `.env` 里填 `MINIMAX_API_KEY` |
| `openai_compat` | `openai_compat` | 你填的 `base_url` + `/v1/chat/completions` | `.env` 里填 `OPENAI_API_KEY` |

**MiniMax 切到 OpenAI 形态**：把 `backends.minimax.protocol` 改成 `openai_compat`。
**按任务单独指定后端**（可选）：

```yaml
task_backends:
  T1: minimax
  T5: minimax
```

**Ollama 是可选的**：没起 Ollama 服务也能正常启动，`/health` 里该项
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
| `/health` 里 ollama `reachable=false` | Ollama 没起 / 没拉模型 | `ollama serve` + `ollama pull qwen2.5:7b`；或换 `default_backend` |
| 明明本机有 Ollama 却报 `backend_unreachable` | 本机 `HTTP_PROXY` 把 127.0.0.1 请求发给代理了 | 服务端已默认 `trust_env_proxy: false`；`curl` 要加 `--noproxy '*'` |
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

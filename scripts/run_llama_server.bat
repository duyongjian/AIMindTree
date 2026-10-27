@echo off
REM ============================================================
REM  AIMindTree 后端服务 - 本地 llama.cpp 的 llama-server 启动器
REM
REM  用法：
REM     scripts\run_llama_server.bat          弹出档位菜单（15 秒无输入默认选 1）
REM     scripts\run_llama_server.bat 1        直接启动【档位 1】不弹菜单
REM     scripts\run_llama_server.bat 2        直接启动【档位 2】不弹菜单
REM     传了非 1/2 的参数 -> 打一行说明后回落档 1，不弹菜单
REM
REM     一键启动想用 agent 档（而不是每次手动指定 2）：
REM         set LLAMA_PROFILE=2 && scripts\run_llm_server.bat
REM     不设 LLAMA_PROFILE 时 run_llm_server.bat 默认按档 1 拉起本脚本。
REM
REM  它只做一件事：在 127.0.0.1:8085 拉起 llama-server；已经在跑就直接退出（幂等）。
REM  要与 llm_server(Python) 一起启动，请用 scripts\run_llm_server.bat。
REM
REM  固定目录：D:\Local_Llama\llama-b9993-bin-win-cuda-13.3-x64
REM    主模型   models\Qwen3.8-27B-GSQ-RCO-IQ2_XS-mtp.gguf   8.76 GB（自带 MTP 投机头）
REM    多模态   models\mmproj-Qwen3.8-27B-BF16.gguf          931 MB
REM
REM  ---------------- 两档 profile ----------------
REM  档位 1  AIMindTree 提取档  —— T1 结构化 JSON 抽取等离线批量任务
REM  档位 2  Agent 编程/规划档 —— WorkBuddy、Claude Code 这类 agent 产品
REM
REM  为什么要分两档：这两个场景对 reasoning / 并发 / 上下文的诉求是冲突的，
REM  合并成一档必然有一边受损。详细结论见文件末尾「能否合并成一档」。
REM
REM  ---------------- 本机实测基线（RTX 4060 Laptop 8GB / i7-13650HX / 64GB）----
REM    llama-server 版本 9993 (2969d6d15)，CUDA 13.3
REM    模型 27.3B / IQ2_XXS 2.0625 bpw / 8.76 GB
REM    * 预填 prefill：约 21 tok/s（1840 token 冷启动实测 83 秒）
REM    * 解码 decode ：约 8.4 tok/s；MTP 投机接受率约 84%（141/168）
REM    * 命中 prompt 缓存后，每轮仍有约 3.8-4.3 秒固定开销
REM    * 显存：加载后约 7900 MiB / 8188 MiB，基本占满
REM    * 关键实测：显存占用与 -c 几乎无关（均在 7900-7923 MiB 之间波动）
REM        -c 8192   -> 7921 MiB
REM        -c 65536  -> 7923 MiB
REM        -c 131072 -> 7919 MiB
REM      说明 KV cache 实际落在 host RAM 而非显存，所以「加大 -c 不会爆显存」。
REM    => 两档都**不要承诺快**。这是 8G 显存跑 27B 的物理上限，调参只能改形状。
REM
REM  ---------------- 档位 1 参数依据 ----------------
REM    -c 65536     总上下文。注意 -c 是**总量**，会被 --parallel 平分
REM                 （档1 parallel=2，所以每 slot 32768）。
REM    --parallel 2 两个 slot：前台对话 + 后台静默任务（T14 回填等）不互相排队。
REM    -ctk/-ctv q8_0  KV 量化到 8bit，比 f16 省一半以上。
REM    -ngl 99      全部层交给 GPU，实测比 --fit 自动切分快 3-5 倍
REM                 （--fit 在 8GB 装 8.76GB 模型时会保守地把大量层退回 CPU）。
REM                 显式给了 -ngl 后 --fit 自动失效（日志会打 warning）。
REM    --no-mmproj-offload  视觉投影层放 CPU，给主模型省约 950MB 显存。
REM    -fa on       Flash Attention 开。
REM    --jinja      用 GGUF 内嵌 jinja 模板，思考/工具标签渲染才正确。
REM    --reasoning off  关闭思维链。**这是档1 的核心**：T1 要输出结构化 JSON，
REM                 思维链会吃掉 max_tokens 导致 JSON 被截断；
REM                 而且 App 端 structured_parse.dart 不处理 think 标签。
REM    --spec-type draft-mtp / --spec-draft-n-max 4
REM                 用模型自带 MTP 头做投机解码，不需要额外 draft 模型；
REM                 实测 4 比默认 3 好，再往上（8）接受率掉到 36%。
REM    --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.05 --repeat-penalty 1.05
REM                 提取需要一点泛化，0.6 是实测折中值。
REM    -n 8192      单次最大输出 token。T1 一次吐几十条知识点的 JSON 需要大空间。
REM                 注意 tg 约 8.4 tok/s，8192 要 16 分钟，所以 config.yaml 的
REM                 timeouts 已放到 900s。
REM
REM  ---------------- 档位 2 参数依据（逐参数说明，不堆参数）----------------
REM    与档位 1 相同就不再重复，下面只列**变了的**以及理由：
REM
REM    --parallel 1   单 slot 拿到完整 65536 上下文（档1 是 2 x 32768）。
REM                   这是本档最大收益：上下文翻倍而显存零增长（-c 不变）。
REM                   不这么设的后果：agent 一轮「系统提示 + 多文件 + 工具结果」
REM                   很容易撑爆 32k，被截断后模型丢掉早期上下文，
REM                   表现为改错文件、忘记先前约束。
REM                   为什么不是 2：本机是显存带宽瓶颈，2 路并发不提高总吞吐，
REM                   只在两条流之间来回切。实测命中缓存后的单轮固定开销
REM                   2 slot 为 4.87s、1 slot 为 4.32s，1 slot 反而更快。
REM
REM    --reasoning on agent 要规划/调试/多步推理，关掉思维链在复杂重构上明显变差。
REM                   档1 关掉的理由（JSON 截断）在编程场景不成立。
REM
REM    --reasoning-budget 1024  **必须配**，不能只开 reasoning。
REM                   原因：本 GGUF 内嵌 chat template 第 46 行默认
REM                   reasoning_effort = 'xhigh'，xhigh 会注入一长段
REM                   「请仔细思考、验证关键假设、考虑替代方案」的指令；
REM                   不设预算就会一路想到 -n 上限。
REM                   1024 是安全阀不是限流器：实测简单任务模型约 100 token
REM                   就自己收尾，预算几乎不触发；复杂任务最多 1024 token
REM                   （约 2 分钟）就强制收尾进入正题。
REM                   不设的后果：单轮思考 5000+ token，10 分钟以上，交互不可用。
REM                   客户端还可按请求传 chat_template_kwargs:
REM                   {"reasoning_effort":"low"} 进一步压短思考。
REM
REM    --cache-reuse 256  agent 每轮重发「系统提示 + 文件上下文」，前缀高度重复。
REM                   实测开启后命中缓存的单轮固定开销 4.31s -> 3.81s（约 11%），
REM                   4 轮全部复现。
REM                   但要说清楚：这是**小优化不是数量级改善**——llama-server
REM                   默认已开 prompt cache 并按 LCP 相似度选 slot
REM                   （日志 selected slot by LCP similarity, sim_best = 0.985），
REM                   大头早被默认行为吃掉。不设的后果只是每轮多付约 0.5 秒。
REM
REM    --temp 0.3     代码要确定性。实测同一改写任务 0.6 与 0.3 输出完全一致，
REM                   但 0.3 的思考更短（106 vs 151 token），整轮 16.6s vs 30.4s。
REM                   注意：Qwen3 思维链模式官方推荐 temp 0.6。这里为了确定性
REM                   和速度降到 0.3；如果发现复杂任务思考退化，把这一行改回
REM                   0.6 即可，其他不用动。
REM
REM    -c 65536       为什么不提到 131072：
REM                   直觉上上下文越大越好，但这里**不能提**，理由不是爆显存
REM                   （实测 -c 131072 加载后显存 7919 MiB，和 -c 8192 的
REM                   7921 MiB 几乎一样，KV 在 host RAM），而是：
REM                   本机 prefill 只有约 21 tok/s，131072 token 的冷预填要约 100 分钟。
REM                   给一个「装得下但读不完」的上下文，只会让 agent 更倾向于塞满它，
REM                   然后每一轮都在等预填。65536 已经是档1 的两倍，够放
REM                   「系统提示 + 若干文件 + 多轮工具结果」，又把最坏等待压住。
REM
REM    仍保留 --mmproj：实测去掉 --mmproj 显存 delta = 0 MiB
REM                   （7923 MiB vs 7923 MiB），保留不花代价，
REM                   agent 需要看截图时仍然可用。
REM
REM  ---------------- 能否合并成一档（本次结论）----------------
REM    不能合并。两档的冲突点是**同一条 -c 上的零和分配**：
REM      档1 需要 parallel=2（前台对话 + 后台静默任务并存）；
REM      档2 需要 parallel=1（单会话要吃满 64k，且 1 slot 实测更快）。
REM    -c 固定 65536 时，parallel 只能二选一：2x32768 或 1x65536。
REM    同时 reasoning 也必须相反：档1 必须 off（否则 JSON 截断），
REM    档2 必须 on（否则复杂规划明显变差）。
REM    硬用一档只能是「parallel=1 + reasoning off + 32k」，等于
REM    牺牲档1 的后台并发能力，也牺牲档2 的推理能力，两头不讨好。
REM    折中方案（如果你坚持一档）：parallel=2 + reasoning on +
REM    reasoning-budget 1024 + cache-reuse 256，代价是每 slot 只有 32k，
REM    且档1 的 JSON 抽取要自己保证 max_tokens 不被思考吃掉。
REM
REM  其他：
REM    健康检查   http://127.0.0.1:8085/health
REM    模型列表   http://127.0.0.1:8085/v1/models
REM    退出：在本窗口按 Ctrl+C
REM ============================================================
setlocal EnableDelayedExpansion

set "LLAMA_DIR=D:\Local_Llama\llama-b9993-bin-win-cuda-13.3-x64"
set "MODEL=models\Qwen3.8-27B-GSQ-RCO-IQ2_XS-mtp.gguf"
set "MMPROJ=models\mmproj-Qwen3.8-27B-BF16.gguf"
set "HOST=127.0.0.1"
set "PORT=8085"
REM 必须与 llm_server\config.yaml 的 backends.llama_cpp.default_model / models 一致
REM （llm_server 靠 /v1/models 返回的 id 匹配，而 id 就是 --alias 的值）
set "ALIAS=Qwen3.8-27B-Uncensored"

REM 清空代理变量：系统代理会把 127.0.0.1:xxxxx 也拦走，
REM 表现为「加载完了却连不上」或「假挂起」。
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "http_proxy="
set "https_proxy="
set "NO_PROXY=localhost,127.0.0.1,::1"
set "no_proxy=localhost,127.0.0.1,::1"

if not exist "%LLAMA_DIR%\llama-server.exe" (
    echo [llama_server] !!! 找不到 %LLAMA_DIR%\llama-server.exe
    echo [llama_server] 请确认 llama.cpp 已解压到该目录，或修改本脚本顶部的 LLAMA_DIR。
    pause
    endlocal & exit /b 1
)

REM ---------- 已经在跑？直接退出，避免重复占显存 ----------
REM 用 curl 探活而不是查进程名：进程在但模型没加载完也不该重复拉起。
curl -s -m 3 http://%HOST%:%PORT%/health >nul 2>&1
if not errorlevel 1 (
    echo [llama_server] already running on %HOST%:%PORT% , nothing to do.
    echo [llama_server] health: http://%HOST%:%PORT%/health
    endlocal & exit /b 0
)

REM ---------- 公共参数 ----------
REM 路径与 alias 一律加引号：当前取值不含空格，展开后等价；
REM 但一旦哪天模型文件名或 alias 带空格，不加引号会被拆成两段参数，
REM llama-server 报的错跟真实原因无关，排查成本很高。
set "COMMON=-m "%MODEL%" --mmproj "%MMPROJ%" --no-mmproj-offload --host %HOST% --port %PORT% -a "%ALIAS%" --keep 8192"
set "P1_ARGS=-c 65536 -n 8192 -ngl 99 -fa on -ctk q8_0 -ctv q8_0 --jinja --parallel 2 --spec-type draft-mtp --spec-draft-n-max 4 --reasoning off --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.05 --repeat-penalty 1.05"
REM 档2 的 -ngl 与 -c 必须联动，目标是显存刚好装满、绝不溢出：
REM 本机实测约 175 MB 每层、共约 48 层；-c 65536 时 KV 约占 2.0 GB，-c 32768 约 1.0 GB。
REM 计算式：ngl 约等于 （7.5 GB 减 KV） 除以 0.175 GB。-c 65536 取 30，-c 32768 取 37，-c 16384 取 40。
REM 溢出到共享显存会触发 WDDM 页迁移，实测把 prefill 从 175 t/s 打到 21 t/s，比少放几层严重得多。
REM 实测参考：-ngl 20 时 decode 仅 1.5 至 2.7 t/s；-ngl 99 时 decode 8.1 t/s 但 prefill 崩到 21 t/s。
REM -t 12 限制 CPU 线程数：只为降风扇噪音与争抢。
REM COMMON 里的 --keep 8192 是关键：上下文写满触发 shift 时，开头的系统提示与工具定义不会被丢弃。
REM 这正是超过上下文后报 bad function call 的根因。llama.cpp 不做摘要压缩，长会话需客户端自行压缩历史。
REM 加载 --mmproj 会让 llama.cpp 禁用 --cache-reuse；图像支持优先，接受此项失效（slot 的 LCP 复用仍在工作）。
set "P2_ARGS=-c 65536 -n 8192 -ngl 30 -t 12 --threads-batch 12 -fa on -ctk q8_0 -ctv q8_0 --jinja --parallel 1 --spec-type draft-mtp --spec-draft-n-max 4 --reasoning on --reasoning-budget 512 --cache-reuse 256 --temp 0.3 --top-p 0.95 --top-k 20 --min-p 0.05 --repeat-penalty 1.05"

REM ---------- 档位选择 ----------
REM 优先级：命令行参数 > 交互菜单。带参数时**完全不弹菜单**，
REM 这样 run_llm_server.bat 里的 start "" /min 无人值守也不会有等待输入的窗口。
set "PROFILE="
if /i "%~1"=="1" set "PROFILE=1"
if /i "%~1"=="2" set "PROFILE=2"
if defined PROFILE goto :profile_ready

REM 传了参数但不是 1/2：只打一行说明就回落档 1，**不进菜单**。
REM 否则真控制台下会白等 15 秒，而且「明明传了参数却又看到菜单」逻辑别扭。
if not "%~1"=="" goto :profile_invalid

echo ============================================================
echo   llama-server 档位选择
echo ============================================================
echo     [1] AIMindTree 提取档   reasoning off / parallel 2 / 每 slot 32k
echo     [2] Agent 编程规划档    reasoning on+budget / parallel 1 / 单会话 64k
echo.
echo   15 秒内没有输入将自动选择 [1]（无人值守安全，不会卡住）
echo.
REM /t 15 /d 1：15 秒超时默认选项 1。
REM 用「精确比对 errorlevel」而不是 if errorlevel N 的阈值判断：
REM 阈值写法下 255/9009（choice 不可用或被策略禁用）会误落进 >=2 的分支，
REM 结果是无人值守时悄悄起了错误的档位。精确比对可以保证任何异常值一律回落档 1。
choice /c 12 /n /t 15 /d 1 >nul 2>&1
set "RC=!errorlevel!"
if "!RC!"=="2" goto :profile_pick2
if "!RC!"=="1" goto :profile_pick1
goto :profile_fallback

:profile_invalid
echo [llama_server] 无效档位参数 "%~1"，回落默认档位 1（可选 1 / 2）。
set "PROFILE=1"
goto :profile_ready

:profile_pick2
set "PROFILE=2"
goto :profile_ready

:profile_pick1
set "PROFILE=1"
goto :profile_ready

:profile_fallback
echo [llama_server] 未取得选择，回落默认档位 1。
set "PROFILE=1"

:profile_ready
REM 任何非 1/2 的意外值一律按档 1 处理，保证一定能启动。
if "%PROFILE%"=="2" goto :select2
set "PROFILE=1"
set "PNAME=AIMindTree 提取档"
set "P_ARGS=%P1_ARGS%"
goto :launch

:select2
set "PNAME=Agent 编程规划档"
set "P_ARGS=%P2_ARGS%"

:launch
echo [llama_server] profile = %PROFILE% (%PNAME%)
echo [llama_server] model: %MODEL%
echo [llama_server] alias: %ALIAS%
echo [llama_server] cmd: "%LLAMA_DIR%\llama-server.exe" %COMMON% %P_ARGS%
echo.

cd /d "%LLAMA_DIR%"

"%LLAMA_DIR%\llama-server.exe" %COMMON% %P_ARGS%

endlocal

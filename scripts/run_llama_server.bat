@echo off
REM ============================================================
REM  AIMindTree 本地推理后端 —— 拉起 llama.cpp 的 llama-server
REM
REM  用法：
REM     scripts\run_llama_server.bat
REM
REM  它只做一件事：在 127.0.0.1:8085 起 llama-server（已经在跑就直接退出）。
REM  想「llama-server + Python 服务端」一起起，用 scripts\run_llm_server.bat。
REM
REM  推理程序目录（固定）：D:\Local_Llama\llama-b9993-bin-win-cuda-13.3-x64
REM    主模型   models\Qwen3.8-27B-GSQ-RCO-IQ2_XS-mtp.gguf   8.77 GB（自带 MTP 投机解码 draft）
REM    多模态   models\mmproj-Qwen3.8-27B-BF16.gguf          931 MB
REM
REM  ---- 参数取舍（2026-10-27 本机实测：RTX 4060 Laptop 8GB / i7-13650HX / 64GB RAM，
REM       llama.cpp b9993 CUDA 13.3）----
REM    -c 65536     总上下文。配 --parallel 2 时每 slot 32768，够放整篇长笔记 + 8192 输出。
REM    --parallel 2 单用户桌面端给 2 个 slot：前台对话与后台异步任务（T14 查重等）互不排队。
REM                 注意 -c 是**总量**，会被 slot 数平分，不是每 slot 的上下文。
REM    -ctk/-ctv q8_0   KV 缓存量化到 8bit，占用比 f16 减半，长上下文下省 1GB 以上。
REM    -ngl 99      全部层上显卡。实测比让 --fit 自动挑层数快 3-5 倍（8 tok/s vs 1.5 tok/s）：
REM                 显存只有 8GB、模型 8.77GB 装不下，--fit 会保守地把大量层退回 CPU。
REM                 显式给了 -ngl 后 --fit on 会失效（llama.cpp 会打一条 warning 并跳过），
REM                 所以这里保留 --fit on 只是为了让没写 -ngl 时的场景仍安全。
REM    --no-mmproj-offload  视觉投影留 CPU，给主模型腾出约 950MB 显存，实测快 20%-30%。
REM                 当前文本链路不用多模态，但 --mmproj 仍挂着，以后接图片直接可用。
REM    -fa on       开 Flash Attention。
REM    --jinja      Qwen3.5 的聊天模板必须走 jinja，否则思考/工具标签渲染不对。
REM    --reasoning off  关闭思考。实测开启时 60 字回答要配 400+ 字思考，
REM                 max_tokens 会被思考吃掉大半，长 JSON 任务基本跑不完。
REM                 App 侧 structured_parse.dart 本身有 <think> 容错，开着也安全，
REM                 要开就把 off 改成 auto（或 on）并配 --reasoning-budget 限制思考长度。
REM    --spec-type draft-mtp  用模型自带的 MTP draft（GGUF 里 nextn_predict_layers=1），
REM                 不需要再给 --spec-draft-model（-md）。实测接受率 55%-70%。
REM    --spec-draft-n-max 4   默认 3。实测 4 略好；调到 8 接受率掉到 36% 且明显变慢，别调大。
REM    --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.05 --repeat-penalty 1.05
REM                 对齐 GGUF 元数据 general.sampling.* 与 Qwen3 官方推荐；
REM                 本项目以结构化 JSON 输出为主，要的是稳不是发散，所以温度偏低。
REM    -n 8192      单次最大输出 token。T1 一次抽几十个知识点的大 JSON 需要这个量级。
REM                 注意：本机实测 tg 约 8 tok/s，跑满 8192 要约 17 分钟，
REM                 因此 llm_server\config.yaml 的 timeouts 已从 120s 放宽到 900s。
REM
REM  启动后：
REM    健康检查   http://127.0.0.1:8085/health
REM    模型列表   http://127.0.0.1:8085/v1/models
REM  退出：在本窗口按 Ctrl+C
REM ============================================================
setlocal EnableDelayedExpansion

set "LLAMA_DIR=D:\Local_Llama\llama-b9993-bin-win-cuda-13.3-x64"
set "MODEL=models\Qwen3.8-27B-GSQ-RCO-IQ2_XS-mtp.gguf"
set "MMPROJ=models\mmproj-Qwen3.8-27B-BF16.gguf"
set "HOST=127.0.0.1"
set "PORT=8085"
REM 必须与 llm_server\config.yaml 的 backends.llama_cpp.default_model / models 逐字一致，
REM 否则 llm_server 拿到的模型名对不上（/v1/models 返回的 id 就是 --alias 的值）。
set "ALIAS=Qwen3.8-27B-Uncensored"

REM 清空代理：本机系统代理（127.0.0.1:xxxxx）会把 127.0.0.1 的请求也送给代理，
REM 表现为「本地后端连不上」的假故障。
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

REM ---------- 已经在跑？ ----------
curl -s -m 3 http://%HOST%:%PORT%/health >nul 2>&1
if not errorlevel 1 (
    echo [llama_server] already running on %HOST%:%PORT% , nothing to do.
    echo [llama_server] health: http://%HOST%:%PORT%/health
    endlocal & exit /b 0
)

echo [llama_server] starting llama-server on %HOST%:%PORT% ...
echo [llama_server] model: %MODEL%
echo [llama_server] alias: %ALIAS%
echo.

cd /d "%LLAMA_DIR%"

"%LLAMA_DIR%\llama-server.exe" ^
  -m "%MODEL%" ^
  --mmproj "%MMPROJ%" ^
  --no-mmproj-offload ^
  --host %HOST% ^
  --port %PORT% ^
  -a "%ALIAS%" ^
  -c 65536 ^
  -n 8192 ^
  -ngl 99 ^
  -fa on ^
  -ctk q8_0 ^
  -ctv q8_0 ^
  --jinja ^
  --parallel 2 ^
  --spec-type draft-mtp ^
  --spec-draft-n-max 4 ^
  --reasoning off ^
  --temp 0.6 ^
  --top-p 0.95 ^
  --top-k 20 ^
  --min-p 0.05 ^
  --repeat-penalty 1.05

endlocal

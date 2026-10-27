@echo off
REM ============================================================
REM  AIMindTree 服务端一键启动 —— llama.cpp(llama-server) + LLM Server
REM
REM  用法：
REM     scripts\run_llm_server.bat              默认 8787 端口
REM     scripts\run_llm_server.bat --port 8788  端口被占时换一个
REM
REM  它做两件事（缺一步都起不来）：
REM    1) 确认 llama-server 在 127.0.0.1:8085 跑着 —— 没起就自动拉起并等 /health 就绪
REM    2) 启动 LLM Server（Python）—— http://127.0.0.1:8787
REM
REM  推理后端是本地 llama.cpp（llama-server），**不再使用 Ollama**。
REM  想单独起 llama-server（不启 Python 服务端）用 scripts\run_llama_server.bat。
REM
REM  启动后：
REM    管理后台   http://127.0.0.1:8787/admin
REM    健康检查   http://127.0.0.1:8787/health
REM    推理后端   http://127.0.0.1:8085/health
REM  退出：在本窗口按 Ctrl+C（llama-server 那个最小化窗口要单独关）
REM ============================================================
setlocal EnableDelayedExpansion

set "REPO=%~dp0.."
set "VENV=C:\Users\ASUS\.workbuddy\binaries\python\envs\aimindtree-llm\Scripts\python.exe"
set "BASE=C:\Users\ASUS\.workbuddy\binaries\python\versions\3.13.12\python.exe"
set "LLAMA_HOST=127.0.0.1"
set "LLAMA_PORT=8085"
set "LAUNCH=%REPO%\scripts\run_llama_server.bat"
if not defined LLAMA_PROFILE set "LLAMA_PROFILE=1"

REM 清空代理：本机系统代理 127.0.0.1:44166 会把 127.0.0.1 的请求送给代理，
REM 表现为「本地后端连不上」的假故障（服务端默认 trust_env=False，这里双保险）。
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "http_proxy="
set "https_proxy="
set "NO_PROXY=localhost,127.0.0.1,::1"
set "no_proxy=localhost,127.0.0.1,::1"

REM ---------- Python 解释器 ----------
if exist "%VENV%" (
    set "PY=%VENV%"
    echo [llm_server] using venv: %VENV%
) else (
    set "PY=%BASE%"
    echo [llm_server] venv not found, using base python: %BASE%
    echo [llm_server] if dependencies are missing, run:
    echo     "%BASE%" -m pip install -r "%REPO%\llm_server\requirements.txt"
)

REM ---------- [1/2] llama-server（本地推理后端） ----------
echo [llm_server] [1/2] checking llama-server on %LLAMA_HOST%:%LLAMA_PORT% ...

curl -s -m 3 http://%LLAMA_HOST%:%LLAMA_PORT%/health >nul 2>&1
if not errorlevel 1 goto :llama_ready

echo [llm_server] llama-server 未运行，正在启动（最小化窗口）...
if not exist "%LAUNCH%" (
    echo [llm_server] 找不到启动器: %LAUNCH%
    pause
    endlocal & exit /b 1
)
start "" /min "%LAUNCH%" %LLAMA_PROFILE%

REM 轮询等待 /health 就绪。27B 模型加载 + 首次 CUDA 初始化需要几十秒，
REM 这里给 60 次 * 3 秒 = 180 秒；磁盘慢时可以调大 _max。
set /a _tries=0
set /a _max=60
:wait_llama
set /a _tries+=1
curl -s -m 3 http://%LLAMA_HOST%:%LLAMA_PORT%/health >nul 2>&1
if not errorlevel 1 goto :llama_ready
if !_tries! geq !_max! (
    echo [llm_server] 等待 llama-server 就绪超时（180s）。
    echo [llm_server] 请手动运行 scripts\run_llama_server.bat 看报错，或检查：
    echo     1^) %LAUNCH% 里的 LLAMA_DIR / 模型文件名是否正确
    echo     2^) 显存是否被别的程序占满（nvidia-smi）
    pause
    endlocal & exit /b 1
)
REM 用 ping 制造 3 秒节拍（-n 4 = 首包 + 3 个间隔，约 3 秒）。不用 timeout：其行为依赖 stdin 是否被
REM 重定向——控制台下完整睡 3 秒，重定向下则立即报「不支持输入重新定向」并返回，两种环境节拍不一致。
ping -n 4 127.0.0.1 >nul 2>&1
goto :wait_llama

:llama_ready
echo [llm_server] llama-server OK（http://%LLAMA_HOST%:%LLAMA_PORT%/health）

REM ---------- [2/2] LLM Server ----------
echo [llm_server] [2/2] starting LLM Server ...
echo [llm_server] repo: %REPO%
echo.

"%PY%" "%REPO%\llm_server\run.py" %*

if errorlevel 1 (
    echo.
    echo [llm_server] exited with error. Common causes:
    echo   1^) dependencies missing  -> pip install -r llm_server\requirements.txt
    echo   2^) port 8787 occupied    -> run_llm_server.bat --port 8788
    echo   3^) config.yaml broken    -> check llm_server\config.yaml
    echo   4^) llama-server 掉了     -> 看那个最小化窗口的报错（显存不足最常见）
    pause
)

endlocal

@echo off
chcp 65001 >nul
REM ============================================================
REM  AIMindTree 服务端一键启动 —— Ollama + LLM Server
REM
REM  用法：
REM     scripts\run_llm_server.bat              默认 8787 端口
REM     scripts\run_llm_server.bat --port 8788  端口被占时换一个
REM
REM  它做三件事（缺一步都起不来）：
REM    1) 确认 Ollama 在跑        —— 没起就自动 `ollama serve`（最小化窗口）
REM    2) 确认模型 qwen3:8b-8k 在  —— 不在就自动 create（读 llm_server\ollama\Modelfile.qwen3-8k）
REM    3) 启动 LLM Server          —— http://127.0.0.1:8787
REM
REM  启动后：
REM    管理后台   http://127.0.0.1:8787/admin
REM    健康检查   http://127.0.0.1:8787/health
REM  退出：在本窗口按 Ctrl+C（Ollama 那个最小化窗口要单独关）
REM ============================================================
setlocal EnableDelayedExpansion

set "REPO=%~dp0.."
set "VENV=C:\Users\ASUS\.workbuddy\binaries\python\envs\aimindtree-llm\Scripts\python.exe"
set "BASE=C:\Users\ASUS\.workbuddy\binaries\python\versions\3.13.12\python.exe"
set "MODEL=qwen3:8b-8k"
set "MODELFILE=%REPO%\llm_server\ollama\Modelfile.qwen3-8k"

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

REM ---------- [1/3] Ollama 服务 ----------
echo [llm_server] [1/3] checking Ollama ...
where ollama >nul 2>&1
if errorlevel 1 (
    echo [llm_server] 找不到 ollama 命令。请先安装 Ollama: https://ollama.com/download
    pause
    exit /b 1
)

ollama list >nul 2>&1
if errorlevel 1 (
    echo [llm_server] Ollama 未运行，正在启动 ollama serve ...
    start "" /min ollama serve
    set /a _tries=0
    :wait_ollama
    set /a _tries+=1
    ollama list >nul 2>&1
    if not errorlevel 1 goto :ollama_ready
    if !_tries! geq 20 (
        echo [llm_server] 等待 Ollama 就绪超时（20s）。请手动运行 ollama serve 后重试。
        pause
        exit /b 1
    )
    timeout /t 1 /nobreak >nul
    goto :wait_ollama
)
:ollama_ready
echo [llm_server] Ollama OK

REM ---------- [2/3] 模型 ----------
echo [llm_server] [2/3] checking model %MODEL% ...
ollama list | findstr /c:"%MODEL%" >nul
if errorlevel 1 (
    echo [llm_server] 模型 %MODEL% 不存在，正在创建（约 1-2 分钟）...
    if not exist "%MODELFILE%" (
        echo [llm_server] 找不到 Modelfile: %MODELFILE%
        pause
        exit /b 1
    )
    ollama create %MODEL% -f "%MODELFILE%"
    if errorlevel 1 (
        echo [llm_server] 模型创建失败。请确认基础模型 qwen3:8b 已 pull：
        echo     ollama pull qwen3:8b
        pause
        exit /b 1
    )
    echo [llm_server] 模型 %MODEL% 创建完成
) else (
    echo [llm_server] 模型 %MODEL% 已存在
)

REM ---------- [3/3] LLM Server ----------
echo [llm_server] [3/3] starting LLM Server ...
echo [llm_server] repo: %REPO%
echo.

"%PY%" "%REPO%\llm_server\run.py" %*

if errorlevel 1 (
    echo.
    echo [llm_server] exited with error. Common causes:
    echo   1) dependencies missing  -^> pip install -r llm_server\requirements.txt
    echo   2) port 8787 occupied    -^> run_llm_server.bat --port 8788
    echo   3) config.yaml broken    -^> check llm_server\config.yaml
    pause
)

endlocal

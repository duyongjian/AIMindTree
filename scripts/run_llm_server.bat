@echo off
REM ============================================================
REM  AIMindTree LLM Server —— Windows 双击启动
REM  服务地址：http://127.0.0.1:8787
REM  健康检查：浏览器打开 http://127.0.0.1:8787/health
REM  退出：在本窗口按 Ctrl+C
REM ============================================================
setlocal

set "REPO=%~dp0.."
set "VENV=C:\Users\ASUS\.workbuddy\binaries\python\envs\aimindtree-llm\Scripts\python.exe"
set "BASE=C:\Users\ASUS\.workbuddy\binaries\python\versions\3.13.12\python.exe"

if exist "%VENV%" (
    set "PY=%VENV%"
    echo [run_llm_server] using venv: %VENV%
) else (
    set "PY=%BASE%"
    echo [run_llm_server] venv not found, using base python: %BASE%
    echo [run_llm_server] if dependencies are missing, run:
    echo     "%BASE%" -m pip install -r "%REPO%\llm_server\requirements.txt"
)

echo [run_llm_server] repo: %REPO%
echo.

"%PY%" "%REPO%\llm_server\run.py" %*

if errorlevel 1 (
    echo.
    echo [run_llm_server] exited with error. Common causes:
    echo   1) dependencies missing  -^> pip install -r llm_server\requirements.txt
    echo   2) port 8787 occupied    -^> run_llm_server.bat --port 8788
    echo   3) config.yaml broken    -^> check llm_server\config.yaml
    pause
)

endlocal

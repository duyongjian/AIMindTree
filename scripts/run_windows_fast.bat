@echo off
chcp 65001 >nul
REM AIMindTree Windows 桌面应用 —— 快速启动（日常用这个）。
REM
REM 与 scripts\run_windows.bat 的区别：**跳过** flutter pub get 与项目门禁
REM （dart tool\analyze_inproc.dart），直接 flutter run。
REM 那两个步骤只在「依赖变了」或「想先过一遍静态检查」时才需要跑，用完整脚本。
REM
REM 本脚本仍然做两件必须做的事（都与代理有关，别删）：
REM   1) 清空 HTTP_PROXY / HTTPS_PROXY / http_proxy / https_proxy
REM      —— 本机有系统代理 127.0.0.1:44166，会把 flutter run 的 VM Service
REM      WebSocket 拦成 502，于是卡在 "Connecting to the VM Service"（重试 350+
REM      次也不退，App 其实已经起来了）。只设 NO_PROXY 无效，必须清空。
REM   2) 显式 set PROGRAMFILES(X86) —— 某些精简环境没有这个变量。
REM
REM 前置条件（不在本脚本职责内）：
REM   - ollama serve 正在跑（本地推理）
REM   - scripts\run_llm_server.bat 已启动（App 的 AI 服务端，127.0.0.1:8787）
REM   App 冷启动会自己拉 /v1/app/config，无需手工配 provider。
REM
REM 退出：在 flutter run 窗口按 q 或 Ctrl+C。

setlocal

REM ---- 环境修补 ----
set "PROGRAMFILES(X86)=C:\Program Files (x86)"

set "HTTP_PROXY="
set "HTTPS_PROXY="
set "http_proxy="
set "https_proxy="
set "NO_PROXY=localhost,127.0.0.1,::1"
set "no_proxy=localhost,127.0.0.1,::1"

set "FLUTTER=D:\DevTools\flutter\bin\flutter.bat"

REM ---- 切到应用目录 ----
cd /d "%~dp0..\aimindtree_app"
if errorlevel 1 (
    echo !!! 找不到应用目录 aimindtree_app
    exit /b 1
)

echo === flutter run -d windows --debug  (fast: 跳过 pub get + 门禁) ===
call "%FLUTTER%" --no-version-check run -d windows --debug

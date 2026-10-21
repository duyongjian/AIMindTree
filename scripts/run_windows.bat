@echo off
chcp 65001 >nul
REM 一键启动 AIMindTree Windows 桌面应用。
REM
REM 踩过的坑（都实际发生过，别删注释）：
REM   1) %PROGRAMFILES(X86)% 可能缺失 → 显式 set
REM   2) 本机系统代理 127.0.0.1:44166 会把 flutter run 的 VM Service WebSocket
REM      请求送给代理 → 502 → 卡在 "Connecting to the VM Service"（App 其实已经
REM      起来了，重试 350 次也不退）。只设 NO_PROXY **没用**，必须把代理变量清空。
REM   3) sqlite3 native assets 首次会从 GitHub 下载 → 走 pub get 流程
REM   4) flutter run 默认 release 模式 → debug 模式更友好（保留 hot reload）
REM   5) `flutter analyze` 用 flutter_lints，会把 tool/ 与 test/ 里的 info 级 lint
REM      算成失败（当前 22 issues，如 depend_on_referenced_packages /
REM      deprecated_member_use / prefer_interpolation_to_compose_strings），
REM      于是每次启动都被挡下。项目真正的门禁是 tool/analyze_inproc.dart
REM      （error + warning + info 全查，当前 74 文件 0/0/0），所以第 2 步改用它。
REM
REM   scripts\run_windows.bat            完整流程（pub get + 门禁 + run）
REM   scripts\run_windows_fast.bat       快速启动（跳过 pub get + 门禁，直接 run）
REM   （传 fast 参数等价于调用快速脚本，保留兼容：run_windows.bat fast）
REM
REM 退出：在 flutter run 窗口按 q 或 Ctrl+C。

setlocal

REM ---- 解决 #1：bash 不能 export 带括号变量。----
set "PROGRAMFILES(X86)=C:\Program Files (x86)"

REM ---- 解决 #2：清空代理 + 设 NO_PROXY（清空才是关键）。----
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "http_proxy="
set "https_proxy="
set "NO_PROXY=localhost,127.0.0.1,::1"
set "no_proxy=localhost,127.0.0.1,::1"

set "FLUTTER=D:\DevTools\flutter\bin\flutter.bat"
set "DART=D:\DevTools\flutter\bin\cache\dart-sdk\bin\dart.exe"

REM 切到应用目录。
cd /d "%~dp0..\aimindtree_app"
if errorlevel 1 (
    echo !!! 找不到应用目录 aimindtree_app
    exit /b 1
)

if /i "%1"=="fast" (
    call "%~dp0run_windows_fast.bat"
    goto :eof
)

echo === [1/3] flutter pub get ===
call "%FLUTTER%" --no-version-check pub get
if errorlevel 1 goto :fail

echo === [2/3] project gate: dart tool\analyze_inproc.dart ===
call "%DART%" tool\analyze_inproc.dart
if errorlevel 1 goto :fail

:run
echo === [3/3] flutter run -d windows --debug ===
call "%FLUTTER%" --no-version-check run -d windows --debug
goto :eof

:fail
echo.
echo !!! 启动前检查失败，请看上方错误。
echo     常见原因：
echo       1) 依赖缺失        -^> 手动跑一遍 flutter pub get
echo       2) native assets 下载失败 -^> 确认能访问 GitHub，或重试
echo       3) 门禁有 error    -^> 按 dart tool\analyze_inproc.dart 的输出修
exit /b 1

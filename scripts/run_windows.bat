@echo off
REM 一键启动 AIMindTree Windows 桌面应用。
REM 处理沙箱/首次运行踩过的 4 个坑：
REM   1) %PROGRAMFILES(X86)% 可能缺失 → 显式 set
REM   2) http_proxy 会拦截 flutter_tester → set no_proxy
REM   3) sqlite3 native assets 首次会从 GitHub 下载 → 走 pub get 流程
REM   4) flutter run 默认 release 模式 → debug 模式更友好（保留 hot reload）

setlocal

REM 解决 #1：bash 不能 export 带括号变量。
set "PROGRAMFILES(X86)=C:\Program Files (x86)"

REM 解决 #2：把本地和 IPv6 loopback 加进 NO_PROXY。
set "NO_PROXY=localhost,127.0.0.1,::1"
set "no_proxy=localhost,127.0.0.1,::1"

REM 切到应用目录。
cd /d "%~dp0..\aimindtree_app"

echo === [1/3] flutter pub get ===
call "D:\DevTools\flutter\bin\flutter.bat" --no-version-check pub get
if errorlevel 1 goto :fail

echo === [2/3] flutter analyze (快速回归检查) ===
call "D:\DevTools\flutter\bin\flutter.bat" --no-version-check analyze
if errorlevel 1 goto :fail

echo === [3/3] flutter run -d windows ===
call "D:\DevTools\flutter\bin\flutter.bat" --no-version-check run -d windows --debug
goto :eof

:fail
echo !!! 启动前检查失败，请看上方错误。
exit /b 1
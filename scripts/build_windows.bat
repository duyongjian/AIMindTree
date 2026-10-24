@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
REM ============================================================
REM  AIMindTree - Windows release build (x64) + zip package
REM  Run: scripts\build_windows.bat   (double-click or from repo root)
REM  Output: dist\AIMindTree_<VER>_windows_x64.zip
REM  Keep VER in sync with pubspec.yaml "version:".
REM ============================================================
set "VER=1.0.0"
set "APP_DIR=%~dp0..\aimindtree_app"
set "OUT_DIR=%~dp0..\dist"

REM --- locate flutter: PATH first, fallback D:\DevTools\flutter ---
where flutter >nul 2>nul
if %errorlevel%==0 (
  set "FLUTTER=flutter"
) else if exist "D:\DevTools\flutter\bin\flutter.bat" (
  set "FLUTTER=D:\DevTools\flutter\bin\flutter.bat"
) else (
  echo [ERROR] flutter not found. Add it to PATH or edit this script.
  exit /b 1
)

cd /d "%APP_DIR%"

echo [1/3] flutter pub get ...
call %FLUTTER% pub get
if errorlevel 1 exit /b 1

echo [2/3] flutter build windows --release ...
call %FLUTTER% build windows --release
if errorlevel 1 exit /b 1

echo [3/3] Packaging zip ...
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
set "ZIP=%OUT_DIR%\AIMindTree_%VER%_windows_x64.zip"
if exist "%ZIP%" del "%ZIP%"
powershell -NoProfile -Command "Compress-Archive -Path 'build\windows\x64\runner\Release\*' -DestinationPath '%ZIP%'"
if errorlevel 1 exit /b 1

echo.
echo [DONE] %ZIP%
echo Unzip anywhere and run aimindtree_app.exe - no install needed.
exit /b 0

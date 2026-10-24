@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
REM ============================================================
REM  AIMindTree - Android release APK build
REM  Run: scripts\build_android.bat   (double-click or from repo root)
REM  Output: dist\AIMindTree_<VER>_android.apk
REM  NOTE: no release keystore yet, so Flutter signs with the debug
REM  key - fine for sideload testing. For store release signing see
REM  docs\BUILD.md section "Release signing".
REM  Keep VER in sync with pubspec.yaml "version:".
REM ============================================================
set "VER=1.0.0"
set "APP_DIR=%~dp0..\aimindtree_app"
set "OUT_DIR=%~dp0..\dist"

REM --- JDK: Android Studio bundled JBR (JAVA_HOME wins if already set) ---
if not defined JAVA_HOME set "JAVA_HOME=D:\AndroidStudio\jbr"

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

echo [2/3] flutter build apk --release ...
echo        (first run downloads Gradle + AGP, can take 10+ min)
call %FLUTTER% build apk --release
if errorlevel 1 exit /b 1

echo [3/3] Copying APK to dist ...
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
copy /y "build\app\outputs\flutter-apk\app-release.apk" "%OUT_DIR%\AIMindTree_%VER%_android.apk"
if errorlevel 1 exit /b 1

echo.
echo [DONE] %OUT_DIR%\AIMindTree_%VER%_android.apk
echo Install: on device enable "install unknown apps", then:
echo   adb install -r "%OUT_DIR%\AIMindTree_%VER%_android.apk"
exit /b 0

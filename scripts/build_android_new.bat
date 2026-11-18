@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
REM ============================================================
REM  AIMindTree - Android release 多架构包构建 (--split-per-abi)
REM  一次构建，按 ABI 分成三个独立 APK 存到 dist，互不覆盖：
REM    AIMindTree_android_arm64-v8a.apk   (新 64 位设备，主流)
REM    AIMindTree_android_armeabi-v7a.apk (老 32 位设备)
REM    AIMindTree_android_x86_64.apk      (x86 模拟器/少数设备)
REM  用法: scripts\build_android_new.bat
REM  说明: 暂无发布用 keystore，Flutter 用 debug 密钥签名，足够侧载测试。
REM ============================================================
set "APP_DIR=%~dp0..\aimindtree_app"
set "OUT_DIR=%~dp0..\dist"
set "APK_DIR=build\app\outputs\flutter-apk"

REM --- JDK: Android Studio 自带 JBR (若已设 JAVA_HOME 则优先) ---
if not defined JAVA_HOME set "JAVA_HOME=D:\AndroidStudio\jbr"

REM --- 定位 flutter: 优先 PATH，回退 D:\DevTools\flutter ---
where flutter >nul 2>nul
if %errorlevel%==0 (
  set "FLUTTER=flutter"
) else if exist "D:\DevTools\flutter\bin\flutter.bat" (
  set "FLUTTER=D:\DevTools\flutter\bin\flutter.bat"
) else (
  echo [ERROR] 未找到 flutter，请加入 PATH 或编辑本脚本。
  exit /b 1
)

cd /d "%APP_DIR%"

echo [1/3] flutter pub get ...
call %FLUTTER% pub get
if errorlevel 1 exit /b 1

echo [2/3] flutter build apk --release --split-per-abi ...
echo        (分架构出三个 APK；首次运行会下载 Gradle + AGP，可能耗时 10+ 分钟)
call %FLUTTER% build apk --release --split-per-abi
if errorlevel 1 exit /b 1

echo [3/3] 按 ABI 分开复制到 dist ...
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
set "COPIED=0"
for %%A in (arm64-v8a armeabi-v7a x86_64) do (
  set "SRC=%APK_DIR%\app-%%A-release.apk"
  set "DST=%OUT_DIR%\AIMindTree_android_%%A.apk"
  if exist "!SRC!" (
    copy /y "!SRC!" "!DST!" >nul
    if errorlevel 1 (
      echo   [WARN] 复制失败: %%A
    ) else (
      echo   [OK] !DST!
      set /a COPIED+=1
    )
  ) else (
    echo   [WARN] 未找到产物: !SRC!  (该 ABI 可能未在 target-platform 启用)
  )
)

echo.
echo [DONE] 已保存 !COPIED!/3 个架构包到 %OUT_DIR%
echo 安装: 按设备架构选对应 apk，开启"允许安装未知来源应用"后执行:
echo   adb install -r "%OUT_DIR%\AIMindTree_android_arm64-v8a.apk"
exit /b 0

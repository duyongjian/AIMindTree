# AIMindTree 打包教程（Windows / Android）

> 适用版本：Flutter 3.47.2 · Dart 3.13.2 · JDK 21（Android Studio 自带 JBR）
> 一键脚本：`scripts/build_windows.bat`、`scripts/build_android.bat`（双击即用，产物统一输出到仓库根 `dist/`）

## 0. 前置条件

| 项 | 要求 | 本机现状 |
|---|---|---|
| Flutter SDK | 3.47.x stable | ✅ `D:\DevTools\flutter`（PATH 已配） |
| JDK | 17+，推荐 JDK 21 | ✅ `D:\AndroidStudio\jbr`（OpenJDK 21.0.3） |
| Android SDK | flutter doctor 全绿 | ✅ 随 Android Studio 安装 |
| 版本号 | `aimindtree_app/pubspec.yaml` 的 `version:` | 当前 `1.0.0+1`，**发版时同步改脚本里的 `VER`** |

## 1. Windows 打包

### 一键脚本

```bat
scripts\build_windows.bat
```

流程：`flutter pub get` → `flutter build windows --release` → 用 PowerShell `Compress-Archive` 打成 `dist\AIMindTree_1.0.0_windows_x64.zip`。

### 手动等价命令

```bash
cd aimindtree_app
flutter build windows --release
# 产物：aimindtree_app/build/windows/x64/runner/Release/
#   aimindtree_app.exe  flutter_windows.dll  data/  各插件 dll
```

### 分发

zip 解压到任意目录即用，**无需安装**（绿色软件）。发给别人时整个 Release 目录一起打包，不要只给 exe。想做成安装包可后续上 MSIX（Visual Studio 生成）或 Inno Setup，当前测试阶段没必要。

## 2. Android 打包

### 一键脚本

```bat
scripts\build_android.bat
```

流程：设 `JAVA_HOME` → `flutter pub get` → `flutter build apk --release` → 复制到 `dist\AIMindTree_1.0.0_android.apk`。**首次构建会下载 Gradle 发行包 + AGP + 依赖，10 分钟以上属正常**（取决于网速）。

### 手动等价命令

```bash
cd aimindtree_app
flutter build apk --release
# 产物：aimindtree_app/build/app/outputs/flutter-apk/app-release.apk
```

### 安装到手机

1. 手机开启「安装未知应用」（设置 → 应用 → 特殊权限）；
2. 数据线连接，执行：
   ```bat
   adb install -r dist\AIMindTree_1.0.0_android.apk
   ```
   或把 apk 发到手机（微信/QQ 传输）点击安装；
3. 覆盖安装用 `-r`；版本降级需先卸载。

### 进阶：按 ABI 分包（包体减半）

单包里含 arm64 + arm32 两套 so，约 20MB+。拆开发只装对应架构：

```bash
flutter build apk --release --split-per-abi
# 产物：app-arm64-v8a-release.apk / app-armeabi-v7a-release.apk
```

绝大多数 2020 年后手机是 arm64-v8a，发这一个就够。

## 3. 正式发布签名（上架/长期分发才需要）

当前**未配置 release keystore**，Flutter 自动用 debug 密钥签名——自测/内部流转没问题，但 debug 签名不能上应用商店，且重装可能冲突。

### 第一步：生成 keystore（只需一次，妥善保管！）

```bat
keytool -genkey -v -keystore %USERPROFILE%\aimindtree-release.jks ^
  -keyalg RSA -keysize 2048 -validity 10000 -alias aimindtree
```

按提示输密码（**忘了就找不回，全部重来**）。

### 第二步：建 `android/key.properties`（勿入库存）

```properties
storeFile=C:/Users/ASUS/aimindtree-release.jks
storePassword=上面设的密码
keyPassword=上面设的密码
keyAlias=aimindtree
```

（路径用正斜杠；`key.properties` 已在 .gitignore 忽略名单里加一条。）

### 第三步：`android/app/build.gradle.kts` 接线

文件顶部加：

```kotlin
import java.util.Properties
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
```

android 块内、defaultConfig 之后加：

```kotlin
signingConfigs {
    create("release") {
        storeFile = keystoreProperties["storeFile"]?.let { file(it) }
        storePassword = keystoreProperties["storePassword"] as String?
        keyAlias = keystoreProperties["keyAlias"] as String?
        keyPassword = keystoreProperties["keyPassword"] as String?
    }
}
buildTypes {
    release {
        signingConfig = signingConfigs.getByName("release")
    }
}
```

配好后 `flutter build apk --release` 即为正式签名包。

## 4. 版本号管理

`pubspec.yaml`：`version: 1.0.0+1`（前者=显示版本，后者=安卓 versionCode，**每次发版 +1**）。发版流程：改 pubspec → 同步改两个 bat 里的 `VER` → 跑脚本。

## 5. 常见问题

| 现象 | 原因 | 解法 |
|---|---|---|
| `flutter` 不是内部或外部命令 | PATH 没配 | 脚本已兜底到 `D:\DevTools\flutter\bin`；或把该目录加进 PATH |
| 安卓构建报 JDK 错 | JAVA_HOME 指错 | 脚本自动设 `D:\AndroidStudio\jbr`；手工构建先 `set JAVA_HOME=D:\AndroidStudio\jbr` |
| Gradle 下载卡死 | 代理干扰 | 本机直连一般无事；若开过代理，临时 `set HTTP_PROXY=` 再构建 |
| Windows 构建后 exe 打不开 | 缺 VC 运行库 | 目标机装 VC++ Redistributable（x64），或整目录拷贝而非单 exe |
| 想改应用名/图标 | — | 名称：Windows 改 `windows/runner/main.cpp` 窗口标题、安卓改 `android/app/src/main/AndroidManifest.xml` 的 `android:label`；图标：`flutter pub run flutter_launcher_icons`（需先加配置） |

## 6. 产物位置速查

```
dist/
├── AIMindTree_1.0.0_windows_x64.zip   # Windows 绿色包
└── AIMindTree_1.0.0_android.apk       # 安卓安装包
```

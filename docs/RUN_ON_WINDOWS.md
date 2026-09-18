# AIMindTree 真机启动手册（Windows 桌面 / Android Studio）

> 适用范围：AIMindTree 当前 P0 全量功能（T01-T07）真机端到端验证。
> 沙箱里跑不了 `flutter run -d windows`（无 GPU/桌面 + reg.EXE 黑名单），本手册是给**真机用户**用的。

---

## 一、环境检查

### 1.1 必备
- **Flutter 3.47+ stable**（已验证 `D:\DevTools\flutter`）
- **任选一种运行目标**：
  - **A. Windows 桌面**：Visual Studio 2022 Community（含 MSVC C++ build tools + "使用 C++ 的桌面开发" 工作负载）
  - **B. Android Studio**：Android SDK 35（已验证）+ 任一 Android 模拟器（API 21+）或连接的 Android 真机（开发者模式 + USB 调试）
- **JDK 17**（Android Studio 自带 OpenJDK 17 可）

### 1.2 选配
- **Chrome**（如果要 `flutter run -d chrome`）

### 1.3 一键体检
```bash
cd D:\AndroidStudioProjects\AIMindTree\aimindtree_app
flutter doctor
```
期望：除了 "Chrome - develop for the web"（如果不需要 web 可忽略）和 Proxy Configuration 外，其他都是 ✓。

> ⚠️ `flutter doctor` 在某些沙箱里会卡 `reg.EXE` 黑名单，**真机跑无此问题**。

---

## 二、启动方式（按推荐度排序）

### ⭐ 方式 A：Android Studio（最省事）
适合所有装了 Android Studio 的开发者，**自带设备选择 / 热重载按钮 / 调试面板**。

1. **打开项目**：Android Studio → File → Open → 选 `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\`（**注意是 `aimindtree_app` 不是 `AIMindTree`，也不是 `android/`**）
2. **装 Flutter 插件**：File → Settings → Plugins → Marketplace → 搜 "Flutter" → Install（如果已装跳过）
3. **等 Gradle Sync 完成**（首次 2-5 分钟，左下角进度条）
4. **等 `pub get` 完成**（Android Studio 顶部应自动触发；或菜单 Tools → Flutter → Flutter Pub Get）
5. **选设备**：顶部工具栏设备下拉框：
   - Android 模拟器：要先开 AVD（Tools → Device Manager → Create Device）
   - Android 真机：USB 连 + 开发者模式 + USB 调试
   - Windows 桌面：列表最下面会显示 "Windows (desktop)"
6. **点 ▶ Run 'main.dart'**（或 Shift+F10）
7. **首次编译**：
   - Android：3-8 分钟（Gradle + Dart 编译）
   - Windows：3-8 分钟（MSVC 编译）
   - 增量：5-15 秒
8. **跑起来**：4 Tab（笔记 / 提取 / 知识树 / 设置）就绪

**Android Studio 热重载**：代码改了按 Ctrl+S（或点 ⚡ 闪电按钮）即可热重载，不用重启 App。

### 方式 B：脚本启动（推荐给命令行党）
```bash
"D:\AndroidStudioProjects\AIMindTree\scripts\run_windows.bat"
```
脚本自动处理：
- `PROGRAMFILES(X86)` 环境变量缺失
- `http_proxy` 拦截本地 loopback
- `flutter pub get` + `flutter analyze` + `flutter run -d windows` 三步串行

### 方式 C：手工命令
```bash
cd D:\AndroidStudioProjects\AIMindTree\aimindtree_app
set PROGRAMFILES(X86)=C:\Program Files (x86)
set no_proxy=localhost,127.0.0.1,::1
flutter pub get
flutter run -d windows --debug
```

### 方式 D：Android 命令行
```bash
cd D:\AndroidStudioProjects\AIMindTree\aimindtree_app
flutter run -d android    # 自动选连接的设备 / 启动模拟器
flutter devices           # 看可用设备列表
```

---

## 三、首次启动会做什么

1. **pub get**：拉 drift / drift_flutter / flutter_riverpod / ulid / path_provider / shared_preferences 等
2. **Drift codegen**（自动触发）：生成 `lib/data/db/drift_database.g.dart`（已生成好，不用重跑）
3. **首次编译**：3-8 分钟（编译 Flutter Engine + Dart + 你的代码），后续增量 5-15 秒
4. **下载 sqlite3 native**：Drift 首次会下载 sqlite3 native assets（如果 GitHub 502，用 `lib/data/db` 临时方案）
5. **数据库初始化**：`AppDatabase` 在 `getApplicationDocumentsDirectory()/aimindtree.sqlite` 建库 + 14 张表
6. **默认 seed**：从 `LocalAiConfig` 自动 seed 一个 Dify Provider（`http://localhost:8080` + 来自 LocalAiConfig 的 API Key）
7. **App 启动**：4 Tab（笔记 / 提取 / 知识树 / 设置）就绪

---

## 四、首次跑通的最小 happy path

1. **笔记 Tab** → 点 + → 写一段关于"牛顿第二定律"的 Markdown → 保存
2. **编辑器右上 ★** → 触发 T1 提取（需要 Dify 在 localhost:8080 跑着，参考 `docs/DIFY_KNOWLEDGE_WORKFLOW.md`）
   - 成功：底部状态栏显示「已入库 N / 幻觉剔除 M」
3. **知识树 Tab** → 选刚才的笔记 → 看 KP 森林
4. **点任一 KP** → 老师模式：顶 KP 摘要 + 聊天
5. **设置 Tab**：
   - 「AI 提供商」：可改名 / 停用 / 删除默认 Dify，可新增 Dify
   - 「同步（Supabase ai-proxy）」：URL + Token 留空也 OK（Mock 占位）

---

## 三、首次启动会做什么

1. **pub get**：拉 drift / drift_flutter / flutter_riverpod / ulid / path_provider / shared_preferences 等
2. **Drift codegen**（自动触发）：生成 `lib/data/db/drift_database.g.dart`（已生成好，不用重跑）
3. **首次编译 Windows 桌面**：3-8 分钟（编译 Flutter Engine + Dart + 你的代码），后续增量 5-15 秒
4. **下载 sqlite3.dll**：Drift 在 Windows 上首次会从 GitHub release 拉 sqlite3 native assets（如果 GitHub 502，用 `lib/data/db` 临时方案）
5. **数据库初始化**：`AppDatabase` 在 `getApplicationDocumentsDirectory()/aimindtree.sqlite` 建库 + 14 张表
6. **默认 seed**：从 `LocalAiConfig` 自动 seed 一个 Dify Provider（`http://localhost:8080` + 来自 LocalAiConfig 的 API Key）
7. **App 启动**：4 Tab（笔记 / 提取 / 知识树 / 设置）就绪

---

## 四、首次跑通的最小 happy path

1. **笔记 Tab** → 点 + → 写一段关于"牛顿第二定律"的 Markdown → 保存
2. **编辑器右上 ★** → 触发 T1 提取（需要 Dify 在 localhost:8080 跑着，参考 `docs/DIFY_KNOWLEDGE_WORKFLOW.md`）
   - 成功：底部状态栏显示「已入库 N / 幻觉剔除 M」
3. **知识树 Tab** → 选刚才的笔记 → 看 KP 森林
4. **点任一 KP** → 老师模式：顶 KP 摘要 + 聊天
5. **设置 Tab**：
   - 「AI 提供商」：可改名 / 停用 / 删除默认 Dify，可新增 Dify
   - 「同步（Supabase ai-proxy）」：URL + Token 留空也 OK（Mock 占位）

---

## 五、踩坑清单（真机已验证）

### 5.1 `reg.EXE` 黑名单（仅沙箱）
真机无此问题。

### 5.2 `PROGRAMFILES(X86)` 缺失
Bash 不能 `export PROGRAMFILES(X86)=...`（括号被解析），要用 `env "PROGRAMFILES(X86)=C:/Program Files (x86)" cmd` 或者 .bat 脚本里的 `set "PROGRAMFILES(X86)=C:\Program Files (x86)"`。

### 5.3 http_proxy 拦截 flutter_tester
如果用公司 VPN 或代理，`http_proxy` 会拦截 `127.0.0.1` 的 websocket。`set no_proxy=localhost,127.0.0.1,::1`。

### 5.4 sqlite3 native assets 下载失败
Drift 在 Windows 桌面首次运行会下载 `sqlite3.dll`（~1.5MB），从 GitHub release。如果 GitHub 502/限速：
- 方案 A：等几秒重试
- 方案 B：手动下 `sqlite3.dll` 放到 `C:\Users\<you>\AppData\Local\aimindtree\...`
- 方案 C：用 Python 自带的 sqlite3.dll 拷贝到 `aimindtree/.dart_tool/hooks_runner/shared/sqlite3/build/download-*/`

### 5.5 Drift 生成代码过期
如果改了 `lib/data/db/tables.dart`，需要重新跑：
```bash
cd D:\AndroidStudioProjects\AIMindTree\aimindtree_app
dart run build_runner build --delete-conflicting-outputs
```

### 5.6 同毫秒排序 bug（已修）
历史 bug：`MasteryRecords.currentMastery` 用 `ORDER BY updatedAt DESC` 在同毫秒连写时退化。已改用 `version` 列排序。无需手动处理。

---

## 六、调试技巧

### 6.1 看日志
Flutter 在 console 输出 `print` / `debugPrint`，包括 sync_engine 的 `[sync_engine]` / `[settings_repo]` 等 tag。

### 6.2 看数据库
```bash
# 用 DB Browser for SQLite 打开
%APPDATA%\com.example.aimindtree_app\aimindtree.sqlite
```
> 路径取决于 `package_name`，开发时通常是 `com.example.aimindtree_app`。

### 6.3 看 SecretStore
```bash
%APPDATA%\com.example.aimindtree_app\.aimindtree\secrets.json
```
> P0 是明文 JSON，生产替换为 flutter_secure_storage。

### 6.4 清空数据
```bash
rd /s /q "%APPDATA%\com.example.aimindtree_app"
```
下次启动会重建数据库 + 重新 seed Dify Provider。

---

## 七、跑测试（无需桌面）

真机也可以跑：
```bash
cd D:\AndroidStudioProjects\AIMindTree\aimindtree_app
set PROGRAMFILES(X86)=C:\Program Files (x86)
set no_proxy=localhost,127.0.0.1,::1
flutter test --no-pub
```
期望：**53 / 53 通过**。

---

## 八、上 supabase 后端（可选）

设置 Tab → 同步 → 填：
- Base URL：`https://<project-ref>.supabase.co/functions/v1/ai-proxy`
- Token：你的 user JWT（Supabase Auth 颁发）

然后「启用自动同步」+「立即同步」。需要在 Supabase 端先部署 `/sync/{push,pull,manifest}` 三个 Edge Functions（参考 `docs/ARCHITECTURE_T03.md` §12）。沙箱里跑不了这一步，必须真机 + 联网。
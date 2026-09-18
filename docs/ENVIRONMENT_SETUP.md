# AIMindTree 本地环境搭建指南（Flutter + Dify）

> 面向对象：有 Kotlin / Android 基础、Flutter 边做边学的开发者
> 目标机器：本机（Windows 11 Pro，win32），工作区 `D:\AndroidStudioProjects\AIMindTree`
> 文档性质：**手把手、命令可直接复制执行**。每步都说明「为什么」，不要无脑复制。

---

## 0. 先读这一段：本机实测环境快照

下面所有结论都来自**在这台机器上实际跑命令得到的结果**，不是通用模板。请不要跳过。

| 项目 | 实测结果 | 需要做什么 |
|---|---|---|
| 操作系统 | Windows 11 Pro（win32） | — |
| **C 盘空间** | ✅ **927G 总 / 801G 已用 / 剩 127G（87%）** | ✅ 已通过 §0.2 迁移释放 ~100G（对比 9-03 的 23G） |
| **D 盘空间** | 🔴 **1.9T 总 / 63G 可用（97%）** | 🔴 偏紧：Dify 镜像 10–20G + Flutter 3–5G + Gradle/pub 缓存持续增长；装新东西前确认 ≥50G |
| **Docker WSL2 磁盘** | ✅ **已迁移到 D 盘**（C 盘已释放 ~100G） | 已完成，跳过 §0.2 |
| Gradle 缓存 | 🟡 `C:\Users\ASUS\.gradle` = **2.0 GB**，还会持续增长 | 改到 D 盘 |
| **Flutter** | ✅ **已安装**：`D:\DevTools\flutter`，**3.47.2 (stable)**（2026-08-26 发布），附带 Dart 3.13.2，DevTools 2.60.0，SDK 体积 3.3G，dart-sdk 与 flutter_tools.snapshot 均已缓存 | 只需加 PATH（§2.4），**不必重新下载** |
| **Dart** | ✅ 随 Flutter 附带，**3.13.2**（实测 `dart --version` 正常） | — |
| **Java 默认版本** | 🔴 `java -version` → **1.8.0_144**，解析到 `C:\ProgramData\Oracle\Java\javapath\java`（在系统变量 PATH 里） | 仍要处理 PATH 顺序，但**不必装新 JDK**，见下一条 |
| 机器上已有的 JDK | `C:\Program Files\Java\jdk-23`（23.0.1，太新）、`jdk1.8.0_144`（太老）、`jre1.8.0_144`、`C:\Program Files\Microsoft\jdk-11.0.16.101-hotspot`（11.0.16.1，太老） | 这四个都用不了，但**不需要再装 JDK**，见下一条 |
| ✅ **Android Studio 真实位置** | 🟢 **`D:\AndroidStudio`**（2.7G，版本 `AI-242.23339.11` = Ladybug 2024.2.1），`bin\studio64.exe` 存在 | **这才是你真正要用的 IDE** |
| ✅ **Android Studio 内置 JDK** | 🟢 **`D:\AndroidStudio\jbr` = OpenJDK 21.0.3**，实测 `java -version` 正常输出 | 🎉 **JDK 17 不用装了**！21 在 Gradle 8.x 支持的 17–22 范围内。设 `JAVA_HOME=D:\AndroidStudio\jbr` 即可，见 §1.0 |
| 🔴 **`C:\Program Files\Android\Android Studio`** | 🔴 **残缺残留**：只有 `jbr`/`lib`/`plugins` 三个目录，**没有 `bin` 目录**（无 `studio64.exe`），`jbr\lib` 只剩空的 `modules` | **直接无视它**，别去修，也别把它当 JAVA_HOME |
| **Android SDK** | ✅ 已装在 `C:\Users\ASUS\AppData\Local\Android\Sdk`<br>platforms: `android-33/34/35`<br>build-tools: `30.0.3/34.0.0/35.0.0`<br>platform-tools: ✅ `adb.exe` 在 | **不用重装**，只需设环境变量 |
| **Android cmdline-tools** | 🔴 **目录存在但是空的** | 必装，否则 `flutter doctor` 报错、licenses 无法接受 |
| ANDROID_HOME / ANDROID_SDK_ROOT | ❌ 均未设置 | 第 3 步设置 |
| JAVA_HOME | ❌ 未设置 | 第 1 步设置 |
| Git | ✅ 2.55.0 | — |
| **Docker Engine** | ✅ 29.7.2 已安装，但 🔴 **守护进程未运行**（连不上 `npipe:////./pipe/dockerDesktopLinuxEngine`） | 第 5 步**手动启动 Docker Desktop** |
| **Docker Compose** | ✅ v5.3.1，但 🔴 **本机只能用 `docker-compose`（带短横线）**，`docker compose`（空格）报 unknown command | 全文命令已按此写 |
| **Dify 源码** | 🟡 **已存在 `D:\dify`**，且 `docker\.env` 已复制好；版本 **1.0.1**；`VECTOR_STORE=weaviate` | 不用重新下载，见 §6 |
| ⚠️ `D:\dify` 是否 git 仓库 | ❌ **不是**（`git log` 报错），是解压/拷贝来的 | 以后无法 `git pull` 升级，见 §6.1 |
| **80 端口** | 🔴 **已被系统进程占用**（`0.0.0.0:80 LISTENING PID 4`） | Dify 不能用 80，改 8080 |
| 备用端口实测 | ✅ `8080` / `3000` / `5001` / `8888` 全部空闲 | Dify 改用 `8080` |
| ✅ **Dify 端口（已于 2026-09-04 改好）** | 🟢 `.env` 第 917 行 `EXPOSE_NGINX_PORT=8080`、第 918 行 `EXPOSE_NGINX_SSL_PORT=8443` | **已由主理人代改**，你不用再动。首次启动直接 `docker-compose up -d` |
| 当前项目性质 | 🟡 `D:\AndroidStudioProjects\AIMindTree` 现在是**纯 Kotlin JVM Gradle 项目**（kotlin.jvm 2.0.20 + Gradle 8.9），不是 Flutter 也不是 Android App | Flutter 项目要另建目录，见 §2.6 |

---

## 1 张图看清搭建顺序

顺序不能乱。JDK 是 Flutter Android 构建的地基，Docker Desktop 必须先跑起来 Dify 才有意义。

```mermaid
flowchart TD
    S0["第 0 步 · 磁盘空间治理<br/>✅ C 盘已释放（127G 可用）<br/>🔴 D 盘偏紧（63G 可用）"]

    S0 --> S0a["0.1 迁移 Docker WSL2 磁盘<br/>（若已完成迁移可跳过）"]
    S0 --> S0b["0.2 Gradle 缓存改到 D 盘<br/>GRADLE_USER_HOME"]
    S0 --> S0c["0.3 Pub 缓存改到 D 盘<br/>PUB_CACHE"]

    S0a --> S1
    S0b --> S1
    S0c --> S1

    S1["第 1 步 · 安装 JDK 17<br/>并修正 PATH 顺序<br/>当前 java 指向 1.8"]
    S1 --> S2["第 2 步 · 安装 Flutter SDK<br/>解压到 D 盘 + 配国内镜像"]
    S2 --> S3["第 3 步 · 对接已有 Android SDK<br/>设环境变量 + 补装 cmdline-tools"]
    S3 --> S4["第 4 步 · flutter doctor -v<br/>逐项排错"]

    S4 --> S5["第 5 步 · 手动启动 Docker Desktop<br/>命令行无法启动守护进程"]
    S5 --> S6["第 6 步 · 部署 Dify<br/>改端口 80 → 8080<br/>docker-compose up -d"]
    S6 --> S7["第 7 步 · 建「知识点提取」工作流<br/>拿 App API Key + curl 验证"]
    S7 --> S8["第 8 步 · 最终验证清单<br/>逐项打勾"]

    style S0 fill:#ffe0e0,stroke:#c00,stroke-width:3px
    style S1 fill:#fff4e0,stroke:#e08000
    style S5 fill:#e0f0ff,stroke:#0066cc
    style S6 fill:#e0f0ff,stroke:#0066cc
    style S8 fill:#e0ffe0,stroke:#00a000
```

---

## 关于本文的命令写法

本机默认 shell 是 **bash（Git Bash）**，但部分操作在 **PowerShell** 里更方便（尤其设置环境变量）。因此本文的命令基本都给两套：

```bash
# ← 这种标记的代码块在 Git Bash 里跑
```

```powershell
# ← 这种标记的代码块在 PowerShell 里跑
```

**路径写法差异**（新手最容易踩）：

| 位置 | Git Bash 写法 | PowerShell / cmd 写法 |
|---|---|---|
| C 盘用户目录 | `/c/Users/ASUS` | `C:\Users\ASUS` |
| 项目目录 | `/d/AndroidStudioProjects/AIMindTree` | `D:\AndroidStudioProjects\AIMindTree` |
| 读环境变量 | `$ANDROID_HOME` | `$env:ANDROID_HOME`（PS）/ `%ANDROID_HOME%`（cmd） |
| 复制文件 | `cp a b` | `Copy-Item a b` |

> ⚠️ **重要**：在 Git Bash 里用 `export` 设的环境变量**只在当前窗口有效，关掉就没了**。要永久生效，必须用 PowerShell 的 `setx` 或 Windows「系统属性 → 环境变量」图形界面。本文永久设置统一用 PowerShell。

---

# 第 0 步 · 磁盘空间治理（最重要，先做这一步）

## 0.0 为什么这是第 0 步

C 盘此前只剩 **23GB**，但用户已于 2026-09-04 完成 §0.2 的 Docker WSL2 磁盘迁移，现已释放到约 **127GB 可用（87%）**。不过代价是这些空间需求几乎全转到了 D 盘。接下来要装的东西分别要吃：

| 要装的东西 | 预估占用 | 默认落在哪（迁移后） |
|---|---|---|
| Flutter SDK（含 Dart、各平台工具链） | 1.5 – 3 GB，用一段时间后到 5 GB+ | D 盘（建议 `D:\DevTools\flutter`） |
| Pub 包缓存（`.pub-cache`） | 1 – 3 GB | D 盘（`D:\DevCache\pub-cache`） |
| Gradle 缓存 + 构建产物 | 🔴 **2 – 5 GB / 项目**（现在已经 2GB） | D 盘（`D:\DevCache\gradle`） |
| **Dify 的 Docker 镜像 + 数据卷** | 🔴 **10 – 20 GB**（9+ 个容器） | 🔴 D 盘的 WSL2 虚拟磁盘 |
| Android 模拟器镜像（如果新建 AVD） | 每个 3 – 8 GB | D 盘（`D:\DevCache\android-avd`） |

**结论，说得再直白一点（2026-09-04 实测更新）：**

- ✅ **C 盘已缓解**：迁移后 C 盘剩余约 **127GB**，构成本身很难再触顶。第 0 步的 C 盘危机已解除。
- 🔴 **但 D 盘变紧张了**：Dify 镜像 + 数据卷、Flutter SDK、Gradle/pub 缓存现在全堆在 D 盘，**D 盘只剩约 63GB（97% 已用）**。Dify 首次 `up -d` 会拉十几个 GB 镜像，加上 postgres/redis/weaviate 数据卷持续增长，很可能吃光这 63G。
- 🔴 **硬门槛**：开始装 Dify 前，务必确认 **D 盘剩余 ≥ 50GB**。不足的话先按 §0.6 清理 D 盘再继续，否则会在拉镜像中途磁盘满而失败——而**镜像拉取中途失败会留下一堆无法自动清理的层文件，反而更占空间**。

## 0.1 先看清楚各盘剩多少（先量再动）

```bash
# Git Bash：查看所有盘符
df -h
```

```powershell
# PowerShell：更清楚的版本，显示 GB
Get-PSDrive -PSProvider FileSystem |
  Select-Object Name,
    @{n='已用GB';e={[math]::Round($_.Used/1GB,1)}},
    @{n='剩余GB';e={[math]::Round($_.Free/1GB,1)}}
```

本机当前实测结果（2026-09-04 实测，已反映迁移后状态）：

```
Filesystem   Size  Used Avail Use% Mounted on
C:            927G  801G  127G  87% /      ← ✅ 已缓解（迁移后释放 ~100G）
D:            1.9T  ~1.84T  63G  97% /d    ← 🔴 偏紧，装 Dify 前先确认 ≥50G
```

再确认迁移已生效（C 盘旧位置应已消失，新 vhdx 在 D 盘）：

```bash
# C 盘旧位置应该已经没了（如果还在，说明没迁成功）
ls /c/Users/ASUS/AppData/Local/Docker/wsl/disk/docker_data.vhdx 2>&1
# 期望：No such file or directory

# 新的 vhdx 在 D 盘（具体路径取决于 Docker Desktop 设置，常见如下）
ls -la /d/DockerData/*.vhdx 2>&1
```

```powershell
# PowerShell 版本：确认 C 盘旧文件不存在 + 看 D 盘新文件大小
Test-Path "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"   # 期望 False
Get-ChildItem "D:\DockerData" -Recurse -Filter *.vhdx |
  Select-Object FullName, @{n='GB';e={[math]::Round($_.Length/1GB,1)}}
```

## 0.2 迁移 Docker Desktop 的 WSL2 虚拟磁盘到 D 盘（释放 ~100GB）

> 🟢 **是否已做验收**：本机用户已于 **2026-09-04** 完成迁移——C 盘从 23G 可用涨到约 127G，D 盘的 `docker_data.vhdx` 已生效（用上方 §0.1 命令可验证）。**若你读到这里且已确认迁移完成，直接跳到 §0.3，本节可跳过。** 下面内容保留给「还没做 / 需要重做」的情况。

### 为什么要做

Docker Desktop 在 Windows 上用 WSL2 后端时，**所有镜像和数据卷都存在一个叫 `docker_data.vhdx` 的虚拟磁盘文件里**，默认放在 C 盘。这个文件**只会长大，不会自动缩小**——即使你 `docker rmi` 删了镜像，vhdx 文件的体积也不会自动回落。

所以：
- 想让 C 盘真正腾出空间，**光删镜像没用，必须迁移或重建这个文件**。
- 迁移之后，将来 Dify 那十几 GB 镜像会直接落到 D 盘，C 盘不再受影响。**一次投资，长期受益。**

### 方式 A：用 Docker Desktop 图形界面迁移（✅ 推荐，最安全）

Docker Desktop 自带迁移功能，会自己搬文件并保证一致性，**不会丢镜像和数据卷**。

1. 先手动启动 Docker Desktop（守护进程当前是没跑的，见第 5 步），等右下角托盘图标变成稳定的鲸鱼状态。
2. 点右上角 ⚙️ **Settings**。
3. 左侧选 **Resources → Advanced**。
4. 找到 **Disk image location**（有些版本叫 "Disk image location" 或在 "Virtual disk limit" 附近）。
5. 点 **Browse**，改成 `D:\DockerData`（目录不存在会自动建，也可以先手动建）。

   ```powershell
   # 可选：提前建好目录
   New-Item -ItemType Directory -Force -Path "D:\DockerData"
   ```

6. 点 **Apply & restart**。
7. ⏳ **耐心等**：要搬 100GB，取决于磁盘速度，**可能十几分钟到半小时以上**。搬运期间**不要关机、不要强退 Docker Desktop**。
8. 搬完后验证 C 盘空间确实释放了：

   ```bash
   df -h
   # 期望：C 盘 Avail 从 23G 涨到 120G 左右
   ```

   ```powershell
   # 确认新位置有文件了
   Get-ChildItem "D:\DockerData" -Recurse -Filter *.vhdx |
     Select-Object FullName, @{n='GB';e={[math]::Round($_.Length/1GB,1)}}
   ```

### 方式 B：如果那 100GB 本来就是垃圾（更快，但会删东西）

如果你确认那 100GB 里**没有任何还需要的镜像和数据**（比如都是以前别的项目留下的），可以直接清空重建，比搬 100GB 快得多。

> 🔴🔴 **数据丢失警告**
> 下面的操作会 **永久删除本机所有 Docker 镜像、容器、数据卷**，不可恢复。
> 执行前请务必先跑 `docker images` 和 `docker volume ls` 看一眼里面有什么。
> **如果不确定，请用方式 A。**

先看清楚有什么（只读，安全）：

```bash
# 需要先启动 Docker Desktop 才能跑
docker images
docker volume ls
docker ps -a
```

确认可以全删之后：

```bash
# 🔴 危险：删除所有未使用的镜像、容器、网络、数据卷
docker system prune -a --volumes
```

或者更彻底：Docker Desktop → 右上角 🐞 **Troubleshoot**（虫子图标）→ **Clean / Purge data**，勾选后确认。这个操作会**直接把 vhdx 文件重建为空**，C 盘立刻回收空间。

> ⚠️ 注意：单独跑 `docker system prune -a --volumes` **不会让 vhdx 文件变小**（只是里面空了）。要真正回收 C 盘空间，还是得走 Purge data 或方式 A 的迁移。这是 WSL2 虚拟磁盘的特性，不是 bug。

### 方式 C：只把 Dify 的数据卷挂到 D 盘（保底方案）

如果上面两种都不想做，至少可以让 Dify 的**持久化数据**落在 D 盘。但注意：**这只管数据，不管镜像**。镜像（十几 GB）仍然在 C 盘的 vhdx 里，所以**这只是缓解，不能替代方式 A**。

由于 Dify 源码本身就在 `D:\dify`，而它的 compose 文件默认用 `./volumes/...` 这样的**相对路径绑定挂载**，所以 **Dify 的数据卷其实已经天然落在 D 盘了**（`D:\dify\docker\volumes`）。可以自己确认：

```bash
ls /d/dify/docker/volumes
# 实测输出：myscale  oceanbase  opensearch  sandbox
# 目录只有 19K，说明从未启动过
```

所以针对本机，**方式 C 已经自动满足了，你要解决的核心还是「镜像占 C 盘」，也就是必须做方式 A 或 B。**

## 0.3 把 Gradle 缓存改到 D 盘

### 为什么要做

Gradle 会把下载的依赖、wrapper 发行包、构建缓存全塞进 `C:\Users\ASUS\.gradle`，**实测现在已经 2.0GB**。一个 Flutter Android 项目跑几轮 build 之后，这个目录 + 项目内 `build/` 目录轻松吃掉 2–5GB。C 盘扛不住。

`GRADLE_USER_HOME` 环境变量可以整体挪走它。

```powershell
# PowerShell（管理员不必要，普通权限即可）
# 1) 建目标目录
New-Item -ItemType Directory -Force -Path "D:\DevCache\gradle"

# 2) 永久设置环境变量（写入当前用户）
setx GRADLE_USER_HOME "D:\DevCache\gradle"
```

（可选）把已有的 2GB 缓存搬过去，避免重新下载依赖：

```powershell
# 先确保没有 Gradle / Android Studio 在跑，否则文件被占用会搬失败
Move-Item -Path "$env:USERPROFILE\.gradle\*" -Destination "D:\DevCache\gradle\" -Force
```

> ⚠️ `setx` 设置的变量**对已经打开的终端无效**。设置完请**关掉所有终端窗口重新开**，然后验证：

```powershell
# 新开一个 PowerShell
$env:GRADLE_USER_HOME    # 期望输出 D:\DevCache\gradle
```

```bash
# 新开一个 Git Bash
echo "$GRADLE_USER_HOME"  # 期望输出 D:\DevCache\gradle
```

## 0.4 把 Pub（Dart 包）缓存改到 D 盘

### 为什么要做

Flutter 的包管理器 pub 默认把包缓存到 `C:\Users\ASUS\AppData\Local\Pub\Cache`（实测该目录**目前还不存在**，因为 Flutter 没装）。趁现在还没生成，**提前设好，一劳永逸**，免得以后再搬。

```powershell
New-Item -ItemType Directory -Force -Path "D:\DevCache\pub-cache"
setx PUB_CACHE "D:\DevCache\pub-cache"
```

## 0.5 （可选）把 Android 模拟器镜像改到 D 盘

如果你打算用 Android 模拟器（每个 AVD 3–8GB），也一起挪走：

```powershell
New-Item -ItemType Directory -Force -Path "D:\DevCache\android-avd"
setx ANDROID_AVD_HOME "D:\DevCache\android-avd"
```

> 💡 真机调试（USB 连你的安卓手机）比模拟器省空间、省内存、也更快。**建议优先用真机**，模拟器这一步可以先跳过。

## 0.6 第 0 步验收

新开一个 PowerShell，逐条跑：

```powershell
df_check = $null
Get-PSDrive C,D | Select-Object Name, @{n='剩余GB';e={[math]::Round($_.Free/1GB,1)}}
$env:GRADLE_USER_HOME
$env:PUB_CACHE
```

| 检查项 | 期望结果 |
|---|---|
| C 盘剩余 | **≥ 100GB**（迁移后实测约 127GB） |
| 🔴 D 盘剩余 | **≥ 50GB**（现在才约 63GB，偏紧！装 Dify 前务必确认） |
| `$env:GRADLE_USER_HOME` | `D:\DevCache\gradle` |
| `$env:PUB_CACHE` | `D:\DevCache\pub-cache` |

> 🔴 **硬门槛：若 D 盘剩余 < 50GB，先清理 D 盘再继续，不要硬装 Dify。** Dify 首次 `up -d` 要拉 10–20GB 镜像，63GB 余量很可能在中途见底，导致拉取失败并留下无法自动清理的层文件。
>
> **D 盘清理建议（按安全程度排序）：**
> 1. 看 Docker 占了多少：`docker system df`（需在 Docker Desktop 启动后跑）。若 `Images` / `Volumes` 占用大，删掉无用镜像与卷：
>    ```bash
>    docker images            # 看有哪些镜像
>    docker rmi <无用镜像ID>   # 删具体无用镜像（别删正在用的 Dify 镜像）
>    docker volume ls         # 看数据卷
>    docker volume prune      # 删除所有「未被容器使用」的卷（🟡 确认无重要数据再跑）
>    ```
> 2. 清其他 D 盘大目录：已解压的安装包 `D:\Downloads`、旧的 Flutter/Gradle 缓存、不再用的项目。
> 3. 实在不够，可把 Dify 镜像之外的其他 Docker 项目数据卷搬走或删掉（务必先确认不是 Dify）。
>
> 🔴 **如果 C 盘剩余仍 < 40GB（迁移未生效），请不要继续。** 先回到 §0.2 把 Docker 磁盘迁移做掉。

---

# 第 1 步 · 安装 JDK 17

## 1.0 为什么必须是 17，不能用现成的 1.8 或 23

### 先说清楚：Flutter / Dart 本身「不需要」JDK

这是新手最容易误解的一点，先讲明白，免得你纠结"我能不能不装 JDK"：

- **Flutter / Dart 运行时本身不依赖 JDK。** Dart 有自带 VM，`flutter` / `dart` 命令直接跑，不需要 Java。
- **只有在「构建 Android APK / App Bundle」时才需要 JDK**——因为 Android 构建走 Gradle，而 Gradle 跑在 JVM 上，所以必须有 JDK。
- 其他平台的构建**都不需要 JDK**：
  - 构建 **Windows 桌面版** → 需要 **Visual Studio（MSVC）**，不需要 JDK；
  - 构建 **Web 版** → 用 **dart2js**，不需要 JDK。

**所以理论上**：如果你暂时只做 Windows 桌面版或 Web 版，可以**先不装 JDK、绕过这一步**。

**但为什么本文还是要求装 JDK 17？**

1. 本项目的 **P0 目标包含 Android**（手机 App），Android 构建绕不开 Gradle + JDK。
2. `flutter doctor` 的 **Android toolchain** 检查会**验证 Java 版本**，没装或版本不对会直接报 ✗，工具链不算"绿灯"。
3. 机器上现在**没有任何可用的 JDK 17–21**（见下方实测表），不装的话 Android 这条路根本走不通。

> 💡 一句话：**能绕，但本项目绕不开——为了 P0 的 Android + 让 `flutter doctor` 全绿，建议老老实实装 JDK 17。**

本机实测：

```bash
java -version
# java version "1.8.0_144"   ← 🔴 太老
which java
# /c/ProgramData/Oracle/Java/javapath/java   ← 注意这个路径，后面要用
```

机器上已有的 JDK：

| 已有 JDK | 版本 | 能不能用 | 原因 |
|---|---|---|---|
| `C:\Program Files\Java\jdk1.8.0_144` | 8 | ❌ 不能 | Android Gradle Plugin 8.x **要求 JDK 17+**，用 1.8 构建会直接失败 |
| `C:\Program Files\Java\jdk-23` | 23.0.1 | ⚠️ 不推荐 | 项目 Gradle wrapper 是 **8.9**，Gradle 8.9 官方最高只支持到 JDK 22，**JDK 23 会报 "Unsupported class file major version 67"**；且 AGP 官方基线就是 17 |
| 🆕 `C:\Program Files\Microsoft\jdk-11.0.16.101-hotspot` | 11.0.16.1 LTS | 🟡 能跑但太老 | 🆕 此前遗漏。实测能正常启动（`java -version` 输出 `openjdk version "11.0.16.1" 2022-08-12 LTS` / `Microsoft-40648`），但 **JDK 11 对 AGP 8.x 仍太老**，构建 Android 会失败 |
| `C:\Program Files\Java\jre1.8.0_144` | 8（仅 JRE） | ❌ 不能 | 只是 JRE 不是 JDK，且不带 `javac`；版本也太老 |
| `Android Studio\jbr` | ? | ❌ 不能 | 🔴 **实测已损坏**：跑 `java -version` 直接报 `Error: could not open 'C:\Program Files\Android\Android Studio\jbr\lib\jvm.cfg'`，连 JAVA_HOME 都当不了 |

**结论：机器上没有任何可用的 JDK 17–21，必须新装一个独立的 JDK 17。**

## 1.1 选哪个发行版

推荐 **Eclipse Temurin 17（LTS）**：

- 由 Adoptium 社区维护，**永久免费，无商业授权风险**（Oracle JDK 的商业条款对企业用途有限制，学生个人项目虽然没问题，但养成习惯更好）
- Android / Gradle / Flutter 生态里最常见的选择，遇到问题搜得到答案
- 官方提供 Windows `.msi` 安装包，一键装好

**下载地址**：https://adoptium.net/temurin/releases/?version=17&os=windows&arch=x64

选 **JDK**（不是 JRE）、**x64**、**Windows**、`.msi` 格式。

## 1.2 安装时的关键选项

运行 `.msi` 安装包，安装路径改到 **D 盘**（省 C 盘空间，JDK 约 300MB，不算大但顺手挪走）：

```
安装路径：D:\DevTools\jdk-17
```

安装向导里有几个勾选项，建议这样选：

| 选项 | 怎么选 | 为什么 |
|---|---|---|
| **Add to PATH** | ✅ 勾上 | 省事 |
| **Set JAVA_HOME variable** | ✅ **务必勾上** | Gradle / Flutter 都靠它找 JDK |
| **JavaSoft (Oracle) registry keys** | ⬜ 不勾 | 避免和已有 JDK 抢注册表 |
| **Associate .jar** | ⬜ 不勾 | 用不到 |

## 1.3 🔴 关键：修正 PATH 顺序（本机必做）

### 为什么这一步会卡住很多人

实测本机的 `java` 命令解析到了：

```
C:\ProgramData\Oracle\Java\javapath\java
```

这是 Oracle JDK 8 安装时留下的**"垫片"目录**，它在系统 PATH 里的位置**非常靠前**。结果就是：

> 即使你装好 JDK 17、`JAVA_HOME` 也设对了、`%JAVA_HOME%\bin` 也加进 PATH 了，
> 只要 `C:\ProgramData\Oracle\Java\javapath` 排在前面，
> **`java -version` 依然会显示 1.8.0_144。**

然后你会一脸困惑："我明明装了 17 啊？"——这就是本机最典型的坑。

### 怎么修

**方式 A：图形界面调顺序（推荐，直观）**

1. `Win + R` → 输入 `sysdm.cpl` → 回车
2. **高级** 选项卡 → **环境变量**
3. 在**上半部分「用户变量」**里找 `Path` → **编辑**
4. 确认里面有一行 `%JAVA_HOME%\bin`（Temurin 安装器通常会加）；没有就 **新建** 一行填上
5. 选中它，点 **上移** 按钮，移到**最顶端**
6. 在**下半部分「系统变量」**里找 `Path` → **编辑**，找到 `C:\ProgramData\Oracle\Java\javapath`
   - 稳妥做法：选中它 → **下移** 到最底部
   - 彻底做法：选中它 → **删除**（如果你确定不再需要 JDK 8。删了之后老的 Java 8 程序可能找不到 java，但一般无影响）
7. 一路点 **确定**
8. **关掉所有终端窗口**，重新打开

**方式 B：命令行验证（PowerShell）**

改完之后，看 PATH 里 java 相关条目的顺序：

```powershell
# 列出 PATH 中所有含 java/jdk 的条目，按顺序
$env:Path -split ';' | Where-Object { $_ -match 'java|jdk' }
```

期望输出中 **Temurin 17 的路径在 `Oracle\Java\javapath` 之前**（或后者已不存在）：

```
D:\DevTools\jdk-17\bin          ← 应该在前面
C:\ProgramData\Oracle\Java\javapath   ← 应该在后面，或者没有
```

## 1.4 手动设置 JAVA_HOME（如果安装器没设成功）

```powershell
setx JAVA_HOME "D:\DevTools\jdk-17"
```

> ⚠️ **不要**在 `JAVA_HOME` 后面加 `\bin`。Gradle 期望的是 JDK **根目录**，加了 `\bin` 会报 "JAVA_HOME is set to an invalid directory"。

## 1.5 第 1 步验收

**关掉所有终端，新开一个**，然后：

```bash
# Git Bash
java -version
javac -version
echo "$JAVA_HOME"
which java
```

```powershell
# PowerShell
java -version
javac -version
$env:JAVA_HOME
(Get-Command java).Source
```

| 检查项 | 期望输出 | 如果不对 |
|---|---|---|
| `java -version` | `openjdk version "17.0.x"` | 回到 §1.3 改 PATH 顺序 |
| `javac -version` | `javac 17.0.x` | 你可能装的是 JRE 不是 JDK，重装选 JDK |
| `$JAVA_HOME` | `D:\DevTools\jdk-17` | 回到 §1.4 |
| `which java` | 指向 `D:\DevTools\jdk-17\bin\java` | 🔴 如果还是 `ProgramData\Oracle\Java\javapath`，PATH 顺序没改对 |

> 💡 `java -version` 的输出是打到 **stderr** 的，所以在 bash 里 `java -version > /dev/null` 仍然会看到输出。这是正常现象，不是出错。

---

# 第 2 步 · 安装 Flutter SDK

## 2.0 为什么 Windows 上要手动解压 zip

Windows 上 Flutter **没有官方包管理器安装方式**（macOS 有 brew，Linux 有 snap）。虽然社区有 Chocolatey / Scoop 的包，但：

- 版本更新经常滞后
- 装的位置不好控制（可能又落到 C 盘）
- `flutter upgrade` 和包管理器的更新机制会互相打架

所以**官方推荐、也是最省事的方式：下载 zip，解压到你指定的目录，加进 PATH**。Flutter SDK 本身就是一个自包含的目录，Dart SDK 就在里面（`flutter\bin\cache\dart-sdk`），**不需要单独装 Dart**。

## 2.1 装到哪个盘 —— 推荐路径与理由

**推荐路径：`D:\DevTools\flutter`**

理由：

| 考虑点 | 说明 |
|---|---|
| **必须在 D 盘** | C 盘只剩 23GB，而 Flutter SDK 初装 1.5–3GB，用一段时间后 `bin\cache` 会涨到 5GB+（每个平台的引擎产物都会缓存）。放 C 盘是给自己埋雷 |
| **路径不能有空格** | 🔴 **绝对不要装到 `D:\Program Files\flutter`**。Flutter 工具链里有些脚本对空格处理不好，会出现莫名其妙的构建错误。这是官方明确警告过的 |
| **路径不能有中文** | 同理，中文路径会导致编码问题 |
| **不要放在需要管理员权限的目录** | `flutter upgrade` 要往 SDK 目录写文件。放在 `C:\Program Files` 下会因权限不足失败 |
| **和其他工具放一起，好管理** | 前面 JDK 装在 `D:\DevTools\jdk-17`，Flutter 放 `D:\DevTools\flutter`，以后一眼就知道开发工具都在哪 |

> ⚠️ 也**不要**把 Flutter SDK 解压进 `D:\AndroidStudioProjects\AIMindTree` 项目目录里。SDK 是全局工具，项目是代码，混在一起会被 git 误追踪，而且换项目还要重装。

## 2.2 🔴 先配国内镜像（在下载之前就配）

### 为什么必须先配

Flutter 的两个下载源在国内直连**极慢甚至超时**：

| 环境变量 | 控制什么 | 不配的后果 |
|---|---|---|
| `PUB_HOSTED_URL` | Dart/Flutter **包**（`pub get` 拉依赖） | `flutter pub get` 卡住或超时失败 |
| `FLUTTER_STORAGE_BASE_URL` | Flutter **SDK 自身的产物**（引擎二进制、Dart SDK、各平台工具） | 第一次跑 `flutter doctor` 时会下载 Dart SDK，可能卡几十分钟甚至失败 |

**所以顺序很重要：先设镜像环境变量，再第一次运行 `flutter` 命令。** 如果你先跑了 flutter 导致下载失败，配好镜像后需要删掉 `flutter\bin\cache` 目录重新触发下载。

### 怎么配

推荐用**清华大学 TUNA 镜像**（稳定、有 CDN）：

```powershell
# PowerShell —— 永久设置
setx PUB_HOSTED_URL "https://mirrors.tuna.tsinghua.edu.cn/dart-pub"
setx FLUTTER_STORAGE_BASE_URL "https://mirrors.tuna.tsinghua.edu.cn/flutter"
```

备选：上海交大镜像（如果清华的慢，换这个试试）

```powershell
setx PUB_HOSTED_URL "https://mirror.sjtu.edu.cn/dart-pub"
setx FLUTTER_STORAGE_BASE_URL "https://mirror.sjtu.edu.cn/flutter"
```

设完**关掉终端重开**，验证：

```bash
echo "$PUB_HOSTED_URL"
echo "$FLUTTER_STORAGE_BASE_URL"
```

> 💡 **什么时候该取消镜像**：如果以后你有稳定的代理，或者遇到镜像同步滞后导致某个新版本包拉不到，可以临时清掉：
> ```powershell
> setx PUB_HOSTED_URL ""
> setx FLUTTER_STORAGE_BASE_URL ""
> ```

## 2.3 下载并解压 Flutter SDK

**下载地址**（Windows stable 版）：
https://docs.flutter.dev/get-started/install/windows

或者直接从清华镜像下（配了 `FLUTTER_STORAGE_BASE_URL` 之后浏览器下载不受影响，这里给镜像的直链目录）：
https://mirrors.tuna.tsinghua.edu.cn/flutter/flutter_infra_release/releases/

找 `flutter_windows_<版本>-stable.zip`（约 1GB）。

**解压**：

```powershell
# PowerShell —— 假设你把 zip 下载到了 D:\Downloads
New-Item -ItemType Directory -Force -Path "D:\DevTools"

# 解压（会自动生成 D:\DevTools\flutter 目录，zip 内已含 flutter 顶层文件夹）
Expand-Archive -Path "D:\Downloads\flutter_windows_3.x.x-stable.zip" -DestinationPath "D:\DevTools" -Force
```

> ⚠️ 把 `3.x.x` 换成你实际下载到的版本号。也可以直接用资源管理器右键「解压到 D:\DevTools」，效果一样。
> ⚠️ **不要用 Windows 自带的"压缩文件夹"直接拖拽解压超大 zip**，偶发文件损坏。用 7-Zip 或上面的 `Expand-Archive` 更可靠。

验证解压结果：

```bash
ls /d/DevTools/flutter/bin/flutter.bat
# 期望：文件存在
```

## 2.4 把 Flutter 加进 PATH

**图形界面方式（推荐）**：

1. `Win + R` → `sysdm.cpl` → **高级** → **环境变量**
2. 「用户变量」里选 `Path` → **编辑** → **新建**
3. 填入：`D:\DevTools\flutter\bin`
4. 确定，**关掉所有终端重开**

**命令行方式（PowerShell）**：

```powershell
# 🔴 注意：setx 对 PATH 有 1024 字符截断风险，本机 PATH 可能已经很长
# 先看一下当前用户 PATH 有多长
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
$userPath.Length
```

如果长度**接近或超过 1024**，🔴 **不要用 `setx` 改 PATH**，会截断导致其他工具全部失效。改用下面这种 .NET API 方式（无长度限制）：

```powershell
# 安全的追加方式，不走 setx，无截断风险
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
if ($userPath -notlike '*D:\DevTools\flutter\bin*') {
    [Environment]::SetEnvironmentVariable('Path', "D:\DevTools\flutter\bin;$userPath", 'User')
    "已添加 Flutter 到 PATH"
} else {
    "PATH 中已存在，跳过"
}
```

**关掉所有终端重开**，验证：

```bash
which flutter
# 期望：/d/DevTools/flutter/bin/flutter

flutter --version
# 第一次运行会下载 Dart SDK，需要等一会儿（有镜像的话 1-3 分钟）
```

> 💡 **第一次跑 `flutter --version` 会比较久**，因为它要下载并解包 Dart SDK 到 `flutter\bin\cache`。看到进度条是正常的。如果卡住不动超过 5 分钟，检查 §2.2 的镜像是否生效。

## 2.5 关闭 Flutter 匿名统计（可选，但建议）

```bash
flutter config --no-analytics
```

理由：减少不必要的网络请求，国内环境下这些请求经常超时，会让命令变慢。

## 2.6 🟡 关于在哪创建 Flutter 项目（本机特殊情况）

实测 `D:\AndroidStudioProjects\AIMindTree` **当前是一个纯 Kotlin JVM Gradle 项目**：

```
build.gradle          ← kotlin.jvm 2.0.20
settings.gradle
gradlew / gradlew.bat
gradle/wrapper/gradle-wrapper.properties   ← Gradle 8.9
local.properties      ← sdk.dir=C:\Users\ASUS\AppData\Local\Android\Sdk
src/
docs/                 ← PRD.md / ARCHITECTURE.md 在这里
```

🔴 **如果你在这个目录直接跑 `flutter create .`，会和已有的 `build.gradle` / `settings.gradle` / `gradlew` 冲突**，Flutter 生成的 Android 子项目结构会被现有 Gradle 配置干扰，很难排查。

**推荐做法：把 Flutter App 建在子目录，文档留在原地。**

```bash
cd /d/AndroidStudioProjects/AIMindTree

# 建 Flutter 项目到子目录 aimindtree_app
flutter create --org com.aimindtree --project-name aimindtree_app aimindtree_app
```

目录结构会变成：

```
D:\AndroidStudioProjects\AIMindTree\
├── docs\                 ← PRD / ARCHITECTURE / 本文档
├── aimindtree_app\       ← ✅ Flutter 项目在这里
│   ├── lib\
│   ├── android\
│   ├── ios\
│   ├── pubspec.yaml
│   └── ...
├── build.gradle          ← 旧的 Kotlin 项目文件，暂时留着
└── ...
```

> 💡 参数说明：
> - `--org com.aimindtree` 决定 Android 的 `applicationId` 和 iOS 的 Bundle ID 前缀（会生成 `com.aimindtree.aimindtree_app`）。**这个值以后改起来麻烦，一开始就定好。**
> - `--project-name` 必须是**小写 + 下划线**（Dart 包命名规范），不能用中划线或大写。

如果确认旧的 Kotlin 项目文件不再需要，可以清理——但**先确认**：

```bash
# 只读检查：看看 src 里有没有你写过的代码
ls -R /d/AndroidStudioProjects/AIMindTree/src
```

> 🔴 **删除前务必确认**。如果 `src` 里有你的代码，不要删。这个目录不是 git 仓库（实测项目根目录无 `.git`，只有 `.gitignore`），**删了没有版本历史可以恢复**。

## 2.7 第 2 步验收

```bash
flutter --version
dart --version
echo "$PUB_HOSTED_URL"
echo "$FLUTTER_STORAGE_BASE_URL"
echo "$PUB_CACHE"
```

| 检查项 | 期望输出 |
|---|---|
| `flutter --version` | `Flutter 3.x.x • channel stable` + Dart 版本 |
| `dart --version` | `Dart SDK version: 3.x.x`（随 Flutter 附带，不用单独装） |
| `$PUB_HOSTED_URL` | 清华或交大镜像地址 |
| `$PUB_CACHE` | `D:\DevCache\pub-cache` |

---

# 第 3 步 · 对接已有的 Android SDK

## 3.0 好消息：不用重装

> 🔴 **Android Studio 这个 IDE 可能都打不开**：它的内置 JDK（`jbr`）已损坏（实测报 `Error: could not open 'C:\Program Files\Android\Android Studio\jbr\lib\jvm.cfg'`，见 §1.0）。`jbr` 损坏通常意味着 Android Studio 启动时会因找不到 JVM 而失败。
> - 如果你**还能打开** Android Studio：忽略此条，正常用它的 SDK Manager（见 §3.2 方式 A）。
> - 如果你**打不开**：需要重装 / 修复 Android Studio。**建议装到 D 盘**（C 盘虽已缓解，但 D 盘更从容，避免再挤占 C 盘）。重装时选择 "Repair" 或卸载后重装到 `D:\AndroidStudio`。
> - 命令行 / Flutter 构建**不依赖 Android Studio 这个 IDE 本身**，只要 `ANDROID_HOME` 指向的 SDK 目录完整即可（本机 SDK 完好，见下）。

实测本机 Android SDK **已经装好了**，在：

```
C:\Users\ASUS\AppData\Local\Android\Sdk
```

已有组件（实测）：

| 组件 | 已安装版本 | 状态 |
|---|---|---|
| `platforms` | `android-33`、`android-34`、`android-35` | ✅ 够用 |
| `build-tools` | `30.0.3`、`34.0.0`、`35.0.0` | ✅ 够用 |
| `platform-tools`（含 `adb.exe`） | ✅ 存在 | ✅ |
| `emulator` | ✅ 存在 | ✅ |
| `licenses` | `android-sdk-license`、`intel-android-extra-license` | 🟡 部分已接受 |
| **`cmdline-tools`** | 🔴 **目录是空的** | ❌ **必须补装** |

**所以你只需要做两件事：**
1. 设置环境变量指向它（§3.1）
2. 补装空缺的 `cmdline-tools`（§3.2）

> ⚠️ **不要重新下载 Android SDK**。它有好几个 GB，重装纯属浪费 C 盘空间和时间。

## 3.1 设置 ANDROID_HOME / ANDROID_SDK_ROOT

### 为什么两个都要设

历史包袱：Android 工具链早期用 `ANDROID_HOME`，后来官方改推 `ANDROID_SDK_ROOT`，再后来又回到 `ANDROID_HOME`。现实是**不同工具认不同的变量**：

- Flutter / Gradle 主要认 `ANDROID_HOME`
- 部分老版本 `sdkmanager` / `avdmanager` 认 `ANDROID_SDK_ROOT`

**两个都设成同一个值，最省心。**

```powershell
# PowerShell
setx ANDROID_HOME "C:\Users\ASUS\AppData\Local\Android\Sdk"
setx ANDROID_SDK_ROOT "C:\Users\ASUS\AppData\Local\Android\Sdk"
```

### 把 platform-tools 加进 PATH

这样才能在任何目录直接用 `adb` 命令（真机调试必备）。

```powershell
# 用无截断风险的方式追加（同 §2.4）
$sdk = "C:\Users\ASUS\AppData\Local\Android\Sdk"
$add = "$sdk\platform-tools;$sdk\cmdline-tools\latest\bin;$sdk\emulator"
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
if ($userPath -notlike "*$sdk\platform-tools*") {
    [Environment]::SetEnvironmentVariable('Path', "$add;$userPath", 'User')
    "已添加 Android SDK 工具到 PATH"
} else {
    "PATH 中已存在，跳过"
}
```

**关掉所有终端重开**，验证：

```bash
echo "$ANDROID_HOME"
# 期望：C:\Users\ASUS\AppData\Local\Android\Sdk

adb version
# 期望：Android Debug Bridge version 1.0.xx
```

```cmd
:: cmd 里验证的写法（注意百分号）
echo %ANDROID_HOME%
```

```powershell
# PowerShell 里的写法
$env:ANDROID_HOME
```

## 3.2 🔴 补装 cmdline-tools（本机必做）

### 为什么必须装

实测 `C:\Users\ASUS\AppData\Local\Android\Sdk\cmdline-tools` **是个空目录**。后果：

- `flutter doctor` 会报 **`cmdline-tools component is missing`**
- `flutter doctor --android-licenses` **直接跑不起来**（因为 `sdkmanager` 就在 cmdline-tools 里）
- 无法用命令行补装任何 SDK 组件

这是本机**第二大坑**（第一大是磁盘）。

### 方式 A：用 Android Studio 的 SDK Manager（✅ 推荐，最简单）

1. 打开 **Android Studio**
2. 菜单 **Tools → SDK Manager**（或欢迎页 → **More Actions → SDK Manager**）
3. 切到 **SDK Tools** 选项卡
4. 🔴 **勾上右下角的 `Show Package Details`**（关键！不勾看不到具体版本）
5. 找到 **Android SDK Command-line Tools (latest)**，勾选
6. 顺便确认这几个也勾上了：
   - ✅ **Android SDK Build-Tools**（已有 35.0.0，OK）
   - ✅ **Android SDK Platform-Tools**（已有，OK）
   - ✅ **Android SDK Command-line Tools (latest)** ← 本次要装的
7. 点 **Apply → OK**，等下载完成（约 150MB）

安装完验证：

```bash
ls /c/Users/ASUS/AppData/Local/Android/Sdk/cmdline-tools
# 期望：出现 latest 目录（之前是空的）

ls /c/Users/ASUS/AppData/Local/Android/Sdk/cmdline-tools/latest/bin
# 期望：能看到 sdkmanager.bat、avdmanager.bat
```

### 方式 B：手动下载（Android Studio 打不开时的备选）

1. 下载：https://developer.android.com/studio#command-line-tools-only
   选 **Windows** 那个 zip（`commandlinetools-win-*_latest.zip`）
2. 解压后**目录结构必须是这样**（这一步很容易搞错）：

```
C:\Users\ASUS\AppData\Local\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat
                                                      ↑
                                          必须多套一层叫 latest 的目录
```

zip 解压出来是一个叫 `cmdline-tools` 的文件夹，里面直接是 `bin/`、`lib/`。你需要**把它重命名为 `latest`**，再放进 SDK 的 `cmdline-tools` 目录下：

```powershell
# PowerShell —— 假设 zip 解压到了 D:\Downloads\cmdline-tools
$dest = "C:\Users\ASUS\AppData\Local\Android\Sdk\cmdline-tools\latest"
New-Item -ItemType Directory -Force -Path (Split-Path $dest)
Move-Item -Path "D:\Downloads\cmdline-tools" -Destination $dest
```

验证：

```bash
ls /c/Users/ASUS/AppData/Local/Android/Sdk/cmdline-tools/latest/bin/sdkmanager.bat
# 期望：文件存在
```

## 3.3 用 sdkmanager 检查和补装组件

装好 cmdline-tools 后，就可以用命令行管理 SDK 了。

```bash
# 列出已安装的组件（只读，安全）
sdkmanager --list_installed
```

```bash
# 列出所有可装的组件（输出很长，建议管道过滤）
sdkmanager --list | head -50
```

如果 `sdkmanager` 找不到（PATH 没生效），用完整路径：

```bash
/c/Users/ASUS/AppData/Local/Android/Sdk/cmdline-tools/latest/bin/sdkmanager.bat --list_installed
```

**本机已有 platforms 33/34/35 和 build-tools 35.0.0，理论上不需要补装任何东西。** 只有在 `flutter doctor` 明确报缺某个组件时才装，比如：

```bash
# 举例：假设 doctor 说缺 build-tools 33.0.1
sdkmanager "build-tools;33.0.1"

# 举例：补装某个 platform
sdkmanager "platforms;android-34"
```

> 💡 组件名要用**双引号包起来**，因为里面有分号，bash 会把分号当命令分隔符。

## 3.4 接受 Android licenses

### 为什么要做

Google 要求你显式接受 SDK 各组件的许可协议，否则 Gradle 构建时会报：

```
Failed to install the following Android SDK packages as some licences have not been accepted.
```

实测本机 `licenses` 目录只有 2 个文件（`android-sdk-license`、`intel-android-extra-license`），大概率还有没接受的。

```bash
flutter doctor --android-licenses
```

会连续弹出协议文本，**每个都输入 `y` 回车**。可能要按十几次。

> ⚠️ **这条命令必须在 §3.2 装完 cmdline-tools 之后跑**，否则会报 `Android sdkmanager not found`。
> ⚠️ 如果输出乱码，在 PowerShell 里先执行 `chcp 65001` 切到 UTF-8 再跑。

验证：

```bash
ls /c/Users/ASUS/AppData/Local/Android/Sdk/licenses
# 期望：文件变多了（通常会有 android-sdk-license、android-sdk-preview-license 等）
```

## 3.5 告诉 Flutter 你的 Android SDK 在哪（如果它自己没找到）

一般设了 `ANDROID_HOME` 就够了。如果 `flutter doctor` 仍然说找不到 Android SDK：

```bash
flutter config --android-sdk "C:\Users\ASUS\AppData\Local\Android\Sdk"
```

如果 `flutter doctor` 说找不到 Android Studio：

```bash
flutter config --android-studio-dir "C:\Program Files\Android\Android Studio"
```

---

# 第 4 步 · 跑 flutter doctor 并逐项排错

## 4.0 先跑起来

```bash
flutter doctor -v
```

`-v` 参数很重要：它会打印**每一项的详细路径和具体原因**，不加 `-v` 只有一句「✗ 有问题」，根本没法排查。

## 4.1 输出符号怎么读

| 符号 | 含义 | 要不要处理 |
|---|---|---|
| `[✓]` | 完全正常 | 不用管 |
| `[!]` | 有警告，但**通常不阻塞开发** | 看具体内容，部分可忽略 |
| `[✗]` | 有错误，**会阻塞构建** | 🔴 必须修 |

## 4.2 🔴 常见报错对照表（新手最容易卡的地方）

按本机情况，最可能遇到下面这些。**照表对号入座。**

### ① `cmdline-tools component is missing`

```
[!] Android toolchain - develop for Android devices
    ✗ cmdline-tools component is missing
      Run `path/to/sdkmanager --install "cmdline-tools;latest"`
```

| 项 | 内容 |
|---|---|
| **原因** | 本机 `cmdline-tools` 目录是空的（实测确认） |
| **解决** | 回到 **§3.2**，用 Android Studio SDK Manager 装 `Android SDK Command-line Tools (latest)` |
| **优先级** | 🔴 高。不修的话 licenses 也接受不了 |

### ② `Android license status unknown`

```
[!] Android toolchain
    ! Some Android licenses not accepted.
      To resolve this, run: flutter doctor --android-licenses
```

| 项 | 内容 |
|---|---|
| **原因** | 许可协议没全部接受 |
| **解决** | `flutter doctor --android-licenses`，一路按 `y` |
| **前置条件** | 🔴 必须先修好 ①，否则这条命令跑不起来 |
| **优先级** | 🔴 高。会导致 Gradle 构建失败 |

### ③ `Unable to locate Android SDK`

```
[✗] Android toolchain - develop for Android devices
    ✗ Unable to locate Android SDK.
```

| 项 | 内容 |
|---|---|
| **原因** | `ANDROID_HOME` 没设，或者设错了路径 |
| **解决** | 1) 回到 §3.1 设 `ANDROID_HOME`<br>2) **关掉终端重开**（这一步最容易漏）<br>3) 还不行就 `flutter config --android-sdk "C:\Users\ASUS\AppData\Local\Android\Sdk"` |
| **自查** | `echo "$ANDROID_HOME"` 有没有输出？`ls "$ANDROID_HOME/platform-tools/adb.exe"` 文件存在吗？ |

### ④ Java 版本相关错误

```
[!] Android toolchain
    ! Java version 1.8.0_144
      Flutter requires Java 17 or later
```
或构建时报：
```
Unsupported class file major version 61
Android Gradle plugin requires Java 17 to run
```

| 项 | 内容 |
|---|---|
| **原因** | 🔴 **本机最典型问题**：`java` 解析到了 `C:\ProgramData\Oracle\Java\javapath\java`（JDK 8） |
| **解决** | 回到 **§1.3**，把 `%JAVA_HOME%\bin` 移到 PATH 最前，把 `C:\ProgramData\Oracle\Java\javapath` 移到最后或删掉 |
| **自查** | `java -version` 是不是 17.x？`which java` 指向哪？ |
| **额外坑** | 如果你把 `JAVA_HOME` 设成了 `C:\Program Files\Java\jdk-23`，Gradle 8.9 会报 `Unsupported class file major version 67`。**必须用 17**，见 §1.0 |

### ⑤ `Android Studio (not installed)` 或 `Unable to find bundled Java version`

```
[!] Android Studio (version 2024.x)
    ✗ Unable to find bundled Java version.
```

| 项 | 内容 |
|---|---|
| **原因** | 🔴 实测本机 `C:\Program Files\Android\Android Studio\jbr` **已损坏**（缺 `lib\jvm.cfg`） |
| **解决** | 因为我们已经装了独立的 JDK 17 并设了 `JAVA_HOME`，Flutter 会优先用 `JAVA_HOME`，**这条警告可以忽略** |
| **彻底修复（可选）** | 重新安装 / 修复 Android Studio；或从 https://github.com/JetBrains/JetBrainsRuntime 下载对应版本 JBR 覆盖 `jbr` 目录 |
| **优先级** | 🟡 低。只影响 Android Studio 内部构建，命令行 `flutter build` 不受影响 |

### ⑥ `Visual Studio - develop for Windows` 报 ✗

```
[✗] Visual Studio - develop Windows apps
    ✗ Visual Studio not installed
```

| 项 | 内容 |
|---|---|
| **原因** | 没装 Visual Studio 的 C++ 桌面开发工作负载 |
| **要不要修** | ⬜ **AIMindTree 初期不需要**。这只影响**编译 Windows 桌面版**。你要先做 Android + Web |
| **将来要做 Windows 桌面版时** | 装 Visual Studio 2022 Community，勾选 **"使用 C++ 的桌面开发"** 工作负载（约 8GB，🔴 注意 C 盘空间） |
| **优先级** | ⬜ 可忽略 |

### ⑦ `Chrome - develop for the web` 报 ✗

| 项 | 内容 |
|---|---|
| **原因** | Flutter 找不到 Chrome |
| **解决** | 装 Chrome；或者如果你用 Edge：`setx CHROME_EXECUTABLE "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"` |
| **优先级** | 🟡 中。AIMindTree 要做 Web 端，最终需要，但可以晚点修 |

### ⑧ `No devices available`

| 项 | 内容 |
|---|---|
| **原因** | 没连真机、没开模拟器 |
| **解决（真机，推荐）** | 1) 手机开**开发者选项** → 打开 **USB 调试**<br>2) USB 连电脑，手机弹窗点「允许」<br>3) `adb devices` 应该看到设备 |
| **解决（模拟器）** | `flutter emulators` 列出可用的，`flutter emulators --launch <id>` 启动 |
| **优先级** | 🟡 到要跑 App 时才需要 |

### ⑨ 网络类错误：卡在下载 / `SocketException` / 超时

| 项 | 内容 |
|---|---|
| **原因** | 镜像没配好，直连 Google 源 |
| **解决** | 1) 检查 `echo "$PUB_HOSTED_URL"` 和 `echo "$FLUTTER_STORAGE_BASE_URL"` 有没有值<br>2) 没值 → 回 §2.2<br>3) 有值但还是慢 → 换交大镜像<br>4) 如果之前下载失败留了残缺缓存：删掉 `D:\DevTools\flutter\bin\cache` 目录，重新跑 `flutter doctor` 会重下 |
| **优先级** | 🔴 高 |

## 4.3 第 4 步的验收标准

**不要求全绿。** 对 AIMindTree 初期开发，可接受的状态是：

```
[✓] Flutter (Channel stable, 3.x.x, on Microsoft Windows ...)
[✓] Windows Version
[✓] Android toolchain - develop for Android devices (Android SDK version 35.0.0)
[!] Android Studio (version 2024.x)          ← 可接受（jbr 损坏，见 ⑤）
[✗] Visual Studio - develop Windows apps     ← 可接受（暂不做 Windows 桌面）
[!] Chrome - develop for the web             ← 建议修，做 Web 端要用
[✓] Connected device (1 available)           ← 接了真机才有
[✓] Network resources
```

🔴 **必须是 `[✓]` 的两项**：
1. `Flutter` 本身
2. **`Android toolchain`** ← 这一项如果不是 ✓，Android 构建一定失败

---

# 第 5 步 · 启动 Docker Desktop

## 5.0 🔴 重要：这一步命令行解决不了

实测本机状态：

```bash
docker --version
# Docker version 29.7.2, build a7dcaa6   ← 客户端在

docker info
# error during connect: ... open //./pipe/dockerDesktopLinuxEngine:
# The system cannot find the file specified.
#                                      ↑ 守护进程没跑
```

**这个报错的含义**：Docker 分成「客户端 `docker` 命令」和「守护进程 Docker Engine」两部分。客户端装好了，但守护进程没运行，所以连不上那个命名管道（named pipe）。

🔴 **在 Windows 上，Docker Engine 是由 Docker Desktop 这个 GUI 应用托管的。你必须手动启动 Docker Desktop 应用，没有纯命令行的启动方式。** 这不是缺个参数的问题，是架构决定的。

## 5.1 怎么启动

**方式 A：从开始菜单（最直接）**

按 `Win` 键 → 输入 `Docker Desktop` → 回车。

**方式 B：双击可执行文件**

实测路径确认存在：

```
C:\Program Files\Docker\Docker\Docker Desktop.exe
```

**方式 C：PowerShell 拉起 GUI**

```powershell
Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"
```

> 💡 想让它开机自启：Docker Desktop → **Settings → General** → 勾选 **Start Docker Desktop when you sign in**。
> 🟡 但注意：Docker Desktop 常驻会**吃掉 2–4GB 内存**。如果你机器内存紧张，建议**不开自启**，要用 Dify 时手动启。

## 5.2 等它真正就绪（不要急着跑命令）

启动后**不是立刻可用**。判断标准：

1. 右下角系统托盘的**鲸鱼图标停止动画**，变成稳定状态
2. Docker Desktop 窗口左下角显示绿色的 **Engine running**

然后才验证：

```bash
docker info
```

**期望输出**（关键几行）：

```
Client:
 Version:    29.7.2
Server:
 Server Version: ...
 Storage Driver: overlayfs
 Operating System: Docker Desktop
 Total Memory: ...GiB          ← 记下这个数字，§6.6 要用
```

🔴 **只要 `docker info` 还在报 `open //./pipe/... The system cannot find the file specified`，就说明没就绪，不要往下走。**

## 5.3 WSL2 后端注意事项

Docker Desktop 在 Windows 上默认用 **WSL2 后端**（跑一个轻量 Linux 虚拟机来托管容器）。相关注意点：

| 注意点 | 说明 |
|---|---|
| **必须启用 WSL2 和虚拟化** | 如果 Docker Desktop 启动时报 "WSL 2 installation is incomplete"，用管理员 PowerShell 跑 `wsl --update`，然后重启电脑 |
| **BIOS 虚拟化要开** | 报 "Virtualization is not enabled" → 进 BIOS 打开 `Intel VT-x` / `AMD-V` |
| 🔴 **内存会被 WSL2 吃掉** | WSL2 默认可能占用宿主机**一半以上的内存**。见下面的 `.wslconfig` |
| **磁盘只增不减** | vhdx 文件不会自动缩小，见 §0.2 |
| **和 VMware/VirtualBox 冲突** | 老版本 VMware 与 Hyper-V/WSL2 不兼容。如果你装了，可能需要二选一 |

### 限制 WSL2 内存占用（强烈建议做）

在你的用户目录建一个 `.wslconfig` 文件：

```powershell
# PowerShell —— 注意文件名前面有个点，且没有扩展名
@"
[wsl2]
memory=6GB
processors=4
swap=2GB
"@ | Out-File -FilePath "$env:USERPROFILE\.wslconfig" -Encoding ascii -Force
```

**参数怎么定**（本机总内存未知，请先自己查）：

```powershell
# 查本机总内存
"{0:N1} GB" -f ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB)
```

| 你的总内存 | `memory` 建议 | `processors` 建议 | 说明 |
|---|---|---|---|
| 8 GB | `4GB` | `2` | 🔴 跑 Dify 会很吃力，见 §6.6 优化 |
| 16 GB | `6GB` | `4` | ✅ 推荐配置，能舒服跑 Dify |
| 32 GB+ | `12GB` | `6` | 很宽裕 |

改完后必须重启 WSL 才生效（在 PowerShell 里跑）：

```powershell
wsl --shutdown
```

然后重新启动 Docker Desktop。

> ⚠️ `wsl --shutdown` 会**关闭所有 WSL 发行版和正在运行的容器**。如果你有正在跑的容器，先 `docker-compose stop`。

## 5.4 第 5 步验收

```bash
docker info
docker ps
docker-compose --version
```

| 检查项 | 期望输出 |
|---|---|
| `docker info` | 有 `Server:` 段落，能看到 `Server Version` |
| `docker ps` | 输出表头 `CONTAINER ID   IMAGE ...`（没有容器是正常的） |
| `docker-compose --version` | `Docker Compose version v5.3.1` |

🔴 **本机 Compose 用法特别提醒**（实测）：

```bash
docker-compose up -d    # ✅ 本机可用（带短横线）
docker compose up -d    # ❌ 本机报 unknown command（空格形式不可用）
```

**本文档后面所有命令都用 `docker-compose`。** 你在网上看到的 Dify 教程大多写 `docker compose`（新版官方推荐写法），在这台机器上**要自己换成 `docker-compose`**。

---

# 第 6 步 · 本地部署 Dify

## 6.0 先看清楚要付出什么

| 资源 | 需求 |
|---|---|
| **磁盘** | 🔴 首次拉镜像 **10–20 GB**；运行后数据卷持续增长 |
| **内存（最低）** | 8 GB 可勉强跑（需按 §6.6 优化），体验较差 |
| **内存（推荐）** | **16 GB 以上** |
| **CPU（最低）** | 2 核 |
| **CPU（推荐）** | 4 核以上 |
| **首次启动耗时** | 🔴 **10–30 分钟**（取决于网速，要拉 9+ 个镜像） |

🔴 **在开始前，再确认一次 C 盘空间**（如果你还没做 §0.2 的迁移，现在回去做）：

```bash
df -h
```

## 6.1 🟡 好消息：Dify 源码已经在 D 盘了

实测发现 **`D:\dify` 已经存在**，而且：

| 检查项 | 实测结果 |
|---|---|
| 目录 | ✅ `D:\dify` 存在，内容完整（有 `docker/`、`README.md`、`Makefile` 等） |
| `docker/.env` | ✅ **已经存在**（32660 字节，和 `.env.example` 同样大小，说明是完好的拷贝） |
| Dify 版本 | `langgenius/dify-api:1.0.1`（2025-03 左右的版本） |
| 向量库配置 | `VECTOR_STORE=weaviate` |
| nginx 端口 | `EXPOSE_NGINX_PORT=80` ← 🔴 有冲突，见 §6.4 |
| `docker/volumes` | 只有 19K，说明**从未启动过** |
| 🔴 **是否 git 仓库** | ❌ **不是**。`git log` 报错，说明是下载 zip 解压的 |

**所以你不需要重新 clone。** 直接跳到 §6.3。

### 如果你想重新 clone（可选）

`D:\dify` 不是 git 仓库意味着**以后无法用 `git pull` 升级 Dify**。如果你在意这点，可以重新 clone 一份：

```bash
# 建议 clone 到 D 盘，绝对不要放 C 盘（C 盘只剩 23G）
cd /d
git clone https://github.com/langgenius/dify.git dify-git

# 可选：切到指定稳定版 tag，避免 main 分支不稳定
cd /d/dify-git
git tag | tail -20        # 看最近的版本 tag
git checkout 1.0.1        # 或换成你想要的版本
```

> ⚠️ **不要直接 `git clone` 到已存在的 `D:\dify`**，git 会拒绝（目录非空）。用不同的目录名。
> ⚠️ Dify 仓库不小（几百 MB），网络慢的话加 `--depth 1` 只拉最新一次提交：
> ```bash
> git clone --depth 1 https://github.com/langgenius/dify.git dify-git
> ```

## 6.2 为什么必须在 D 盘

| 原因 | 说明 |
|---|---|
| 源码本身几百 MB | 小事 |
| 🔴 **`docker/volumes` 目录会长很大** | Dify 用**相对路径绑定挂载**（`./volumes/...`），postgres 数据、上传的文件、weaviate 索引全在这里。跑一段时间几个 GB 很正常 |
| C 盘只剩 23GB | 不解释 |

好消息是 `D:\dify` 已经满足这个要求了。

## 6.3 确认 .env 文件

### 为什么需要 .env

Dify 的 `docker-compose.yaml` 里大量配置（数据库密码、密钥、端口、向量库类型…）都从 `.env` 读取。**没有 `.env` 文件，容器起不来。**

实测 `D:\dify\docker\.env` **已经存在**，先确认一下：

```bash
ls -la /d/dify/docker/.env /d/dify/docker/.env.example
# 实测：两个文件都是 32660 字节，说明 .env 是 .env.example 的完整拷贝
```

**如果你的 `.env` 不见了或想重建**，复制命令三种 shell 的写法都给：

```bash
# Git Bash
cd /d/dify/docker
cp .env.example .env
```

```powershell
# PowerShell
Set-Location "D:\dify\docker"
Copy-Item .env.example .env
```

```cmd
:: cmd
cd /d D:\dify\docker
copy .env.example .env
```

> ⚠️ **不要用 `mv` / `Move-Item`**，那会把 `.env.example` 弄没了，以后想重置就没有模板了。用 **复制**。
> ⚠️ Git Bash 里 `cp .env.example .env` 完全正常。有些教程写 `cp -n`（不覆盖已有文件），如果你的 `.env` 已经改过配置，用 `-n` 更安全。

## 6.4 🔴 关键：必须改端口（本机 80 端口被占）

### 问题

实测本机 80 端口已被占用：

```bash
netstat -ano | grep '0.0.0.0:80 '
# TCP    0.0.0.0:80    0.0.0.0:0    LISTENING    4
#                                                ↑ PID 4 = Windows System 进程
```

**PID 4 是 Windows 的 `System` 进程**，通常意味着 `http.sys` 内核驱动占用了 80 端口（可能来自 IIS、World Wide Web Publishing 服务、SQL Server Reporting Services、或某些开发工具）。

🔴 **Dify 的 nginx 默认要绑 80 端口，直接 `up -d` 会失败**，报错类似：

```
Error response from daemon: Ports are not available:
exposing port TCP 0.0.0.0:80 -> 127.0.0.1:0: listen tcp 0.0.0.0:80: bind: ...
```

### 解决：改用 8080

实测 `8080` / `3000` / `5001` / `8888` **全部空闲**。我们用 `8080`。

编辑 `D:\dify\docker\.env`，找到这两行（实测**精确在第 917、918 行**）：

```properties
EXPOSE_NGINX_PORT=80
EXPOSE_NGINX_SSL_PORT=443
```

改成：

```properties
EXPOSE_NGINX_PORT=8080
EXPOSE_NGINX_SSL_PORT=8443
```

用编辑器改（推荐，改完自己核对一眼）：

```powershell
# 用 VS Code 打开
code D:\dify\docker\.env

# 或者记事本
notepad D:\dify\docker\.env
```

改完**务必确认**：

```bash
grep -nE '^EXPOSE_NGINX_PORT=|^EXPOSE_NGINX_SSL_PORT=' /d/dify/docker/.env
# 期望（注意是精确行号）：
# 917:EXPOSE_NGINX_PORT=8080
# 918:EXPOSE_NGINX_SSL_PORT=8443
```

> 🔴 **关键：改完 `.env` 后必须「重建容器」才能生效，单纯 `restart` 不够！**
> Docker Compose 的 `.env` 文件**只在创建（create）容器那一刻被读取**，之后容器里写死的是当时解析出的环境变量。所以：
> - `docker-compose restart` / `docker restart` → ❌ 只读已有容器的配置，**不会重新读 `.env`**，端口还是旧的 80。
> - 必须让 Compose **重新创建容器**，新端口才进得去。
>
> 在 **`D:\dify\docker\`** 目录下执行（实测该目录含 `docker-compose.yaml` / `docker-compose.middleware.yaml` / `middleware.env.example` 等，命令必须在此目录跑）：
>
> ```bash
> cd /d/dify/docker
>
> # 方式一：先 down 再 up（会停掉并删除旧容器，重新按新 .env 创建）
> docker-compose down
> docker-compose up -d
>
> # 方式二：原地强制重建（更省事，等价于重建受影响的容器）
> docker-compose up -d --force-recreate
> ```
>
> 重建后验证 nginx 确实监听在 8080：
> ```bash
> docker-compose ps
> # 看 nginx 服务对应的 PORTS 列，应该是 0.0.0.0:8080->80/tcp
> ```

### 顺便检查还有没有其他 URL 需要改

`.env` 里有几个 `*_URL` 配置项控制 Dify 前端生成的链接。**如果留空，Dify 会自动用你浏览器访问的地址，通常不用改。** 但如果改了端口后前端出现"接口 404 / 跨域"问题，检查这几项：

```bash
grep -nE '^CONSOLE_API_URL=|^CONSOLE_WEB_URL=|^SERVICE_API_URL=|^APP_API_URL=|^APP_WEB_URL=|^FILES_URL=' /d/dify/docker/.env
```

- 如果它们都是**空值**（`XXX=`）→ ✅ 保持空值，Dify 会自动推断
- 如果有值且写了 `http://localhost` → 改成 `http://localhost:8080`

### （可选）想查 80 端口到底被谁占了

```powershell
# PowerShell —— 查 PID 4 是什么
Get-Process -Id 4 | Select-Object Id, ProcessName, Path

# 查所有监听端口和对应进程
Get-NetTCPConnection -State Listen -LocalPort 80 |
  Select-Object LocalAddress, LocalPort, OwningProcess
```

> 💡 **不建议为了 Dify 去关掉占用 80 端口的系统服务**。改 Dify 的端口是零风险的做法，而动系统服务可能影响其他东西。

## 6.5 启动 Dify

### 前置确认（三个都要 ✅）

```bash
# 1) Docker 守护进程在跑？
docker info | head -5

# 2) D 盘还有空间？（C 盘已迁移缓解；🔴 D 盘偏紧，剩余 < 50G 先清理再继续，见 §0.6）
df -h

# 3) 端口改好了？
grep -n '^EXPOSE_NGINX_PORT=' /d/dify/docker/.env
```

### 启动

```bash
cd /d/dify/docker

# 🔴 本机必须用 docker-compose（带短横线），docker compose 不可用
docker-compose up -d
```

```powershell
# PowerShell 版本
Set-Location "D:\dify\docker"
docker-compose up -d
```

**`-d` 参数的含义**：detached，后台运行。不加 `-d` 的话所有容器日志会刷在当前终端，关掉终端容器就停了。

### 🔴 第一次启动会发生什么（请有心理准备）

```
[+] Running 0/9
 ⠿ redis Pulling                    ...
 ⠿ db Pulling                       ...
 ⠿ api Pulling                      ...
 ⠿ worker Pulling                   ...
 ⠿ web Pulling                      ...
 ⠿ sandbox Pulling                  ...
 ⠿ plugin_daemon Pulling            ...
 ⠿ weaviate Pulling                 ...
 ⠿ nginx Pulling                    ...
 ⠿ ssrf_proxy Pulling               ...
```

要拉的镜像清单（实测从本机 `docker-compose.yaml` 读出）：

| 镜像 | 作用 | 大致体积 |
|---|---|---|
| `langgenius/dify-api:1.0.1` | 后端 API（api + worker 共用同一镜像） | 大（~2–3 GB） |
| `langgenius/dify-web:1.0.1` | 前端 | 中（~1 GB） |
| `postgres:15-alpine` | 主数据库 | 小（~250 MB） |
| `redis:6-alpine` | 缓存 / 队列 | 小（~40 MB） |
| `langgenius/dify-sandbox:0.2.10` | 代码执行沙箱 | 中 |
| `langgenius/dify-plugin-daemon:0.0.4-local` | 插件守护进程 | 中 |
| `semitechnologies/weaviate:1.19.0` | 🔴 向量数据库（吃内存大户） | 中 |
| `nginx:latest` | 反向代理 | 小（~200 MB） |
| `ubuntu/squid:latest` | SSRF 防护代理 | 小 |

**合计 10–20 GB，耗时 10–30 分钟。**

> ⏳ **耐心**。这一步很慢，但只有第一次慢。
> 🔴 **中途不要 Ctrl+C**。中断会留下不完整的镜像层，既占空间又要手动清。真要中断，之后跑 `docker-compose down` 收尾。
> 💡 如果拉镜像特别慢或超时，考虑给 Docker 配国内镜像加速：Docker Desktop → **Settings → Docker Engine**，在 JSON 里加 `"registry-mirrors": ["https://docker.m.daocloud.io"]`，然后 **Apply & restart**。

## 6.6 🔴 内存优化（内存 < 16GB 必看）

### 问题在哪

Dify 默认带 **weaviate 向量数据库**（实测 `VECTOR_STORE=weaviate`）。weaviate 是 Java/Go 系的独立服务，**空载就要吃 1–2GB 内存**，加上 postgres、redis、api、worker、web、sandbox、plugin_daemon、nginx、ssrf_proxy，**整套跑起来 6–8GB 内存很常见**。

先查你的内存：

```powershell
"{0:N1} GB" -f ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB)
```

```bash
# 看 Docker 能用多少内存
docker info | grep -i "total memory"
```

### 优化 A：把 weaviate 换成 pgvector（✅ 最有效）

**思路**：pgvector 是 PostgreSQL 的向量扩展。Dify 反正已经要跑一个 postgres，用 pgvector 就**少一个独立容器、少 1–2GB 内存**。

改 `.env`（实测本机在第 387 行）：

```properties
# 原来
VECTOR_STORE=weaviate

# 改成
VECTOR_STORE=pgvector
```

**为什么只改这一行就够？** Dify 的 compose 用了 Docker Compose 的 **profiles 机制**——每个向量库容器都挂了自己的 profile（实测 `docker-compose.yaml` 里能看到 `profiles: [weaviate]`、`profiles: [qdrant]`、`profiles: [pgvector]` 等），而 `.env` 里的 `COMPOSE_PROFILES` 会跟随 `VECTOR_STORE` 的值。所以改了 `VECTOR_STORE`，就只会启动对应的那个向量库容器。

改完确认：

```bash
grep -nE '^VECTOR_STORE=|^COMPOSE_PROFILES=' /d/dify/docker/.env
```

> 🔴 **如果你已经启动过 Dify 并且导入了知识库数据，切换向量库会导致已有的向量索引失效**（数据还在 postgres 里，但需要重新索引）。**建议在第一次启动之前就决定用哪个。**
> 💡 对 AIMindTree 的 T1「知识点提取」任务来说，如果你只用 Dify 跑 LLM 工作流、**不用它的知识库检索功能**，那么向量库用哪个其实不重要，选最省资源的 pgvector 就好。

### 优化 B：给容器加内存上限

如果不想动向量库，可以限制各容器的内存。在 `D:\dify\docker` 下新建一个 **override 文件**（不改原始 compose，升级时不冲突）：

```yaml
# D:\dify\docker\docker-compose.override.yaml
services:
  weaviate:
    deploy:
      resources:
        limits:
          memory: 1g
  db:
    deploy:
      resources:
        limits:
          memory: 1g
  api:
    deploy:
      resources:
        limits:
          memory: 2g
  worker:
    deploy:
      resources:
        limits:
          memory: 2g
  web:
    deploy:
      resources:
        limits:
          memory: 512m
```

Compose 会**自动读取** `docker-compose.override.yaml`，不需要额外参数。

> ⚠️ 内存限制设太小会导致容器被 OOM Kill（表现为容器反复重启）。如果 `docker-compose ps` 看到某个容器状态在 `Restarting` 之间跳，把它的 limit 调大。

### 优化 C：不用的组件不要启动

Dify 的 compose 里有一大堆**可选组件**（实测有 qdrant、couchbase、milvus、opensearch、elasticsearch、kibana、oracle、oceanbase、myscale、tidb、certbot、unstructured 等）。它们都挂了 profile，**默认不会启动**——所以你不用管，profiles 机制已经帮你隔离了。

**不要手动 `docker-compose up` 加一堆 profile 参数**，除非你明确知道自己要什么。

### 优化 D：限制 WSL2 总内存

见 §5.3 的 `.wslconfig`。这是从外层兜底，防止 Docker 把整机内存吃光导致 Windows 卡死。

## 6.7 验证启动结果

```bash
cd /d/dify/docker
docker-compose ps
```

**期望输出**：所有容器 `STATUS` 都是 `Up`（healthcheck 的可能显示 `Up (healthy)`）。

```
NAME                  IMAGE                                   STATUS          PORTS
docker-api-1          langgenius/dify-api:1.0.1               Up              5001/tcp
docker-db-1           postgres:15-alpine                      Up (healthy)    5432/tcp
docker-nginx-1        nginx:latest                            Up              0.0.0.0:8080->80/tcp
docker-plugin_daemon-1 langgenius/dify-plugin-daemon:0.0.4-local Up
docker-redis-1        redis:6-alpine                          Up (healthy)    6379/tcp
docker-sandbox-1      langgenius/dify-sandbox:0.2.10          Up
docker-ssrf_proxy-1   ubuntu/squid:latest                     Up
docker-weaviate-1     semitechnologies/weaviate:1.19.0        Up
docker-web-1          langgenius/dify-web:1.0.1               Up
docker-worker-1       langgenius/dify-api:1.0.1               Up
```

🔴 **重点看两件事**：
1. `nginx` 的 PORTS 是 **`0.0.0.0:8080->80/tcp`**（说明端口改对了）
2. 没有容器处于 `Exited` 或 `Restarting`

### 如果有容器没起来

```bash
# 看某个容器的日志（最后 100 行）
docker-compose logs --tail=100 api
docker-compose logs --tail=100 db
docker-compose logs --tail=100 nginx

# 实时跟踪日志
docker-compose logs -f api
```

| 症状 | 常见原因 | 处理 |
|---|---|---|
| `nginx` Exited，日志有 `bind: address already in use` | 端口还是被占 | 回到 §6.4 确认 `.env` 改了，然后 `docker-compose up -d` 重来 |
| `db` 一直 `starting` | 磁盘满 或 数据卷权限问题 | `df -h` 查空间；看 `docker-compose logs db` |
| `api` 反复 `Restarting` | 连不上 db/redis，或内存不足被 OOM | 先确认 db 是 `Up (healthy)`；再看内存限制是否设太小 |
| 全部 Exited，报 no space left on device | 🔴 **磁盘满了** | 回到 §0.2 |

## 6.8 初始化管理员账号

**因为改了端口，访问地址是 8080（不是默认的 80）**：

```
http://localhost:8080/install
```

如果这个地址 404 或跳转，试：

```
http://localhost:8080
```

Dify 会自动引导到安装页。填写：

| 字段 | 说明 |
|---|---|
| **邮箱** | 随便填一个你记得住的，比如 `admin@aimindtree.local`。**本地部署不会真的发邮件** |
| **用户名** | 自定 |
| **密码** | 🔴 **一定要记住**。本地 Dify 没有邮件找回功能，忘了只能进数据库改 |

设置完会跳到登录页，用刚设的账号登录。

> ⚠️ **`/install` 页面只能用一次**。初始化完成后再访问会提示已初始化。

## 6.9 日常运维命令

```bash
cd /d/dify/docker
```

### 安全的命令（不会丢数据）

```bash
# 查看状态
docker-compose ps

# 停止所有容器（数据保留，下次 up 继续）
docker-compose stop

# 启动已停止的容器
docker-compose start

# 重启
docker-compose restart

# 重启单个服务
docker-compose restart api

# 停止并删除容器（🟡 数据卷保留，数据不丢）
docker-compose down

# 重新创建并启动
docker-compose up -d

# 改了 .env 后需要重建容器才生效
docker-compose up -d --force-recreate

# 看日志
docker-compose logs -f --tail=100 api

# 看资源占用（实时，Ctrl+C 退出）
docker stats
```

### 🔴🔴🔴 危险命令 —— 会永久删除数据

```bash
# 🔴🔴🔴 危险！！！
# -v 参数会删除所有数据卷：
#   → 你在 Dify 里建的所有应用、工作流、API Key 全部消失
#   → 上传的所有文档、知识库全部消失
#   → 管理员账号消失，需要重新走 /install
#   → 不可恢复，没有回收站，没有撤销
#
# 只有在你确实想「彻底重装 Dify」时才用这条命令
#
# docker-compose down -v
```

> 🔴 **请注意上面那条命令我故意注释掉了。** 如果你真的要执行，请自己去掉 `#`，并且**在执行前默念一遍：我的所有 Dify 数据都会消失**。
>
> **更安全的替代方案**：如果只是想重置某个应用，在 Dify 界面里删掉那个应用就行，不需要动数据卷。

```bash
# 🔴 危险：删除所有未使用的 Docker 资源（镜像/容器/网络/数据卷）
# 会影响本机其他 Docker 项目，不只是 Dify
# docker system prune -a --volumes
```

```bash
# 🔴 危险：递归强制删除，Windows 上误删系统目录后果严重
# rm -rf 任何路径   ← 执行前一定先用 ls 确认路径对不对
```

### 数据在哪（备份用）

```bash
# Dify 的持久化数据都在这里（绑定挂载，就在 D 盘）
ls /d/dify/docker/volumes
du -sh /d/dify/docker/volumes
```

**备份方法**（先停容器保证数据一致）：

```bash
cd /d/dify/docker
docker-compose stop
```

```powershell
# PowerShell 打包备份
Compress-Archive -Path "D:\dify\docker\volumes" `
  -DestinationPath "D:\Backups\dify-volumes-$(Get-Date -Format yyyyMMdd).zip"
```

```bash
# 恢复运行
docker-compose start
```

---

# 第 7 步 · 在 Dify 创建「知识点提取」工作流

这一步对应 AIMindTree 的核心 AI 任务 **T1：知识点提取**。目标是跑通「输入一段笔记文本 → 输出结构化知识点」的链路，并拿到 App 能调用的 API Key。

## 7.0 先配置模型供应商（不配这一步后面全都跑不了）

### 为什么

Dify 本身**不含大模型**，它是编排层。你必须先告诉它用哪个模型。

**操作路径**：登录 Dify → 右上角**头像** → **设置** → **模型供应商**

**选一个配置**：

| 供应商 | 适合场景 | 需要什么 |
|---|---|---|
| **通义千问 / DeepSeek / 智谱 GLM** | ✅ 国内推荐，无需代理，有免费额度 | 去官网注册拿 API Key |
| **OpenAI** | 效果好 | 需要代理 + 付费 Key |
| **Ollama（本地模型）** | 完全离线、免费 | 🔴 需额外装 Ollama + 下模型（模型文件 4–40GB，**注意磁盘**） |

> 💡 **给 AIMindTree 的建议**：先用 **DeepSeek** 或 **通义千问**。它们的中文能力对「知识点提取」这种任务够用，价格便宜，注册即用，不用折腾代理。等链路跑通了再考虑换模型。
> 🔴 **不建议现在上 Ollama 本地模型**：C 盘只剩 23GB，模型文件动辄十几 GB，风险太大。

配好后确认：**设置 → 模型供应商** 里该供应商显示为已配置，并且在**系统模型设置**里指定了默认的推理模型。

## 7.1 创建应用：选 Workflow 还是 Chatflow / 文本生成？

Dify 有几种应用类型，**API 端点不同，选错了后面 curl 会调不通**：

| 应用类型 | 适用场景 | API 端点 | 对 AIMindTree 的建议 |
|---|---|---|---|
| **工作流 Workflow** | 单次输入 → 单次输出的**批处理任务**，可编排多节点 | `POST /v1/workflows/run` | ✅ **推荐**。知识点提取正是"给一段文本，返回结构化结果"，没有多轮对话需求 |
| **聊天助手 Chatbot** | 多轮对话 | `POST /v1/chat-messages` | ⬜ 不合适 |
| **Chatflow** | 带编排的多轮对话 | `POST /v1/chat-messages` | ⬜ 不合适 |
| **文本生成 Completion** | 简单的单次文本生成，不能编排 | `POST /v1/completion-messages` | 🟡 能用但功能弱，不如 Workflow |
| **Agent** | 需要自主调工具 | `POST /v1/chat-messages` | ⬜ 现阶段不需要 |

**结论：选「工作流 / Workflow」。**

### 创建步骤

1. Dify 首页 → **创建空白应用**
2. 类型选 **工作流（Workflow）**
3. 应用名称：`AIMindTree-知识点提取`
4. 点 **创建**

## 7.2 编排最小可用工作流

进入工作流编辑器后，画布上默认有 **开始（Start）** 节点。

### ① 配置 Start 节点的输入变量

点 **开始** 节点 → 在右侧 **输入字段** 区域点 **+**：

| 变量名 | 类型 | 说明 | 必填 |
|---|---|---|---|
| `note_text` | **段落（Paragraph）** | 用户的笔记原文 | ✅ 是 |

> 🔴 **变量名要记牢**：后面 curl 调用时，`inputs` 里的 key **必须和这里完全一致**（`note_text`）。写错了会报 `input is required`。
> 💡 类型选「段落」而不是「短文本」，因为笔记可能很长，短文本有长度限制。

### ② 加 LLM 节点

1. 点 Start 节点右侧的 **+** → 选 **LLM**
2. **模型**：选你在 §7.0 配好的模型
3. **上下文/提示词**：在 SYSTEM 或 USER 提示词里写抽取指令，用 `/` 或 `{{}}` 插入变量 `note_text`

参考提示词（可以直接复制）：

```
你是一个知识点提取助手。请从用户提供的笔记文本中提取核心知识点。

要求：
1. 每个知识点独立成条，不要合并多个概念
2. 每条包含：知识点名称、一句话解释、所属学科领域
3. 严格按下面的 JSON 格式输出，不要输出任何额外说明文字、不要用 markdown 代码块包裹

输出格式：
{
  "points": [
    {
      "name": "知识点名称",
      "explanation": "一句话解释",
      "domain": "所属领域"
    }
  ]
}

笔记原文：
{{#context#}}
```

> 💡 在 Dify 编辑器里，输入 `/` 会弹出变量选择器，选 `开始 / note_text` 即可插入正确的变量引用。**不要手写 `{{note_text}}`**，容易写错命名空间。

### ③ 加 End 节点

1. 点 LLM 节点右侧 **+** → 选 **结束（End）**
2. 在 **输出变量** 里 **+** 添加：
   - 变量名：`result`
   - 值：选择 **LLM 节点 → text**

> 🔴 **必须有 End 节点并配置输出变量**，否则 API 调用返回的 `outputs` 会是空的。这是新手常忘的一步。

### ④ 测试

右上角 **预览 / 运行** → 在 `note_text` 里粘一段测试文本，比如：

```
傅里叶变换可以把时域信号分解为不同频率的正弦波叠加。卷积定理指出，
时域的卷积等于频域的乘积，这个性质让滤波器设计变得非常方便。
```

确认能返回 JSON 结构的知识点列表。**在界面里跑通了，再去搞 API。** 界面里跑不通的话，API 也一定跑不通，而界面的报错信息更直观。

### ⑤ 发布

🔴 **右上角点「发布」→「更新发布」。**

**这一步绝对不能漏。** Dify 的 API 调用的是**已发布版本**，不是你在编辑器里的草稿。没发布就调 API，会报应用未发布或者调到旧版本。

## 7.3 获取 App API Key

### 关键概念：API Key 是「按应用」签发的

🔴 **这一点很重要**：Dify 的 API Key **不是账号级别的全局 Key，而是每个应用单独签发**。

含义：
- 你为「知识点提取」应用签发的 Key，**只能调用这一个应用**
- 以后 AIMindTree 如果还要做「T2 摘要生成」「T3 出题」等其他 AI 任务，**每个应用要单独建、单独签 Key**
- 换句话说，客户端代码里要按任务类型保存**多个 Key**

> 💡 **架构提示**：这意味着 AIMindTree 的 AI 配置层需要设计成 `Map<任务类型, {endpoint, apiKey}>` 的结构，而不是单一的全局 Key。这一点建议同步给架构设计。

### 获取步骤

1. 在应用内，左侧菜单点 **访问 API**（英文界面是 **API Access**）
2. 页面顶部能看到 **API 服务器地址**（Base URL）
3. 右上角点 **API 密钥** → **创建密钥**
4. 复制出来的 Key，格式是 `app-xxxxxxxxxxxxxxxxxxxxxxxx`

🔴 **Key 只在创建时完整显示一次**（后面只显示前后几位）。**立刻复制保存**。丢了就删掉重新建一个。

> 🔴 **安全提醒**：这个 Key 相当于调用你 Dify 应用的密码。
> - **不要**提交到 git（写进 `.gitignore` 覆盖的配置文件，或用环境变量）
> - **不要**硬编码在 Flutter 客户端代码里 —— 客户端 APK 可以被反编译，Key 会泄露。生产环境应该由你自己的后端代理转发。
> - 本地开发阶段可以先直连，但**上线前必须改掉**。

## 7.4 端点地址（本机实测值）

### Base URL

Dify 界面上显示的 API 地址通常是 `http://localhost/v1`（因为它默认按 80 端口生成）。🔴 **本机改了端口，所以实际要用**：

```
http://localhost:8080/v1
```

### 各类型应用的端点对照

| 应用类型 | 完整端点 | 请求体关键字段 |
|---|---|---|
| **工作流 Workflow** | `POST http://localhost:8080/v1/workflows/run` | `inputs`、`response_mode`、`user` |
| 聊天助手 / Chatflow / Agent | `POST http://localhost:8080/v1/chat-messages` | `query`、`inputs`、`response_mode`、`user`、`conversation_id` |
| 文本生成 Completion | `POST http://localhost:8080/v1/completion-messages` | `inputs`（含 `query`）、`response_mode`、`user` |

**认证方式**（所有端点通用）：

```
Authorization: Bearer app-xxxxxxxxxxxxxxxxxxxxxxxx
Content-Type: application/json
```

### 🔴🔴 关键提醒：手机真机调试不能用 localhost

**这一点对你后面用真机调 AIMindTree 至关重要，现在就要理解：**

| 从哪里访问 | 用什么地址 | 为什么 |
|---|---|---|
| 你的电脑（浏览器 / curl） | `http://localhost:8080` | ✅ 正常 |
| **Android 真机**（USB 连着的手机） | 🔴 **`http://<你电脑的局域网IP>:8080`** | 🔴 手机上的 `localhost` 指的是**手机自己**，不是你的电脑！ |
| **Android 模拟器** | `http://10.0.2.2:8080` | 模拟器里 `10.0.2.2` 是宿主机的特殊别名 |
| iOS 模拟器 | `http://localhost:8080` | iOS 模拟器和宿主机共享网络栈 |
| Flutter Web（Chrome 跑在本机） | `http://localhost:8080` | ✅ 正常 |

**查你电脑的局域网 IP**：

```bash
# Git Bash
ipconfig | grep -A5 "无线局域网\|以太网" | grep "IPv4"
```

```powershell
# PowerShell —— 更可靠，直接列出所有非回环的 IPv4
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
  Select-Object InterfaceAlias, IPAddress
```

会得到形如 `192.168.x.x` 的地址。手机和电脑**必须连同一个 WiFi**。

**还需要放行 Windows 防火墙**（否则手机连不上）：

```powershell
# PowerShell —— 需要管理员权限
New-NetFirewallRule -DisplayName "Dify 8080 局域网" `
  -Direction Inbound -LocalPort 8080 -Protocol TCP -Action Allow `
  -Profile Private
```

> ⚠️ `-Profile Private` 限定只对「专用网络」生效，比全放开安全。如果你的 WiFi 被 Windows 识别成「公用网络」，规则不生效——去 **设置 → 网络和 Internet → WiFi → 属性**，把网络配置文件改成 **专用**。
> 🔴 **不要**改成 `-Profile Any`，那会让你在咖啡厅连公共 WiFi 时也暴露 8080 端口。

**Android 还有一个坑**：Android 9+ 默认**禁止明文 HTTP 请求**。用 `http://` 调本地 Dify 会被系统拦掉，报 `CLEARTEXT communication not permitted`。开发阶段的解决办法：在 `android/app/src/main/AndroidManifest.xml` 的 `<application>` 标签加：

```xml
<application
    android:usesCleartextTraffic="true"
    ... >
```

> 🔴 **这只是开发期的权宜之计，上线前必须去掉并改用 HTTPS。**

## 7.5 最小可用验证：用 curl 调通

### Git Bash 版本

```bash
curl -X POST 'http://localhost:8080/v1/workflows/run' \
  -H 'Authorization: Bearer app-你的KEY换掉这里' \
  -H 'Content-Type: application/json' \
  -d '{
    "inputs": {
      "note_text": "傅里叶变换可以把时域信号分解为不同频率的正弦波叠加。卷积定理指出，时域的卷积等于频域的乘积。"
    },
    "response_mode": "blocking",
    "user": "aimindtree-dev"
  }'
```

### PowerShell 版本

🔴 **PowerShell 的 curl 是 `Invoke-WebRequest` 的别名，语法完全不同**，直接抄 bash 的 curl 命令会报错。用这个：

```powershell
$headers = @{
    "Authorization" = "Bearer app-你的KEY换掉这里"
    "Content-Type"  = "application/json"
}

$body = @{
    inputs = @{
        note_text = "傅里叶变换可以把时域信号分解为不同频率的正弦波叠加。卷积定理指出，时域的卷积等于频域的乘积。"
    }
    response_mode = "blocking"
    user = "aimindtree-dev"
} | ConvertTo-Json -Depth 5

$resp = Invoke-RestMethod -Uri "http://localhost:8080/v1/workflows/run" `
    -Method Post -Headers $headers -Body $body

$resp | ConvertTo-Json -Depth 10
```

> 💡 **为什么用 `Invoke-RestMethod` 而不是 `Invoke-WebRequest`**：前者自动把 JSON 响应解析成对象，后者返回原始文本还要自己 parse。
> 🔴 **中文乱码问题**：如果 PowerShell 里中文请求体发出去变成乱码，先跑 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`，并确保 `$PSDefaultParameterValues['Invoke-RestMethod:ContentType']='application/json; charset=utf-8'`。

### 如果是「聊天助手」类型的应用

```bash
curl -X POST 'http://localhost:8080/v1/chat-messages' \
  -H 'Authorization: Bearer app-你的KEY换掉这里' \
  -H 'Content-Type: application/json' \
  -d '{
    "inputs": {},
    "query": "从这段笔记提取知识点：傅里叶变换可以把时域信号分解为不同频率的正弦波叠加。",
    "response_mode": "blocking",
    "user": "aimindtree-dev",
    "conversation_id": ""
  }'
```

### 期望响应

```json
{
  "task_id": "xxxx-xxxx-xxxx",
  "workflow_run_id": "xxxx-xxxx-xxxx",
  "data": {
    "id": "xxxx",
    "workflow_id": "xxxx",
    "status": "succeeded",
    "outputs": {
      "result": "{\"points\":[{\"name\":\"傅里叶变换\",\"explanation\":\"...\",\"domain\":\"信号与系统\"}]}"
    },
    "elapsed_time": 3.21,
    "total_tokens": 456,
    "created_at": 1234567890,
    "finished_at": 1234567893
  }
}
```

🔴 **看两个地方**：
1. `data.status` 必须是 **`"succeeded"`**
2. `data.outputs.result` 里有内容（这是你在 End 节点配的输出变量名）

> 💡 注意 `outputs.result` 的值是一个**JSON 字符串**（被转义了），不是嵌套对象。因为 LLM 节点输出的是文本。在 Flutter 里拿到后需要 `jsonDecode` 两次：先解外层响应，再解 `result` 字符串。

### 常见错误对照

| HTTP 状态 / 错误信息 | 原因 | 解决 |
|---|---|---|
| 连不上 / `Connection refused` | 端口错了，或容器没起 | 确认用的是 `8080` 不是 `80`；`docker-compose ps` 看 nginx 是否 Up |
| `401 Unauthorized` | API Key 错、少了 `Bearer ` 前缀、或用了别的应用的 Key | 检查 `Authorization: Bearer app-xxx`，注意 Bearer 后面有个空格 |
| `404 Not Found` | 端点和应用类型不匹配 | Workflow 用 `/v1/workflows/run`，聊天用 `/v1/chat-messages`，见 §7.4 对照表 |
| `400` + `input is required` | `inputs` 里的 key 和 Start 节点的变量名不一致 | 回 §7.2 ① 核对变量名是 `note_text` |
| `400` + `app unavailable` / 工作流未发布 | 🔴 **忘了点「发布」** | 回 §7.2 ⑤ |
| `data.status` = `"failed"` | 工作流内部出错，通常是模型没配好或额度用完 | 去 Dify 界面 **日志与标注** 看这次运行的详细错误 |
| 响应很慢 / 超时 | `response_mode: blocking` 会等模型全部生成完 | 生产环境改用 `"streaming"`（SSE 流式），前端体验更好 |

### 在 Dify 界面看调用日志

调不通时，**Dify 界面的日志比 curl 的报错有用得多**：

应用内左侧 → **日志与标注（Logs & Annotations）** → 点具体某次运行 → 能看到每个节点的输入输出和错误堆栈。

---

# 第 8 步 · 最终环境验证清单

**逐条跑，逐条打勾。** 全部通过才算环境就绪。

## 8.1 磁盘

```bash
df -h
```

```powershell
Get-PSDrive C,D | Select-Object Name, @{n='剩余GB';e={[math]::Round($_.Free/1GB,1)}}
```

- [ ] C 盘剩余 **≥ 100GB**（迁移后实测约 127GB）
- [ ] 🔴 D 盘剩余 **≥ 50GB**（现在约 63GB，偏紧；装 Dify 前务必确认，见 §0.6）

## 8.2 Flutter / Dart

```bash
flutter --version
```
- [ ] 输出 `Flutter 3.x.x • channel stable`

```bash
dart --version
```
- [ ] 输出 `Dart SDK version: 3.x.x`

## 8.3 Java

```bash
java -version
```
- [ ] 🔴 输出 **`openjdk version "17.0.x"`**（**不是** 1.8.0_144，**不是** 23.0.1）

```bash
javac -version
```
- [ ] 输出 `javac 17.0.x`

```bash
which java
```
- [ ] 指向 `D:\DevTools\jdk-17\bin\java`，**不是** `C:\ProgramData\Oracle\Java\javapath\java`

## 8.4 环境变量

```bash
# Git Bash
echo "JAVA_HOME        = $JAVA_HOME"
echo "ANDROID_HOME     = $ANDROID_HOME"
echo "ANDROID_SDK_ROOT = $ANDROID_SDK_ROOT"
echo "GRADLE_USER_HOME = $GRADLE_USER_HOME"
echo "PUB_CACHE        = $PUB_CACHE"
echo "PUB_HOSTED_URL   = $PUB_HOSTED_URL"
echo "FLUTTER_STORAGE_BASE_URL = $FLUTTER_STORAGE_BASE_URL"
```

```cmd
:: cmd 版本
echo %JAVA_HOME%
echo %ANDROID_HOME%
echo %ANDROID_SDK_ROOT%
echo %GRADLE_USER_HOME%
echo %PUB_CACHE%
```

```powershell
# PowerShell 版本
'JAVA_HOME','ANDROID_HOME','ANDROID_SDK_ROOT','GRADLE_USER_HOME','PUB_CACHE','PUB_HOSTED_URL','FLUTTER_STORAGE_BASE_URL' |
  ForEach-Object { "{0,-26} = {1}" -f $_, [Environment]::GetEnvironmentVariable($_) }
```

| 变量 | 期望值 | ✓ |
|---|---|---|
| `JAVA_HOME` | `D:\DevTools\jdk-17` | [ ] |
| `ANDROID_HOME` | `C:\Users\ASUS\AppData\Local\Android\Sdk` | [ ] |
| `ANDROID_SDK_ROOT` | 同上 | [ ] |
| `GRADLE_USER_HOME` | `D:\DevCache\gradle` | [ ] |
| `PUB_CACHE` | `D:\DevCache\pub-cache` | [ ] |
| `PUB_HOSTED_URL` | 清华/交大镜像地址 | [ ] |
| `FLUTTER_STORAGE_BASE_URL` | 清华/交大镜像地址 | [ ] |

## 8.5 Android 工具链

```bash
adb version
```
- [ ] 输出 `Android Debug Bridge version 1.0.xx`

```bash
ls /c/Users/ASUS/AppData/Local/Android/Sdk/cmdline-tools/latest/bin/sdkmanager.bat
```
- [ ] 🔴 文件存在（之前 cmdline-tools 是空的）

```bash
sdkmanager --list_installed
```
- [ ] 能正常列出组件，不报错

## 8.6 flutter doctor

```bash
flutter doctor -v
```

- [ ] 🔴 `[✓] Flutter`
- [ ] 🔴 `[✓] Android toolchain - develop for Android devices`
- [ ] `[✓] Windows Version`
- [ ] `[✓] Network resources`
- [ ] 🟡 `[!] Android Studio` — **可接受**（jbr 损坏，见 §4.2 ⑤）
- [ ] 🟡 `[✗] Visual Studio` — **可接受**（暂不做 Windows 桌面版）
- [ ] 🟡 `[!] Chrome` — 建议修（做 Web 端要用）

## 8.7 Docker

```bash
docker info
```
- [ ] 有 `Server:` 段落，能看到 `Server Version`
- [ ] 🔴 **没有** `open //./pipe/dockerDesktopLinuxEngine` 这个报错

```bash
docker-compose --version
```
- [ ] 输出 `Docker Compose version v5.3.1`
- [ ] 🔴 记住：本机用 `docker-compose`（短横线），**不是** `docker compose`

## 8.8 Dify 容器

```bash
cd /d/dify/docker
docker-compose ps
```

- [ ] 所有容器 STATUS 为 `Up` 或 `Up (healthy)`
- [ ] 🔴 没有 `Exited` 或 `Restarting` 的容器
- [ ] 🔴 nginx 的 PORTS 显示 `0.0.0.0:8080->80/tcp`

```bash
grep -nE '^EXPOSE_NGINX_PORT=|^VECTOR_STORE=' /d/dify/docker/.env
```
- [ ] `EXPOSE_NGINX_PORT=8080`
- [ ] `VECTOR_STORE=` 是你决定的值（`pgvector` 省内存 / `weaviate` 默认）

## 8.9 Dify Web 界面

浏览器打开：

```
http://localhost:8080/install
```

- [ ] 🔴 页面能打开（不是 `无法访问此网站` / `ERR_CONNECTION_REFUSED`）
- [ ] 完成管理员账号初始化
- [ ] 能用该账号登录进控制台

## 8.10 Dify API 链路

- [ ] **设置 → 模型供应商** 里已配好至少一个模型
- [ ] 已创建「工作流」类型应用 `AIMindTree-知识点提取`
- [ ] Start 节点有变量 `note_text`（段落类型）
- [ ] End 节点有输出变量 `result`
- [ ] 🔴 **已点「发布」→「更新发布」**
- [ ] 在界面里 **运行** 测试通过，能返回结构化知识点
- [ ] 已在 **访问 API** 页创建并保存了 App API Key（`app-xxx`）
- [ ] 🔴 §7.5 的 curl 调用返回 `"status": "succeeded"`，`outputs.result` 有内容

## 8.11 真机调试准备（做 App 时需要）

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
  Select-Object InterfaceAlias, IPAddress
```
- [ ] 记下电脑局域网 IP（形如 `192.168.x.x`）

- [ ] 手机与电脑连同一个 WiFi
- [ ] 已放行防火墙 8080 端口（§7.4）
- [ ] 手机浏览器能打开 `http://<电脑IP>:8080`
- [ ] 🔴 理解了 **手机上不能用 `localhost`**，必须用局域网 IP

```bash
adb devices
```
- [ ] 手机 USB 连接后能列出设备（状态是 `device`，不是 `unauthorized`）

## 8.12 Flutter 项目跑起来

```bash
cd /d/AndroidStudioProjects/AIMindTree/aimindtree_app
flutter pub get
```
- [ ] 依赖拉取成功（配了镜像应该很快）

```bash
flutter devices
```
- [ ] 至少列出一个可用设备

```bash
flutter run
```
- [ ] 能看到默认的计数器 Demo 界面

> 💡 **首次 `flutter run` 会很慢**（要下 Gradle 发行包、拉 Android 依赖、编译）。**十几分钟是正常的**。第二次就快了。
> 🔴 如果卡在 `Running Gradle task 'assembleDebug'...` 超过 20 分钟不动，大概率是网络问题。检查 §2.2 的镜像配置，并考虑给 Gradle 也配国内镜像源。

---

# 第 9 步 · 在 Android Studio 里配置 Flutter

> 前 8 步走的是命令行路线。这一步给你 **IDE 路线**——用 Android Studio 图形界面配置，更直观。
> 🔴 **先确认一件事**：你的 Android Studio 在 **`D:\AndroidStudio`**（2.7G，Ladybug 2024.2.1，内置 JDK 21.0.3 实测可用）。
> `C:\Program Files\Android\Android Studio` 是**残缺残留**（只有 `jbr`/`lib`/`plugins`，连 `bin` 目录都没有），别启动它，也别去修它。

## 9.1 安装 Flutter 插件

1. 启动 `D:\AndroidStudio\bin\studio64.exe`
2. 首次启动走 Setup Wizard，选 **Do not import settings**
3. 到欢迎页 → 左侧 **Plugins** → **Marketplace** → 搜 `Flutter` → **Install**
4. 会提示同时安装 **Dart** 插件，点 **Yes**（Flutter 依赖 Dart，必须一起装）
5. 装完点 **Restart IDE**

## 9.2 指定 Flutter SDK 路径

重启后欢迎页会多出 **New Flutter Project**。若要手动指定或改路径：

**File → Settings → Languages & Frameworks → Flutter**
- Flutter SDK path 填 `D:\DevTools\flutter`
- 点 OK，它会自行校验并显示出 **Flutter 3.47.2 / Dart 3.13.2**

## 9.3 建 Flutter 工程（🔴 目录别选错）

**File → New → New Flutter Project**

| 选项 | 填什么 |
|---|---|
| Flutter SDK path | 自动填好 `D:\DevTools\flutter`，别动 |
| **Project location** | 🔴 **`D:\AndroidStudioProjects\AIMindTree\aimindtree_app`** |
| Project type | Application |
| Organization | `com.aimindtree`（applicationId 后期很难改，现在定好） |
| Android language | **Kotlin**（你本来就是 Kotlin 背景） |
| iOS language | Swift |
| Platforms | 勾 **Android + Windows + Web**（iOS 在 Windows 上编译不了，勾不勾都会生成目录） |

> 🔴 **为什么必须是 `aimindtree_app` 子目录**：`D:\AndroidStudioProjects\AIMindTree` 根目录现在是个 **Kotlin JVM Gradle 工程**，有 `build.gradle` / `settings.gradle` / `gradlew`。在这里直接建 Flutter 工程会**文件冲突**。根目录只保留 `docs/`。

## 9.4 设置 JAVA_HOME —— 🎉 不用装 JDK 17

之前文档说"必须装 JDK 17"，那是基于「Android Studio 内置 JDK 坏了」的判断。**这个判断已作废**：`D:\AndroidStudio\jbr` 实测是 **OpenJDK 21.0.3，能正常跑**。Gradle 8.x 支持 JDK 17–22，21 完全够用。

```powershell
[Environment]::SetEnvironmentVariable("JAVA_HOME", "D:\AndroidStudio\jbr", "User")
[Environment]::SetEnvironmentVariable("ANDROID_HOME", "$env:LOCALAPPDATA\Android\Sdk", "User")
[Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", "$env:LOCALAPPDATA\Android\Sdk", "User")
```

🔴 **设完必须关掉所有终端 + Android Studio 重开**，否则不生效。

**验证**：新开终端跑 `java -version`，应显示 `openjdk version "21.0.3"`。

> 🔴 **如果还是显示 1.8**：`C:\ProgramData\Oracle\Java\javapath` 在**系统变量** PATH 里，优先级高于用户变量。
> 解决：`sysdm.cpl` → 高级 → 环境变量 → **系统变量**的 `Path` → 找到 `C:\ProgramData\Oracle\Java\javapath` → **下移到最底部或直接删除**。这一步只能手动点图形界面，脚本改不了。

## 9.5 补装 cmdline-tools（必做，否则 flutter doctor 报错）

**File → Settings → Android SDK → SDK Tools 选项卡**
→ 勾选 **Android SDK Command-line Tools (latest)** → Apply

装完验证 `C:\Users\ASUS\AppData\Local\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat` 存在。

> 🔴 这个目录现在是空的，`flutter doctor` 会报 `cmdline-tools component is missing`，且 `flutter doctor --android-licenses` 根本跑不起来（sdkmanager 就在这个包里）。

## 9.6 把 flutter 加进 PATH（可选，想在终端用 flutter 命令才需要）

```powershell
$old = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", "$old;D:\DevTools\flutter\bin", "User")
```

> 🔴 **不要用 `setx`**：它对超过 1024 字符的 PATH 会截断，可能让你整台机器的命令全部失效。用上面这行 `[Environment]::SetEnvironmentVariable` 才是安全的。

## 9.7 接受 Android 协议 + 验收

```bash
flutter doctor --android-licenses   # 一路输入 y
flutter doctor -v
```

**必须打勾的只有两项**：`Flutter` 和 `Android toolchain`。
**可以不管的**：`Visual Studio` 报 ✗（暂不做 Windows 桌面版）；`Chrome` 报 ✗（只是不能跑 Web 调试，装了 Chrome 就好）。

---

# 第 10 步 · Dify 启动与配置

## 10.1 启动 Docker Desktop（🔴 必须手动，命令行做不到）

Docker Engine 29.7.2 已装，但**守护进程没在跑**。

1. 开始菜单搜 **Docker Desktop** 启动
2. 等任务栏鲸鱼图标**停止动画**（变实心）才算就绪，通常 1–2 分钟
3. 验证：

```bash
docker info --format "{{.ServerVersion}}"
```

输出版本号 = 成功；报 `npipe:////./pipe/dockerDesktopLinuxEngine` = 还没起来，继续等。

## 10.2 直接启动（端口已改好）

✅ `.env` 第 917/918 行已于 2026-09-04 改为 `EXPOSE_NGINX_PORT=8080` / `EXPOSE_NGINX_SSL_PORT=8443`，你不用再改。

```bash
cd /d/dify/docker
docker-compose up -d
```

🔴 本机只能用 **`docker-compose`（短横线）**，`docker compose`（空格）报 unknown command。网上教程写的空格形式要自己换掉。

**首次启动会拉十几个 GB 镜像**（postgres / redis / weaviate / nginx / api / worker / web / sandbox / plugin_daemon），**10–30 分钟**。

> ⚠️ 启动前确认 **D 盘剩余 ≥ 30G**（现在约 59G）。镜像拉到一半失败会**留下无法自动清理的层文件**，反而更占空间。

```bash
docker-compose ps           # 看各容器状态
docker-compose logs -f api  # 跟 API 日志
```

## 10.3 初始化管理员账号

浏览器打开 **http://localhost:8080/install** → 设邮箱、用户名、密码 → 之后登录 **http://localhost:8080**

> 🔴 **记住这个坑**：Dify 界面上显示的 API 地址是 `http://localhost/v1`（**不带端口**），你自己在代码里调用时要手动补成 **`http://localhost:8080/v1`**。

## 10.4 配置模型供应商（不配的话工作流跑不了）

Dify 只是编排层，得先挂一个模型。**右上角头像 → 设置 → 模型供应商**

| 方案 | 怎么配 |
|---|---|
| **MiniMax**（推荐先试，你已有 Key） | 列表里若没有 MiniMax，装 **OpenAI-API-compatible** 供应商，Base URL 填 `https://api.minimaxi.com/v1`（OpenAI 兼容端点）+ 你的 Key |
| **Ollama 本地** | 装 Ollama 后，供应商选 Ollama，Base URL 填 **`http://host.docker.internal:11434`** |
| 其他 OpenAI 兼容厂商 | 装 OpenAI-API-compatible，填各家 Base URL + Key |

> 🔴 **Docker 网络坑**：Dify 跑在容器里，容器里的 `localhost` 指的是**容器自己**，不是你的电脑。要访问宿主机上的 Ollama，必须用 `host.docker.internal`，填 `localhost` 或 `127.0.0.1` 都会连不上。

## 10.5 建第一个工作流（知识点提取）

1. 首页 → **创建应用** → 🔴 选 **工作流（Workflow）**，**别选"聊天助手"**
   （端点不一样：Workflow 是 `/v1/workflows/run`，聊天助手是 `/v1/chat-messages`）
2. 编排：
   - **Start 节点**：加输入变量 `note_text`（类型：段落）
   - **LLM 节点**：提示词里引用 `{{#start.note_text#}}`，要求输出 JSON 数组，每项含 `title` / `summary` / `source_quote`
     - 🔴 `source_quote` 必须是**从原文摘取的引用**——这对应 PRD 硬规则「知识点必须带来源锚点，无锚点视为 AI 幻觉，禁止入库」
   - **End 节点**：加输出变量 `result`（引用 LLM 节点输出）
3. 右上角 **发布 → 更新发布**
   - 🔴 **不点发布，API 一定调不通**（API 只认已发布版本，草稿无效）。这是新手最常见的失败原因。
4. 左侧 **访问 API** → 右上角 **API 密钥** → **创建密钥**
   - Key 格式 `app-xxxxxxxx`，**只完整显示一次，立刻复制保存**

## 10.6 用 curl 打通再接进 App

```bash
curl -X POST http://localhost:8080/v1/workflows/run \
  -H "Authorization: Bearer app-你的key" \
  -H "Content-Type: application/json" \
  -d '{"inputs":{"note_text":"梯度下降是一种优化算法..."},"response_mode":"blocking","user":"test-user"}'
```

🔴 `inputs` 的 key 必须和 Start 节点里定义的变量名**完全一致**，否则报 `xxx is required`。

调不通时**别死磕 curl 报错**，去 Dify 界面的「日志与标注」看，那里信息全得多。

## 10.7 关于多应用（对应架构的 `ai_task_routes`）

Dify 的 Key **按应用签发**，一把 Key 只能调一个应用。
- **现在**：只建一个「知识点提取」应用就够
- **以后**：若给「出题」「讲解」各建应用 = 多把 Key。架构已预留 `ai_task_routes` 表按任务路由，配置界面是 P1（见 PRD H13）

## 10.8 日常命令 🔴

```bash
cd /d/dify/docker
docker-compose stop     # 停止，数据保留
docker-compose start    # 启动
docker-compose ps       # 看状态
docker-compose logs -f  # 看日志
```

> 🔴🔴 **`docker-compose down -v` 会永久删除所有数据**——应用、工作流、API Key、知识库、管理员账号全部消失，**不可恢复，没有回收站**。别乱跑。

---

# 附录 A · 环境变量总表（一次性设置脚本）

⚠️ **不要盲目整段执行**。先通读，确认路径符合你的实际安装位置，再逐条跑。

```powershell
# ============================================
# AIMindTree 环境变量一次性设置（PowerShell）
# 执行前请确认：
#   1) JDK 17 已装在 D:\DevTools\jdk-17
#   2) Flutter 已解压到 D:\DevTools\flutter
#   3) 各目录路径与你的实际情况一致
# ============================================

# --- 建缓存目录 ---
New-Item -ItemType Directory -Force -Path "D:\DevCache\gradle"      | Out-Null
New-Item -ItemType Directory -Force -Path "D:\DevCache\pub-cache"   | Out-Null

# --- JDK ---
setx JAVA_HOME "D:\DevTools\jdk-17"

# --- Android SDK（已存在，只是指过去）---
setx ANDROID_HOME     "C:\Users\ASUS\AppData\Local\Android\Sdk"
setx ANDROID_SDK_ROOT "C:\Users\ASUS\AppData\Local\Android\Sdk"

# --- 缓存搬到 D 盘 ---
setx GRADLE_USER_HOME "D:\DevCache\gradle"
setx PUB_CACHE        "D:\DevCache\pub-cache"

# --- Flutter 国内镜像（清华 TUNA）---
setx PUB_HOSTED_URL           "https://mirrors.tuna.tsinghua.edu.cn/dart-pub"
setx FLUTTER_STORAGE_BASE_URL "https://mirrors.tuna.tsinghua.edu.cn/flutter"

# --- PATH（用无截断风险的方式追加）---
$sdk = "C:\Users\ASUS\AppData\Local\Android\Sdk"
$toAdd = @(
    "D:\DevTools\jdk-17\bin",
    "D:\DevTools\flutter\bin",
    "$sdk\platform-tools",
    "$sdk\cmdline-tools\latest\bin",
    "$sdk\emulator"
)

$userPath = [Environment]::GetEnvironmentVariable('Path','User')
$parts = $userPath -split ';' | Where-Object { $_ }

foreach ($p in $toAdd) {
    if ($parts -notcontains $p) {
        $parts = @($p) + $parts     # 加到最前面，确保优先级高于旧的 Oracle javapath
        "已添加: $p"
    } else {
        "已存在，跳过: $p"
    }
}

[Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')

Write-Host ""
Write-Host "===========================================" -ForegroundColor Yellow
Write-Host " 设置完成。请关闭所有终端窗口后重新打开！" -ForegroundColor Yellow
Write-Host " 然后手动检查系统变量 Path 中的" -ForegroundColor Yellow
Write-Host " C:\ProgramData\Oracle\Java\javapath" -ForegroundColor Yellow
Write-Host " 是否需要下移或删除（见 §1.3）" -ForegroundColor Yellow
Write-Host "===========================================" -ForegroundColor Yellow
```

> 🔴 **这个脚本只改「用户变量」的 PATH，无法动「系统变量」的 PATH。** 而 `C:\ProgramData\Oracle\Java\javapath` 在**系统变量**里。所以跑完脚本后，**仍然需要手动按 §1.3 的图形界面方式处理它**。
>
> Windows 的 PATH 解析顺序是：**系统变量 PATH → 用户变量 PATH**。这意味着系统变量里的 javapath **天然优先于**用户变量里的 JDK 17 —— 这就是为什么必须手动处理。

# 附录 B · 各软件安装位置汇总

| 软件 / 数据 | 位置 | 盘 | 说明 |
|---|---|---|---|
| JDK 17（Temurin） | `D:\DevTools\jdk-17` | D | 新装 |
| Flutter SDK（含 Dart） | `D:\DevTools\flutter` | D | 新装，🔴 路径不能有空格 |
| Android SDK | `C:\Users\ASUS\AppData\Local\Android\Sdk` | C | **已存在，不动** |
| Android Studio | `C:\Program Files\Android\Android Studio` | C | 已存在，jbr 损坏但不影响命令行 |
| Gradle 缓存 | `D:\DevCache\gradle` | D | 从 C 盘迁出 |
| Pub 包缓存 | `D:\DevCache\pub-cache` | D | 提前设好，避免落 C 盘 |
| Docker WSL2 虚拟磁盘 | `D:\DockerData` | D | 🔴 从 C 盘迁出，释放 ~100GB |
| Dify 源码 + 数据卷 | `D:\dify` | D | **已存在** |
| AIMindTree 文档 | `D:\AndroidStudioProjects\AIMindTree\docs` | D | 已存在 |
| AIMindTree Flutter 项目 | `D:\AndroidStudioProjects\AIMindTree\aimindtree_app` | D | 待创建 |

# 附录 C · 本机三大坑速查

如果你只记住三件事，记这三件：

### 🟢 坑 1（已解决）：C 盘 23GB 危机已通过 §0.2 迁移解除 + 🔴 新增：D 盘仅剩 63GB 偏紧

**旧坑（已解决）**：之前 C 盘只剩 23GB、Docker 的 WSL2 虚拟磁盘占了 100GB。已于 2026-09-04 完成 §0.2 迁移，C 盘释放到约 127GB，危机解除。

**新增风险**：迁移后压力转到了 D 盘——Dify 镜像 + 数据卷、Flutter SDK、Gradle/pub 缓存全堆在 D 盘，**D 盘只剩约 63GB（97% 已用）**，偏紧。装 Dify（首拉镜像 10–20GB）前务必确认 D 盘 ≥ 50GB，否则中途磁盘满、失败、留垃圾。

**动作**：
- C 盘侧：迁移已做，跳过 §0.2（验证命令见 §0.1）。
- 🔴 D 盘侧：`docker system df` 看占用，删无用镜像/卷；不足 50G 先清理再继续（详见 §0.6）。

### 🔴 坑 2：`java -version` 会一直显示 1.8，哪怕你装了 17

因为 `C:\ProgramData\Oracle\Java\javapath` 在**系统变量 PATH** 里，优先级高于用户变量。

**动作**：`sysdm.cpl` → 环境变量 → **系统变量** 的 Path → 把 `C:\ProgramData\Oracle\Java\javapath` 下移到底部或删除。见 §1.3。

### 🔴 坑 3：Dify 起不来，因为 80 端口被系统占了

`0.0.0.0:80` 被 PID 4（Windows System / http.sys）占用，nginx 绑不上。

**动作**：改 `D:\dify\docker\.env` 的 `EXPOSE_NGINX_PORT=8080`，访问地址变成 `http://localhost:8080`。见 §6.4。

**附带影响**：Dify 界面上显示的 API 地址会是 `http://localhost/v1`（没带端口），你自己调用时**要手动加上 `:8080`**。

# 附录 D · 命令速查

```bash
# ---- 环境检查 ----
df -h                        # 磁盘空间
flutter doctor -v            # Flutter 环境全面检查
java -version                # Java 版本（应为 17.x）
adb devices                  # 已连接的 Android 设备
docker info                  # Docker 守护进程状态

# ---- Flutter 日常 ----
flutter pub get              # 拉依赖
flutter run                  # 跑到默认设备
flutter run -d chrome        # 跑 Web
flutter devices              # 列出可用设备
flutter clean                # 清构建产物（磁盘紧张时有用）
flutter build apk --debug    # 打 debug APK

# ---- Dify 日常（必须在 /d/dify/docker 目录下）----
cd /d/dify/docker
docker-compose ps                      # 容器状态
docker-compose up -d                   # 启动
docker-compose stop                    # 停止（数据保留）
docker-compose restart api             # 重启单个服务
docker-compose logs -f --tail=100 api  # 跟日志
docker-compose down                    # 删容器（🟡 数据卷保留）
docker stats                           # 实时资源占用

# ---- 🔴 危险命令（已注释，确认后再手动去掉 #）----
# docker-compose down -v               # 🔴 删除所有 Dify 数据，不可恢复
# docker system prune -a --volumes     # 🔴 清空本机所有 Docker 资源
```

---

## 10.9 排错：首次打开报 `Internal server error` / 500（数据库迁移没跑）

**症状**：`docker-compose up -d` 后所有容器都 `Up`，但打开 `http://localhost:8080/install` 报 *Internal server error*，或 `/console/api/setup` 返回 **500**。

**根因（实测）**：`api` / `worker` 容器在启动时执行 `flask db upgrade` 跑数据库迁移，但**比 Postgres 早启动了半秒**，迁移因 `psycopg2.OperationalError: Connection refused` 失败；容器没退出而是继续运行，于是所有表（含 `dify_setups`、`alembic_version`）都不存在。API 每次读 `dify_setups` 就 500。
> 注意：CSDN 上常见的「把 `CONSOLE_API_URL` 改成 `http://localhost`」是**另一种**症状（跨机访问时前端拿不到 API 地址），对本机的 500 **无效**，别被带偏。

**快速确认**：
```bash
cd D:\dify\docker
# 1) setup 接口是否 500
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/console/api/setup
# 2) api 日志是否报迁移失败 / connection refused
docker-compose logs api 2>&1 | grep -iE "Failed to execute database migration|connection refused|dify_setups"
# 3) 确认 db 现在健康（此时应该已 healthy）
docker-compose ps db
```

**一键修复**（db 已 healthy 时直接手动补跑迁移）：
```bash
cd D:\dify\docker
# 在 api 容器内用 venv 的 flask 跑迁移（工作目录必须是 /app/api）
docker exec -w /app/api docker-api-1 /app/api/.venv/bin/flask db upgrade
# 重启三个服务让它们重新加载 schema
docker-compose restart api worker web
# 验证：setup 接口应回到 200，install 页面可正常打开
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/console/api/setup
curl -s http://localhost:8080/console/api/setup        # 正常应返回 {"step":"not_started"}
```

**为什么不会复发**：迁移记录写在 Postgres 的 `alembic_version` 表（实测值 `f051706725cc`），持久化在 Docker 卷里。下次 `docker-compose up -d` 时 `flask db upgrade` 是空跑（版本已最新），不再有「首次迁移」的竞态窗口。仅在你 **`docker-compose down -v` 删了数据卷** 或换了一台机器重新 `up` 时才需要再跑一次上面的修复。
> 想从根上消除冷启动竞态，可给 `docker-compose.yaml` 里 `api`/`worker` 的 `depends_on.db` 加上 `condition: service_healthy`（db 服务已有 healthcheck）。属于可选加固，不做也不影响使用。

---

## 10.10 排错：`flutter test` / `dart run` 报 `Unable to connect to flutter_tester` / `WebSocketException`

**现象**（实测）：
```
Failed to load ".../test/widget_test.dart": Unable to connect to flutter_tester process:
WebSocketException: Invalid WebSocket upgrade request
```
`flutter analyze` 正常、代码没问题，但测试起不来。

**根因**：本机/沙箱设置了 `http_proxy=http://127.0.0.1:<随机端口>`，`flutter_tester` 与测试驱动之间走的是**本机 websocket**，被这个代理拦截了。同理，脚本里用 `dart:io` 访问 `localhost:8080`（Dify）也可能被代理拦。

**修法**：让 localhost 走直连（两个环境变量都设，大小写不敏感）：
```bash
export no_proxy="localhost,127.0.0.1"
export NO_PROXY="localhost,127.0.0.1"
flutter test
# 或
no_proxy=localhost,127.0.0.1 dart run tool/smoke_extract.dart
```
设完即时生效，**不需要**关终端重开（这是 `export` 的即时导出，与 §10 里「改了不生效要重开终端」不是一回事）。

**判断依据**：`echo $http_proxy` 若打印 `http://127.0.0.1:...` 即命中本问题。这是**环境问题不是代码问题**——`flutter analyze` 全绿就说明代码本身没毛病。

---

## 10.11 排错：引入 Drift 后 `flutter test` / `flutter run` 卡死或报 native assets 失败

**现象**（实测）：项目加入 `drift` / `drift_flutter`（依赖 `sqlite3` 原生库）后：
```
This failed (attempted to download https://github.com/simolus3/sqlite3.dart/releases/.../sqlite3.x64.windows.dll)
Original cause: HttpException: Proxy failed to establish tunnel (502 Bad Gateway)
Building native assets failed.
```
或 bash 下直接吐 `%PROGRAMFILES(X86)% environment variable not found.`（原生构建工具链找不到 VS 相关环境变量）。

**根因**：`sqlite3` 包在**构建期**（不是运行期）通过 native assets hook 从 GitHub 下载预编译 DLL；若代理拦截 GitHub（502）则构建失败。且项目一旦依赖 sqlite3，**任何** `flutter test` / `flutter run` 都会触发该构建。

**沙箱/代理环境下的应对**：
1. 注入 VS 环境变量（bash 的 `export` 不支持带括号的名字，要用 `env`）：
   ```bash
   env "PROGRAMFILES(X86)=C:\\Program Files (x86)" "PROGRAMFILES=C:\\Program Files" flutter test
   ```
2. DLL 下载失败时，可从本机 Python 复制一份顶上（实测路径）：
   ```bash
   cp /c/Users/ASUS/.workbuddy/binaries/python/versions/3.13.12/DLLs/sqlite3.dll \
      aimindtree_app/.dart_tool/hooks_runner/shared/sqlite3/build/download-2bf39f2a/sqlite3.dll
   ```
   > `download-2bf39f2a` 这个哈希目录名随 sqlite3 版本变化，以 `.dart_tool/hooks_runner/shared/sqlite3/build/` 下实际存在的为准。
3. **在真实机器（可直连 GitHub）上首次 `flutter test` / `flutter run` 会自动下载 DLL 并缓存**，之后离线可用——上面的手动步骤只在受限网络环境需要。

**判断依据**：`flutter analyze` 全绿但 `flutter test` 挂在 "Building native assets"，即命中本问题；这是环境问题不是代码问题。

---

## 遇到问题怎么办

1. **先看 `flutter doctor -v` 的完整输出**，它会明确告诉你缺什么
2. **Dify 出问题先看容器日志**：`docker-compose logs --tail=100 <服务名>`
3. **Dify 工作流出问题看界面日志**：应用内 → 日志与标注
4. **磁盘相关问题先跑 `df -h`**，很多"莫名其妙的失败"根源是磁盘满
5. **环境变量改了不生效**：99% 是因为**没关掉终端重开**

---

*文档基于本机实测环境编写。所有标注「实测」的数据均来自在 `D:\AndroidStudioProjects\AIMindTree` 工作区实际执行的只读探测命令。若你的机器状态发生变化（如已迁移 Docker 磁盘、已装 JDK），请重新跑一遍 §8 的验证清单确认。*

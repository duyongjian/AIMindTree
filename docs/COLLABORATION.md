# AIMindTree 多人协作规矩

> 本文只固化**「多人同时在同一个工作树上施工」**时反复踩到的坑，与对应的正确做法。
> 架构、需求、测试方案各有其文档，本文**不复制、不重写，也不在此处新增任何架构决策**。

| 本文管什么 | 本文不管什么 |
| --- | --- |
| 同一工作树多人并行时的**操作规矩**：改动隔离、临时文件、门禁时机、断言有效性 | 架构设计与分层、需求与验收标准、测试用例设计 —— 见 `ARCHITECTURE.md` / `TEACHER_SESSION_PRD.md` / `TEACHER_SESSION_TEST_PLAN.md` |
| 工具怎么调（代理、门禁命令） | 业务逻辑怎么写 |

**背景**：老师模式会话化（T01a–T05）期间，多条任务线在同一工作树上并行推进。下面每条规矩都来自**本轮真实踩过**的坑，且都配了实例。

---

## 1. 不得用 `git checkout --` / `git restore` 抹掉别人的未提交改动

**实例**：architect-2 为复现「读源文件」的路径问题，对一个**自己没改过**的文件执行 `git checkout -- <file>`，结果把 software-engineer-4 尚未提交的一行改动一起抹了（后已恢复）。

| 场景 | ✅ 正确做法 | ❌ 错误做法 |
| --- | --- | --- |
| 还原**自己**改过的文件 | `git diff > /tmp/x.patch` → `git checkout -- <file>` → `git apply /tmp/x.patch` | 直接 `git checkout -- <file>`（连别人的改动一起抹） |
| 还原**别人**改过的文件 | **不动**。先 `git status` 确认这个文件是不是只有一个人在改；拿不准就**别动**，宁可多问一句 | `git restore <file>` / `git checkout -- <file>` / `git stash`（会连带卷走他人 WIP） |
| 只想看「原始版本长什么样」 | `git show HEAD:<file>`（只读，不碰工作树） | `git checkout -- <file>`（破坏性） |

> **判据**：`git checkout --` 是**破坏性**操作，作用于**整个工作树**，**不区分改动是谁的**。

---

## 2. 临时探针文件必须放在 `test/` 内、命名 `tmp_*.dart`、**用完立刻删**

**实例**：`test/tmp_pragma_probe_test.dart`、`test/zz_scratch_pragmas_test.dart` 反复出现；其中一次探针放在 `test/` **之外** → `flutter test` 根本不扫它 → 跑出 **0 断言的「假绿」**，等于没写。

| 为什么 | 依据 |
| --- | --- |
| **必须在 `test/` 内** | `flutter test` **只扫描包内的 `test/` 目录** → 探针放到 `/tmp` 或仓库其它位置 = **测不到 = 等于没写** |
| **必须用完立刻删** | `tool/analyze_inproc.dart` 的 `kDefaultRoots = ['lib','test']` 走**文件系统遍历**（**含未跟踪文件**）→ 残留探针会进 analyze 的 error/warning 计数 → **污染门禁基线**（本轮发生过 1 个 warning，来源就是没删干净的探针） |
| **收尾自查** | `git status --porcelain` 里**不允许出现 `??` 开头的行**（= 没有未跟踪残留） |

> **实测补充**：探针文件**从未被提交过**（`git log --diff-filter=A -- 'aimindtree_app/test/tmp_*' 'aimindtree_app/test/zz_*'` 查不到任何提交）→ **git 历史里根本查不到它们，只能靠 `git status` 现场发现**。所以上面那条自查不是形式主义。

---

## 3. 提交前先跑门禁，且门禁必须在**别人没在改的文件**上跑

**实例**：本轮多次出现「A 在施工 → B 跑全量测试 → 读到半成品 → 报 12 error / 2 条红」的**瞬时态**，被误判成真实 bug，浪费一轮排查。我自己撞到过一次：`flutter test` **602/602 全绿**、但 `analyze_inproc` 报 **12 error** —— 复测立刻回 0 error，且当时 `git status` 明确有他人未提交的半成品改动。

| 场景 | ✅ 正确做法 | ❌ 错误做法 |
| --- | --- | --- |
| 跑门禁的时机 | 工作树干净时跑（自己的改动已提交，或只在自己的文件上改） | 别人正在改同一批文件时跑，读到半成品 |
| 跑出红灯时 | **先** `git status --porcelain` + 看 `lib/` 下文件 mtime，确认是不是有人在施工 | 直接认定是自己的 bug，开始改代码 |
| 判定瞬时态的三个信号 | ① 复测结果与上次不一致 ② `git status` 有他人未提交改动 ③ 报错文件不在自己职责范围 | 只看报错信息就下结论 |

> **反向教训**：同一份 `agent_page.dart` 在我两次读取之间行数从 **1749 变成 1742** → **行号不是稳定锚点**，文档里应按符号名定位。

---

## 4. 反向验证：任何「护栏 / 断言」类改动，必须证明它**会红**

**实例一**（同步契约第四腿）：工程师做了两轮反证才敢收工 —— ① 真在内存库 `ALTER TABLE` 加一列 → 真实 PRAGMA 链路必须报出 `missing`；② 把逐表断言短路掉（`if (false)` 包一层）→ 端到端反证那条**必须跟着红**（这一步还暴露了旧结构「两份代码」的真问题，才有了 `298c5e7` 的断言点收敛）。

**实例二**（老师模式会话面板 R1/R2）：作者把 `Navigator.pop` 与 `_bootstrap()` **改回旧写法** → R1/R2 **都失败**；改回修复后转绿 → 确认不是恒真断言。

| 步骤 | 做法 |
| --- | --- |
| 1. 写断言 | 写完「这条断言能抓住 X」 |
| 2. **制造 X** | 真的把 X 造出来（改坏实现 / 加列 / 短路断言） |
| 3. 确认变红 | 该红的**必须红**；不红 = 断言无效 |
| 4. 撤掉 | 恢复现场，确认转绿 |

> **只写不验 = 不知道它是恒真还是有效。** 恒真断言会给出「测试全绿 = 没问题」的假信号，比没有测试更危险。

---

## 5. 代理必须**显式置空**，不能用 `unset ... &&`

```bash
# ✅ 正确
HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= ALL_PROXY= all_proxy= flutter.bat test

# ❌ 错误：本机会被 SIGTERM 掉且无任何输出（踩了两次）
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy && flutter.bat test
```

> ⚠️ **`analyze_inproc.dart` 不走网络** → 它报 error **不可能**是代理问题。别拿代理解释与网络无关的错误。

---

## 6. 门禁命令与基线

```bash
cd aimindtree_app
D:/DevTools/flutter/bin/cache/dart-sdk/bin/dart.exe tool/analyze_inproc.dart   # 错 + 警都 fail；info 允许
HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= ALL_PROXY= all_proxy= flutter.bat test
```

| 事项 | 规矩 |
| --- | --- |
| `flutter analyze` | **不能**当门禁（会报一堆存量 info） |
| analyze 判定 | **error 与 warning 都算失败**；info 允许，但**不得新增**（存量 3 条 `withOpacity` 废弃告警） |
| test 判定 | 0 失败、0 编译错误；条数 **≥ 基线 + 新增条数** |
| 门禁跑完 | `git status --porcelain` 应为空 |
| **基线是移动靶** | 本轮基线 **602 → 670 → 674 → 695 → 878 → 882 → 883 → 884**。**不要抄文档里的旧数字**，每次**当场实测**再写进文档。报数时 **hash 与数字必须同一条命令取**（`echo BEFORE head=$(git rev-parse --short HEAD)` → 测试 → `echo AFTER head=...`），否则会把「B 时刻的用例数」挂到「A 时刻的 hash」上（真实发生过：883 被记到 `924c76a` 头上，实为 882） |
| **全量 test 必须串行** | 同一 worktree 里并发跑 `flutter test` 会锁 `build/native_assets/windows/sqlite3.dll`，报 `Flutter failed to delete file`，**一条测试都不会执行**（见 §9）。跑之前先确认没有别人的 dart/flutter 进程 |

> 附：`grep -rn "'local-dev'" aimindtree_app/lib` → 必须 **0 命中**；`test/` 里的 **27 处**是合法多设备夹具（刻意模拟多设备），**不许动**。

---

## 7. 共享 worktree 的 git 红线（2026-10-27 实战事故）

同一 worktree 上多人并行时，**任何作用于整个工作区的 git 命令都会静默吃掉别人未提交的改动**。已发生一次：一条已写好、已验证但尚未提交的测试，被并发的全工作区操作清掉（`git status` 变干净、文件回退），只能重写重提。

| 禁止 | 原因 |
| --- | --- |
| `git add -a` / `git add .` / `git commit -a` | 会把别人在途改动一起卷进你的 commit |
| `git stash` / `git checkout -- .` / `git reset --hard` | 会丢弃别人未提交的改动 |
| 把未提交改动留在共享工作区 | 下一轮任何全工作区操作都可能带走它 |

正确做法：
1. **只 `git add <自己名下的具体文件>`**，逐个列路径；
2. 提交前 `git status --porcelain` 自查：除自己文件外不应有变化（别人的 `??`/`M` 一律不碰、不提交）；
3. **改完立刻提交**，不要攒；
4. 回退自己改动用 `git checkout -- <你那个文件>`（单文件），**绝不用** `git reset --hard <commit>`（会连别人的已提交提交一起丢）。

---

## 8. flutter test 与本地代理

本机若有 `http_proxy/https_proxy=http://127.0.0.1:9562` 之类代理，会拦住 `flutter_tester` 的本地 WebSocket，报 `Invalid WebSocket upgrade request`（**不是代码问题**）。必须按 §5 显式置空：`HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= ALL_PROXY= all_proxy= flutter test`。

**当前测试基线（2026-10-27 实测）：884/884**（`a887c2c`/T5c 守卫后）。每次当场复测，别抄旧数字。

判定只看**最后一行** `+NNN: All tests passed!`。中间那些 `+NNN: <同一测试名>` 的重复进度行是并发打印的，不要拿其中某一行当总数。

---

## 9. 全量 `flutter test` 必须串行化（2026-10-27 实测）

同一 worktree 里两个人（或两个 worker）同时跑全量 `flutter test`，会抢 `build/native_assets/windows/sqlite3.dll` 的文件锁，先启动的那个直接把后启动的顶掉：

```
Flutter failed to delete a file at
"D:\...\aimindtree_app\build\native_assets\windows\sqlite3.dll".
The flutter tool cannot access the file.
```

**症状具有强误导性**：既没有测试失败、也没有编译错误，命令直接退出——看起来像"跑完了没输出"，极易被误读成"全绿"。实际**一条测试都没执行**。

| 规矩 | 说明 |
| --- | --- |
| 跑全量前先查进程 | `tasklist \| grep -c "dart.exe\|flutter_tester"` → 必须是 `0` |
| 看到上面那条报错 | **不要**当成通过，也不要归因于代码；等对方跑完再重跑 |
| 自己跑完立刻报数 | 报 **分子/分母 + 末行原文**，不要只说"绿了" |
| 单文件测试也受影响 | 它同样走 `native_assets` 构建；并发时倾向单跑自己那个文件、避开对方的全量窗口 |

> 这条比代理问题（§8）更容易骗人：§8 至少会报 `Invalid WebSocket upgrade request` 这种显式错误，而这条只留下一句"删不掉文件"，随后静默退场。

**想并行：`git worktree add` 在本机不可用（2026-10-27 实测）。** 新 worktree 里 `flutter pub get --offline` 直接失败：

```
Building with plugins requires symlink support.
Please enable Developer Mode in your system settings.
```

Windows 未开「开发者模式」→ 插件 symlink 拿不到权限 → 独立树编译不了。要用这条路必须先开开发者模式，否则只能串行。

---

## 10. 反向验红的正确做法：优先「结构性保证」，别改共享文件

§4 要求「护栏类改动必须证明它会红」。实践中 `e-note-t3` 用了 `git checkout -- <单文件>` 还原被临时改坏的实现——**这是 §1/§7 明令禁止的命令**，本次侥幸无害（当时工作树里只有它自己的文件），但**不能因为没出事就算合规**：窗口内若有别人的未提交改动，会一起被抹掉。

按风险从低到高，正确顺序是：

| 优先级 | 做法 | 说明 |
| --- | --- | --- |
| **① 首选** | 让用例**结构上不可能绿** | 类型断言用 `as` 而非 `is`：`doc.blocks[0] as HeadingBlock`，顺序一颠倒立刻 `TypeError`；再配一条序列化字符串断言（`markdown == '# 一\n\n> 二'`）。**不碰实现文件、不开还原窗口** |
| ② 次选 | 一次性探针文件 | 新建 `test/tmp_*_probe.dart` 写**反向断言**（断言错误顺序），跑它**必须失败**——观察到红即证明正向成立。跑完**立刻删**，确认 `git status` 无 `??` |
| ③ 最后 | 字节备份还原 | `sha256sum` 记基线 → `cp` 备份 → 改一行 → 只跑该条（`--plain-name`）→ `cp` 还原 → `sha256sum` 必须与基线一致 → `git status` 里该文件不得出现 |

**任何情况下都不许用 `git checkout --` 还原「自己刚改坏的共享文件」**——改用 `cp` 备份还原，或直接用 ① 避免动文件。

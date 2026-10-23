# AIMindTree 同步中继 · 腾讯云开发 CloudBase 版

把 AIMindTree 的多端同步中继部署到**腾讯云开发 CloudBase**（云函数 + HTTP 访问服务 +
**PostgreSQL**）。

> ## ⚠️ 先读这个：环境必须是 PostgreSQL 模式，文档型那套代码跑不起来
>
> **新开的 CloudBase 环境默认可能是 PostgreSQL 环境，不是文档型（NoSQL）环境。**
> 本服务的数据层（`db.js`）走 `app.rdb()`（PostgREST 客户端）。如果拿文档型数据库的
> 写法（`app.database()` / `db.collection()` / `db.command.gt`）部署到 PG 环境，会直接
> 报错：
>
> ```
> This environment has no document database instance. It is provisioned with
> PostgreSQL instance [postgres-xxx], so document-database actions such as
> CreateTable are not available.
> ```
>
> 本目录历史上第一版就是按文档型写的，已废弃；当前版本与
> `sync_relay_cf/schema.sql` 一一对应的 PG 表由 `cloudbase/migrations/` 下的
> migration 文件管理（主理人维护，部署前先执行）。

## 为什么要再做一个版本

原 `sync_relay_cf/`（Cloudflare Worker + D1）实测在中国大陆连不上：**系统 DNS 被投毒**
返回黑洞 IP `103.200.31.172`；改用 DoH 能拿到真实 CF IP（`172.67.169.150` /
`104.21.27.171`），但**连真 IP 也是 20 秒 TCP 超时**——这是 IP 段层面的阻断，不是配置问题。

CloudBase 是国内节点、直连可达、无需备案，个人同步用量在免费额度内。
**App 端零改动**：本服务的 HTTP 契约与 CF 版逐字一致，只需在 App 设置页把「同步服务器地址」
换成 CloudBase 的域名。两个版本可以同时存在于仓库里，按需切换。

> 数据从此存在**腾讯云**上，而不是你自己的机器或 Cloudflare。请知悉这一点再启用。

## 与 App 的契约（必须与 CF 版一致）

| 方法 | 路径 | 请求体 | 响应 |
|------|------|--------|------|
| GET  | `/` | — | `{ok:true, service:'aimindtree-sync-relay', version:'1.0.0'}` |
| POST | `/auth/register` | `{username, password}` | `{user_id, token}`（重名 409 / 弱密码 400 / 短用户名 400） |
| POST | `/auth/login`    | `{username, password}` | `{user_id, token}`（错误密码 401） |
| POST | `/sync/push` | `{device_id, envelopes:[...]}` | `{received, accepted, server_time}` |
| POST | `/sync/pull` | `{device_id, since\|null}` | `{envelopes:[...], server_time}` |
| GET  | `/sync/manifest` | — | `{count}` |

- `received` 与 `accepted` **两个字段都返回**且数值相同：新版 App 的 `HttpSyncApi` 优先读
  `received`，旧版 App 只读 `accepted`，双写避免「传成功但显示 0 条」。
- envelope 字段（与 App `SyncEnvelope` 对齐）：
  `device_id / entity_table / entity_id / op / payload / base_version / updated_at / deleted_at`。
- 服务端只存每个 `(owner_id, entity_table, entity_id)` 的**最新态**（LWW 已在 App 端完成），
  并附 `server_time`（ISO 8601 UTC，带 `Z`）；`pull` 按 `server_time > since` 过滤、
  **按 server_time 升序**返回；`since` 为空 = 全量。
- `owner_id` 来自登录令牌，不同账号数据互不串访。
- 所有 `/sync/*` 需 `Authorization: Bearer <token>`，缺失或无效 → `401 {"error":"unauthorized"}`。
- 未匹配的路径 → `404 {"error":"not found"}`。
- **`GET /` 返回 200**（CF 版是 404）。App 设置页的「测试连接」按钮会 GET 根路径，
  有这个端点才能一眼判断是否真的连上。

口令以 PBKDF2-QGB962（随机 16 字节盐、10 万次迭代、32 字节输出）存 `saltHex:hashHex`，
明文不落库；校验用常量时间比较（Node `crypto.timingSafeEqual`）。令牌是 32 字节随机十六进制。

## 数据层选型（为什么代码里是 PostgREST 而不是 SQL 字符串）

云函数里访问本环境 PostgreSQL，`@cloudbase/node-sdk` 提供的是 **`app.rdb()` 返回的
PostgREST 客户端**（supabase-js 风格）：

```js
const app = cloudbase.init({ env: 'your-env-id' });
const db = app.rdb();

// 查：from(table).select(cols, {count, head}) + eq/gt/order/range/limit
const { data, error } = await db.from('sync_users').select('id, pw_hash').eq('username', 'alice').maybeSingle();
// 批量 upsert：底层就是 INSERT ... ON CONFLICT (...) DO UPDATE
await db.from('sync_envelopes').upsert(rows, { onConflict: 'owner_id,entity_table,entity_id' });
```

查证过的其它路径与结论：

| 路径 | 结论 |
|------|------|
| `app.models.$runSQL(sql, params)` | **不可用**。官方文档原文 "MySQL data model provides two SQL query methods"，这是 **MySQL 数据模型**的 SQL 执行入口（Mustache `{{ }}` 参数、反引号表名、`UNIX_TIMESTAMP`），PG-only 环境没有 MySQL 数据模型。 |
| HTTP API `POST /v1/rdb/exec-pgsql` | **不可用**。仅管理员可调用（TC3 签名 / B 端管理员 Token / API Key），非管理员 403；云函数运行时没有管理员凭证。 |
| `pg` 驱动直连 | **不采用**。PG 环境通过 PostgREST 网关暴露，控制台不给云函数用的直连带连接串；多引一个驱动没有收益。 |
| `app.rdb()` PostgREST 客户端 | **采用**。官方 PG 系列文档（fetch / insert / upsert / update / filters / modifiers）描述的正是这套，云函数内免密（SDK 自动取环境凭证），`upsert()` 底层即 `ON CONFLICT DO UPDATE`，`onConflict` 支持逗号分隔复合列。 |

upsert 的落库语义（与 CF 版 `INSERT OR REPLACE` 等价）：PostgREST 把
`upsert(rows, { onConflict: 'owner_id,entity_table,entity_id' })` 翻成

```sql
INSERT INTO sync_envelopes (owner_id, entity_table, entity_id, device_id, op,
                            payload_json, base_version, updated_at, deleted_at, server_time)
VALUES (...), (...), ...
ON CONFLICT (owner_id, entity_table, entity_id) DO UPDATE SET
  device_id = excluded.device_id, op = excluded.op,
  payload_json = excluded.payload_json, base_version = excluded.base_version,
  updated_at = excluded.updated_at, deleted_at = excluded.deleted_at,
  server_time = excluded.server_time;
```

即冲突时**除三个主键列外全部列都更新**（主键列值本来就相同，无需更新）；
`base_version` 直接写 App 端传来的值（LWW 已在 App 端完成，服务端不比较版本）。

### 与文档型旧版的差异（迁移历史）

- **`entity_id` 不再需要 `_id` 转义**：文档型版要把 `owner_id/entity_table/entity_id`
  拼成字符串当 `_id`，而 `_id` 不允许 `. $ /` 等字符，需要百分号风格转义；PG 用
  **复合主键**，`entity_id` 原样存、原样返回，特殊字符（测试覆盖 `a.b$c/d`）无风险。
- **分页从 `skip/limit` 改为 `order + range`**，排序键从 `server_time + _id` 改为
  `server_time + entity_table + entity_id`（主键后两列，同 `server_time` 时分页不重不漏）。
- **push 从并发 20 条 `set()` 改为分块 upsert**（默认 100 条/块，`CB_PUSH_CHUNK` 可调），
  控制单次请求体大小（envelope 的 payload 可能是整篇笔记）。
- 账号/令牌表的写入从 `doc().set()` 改为 `insert()`；唯一索引（username）由 migration
  建好，重名防线与旧版一致（代码层面仍是「先查后插」）。

## 目录结构

| 文件 | 作用 |
|------|------|
| `index.js` | 云函数入口：HTTP 事件解析、路由、账号、密码散列、集成响应 |
| `db.js` | 数据访问薄适配层（所有 PostgreSQL 调用都收敛在这里，`app.rdb()` PostgREST 客户端） |
| `test_protocol.mjs` | 本地冒烟测试（node:sqlite 内存库 + PostgREST 翻译层，不联网、不装驱动） |
| `package.json` | 依赖：仅 `@cloudbase/node-sdk`（`rdb()` 自带 PG 访问，无需 `pg`） |
| `cloudbase/migrations/` | 建表 migration（主理人维护，本目录代码不创建/修改它） |

## 本地自测（不需要腾讯云账号）

```bash
node test_protocol.mjs
```

用一个「node:sqlite 内存库 + PostgREST 翻译层」替换真实的 `app.rdb()` 客户端：翻译层把
`from(table).select().eq().order().range()` / `insert()` / `upsert(rows, {onConflict})`
翻成等价的 SQLite SQL（含 `ON CONFLICT (...) DO UPDATE SET ... = excluded.*`）由 SQLite
真执行——唯一索引、复合主键、分页边界都是引擎级验证。建表 DDL 与
`cloudbase/migrations/` 里的 PG 语句一致（SQLite 与 PG 的这部分方言相同）。

覆盖：根路径健康检查、注册/登录/重名/弱密码/短用户名/错误密码/非法 JSON、
未鉴权 401、push→manifest→pull 往返、upsert 覆盖、`since` 增量、多租户隔离、
**批量 push 1200 条时 pull 能取回全部 1200 条**（验证分页逻辑）、
`entity_id` 含 `. $ /` 时复合主键 upsert 仍然正确。全绿退出码 0，失败退出码 1。

## CloudBase HTTP 访问服务契约（代码按这个写的）

参考文档：

- [通过 HTTP 访问云函数](https://docs.cloudbase.net/service/access-cloud-function)
- [编写普通云函数（集成响应）](https://docs.cloudbase.net/cloud-function/how-coding)
- [node-sdk PostgreSQL · 查询数据](https://docs.cloudbase.net/api-reference/server/node-sdk/postgresql/fetch)
- [node-sdk PostgreSQL · 新增数据（含 upsert）](https://docs.cloudbase.net/api-reference/server/node-sdk/postgresql/upsert)
- [node-sdk PostgreSQL · 过滤器](https://docs.cloudbase.net/api-reference/server/node-sdk/postgresql/filters)
- [node-sdk PostgreSQL · 修饰符（order/limit/range）](https://docs.cloudbase.net/api-reference/server/node-sdk/postgresql/modifiers)
- [初始化（CloudBase 初始化 / 环境 ID）](https://cloud.tencent.com/document/product/876/19363)
- [环境信息（SYMBOL_CURRENT_ENV / parseContext）](https://docs.cloudbase.net/api-reference/server/node-sdk/env)

### 入口 `exports.main = async (event, context)` 收到的 `event`

官方文档给出的字段：

```js
{
  path,                  // HTTP 请求路径，如 /api/hello
  httpMethod,            // HTTP 方法，如 GET、POST、PUT、DELETE
  headers,               // 请求头对象
  queryStringParameters, // URL 查询参数对象
  body,                  // 请求体内容（字符串格式）
  isBase64Encoded,       // body 是否为 Base64 编码
  requestContext         // 云开发环境相关信息
}
```

本实现据此做的处理：

- 路径用 `path`；为兼容把触发路径绑成非 `/` 的情况，路由一律用 `endsWith('/auth/login')`
  这种后缀匹配（与 CF 版写法一致），并可把触发路径配到环境变量 `CB_BASE_PATH` 上，
  使 `GET <CB_BASE_PATH>` 被识别为健康检查的根请求。
- 请求头统一转成小写键后再读（网关大小写不确定）。
- `isBase64Encoded` 为真时先 `Buffer.from(body, 'base64')` 解码再 `JSON.parse`。

### 返回值（集成响应）

文档明确：**返回值里只要包含 `statusCode` 字段，就会被识别为集成响应**。

```js
{
  statusCode: 200,               // 必填，HTTP 状态码
  headers: { 'Content-Type': 'application/json; charset=utf-8', ... }, // 可选
  body: '{"ok":true}',           // 可选，响应体字符串
  isBase64Encoded: false         // 可选，body 是否为 Base64
}
```

> 注意：网关的 `headers` 不支持 `Location` key（我们不重定向，不受影响）。
> 若返回普通对象（不含 `statusCode`），网关会按 200 + `application/json` 兜底处理。

### 环境 ID 注入

文档原文：「从 v3 版本开始，如在初始化 `init({})` 未指定 env 参数，则默认使用当前云函数
环境 ID」；另有 `tcb.SYMBOL_CURRENT_ENV` 表示「取当前云函数所在环境」，云函数运行时也会把
环境 ID 注入到环境变量（可用 `tcb.parseContext(context)` 解析 `context` 查看，其中包含
用户自定义环境变量）。云函数内调用**无需** `secretId`/`secretKey`。

本实现的做法（`index.js` 的 `getStore()`）：优先读 `process.env.TCB_ENV`，
否则用 `tcb.SYMBOL_CURRENT_ENV`，两者都没有时交给 SDK 默认行为；拿到 `app` 后取
`app.rdb()`（**不是** `app.database()`，后者是文档型入口，PG 环境会报错）。

### PostgreSQL 访问与分页

- PG 本身没有文档库那种单次 100/1000 条上限，但一次全量 pull 可能上千条，
  `pullSince()` 仍用 `order + range` 循环翻页取干净；默认每页 100 条
  （`CB_PAGE_SIZE` 可调，硬上限 1000）。
- 三级排序 `server_time + entity_table + entity_id`：同一批 push 的 `server_time`
  完全相同，PG 不保证同值行的稳定序，只按时间排会让分页边界不确定（漏/重），
  加上主键后两列兜底。测试里用 1200 条验证过不重不漏。
- `manifest` 用 `select('*', { count: 'exact', head: true })`，底层是 `COUNT(*)`。

## 部署步骤（手把手）

> 全程在浏览器控制台操作，**不需要买服务器**。全程约 10 分钟。

### 1. 开通腾讯云开发 CloudBase（PostgreSQL 环境）

1. 打开 https://tcb.cloud.tencent.com/ ，用微信或腾讯云账号登录。
2. 新建环境：填环境名称（如 `aimindtree`），计费方式选**按量计费**（有免费额度，用多少算多少，
   不用不扣钱），地域选离你近的（如 `上海`）。
3. 记下环境 ID（形如 `mindtree-d7glv6crkd8e9fba9`），后面会用到。
4. **确认数据库类型是 PostgreSQL**（控制台「数据库」里应看到 PG 控制台入口，而不是
   「文档型数据库」的集合管理）。本仓库 `cloudbase/migrations/` 下的 migration 就是按
   PG 写的；如果环境是文档型，要么换环境，要么改用文档型版代码（已废弃，不在本目录）。

### 2. 执行 migration 建表

表结构由 `cloudbase/migrations/` 下的 migration 文件管理（`sync_envelopes` /
`sync_users` / `sync_tokens` 三张表 + 相应索引，与 `sync_relay_cf/schema.sql` 一一对应）。
部署时先按主理人的方式把 migration 应用到目标环境（控制台 PG 的 SQL 窗口或
CloudBase MCP 的 migration 工具均可）。**不要在文档型数据库的「集合」界面找这三张表——
它们是 PG 里的真表，不是集合。**

> 也可以手工在 PG 控制台执行 migration 文件里的 SQL；索引（含 `sync_users.username`
> 唯一索引）由 migration 一并建好，无需再手工建。

### 3. 本地准备代码

```bash
cd sync_relay_cn
npm i                     # 只装 @cloudbase/node-sdk（自带 rdb()，不需要 pg）
node test_protocol.mjs    # 可选：确认本地全绿
```

### 4. 打包成 zip（必须带上 node_modules）

Windows PowerShell：

```powershell
Compress-Archive -Path index.js, db.js, package.json, package-lock.json, node_modules -DestinationPath sync-relay-cn.zip -Force
```

macOS / Linux：

```bash
zip -r sync-relay-cn.zip index.js db.js package.json package-lock.json node_modules
```

> 在资源管理器里手动压缩也行：**选中上面那几项 → 右键 → 压缩**。注意是选中文件夹+文件压缩，
> 不要把 `sync_relay_cn` 整个外层目录压进去（那样云函数里会多一层目录，入口找不到）。
> `test_protocol.mjs` / `README.md` 不需要打进 zip。

### 5. 上传云函数

1. 控制台左侧「云函数」→ 「新建云函数」。
2. 函数名：`aimindtree-sync-relay`（随便起，记住就行）。
3. 创建方式选**本地上传 zip 包**（或「上传文件夹」），运行环境选 `Nodejs 18/20/22`。
4. 选刚才打包的 `sync-relay-cn.zip`，上传。
5. （可选）在云函数「函数配置 → 环境变量」里设置：
   - `CB_PAGE_SIZE=1000` 减少 pull 分页轮次；
   - `CB_PUSH_CHUNK=100`（默认）控制单次 upsert 请求体大小；
   - 若 HTTP 触发路径不是 `/`，加 `CB_BASE_PATH=/你的触发路径`。
6. （可选）把函数内存调到 256MB、超时调到 30 秒，大量首次上传时更从容。

### 6. 开启 HTTP 访问服务，拿到域名

1. 进入刚建的云函数详情页，找到「HTTP 访问服务」/「自定义域名」模块，点「添加域名」。
2. **触发路径填 `/`**（表示所有路径都转给这个函数）。
3. 域名选**默认域名**（形如 `https://<环境ID>.<地域>.app.tcloudbase.com`），
   也可以选自定义域名（需备案）。
4. 确认后拿到完整地址，例如：
   `https://mindtree-d7glv6crkd8e9fba9.ap-shanghai.app.tcloudbase.com`

### 7. 先验证，再填进 App

**在浏览器或命令行里先打开根路径**，确认能看到健康检查响应：

```bash
curl https://mindtree-d7glv6crkd8e9fba9.ap-shanghai.app.tcloudbase.com/
```

应该看到：

```json
{"ok":true,"service":"aimindtree-sync-relay","version":"1.0.0"}
```

看到这个再往下走。如果这一步就不通（超时 / 404 / 不是这个 JSON），先别填 App——
问题在中继侧，可以再跑一遍第 6 步确认触发路径和域名。

顺手验一下注册（把地址换成你自己的）：

```bash
curl -X POST https://<你的域名>/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"test","password":"test12345"}'
```

应返回 `{"user_id":"u_...","token":"<64位十六进制>"}`。

### 8. 填进 App

设置页 → 同步 → 「同步服务器地址」，填上面拿到的域名（**不带结尾斜杠**，例如
`https://mindtree-d7glv6crkd8e9fba9.ap-shanghai.app.tcloudbase.com`），
然后用 App 里的账号密码注册/登录，正常上传下载即可。

## 费用与免责

- CloudBase 按量计费有**免费额度**（云函数调用次数、资源使用量、数据库读写次数、存储容量
  各有一部分免费额度，额度随时间可能调整，请以控制台「费用中心 / 免费额度」为准）。
  个人双端同步每天几十次调用，基本落在免费额度内。
- **超出**免费额度会按量计费（金额很小但确实会产生）。建议在控制台配一个**费用告警**。
- **数据存放在腾讯云上**：笔记内容是明文存进 `sync_envelopes` 的（App 端没做端到端加密）。
  介意的话请不要使用云端同步，继续用本地 `llm_server` 方案。
- 本中继没有任何删除接口，数据不会自动过期，长期不用建议在 PG 控制台直接
  `TRUNCATE sync_envelopes;`（或删环境）清空。

## 已知与 CF 版的差异

| 项 | CF 版（worker.js） | 本版 |
|----|-------------------|------|
| `GET /` | 404 | **200 + 服务标识**（App「测试连接」需要） |
| 密码散列实现 | Web Crypto `crypto.subtle`（`PBKDF2` + `SHA-256`，异步） | Node 内置 `crypto.pbkdf2Sync`（`sha256`，同步） |
| 密码散列参数 | 随机 16 字节盐、10 万次迭代、256 bit 输出 → `saltHex:hashHex` | **完全一致**（同一个 PBKDF2 编码结论，与迭代次数/盐长无关地互通） |
| 数据库 | D1（SQLite） | PostgreSQL（`app.rdb()` PostgREST 客户端） |
| upsert 写法 | `INSERT OR REPLACE` | `upsert(rows, {onConflict})` → `ON CONFLICT ... DO UPDATE` |
| `entity_id` 特殊字符 | SQLite text 直接存 | 复合主键直接存（**不再需要** `_id` 转义） |
| 全量拉取 | D1 无条数上限 | PG 无硬上限，仍按 100 条/页 `range` 翻页（网关行为保守起见） |
| 排序键 | `server_time` | `server_time + entity_table + entity_id`（同值分页确定性） |

其余（路径、请求/响应字段、错误文案、鉴权方式）完全一致。

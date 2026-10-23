# AIMindTree 同步中继 · 腾讯云开发 CloudBase 版

把 AIMindTree 的多端同步中继部署到**腾讯云开发 CloudBase**（云函数 + HTTP 访问服务 +
云数据库文档型）。

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

口令以 PBKDF2-SHA256（随机 16 字节盐、10 万次迭代、32 字节输出）存 `saltHex:hashHex`，
明文不落库；校验用常量时间比较（Node `crypto.timingSafeEqual`）。令牌是 32 字节随机十六进制。

## 目录结构

| 文件 | 作用 |
|------|------|
| `index.js` | 云函数入口：HTTP 事件解析、路由、账号、密码散列、集成响应 |
| `db.js` | 数据访问薄适配层（所有云数据库调用都收敛在这里） |
| `test_protocol.mjs` | 本地冒烟测试（内存 mock 替换数据库，不联网） |
| `package.json` | 依赖：仅 `@cloudbase/node-sdk` |

## 本地自测（不需要腾讯云账号）

```bash
node test_protocol.mjs
```

用一个内存版「文档型数据库」替换真实的 `app.database()` 句柄，直接驱动 `index.js`，
覆盖：根路径健康检查、注册/登录/重名/弱密码/短用户名/错误密码/非法 JSON、
未鉴权 401、push→manifest→pull 往返、upsert 覆盖、`since` 增量、多租户隔离、
**批量 push 1200 条时 pull 能取回全部 1200 条**（验证分页逻辑）、
`entity_id` 含 `. $ /` 时主键转义仍然正确。全绿退出码 0，失败退出码 1。

## CloudBase HTTP 访问服务契约（代码按这个写的）

参考文档：

- [通过 HTTP 访问云函数](https://docs.cloudbase.net/service/access-cloud-function)
- [编写普通云函数（集成响应）](https://docs.cloudbase.net/cloud-function/how-coding)
- [初始化（CloudBase 初始化 / 环境 ID）](https://cloud.tencent.com/document/product/876/19363)
- [环境信息（SYMBOL_CURRENT_ENV / parseContext）](https://docs.cloudbase.net/api-reference/server/node-sdk/env)
- [node-sdk 数据库 API](https://github.com/TencentCloudBase/node-sdk/blob/master/docs/database/database.md)
- [索引管理](https://docs.cloudbase.net/model/data-index) / [数据库 FAQ](https://cloud.tencent.com.cn/document/faq/876/18436)

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
否则用 `tcb.SYMBOL_CURRENT_ENV`，两者都没有时交给 SDK 默认行为。

### 云数据库 `get()` 的条数上限 —— 以及分页处理

**文档口径不一致，代码按保守值实现：**

- 官方「增删改查」文档：`limit()` **默认 100 条，最多 1000 条**；
- node-sdk 仓库文档：`get()`「如不指定 limit 则默认取前 100 条数据，**且最大取前 100 条**」；
- 腾讯云 FAQ / 社区口径：「服务端（云函数）默认及最大上限为 1000」。

结论：**默认 100 条是确定的**，所以全量拉取必须自己翻页。
`db.js` 的 `pullSince()` 用 `skip()` + `limit()` 循环分页把结果取干净：

```js
for (let skip = 0; ; skip += pageSize) {
  const res = await col.where(cond)
    .orderBy('server_time', 'asc').orderBy('_id', 'asc')
    .skip(skip).limit(pageSize).get();
  const rows = res.data || [];
  out.push(...rows);
  if (rows.length < pageSize) break;
}
```

- 默认 `pageSize = 100`（对两种口径都安全），可用环境变量 `CB_PAGE_SIZE` 调大，硬上限 1000。
- **二级排序 `server_time` + `_id`**：同一批 push 的 `server_time` 完全相同，只按时间排序
  会让分页边界不确定（漏/重），加上 `_id` 兜底保证翻页不重不漏。测试里用 1200 条验证过。

## 部署步骤（手把手）

> 全程在浏览器控制台操作，**不需要买服务器**。全程约 10 分钟。

### 1. 开通腾讯云开发 CloudBase

1. 打开 https://tcb.cloud.tencent.com/ ，用微信或腾讯云账号登录。
2. 新建环境：填环境名称（如 `aimindtree`），计费方式选**按量计费**（有免费额度，用多少算多少，
   不用不扣钱），地域选离你近的（如 `上海`）。
3. 记下环境 ID（形如 `aimindtree-1x3j5k2f8b9c0d`），后面会用到。

### 2. 创建 3 个集合（数据库 → 文档型）

在左侧「数据库」，点「新建集合」，依次创建三个（**注意名字必须完全一致**）：

1. `sync_envelopes` —— 存同步数据（每条笔记/知识点的最新态）
2. `sync_users`     —— 存账号
3. `sync_tokens`    —— 存登录令牌

> 也可以用一个临时云函数跑 `db.createCollection('sync_envelopes')` 来建集合，
> 但**索引必须在控制台手工建**（见下一步），所以直接建集合更省事。

### 3. 建索引（重要：不建索引数据多了会慢到不可用）

进入每个集合 → 「索引管理」→ 「新建索引」：

| 集合 | 索引字段（按顺序） | 是否唯一 | 排序 | 用途 |
|------|------------------|---------|------|------|
| `sync_envelopes` | `owner_id` + `server_time` | 非唯一 | 升序 | pull / manifest 按用户+时间过滤排序 |
| `sync_users` | `username` | **唯一** | 升序 | 防止重名注册 |
| `sync_tokens` | `token` | 唯一 | 升序 | Bearer 令牌查 owner |

> 说明：本实现把 `user_id` 当作 `sync_users` 文档的 `_id`、把明文令牌当作 `sync_tokens`
> 文档的 `_id`，天然享有主键索引；上表中 `sync_tokens.token` 一条可以不建（`token` 字段
> 与 `_id` 同值），建了也无害。`sync_envelopes` 的 `(owner_id, server_time)` 组合索引必建。
>
> 限制（官方 FAQ）：每个集合最多 100 个索引，每个索引最多 31 个字段。
> 另外，重名的最终防线是唯一索引——并发注册同一用户名时仍存在极小的时间窗，
> 真要严格保证请以 CloudBase 唯一索引为准（代码层面是「先查后插」）。

### 4. 本地准备代码

```bash
cd sync_relay_cn
npm i                     # 只装 @cloudbase/node-sdk
node test_protocol.mjs    # 可选：确认本地全绿
```

### 5. 打包成 zip（必须带上 node_modules）

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

### 6. 上传云函数

1. 控制台左侧「云函数」→ 「新建云函数」。
2. 函数名：`aimindtree-sync-relay`（随便起，记住就行）。
3. 创建方式选**本地上传 zip 包**（或「上传文件夹」），运行环境选 `Nodejs 16/18`。
4. 选刚才打包的 `sync-relay-cn.zip`，上传。
5. （可选）在云函数「函数配置 → 环境变量」里设置 `CB_PAGE_SIZE=1000` 以减少分页轮次；
   若 HTTP 触发路径不是 `/`，再加一个 `CB_BASE_PATH=/你的触发路径`。
6. （可选）把函数内存调到 256MB、超时调到 30 秒，大量首次上传时更从容。

### 7. 开启 HTTP 访问服务，拿到域名

1. 进入刚建的云函数详情页，找到「HTTP 访问服务」/「自定义域名」模块，点「添加域名」。
2. **触发路径填 `/`**（表示所有路径都转给这个函数）。
3. 域名选**默认域名**（形如 `https://<环境ID>.<地域>.app.tcloudbase.com`），
   也可以选自定义域名（需备案）。
4. 确认后拿到完整地址，例如：
   `https://aimindtree-1x3j5k2f8b9c0d.ap-shanghai.app.tcloudbase.com`

### 8. 先验证，再填进 App

**在浏览器或命令行里先打开根路径**，确认能看到健康检查响应：

```bash
curl https://aimindtree-1x3j5k2f8b9c0d.ap-shanghai.app.tcloudbase.com/
```

应该看到：

```json
{"ok":true,"service":"aimindtree-sync-relay","version":"1.0.0"}
```

看到这个再往下走。如果这一步就不通（超时 / 404 / 不是这个 JSON），先别填 App——
问题在中继侧，可以再跑一遍第 7 步确认触发路径和域名。

顺手验一下注册（把地址换成你自己的）：

```bash
curl -X POST https://<你的域名>/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"test","password":"test12345"}'
```

应返回 `{"user_id":"u_...","token":"<64位十六进制>"}`。

### 9. 填进 App

设置页 → 同步 → 「同步服务器地址」，填上面拿到的域名（**不带结尾斜杠**，例如
`https://aimindtree-1x3j5k2f8b9c0d.ap-shanghai.app.tcloudbase.com`），
然后用 App 里的账号密码注册/登录，正常上传下载即可。

## 费用与免责

- CloudBase 按量计费有**免费额度**（云函数调用次数、资源使用量、数据库读写次数、存储容量
  各有一部分免费额度，额度随时间可能调整，请以控制台「费用中心 / 免费额度」为准）。
  个人双端同步每天几十次调用，基本落在免费额度内。
- **超出**免费额度会按量计费（金额很小但确实会产生）。建议在控制台配一个**费用告警**。
- **数据存放在腾讯云上**：笔记内容是明文存进 `sync_envelopes` 的（App 端没做端到端加密）。
  介意的话请不要使用云端同步，继续用本地 `llm_server` 方案。
- 本中继没有任何删除接口，数据不会自动过期，长期不用建议在控制台直接删集合清空。

## 已知与 CF 版的差异

| 项 | CF 版（worker.js） | 本版 |
|----|-------------------|------|
| `GET /` | 404 | **200 + 服务标识**（App「测试连接」需要） |
| 密码散列算法名 | 源码里写成了非标准算法名（Web Crypto 只认 `PBKDF2`，实跑会 500） | `PBKDF2-SHA256`，Node 内置 crypto，100000 迭代 / 16 字节盐 / 32 字节输出 |
| 全量拉取 | D1 无条数上限 | 云数据库单次 `get()` 默认 100 条，**循环分页取回全部** |
| 单条记录大小 | SQLite text | 文档型限制单文档 16 MB（envelope 远小于此） |

其余（路径、请求/响应字段、错误文案、鉴权方式、排序规则）完全一致。

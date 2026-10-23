# AIMindTree 同步中继 · Vercel 版

把 AIMindTree 的多端同步中继部署到 **Vercel Serverless Functions + Vercel KV
（Upstash Redis）**。

## 为什么要再做一个版本

项目里已有两个同步中继，HTTP 契约逐字一致（App 端零改动，只换「同步服务器地址」）：

| 版本 | 目录 | 状态 |
|------|------|------|
| Cloudflare Worker + D1 | `sync_relay_cf/` | 权威契约；**实测在中国大陆连不上**（IP 段层阻断） |
| 腾讯云 CloudBase 云函数 | `sync_relay_cn/` | 国内直连可达，已交付 |
| **Vercel Functions + KV（本版）** | `sync_relay_vercel/` | 免费额度、部署最简单（纯 Web 控制台），作为第三个可选后端 |

选 Vercel KV 而不是别的存储，是因为 Redis 的 **ZSET 天然适合「按时间游标增量拉取」**
这种 KV 语义（见下面「数据在 Redis 里长什么样」）。

> **数据从此存在 Vercel / Upstash 上**，而不是你自己的机器。笔记内容是明文存进去的
> （App 端没做端到端加密）。介意的话请不要使用云端同步，继续用本地 `llm_server` 方案。

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
- 所有 `/sync/*` 需 `Authorization: Bearer <token>`（前缀大小写不敏感），
  缺失或无效 → `401 {"error":"unauthorized"}`。
- 未匹配的路径 → `404 {"error":"not found"}`；非法 JSON 请求体 → `400 {"error":"invalid json"}`。
- **`GET /` 返回 200**（CF 版是 404）。App 设置页的「测试连接」会 GET 根路径，
  有这个端点才能一眼判断是否真的连上。

口令以 PBKDF2-SHA256（随机 16 字节盐、10 万次迭代、32 字节输出）存 `saltHex:hashHex`，
明文不落库；校验用常量时间比较（Node `crypto.timingSafeEqual`）。令牌是 32 字节随机十六进制。
**参数与 CF 版完全一致**，两个后端的账号哈希可互相移植。

## 数据在 Redis 里长什么样

与 CF 版 `schema.sql` 三张表一一对应：

| CF 版表 | Redis 结构 | 说明 |
|---------|-----------|------|
| `sync_users` | HASH `sync:users` | field=username，value=账号 JSON |
| `sync_tokens` | HASH `sync:tokens` | field=明文令牌，value=`{userId, createdAt}` |
| `sync_envelopes` | HASH `sync:env:{ownerId}` + ZSET `sync:z:{ownerId}` | 见下 |

envelope 拆成两个 key，各司其职：

- **HASH `sync:env:{ownerId}`**：field=转义后的 `table__entity`，value=文档 JSON
  （payload 以 JSON **字符串**存，与 CF 版一致）。HSET 同 field 即覆盖，
  实现「每个 (owner, table, entity) 只保留最新态」的 upsert 语义（≈ D1 的
  `INSERT OR REPLACE`）。
- **ZSET `sync:z:{ownerId}`**：member=同一个转义键，**score = `Date.parse(server_time)`**
  （ISO 8601 UTC 的毫秒数）。这就是增量游标，≈ D1 的
  `WHERE server_time > since ORDER BY server_time`。

两个关键点（代码里有详细注释）：

1. **score 是数字、member 必须唯一**。同一批 push 的 `server_time` 可能完全相同，
   member 用 `table__entity`（天然唯一）而不是带时间的内容，ZSET 排序才是全序，
   `LIMIT offset count` 翻页才不重不漏。重复 push 同一个 key 时，ZADD 只刷新
   score（游标后移），不会多出一条。
2. **转义**。`entity_id` 可能含 `. $ / \` 等字符，且 member 是拼接出来的，
   所以对 `table` / `entity` 两段做百分号转义（`%` 自身先转义，可逆），
   分隔符 `_` 也一起转义——否则 `('notes__x', 'y')` 和 `('notes', 'x__y')`
   会撞到同一个 member。原值以独立字段存在文档里，返回给 App 的永远是原值。

写入按块走 `multi()` 事务（默认 100 条/块）：每个事务里 HSET + ZADD 同时生效，
不会出现「hash 有、zset 无」导致 pull 漏数据。

## 本地自测（不需要 Vercel 账号、不联网）

```bash
cd sync_relay_vercel
node test_protocol.mjs
```

用一个内存版 Redis mock 替换真实客户端，直接驱动 `core.js`，并在装了依赖时
额外驱动真实的 `api/[[...path]].js`（Web `Request` → `Response` 适配层）。
覆盖：根路径健康检查、注册/登录/重名/弱密码/短用户名/错误密码/非法 JSON、
未鉴权 401、小写 bearer、旧令牌有效、push→manifest→pull 往返、upsert 覆盖、
`since` 增量、多租户隔离、server_time 升序、**批量 push 1200 条 pull 取回全部 1200 条
且无重复**（验证翻页）、`SYNC_PULL_PAGE_SIZE` / `SYNC_WRITE_CHUNK` 调参、
`entity_id` 含 `. $ / _` 时覆盖与原值返回、KV 未绑定时入口返回可读 503。
全绿退出码 0，失败退出码 1。

**没有执行 `npm i` 也能跑**：核心用例（66 条）不依赖 `@vercel/kv` 真实包，
入口级用例会自动跳过并提示。

## 部署步骤（手把手，全程浏览器操作）

> 不需要买服务器，全程约 10 分钟。个人双端同步用量在免费额度内。

### 1. 注册 / 登录 Vercel

打开 https://vercel.com/ ，用 GitHub / GitLab / Bitbucket 或邮箱登录（Hobby 免费版即可）。

### 2. 导入本项目

1. 控制台右上 **Add New… → Project**。
2. 选择**本仓库**（`AIMindTree`）并授权 Vercel 读取。
3. **Root Directory 选 `sync_relay_vercel`**（重要：这个目录才是 Vercel 项目根，
   里面有 `package.json` 和 `api/`）。
4. Framework Preset 选 **Other**（没有框架，就是几个 Serverless Functions）。
5. 先**不要**点 Deploy——下一步建 KV 更省事（先部署也能后绑，见第 4 步）。

### 3. 创建 KV 数据库并绑定（不绑服务起不来）

1. 顶部切到 **Storage** 标签 → **Create Database** → 选 **KV**（Upstash Redis）。
2. 起个名（如 `aimindtree-sync`），地域选离你近的（如 `Singapore` / `Tokyo`，
   国内访问 `Singapore` 通常好些），创建。
3. 创建后在 KV 详情页点 **Connect**（或项目页 Storage 里 **Connect Project**），
   选中第 2 步的项目，确认绑定。
4. 绑定后平台会**自动注入**环境变量 `KV_REST_API_URL` / `KV_REST_API_TOKEN`，
   代码里不需要填任何密钥。到项目 **Settings → Environment Variables** 能看到这两个
   变量即算绑好。

### 4. 部署

回到项目页点 **Deploy**。等一两分钟出现 `Ready` 后拿到域名，形如
`https://aimindtree-sync-relay-xxx.vercel.app`。

> 部署时没绑 KV 也不会报错，但服务不可用——见下一步怎么判断。

### 5. 先验证，再填进 App

**在浏览器或命令行里先打开根路径**：

```bash
curl https://<你的域名>.vercel.app/
```

正常应该看到：

```json
{"ok":true,"service":"aimindtree-sync-relay","version":"1.0.0"}
```

**如果返回 `503` 且 `{"ok":false, ..., "error":"KV 未绑定：..."}`**，说明 KV 没绑好：
回第 3 步把 KV 连到项目，然后在项目页 **Deployments → 最新部署 → Redeploy**
（环境变量变更需要重新部署才生效）。看到 `{"ok":true,...}` 再往下走。

顺手验一下注册（把地址换成你自己的）：

```bash
curl -X POST https://<你的域名>.vercel.app/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"test","password":"test12345"}'
```

应返回 `{"user_id":"u_...","token":"<64位十六进制>"}`。

### 6. 填进 App

设置页 → 同步 → 「同步服务器地址」，填上面拿到的域名（**不带结尾斜杠**），
然后用 App 里的账号密码注册/登录，正常上传下载即可。

> 也可以先用命令行部署（可选）：装 `npm i -g vercel`，在 `sync_relay_vercel/` 里
> 跑 `vercel` 按提示绑定项目，KV 仍在控制台 Storage 里建并 Connect。

## 环境变量

| 变量 | 来源 | 说明 |
|------|------|------|
| `KV_REST_API_URL` / `KV_REST_API_TOKEN` | 绑定 KV 后平台自动注入 | 必填；缺失时服务返回 503 + 可读指引 |
| `SYNC_PULL_PAGE_SIZE` | 可选，默认 100 | 单次 `zrange` 分页大小（pull 循环翻页取全量） |
| `SYNC_WRITE_CHUNK` | 可选，默认 100 | 单个 `multi()` 事务写入的 envelope 条数 |

函数时长在 `vercel.json` 里设为 30 秒（默认 10 秒）：首次全量拉取上千条时
翻页 + Upstash 往返需要点时间。Hobby 版的上限以控制台为准，超出会部署报错，
可把 30 改小。

## 费用与免责

- Vercel **Hobby（免费版）**即可运行；Vercel KV 由 Upstash 提供，有免费额度
  （存储容量 + 每月命令数，个人双端同步每天几十次调用，远低于限额）。
  **具体数字以官方为准**：https://vercel.com/docs/storage/vercel-kv 、
  https://upstash.com/pricing 。超出免费额度会产生费用，建议在 Vercel /
  Upstash 控制台配费用告警。
- **`*.vercel.app` 域名在中国大陆的可达性不稳定**：这是事实，不是配置问题——
  部分地区/运营商会超时或被重置，与 Cloudflare 版被阻断同源。如果实测连不上，
  请改用 `sync_relay_cn`（腾讯云 CloudBase，国内直连）或本地 `llm_server` 方案；
  也可以给 Vercel 项目绑自己的域名（需备案）改善可达性。
- **数据存放在 Vercel / Upstash 的 Redis 上**，明文存储，无自动过期。
  长期不用建议在 KV 控制台直接删数据（或删整个数据库）。
- 本中继没有任何删除接口，账号密码忘记即无法恢复数据。

## 已知与 CF 版的差异

| 项 | CF 版（worker.js） | 本版 |
|----|-------------------|------|
| `GET /` | 404 | **200 + 服务标识**（App「测试连接」需要） |
| 存储 | D1（SQLite） | Vercel KV（Upstash Redis）：HASH 存文档 + ZSET 存时间游标 |
| 增量游标 | SQL `server_time > since`（字符串比较） | ZSET score 开区间 `(sinceMs +inf`（毫秒数比较）。语义等价：`server_time` 恒为 ISO 8601 UTC，字符串比较与毫秒比较同序 |
| 批量 push 原子性 | D1 `batch()` 单事务 | 按块 `multi()` 事务（默认 100 条/块）。块间非原子，中途失败前几块已生效——App 侧 push 是幂等 upsert，重推同一批即收敛 |
| 重名注册 | 唯一索引兜底 | 「先查后插」+ `HSETNX` 原子占位（等价唯一索引） |
| 密码散列实现 | Web Crypto（异步） | Node `crypto.pbkdf2Sync`（同步，**参数完全一致**，哈希值互通） |
| 单条记录大小 | SQLite text 无上限 | Upstash value 上限 1 MB（envelope 远小于此；payload 超大时会写失败并回 500） |
| 全量拉取 | D1 无条数上限 | `zrange` 分页循环取回全部（`LIMIT offset count`，member 唯一保证不重不漏） |

其余（路径、请求/响应字段、错误文案、鉴权方式、排序规则、双计数字段）完全一致。

## 目录结构

| 文件 | 作用 |
|------|------|
| `api/[[...path]].js` | Vercel 入口（catch-all 函数）：Web `Request` → core → `Response`；KV 未绑定时返回可读 503 |
| `core.js` | 平台无关的路由 / 账号 / 同步逻辑（输入 `{method, path, headers, body}`，输出 `{status, headers, body}`） |
| `db.js` | 数据访问薄适配层（所有 Redis 调用都收敛在这里；不 import `@vercel/kv`，客户端由调用方注入） |
| `test_protocol.mjs` | 本地冒烟测试（内存 Redis mock，不联网） |
| `package.json` | 依赖：仅 `@vercel/kv` |
| `vercel.json` | 函数 `maxDuration: 30` |

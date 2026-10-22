# AIMindTree 同步中继（方案 B：Cloudflare Worker + D1）

把 AIMindTree 的多端同步中继部署到 **Cloudflare Workers + D1**，作为方案 A
（并进本地 `llm_server`）的可选免费云端后端。两个方案**共用同一份 App 端契约**
（见 `aimindtree_app/lib/data/sync/sync_api.dart`），App 端通过「同步」设置页的
4 个按钮分别指向 `llm_server` 或 `CF`。

## 为什么是 Cloudflare

- 免费额度充足：Workers 10 万次请求/天、D1 5 GB 存储（个人同步绰绰有余）；
- 全球边缘节点，国内/海外延迟都比「本机 llm_server」更适合跨设备；
- 无需自建服务器，部署一条命令。

> 方案 A（本地 llm_server）适合开发期与完全私有化；方案 B（CF）适合真机跨设备。
> App 端两套配置独立，可同时配置、按需点对应按钮。

## 与 App 的契约（必须一致）

| 方法 | 路径 | 请求体 | 响应 |
|------|------|--------|------|
| POST | `/auth/register` | `{username, password}` | `{user_id, token}`（重名 409 / 弱密码 400） |
| POST | `/auth/login`    | `{username, password}` | `{user_id, token}`（错误密码 401） |
| POST | `/sync/push` | `{device_id, envelopes:[...]}` | `{received, server_time}` |
| POST | `/sync/pull` | `{device_id, since\|null}` | `{envelopes:[...], server_time}` |
| GET  | `/sync/manifest` | — | `{count}` |

envelope 字段（与 App `SyncEnvelope` 对齐）：
`device_id / entity_table / entity_id / op / payload / base_version /
updated_at / deleted_at`。

D1 表只存每个 `(owner_id, entity_table, entity_id)` 的**最新态**——LWW 已在 App 端完成，
服务端只保存最新态 + `server_time` 供增量拉取（`pull` 按 `server_time > since`
过滤，`since` 为空 = 全量）。`owner_id` 来自登录令牌，保证不同用户数据互不串访。

密码以 PBKDF2-SHA256（随机盐 + 10 万次迭代）哈希存储，明文不落库。
`sync/*` 路由均须带 `Authorization: Bearer <token>`，否则 401。

## 本地自测（无需 wrangler / D1）

用内存版 D1 模拟直接驱动 `worker.js` 的 `fetch`，验证 push→pull→manifest 链路：

```bash
node test_worker.mjs
```

覆盖：空 token 放行 / 设 token 后 401 / push 计数 / manifest 计数 / pull 全量 /
INSERT OR REPLACE 覆盖同 key / since 增量过滤 / 404。

## 部署到 Cloudflare

1. 安装 wrangler：`npm i -g wrangler`（或 `npx wrangler`）。
2. 登录：`wrangler login`。
3. 建 D1 数据库，记下返回的 `database_id`：
   ```bash
   wrangler d1 create aimindtree_sync
   ```
4. 把 `wrangler.toml` 里的 `database_id` 改成上一步的值。
5. 建表（含账号表 + 每用户命名空间）：
   ```bash
   wrangler d1 execute aimindtree_sync --file=./schema.sql
   ```
6. 部署：
   ```bash
   wrangler deploy
   ```
   部署成功后拿到 `https://<subdomain>.workers.dev`（或自定义域）。

> 本方案为「账号登录多租户」：**无需设置任何 secret / 共享 token**。
> 普通用户用 App 端用户名+密码自助注册/登录，登录后拿到的每用户令牌即同步凭证。

## App 端配置

设置页 → 「Cloudflare 目标（方案 B）」：

- **CF Worker URL**：填上面拿到的 `https://<subdomain>.workers.dev`；
- **账号**：在「Cloudflare 账号」卡片用用户名+密码「注册」或「登录」（无需填任何共享 token）；
- 登录成功后，用「上传到 CF / 从 CF 拉取」按钮即可；每用户数据按账号隔离。

> 同一份本地 outbox 数据若想同时传两个后端，注意：上传会消费本地 outbox
> （标记 done）。开发期两个后端共用一个 `lastPulledAt` 游标，已通过每次拉取前
> 归零规避漏拉；正式多端场景建议固定指向单一云端后端（CF），llm_server 仅作
> 本地开发兜底。

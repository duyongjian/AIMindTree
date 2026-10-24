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

## 国内线路可达性（2026-10-24 实测）

`*.workers.dev` 在国内线路**双重受阻**，但两层都有解法，桌面端（PC）最终可用：

| 层 | 现象 | 解法 |
|----|------|------|
| DNS | 系统 DNS 对 `*.workers.dev` 投毒，返回 Facebook/Twitter 段假 IP（实测 128.242.240.149 / 66.220.148.145） | App 侧 DoH（`doh.pub`）拿真实 CF IP（172.67.x / 104.21.x），见 `aimindtree_app/lib/data/sync/doh_resolver.dart` |
| TLS | 拿到真 IP 后 TCP 可连，但带 `workers.dev` SNI 的 ClientHello 被 RST（SNI 级阻断，openssl/curl 均复现） | 走本地代理隧道：Clash/v2rayN 等自行解析并转发，不受本机投毒影响 |

**桌面端现状（本机实测全绿）**：Clash 监听 7897 时，App 启动即自动探测到该代理
（`initSystemProxy` 探测列表首位），同步请求全部走 CONNECT 隧道，
register / push / pull / manifest / login 五端点全部 200。

**App 侧两个对应设计**：

1. `createDirectHttpClient`（`direct_connect.dart`）探测式启用：能直连就零改道；
   不能直连才 DoH 拿真 IP、以原域名 SNI 建连；**已配置代理时直接跳过探测与
   DoH 预解析**——代理路径下 DoH 工厂本就不会被用到，跳过可省首请求 4~10s。
2. DoH 端点只保留 `doh.pub`：`dns.alidns.com` / `doh.360.cn` 只认 RFC 8484
   wire format（JSON 参数直接 400），`dns.alidns.com/resolve` 对 workers.dev
   返回污染 IP（104.244.43.182），均不可用；依据见 `doh_resolver.dart`
   `kDefaultDoHEndpoints` 常量注释。

> 若所在网络连代理也不通（SNI 阻断极严），终极解法是给 Worker 绑**自有域名**
> （Dashboard → Workers → Triggers → Custom Domains）——非 workers.dev 域名
> 不触发该 SNI 黑名单。

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

用内存版 D1 模拟直接驱动 `worker.js` 的 `fetch`，验证账号 / 同步 / 管理接口全链路：

```bash
node test_worker.mjs          # 期望：通过 74，失败 0
```

覆盖：注册/登录/重名/弱密码、未授权 401、push→pull→manifest、INSERT OR REPLACE
覆盖、since 增量、多租户隔离、404；以及 `/admin/*` 全组（未配 ADMIN_TOKEN → 404、
错令牌 → 401、stats/users 形状与 100 条上限、reset 三种 scope 计数与幂等、
DELETE 用户 404、export 形状 / user_id 过滤 / 10000 条截断）。

## 管理接口（`/admin/*`，默认关闭）

供本地管理后台巡检与清理，**与用户侧契约完全隔离**（`/auth/*`、`/sync/*` 语义零变化），
HTTP 契约与 `sync_relay_netlify` **逐字一致**。

开启方式：给 Worker 配 `ADMIN_TOKEN`（**不配置则所有 `/admin/*` 一律 404**，
端点连存在性都不暴露）：

```bash
wrangler secret put ADMIN_TOKEN      # 输入你自己的强随机串
```

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/admin/ping` | `{ok,storage:"d1",server_time}` |
| GET | `/admin/stats` | 全局 `users/tokens/envelopes` + `per_user`（按 envelopes 降序，≤100） |
| GET | `/admin/users` | 账号列表（含 tokens/envelopes 用量，≤100） |
| POST | `/admin/reset` | `{scope:"all"\|"envelopes"\|"user", user_id?, confirm:"RESET"}`，幂等 |
| DELETE | `/admin/user/{id}` | 删账号 + 其 envelopes/tokens；不存在 → 404 |
| GET | `/admin/export?user_id=` | 导出 envelope 快照（单次 ≤10000 条，超出 `truncated:true`） |

鉴权：`Authorization: Bearer <ADMIN_TOKEN>`，常量时间比较；令牌不符 → 401 +
`WWW-Authenticate: Bearer`。

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
> 若要启用管理接口，再单独 `wrangler secret put ADMIN_TOKEN`（见上一节）。

## App 端配置

设置页 → 「Cloudflare 目标（方案 B）」：

- **CF Worker URL**：填上面拿到的 `https://<subdomain>.workers.dev`；
- **账号**：在「Cloudflare 账号」卡片用用户名+密码「注册」或「登录」（无需填任何共享 token）；
- 登录成功后，用「上传到 CF / 从 CF 拉取」按钮即可；每用户数据按账号隔离。

> 同一份本地 outbox 数据若想同时传两个后端，注意：上传会消费本地 outbox
> （标记 done）。开发期两个后端共用一个 `lastPulledAt` 游标，已通过每次拉取前
> 归零规避漏拉；正式多端场景建议固定指向单一云端后端（CF），llm_server 仅作
> 本地开发兜底。

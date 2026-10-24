# sync_relay_netlify · AIMindTree 同步中继（Netlify 版）

Netlify **Functions（Node.js）+ Blobs** 实现。HTTP 契约与
`sync_relay_cf` / `sync_relay_cn` / `sync_relay_vercel` / `sync_relay_eo`
**逐字一致**，App 端换后端只换地址。

> 状态（2026-10-24）：**已部署到生产并全链路实测通过**。
> 站点 `aimindtree-sync-relay`（`https://aimindtree-sync-relay.netlify.app`），
> 注册/登录/推送/manifest/拉取 + 401/409 错误路径均验证 OK；App 侧已接为
> **第五同步后端**（设置页五选一），`kSyncNetlifyDefaultBaseUrl` 已回填。

## 调研结论（可行性）

**结论：可行，且是五后端里存储最稳的一个。** 但有一个硬约束：**国内直连可达性差**
（与 Vercel 同病，函数跑在美/欧单区域），所以它定位为**海外/备份后端**，不是
国内首选（国内首选仍是 EdgeOne）。

| 维度 | Cloudflare | CloudBase | Vercel | EdgeOne | **Netlify（本版）** |
|---|---|---|---|---|---|
| 运行时 | Worker (V8) | 云函数 | Serverless | Edge Function | **Functions（Node.js / AWS Lambda）** |
| 数据 | D1 (SQLite) | PostgreSQL | Upstash Redis | KV | **Blobs（键值）** |
| 一致性 | 强 | 强 | 强 | 最终(~60s) | **强（API 模式直达源站）** |
| 请求体上限 | 大 | 大 | 大 | 1MB | **宽松（本版守 4MB）** |
| 国内可达 | 经代理 | 满分 | 不稳 | 满分 | **差（海外单区）** |
| 免费额度 | 有 | 有 | 有 | 永久免费 | **有（125K 函数/月 + ~10GB Blobs）** |

### 为什么是它 / 为什么不是首选

- **存储最稳**：Blobs 的 API 访问模式读写直达源站，写入立即可读，不像 EdgeOne
  KV 要等 60s 最终一致；pull 的回退窗口仅留 1s 覆盖同毫秒边界（`kPullLookbackMs`，
  可用站点环境变量 `SYNC_PULL_LOOKBACK_MS` 覆盖），窗口外即严格增量。
- **免费且无需绑卡**：Starter 计划含 100GB 带宽、300 构建积分、125K 函数请求/月、
  ~10GB Blobs 存储（2025-09 起的积分模型，额度用完网站暂停而非扣费）。
- **致命短板——国内可达性**：函数默认落在美/欧单区域，从中国直连延迟高、且可能
  被墙/不稳。这与 Vercel 完全一致。**国内用户真正顺滑的后端只有 EdgeOne（满分）
  与 CloudBase（满分）**。所以 Netlify 只建议作为：海外使用、或 Vercel 之外的
  备选兜底。

### 平台适配要点（已落实，含 2026-10-24 实测踩坑）

1. **运行时是完整 Node.js（v18.20.8）**，不是 Edge isolate。**但 Node 18 没有
   全局 `crypto`**（全局 Web Crypto 是 Node 19+ 才默认开放）——`relay.js` 顶部
   从 `node:crypto` 取 `webcrypto` 兜底，PBKDF2 哈希参数与另四版**完全一致、
   哈希值可互相移植**（多后端用户迁移无障碍）。本地 Node 22 与测试走全局分支。
2. **存储用 `@netlify/blobs`，走「API 访问」模式**（`relay.js` 把存储抽象成
   `{get, set, listKeys}` 接口，生产 `netlify/functions/sync.mjs` 适配，测试用
   内存实现零依赖跑通）。**不依赖平台自动注入 Blobs 上下文**——实测 v2 默认导出 +
   惰性建 store + `.mjs` 扩展名均无法让平台注入 `netlifyBlobsContext` /
   `NETLIFY_BLOBS_CONTEXT`（每请求 `MissingBlobsEnvironmentError`；Netlify 支持
   论坛有同期活跃缺陷帖）。故显式传 siteID（运行时 `context.site.id`）+ token
   （站点环境变量 `NETLIFY_BLOBS_TOKEN`，**绝不入库存**）。API 模式不经
   edgeURL，无 `uncachedEdgeURL` 要求，读写直达源站 = 强一致。
3. **路由用 `netlify.toml` rewrite（200）**：Netlify Functions 没有 Vercel 那种
   文件级 catch-all，故把 `/`、`/auth/*`、`/sync/*` 全部 rewrite 到同一个函数
   `.netlify/functions/sync`（带 `:splat` 保留子路径）；函数内
   `toLogicalRequest` 剥掉挂载前缀还原逻辑路径，契约逐字一致。
4. **`.mjs` + `[functions] node_bundler = "esbuild"`**：`.mjs` 扩展名保证 ESM
   （v2 运行时的判定依据；`export default` 即 v2，`export const handler` 是 v1
   不支持 Blobs）。esbuild 打包把 `relay.js` 与依赖收进单文件。
5. **Blobs 键名允许 Unicode**，本版仍用 UTF-16 hex 编码键名，保证五后端键格式统一、
   可迁移。
6. **Blobs 无内置访问控制**：中继函数本身是网关，所有读写先过 Bearer 鉴权，与另四版一致。
7. **本地 dev 的已知缺陷（非本项目问题）**：netlify-cli@17 内置的 blobs 版本用
   `rename` 落盘，临时目录（C:）与项目（D:）跨盘 → Windows EXDEV → 本地 dev 的
   写全部 500。**生产（Linux）无此问题**；本地只读验证可用，写验证以生产为准。

## 目录结构

```
sync_relay_netlify/
├── netlify/
│   └── functions/
│       └── sync.mjs         # 生产入口：Blobs(API 模式) → relay 接口 → handleFetch
├── relay.js                 # 存储无关核心逻辑（契约 + 鉴权 + PBKDF2），可内存测试
├── test_protocol.mjs        # 协议冒烟测试（39 断言，零依赖）
├── netlify.toml             # functions 目录 + esbuild + rewrite 路由 + 占位 publish
├── package.json             # type:module，依赖 @netlify/blobs
├── public/.gitkeep          # 占位发布目录
└── README.md
```

`relay.js` 导出：`handleFetch(request, store, env)`（核心分发）与
`makeMemoryStore()`（测试用内存 store）。生产 `sync.mjs` 只负责把 Blobs 适配成
`store` 接口。

## 本地验证（零依赖）

```bash
cd sync_relay_netlify
node test_protocol.mjs        # 期望：通过 39，失败 0
```

> 注意：本地 `node` 测试用的是内存 store，**不验证 @netlify/blobs 本身**。本地
> `netlify dev` 可验证读路径（本地 Blobs 服务器 GET 正常），**写路径因上述
> EXDEV 缺陷不可用**——写/全链路验证以生产部署为准（CLI 一条命令，见下）。

## 部署（CLI + 令牌，2026-10-24 实操通过）

```bash
# 0) 装 CLI（锁 17.0.0：latest 版在本机 npm 缓存有 zip-it-and-ship-it 解析故障）
cd sync_relay_netlify
npm install --no-save netlify-cli@17.0.0

# 1) 建站点（--account-slug 避开交互式 Team 选择；沙箱/无头环境必须）
NETLIFY_AUTH_TOKEN=<token> ./node_modules/.bin/netlify sites:create \
  --name aimindtree-sync-relay --account-slug <your-slug> --disable-linking

# 2) 链接本地目录
NETLIFY_AUTH_TOKEN=<token> ./node_modules/.bin/netlify link --id <site-id>

# 3) 注入 Blobs 访问令牌（站点级环境变量，勿入库存；生产 context）
NETLIFY_AUTH_TOKEN=<token> ./node_modules/.bin/netlify env:set \
  NETLIFY_BLOBS_TOKEN <token> --context production

# 4) 部署（函数由 netlify.toml 的 esbuild 配置打包，无需 build 命令）
NETLIFY_AUTH_TOKEN=<token> ./node_modules/.bin/netlify deploy --prod
```

**换新机器/重建站点时必做**：步骤 3 的 `NETLIFY_BLOBS_TOKEN`（用 Netlify
Personal Access Token，User settings → Applications → Personal access tokens）。
漏了它函数每请求 500（`NETLIFY_BLOBS_TOKEN 未配置` 提示已内置在报错信息里）。
轮换 PAT 后需重新 `env:set` 并部署。

> `npx netlify`（不锁版本）在本机 npm 缓存报 `@netlify/zip-it-and-ship-it`
> 解析不到——本地缓存/源问题，非项目问题；干净环境无此障碍。

### 方式 B：Netlify 控制台（手动兜底）

1. 控制台 → **Add new site → Import from Git** → 选 GitHub 仓库 `AIMindTree`。
2. **根目录（Base directory）填 `sync_relay_netlify`**（只部署这个子目录；
   `netlify.toml` 已声明 functions / esbuild / rewrite，无需额外配置）。
3. **Environment variables 加 `NETLIFY_BLOBS_TOKEN`**（同上，PAT）。
4. Deploy → 等 `Ready`。`GET /` 应返 `{ok:true, service:"aimindtree-sync-relay",
   runtime:"netlify-functions-node", storage:"netlify-blobs"}`。
5. 域名回填 `kSyncNetlifyDefaultBaseUrl`（本项目已填
   `https://aimindtree-sync-relay.netlify.app`）。

## 安全 / 隐私

- 密码 `PBKDF2` 10 万次迭代 + 随机盐，明文不落库；令牌 64 位 hex，按用户隔离。
- 多租户数据按 `owner_id` 严格隔离；一个用户看不到另一个用户的数据（测试已覆盖）。
- 中继只存「每个 (owner, table, entity) 的最新态 + server_time」，不备份历史版本。
- Blobs 走站点环境变量 `NETLIFY_BLOBS_TOKEN`（PAT，仅存 Netlify 环境配置，
  **不在仓库、不在 App、不下发**）。注意 PAT 是账号级凭证，泄露可轮换重置。

## App 集成（已完成，第五后端）

- `SyncBackend.netlify`（UI 名 `Netlify`，keySuffix `nf`），设置页后端选择器
  **五选一**（Cloudflare / CloudBase / Vercel / EdgeOne / Netlify），账号体系
  互相独立。
- `kSyncNetlifyDefaultBaseUrl` 已回填 `https://aimindtree-sync-relay.netlify.app`
  （rewrite 收口全路径，**无需 `/api` 之类前缀**；用户手填覆盖优先）。
- push 预算：Netlify 沿用 4MB / 6MB（平台无 1MB 硬限，不必收 850KB）。

## 契约速查（与另四版一致）

- `POST /auth/register` `{username,password}` → `{user_id,token}`
- `POST /auth/login` `{username,password}` → `{user_id,token}`
- `POST /sync/push` `{device_id,envelopes:[...]}` → `{received,accepted,server_time}`
- `POST /sync/pull` `{device_id,since|null}` → `{envelopes:[...],server_time}`
- `GET  /sync/manifest` → `{count}`

所有 `/sync/*` 需 `Authorization: Bearer <token>`。

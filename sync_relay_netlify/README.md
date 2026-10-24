# sync_relay_netlify · AIMindTree 同步中继（Netlify 版）

Netlify **Functions（Node.js）+ Blobs** 实现。HTTP 契约与
`sync_relay_cf` / `sync_relay_cn` / `sync_relay_vercel` / `sync_relay_eo`
**逐字一致**，App 端换后端只换地址。

> 状态（2026-10-24）：**可行性已确认、代码已就绪、协议测试 39/0 全绿**。
> 尚未实际部署到 Netlify——等你给 Netlify 权限（或开一个 token）后，部署是
> 一条命令的事（见「部署」一节）。App 侧也**尚未**把 netlify 接成第五后端
> （见末尾「App 集成」）。

## 调研结论（可行性）

**结论：可行，且是五后端里存储最稳的一个。** 但有一个硬约束：**国内直连可达性差**
（与 Vercel 同病，函数跑在美/欧单区域），所以它定位为**海外/备份后端**，不是
国内首选（国内首选仍是 EdgeOne）。

| 维度 | Cloudflare | CloudBase | Vercel | EdgeOne | **Netlify（本版）** |
|---|---|---|---|---|---|
| 运行时 | Worker (V8) | 云函数 | Serverless | Edge Function | **Functions（Node.js / AWS Lambda）** |
| 数据 | D1 (SQLite) | PostgreSQL | Upstash Redis | KV | **Blobs（键值）** |
| 一致性 | 强 | 强 | 强 | 最终(~60s) | **强（默认可开 strong）** |
| 请求体上限 | 大 | 大 | 大 | 1MB | **宽松（本版守 4MB）** |
| 国内可达 | 经代理 | 满分 | 不稳 | 满分 | **差（海外单区）** |
| 免费额度 | 有 | 有 | 有 | 永久免费 | **有（125K 函数/月 + ~10GB Blobs）** |

### 为什么是它 / 为什么不是首选

- **存储最稳**：Blobs 支持 `consistency: 'strong'`，写入立即可读，不像 EdgeOne
  KV 要等 60s 最终一致；pull 也无需依赖回退窗口（本版仍留 5s 余量）。
- **零配置凭证**：`getStore()` 在 Functions 内自动注入站点凭证，不像 CloudBase
  要配 SecretId/Key，也不像 Vercel 要单独建 Upstash 实例。
- **免费且无需绑卡**：Starter 计划含 100GB 带宽、300 构建积分、125K 函数请求/月、
  ~10GB Blobs 存储（2025-09 起的积分模型，额度用完网站暂停而非扣费）。
- **致命短板——国内可达性**：函数默认落在美/欧单区域，从中国直连延迟高、且可能
  被墙/不稳。这与 Vercel 完全一致。**国内用户真正顺滑的后端只有 EdgeOne（满分）
  与 CloudBase（满分）**。所以 Netlify 只建议作为：海外使用、或 Vercel 之外的
  备选兜底。

### 平台适配要点（已落实）

1. **运行时是完整 Node.js**，不是 Edge isolate：`crypto.subtle` / `getRandomValues`
   是全局，PBKDF2 哈希参数与另四版**完全一致、哈希值可互相移植**（多后端用户迁
   移无障碍）。
2. **存储用 `@netlify/blobs`**：`relay.js` 把存储抽象成 `{get, set, listKeys}` 接口，
   生产 `netlify/functions/sync.js` 用 Blobs 适配，测试用内存实现（零依赖跑通协议）。
3. **路由用 `netlify.toml` rewrite（200）**：Netlify Functions 没有 Vercel 那种
   文件级 catch-all，故把 `/`、`/auth/*`、`/sync/*` 全部 rewrite 到同一个函数
   `.netlify/functions/sync`，函数内 `request.url` 仍保留原始路径，契约逐字一致。
4. **Blobs 键名允许 Unicode**，本版仍用 UTF-16 hex 编码键名，保证五后端键格式统一、
   可迁移。
5. **Blobs 无内置访问控制**：中继函数本身是网关，所有读写先过 Bearer 鉴权，与另四版一致。

## 目录结构

```
sync_relay_netlify/
├── netlify/
│   ├── functions/
│   │   └── sync.js          # 生产入口：@netlify/blobs → relay 接口 → handleFetch
│   └── (netlify.toml 在仓库根，见下)
├── relay.js                 # 存储无关核心逻辑（契约 + 鉴权 + PBKDF2），可内存测试
├── test_protocol.mjs        # 协议冒烟测试（39 断言，零依赖）
├── netlify.toml             # functions 目录 + rewrite 路由 + 占位 publish
├── package.json             # type:module，依赖 @netlify/blobs
├── public/.gitkeep          # 占位发布目录
└── README.md
```

`relay.js` 导出：`handleFetch(request, store, env)`（核心分发）与
`makeMemoryStore()`（测试用内存 store）。生产 `sync.js` 只负责把 Blobs 适配成
`store` 接口。

## 本地验证（零依赖）

```bash
cd sync_relay_netlify
node test_protocol.mjs        # 期望：通过 39，失败 0
```

> 注意：本地 `node` 测试用的是内存 store，**不验证 @netlify/blobs 本身**（那要
> 在真实部署里才跑得到）。但核心契约、鉴权、隔离、增量、413 守卫都已在本机证明。

## 部署（控制台 / API 方式，不靠浏览器插件）

与 EdgeOne / Vercel 统一决策：**用官方 CLI + 令牌做自动化，不靠 Chrome 插件点选**
（沙箱无头、浏览器登录弹窗用户无法交互；CLI 可脚本化、结果可验证；插件仅作手动兜底）。

### 方式 A：CLI（推荐，可脚本化）

```bash
# 1) 登录（首次会开浏览器走 OAuth 一次；之后令牌缓存，不再弹窗）
npx netlify login
# 2) 关联仓库（从 GitHub 私有仓 AIMindTree 导入，根目录选 sync_relay_netlify）
npx netlify link --git-remote-url https://github.com/BOFHT/AIMindTree
# 3) 先 preview 部署验证
npx netlify deploy
# 4) 确认无误后推生产
npx netlify deploy --prod
```

部署后回填 `kSyncNetlifyDefaultBaseUrl`（App 设置页才会出现 Netlify 选项）。

> 实测本机 `npx netlify` 因 npm 缓存里 `@netlify/zip-it-and-ship-it@16.5.1`
> 解析不到而报错——这是**本地 npm 缓存/源**问题，不是项目问题；清缓存或换源即可，
> 不影响代码正确性。正式部署在干净环境（或用户的 Netlify 控制台）无此问题。

### 方式 B：Netlify 控制台（手动兜底）

1. 控制台 → **Add new site → Import from Git** → 选 GitHub 仓库 `AIMindTree`。
2. **根目录（Base directory / Root）填 `sync_relay_netlify`**（只部署这个子目录，
   别选仓库根；`netlify.toml` 已声明 functions 与 rewrite，无需额外配置）。
3. Deploy → 等 `Ready`。`GET /` 应返 `{ok:true, service:"aimindtree-sync-relay",
   runtime:"netlify-functions-node", storage:"netlify-blobs"}`。
4. 把分配的域名（形如 `https://<site>.netlify.app`）发主理人，回填
   `kSyncNetlifyDefaultBaseUrl`。

## 安全 / 隐私

- 密码 `PBKDF2` 10 万次迭代 + 随机盐，明文不落库；令牌 64 位 hex，按用户隔离。
- 多租户数据按 `owner_id` 严格隔离；一个用户看不到另一个用户的数据（测试已覆盖）。
- 中继只存「每个 (owner, table, entity) 的最新态 + server_time」，不备份历史版本。
- Blobs 站点级 store 凭证由 Netlify 自动注入，无密钥落库风险。

## App 集成（尚未做，建议作为第五后端）

目前 App 已支持 `cf / cb / vc / eo` 四后端。若要加 `netlify` 第五后端，改动与
EdgeOne 那次**同构**：

- `SyncBackend` 枚举加 `netlify`（label `Netlify`，keySuffix `nf`，defaultBaseUrl
  空串待回填）；`pushBatchBudgetBytes` / `maxEnvelopeBytes` 取 4MB / 6MB（Netlify
  非 1MB 限制，无需收 850KB）。
- 设置页后端选择器变「五选一」；回填 `kSyncNetlifyDefaultBaseUrl` 前 UI 显示
  「（待配置）」并禁用手动上传/拉取。
- 补一条断言测试。

**是否接入请确认**：鉴于 Netlify 国内可达性差，它不是国内用户的实用后端，是否值得
在 App 里占一个选项位，等你拍板。（EdgeOne 才是国内首选，建议优先把 EdgeOne 控台
KV/域名绑定收尾，而非先扩 Netlify。）

## 契约速查（与另四版一致）

- `POST /auth/register` `{username,password}` → `{user_id,token}`
- `POST /auth/login` `{username,password}` → `{user_id,token}`
- `POST /sync/push` `{device_id,envelopes:[...]}` → `{received,accepted,server_time}`
- `POST /sync/pull` `{device_id,since|null}` → `{envelopes:[...],server_time}`
- `GET  /sync/manifest` → `{count}`

所有 `/sync/*` 需 `Authorization: Bearer <token>`。

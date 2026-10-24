# sync_relay_eo · AIMindTree 同步中继（EdgeOne Pages 版）

腾讯云 **EdgeOne Pages** 的 Edge Functions + KV 实现。HTTP 契约与
`sync_relay_cf` / `sync_relay_cn` / `sync_relay_vercel` **逐字一致**，App 端
只换地址即可切换后端。

## 为什么是它（国内免费首选）

- **官方 FAQ 明示“永久免费”**：不限安全加速流量 / 请求 + 每月 3M Edge Functions
  请求与 CPU 时间 + **1GB KV 存储** + 500 次构建 / 月；2025-12 正式版 GA，无需绑卡。
- **腾讯边缘节点**：国内直连可达性满分，不依赖被污染的 `*.workers.dev` /
  `*.vercel.app` 线路。
- 工作量小：本目录就是把 Cloudflare 版（`sync_relay_cf/worker.js`）改造为
  EdgeOne Edge Function + KV 适配层。

## 与另三版的差异（务必先读）

| 维度 | Cloudflare | CloudBase | Vercel | **EdgeOne（本版）** |
|---|---|---|---|---|
| 运行时 | Worker (V8 isolate) | 云函数 | Serverless | **Edge Function** |
| 数据 | D1 (SQLite) | PostgreSQL | Upstash Redis | **KV（键值）** |
| 路由 | 单文件 worker | 网关路径 `/sync-relay` | `api/[[...path]]` | **`edge-functions/[[default]].js`（可选 catch-all，含根 `/`）** |
| 契约 | 5 端点 + Bearer | 同 | 同 | **同** |
| 请求体上限 | 大 | 大 | 大 | **1MB（本版 900KB 即 413 守卫）** |
| 一致性 | 强 | 强 | 强 | **最终一致 ~60s（pull 自带 65s 回退窗口）** |
| 国内可达 | 经代理才通 | 满分 | 不稳 | **满分** |

### EdgeOne 专属约束（实现已处理，仅作记录）

1. **KV 命名空间是全局变量，不在 `context.env`**：控制台绑定 Namespace 时
   **Variable Name 必须填 `SYNC_KV`**（大小写敏感）。代码按
   `env.SYNC_KV` → `globalThis.SYNC_KV` 顺序探测。
2. **KV 键名只允许数字/字母/下划线（≤512B）**：`username` / `entity_table` /
   `entity_id` 可能含中文、点、斜杠，一律先做 UTF-16 hex 编码再拼键。
3. **KV 最终一致（全球 60s 内同步）**：`pull` 的 since 起点自动回退 65s
   （`SYNC_PULL_LOOKBACK_MS` 可覆盖，测试里置 0 拿严格语义），把仍在传播的
   写入捞回来；App 侧 apply 幂等，重复投递无害。
4. **请求体上限 1MB**：超过 900KB 直接 413，不缓冲巨包。单条 envelope 超过
   约 900KB（典型是大图片附件 `data_base64`）在任何后端都存不下——App 侧
   对 EdgeOne 后端需把切批预算从 4MB 收到 ≤900KB（见 App 集成一节）。
5. 运行时仅 JavaScript（ES module）、CPU 200ms/次：密码哈希走 Web Crypto
   原生 `PBKDF2`（10 万次迭代），不占 JS CPU 预算，与另三版哈希互通。

## 目录结构

```
sync_relay_eo/
├── edge-functions/
│   └── [[default]].js     # 全部路由（根健康检查 + auth + sync），自包含、无 import
├── test_protocol.mjs      # 本地协议冒烟测试（69 断言，不联网）
├── package.json           # type:module，无外部依赖
└── README.md
```

`[[default]].js` 导出了两个名字：
- `onRequest(context)`：EdgeOne 运行时入口（`context.request` / `context.env`）。
- `handleFetch(request, env)`：测试直驱的纯函数（Web `Request` + `{SYNC_KV}`）。

## 本地验证

```bash
cd sync_relay_eo
node test_protocol.mjs      # 期望：通过 69，失败 0
```

## 部署（手把手）

### 方式 A：EdgeOne Pages 控制台（推荐，不用 CLI）

1. 打开 [edgeone.ai](https://edgeone.ai) / 国内站 → **EdgeOne Pages** →
   **新建项目** → 选择导入 GitHub 仓库 `AIMindTree`。
2. **根目录（Root Directory）填 `sync_relay_eo`**（只部署这个子目录，别选仓库根）。
   Framework Preset 选 **Other / 无框架**。
3. 点 **部署**。等待 `Ready`。此时 `GET /` 应返回
   `{ok:true, service:"aimindtree-sync-relay", version:"1.0.0"}`，但 `/sync/*`
   会返 **503**（KV 还没绑）。
4. 控制台 → **KV Storage** → 新建命名空间（如 `aimindtree-sync`）→
   **绑定到本项目**，绑定配置里 **Variable Name 填 `SYNC_KV`**（大小写敏感，
   填错即 503）。
5. 重新部署（绑定 KV 后需重新触发一次构建让绑定生效）。
6. 验证：
   ```bash
   curl https://<你的默认域名>/                    # → {ok:true,...}
   curl -X POST https://<你的默认域名>/auth/register \
     -H 'Content-Type: application/json' \
     -d '{"username":"alice","password":"password123"}'   # → {user_id, token}
   ```
7. 把域名发主理人，回填 `kSyncEoDefaultBaseUrl`（App 设置页才会出现 EdgeOne 选项）。

### 方式 B：CLI（eo 未开源，控制台最稳）

EdgeOne Pages 的 CLI 不如 Vercel 成熟，建议直接走控制台。若要用 CLI，思路是
`eo pages deploy sync_relay_eo --...`，具体以官方文档为准。

### 自定义域名（可选，需备案）

EdgeOne 支持绑定自有域名（DNS / 文件 / 委派验证 + 免费证书）。主域名走国内节点、
免备案解析友好；子域名如需大陆节点仍需 ICP 备案。

## 安全 / 隐私

- 密码 `PBKDF2` 10 万次迭代 + 随机盐，明文不落库；令牌 64 位 hex，按用户隔离。
- 多租户数据按 `owner_id` 严格隔离；一个用户看不到另一个用户的数据。
- 中继只存「每个 (owner, table, entity) 的最新态 + server_time」，不备份历史版本。

## 契约速查（与另三版一致）

- `POST /auth/register` `{username,password}` → `{user_id,token}`
- `POST /auth/login` `{username,password}` → `{user_id,token}`
- `POST /sync/push` `{device_id,envelopes:[...]}` → `{received,accepted,server_time}`
- `POST /sync/pull` `{device_id,since|null}` → `{envelopes:[...],server_time}`
- `GET  /sync/manifest` → `{count}`

所有 `/sync/*` 需 `Authorization: Bearer <token>`。

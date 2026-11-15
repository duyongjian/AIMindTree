/**
 * AIMindTree 同步中继 · Netlify 版核心逻辑（与 Cloudflare / EdgeOne 两版
 * **契约逐字一致**，App 端换后端只换地址）。
 *
 * 本文件是「存储无关」的纯逻辑：所有读写都走传入的 `store` 对象
 * （接口见 [makeMemoryStore] / sync.js 里的 Blobs 适配层），因此可以不装
 * 任何外部依赖、用一个内存 store 直接跑协议测试（见 test_protocol.mjs）。
 *
 * 账号（多租户隔离，普通用户自助注册/登录，无需共享 token）：
 * - ``POST /auth/register``  ``{username, password}`` → ``{user_id, token}``
 * - ``POST /auth/login``     ``{username, password}`` → ``{user_id, token}``
 * 同步（均须 ``Authorization: Bearer <token>``，按 token 归属的 user_id 隔离）：
 * - ``POST /sync/push``   ``{device_id, envelopes:[...]}`` → ``{received, accepted, skipped, server_time, versions}``
 * - ``POST /sync/pull``   ``{device_id, since|null}``      → ``{envelopes:[...], server_time}``
 * - ``GET  /sync/manifest``                             → ``{count, max_version}``
 *
 * 管理接口（与 CF 版逐字一致；``Authorization: Bearer <ADMIN_TOKEN>``，
 * 未配置 ADMIN_TOKEN 时全部 404，令牌不符 401）：
 * - ``GET  /admin/ping`` / ``/admin/stats`` / ``/admin/users`` / ``/admin/export``
 * - ``POST /admin/reset`` ``{scope, user_id?, confirm:"RESET"}``
 * - ``DELETE /admin/user/{id}``
 *
 * 平台适配要点（2026-10-24 依 Netlify 官方文档落实）：
 *
 * 1. **运行时是 Node.js（AWS Lambda），不是 Edge isolate**：完整 Node 运行时，
 *    PBKDF2 / getRandomValues 走 Web Crypto，与 CF / EdgeOne 版**同一套哈希参数、
 *    哈希值可互相移植**（多后端用户迁移无障碍）。注意 Netlify 函数运行时的
 *    Node 18.20.8 **没有全局 ``crypto``**（全局 Web Crypto 是 Node 19+ 才默认开放），
 *    故下面从 ``node:crypto`` 取 ``webcrypto`` 兜底（2026-10-24 实测踩坑）。
 * 2. **存储用 Netlify Blobs（``@netlify/blobs``）**：KV 风格键值。本版走官方
 *    「API 访问」模式（显式 siteID + token，见 sync.mjs），读写直达 API 源站，
 *    即强一致；``kPullLookbackMs`` 仅留 1s 覆盖同毫秒边界（详见其注释）。
 * 3. **Blobs 键名允许 Unicode（≤600B、不能以 / 开头）**：本版仍沿用另两版的
 *    UTF-16 hex 编码键名，保证键格式在各后端间一致、可迁移。
 * 4. **请求体上限**：Netlify Functions 没有 EdgeOne 那种 1MB 硬限（平台更宽松），
 *    本版把守卫放宽到 4MB（与 Cloudflare 版一致），App 端若接入 netlify
 *    后端可沿用 4MB / 6MB 预算，不必收 850KB。
 * 5. **Blobs 没有内置访问控制**：中继函数本身就是网关——所有读写都先过
 *    Bearer 鉴权，未授权一律 401，与另两版一致。
 */

import { webcrypto as nodeWebcrypto } from 'node:crypto';

/**
 * Web Crypto 实例：优先全局（Node≥19 / Deno / 边缘运行时），回退
 * ``node:crypto.webcrypto``（Netlify 函数运行时 Node 18.20.8 实测无全局 crypto）。
 * 本文件的两个消费方（Netlify 函数、test_protocol.mjs）都是 Node，静态引入无负担。
 */
const crypto =
  typeof globalThis.crypto !== 'undefined' && globalThis.crypto.subtle
    ? globalThis.crypto
    : nodeWebcrypto;

/** 服务标识（健康检查与错误响应用）。 */
const SERVICE_NAME = 'aimindtree-sync-relay';
const SERVICE_VERSION = '1.0.0';

/** CORS：方便 curl / 浏览器手动测试；App 走 dart:io，不需要。 */
// 含 DELETE：浏览器端管理面板直发 ``DELETE /admin/user/{id}`` 时预检必须放行。
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

/**
 * 请求体字节上限（4MB）。
 *
 * Netlify Functions 平台对此比 EdgeOne（1MB）宽松；留 4MB 与 Cloudflare 版
 * 对齐。content-length 超过它就直接 413，不读 body——巨包连函数都不进。
 */
const kMaxBodyBytes = 4 * 1024 * 1024;

/**
 * pull 增量起点回退量（1s）。
 *
 * 本版走 Blobs API 访问模式：读写直达源站 = 强一致，且 ``since`` 用的是中继
 * 自己赋值的 server_time（同源时钟、无偏斜），正常增量无需回退窗口。留 1s
 * 只为覆盖边界：push 若恰落在上次 pull 的同一毫秒（server_time 相等），严格
 * ``>`` 比较会漏掉这条。窗口内重复返回的 envelope 由 App 端自回声过滤 + LWW
 * 幂等合并消化，无副作用。测试可经 store/env 的 ``SYNC_PULL_LOOKBACK_MS``
 * 覆盖（置 0 拿严格增量语义）。
 */
const kPullLookbackMs = 1 * 1000;

/** PBKDF2 迭代次数（与另两版一致，哈希值可互相移植）。 */
const PBKDF2_ITER = 100000;

const MIN_USERNAME = 3;
const MIN_PASSWORD = 8;

// ---------------- 键名编码 ----------------

/** UTF-16 码元 → 四位 hex（与另两版一致，保证键格式可迁移）。 */
function hexEncode(s) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    out += s.charCodeAt(i).toString(16).padStart(4, '0');
  }
  return out;
}

/** [hexEncode] 的逆变换（测试与调试用；线上只编码不解码）。 */
function hexDecode(h) {
  let out = '';
  for (let i = 0; i + 4 <= h.length; i += 4) {
    out += String.fromCharCode(parseInt(h.slice(i, i + 4), 16));
  }
  return out;
}

/** 用户记录键：``u_<hex(username)>``。 */
function userKey(username) {
  return 'u_' + hexEncode(username);
}

/** 令牌键：``t_<token>``。令牌本身是 64 位 hex，无需再编码。 */
function tokenKey(token) {
  return 't_' + token;
}

/** envelope 键：``e_<hex(owner)>_<hex(table)>_<hex(entity)>``。 */
function envelopeKey(ownerId, table, entityId) {
  return 'e_' + hexEncode(ownerId) + '_' + hexEncode(table) + '_' + hexEncode(entityId);
}

/** 某 owner 全部 envelope 的 list 前缀。 */
function envelopePrefix(ownerId) {
  return 'e_' + hexEncode(ownerId) + '_';
}

// ---------------- 字节 / 十六进制 / 密码 ----------------

function toHex(buf) {
  const b = new Uint8Array(buf);
  let s = '';
  for (let i = 0; i < b.length; i++) s += b[i].toString(16).padStart(2, '0');
  return s;
}

function fromHex(h) {
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.substr(i * 2, 2), 16);
  return out;
}

/** 定长常量时间比较（防时序侧信道）。 */
function safeEqual(a, b) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

async function pbkdf2(password, salt) {
  const enc = new TextEncoder();
  const keyMaterial = await crypto.subtle.importKey(
    'raw',
    enc.encode(password),
    'PBKDF2',
    false,
    ['deriveBits'],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt, iterations: PBKDF2_ITER, hash: 'SHA-256' },
    keyMaterial,
    256,
  );
  return new Uint8Array(bits);
}

/** 返回存储串 ``saltHex:hashHex``。 */
async function hashPassword(password) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await pbkdf2(password, salt);
  return toHex(salt) + ':' + toHex(hash);
}

/** 校验密码：重算并与存储串定长比较。 */
async function verifyPassword(password, stored) {
  const sep = stored.indexOf(':');
  if (sep < 0) return false;
  const salt = fromHex(stored.slice(0, sep));
  const expected = stored.slice(sep + 1);
  const hash = await pbkdf2(password, salt);
  return safeEqual(toHex(hash), expected);
}

/** 生成 32 字节随机十六进制令牌。 */
function newToken() {
  return toHex(crypto.getRandomValues(new Uint8Array(32)));
}

/** 服务端时间戳：ISO 8601 UTC（Z 后缀），与 App 端解析一致。 */
function nowIso() {
  return new Date().toISOString();
}

// ---------------- 响应工具 ----------------

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
  });
}

/** 存储未就绪（如 Blobs 未配置 / 函数冷启动拿不到 store）。 */
function storeErrorResponse() {
  return jsonResponse(
    {
      ok: false,
      error:
        '存储未就绪：请确认 Netlify 函数已正确部署且 @netlify/blobs 可访问' +
        '（getStore 在 Functions 内自动注入凭证）。',
    },
    503,
  );
}

/**
 * 读 JSON body；超限/畸形分别回 413 / 400。
 */
async function readJsonBody(request) {
  const len = Number(request.headers.get('content-length') || '0');
  if (Number.isFinite(len) && len > kMaxBodyBytes) {
    return {
      error: jsonResponse(
        { error: `请求体超过 ${Math.floor(kMaxBodyBytes / 1024)}KB 上限。` },
        413,
      ),
    };
  }
  let text;
  try {
    text = await request.text();
  } catch {
    return { error: jsonResponse({ error: 'invalid json' }, 400) };
  }
  if (text.length > kMaxBodyBytes) {
    return {
      error: jsonResponse(
        { error: `请求体超过 ${Math.floor(kMaxBodyBytes / 1024)}KB 上限。` },
        413,
      ),
    };
  }
  try {
    return { body: JSON.parse(text) };
  } catch {
    return { error: jsonResponse({ error: 'invalid json' }, 400) };
  }
}

// ---------------- 账号 ----------------

async function handleRegister(request, store) {
  const { body, error } = await readJsonBody(request);
  if (error) return error;
  const username = ((body && body.username) || '').toString().trim();
  const password = (body && body.password) || '';
  if (username.length < MIN_USERNAME) {
    return jsonResponse({ error: `username too short (>=${MIN_USERNAME})` }, 400);
  }
  if (typeof password !== 'string' || password.length < MIN_PASSWORD) {
    return jsonResponse({ error: `password too short (>=${MIN_PASSWORD})` }, 400);
  }

  const existing = await store.get(userKey(username));
  if (existing) return jsonResponse({ error: 'username taken' }, 409);

  const id = 'u_' + newToken().slice(0, 24);
  const pwHash = await hashPassword(password);
  await store.set(
    userKey(username),
    JSON.stringify({ id, username, pw_hash: pwHash, created_at: nowIso() }),
  );

  const token = await issueToken(store, id);
  return jsonResponse({ user_id: id, token });
}

async function handleLogin(request, store) {
  const { body, error } = await readJsonBody(request);
  if (error) return error;
  const username = ((body && body.username) || '').toString().trim();
  const password = (body && body.password) || '';
  const raw = await store.get(userKey(username));
  if (!raw) return jsonResponse({ error: 'invalid credentials' }, 401);
  let row;
  try {
    row = JSON.parse(raw);
  } catch {
    return jsonResponse({ error: 'invalid credentials' }, 401);
  }
  if (!(await verifyPassword(password, row.pw_hash))) {
    return jsonResponse({ error: 'invalid credentials' }, 401);
  }
  const token = await issueToken(store, row.id);
  return jsonResponse({ user_id: row.id, token });
}

/** 签发新会话令牌并落库，返回明文令牌。 */
async function issueToken(store, userId) {
  const token = newToken();
  await store.set(tokenKey(token), JSON.stringify({ userId, createdAt: nowIso() }));
  return token;
}

/** 从 Bearer 头解析令牌并查归属 user_id；无效/缺失返回 null。 */
async function resolveUser(request, store) {
  const auth = request.headers.get('Authorization') || '';
  const token = auth.toLowerCase().startsWith('bearer ')
    ? auth.slice('bearer '.length).trim()
    : '';
  if (!token) return null;
  const raw = await store.get(tokenKey(token));
  if (!raw) return null;
  try {
    const row = JSON.parse(raw);
    return row && row.userId ? row.userId : null;
  } catch {
    return null;
  }
}

// ---------------- 同步（按 owner_id 隔离） ----------------

/** POST /sync/push —— 逐 envelope upsert（每键一次 set，天然无锁）。 */
async function handlePush(request, store, ownerId) {
  const { body, error } = await readJsonBody(request);
  if (error) return error;
  const envelopes = Array.isArray(body && body.envelopes) ? body.envelopes : [];
  const serverTime = nowIso();
  // 服务端权威版本号映射：`<entity_table>:<entity_id>` → 新分配的版本。
  const versions = {};
  // 被防陈旧守卫跳过（未写入）的键，格式 `<entity_table>:<entity_id>`。
  const skipped = [];
  // 本批开始前各键的权威版本（每个 key 只从存储读一次，作为陈旧覆盖判定基准）；
  // running 记录本批内该键已分配到的版本，供同一批次内同键多 envelope 链式递增。
  const authStart = {};
  const running = {};

  for (const e of envelopes) {
    const key = envelopeKey(ownerId, String(e.entity_table), String(e.entity_id));
    const k2 = `${e.entity_table}:${e.entity_id}`;
    if (authStart[k2] === undefined) {
      let ex = 0;
      const raw = await store.get(key);
      if (raw) {
        try {
          const rec = JSON.parse(raw);
          if (rec && rec.base_version != null) ex = Number(rec.base_version) || 0;
        } catch {
          // 坏记录：按 0 处理。
        }
      }
      authStart[k2] = ex;
      running[k2] = ex;
    }
    const incoming = parseInt(e.base_version, 10) || 0;
    // 防陈旧覆盖：客户端声明版本 >= 本批开始前服务端权威版本才接受其 payload
    // 并递增；若声明版本落后（过期本地副本，常见于「上传」对未拉取设备做全量
    // 重推），则保留服务端现有内容与版本、不写入也不递增，避免把云端较新内容
    // 翻回旧内容。App 端 saveNote 每次编辑都会 bump 本地版本，正常上行不触发
    // 此分支。同一批次内同键多条 envelope 视为同一设备有序编辑，依次覆盖（最后
    // 一条胜出），因此判定基准用 batch 开始前的权威版本而非批内运行版本。回写的
    // versions 取服务端权威版本，让客户端 adoption 对齐、不被卡死。
    if (incoming >= authStart[k2]) {
      const newVer = Math.max(running[k2], incoming) + 1;
      running[k2] = newVer;
      versions[k2] = newVer;

      await store.set(
        key,
        JSON.stringify({
          device_id: e.device_id,
          entity_table: e.entity_table,
          entity_id: e.entity_id,
          op: e.op,
          payload: e.payload == null ? null : JSON.stringify(e.payload),
          base_version: newVer,
          updated_at: e.updated_at,
          deleted_at: e.deleted_at,
          server_time: serverTime,
        }),
      );
    } else {
      skipped.push(k2);
      // 同批该 key 前面已有 accepted envelope 时，versions[k2] 已被抬到更高版本；
      // 这里取 max 防止把已分配的高版本回退成批前 authStart（否则 App adopt 到
      // 低于云端实际版本的值，下一轮更容易再次 stale）。
      versions[k2] = Math.max(versions[k2] ?? 0, authStart[k2]);
      // 跳过写入：保留服务端现有 payload / server_time（不覆盖、不递增）。
      // 不写 store、也不刷新 server_time：自愈靠 App 收到 skipped 后 adoption
      // 对齐 base_version → 自动重推，重推命中覆盖分支才写入新 payload + 新
      // server_time。若在此刷新 server_time，对端增量 pull 会拿到「云端旧
      // payload + 合法高 base_version」，LWW 判远端更新后主动把旧正文写下去，
      // 反而扩大数据丢失；让旧行暂留 since 游标之外、等重推完成更安全。
      // 读改写 blob 还会引入并发 CAS 竞态。
    }
  }

  return jsonResponse({
    received: envelopes.length,
    accepted: envelopes.length - skipped.length,
    skipped,
    server_time: serverTime,
    versions,
  });
}

/**
 * pull 的增量起点：``min(since, now - lookback)``。
 *
 * lookback 仅覆盖同毫秒边界（见 [kPullLookbackMs]）；强一致模式下窗口内重复
 * 返回由 App 幂等合并。since 缺失/不可解析 → 全量。lookback 可用 store/env 的
 * ``SYNC_PULL_LOOKBACK_MS`` 覆盖（测试置 0 拿严格增量语义）。
 */
export function effectiveSince(since, env) {
  const override = env && env.SYNC_PULL_LOOKBACK_MS;
  const n = override == null ? NaN : Number(override);
  const lookback = Number.isFinite(n) && n >= 0 ? n : kPullLookbackMs;
  if (!since || typeof since !== 'string') return null;
  const sinceMs = Date.parse(since);
  if (!Number.isFinite(sinceMs)) return null;
  const floor = Date.now() - lookback;
  return new Date(Math.min(sinceMs, floor)).toISOString();
}

/** POST /sync/pull —— 拉取本用户 since 之后的增量；since 为空 = 全量。 */
async function handlePull(request, store, ownerId, env) {
  const { body, error } = await readJsonBody(request);
  if (error) return error;
  const since = effectiveSince(body && body.since ? body.since : null, env);

  const keys = await store.listKeys(envelopePrefix(ownerId));
  const recs = [];
  for (const key of keys) {
    const raw = await store.get(key);
    if (!raw) continue;
    let rec;
    try {
      rec = JSON.parse(raw);
    } catch {
      continue;
    }
    if (since && rec.server_time && rec.server_time <= since) continue;
    recs.push(rec);
  }
  recs.sort((a, b) => {
    const ta = a.server_time || '';
    const tb = b.server_time || '';
    if (ta !== tb) return ta < tb ? -1 : 1;
    const ka = envelopeKey(ownerId, String(a.entity_table), String(a.entity_id));
    const kb = envelopeKey(ownerId, String(b.entity_table), String(b.entity_id));
    return ka < kb ? -1 : ka > kb ? 1 : 0;
  });
  const envelopes = recs.map((rec) => ({
    device_id: rec.device_id,
    entity_table: rec.entity_table,
    entity_id: rec.entity_id,
    op: rec.op,
    payload: rec.payload ? JSON.parse(rec.payload) : null,
    base_version: rec.base_version,
    updated_at: rec.updated_at,
    deleted_at: rec.deleted_at,
  }));
  return jsonResponse({ envelopes, server_time: nowIso() });
}

/**
 * GET /sync/manifest —— 本用户当前存量 envelope 数与最大版本号。
 *
 * 响应与 CF / EdgeOne 版**逐字一致**：``{count, max_version}``。
 *
 * 取舍说明：Blobs 没有 SQL 聚合，``max_version`` 只能在列完键名后**逐值读取**
 * 求最大（与 [handlePull] 同量级的一次全命名空间扫描）。这里刻意**流式聚合**
 * ——每条读完只留一个 running max，不把 envelope（含数 MB 的
 * ``data_base64``）攒进内存。
 *
 * 代价是 O(记录数) 次 get。没有改成「push 时维护汇总键」是因为 Blobs 无原子
 * 自增，并发 push 会让汇总键漂移；而 manifest 是低频的**总览探针**（进设置页 /
 * 同步完各一次），准确优先。
 */
async function handleManifest(store, ownerId) {
  const keys = await store.listKeys(envelopePrefix(ownerId));
  let maxVersion = 0;
  for (const key of keys) {
    const raw = await store.get(key);
    if (!raw) continue;
    try {
      const rec = JSON.parse(raw);
      const v = Number(rec && rec.base_version);
      if (Number.isFinite(v) && v > maxVersion) maxVersion = v;
    } catch {
      // 坏记录：不参与 max，也不影响 count（count 以键名为准）。
    }
  }
  return jsonResponse({ count: keys.length, max_version: maxVersion });
}

// ---------------- 管理接口（/admin/*） ----------------
//
// 与 CF 版**逐字一致**的运维契约（本地管理后台同时对接两套中继）：
// ``GET /admin/ping``、``GET /admin/stats``、``GET /admin/users``、
// ``POST /admin/reset``、``DELETE /admin/user/{id}``、``GET /admin/export``。
//
// 默认关闭：只有环境变量 ``ADMIN_TOKEN`` 非空才启用；未配置时一律 404（不暴露
// 端点存在性），配了但令牌不符 → 401 + ``WWW-Authenticate: Bearer``。
//
// Blobs 没有 SQL，全部靠 ``listKeys(前缀)`` + 逐键 ``get``/``delete``。
// 管理接口是 operator 低频操作，允许 O(记录数) 的扫描；用户侧 hot path 不受影响。

/** per_user / users 列表上限（按 envelopes 降序取前 N）。 */
const ADMIN_LIST_MAX = 100;

/** export 单次返回的 envelope 上限。 */
const ADMIN_EXPORT_MAX = 10000;

/** 读取配置的 ADMIN_TOKEN；未配置或全空白视作「端点关闭」。 */
function adminTokenOf(env) {
  const t = env && env.ADMIN_TOKEN;
  return typeof t === 'string' ? t.trim() : '';
}

/** 401 响应：带 WWW-Authenticate，便于管理端区分「令牌不对」与「端点未开启」。 */
function adminUnauthorizedResponse() {
  return new Response(JSON.stringify({ error: 'unauthorized' }), {
    status: 401,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'WWW-Authenticate': 'Bearer',
      ...CORS_HEADERS,
    },
  });
}

/**
 * 管理鉴权：通过返回 null，否则返回应直接下发的 Response。
 *
 * 先判「是否配置」（未配置 → 404 隐藏端点），再判令牌（不符 → 401）。
 */
function guardAdmin(request, env) {
  const expected = adminTokenOf(env);
  if (!expected) return jsonResponse({ error: 'not_found' }, 404);
  const auth = request.headers.get('Authorization') || '';
  const token = auth.toLowerCase().startsWith('bearer ')
    ? auth.slice('bearer '.length).trim()
    : '';
  if (!token || !safeEqual(token, expected)) return adminUnauthorizedResponse();
  return null;
}

/** 从可能带部署前缀的路径里切出 ``/admin`` 之后的子路径；不含则 null。 */
function adminSubPath(path) {
  const idx = path.indexOf('/admin/');
  if (idx >= 0) return path.slice(idx + '/admin'.length);
  if (path === '/admin' || path.endsWith('/admin')) return '/';
  return null;
}

// --- 扫描工具（Blobs 无查询语言，只能按前缀列举 + 逐键读） ---

/** 扫描 ``u_``：全部账号记录（坏记录跳过）。 */
async function adminScanUsers(store) {
  const keys = await store.listKeys('u_');
  const out = [];
  for (const key of keys) {
    const raw = await store.get(key);
    if (!raw) continue;
    let rec;
    try {
      rec = JSON.parse(raw);
    } catch {
      continue;
    }
    if (!rec || !rec.id) continue;
    out.push({
      key,
      user_id: rec.id,
      username: rec.username == null ? null : rec.username,
      created_at: rec.created_at == null ? null : rec.created_at,
    });
  }
  return out;
}

/** 扫描 ``t_``：全部令牌记录（userId 用于归属统计与按用户删除）。 */
async function adminScanTokens(store) {
  const keys = await store.listKeys('t_');
  const out = [];
  for (const key of keys) {
    const raw = await store.get(key);
    if (!raw) continue;
    let rec;
    try {
      rec = JSON.parse(raw);
    } catch {
      continue;
    }
    if (!rec || !rec.userId) continue;
    out.push({ key, userId: rec.userId });
  }
  return out;
}

/** 从 envelope 键反解 owner_id（键格式见 [envelopeKey]）；不合规返回 null。 */
function ownerFromEnvelopeKey(key) {
  const m = /^e_([0-9a-f]+)_([0-9a-f]+)_([0-9a-f]+)$/.exec(key);
  return m ? hexDecode(m[1]) : null;
}

/**
 * 扫描全部 envelope，聚合成 ``Map<owner_id, {count, last}>``。
 *
 * last_server_time 只能读值才知道（Blobs list 不回传内容），故这里是「每键一读」；
 * 仅管理接口走这条路径。
 */
async function adminScanEnvelopes(store) {
  const keys = await store.listKeys('e_');
  const agg = new Map();
  for (const key of keys) {
    const ownerId = ownerFromEnvelopeKey(key);
    if (!ownerId) continue;
    let cur = agg.get(ownerId);
    if (!cur) {
      cur = { count: 0, last: null };
      agg.set(ownerId, cur);
    }
    cur.count += 1;
    const raw = await store.get(key);
    if (!raw) continue;
    let rec;
    try {
      rec = JSON.parse(raw);
    } catch {
      continue;
    }
    const ts = rec && rec.server_time ? String(rec.server_time) : null;
    if (ts && (cur.last === null || ts > cur.last)) cur.last = ts;
  }
  return agg;
}

/** 按前缀批量删除，返回删掉的键数（Blobs 无批量删，逐键删）。 */
async function adminDeletePrefix(store, prefix) {
  const keys = await store.listKeys(prefix);
  for (const key of keys) await store.delete(key);
  return keys.length;
}

/**
 * per_user 聚合：以账号表为主，再补上「有 envelope 但账号已不存在」的孤儿
 * owner（username 为 null），按 envelopes 降序、user_id 升序，最多 100 条。
 */
function adminBuildPerUser(users, tokenCounts, envAgg) {
  const rows = [];
  const seen = new Set();
  for (const u of users) {
    seen.add(u.user_id);
    const agg = envAgg.get(u.user_id) || { count: 0, last: null };
    rows.push({
      user_id: u.user_id,
      username: u.username,
      tokens: tokenCounts.get(u.user_id) || 0,
      envelopes: agg.count,
      last_server_time: agg.last,
    });
  }
  for (const [ownerId, agg] of envAgg) {
    if (seen.has(ownerId)) continue;
    rows.push({
      user_id: ownerId,
      username: null,
      tokens: tokenCounts.get(ownerId) || 0,
      envelopes: agg.count,
      last_server_time: agg.last,
    });
  }
  rows.sort((a, b) =>
    b.envelopes !== a.envelopes
      ? b.envelopes - a.envelopes
      : a.user_id < b.user_id
        ? -1
        : a.user_id > b.user_id
          ? 1
          : 0,
  );
  return rows.slice(0, ADMIN_LIST_MAX);
}

/** 令牌计数：``Map<user_id, count>``。 */
function adminTokenCounts(tokens) {
  const out = new Map();
  for (const t of tokens) out.set(t.userId, (out.get(t.userId) || 0) + 1);
  return out;
}

/** GET /admin/ping —— 存活 + 存储后端标识。 */
function handleAdminPing() {
  return jsonResponse({
    ok: true,
    storage: 'netlify-blobs',
    server_time: nowIso(),
  });
}

/** GET /admin/stats —— 全局计数 + 按用户的用量（最多 100 条）。 */
async function handleAdminStats(store) {
  const users = await adminScanUsers(store);
  const tokens = await adminScanTokens(store);
  const envAgg = await adminScanEnvelopes(store);

  let envelopes = 0;
  for (const a of envAgg.values()) envelopes += a.count;

  return jsonResponse({
    storage: 'netlify-blobs',
    users: users.length,
    tokens: tokens.length,
    envelopes,
    server_time: nowIso(),
    per_user: adminBuildPerUser(users, adminTokenCounts(tokens), envAgg),
  });
}

/** GET /admin/users —— 账号列表（含用量），按 envelopes 降序，最多 100 条。 */
async function handleAdminUsers(store) {
  const users = await adminScanUsers(store);
  const tokenCounts = adminTokenCounts(await adminScanTokens(store));
  const envAgg = await adminScanEnvelopes(store);

  const list = users.map((u) => {
    const agg = envAgg.get(u.user_id) || { count: 0, last: null };
    return {
      user_id: u.user_id,
      username: u.username,
      created_at: u.created_at,
      tokens: tokenCounts.get(u.user_id) || 0,
      envelopes: agg.count,
    };
  });
  list.sort((a, b) =>
    b.envelopes !== a.envelopes
      ? b.envelopes - a.envelopes
      : a.user_id < b.user_id
        ? -1
        : a.user_id > b.user_id
          ? 1
          : 0,
  );
  return jsonResponse({ users: list.slice(0, ADMIN_LIST_MAX) });
}

/**
 * POST /admin/reset —— 清库（all / envelopes / user）。
 *
 * 先列举计数再逐键删除，重复调用第二次计数自然为 0，天然幂等。
 */
async function handleAdminReset(request, store) {
  const { body, error } = await readJsonBody(request);
  if (error) return error;
  const confirm = body && body.confirm != null ? String(body.confirm) : '';
  const scope = body && body.scope != null ? String(body.scope) : '';
  const userId = body && body.user_id != null ? String(body.user_id) : '';

  // 校验顺序与契约一致：先确认口令，再看 scope 合法性，最后看 user_id 是否缺失。
  if (confirm !== 'RESET') return jsonResponse({ error: 'confirm_required' }, 400);
  if (scope === 'user') {
    if (!userId) return jsonResponse({ error: 'user_id_required' }, 400);
  } else if (scope !== 'all' && scope !== 'envelopes') {
    return jsonResponse({ error: 'invalid_scope' }, 400);
  }

  const deleted = { envelopes: 0, tokens: 0, users: 0 };

  if (scope === 'all') {
    deleted.envelopes = await adminDeletePrefix(store, 'e_');
    for (const t of await adminScanTokens(store)) {
      await store.delete(t.key);
      deleted.tokens += 1;
    }
    // 用户按记录逐个确认后再删，只统计真实删掉的账号数。
    for (const u of await adminScanUsers(store)) {
      await store.delete(u.key);
      deleted.users += 1;
    }
  } else if (scope === 'envelopes') {
    deleted.envelopes = await adminDeletePrefix(store, 'e_');
  } else {
    deleted.envelopes = await adminDeletePrefix(store, envelopePrefix(userId));
    for (const t of await adminScanTokens(store)) {
      if (t.userId !== userId) continue;
      await store.delete(t.key);
      deleted.tokens += 1;
    }
    for (const u of await adminScanUsers(store)) {
      if (u.user_id !== userId) continue;
      await store.delete(u.key);
      deleted.users += 1;
    }
  }

  return jsonResponse({ scope, deleted });
}

/** DELETE /admin/user/{id} —— 删单个账号及其数据；账号不存在 → 404。 */
async function handleAdminDeleteUser(store, userId) {
  let userKeyToDelete = null;
  for (const u of await adminScanUsers(store)) {
    if (u.user_id === userId) {
      userKeyToDelete = u.key;
      break;
    }
  }
  if (!userKeyToDelete) return jsonResponse({ error: 'user_not_found' }, 404);

  const envelopes = await adminDeletePrefix(store, envelopePrefix(userId));
  let tokens = 0;
  for (const t of await adminScanTokens(store)) {
    if (t.userId !== userId) continue;
    await store.delete(t.key);
    tokens += 1;
  }
  await store.delete(userKeyToDelete);
  return jsonResponse({ deleted: { envelopes, tokens, users: 1 } });
}

/**
 * GET /admin/export?user_id= —— 导出 envelope 快照（信封形状与 pull 一致）。
 *
 * 单次最多 10000 条；超出置 truncated=true。
 */
async function handleAdminExport(store, url) {
  const userId = (url.searchParams.get('user_id') || '').trim();

  const users = await adminScanUsers(store);
  const picked = (userId ? users.filter((u) => u.user_id === userId) : users).map(
    (u) => ({
      user_id: u.user_id,
      username: u.username,
      created_at: u.created_at,
    }),
  );

  const keys = await store.listKeys(userId ? envelopePrefix(userId) : 'e_');
  const recs = [];
  for (const key of keys) {
    const raw = await store.get(key);
    if (!raw) continue;
    try {
      recs.push(JSON.parse(raw));
    } catch {
      continue;
    }
  }
  recs.sort((a, b) => {
    const ta = a.server_time || '';
    const tb = b.server_time || '';
    if (ta !== tb) return ta < tb ? -1 : 1;
    const ka = String(a.entity_table) + '\u0000' + String(a.entity_id);
    const kb = String(b.entity_table) + '\u0000' + String(b.entity_id);
    return ka < kb ? -1 : ka > kb ? 1 : 0;
  });

  const truncated = recs.length > ADMIN_EXPORT_MAX;
  const envelopes = recs.slice(0, ADMIN_EXPORT_MAX).map((rec) => ({
    device_id: rec.device_id,
    entity_table: rec.entity_table,
    entity_id: rec.entity_id,
    op: rec.op,
    payload: rec.payload ? JSON.parse(rec.payload) : null,
    base_version: rec.base_version,
    updated_at: rec.updated_at,
    deleted_at: rec.deleted_at,
  }));

  return jsonResponse({
    user_id: userId || null,
    exported_at: nowIso(),
    truncated,
    envelopes,
    users: picked,
  });
}

/**
 * /admin/* 分发：返回 Response；未知子路径返回 null（由调用方回落 404）。
 * 鉴权已由 [guardAdmin] 前置完成。
 */
async function routeAdmin(request, store, sub) {
  const method = (request.method || 'GET').toUpperCase();

  if (method === 'GET' && sub === '/ping') return handleAdminPing();
  if (method === 'GET' && sub === '/stats') return await handleAdminStats(store);
  if (method === 'GET' && sub === '/users') return await handleAdminUsers(store);
  if (method === 'POST' && sub === '/reset') return await handleAdminReset(request, store);
  if (method === 'GET' && sub === '/export') {
    return await handleAdminExport(store, new URL(request.url));
  }
  if (method === 'DELETE' && sub.startsWith('/user/')) {
    const raw = sub.slice('/user/'.length);
    if (!raw) return null;
    let userId;
    try {
      userId = decodeURIComponent(raw);
    } catch {
      userId = raw;
    }
    return await handleAdminDeleteUser(store, userId);
  }
  return null;
}

// ---------------- 路由 ----------------

/**
 * 核心分发（测试与生产共用）。
 *
 * 路径判定不依赖文件路由参数：本版由 netlify.toml 的 rewrite 把 ``/``、
 * ``/auth/*``、``/sync/*``、``/admin/*`` 全部转发到同一个函数，内部按
 * ``endsWith`` / 子路径分发（与另两版同构，App 地址不带路径前缀也能用）。
 */
export async function handleFetch(request, store, env = {}) {
  const method = (request.method || 'GET').toUpperCase();
  const url = new URL(request.url);
  const path = url.pathname;

  // 请求体体积守卫（防御纵深）。
  const declaredLen = Number(request.headers.get('content-length') || '0');
  if (Number.isFinite(declaredLen) && declaredLen > kMaxBodyBytes) {
    return jsonResponse(
      { error: `请求体超过 ${Math.floor(kMaxBodyBytes / 1024)}KB 上限。` },
      413,
    );
  }

  // 根路径健康检查：KV 未绑定时也返 200（服务探活 ≠ 存储状态；App 设置页「测试连接」靠它）。
  if (method === 'GET' && path === '/') {
    return jsonResponse({
      ok: true,
      service: SERVICE_NAME,
      version: SERVICE_VERSION,
      runtime: 'netlify-functions-node',
      storage: 'netlify-blobs',
    });
  }

  if (method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (!store) return storeErrorResponse();

  try {
    // 管理接口排在用户路由之前：/admin/* 只认 ADMIN_TOKEN，不碰用户鉴权块。
    const adminSub = adminSubPath(path);
    if (adminSub !== null) {
      const denied = guardAdmin(request, env);
      if (denied) return denied;
      const resp = await routeAdmin(request, store, adminSub);
      return resp || jsonResponse({ error: 'not_found' }, 404);
    }

    if (method === 'POST' && path.endsWith('/auth/register')) {
      return await handleRegister(request, store);
    }
    if (method === 'POST' && path.endsWith('/auth/login')) {
      return await handleLogin(request, store);
    }
    if (
      (method === 'POST' && path.endsWith('/sync/push')) ||
      (method === 'POST' && path.endsWith('/sync/pull')) ||
      (method === 'GET' && path.endsWith('/sync/manifest'))
    ) {
      const ownerId = await resolveUser(request, store);
      if (!ownerId) return jsonResponse({ error: 'unauthorized' }, 401);

      if (method === 'POST' && path.endsWith('/sync/push')) {
        return await handlePush(request, store, ownerId);
      }
      if (method === 'POST' && path.endsWith('/sync/pull')) {
        return await handlePull(request, store, ownerId, env);
      }
      return await handleManifest(store, ownerId);
    }
    return jsonResponse({ error: 'not found' }, 404);
  } catch (e) {
    const msg = e && e.message ? e.message : String(e);
    return jsonResponse({ error: msg }, 500);
  }
}

// ---------------- 内存 store（测试用，零依赖） ----------------

/**
 * 进程内内存实现，暴露与生产 Blobs 适配层一致的接口：
 * ``get(key) -> string|null``、``set(key, string)``、``listKeys(prefix) -> string[]``、
 * ``delete(key)``。测试据此零依赖跑通协议（见 test_protocol.mjs），无需安装
 * @netlify/blobs。
 */
export function makeMemoryStore() {
  const map = new Map();
  return {
    async get(key) {
      const v = map.get(key);
      return v === undefined ? null : v;
    },
    async set(key, value) {
      map.set(key, value);
    },
    async listKeys(prefix) {
      const out = [];
      for (const k of map.keys()) {
        if (k.startsWith(prefix)) out.push(k);
      }
      return out;
    },
    async delete(key) {
      map.delete(key);
    },
    // 仅供测试断言用，生产接口不含。
    _dump: () => new Map(map),
  };
}

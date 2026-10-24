/**
 * AIMindTree 同步中继 · Netlify 版核心逻辑（与 CF / CloudBase / Vercel /
 * EdgeOne 四版**契约逐字一致**，App 端换后端只换地址）。
 *
 * 本文件是「存储无关」的纯逻辑：所有读写都走传入的 `store` 对象
 * （接口见 [makeMemoryStore] / sync.js 里的 Blobs 适配层），因此可以不装
 * 任何外部依赖、用一个内存 store 直接跑协议测试（见 test_protocol.mjs）。
 *
 * 账号（多租户隔离，普通用户自助注册/登录，无需共享 token）：
 * - ``POST /auth/register``  ``{username, password}`` → ``{user_id, token}``
 * - ``POST /auth/login``     ``{username, password}`` → ``{user_id, token}``
 * 同步（均须 ``Authorization: Bearer <token>``，按 token 归属的 user_id 隔离）：
 * - ``POST /sync/push``   ``{device_id, envelopes:[...]}`` → ``{received, accepted, server_time}``
 * - ``POST /sync/pull``   ``{device_id, since|null}``      → ``{envelopes:[...], server_time}``
 * - ``GET  /sync/manifest``                             → ``{count}``
 *
 * 平台适配要点（2026-10-24 依 Netlify 官方文档落实）：
 *
 * 1. **运行时是 Node.js（AWS Lambda），不是 Edge isolate**：完整 Node 运行时，
 *    Web Crypto 在 Node 18+ 已是全局 ``crypto``，PBKDF2 / getRandomValues 直接可用，
 *    与 CF / EdgeOne 版**同一套哈希参数、哈希值可互相移植**（多后端用户迁移无障碍）。
 * 2. **存储用 Netlify Blobs（``@netlify/blobs``）**：KV 风格键值。本版默认
 *    ``consistency: 'strong'``（Blobs 支持强一致，比 EdgeOne KV 的最终一致更稳），
 *    因此 pull 不再依赖 60s 回退窗口——但为跨区复制留 5s 余量更稳妥，见
 *    [kPullLookbackMs]。
 * 3. **Blobs 键名允许 Unicode（≤600B、不能以 / 开头）**：本版仍沿用另四版的
 *    UTF-16 hex 编码键名，保证键格式在五个后端间一致、可迁移。
 * 4. **请求体上限**：Netlify Functions 没有 EdgeOne 那种 1MB 硬限（平台更宽松），
 *    本版把守卫放宽到 4MB（与 CF / CloudBase 版一致），App 端若接入 netlify
 *    后端可沿用 4MB / 6MB 预算，不必收 850KB。
 * 5. **Blobs 没有内置访问控制**：中继函数本身就是网关——所有读写都先过
 *    Bearer 鉴权，未授权一律 401，与另四版一致。
 */

/** 服务标识（健康检查与错误响应用）。 */
const SERVICE_NAME = 'aimindtree-sync-relay';
const SERVICE_VERSION = '1.0.0';

/** CORS：方便 curl / 浏览器手动测试；App 走 dart:io，不需要。 */
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

/**
 * 请求体字节上限（4MB）。
 *
 * Netlify Functions 平台对此比 EdgeOne（1MB）宽松；留 4MB 与 CF / CloudBase 版
 * 对齐。content-length 超过它就直接 413，不读 body——巨包连函数都不进。
 */
const kMaxBodyBytes = 4 * 1024 * 1024;

/**
 * pull 增量起点回退量（5s）。
 *
 * Blobs 默认强一致（本版已开启 ``consistency:'strong'``），写入立即可读；仍留
 * 5s 余量以覆盖跨区域复制的极端边界。测试里可经 store/env 把 lookback 置 0
 * 拿到严格增量语义。
 */
const kPullLookbackMs = 5 * 1000;

/** PBKDF2 迭代次数（与另四版一致，哈希值可互相移植）。 */
const PBKDF2_ITER = 100000;

const MIN_USERNAME = 3;
const MIN_PASSWORD = 8;

// ---------------- 键名编码 ----------------

/** UTF-16 码元 → 四位 hex（与另四版一致，保证键格式可迁移）。 */
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

  for (const e of envelopes) {
    await store.set(
      envelopeKey(ownerId, String(e.entity_table), String(e.entity_id)),
      JSON.stringify({
        device_id: e.device_id,
        entity_table: e.entity_table,
        entity_id: e.entity_id,
        op: e.op,
        payload: e.payload == null ? null : JSON.stringify(e.payload),
        base_version: parseInt(e.base_version, 10) || 0,
        updated_at: e.updated_at,
        deleted_at: e.deleted_at,
        server_time: serverTime,
      }),
    );
  }

  return jsonResponse({
    received: envelopes.length,
    accepted: envelopes.length,
    server_time: serverTime,
  });
}

/**
 * pull 的增量起点：``min(since, now - lookback)``。
 *
 * 对抗跨区域复制边界（见 [kPullLookbackMs]）。since 缺失/不可解析 → 全量。
 * lookback 可用 store/env 的 ``SYNC_PULL_LOOKBACK_MS`` 覆盖（测试置 0 拿严格语义）。
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

/** GET /sync/manifest —— 本用户当前存量 envelope 数。 */
async function handleManifest(store, ownerId) {
  const keys = await store.listKeys(envelopePrefix(ownerId));
  return jsonResponse({ count: keys.length });
}

// ---------------- 路由 ----------------

/**
 * 核心分发（测试与生产共用）。
 *
 * 路径判定不依赖文件路由参数：本版由 netlify.toml 的 rewrite 把 ``/``、
 * ``/auth/*``、``/sync/*`` 全部转发到同一个函数，内部按 ``endsWith`` 后缀分发
 * （与另四版同构，App 地址不带路径前缀也能用）。
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
 * ``get(key) -> string|null``、``set(key, string)``、``listKeys(prefix) -> string[]``。
 * 测试据此零依赖跑通协议（见 test_protocol.mjs），无需安装 @netlify/blobs。
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
    // 仅供测试断言用，生产接口不含。
    _dump: () => new Map(map),
  };
}

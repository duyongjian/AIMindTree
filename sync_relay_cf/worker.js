/**
 * Cloudflare Worker + D1 同步中继（方案 B，多租户账号版）。
 *
 * 与 App 端 ``HttpSyncApi`` / ``SyncAccountApi`` 契约对齐：
 *
 * 账号（多租户隔离，普通用户自助注册/登录，无需共享 SYNC_TOKEN）：
 * - ``POST /auth/register``  ``{username, password}`` → ``{user_id, token}``
 * - ``POST /auth/login``     ``{username, password}`` → ``{user_id, token}``
 *
 * 同步（均须 ``Authorization: Bearer <token>``，按 token 归属的 user_id 隔离）：
 * - ``POST /sync/push``   ``{device_id, envelopes:[...]}`` → ``{received, accepted, server_time}``
 * - ``POST /sync/pull``   ``{device_id, since|null}``      → ``{envelopes:[...], server_time}``
 * - ``GET  /sync/manifest``                             → ``{count}``
 *
 * envelope 字段（与 App ``SyncEnvelope`` 一致）：
 * ``device_id / entity_table / entity_id / op / payload / base_version /
 * updated_at / deleted_at``。服务端只存每个 (owner_id, entity_table, entity_id)
 * 的最新态 + server_time，供增量拉取（pull 按 server_time > since 过滤）。
 *
 * 鉴权：所有 /sync/* 路由要求合法的用户令牌（``sync_tokens`` 中可查到）。
 * 不再依赖共享的 SYNC_TOKEN——每个用户用自己账号的令牌访问自己的命名空间。
 *
 * 密码哈希：PBKDF2-SHA256，随机 16 字节盐，10 万次迭代（Web Crypto）。
 */

// CORS：方便 curl / 浏览器手动测试；App 走 dart:io，不需要。
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

/** 标准 JSON 响应（带 CORS 头）。 */
function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
  });
}

/** 服务端时间戳：ISO 8601 UTC（Z 后缀），与 App 端解析一致。 */
function nowIso() {
  return new Date().toISOString();
}

// ---------------- 字节 / 十六进制 ----------------

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

// ---------------- 密码哈希（PBKDF2-SHA256） ----------------

const PBKDF2_ITER = 100000;

async function pbkdf2(password, salt) {
  const enc = new TextEncoder();
  const keyMaterial = await crypto.subtle.importKey(
    'raw',
    enc.encode(password),
    'PBKDF2',
    false,
    ['deriveBits']
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt, iterations: PBKDF2_ITER, hash: 'SHA-256' },
    keyMaterial,
    256
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

const MIN_USERNAME = 3;
const MIN_PASSWORD = 8;

// ---------------- 账号 ----------------

async function handleRegister(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: 'invalid json' }, 400);
  }
  const username = ((body && body.username) || '').toString().trim();
  const password = (body && body.password) || '';
  if (username.length < MIN_USERNAME) {
    return jsonResponse({ error: `username too short (>=${MIN_USERNAME})` }, 400);
  }
  if (typeof password !== 'string' || password.length < MIN_PASSWORD) {
    return jsonResponse({ error: `password too short (>=${MIN_PASSWORD})` }, 400);
  }
  const existing = await env.DB.prepare(
    'SELECT id FROM sync_users WHERE username = ?'
  ).bind(username).first();
  if (existing) return jsonResponse({ error: 'username taken' }, 409);

  const id = 'u_' + newToken().slice(0, 24);
  const pwHash = await hashPassword(password);
  await env.DB.prepare(
    'INSERT INTO sync_users (id, username, pw_hash, created_at) VALUES (?, ?, ?, ?)'
  ).bind(id, username, pwHash, nowIso()).run();

  const token = await issueToken(env, id);
  return jsonResponse({ user_id: id, token });
}

async function handleLogin(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: 'invalid json' }, 400);
  }
  const username = ((body && body.username) || '').toString().trim();
  const password = (body && body.password) || '';
  const row = await env.DB.prepare(
    'SELECT id, pw_hash FROM sync_users WHERE username = ?'
  ).bind(username).first();
  if (!row) return jsonResponse({ error: 'invalid credentials' }, 401);
  if (!(await verifyPassword(password, row.pw_hash))) {
    return jsonResponse({ error: 'invalid credentials' }, 401);
  }
  const token = await issueToken(env, row.id);
  return jsonResponse({ user_id: row.id, token });
}

/** 签发新会话令牌并落库，返回明文令牌。 */
async function issueToken(env, userId) {
  const token = newToken();
  await env.DB.prepare(
    'INSERT INTO sync_tokens (token, user_id, created_at) VALUES (?, ?, ?)'
  ).bind(token, userId, nowIso()).run();
  return token;
}

/** 从 Bearer 头解析令牌并查归属 user_id；无效/缺失返回 null。 */
async function resolveUser(request, env) {
  const auth = request.headers.get('Authorization') || '';
  const token = auth.toLowerCase().startsWith('bearer ')
    ? auth.slice('bearer '.length).trim()
    : '';
  if (!token) return null;
  const row = await env.DB.prepare(
    'SELECT user_id FROM sync_tokens WHERE token = ?'
  ).bind(token).first();
  return row ? row.user_id : null;
}

// ---------------- 同步（按 owner_id 隔离） ----------------

const ENVELOPE_COLS =
  'owner_id, entity_table, entity_id, device_id, op, payload_json, ' +
  'base_version, updated_at, deleted_at';

/** 把 D1 行还原成 App envelope（payload 反序列化）。 */
function rowToEnvelope(r) {
  return {
    device_id: r.device_id,
    entity_table: r.entity_table,
    entity_id: r.entity_id,
    op: r.op,
    payload: r.payload_json ? JSON.parse(r.payload_json) : null,
    base_version: r.base_version,
    updated_at: r.updated_at,
    deleted_at: r.deleted_at,
  };
}

/** POST /sync/push —— 批量 upsert 每个 (owner_id, entity_table, entity_id) 最新态。 */
async function handlePush(request, env, ownerId) {
  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: 'invalid json' }, 400);
  }
  const envelopes = Array.isArray(body && body.envelopes) ? body.envelopes : [];
  const serverTime = nowIso();

  if (envelopes.length > 0) {
    const stmt = env.DB.prepare(
      `INSERT OR REPLACE INTO sync_envelopes
       (owner_id, entity_table, entity_id, device_id, op, payload_json,
        base_version, updated_at, deleted_at, server_time)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    );
    const batch = envelopes.map((e) =>
      stmt.bind(
        ownerId,
        e.entity_table,
        e.entity_id,
        e.device_id,
        e.op,
        e.payload == null ? null : JSON.stringify(e.payload),
        parseInt(e.base_version, 10) || 0,
        e.updated_at,
        e.deleted_at,
        serverTime
      )
    );
    await env.DB.batch(batch);
  }

  // 双写 `received` 与 `accepted`：App 端 `HttpSyncApi` 优先读 `received`，
  // 旧版 App（只读 `accepted`）也能拿到正确条数，避免「传成功但显示 0 条」。
  return jsonResponse({
    received: envelopes.length,
    accepted: envelopes.length,
    server_time: serverTime,
  });
}

/** POST /sync/pull —— 拉取本用户 since 之后的增量；since 为空 = 全量。 */
async function handlePull(request, env, ownerId) {
  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: 'invalid json' }, 400);
  }
  const since = body && body.since ? body.since : null;

  let rows;
  if (since) {
    rows = await env.DB.prepare(
      `SELECT ${ENVELOPE_COLS} FROM sync_envelopes ` +
        'WHERE owner_id = ? AND server_time > ? ORDER BY server_time'
    )
      .bind(ownerId, since)
      .all();
  } else {
    rows = await env.DB.prepare(
      `SELECT ${ENVELOPE_COLS} FROM sync_envelopes ` +
        'WHERE owner_id = ? ORDER BY server_time'
    )
      .bind(ownerId)
      .all();
  }

  const envelopes = (rows.results || []).map(rowToEnvelope);
  return jsonResponse({ envelopes, server_time: nowIso() });
}

/** GET /sync/manifest —— 本用户当前存量 envelope 数。 */
async function handleManifest(env, ownerId) {
  const row = await env.DB.prepare(
    'SELECT COUNT(*) AS count FROM sync_envelopes WHERE owner_id = ?'
  ).bind(ownerId).first();
  return jsonResponse({ count: row ? row.count : 0 });
}

// ---------------- 路由 ----------------

export default {
  /**
   * @param {Request} request
   * @param {object} env 绑定：{ DB: D1Database }
   */
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    if (method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    try {
      if (method === 'POST' && path.endsWith('/auth/register')) {
        return await handleRegister(request, env);
      }
      if (method === 'POST' && path.endsWith('/auth/login')) {
        return await handleLogin(request, env);
      }

      if (
        (method === 'POST' && path.endsWith('/sync/push')) ||
        (method === 'POST' && path.endsWith('/sync/pull')) ||
        (method === 'GET' && path.endsWith('/sync/manifest'))
      ) {
        const ownerId = await resolveUser(request, env);
        if (!ownerId) return jsonResponse({ error: 'unauthorized' }, 401);

        if (method === 'POST' && path.endsWith('/sync/push')) {
          return await handlePush(request, env, ownerId);
        }
        if (method === 'POST' && path.endsWith('/sync/pull')) {
          return await handlePull(request, env, ownerId);
        }
        return await handleManifest(env, ownerId);
      }

      return jsonResponse({ error: 'not found' }, 404);
    } catch (e) {
      const msg = e && e.message ? e.message : String(e);
      return jsonResponse({ error: msg }, 500);
    }
  },
};

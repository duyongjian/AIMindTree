/**
 * AIMindTree 同步中继 · Vercel 版核心（平台无关的路由 / 账号 / 同步逻辑）。
 *
 * 本文件是 ``sync_relay_cf/worker.js`` 路由逻辑的搬运 + 平台无关化：
 * 输入 ``{method, path, headers, body}``（headers 为普通对象、body 为字符串），
 * 输出 ``{status, headers, body}``（body 为 JSON 字符串）。不碰任何 Vercel 专有
 * 对象；数据访问全部经由注入的 ``store``（见 db.js），便于本地 mock 自测，
 * 将来再迁平台只需换入口文件和 db.js。
 *
 * 契约与 CF 版逐字一致（App 端零改动，只换「同步服务器地址」）：
 * - ``GET  /``               → ``{ok:true, service, version}``
 *   （CF 版此处 404；本版与 sync_relay_cn 一样返回 200，App 的「测试连接」靠它）
 * - ``POST /auth/register``  ``{username, password}`` → ``{user_id, token}``
 * - ``POST /auth/login``     ``{username, password}`` → ``{user_id, token}``
 * - ``POST /sync/push``      ``{device_id, envelopes:[...]}`` → ``{received, accepted, server_time}``
 * - ``POST /sync/pull``      ``{device_id, since|null}``      → ``{envelopes:[...], server_time}``
 * - ``GET  /sync/manifest``  → ``{count}``
 *
 * 所有 ``/sync/*`` 需 ``Authorization: Bearer <token>``（按 token 归属的 user_id
 * 隔离数据）；密码散列 PBKDF2-SHA256，随机 16 字节盐、10 万次迭代、32 字节输出，
 * 存 ``saltHex:hashHex``，校验用定长常量时间比较（与 CF 版参数完全一致，
 * 两个后端的账号哈希可互相移植）。
 */

import crypto from 'node:crypto';

export const SERVICE_NAME = 'aimindtree-sync-relay';
export const SERVICE_VERSION = '1.0.0';

export const MIN_USERNAME = 3;
export const MIN_PASSWORD = 8;

const PBKDF2_ITERATIONS = 100000;
const PBKDF2_KEYLEN = 32; // 256 bit
const SALT_BYTES = 16;
const TOKEN_BYTES = 32;

// CORS：方便 curl / 浏览器手动测试；App 走 dart:io，不需要。
export const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

// ---------------- 响应构造 ----------------

/** 标准 JSON 响应（带 CORS 头）。 */
function jsonResponse(body, status = 200) {
  return {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
    body: JSON.stringify(body),
  };
}

/** 服务端时间戳：ISO 8601 UTC（Z 后缀），与 App 端 DateTime.parse 一致。 */
function nowIso() {
  return new Date().toISOString();
}

// ---------------- 字节 / 十六进制 ----------------

function toHex(buf) {
  return Buffer.from(buf).toString('hex');
}

function fromHex(hex) {
  return Buffer.from(hex, 'hex');
}

/** 定长常量时间比较（防时序侧信道，与 CF 版 safeEqual 等价）。 */
function safeEqual(a, b) {
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8'));
}

/** 生成随机十六进制串。 */
function randomHex(bytes) {
  return toHex(crypto.randomBytes(bytes));
}

// ---------------- 密码散列（PBKDF2-SHA256） ----------------

/**
 * 返回存储串 ``saltHex:hashHex``。用 Node 内置 crypto，不引第三方库；
 * 100k 迭代在 Node 同步执行约几十毫秒，Vercel 函数时长内毫无压力
 * （这也是运行时选 nodejs 而非 edge 的原因）。
 */
function hashPassword(password) {
  const salt = crypto.randomBytes(SALT_BYTES);
  const hash = crypto.pbkdf2Sync(
    Buffer.from(password, 'utf8'),
    salt,
    PBKDF2_ITERATIONS,
    PBKDF2_KEYLEN,
    'sha256'
  );
  return toHex(salt) + ':' + toHex(hash);
}

/** 校验密码：用存储串里的盐重算，并与期望值做常量时间比较。 */
function verifyPassword(password, stored) {
  if (typeof stored !== 'string') return false;
  const sep = stored.indexOf(':');
  if (sep < 0) return false;
  const salt = fromHex(stored.slice(0, sep));
  const expected = stored.slice(sep + 1);
  const hash = crypto.pbkdf2Sync(
    Buffer.from(password, 'utf8'),
    salt,
    PBKDF2_ITERATIONS,
    PBKDF2_KEYLEN,
    'sha256'
  );
  return safeEqual(toHex(hash), expected);
}

/** 生成 32 字节随机十六进制令牌。 */
function newToken() {
  return randomHex(TOKEN_BYTES);
}

// ---------------- 请求解析 ----------------

/**
 * 归一化路径：补前导斜杠、去掉结尾斜杠（根路径 ``/`` 保留）。
 * 路由一律用 ``endsWith`` 后缀匹配（与 CF 版写法一致），触发路径绑成 ``/``
 * 或挂在任何前缀下都能命中。
 */
function normalizePath(path) {
  let p = typeof path === 'string' ? path : '';
  if (!p.startsWith('/')) p = '/' + p;
  while (p.length > 1 && p.endsWith('/')) p = p.slice(0, -1);
  return p;
}

/** 请求头键统一转小写（各平台大小写习惯不确定）。 */
function normalizeHeaders(headers) {
  const out = {};
  if (!headers) return out;
  for (const [k, v] of Object.entries(headers)) out[String(k).toLowerCase()] = v;
  return out;
}

/**
 * 解析 JSON 请求体；空体 / 非法 JSON 返回 null（调用方统一回 400 invalid json，
 * 与 CF 版 request.json() 抛错后的行为一致）。
 */
function parseJsonBody(bodyString) {
  const text = typeof bodyString === 'string' ? bodyString : '';
  if (!text.trim()) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/** 从 Authorization 头取出 Bearer 令牌（大小写不敏感前缀，与 CF 版一致）。 */
function bearerToken(headers) {
  const auth = headers['authorization'] || '';
  const prefix = 'bearer ';
  return auth.toLowerCase().startsWith(prefix) ? auth.slice(prefix.length).trim() : '';
}

// ---------------- 业务处理 ----------------

/**
 * 生成请求处理函数。store 由调用方注入（入口传真实 KV store，自测传内存 mock）。
 * @returns {(req: {method: string, path: string, headers: object, body: string})
 *   => Promise<{status: number, headers: object, body: string}>}
 */
export function createHandler(store) {
  return async function handle({ method = 'GET', path = '/', headers = {}, body = '' }) {
    const m = String(method || 'GET').toUpperCase();
    const h = normalizeHeaders(headers);
    const p = normalizePath(path);

    try {
      if (m === 'OPTIONS') {
        return { status: 204, headers: { ...CORS_HEADERS }, body: '' };
      }

      // 根路径健康检查：App 设置页的「测试连接」会 GET 根路径，CF 版在这里返回
      // 404，用户没法一眼判断是否真的连上，本版改为 200 + 服务标识。
      if (m === 'GET' && p === '/') {
        return jsonResponse({ ok: true, service: SERVICE_NAME, version: SERVICE_VERSION });
      }

      if (m === 'POST' && p.endsWith('/auth/register')) {
        return await handleRegister(store, body);
      }
      if (m === 'POST' && p.endsWith('/auth/login')) {
        return await handleLogin(store, body);
      }

      const needsAuth =
        (m === 'POST' && (p.endsWith('/sync/push') || p.endsWith('/sync/pull'))) ||
        (m === 'GET' && p.endsWith('/sync/manifest'));
      if (needsAuth) {
        const token = bearerToken(h);
        const ownerId = token ? await store.resolveToken(token) : null;
        if (!ownerId) return jsonResponse({ error: 'unauthorized' }, 401);

        if (m === 'POST' && p.endsWith('/sync/push')) {
          return await handlePush(store, body, ownerId);
        }
        if (m === 'POST' && p.endsWith('/sync/pull')) {
          return await handlePull(store, body, ownerId);
        }
        return await handleManifest(store, ownerId);
      }

      return jsonResponse({ error: 'not found' }, 404);
    } catch (e) {
      const msg = e && e.message ? e.message : String(e);
      return jsonResponse({ error: msg }, 500);
    }
  };
}

// ---------------- 账号 ----------------

async function handleRegister(store, bodyString) {
  const body = parseJsonBody(bodyString);
  if (!body) return jsonResponse({ error: 'invalid json' }, 400);

  const username = body.username == null ? '' : String(body.username).trim();
  const password = body.password;
  if (username.length < MIN_USERNAME) {
    return jsonResponse({ error: `username too short (>=${MIN_USERNAME})` }, 400);
  }
  if (typeof password !== 'string' || password.length < MIN_PASSWORD) {
    return jsonResponse({ error: `password too short (>=${MIN_PASSWORD})` }, 400);
  }

  if (await store.getUserByUsername(username)) {
    return jsonResponse({ error: 'username taken' }, 409);
  }

  const id = 'u_' + newToken().slice(0, 24);
  // hsetnx 原子占位，败者同样按 409 处理（对应 D1 username 唯一索引）。
  const created = await store.createUser({
    id,
    username,
    pwHash: hashPassword(password),
    createdAt: nowIso(),
  });
  if (!created) return jsonResponse({ error: 'username taken' }, 409);

  const token = newToken();
  await store.createToken({ token, userId: id, createdAt: nowIso() });
  return jsonResponse({ user_id: id, token });
}

async function handleLogin(store, bodyString) {
  const body = parseJsonBody(bodyString);
  if (!body) return jsonResponse({ error: 'invalid json' }, 400);

  const username = body.username == null ? '' : String(body.username).trim();
  const password = body.password;
  const user = await store.getUserByUsername(username);
  if (!user || typeof password !== 'string' || !verifyPassword(password, user.pwHash)) {
    return jsonResponse({ error: 'invalid credentials' }, 401);
  }

  const token = newToken();
  await store.createToken({ token, userId: user.id, createdAt: nowIso() });
  return jsonResponse({ user_id: user.id, token });
}

// ---------------- 同步（按 owner_id 隔离） ----------------

/** 把存储文档还原成 App envelope（payload 反序列化）。 */
function docToEnvelope(doc) {
  return {
    device_id: doc.device_id,
    entity_table: doc.entity_table,
    entity_id: doc.entity_id,
    op: doc.op,
    payload: doc.payload_json ? JSON.parse(doc.payload_json) : null,
    base_version: doc.base_version,
    updated_at: doc.updated_at,
    deleted_at: doc.deleted_at,
  };
}

/** POST /sync/push —— 批量 upsert 每个 (owner_id, entity_table, entity_id) 最新态。 */
async function handlePush(store, bodyString, ownerId) {
  const body = parseJsonBody(bodyString);
  if (!body) return jsonResponse({ error: 'invalid json' }, 400);

  const envelopes = Array.isArray(body.envelopes) ? body.envelopes : [];
  const serverTime = nowIso();
  if (envelopes.length > 0) {
    await store.upsertEnvelopes(ownerId, envelopes, serverTime);
  }

  // 双写 received 与 accepted：App 端 HttpSyncApi 优先读 received，旧版 App 只读
  // accepted —— 两个字段都返回，避免「传成功但显示 0 条」。
  return jsonResponse({
    received: envelopes.length,
    accepted: envelopes.length,
    server_time: serverTime,
  });
}

/** POST /sync/pull —— 拉取本用户 since 之后的增量；since 为空 = 全量。 */
async function handlePull(store, bodyString, ownerId) {
  const body = parseJsonBody(bodyString);
  if (!body) return jsonResponse({ error: 'invalid json' }, 400);

  const since = body && body.since ? body.since : null;
  const docs = await store.pullSince(ownerId, since);
  return jsonResponse({ envelopes: docs.map(docToEnvelope), server_time: nowIso() });
}

/** GET /sync/manifest —— 本用户当前存量 envelope 数。 */
async function handleManifest(store, ownerId) {
  return jsonResponse({ count: await store.countEnvelopes(ownerId) });
}

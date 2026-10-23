/**
 * AIMindTree 同步中继 · 腾讯云开发 CloudBase 版（云函数 + HTTP 访问服务 + 云数据库）。
 *
 * 这是 ``sync_relay_cf/worker.js``（Cloudflare Worker + D1）的等价实现，原因：
 * Cloudflare 的 IP 段在中国大陆被 TCP 层阻断，CF 版实测连不上；CloudBase 国内直连。
 * **HTTP 契约逐字兼容 CF 版，App 端零改动**，只需把「同步服务器地址」换成新域名。
 *
 * 契约（与 App 端 HttpSyncApi / SyncAccountApi 对齐）：
 * - ``GET  /``                   → ``{ok, service, version}``（健康检查，CF 版此处是 404）
 * - ``POST /auth/register``      ``{username, password}`` → ``{user_id, token}``
 * - ``POST /auth/login``         ``{username, password}`` → ``{user_id, token}``
 * - ``POST /sync/push``          ``{device_id, envelopes:[...]}`` → ``{received, accepted, server_time}``
 * - ``POST /sync/pull``          ``{device_id, since|null}`` → ``{envelopes:[...], server_time}``
 * - ``GET  /sync/manifest``      → ``{count}``
 *
 * 所有 ``/sync/*`` 需 ``Authorization: Bearer <token>``，否则 401 unauthorized。
 * 服务端只存每个 (owner_id, entity_table, entity_id) 的最新态 + server_time；
 * pull 按 ``server_time > since`` 过滤并按 server_time 升序返回。
 *
 * 密码散列：Node 内置 crypto 的 PBKDF2-SHA256，随机 16 字节盐、10 万次迭代、
 * 32 字节输出，存 ``saltHex:hashHex``；校验用定长常量时间比较（``safeEqual``）。
 *
 * HTTP 访问服务的 event / 返回值结构见 README「CloudBase HTTP 访问服务契约」一节。
 */

'use strict';

const crypto = require('crypto');

const { createStore } = require('./db.js');

const SERVICE_NAME = 'aimindtree-sync-relay';
const SERVICE_VERSION = '1.0.0';

const MIN_USERNAME = 3;
const MIN_PASSWORD = 8;

const PBKDF2_ITERATIONS = 100000;
const PBKDF2_KEYLEN = 32; // 256 bit
const SALT_BYTES = 16;
const TOKEN_BYTES = 32;

// 集成响应统一带的 CORS 头，方便 curl / 浏览器直接验证。
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

// ---------------- 集成响应构造 ----------------

/**
 * CloudBase HTTP 访问服务的「集成响应」：只要返回值里带 ``statusCode`` 字段，
 * 网关就会按下面这个结构产生真实 HTTP 响应。
 */
function respond(body, status = 200) {
  return {
    statusCode: status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
    body: JSON.stringify(body),
    isBase64Encoded: false,
  };
}

// ---------------- 工具函数 ----------------

/** 服务端时间戳：ISO 8601 UTC（Z 后缀），与 App 端解析一致。 */
function nowIso() {
  return new Date().toISOString();
}

/** 十六进制编码。 */
function toHex(buf) {
  return Buffer.from(buf).toString('hex');
}

/** 十六进制解码。 */
function fromHex(hex) {
  return Buffer.from(hex, 'hex');
}

/** 定长常量时间比较（防时序侧信道）。 */
function safeEqual(a, b) {
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8'));
}

/** 生成随机十六进制串。 */
function randomHex(bytes) {
  return toHex(crypto.randomBytes(bytes));
}

// ---------------- 密码散列（PBKDF2-SHA256） ----------------

/** 返回存储串 ``saltHex:hashHex``。 */
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

// ---------------- event 解析 ----------------

/**
 * 归一化路径：补前导斜杠、去掉结尾斜杠（根路径 ``/`` 保留）。
 * @param {string} path event.path，例如 ``/api/hello``
 */
function normalizePath(path) {
  let p = typeof path === 'string' ? path : '';
  if (!p.startsWith('/')) p = '/' + p;
  while (p.length > 1 && p.endsWith('/')) p = p.slice(0, -1);
  return p;
}

/**
 * 剥掉 HTTP 访问服务的「触发路径」前缀。
 *
 * 推荐把触发路径绑成 ``/``（所有请求都转给本函数），此时 ``event.path`` 就是业务
 * 路径本身。若绑成了 ``/aimindtree`` 之类，可以把同样的值配到环境变量
 * ``CB_BASE_PATH`` 上，这样 ``GET /aimindtree`` 会被当成健康检查的根请求；
 * 其余路径一律用 ``endsWith`` 匹配（与 CF 版一致），有无前缀都能命中。
 */
function basePath() {
  return normalizePath(process.env.CB_BASE_PATH || '/');
}

function stripBasePath(path) {
  const base = basePath();
  if (base === '/') return path;
  return path === base ? '/' : path;
}

/** 请求头对象一律转小写键，避免网关给的大小写不确定。 */
function normalizeHeaders(headers) {
  const out = {};
  if (!headers) return out;
  for (const [k, v] of Object.entries(headers)) out[String(k).toLowerCase()] = v;
  return out;
}

/**
 * 解析 JSON 请求体；空体 / 非法 JSON 返回 null（调用方统一回 400 ``invalid json``，
 * 与 CF 版保持一致）。
 */
function parseJsonBody(event) {
  const raw = event && typeof event.body === 'string' ? event.body : '';
  // 网关在请求体含二进制时会置 isBase64Encoded=true 并给出 base64 文本。
  const text = event && event.isBase64Encoded ? Buffer.from(raw, 'base64').toString('utf8') : raw;
  if (!text.trim()) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/** 从 Authorization 头取出 Bearer 令牌（缺 Carrier 返回空串）。 */
function bearerToken(headers) {
  const auth = headers['authorization'] || '';
  const prefix = 'bearer ';
  return auth.toLowerCase().startsWith(prefix) ? auth.slice(prefix.length).trim() : '';
}

// ---------------- 业务处理 ----------------

/** 统一处理一个 HTTP 请求；store 由调用方注入（便于本地用内存 mock 自测）。 */
async function handle(store, event) {
  const method = ((event && event.httpMethod) || 'GET').toUpperCase();
  const headers = normalizeHeaders(event && event.headers);
  const path = stripBasePath(normalizePath(event && event.path));

  try {
    if (method === 'OPTIONS') {
      return { statusCode: 204, headers: CORS_HEADERS, body: '', isBase64Encoded: false };
    }

    // 根路径健康检查：App 设置页的「测试连接」会 GET 根路径，CF 版在这里返回 404，
    // 用户没法一眼判断是否真的连上了，本版改为 200 + 服务标识。
    if (method === 'GET' && path === '/') {
      return respond({ ok: true, service: SERVICE_NAME, version: SERVICE_VERSION });
    }

    if (method === 'POST' && path.endsWith('/auth/register')) {
      return await handleRegister(store, event);
    }
    if (method === 'POST' && path.endsWith('/auth/login')) {
      return await handleLogin(store, event);
    }

    const needsAuth =
      (method === 'POST' && (path.endsWith('/sync/push') || path.endsWith('/sync/pull'))) ||
      (method === 'GET' && path.endsWith('/sync/manifest'));
    if (needsAuth) {
      const token = bearerToken(headers);
      const ownerId = token ? await store.resolveToken(token) : null;
      if (!ownerId) return respond({ error: 'unauthorized' }, 401);

      if (method === 'POST' && path.endsWith('/sync/push')) {
        return await handlePush(store, event, ownerId);
      }
      if (method === 'POST' && path.endsWith('/sync/pull')) {
        return await handlePull(store, event, ownerId);
      }
      return await handleManifest(store, ownerId);
    }

    return respond({ error: 'not found' }, 404);
  } catch (e) {
    return respond({ error: e && e.message ? e.message : String(e) }, 500);
  }
}

// ---------------- 账号 ----------------

async function handleRegister(store, event) {
  const body = parseJsonBody(event);
  if (!body) return respond({ error: 'invalid json' }, 400);

  const username = ((body.username == null ? '' : body.username) + '').trim();
  const password = body.password;
  if (username.length < MIN_USERNAME) {
    return respond({ error: `username too short (>=${MIN_USERNAME})` }, 400);
  }
  if (typeof password !== 'string' || password.length < MIN_PASSWORD) {
    return respond({ error: `password too short (>=${MIN_PASSWORD})` }, 400);
  }

  const existing = await store.getUserByUsername(username);
  if (existing) return respond({ error: 'username taken' }, 409);

  const id = 'u_' + randomHex(TOKEN_BYTES).slice(0, 24);
  await store.createUser({
    id,
    username,
    pw_hash: hashPassword(password),
    created_at: nowIso(),
  });
  const token = await store.issueUserToken(id);
  return respond({ user_id: id, token });
}

async function handleLogin(store, event) {
  const body = parseJsonBody(event);
  if (!body) return respond({ error: 'invalid json' }, 400);

  const username = ((body.username == null ? '' : body.username) + '').trim();
  const password = body.password;
  const user = await store.getUserByUsername(username);
  if (!user || typeof password !== 'string' || !verifyPassword(password, user.pw_hash)) {
    return respond({ error: 'invalid credentials' }, 401);
  }
  const token = await store.issueUserToken(user.id);
  return respond({ user_id: user.id, token });
}

// ---------------- 同步（按 owner_id 隔离） ----------------

/** 把 envelope 文档还原成 App 端 SyncEnvelope 结构（payload 反序列化）。 */
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

async function handlePush(store, event, ownerId) {
  const body = parseJsonBody(event);
  if (!body) return respond({ error: 'invalid json' }, 400);

  const envelopes = Array.isArray(body.envelopes) ? body.envelopes : [];
  const serverTime = nowIso();
  if (envelopes.length > 0) {
    await store.upsertEnvelopes(ownerId, envelopes, serverTime);
  }

  // 双写 received 与 accepted：App 端 HttpSyncApi 优先读 received，旧版 App 只读
  // accepted —— 两个字段都返回，避免「传成功但显示 0 条」。
  return respond({
    received: envelopes.length,
    accepted: envelopes.length,
    server_time: serverTime,
  });
}

async function handlePull(store, event, ownerId) {
  const body = parseJsonBody(event);
  if (!body) return respond({ error: 'invalid json' }, 400);

  const since = body.since ? body.since : null;
  const docs = await store.pullSince(ownerId, since);
  return respond({ envelopes: docs.map(docToEnvelope), server_time: nowIso() });
}

async function handleManifest(store, ownerId) {
  return respond({ count: await store.countEnvelopes(ownerId) });
}

// ---------------- CloudBase 云函数入口 ----------------

let cachedStore = null;

/**
 * 由数据库句柄合成业务 store：``db.js`` 的数据层 + 本文件内的令牌签发函数。
 * 抽出来是为了让本地自测能用同一个入口，只是把手柄换成内存 mock。
 */
function makeStore(database) {
  const data = createStore(database);
  return Object.assign({}, data, {
    /** 签发新会话令牌并落库，返回明文令牌。 */
    issueUserToken: async (userId) => await data.createToken(newToken(), userId, nowIso()),
  });
}

/**
 * 懒加载 SDK 并拿到数据层。
 *
 * CloudBase 云函数运行时会自动注入当前环境信息：可以用 ``tcb.SYMBOL_CURRENT_ENV``
 * 让 init() 取「当前函数所在环境」，也可以读环境变量 ``process.env.TCB_ENV``。
 * 这里优先 TCB_ENV（便于同一份代码在多环境显式切换），退回 SYMBOL_CURRENT_ENV。
 * 云函数内调用不需要 secretId / secretKey。
 */
function getStore() {
  if (!cachedStore) {
    // 延迟 require：本地自测时不必安装 @cloudbase/node-sdk。
    const tcb = require('@cloudbase/node-sdk');
    const opts = {};
    if (process.env.TCB_ENV) opts.env = process.env.TCB_ENV;
    else if (tcb.SYMBOL_CURRENT_ENV) opts.env = tcb.SYMBOL_CURRENT_ENV;
    cachedStore = makeStore(tcb.init(opts).database());
  }
  return cachedStore;
}

// CloudBase HTTP 访问服务入口：event 里是 HTTP 请求，返回值是集成响应。
exports.main = async (event, context) => await handle(getStore(), event);

// 导出供本地自测直接驱动（不联网、不需要腾讯云账号）。
exports.handle = handle;
exports.makeStore = makeStore;

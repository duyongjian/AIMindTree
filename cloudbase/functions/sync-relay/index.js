/**
 * AIMindTree 同步中继 · 腾讯云开发 CloudBase 版（云函数 + HTTP 访问服务 + PostgreSQL）。
 *
 * 这是 ``sync_relay_cf/worker.js``（Cloudflare Worker + D1）的等价实现，原因：
 * Cloudflare 的 IP 段在中国大陆被 TCP 层阻断，CF 版实测连不上；CloudBase 国内直连。
 * **HTTP 契约逐字兼容 CF 版，App 端零改动**，只需把「同步服务器地址」换成新域名。
 *
 * ⚠️ 数据层注意：目标 CloudBase 环境是 **PostgreSQL** 环境（不是文档型 NoSQL），
 * 文档型 API 在该环境直接报错。本版数据层（``db.js``）走 ``app.rdb()``
 * （PostgREST 客户端），选型查证过程见 README「数据层选型」一节。
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

/**
 * 统一处理一个 HTTP 请求。
 *
 * 第一个参数可以是 store 对象（本地自测直接传），也可以是「返回 store 的工厂」
 * （云端入口传 ``getStore``）。用工厂是为了把 SDK 初始化推迟到真正需要数据库的
 * 分支：``GET /`` 健康检查因此完全不碰数据库，「SDK / 数据库没起来」与「业务
 * 逻辑出错」能在响应体里区分开，排查时不用猜。
 */
async function handle(storeOrFactory, event) {
  const method = ((event && event.httpMethod) || 'GET').toUpperCase();
  const headers = normalizeHeaders(event && event.headers);
  const path = stripBasePath(normalizePath(event && event.path));
  const store = typeof storeOrFactory === 'function' ? storeOrFactory : () => storeOrFactory;

  try {
    if (method === 'OPTIONS') {
      return { statusCode: 204, headers: CORS_HEADERS, body: '', isBase64Encoded: false };
    }

    // 根路径健康检查：App 设置页的「测试连接」会 GET 根路径，CF 版在这里返回 404，
    // 用户没法一眼判断是否真的连上了，本版改为 200 + 服务标识。
    if (method === 'GET' && path === '/') {
      return respond({
        ok: true,
        service: SERVICE_NAME,
        version: SERVICE_VERSION,
        // 运行期自描述：确认云端跑在哪个 Node、Web 标准全局对象是否可用
        // （决定入口走 Web Response 分支还是集成响应分支）。
        runtime: {
          node: process.version,
          web_globals: typeof Response === 'function' && typeof Headers === 'function',
        },
      });
    }

    if (method === 'POST' && path.endsWith('/auth/register')) {
      return await handleRegister(store(), event);
    }
    if (method === 'POST' && path.endsWith('/auth/login')) {
      return await handleLogin(store(), event);
    }

    const needsAuth =
      (method === 'POST' && (path.endsWith('/sync/push') || path.endsWith('/sync/pull'))) ||
      (method === 'GET' && path.endsWith('/sync/manifest'));
    if (needsAuth) {
      const token = bearerToken(headers);
      const ownerId = token ? await store().resolveToken(token) : null;
      if (!ownerId) return respond({ error: 'unauthorized' }, 401);

      if (method === 'POST' && path.endsWith('/sync/push')) {
        return await handlePush(store(), event, ownerId);
      }
      if (method === 'POST' && path.endsWith('/sync/pull')) {
        return await handlePull(store(), event, ownerId);
      }
      return await handleManifest(store(), ownerId);
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

/** 把 PG 行还原成 App 端 SyncEnvelope 结构（payload 反序列化）。 */
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
  const rows = await store.pullSince(ownerId, since);
  return respond({ envelopes: rows.map(rowToEnvelope), server_time: nowIso() });
}

async function handleManifest(store, ownerId) {
  return respond({ count: await store.countEnvelopes(ownerId) });
}

// ---------------- CloudBase 云函数入口 ----------------

let cachedStore = null;

/**
 * 由 PostgreSQL 客户端合成业务 store：``db.js`` 的数据层 + 本文件内的令牌签发函数。
 * 抽出来是为了让本地自测能用同一个入口，只是把客户端换成内存 mock。
 */
function makeStore(pg) {
  const data = createStore(pg);
  return Object.assign({}, data, {
    /** 签发新会话令牌并落库，返回明文令牌。 */
    issueUserToken: async (userId) => await data.createToken(newToken(), userId, nowIso()),
  });
}

/**
 * 组装 ``tcb.init()`` 的选项。
 *
 * 抽成纯函数（入参只有 SDK 模块和环境变量）是为了能在本地自测里直接断言，
 * 不用真连腾讯云。
 *
 * @param {object} tcb require('@cloudbase/node-sdk') 的返回值
 */
function buildInitOptions(tcb) {
  const opts = {};
  if (process.env.TCB_ENV) opts.env = process.env.TCB_ENV;
  else if (tcb.SYMBOL_CURRENT_ENV) opts.env = tcb.SYMBOL_CURRENT_ENV;
  // API Key（服务端凭据）→ PostgREST 侧的 service_role。
  //
  // ⚠️ 必须在这里显式传，不能只配环境变量 CLOUDBASE_APIKEY。SDK 的
  // normalizeConfig 有一条明确注释：「不从环境变量读取 CLOUDBASE_APIKEY 并
  // 固化到 config」，而 auth.getClientCredential() 只认 config.accessKey。
  // 环境变量那条回退发生在 requester 内部，且会被匿名令牌盖掉——结果是
  // PostgREST 侧落到 anon 角色，anon 默认只有 SELECT，一切写入都报
  // `permission denied for table xxx`（2026-10-24 实测：register 时
  // SELECT 成功、INSERT 失败，据此定位到角色）。
  //
  // 传了之后链路（已用真 SDK 本地验证）：
  //   tcb.init({accessKey}) → config.accessKey 固化
  //   → getClientCredential() 直接返回**裸字符串** accessKey（不是对象）
  //   → PG 客户端取 .access_token 得 undefined
  //   → requester 里 args.token 为空，改走 `else if (accessKey)` 分支
  //   → 请求带 Authorization: Bearer <API Key> → 服务端识别为 service_role。
  // service_role 可绕过 RLS，仅限服务端使用，切勿下发到客户端。
  if (process.env.CLOUDBASE_APIKEY) opts.accessKey = process.env.CLOUDBASE_APIKEY;
  return opts;
}

/**
 * 懒加载 SDK 并拿到数据层（PostgreSQL 客户端）。
 *
 * CloudBase 云函数运行时会自动注入当前环境信息：可以用 ``tcb.SYMBOL_CURRENT_ENV``
 * 让 init() 取「当前函数所在环境」，也可以读环境变量 ``process.env.TCB_ENV``。
 * 这里优先 TCB_ENV（便于同一份代码在多环境显式切换），退回 SYMBOL_CURRENT_ENV。
 * 云函数内调用不需要 secretId / secretKey。
 *
 * 注意是 ``rdb()`` 而不是 ``database()``：后者是文档型（NoSQL）数据库入口，
 * 在 PostgreSQL 环境会直接报错；前者才是 PG 的 PostgREST 客户端。
 */
function getStore() {
  if (!cachedStore) {
    // 延迟 require：本地自测时不必安装 @cloudbase/node-sdk。
    const tcb = require('@cloudbase/node-sdk');
    const app = tcb.init(buildInitOptions(tcb));
    if (typeof app.rdb !== 'function') {
      throw new Error(
        '当前 @cloudbase/node-sdk 不支持 rdb()（PostgreSQL 客户端），' +
          '请升级到 ^3.18.7 或更高版本'
      );
    }
    cachedStore = makeStore(app.rdb());
  }
  return cachedStore;
}

// ---------------- CloudBase 云函数入口 ----------------
//
// CloudBase 的 HTTP 访问服务把请求转给云函数时有**两种**投递形态，两者要求的
// 返回值形状正好相反，搞错就是「400 + 空 body + content-disposition: attachment」：
//
//   1) 事件函数：event 是 API 网关风格的普通对象
//      （{httpMethod, path, headers, body, isBase64Encoded}），
//      必须返回集成响应 {statusCode, headers, body}；
//   2) Web 函数：event 是 Web 标准 Request 对象，必须返回 Response 对象。
//
// 2026-10-24 实测记录：本函数的网关路由 ``upstreamResourceType=WEB_SCF``，
// 云端按 Web 函数形态投递；而当时的入口按事件函数写、返回普通对象，网关一律回
// 400（响应头 ``x-cloudbase-upstream-status-code: 400``、``content-length: 0``）。
// 注意：**把返回值裁剪成 {statusCode, body} 两字段也依然是 400** —— 所以根因不是
// 「多带了 headers / isBase64Encoded」，而是整个返回形状不被识别。
//
// 因此这里按 ``isWebRequest(event)`` 自动分流：收到 Request 就回 Response，
// 收到普通对象就回集成响应。两种形态都覆盖，将来改路由配置、换运行时版本都不用
// 再动入口。

/** 判断入参是不是 Web 标准 Request（真 Request 的 headers 才有 .get 方法）。 */
function isWebRequest(ev) {
  if (!ev || typeof ev !== 'object') return false;
  if (typeof ev.url !== 'string' || typeof ev.method !== 'string') return false;
  const h = ev.headers;
  return !!h && typeof h.get === 'function';
}

/** Web Request → 事件函数风格的 event（复用同一套 handle 业务逻辑）。 */
async function webRequestToEvent(req) {
  const u = new URL(req.url);
  const headers = {};
  if (req.headers && typeof req.headers.forEach === 'function') {
    req.headers.forEach((v, k) => {
      headers[k] = v;
    });
  }
  let body = '';
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    body = await req.text();
  }
  return {
    httpMethod: req.method,
    path: u.pathname + u.search,
    headers,
    body,
    isBase64Encoded: false,
  };
}

/** 集成响应 → Web 标准 Response（Web 函数形态的返回值）。 */
function toWebResponse(r) {
  const h = new Headers(r.headers || {});
  if (!h.has('content-type')) h.set('content-type', 'application/json; charset=utf-8');
  return new Response(r.body == null ? '' : String(r.body), {
    status: r.statusCode || 200,
    headers: h,
  });
}

/** 兜底：handle 意外返回了不带 statusCode 的东西，也别让网关看到空响应。 */
function normalizeIntegrated(r) {
  if (r && typeof r.statusCode === 'number') return r;
  return respond({ error: 'internal: handler returned no statusCode' }, 500);
}

/**
 * 看门狗超时：``handle`` 可能因为 SDK 初始化 / 数据库连接卡住（云端
 * ``invokeFunction`` 实测出现过 "Invoking task timed out after 3 seconds"）。
 * 超时就回 504 + 诊断信息，而不是让网关干等到函数 timeout——
 * 「卡住」和「报错」在响应体里一眼可分。
 */
const HANDLER_TIMEOUT_MS = 25000;

/**
 * 数据层工厂：默认是真实的 ``getStore``（懒加载 @cloudbase/node-sdk + PostgreSQL）。
 *
 * 云端入口用的是模块级这一个引用，测试可以用 ``__setStoreFactoryForTest`` 换成
 * 内存 store，从而在**不联网、不装腾讯云凭据**的前提下把 ``exports.main``
 * 的双形态分流逻辑也跑进断言——正是 2026-10-24 400 事故里唯一没被覆盖的那段。
 */
let storeFactory = getStore;

/** 仅供本地自测替换数据层工厂；传非函数即恢复默认。 */
function setStoreFactoryForTest(fn) {
  storeFactory = typeof fn === 'function' ? fn : getStore;
  cachedStore = null; // 顺手清掉缓存，避免上一个用例的 store 漏到下一个
  return storeFactory;
}

exports.main = async (event, context) => {
  const web = isWebRequest(event);

  let ev = event;
  if (web) {
    try {
      ev = await webRequestToEvent(event);
    } catch (e) {
      return toWebResponse(
        respond({ error: 'bad request', detail: e && e.message ? e.message : String(e) }, 400)
      );
    }
  } else if (typeof event === 'string') {
    // 有些调用方会把 event 序列化成 JSON 字符串投递。
    try {
      ev = JSON.parse(event);
    } catch {
      ev = {};
    }
  }

  let r;
  let timer = null;
  const watchdog = new Promise((resolve) => {
    timer = setTimeout(
      () => resolve(respond({ error: 'handler timeout', ms: HANDLER_TIMEOUT_MS }, 504)),
      HANDLER_TIMEOUT_MS
    );
  });
  try {
    r = await Promise.race([Promise.resolve(handle(storeFactory, ev || {})), watchdog]);
  } catch (e) {
    r = respond(
      {
        error: 'handler failed',
        detail: e && e.message ? e.message : String(e),
        stack: e && e.stack ? String(e.stack).split('\n').slice(0, 4) : null,
      },
      500
    );
  } finally {
    if (timer) clearTimeout(timer);
  }

  r = normalizeIntegrated(r);
  // Web 函数形态必须回 Response 对象；事件函数形态回集成响应。
  // （官方示例只回 {statusCode, body} 两字段；旧版网关上多带字段行为不确定，
  //  保守起见事件形态只回这两字段，CORS 头交给网关与调用方。）
  return web ? toWebResponse(r) : { statusCode: r.statusCode, body: r.body };
};

// 导出供本地自测直接驱动（不联网、不需要腾讯云账号）。
exports.handle = handle;
exports.makeStore = makeStore;
exports.setStoreFactoryForTest = setStoreFactoryForTest;
exports.buildInitOptions = buildInitOptions;

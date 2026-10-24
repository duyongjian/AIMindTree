/**
 * AIMindTree 同步中继 · EdgeOne Pages 版（Edge Functions + KV）。
 *
 * 与 Cloudflare / CloudBase / Vercel 三版**契约逐字一致**（同样的 5 端点、
 * 同样字段、同样 Bearer 鉴权），App 侧换后端只换地址：
 *
 * 账号（多租户隔离，普通用户自助注册/登录，无需共享 token）：
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
 * 的最新态 + server_time，供增量拉取。
 *
 * 平台适配要点（2026-10-24 依 EdgeOne 官方文档落实，勿凭 CF 经验改）：
 *
 * 1. **路由是文件系统**：本文件是 ``edge-functions/[[default]].js``（根级
 *    **可选 catch-all**，``[[ ]]`` 双括号意味着它**也匹配根路径 ``/``**），
 *    因此所有路径（``/``、``/auth/*``、``/sync/*``）都由这一个文件的分发逻辑
 *    应答，无需再放 ``index.js``（放反而会和 catch-all 抢 ``/`` 路由）。
 * 2. **KV 命名空间是全局变量，不在 context.env**（官方 KV 文档与 Makers
 *    skill 双重确认）。本代码按 ``env.SYNC_KV`` → ``globalThis.SYNC_KV``
 *    顺序探测，控制台绑定 Namespace 时 **Variable Name 必须填 SYNC_KV**。
 * 3. **KV 键名只允许数字/字母/下划线**（≤512B）——owner/table/entity 一律
 *    先做 UTF-16  hex 编码再拼键，``:``/``.``/``/`` 等分隔符全部禁用。
 * 4. **KV 是最终一致（全球 60s 内同步）**：pull 的 since 起点自动回退
 *    [kPullLookbackMs]，把仍在传播中的写入捞回来；App 侧 apply 是幂等
 *    upsert，重复投递无害（计入 skipped）。
 * 5. **请求体上限 1MB**（平台限制）：超过 [kMaxBodyBytes] 直接 413，
 *    绝不缓冲巨包。单条 envelope 超过约 900KB（典型是大图片附件的
 *    data_base64）在任何后端都存不下，属于已知限制，见 README。
 * 6. 运行时仅 JavaScript（ES2023+）、CPU 200ms/次——PBKDF2 10 万次迭代
 *    走 Web Crypto 原生实现，不占 JS CPU 预算（与 CF 版同参数、哈希互通）。
 *
 * 密码哈希：PBKDF2-SHA256，随机 16 字节盐，10 万次迭代（Web Crypto），
 * 存储串 ``saltHex:hashHex``，明文不落库。
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
 * 请求体字节上限（900KB）。
 *
 * 平台硬限制 1MB；留 ~100KB 给头部与 JSON 结构开销。content-length 超过
 * 它就直接 413，不读 body——巨包连函数都不进。
 */
const kMaxBodyBytes = 900 * 1024;

/**
 * pull 增量起点回退量（65s）。
 *
 * KV 全球最终一致同步窗口约 60s：设备 A push 后立刻在设备 B pull，可能
 * 还没同步到 B 命中的边缘节点。把 since 起点回退 65s，漏网写入会在下一
 * 次 pull 被捞回；重复投递的 envelope 经 App 幂等 apply（计 skipped），
 * 不会造成重复数据。
 */
const kPullLookbackMs = 65 * 1000;

/** PBKDF2 迭代次数（与 CF / Vercel 版一致，哈希值可互相移植）。 */
const PBKDF2_ITER = 100000;

const MIN_USERNAME = 3;
const MIN_PASSWORD = 8;

// ---------------- KV 访问 ----------------

/**
 * 取 KV 命名空间客户端；未绑定返回 null（调用方回 503 + 可读指引）。
 *
 * 兼容两种注入形态：``env.SYNC_KV``（部分版本挂在 env）与
 * ``globalThis.SYNC_KV``（官方文档口径：全局变量）。探测顺序不影响结果——
 * 只有一边存在。
 */
function resolveKv(env) {
  const fromEnv = env && env.SYNC_KV;
  if (fromEnv) return fromEnv;
  const fromGlobal = typeof globalThis !== 'undefined' && globalThis.SYNC_KV;
  return fromGlobal || null;
}

// ---------------- 键名编码 ----------------

/**
 * UTF-16 码元 → 四位 hex。
 *
 * KV 键名只允许 [A-Za-z0-9_]（官方文档：≤512B、仅数字字母下划线），
 * 而 username / entity_table / entity_id 可能含中文、点、斜杠等字符，
 * 全部 hex 化后再拼键。逆变换见 [hexDecode]。
 */
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

function kvNotBoundResponse() {
  return jsonResponse(
    {
      ok: false,
      error:
        'KV 未绑定：请在 EdgeOne Pages 控制台 → KV Storage → Bind Namespace，' +
        'Variable Name 填 SYNC_KV（大小写敏感），然后重新部署。',
    },
    503,
  );
}

/**
 * 读 JSON body；超限/畸形分别回 413 / 400。
 *
 * 先看 content-length 拒巨包（不读 body）；再按文本长度兜底校验
 * （chunked 传输没有 content-length）。
 */
async function readJsonBody(request) {
  const len = Number(request.headers.get('content-length') || '0');
  if (Number.isFinite(len) && len > kMaxBodyBytes) {
    return {
      error: jsonResponse(
        {
          error:
            `请求体超过 ${Math.floor(kMaxBodyBytes / 1024)}KB 上限` +
            '（EdgeOne Pages 限制 1MB）。大图片附件请换 CF / Netlify 后端同步。',
        },
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
        {
          error:
            `请求体超过 ${Math.floor(kMaxBodyBytes / 1024)}KB 上限` +
            '（EdgeOne Pages 限制 1MB）。大图片附件请换 CF / Netlify 后端同步。',
        },
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

async function handleRegister(request, kv) {
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

  // KV 没有原子 HSETNX，「先查后插」在极端并发同民注册下有覆盖风险
  // （个人单用户场景可忽略；后注册者覆盖 user 记录，但双方令牌与
  // envelope 命名空间各自独立，不串数据）。已知限制，见 README。
  const existing = await kv.get(userKey(username));
  if (existing) return jsonResponse({ error: 'username taken' }, 409);

  const id = 'u_' + newToken().slice(0, 24);
  const pwHash = await hashPassword(password);
  await kv.put(
    userKey(username),
    JSON.stringify({ id, username, pw_hash: pwHash, created_at: nowIso() }),
  );

  const token = await issueToken(kv, id);
  return jsonResponse({ user_id: id, token });
}

async function handleLogin(request, kv) {
  const { body, error } = await readJsonBody(request);
  if (error) return error;
  const username = ((body && body.username) || '').toString().trim();
  const password = (body && body.password) || '';
  const raw = await kv.get(userKey(username));
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
  const token = await issueToken(kv, row.id);
  return jsonResponse({ user_id: row.id, token });
}

/** 签发新会话令牌并落库，返回明文令牌。 */
async function issueToken(kv, userId) {
  const token = newToken();
  await kv.put(tokenKey(token), JSON.stringify({ userId, createdAt: nowIso() }));
  return token;
}

/** 从 Bearer 头解析令牌并查归属 user_id；无效/缺失返回 null。 */
async function resolveUser(request, kv) {
  const auth = request.headers.get('Authorization') || '';
  const token = auth.toLowerCase().startsWith('bearer ')
    ? auth.slice('bearer '.length).trim()
    : '';
  if (!token) return null;
  const raw = await kv.get(tokenKey(token));
  if (!raw) return null;
  try {
    const row = JSON.parse(raw);
    return row && row.userId ? row.userId : null;
  } catch {
    return null;
  }
}

// ---------------- 同步（按 owner_id 隔离） ----------------

/** POST /sync/push —— 逐 envelope upsert（每键一次 put，天然无锁）。 */
async function handlePush(request, kv, ownerId) {
  const { body, error } = await readJsonBody(request);
  if (error) return error;
  const envelopes = Array.isArray(body && body.envelopes) ? body.envelopes : [];
  const serverTime = nowIso();

  for (const e of envelopes) {
    // 与 App SyncEnvelope 对齐的完整字段落库（payload 以 JSON 字符串存，
    // 与 CF / Vercel 版一致）；server_time 服务端统一签发。
    await kv.put(
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

  // 双写 received 与 accepted：App 端 HttpSyncApi 优先读 received，
  // 旧版 App（只读 accepted）也能拿到正确条数。
  return jsonResponse({
    received: envelopes.length,
    accepted: envelopes.length,
    server_time: serverTime,
  });
}

/**
 * pull 的增量起点：``min(since, now - lookback)``。
 *
 * 对抗 KV 60s 最终一致窗口（见 [kPullLookbackMs]）。since 缺失/不可解析
 * → 全量。返回 ISO 字符串或 null（全量）。
 *
 * lookback 默认 [kPullLookbackMs]，可用环境变量 ``SYNC_PULL_LOOKBACK_MS``
 * 覆盖（测试里置 0 即可拿到严格增量语义，不影响生产默认）。
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

/** 遍历某前缀下全部键名（KV list 每页最多 256，cursor 翻页）。 */
async function listAllKeys(kv, prefix) {
  const keys = [];
  let cursor;
  do {
    const page = await kv.list({ prefix, limit: 256, cursor });
    const items = (page && page.keys) || [];
    for (const item of items) {
      // 官方文档字段是 key；个别模板/文档写作 name，两者都认。
      const name = item && (item.key !== undefined ? item.key : item.name);
      if (typeof name === 'string') keys.push(name);
    }
    cursor = page && page.cursor ? page.cursor : undefined;
    if (page && page.complete === false && !cursor) break; // 防御：无尽翻页
  } while (cursor);
  return keys;
}

/** POST /sync/pull —— 拉取本用户 since 之后的增量；since 为空 = 全量。 */
async function handlePull(request, kv, ownerId, env) {
  const { body, error } = await readJsonBody(request);
  if (error) return error;
  const since = effectiveSince(body && body.since ? body.since : null, env);

  const keys = await listAllKeys(kv, envelopePrefix(ownerId));
  const recs = [];
  for (const key of keys) {
    const raw = await kv.get(key);
    if (!raw) continue; // 传播中的删除/未同步：跳过
    let rec;
    try {
      rec = JSON.parse(raw);
    } catch {
      continue;
    }
    if (since && rec.server_time && rec.server_time <= since) continue;
    recs.push(rec);
  }
  // 按 server_time 升序（App 侧按时间顺序 apply）；并列时按键名稳定排序。
  // 注意：排序作用在「带 server_time 的原始记录」上，再映射成 envelope，
  // 否则返回对象里不含 server_time，排序会退化成按键名（与契约不一致）。
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
async function handleManifest(kv, ownerId) {
  const keys = await listAllKeys(kv, envelopePrefix(ownerId));
  return jsonResponse({ count: keys.length });
}

// ---------------- 路由 ----------------

/**
 * EdgeOne Pages 入口（``edge-functions/[[default]].js``，根级 catch-all）。
 *
 * 路径判定不依赖文件路由参数：本文件匹配所有多段路径，内部按
 * ``endsWith('/auth/register')`` 等后缀分发（与 CF / CN 版同构，
 * App 地址不带路径前缀也能用）。
 */
export async function onRequest(context) {
  const request = context.request;
  return handleFetch(request, context.env);
}

/**
 * 核心分发（测试直接驱动它，无需 EdgeOne 运行时）。
 *
 * 导出两个名字：[onRequest] 给平台路由用，[handleFetch] 给 Node 测试用。
 */
export async function handleFetch(request, env) {
  const method = (request.method || 'GET').toUpperCase();
  const url = new URL(request.url);
  const path = url.pathname;

  // 请求体体积守卫（防御纵深）：任何超过 [kMaxBodyBytes] 的请求在路由/鉴权/
  // 落库之前直接 413，绝不缓冲巨包（EdgeOne 平台硬限 1MB，这里是安全网）。
  const declaredLen = Number(request.headers.get('content-length') || '0');
  if (Number.isFinite(declaredLen) && declaredLen > kMaxBodyBytes) {
    return jsonResponse(
      {
        error:
          `请求体超过 ${Math.floor(kMaxBodyBytes / 1024)}KB 上限` +
          '（EdgeOne Pages 限制 1MB）。大图片附件请换 CF / Netlify 后端同步。',
      },
      413,
    );
  }

  // 根路径健康检查：先判，KV 未绑定时也返 200（服务探活 ≠ KV 状态；
  // 与 Vercel / CN 版一致，App 设置页「测试连接」靠它一眼判断是否连上）。
  if (method === 'GET' && path === '/') {
    return jsonResponse({
      ok: true,
      service: SERVICE_NAME,
      version: SERVICE_VERSION,
      runtime: 'edgeone-pages-edge-functions',
    });
  }

  if (method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  const kv = resolveKv(env);
  if (!kv) return kvNotBoundResponse();

  try {
    if (method === 'POST' && path.endsWith('/auth/register')) {
      return await handleRegister(request, kv);
    }
    if (method === 'POST' && path.endsWith('/auth/login')) {
      return await handleLogin(request, kv);
    }
    if (
      (method === 'POST' && path.endsWith('/sync/push')) ||
      (method === 'POST' && path.endsWith('/sync/pull')) ||
      (method === 'GET' && path.endsWith('/sync/manifest'))
    ) {
      const ownerId = await resolveUser(request, kv);
      if (!ownerId) return jsonResponse({ error: 'unauthorized' }, 401);

      if (method === 'POST' && path.endsWith('/sync/push')) {
        return await handlePush(request, kv, ownerId);
      }
      if (method === 'POST' && path.endsWith('/sync/pull')) {
        return await handlePull(request, kv, ownerId, env);
      }
      return await handleManifest(kv, ownerId);
    }
    return jsonResponse({ error: 'not found' }, 404);
  } catch (e) {
    const msg = e && e.message ? e.message : String(e);
    return jsonResponse({ error: msg }, 500);
  }
}

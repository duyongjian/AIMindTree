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
 * - ``POST /sync/push``   ``{device_id, envelopes:[...]}`` → ``{received, accepted, skipped, server_time, versions}``
 * - ``POST /sync/pull``   ``{device_id, since|null}``      → ``{envelopes:[...], server_time}``
 * - ``GET  /sync/manifest``                             → ``{count, max_version}``
 *
 * 管理接口（与 Netlify 版逐字一致，供本地管理后台调用；``Authorization: Bearer
 * <ADMIN_TOKEN>``，未配置 ADMIN_TOKEN 时全部 404，令牌不符 401）：
 * - ``GET  /admin/ping`` / ``/admin/stats`` / ``/admin/users`` / ``/admin/export``
 * - ``POST /admin/reset`` ``{scope, user_id?, confirm:"RESET"}``
 * - ``DELETE /admin/user/{id}``
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
// 含 DELETE：浏览器端管理面板直发 ``DELETE /admin/user/{id}`` 时预检必须放行。
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
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
  // 服务端权威版本号映射：`<entity_table>:<entity_id>` → 新分配的版本。
  const versions = {};
  // 被防陈旧守卫跳过（未写入）的键，格式 `<entity_table>:<entity_id>`。
  const skipped = [];

  if (envelopes.length > 0) {
    const stmt = env.DB.prepare(
      `INSERT OR REPLACE INTO sync_envelopes
       (owner_id, entity_table, entity_id, device_id, op, payload_json,
        base_version, updated_at, deleted_at, server_time)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    );
    const batch = [];
    for (const e of envelopes) {
      let existing = 0;
      const row = await env.DB.prepare(
        'SELECT base_version FROM sync_envelopes ' +
          'WHERE owner_id = ? AND entity_table = ? AND entity_id = ?'
      )
        .bind(ownerId, e.entity_table, e.entity_id)
        .first();
      if (row && row.base_version != null) existing = Number(row.base_version) || 0;
      const incoming = parseInt(e.base_version, 10) || 0;
      // 防陈旧覆盖：客户端声明版本 >= 服务端现有版本才接受其 payload 并递增；
      // 若声明版本落后（说明它推的是过期本地副本，常见於「上传」时对未拉取过
      // 的设备做全量快照重推），则保留服务端现有内容与版本、不写入也不递增，
      // 避免把云端较新内容翻回旧内容。App 端 saveNote 每次编辑都会 bump 本地
      // 版本，正常上行不会触发此分支。回写的 versions 仍取服务端权威版本，让
      // 客户端 adoption 对齐、不被卡死。
      if (incoming >= existing) {
        const newVer = Math.max(existing, incoming) + 1;
        versions[`${e.entity_table}:${e.entity_id}`] = newVer;
        batch.push(
          stmt.bind(
            ownerId,
            e.entity_table,
            e.entity_id,
            e.device_id,
            e.op,
            e.payload == null ? null : JSON.stringify(e.payload),
            newVer,
            e.updated_at,
            e.deleted_at,
            serverTime
          )
        );
      } else {
        const vk = `${e.entity_table}:${e.entity_id}`;
        skipped.push(vk);
        // 同批该 key 前面已有 accepted envelope 时，versions[vk] 已被抬到更高版本；
        // 这里取 max 防止把已分配的高版本回退成 existing（否则 App adopt 到低于
        // 云端实际版本的值，下一轮更容易再次 stale）。
        versions[vk] = Math.max(versions[vk] ?? 0, existing);
        // 跳过 INSERT：保留服务端现有 payload / server_time（不覆盖、不递增）。
        // 不写 store、也不刷新 server_time：自愈靠 App 收到 skipped 后 adoption
        // 对齐 base_version → 自动重推，重推命中覆盖分支才写入新 payload + 新
        // server_time。若在此刷新 server_time，对端增量 pull 会拿到「云端旧
        // payload + 合法高 base_version」，LWW 判远端更新后主动把旧正文写下去，
        // 反而扩大数据丢失；让旧行暂留 since 游标之外、等重推完成更安全。
        // 读改写该行还会引入并发 CAS 竞态。
      }
    }
    await env.DB.batch(batch);
  }

  // 双写 `received` 与 `accepted`：新版 App 优先读 `accepted`（真实写入数），
  // 缺该字段时回落 `received` 以兼容旧中继；`received` 始终为收到的 envelope 总数。
  return jsonResponse({
    received: envelopes.length,
    accepted: envelopes.length - skipped.length,
    skipped,
    server_time: serverTime,
    versions,
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

/**
 * GET /sync/manifest —— 本用户当前存量 envelope 数与最大版本号。
 *
 * 响应（与 EdgeOne / Netlify 版**逐字一致**）：
 * ``{count, max_version}``；``count`` 保留原字段以兼容只读它的旧版 App。
 *
 * ``max_version`` 是**逐实体修订号**（不是全局 generation）：服务端在 push 时
 * 对每个实体算 ``max(既有, 客户端声明) + 1``，因此它只是「命名空间内被改得
 * 最狠的那个实体改了多少次」，两端数字不必天然相等，只作总览参考。
 * 空命名空间下 SQLite 的 ``MAX()`` 返回 NULL → 回落 0。
 */
async function handleManifest(env, ownerId) {
  const row = await env.DB.prepare(
    'SELECT COUNT(*) AS count, MAX(base_version) AS max_version ' +
      'FROM sync_envelopes WHERE owner_id = ?'
  ).bind(ownerId).first();
  return jsonResponse({
    count: row ? Number(row.count) || 0 : 0,
    max_version: row ? Number(row.max_version) || 0 : 0,
  });
}

// ---------------- 管理接口（/admin/*） ----------------
//
// 供「本地管理后台」巡检/清理用，与用户侧契约完全隔离（/auth/*、/sync/* 语义零变化）。
//
// 默认关闭：只有配置了环境变量 ``ADMIN_TOKEN`` 才启用；未配置/空串时所有
// /admin/* 一律 404（端点连存在性都不暴露），配了但令牌不符则 401。
// 令牌比较走 [safeEqual]（定长常量时间），避免时序侧信道。

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
 * 注意顺序：先判「是否配置」（未配置 → 404 隐藏端点），再判令牌（不符 → 401）。
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

// --- 统计用的三个聚合查询（均为只读，供 stats / users 复用） ---

/** 全部账号（不含 pw_hash）。 */
async function adminListUsers(env) {
  const rows = await env.DB.prepare(
    'SELECT id, username, created_at FROM sync_users'
  ).all();
  return (rows.results || []).map((r) => ({
    user_id: r.id,
    username: r.username == null ? null : r.username,
    created_at: r.created_at == null ? null : r.created_at,
  }));
}

/** ``{ user_id: 令牌数 }``。 */
async function adminTokenCounts(env) {
  const rows = await env.DB.prepare(
    'SELECT user_id, COUNT(*) AS c FROM sync_tokens GROUP BY user_id'
  ).all();
  const out = new Map();
  for (const r of rows.results || []) {
    out.set(r.user_id, Number(r.c) || 0);
  }
  return out;
}

/** ``{ owner_id: {count, last} }``（last = 该 owner 最新的 server_time）。 */
async function adminEnvelopeAgg(env) {
  const rows = await env.DB.prepare(
    'SELECT owner_id, COUNT(*) AS c, MAX(server_time) AS latest ' +
      'FROM sync_envelopes GROUP BY owner_id'
  ).all();
  const out = new Map();
  for (const r of rows.results || []) {
    out.set(r.owner_id, {
      count: Number(r.c) || 0,
      last: r.latest == null ? null : String(r.latest),
    });
  }
  return out;
}

/** 单表计数（col 为空 = 全表）。 */
async function adminCount(env, table, col, val) {
  const sql = col
    ? `SELECT COUNT(*) AS c FROM ${table} WHERE ${col} = ?`
    : `SELECT COUNT(*) AS c FROM ${table}`;
  const stmt = col ? env.DB.prepare(sql).bind(val) : env.DB.prepare(sql);
  const row = await stmt.first();
  return row ? Number(row.c) || 0 : 0;
}

/** 单表删除（col 为空 = 清空整表）。 */
async function adminDelete(env, table, col, val) {
  const sql = col
    ? `DELETE FROM ${table} WHERE ${col} = ?`
    : `DELETE FROM ${table}`;
  const stmt = col ? env.DB.prepare(sql).bind(val) : env.DB.prepare(sql);
  await stmt.run();
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
          : 0
  );
  return rows.slice(0, ADMIN_LIST_MAX);
}

/** GET /admin/ping —— 存活 + 存储后端标识。 */
function handleAdminPing() {
  return jsonResponse({
    ok: true,
    storage: 'd1',
    server_time: nowIso(),
  });
}

/** GET /admin/stats —— 全局计数 + 按用户的用量（最多 100 条）。 */
async function handleAdminStats(env) {
  const users = await adminListUsers(env);
  const tokenCounts = await adminTokenCounts(env);
  const envAgg = await adminEnvelopeAgg(env);

  let tokens = 0;
  for (const c of tokenCounts.values()) tokens += c;
  let envelopes = 0;
  for (const a of envAgg.values()) envelopes += a.count;

  return jsonResponse({
    storage: 'd1',
    users: users.length,
    tokens,
    envelopes,
    server_time: nowIso(),
    per_user: adminBuildPerUser(users, tokenCounts, envAgg),
  });
}

/** GET /admin/users —— 账号列表（含用量），按 envelopes 降序，最多 100 条。 */
async function handleAdminUsers(env) {
  const users = await adminListUsers(env);
  const tokenCounts = await adminTokenCounts(env);
  const envAgg = await adminEnvelopeAgg(env);

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
          : 0
  );
  return jsonResponse({ users: list.slice(0, ADMIN_LIST_MAX) });
}

/**
 * POST /admin/reset —— 清库（all / envelopes / user）。
 *
 * 计数用 ``SELECT COUNT(*)`` + ``DELETE`` 两步（不依赖 RETURNING），因此重复调用
 * 第二次计数自然为 0，天然幂等。
 */
async function handleAdminReset(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: 'invalid json' }, 400);
  }
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
    deleted.envelopes = await adminCount(env, 'sync_envelopes');
    deleted.tokens = await adminCount(env, 'sync_tokens');
    deleted.users = await adminCount(env, 'sync_users');
    await adminDelete(env, 'sync_envelopes');
    await adminDelete(env, 'sync_tokens');
    await adminDelete(env, 'sync_users');
  } else if (scope === 'envelopes') {
    deleted.envelopes = await adminCount(env, 'sync_envelopes');
    await adminDelete(env, 'sync_envelopes');
  } else {
    deleted.envelopes = await adminCount(env, 'sync_envelopes', 'owner_id', userId);
    deleted.tokens = await adminCount(env, 'sync_tokens', 'user_id', userId);
    deleted.users = await adminCount(env, 'sync_users', 'id', userId);
    await adminDelete(env, 'sync_envelopes', 'owner_id', userId);
    await adminDelete(env, 'sync_tokens', 'user_id', userId);
    await adminDelete(env, 'sync_users', 'id', userId);
  }

  return jsonResponse({ scope, deleted });
}

/** DELETE /admin/user/{id} —— 删单个账号及其数据；账号不存在 → 404。 */
async function handleAdminDeleteUser(env, userId) {
  const exists = await env.DB.prepare(
    'SELECT id FROM sync_users WHERE id = ?'
  ).bind(userId).first();
  if (!exists) return jsonResponse({ error: 'user_not_found' }, 404);

  const envelopes = await adminCount(env, 'sync_envelopes', 'owner_id', userId);
  const tokens = await adminCount(env, 'sync_tokens', 'user_id', userId);
  await adminDelete(env, 'sync_envelopes', 'owner_id', userId);
  await adminDelete(env, 'sync_tokens', 'user_id', userId);
  await adminDelete(env, 'sync_users', 'id', userId);
  return jsonResponse({ deleted: { envelopes, tokens, users: 1 } });
}

/**
 * GET /admin/export?user_id= —— 导出 envelope 快照（信封形状与 rowToEnvelope 一致）。
 *
 * 单次最多 10000 条，多取 1 条用于判定 truncated（避免再跑一次 COUNT）。
 */
async function handleAdminExport(env, url) {
  const userId = (url.searchParams.get('user_id') || '').trim();

  const users = await adminListUsers(env);
  const picked = userId ? users.filter((u) => u.user_id === userId) : users;

  const sql = userId
    ? `SELECT ${ENVELOPE_COLS} FROM sync_envelopes WHERE owner_id = ? ` +
      'ORDER BY owner_id, server_time LIMIT ' + (ADMIN_EXPORT_MAX + 1)
    : `SELECT ${ENVELOPE_COLS} FROM sync_envelopes ` +
      'ORDER BY owner_id, server_time LIMIT ' + (ADMIN_EXPORT_MAX + 1);
  const stmt = userId
    ? env.DB.prepare(sql).bind(userId)
    : env.DB.prepare(sql);
  const rows = await stmt.all();
  const all = (rows.results || []).map(rowToEnvelope);

  return jsonResponse({
    user_id: userId || null,
    exported_at: nowIso(),
    truncated: all.length > ADMIN_EXPORT_MAX,
    envelopes: all.slice(0, ADMIN_EXPORT_MAX),
    users: picked,
  });
}

/**
 * /admin/* 分发：返回 Response；未知子路径返回 null（由调用方回落 404）。
 * 鉴权已由 [guardAdmin] 前置完成。
 */
async function routeAdmin(request, env, sub) {
  const method = request.method;

  if (method === 'GET' && sub === '/ping') return handleAdminPing();
  if (method === 'GET' && sub === '/stats') return await handleAdminStats(env);
  if (method === 'GET' && sub === '/users') return await handleAdminUsers(env);
  if (method === 'POST' && sub === '/reset') return await handleAdminReset(request, env);
  if (method === 'GET' && sub === '/export') {
    return await handleAdminExport(env, new URL(request.url));
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
    return await handleAdminDeleteUser(env, userId);
  }
  return null;
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
      // 管理接口排在用户路由之前：/admin/* 只认 ADMIN_TOKEN，不碰用户鉴权块。
      const adminSub = adminSubPath(path);
      if (adminSub !== null) {
        const denied = guardAdmin(request, env);
        if (denied) return denied;
        const resp = await routeAdmin(request, env, adminSub);
        return resp || jsonResponse({ error: 'not_found' }, 404);
      }

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

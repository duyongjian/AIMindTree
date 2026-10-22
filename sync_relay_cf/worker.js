/**
 * Cloudflare Worker + D1 同步中继（方案 B）。
 *
 * 与 App 端 ``HttpSyncApi`` 契约严格对齐（见
 * ``aimindtree_app/lib/data/sync/sync_api.dart`` 头部注释）：
 *
 * - ``POST /sync/push``   ``{device_id, envelopes:[...]}`` → ``{received, server_time}``
 * - ``POST /sync/pull``   ``{device_id, since|null}``      → ``{envelopes:[...], server_time}``
 * - ``GET  /sync/manifest``                             → ``{count}``
 *
 * envelope 字段与 App ``SyncEnvelope`` 一致（见
 * ``aimindtree_app/lib/data/sync/sync_types.dart``）：
 * ``device_id / entity_table / entity_id / op / payload / base_version /
 * updated_at / deleted_at``。
 *
 * 存储用绑定的 D1 数据库（SQLite 兼容），表 ``sync_envelopes`` 只存每个
 * ``(entity_table, entity_id)`` 的最新态——LWW 已在客户端做，服务端只保存
 * 最新态 + ``server_time`` 供增量拉取。
 *
 * 鉴权：Bearer token 比对环境变量 ``SYNC_TOKEN``；若该值为空则直接放行
 * （开发期信任）。部署到公网时务必用 ``wrangler secret put SYNC_TOKEN`` 设置。
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

/**
 * Bearer token 校验。``SYNC_TOKEN`` 为空放行（开发期）。
 * @param {Request} request
 * @param {object} env
 * @returns {boolean}
 */
function verifyToken(request, env) {
  const expected = (env.SYNC_TOKEN || '').trim();
  if (!expected) return true;
  const auth = request.headers.get('Authorization') || '';
  const token = auth.toLowerCase().startsWith('bearer ')
    ? auth.slice('bearer '.length).trim()
    : '';
  return token === expected;
}

const ENVELOPE_COLS =
  'entity_table, entity_id, device_id, op, payload_json, ' +
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

/** POST /sync/push —— 批量 upsert 每个 (entity_table, entity_id) 最新态。 */
async function handlePush(request, env) {
  const body = await request.json();
  const envelopes = Array.isArray(body && body.envelopes) ? body.envelopes : [];
  const serverTime = nowIso();

  if (envelopes.length > 0) {
    const stmt = env.DB.prepare(
      `INSERT OR REPLACE INTO sync_envelopes
       (entity_table, entity_id, device_id, op, payload_json,
        base_version, updated_at, deleted_at, server_time)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
    );
    const batch = envelopes.map((e) =>
      stmt.bind(
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

  return jsonResponse({ received: envelopes.length, server_time: serverTime });
}

/** POST /sync/pull —— 拉取 since 之后的增量；since 为空 = 全量。 */
async function handlePull(request, env) {
  const body = await request.json();
  const since = body && body.since ? body.since : null;

  let rows;
  if (since) {
    rows = await env.DB.prepare(
      `SELECT ${ENVELOPE_COLS} FROM sync_envelopes ` +
        'WHERE server_time > ? ORDER BY server_time'
    )
      .bind(since)
      .all();
  } else {
    rows = await env.DB.prepare(
      `SELECT ${ENVELOPE_COLS} FROM sync_envelopes ORDER BY server_time`
    ).all();
  }

  const envelopes = (rows.results || []).map(rowToEnvelope);
  return jsonResponse({ envelopes, server_time: nowIso() });
}

/** GET /sync/manifest —— 当前存量 envelope 数。 */
async function handleManifest(env) {
  const row = await env.DB.prepare(
    'SELECT COUNT(*) AS count FROM sync_envelopes'
  ).first();
  return jsonResponse({ count: row ? row.count : 0 });
}

export default {
  /**
   * @param {Request} request
   * @param {object} env 绑定：{ DB: D1Database, SYNC_TOKEN?: string }
   */
  async fetch(request, env) {
    if (!verifyToken(request, env)) {
      return jsonResponse({ error: 'invalid sync token' }, 401);
    }

    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    try {
      if (request.method === 'POST' && path.endsWith('/sync/push')) {
        return await handlePush(request, env);
      }
      if (request.method === 'POST' && path.endsWith('/sync/pull')) {
        return await handlePull(request, env);
      }
      if (request.method === 'GET' && path.endsWith('/sync/manifest')) {
        return await handleManifest(env);
      }
      return jsonResponse({ error: 'not found' }, 404);
    } catch (e) {
      const msg = e && e.message ? e.message : String(e);
      return jsonResponse({ error: msg }, 500);
    }
  },
};

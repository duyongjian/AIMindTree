/**
 * sync_relay_eo 协议冒烟测试（不联网、不需要 EdgeOne 账号）。
 *
 * 用一个内存版 KV 替换 EdgeOne 的 KV 命名空间绑定，直接驱动
 * ``edge-functions/[[default]].js`` 的 ``handleFetch``（与 Vercel 版
 * test_protocol.mjs 同口径），验证 HTTP 契约与 ``sync_relay_cf/worker.js`` /
 * ``sync_relay_cn`` / ``sync_relay_vercel`` 完全一致（App 端零改动）。
 *
 * 运行：node test_protocol.mjs     全绿退出码 0，有失败退出码 1。
 *
 * 覆盖：
 * - 根路径健康检查（GET / → 200，且 KV 未绑定时也返 200，KV 状态由 sync 端点体现）；
 * - 账号：register / login / 重名 409 / 弱密码 400 / 短用户名 400 / 错误密码 401 /
 *   不存在用户 401 / 非法 JSON 400 / 密码不明文存储且带盐；
 * - 鉴权：未带令牌 401、无效令牌 401、小写 bearer 前缀可用、旧令牌仍有效；
 * - 数据通路：push → manifest → pull 全量、payload 还原、deleted_at 保留 null、
 *   upsert 覆盖、since 增量（lookback=0 严格语义）、默认 lookback 防最终一致丢更新、
 *   多租户隔离、server_time 严格递增排序；
 * - 分页：push 300 条（超过 KV list 单页 256）后 pull 必须取回全部 300 且无重复；
 * - 特殊字符 entity_id（. $ / _）upsert 正确覆盖、原值返回；
 * - KV 未绑定 → 503 可读报错；
 * - 请求体超 900KB（EdgeOne 1MB 上限）→ 413；
 * - 入口级：真实 onRequest（context.request / context.env）完整注册→push→pull 往返。
 */

import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

import { handleFetch, onRequest, effectiveSince } from './edge-functions/[[default]].js';

// ---------------- 内存版 KV（只实现 [[default]].js 用到的命令）----------------

/**
 * 刻意保持与 EdgeOne KV 一致的方法形状：get / put / list。
 * list 按 prefix 过滤、limit 分页（默认 256，模拟 EdgeOne 单页上限）、cursor 翻页。
 */
class MockKV {
  constructor() {
    this.map = new Map(); // key → string
    this.listCalls = 0; // 白盒：list 调用次数，验证分页翻页
  }

  async get(key) {
    return this.map.has(key) ? this.map.get(key) : null;
  }

  async put(key, value) {
    this.map.set(key, String(value));
  }

  async list({ prefix = '', limit = 256, cursor } = {}) {
    this.listCalls++;
    const all = [];
    for (const k of this.map.keys()) if (k.startsWith(prefix)) all.push(k);
    all.sort(); // 字典序稳定，保证翻页全序
    let start = 0;
    if (cursor) {
      const idx = all.indexOf(cursor);
      start = idx >= 0 ? idx + 1 : 0;
    }
    const slice = all.slice(start, start + Math.max(1, limit));
    const nextCursor = start + slice.length < all.length ? slice[slice.length - 1] : undefined;
    return { keys: slice.map((k) => ({ key: k })), cursor: nextCursor, complete: !nextCursor };
  }
}

// ---------------- 测试脚手架 ----------------

let passed = 0;
let failed = 0;

function assert(cond, msg) {
  if (cond) {
    passed++;
    console.log(`  ✓ ${msg}`);
  } else {
    failed++;
    console.error(`  ✗ ${msg}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------- 请求构造（mock Request）----------------

/**
 * 构造一个最小 Request 替身：handleFetch 只用 method / url / headers.get /
 * text。无需真实 undici Request，避免 body 被消费的边角问题。
 */
function makeRequest(method, reqPath, opts = {}) {
  const { headers = {}, body, rawBody } = opts;
  // 归一化存储键为小写，模拟真实 Request/Response 的大小写不敏感头查找。
  const normHeaders = {};
  for (const [k, v] of Object.entries(headers)) normHeaders[String(k).toLowerCase()] = v;
  const text = rawBody !== undefined ? rawBody : body === undefined ? '' : JSON.stringify(body);
  return {
    method,
    url: 'https://relay.local' + reqPath,
    headers: {
      get: (k) => {
        const v = normHeaders[String(k).toLowerCase()];
        return v === undefined ? null : v;
      },
    },
    text: async () => text,
  };
}

// ---------------- 测试环境 ----------------

function makeEnv() {
  const kv = new MockKV();
  return { kv };
}

/**
 * 驱动一次 HTTP 请求（handleFetch 的输入形状）。返回 { status, body, raw }。
 * extraEnv 合并进传给 handleFetch 的 env（用于注入 SYNC_PULL_LOOKBACK_MS 等）。
 */
async function call(env, options) {
  const {
    method = 'GET',
    path: reqPath = '/',
    body,
    rawBody,
    token,
    authHeader,
    extraEnv,
  } = options;

  const headers = {};
  if (authHeader) headers.Authorization = authHeader;
  else if (token) headers.Authorization = `Bearer ${token}`;

  const req = makeRequest(method, reqPath, { headers, body, rawBody });
  const mergedEnv = Object.assign({ SYNC_KV: env.kv }, extraEnv || {});
  const res = await handleFetch(req, mergedEnv);
  const status = res.status;
  let parsed = null;
  try {
    parsed = JSON.parse(await res.text());
  } catch {
    parsed = null;
  }
  return { status, body: parsed, raw: res };
}

async function post(env, reqPath, body, token) {
  return call(env, { method: 'POST', path: reqPath, body, token: token || '' });
}

async function get(env, reqPath, token) {
  return call(env, { method: 'GET', path: reqPath, token: token || '' });
}

function mkEnvId(entityTable, entityId, device, payload) {
  return {
    device_id: device,
    entity_table: entityTable,
    entity_id: entityId,
    op: 'upsert',
    payload,
    base_version: 1,
    updated_at: '2024-10-23T00:00:00.000Z',
    deleted_at: null,
  };
}

/** 直接从内存 KV 里取一行用户文档，用于校验哈希格式（测试专用）。 */
function findUserRow(kv, username) {
  for (const raw of kv.map.values()) {
    try {
      const d = JSON.parse(raw);
      if (d.username === username) return d;
    } catch {
      // 非用户文档，跳过
    }
  }
  return null;
}

// ---------------- 用例 ----------------

async function run() {
  console.log('sync_relay_eo（EdgeOne Pages 版）协议自测开始：');
  const env = makeEnv();
  const alicePassword = 'password123';
  const bobPassword = 'password456';

  // --- 0) 根路径健康检查（KV 未绑定也返 200）---
  {
    const r = await get(env, '/', '');
    assert(
      r.status === 200 && r.body.ok === true && r.body.service === 'aimindtree-sync-relay',
      'GET / 返回 200 + {ok, service, version}（KV 未绑定时也 200）'
    );
    assert(r.body.version === '1.0.0', 'GET / version = 1.0.0');
    assert(r.body.runtime === 'edgeone-pages-edge-functions', 'GET / 标注 runtime = edgeone-pages-edge-functions');
  }

  // --- 1) 未带令牌的 push → 401 ---
  {
    const r = await post(env, '/sync/push', { device_id: 'd1', envelopes: [] }, '');
    assert(r.status === 401 && r.body.error === 'unauthorized', '未带令牌 push → 401 unauthorized');
  }

  // --- 2) 注册成功 → user_id + 64 位十六进制 token ---
  let aliceToken;
  let aliceUserId;
  {
    const r = await post(env, '/auth/register', { username: 'alice', password: alicePassword }, '');
    assert(r.status === 200 && typeof r.body.token === 'string', 'register 成功返回 token');
    assert(r.body.token.length === 64, 'token 为 64 位十六进制');
    assert(typeof r.body.user_id === 'string' && r.body.user_id.startsWith('u_'), 'user_id 形如 u_xxx');
    aliceToken = r.body.token;
    aliceUserId = r.body.user_id;
  }

  // --- 3) 重名注册 → 409 ---
  {
    const r = await post(env, '/auth/register', { username: 'alice', password: alicePassword }, '');
    assert(r.status === 409 && r.body.error === 'username taken', '重复用户名注册 → 409');
  }

  // --- 4) 弱密码 → 400 ---
  {
    const r = await post(env, '/auth/register', { username: 'bob', password: 'short' }, '');
    assert(r.status === 400 && r.body.error === 'password too short (>=8)', '弱密码注册 → 400');
  }

  // --- 5) 短用户名 → 400 ---
  {
    const r = await post(env, '/auth/register', { username: 'ab', password: alicePassword }, '');
    assert(r.status === 400 && r.body.error === 'username too short (>=3)', '短用户名注册 → 400');
  }

  // --- 6) 非法 JSON → 400 ---
  {
    const r = await call(env, { method: 'POST', path: '/auth/register', rawBody: '{oops' });
    assert(r.status === 400 && r.body.error === 'invalid json', '非法 JSON → 400 invalid json');
  }

  // --- 7) 密码不明文存储，且形如 saltHex:hashHex（16/32 字节）---
  {
    await post(env, '/auth/register', { username: 'carol', password: alicePassword }, '');
    const login = await post(env, '/auth/login', { username: 'carol', password: alicePassword }, '');
    assert(login.status === 200, '第二个账号登录成功');
    const userRow = findUserRow(env.kv, 'carol');
    const parts = String(userRow.pw_hash).split(':');
    assert(userRow.pw_hash !== alicePassword, '密码不以明文存储');
    assert(
      parts.length === 2 && parts[0].length === 32 && parts[1].length === 64,
      'pw_hash 形如 saltHex:hashHex（16/32 字节）'
    );
  }

  // --- 8) 登录正确 → 200 且拿到新 token ---
  let aliceToken2;
  {
    const r = await post(env, '/auth/login', { username: 'alice', password: alicePassword }, '');
    assert(r.status === 200 && typeof r.body.token === 'string', 'login 成功返回 token');
    aliceToken2 = r.body.token;
  }

  // --- 9) 错误密码 → 401 ---
  {
    const r = await post(env, '/auth/login', { username: 'alice', password: 'wrong' }, '');
    assert(r.status === 401 && r.body.error === 'invalid credentials', '错误密码登录 → 401');
  }

  // --- 10) 不存在的用户 → 401 ---
  {
    const r = await post(env, '/auth/login', { username: 'nobody', password: alicePassword }, '');
    assert(r.status === 401, '登录不存在的用户 → 401');
  }

  // --- 11) Alice push 计数 ---
  let pushTime1;
  {
    const envelopes = [
      mkEnvId('notes', 'n1', 'd1', { title: 'A' }),
      mkEnvId('notes', 'n2', 'd1', { title: 'B' }),
    ];
    const r = await post(env, '/sync/push', { device_id: 'd1', envelopes }, aliceToken);
    assert(r.status === 200 && r.body.received === 2, 'Alice push received=2');
    assert(r.body.accepted === 2, 'Alice push accepted=2（兼容旧版 App）');
    assert(
      typeof r.body.server_time === 'string' && r.body.server_time.endsWith('Z'),
      'server_time 为 ISO 8601 UTC'
    );
    pushTime1 = r.body.server_time;
  }

  // --- 12) manifest ---
  {
    const r = await get(env, '/sync/manifest', aliceToken);
    assert(r.body.count === 2, 'Alice manifest count=2');
  }

  // --- 13) pull 全量 ---
  {
    const r = await post(env, '/sync/pull', { device_id: 'd1', since: null }, aliceToken);
    assert(r.body.envelopes.length === 2, 'Alice pull 全量 2 条');
    assert(r.body.envelopes[0].payload.title === 'A', 'Alice payload 还原正确');
    assert(r.body.envelopes[0].deleted_at === null, 'envelope 字段完整（deleted_at 保留 null）');
  }

  // --- 14) 覆盖同 key（upsert）：count 不变、payload 更新 ---
  let pushTime1b;
  {
    await sleep(15); // 确保 server_time 与上一批不同（毫秒）
    const r = await post(
      env,
      '/sync/push',
      { device_id: 'd1', envelopes: [mkEnvId('notes', 'n1', 'd1', { title: 'A-updated' })] },
      aliceToken
    );
    pushTime1b = r.body.server_time;
    const manifest = await get(env, '/sync/manifest', aliceToken);
    assert(manifest.body.count === 2, '覆盖同 key 后 count 仍为 2');

    const pull = await post(env, '/sync/pull', { device_id: 'd1', since: null }, aliceToken);
    const n1 = pull.body.envelopes.find((e) => e.entity_id === 'n1');
    assert(n1.payload.title === 'A-updated', '覆盖后拉取到新 payload');
    // 全量 pull 必须按 server_time 升序：n2（旧）→ n1（刷新后）
    assert(
      JSON.stringify(pull.body.envelopes.map((e) => e.entity_id)) === JSON.stringify(['n2', 'n1']),
      '全量 pull 按 server_time 升序（被覆盖的条目后移）'
    );
  }

  // --- 15) since 增量过滤（lookback=0 拿严格语义）---
  {
    const p3 = await post(
      env,
      '/sync/push',
      { device_id: 'd1', envelopes: [mkEnvId('notes', 'n3', 'd1', { title: 'C' })] },
      aliceToken
    );
    const t3 = p3.body.server_time;
    await sleep(15);
    await post(
      env,
      '/sync/push',
      { device_id: 'd1', envelopes: [mkEnvId('notes', 'n4', 'd1', { title: 'D' })] },
      aliceToken
    );
    const pull = await call(env, {
      method: 'POST',
      path: '/sync/pull',
      body: { device_id: 'd1', since: t3 },
      token: aliceToken,
      extraEnv: { SYNC_PULL_LOOKBACK_MS: '0' },
    });
    assert(
      pull.body.envelopes.length === 1 && pull.body.envelopes[0].entity_id === 'n4',
      'since 增量（lookback=0）仅返回 n4'
    );
  }

  // --- 15b) 默认 lookback 把 65s 内的写入捞回（防 KV 最终一致丢更新）---
  {
    const fresh = makeEnv();
    const reg = await post(fresh, '/auth/register', { username: 'lookb', password: 'dotted12345' }, '');
    const token = reg.body.token;
    const p = await post(
      fresh,
      '/sync/push',
      { device_id: 'd1', envelopes: [mkEnvId('notes', 'x', 'd1', { v: 1 })] },
      token
    );
    const t = p.body.server_time;
    // 默认 lookback：since 等于 x 的 server_time（理论上应排除 x），但因 65s 回退窗口，x 仍被捞回
    const pull = await post(fresh, '/sync/pull', { device_id: 'd1', since: t }, token);
    assert(
      pull.body.envelopes.some((e) => e.entity_id === 'x'),
      '默认 lookback 把 65s 内的写入捞回（防最终一致丢更新）'
    );
  }

  // --- 16) 无效令牌 → 401 ---
  {
    const r = await get(env, '/sync/manifest', 'deadbeef');
    assert(r.status === 401, '无效令牌 → 401');
  }

  // --- 17) lowercase bearer 前缀也能识别 ---
  {
    const r = await call(env, { method: 'GET', path: '/sync/manifest', authHeader: `bearer ${aliceToken}` });
    assert(r.status === 200, '小写 bearer 前缀同样可用');
  }

  // --- 18) 多租户隔离 ---
  let bobToken;
  {
    const reg = await post(env, '/auth/register', { username: 'bob', password: bobPassword }, '');
    bobToken = reg.body.token;
    await post(
      env,
      '/sync/push',
      { device_id: 'd2', envelopes: [mkEnvId('notes', 'n1', 'd2', { title: 'Bobs-N1' })] },
      bobToken
    );

    const alicePull = await post(env, '/sync/pull', { device_id: 'd1', since: null }, aliceToken);
    assert(alicePull.body.envelopes.length === 4, 'Alice 名下 4 条（n1,n2,n3,n4）');
    assert(
      !alicePull.body.envelopes.some((e) => e.payload && e.payload.title === 'Bobs-N1'),
      'Alice 拉不到 Bob 的 n1'
    );
    assert(
      JSON.stringify(alicePull.body.envelopes.map((e) => e.entity_id)) ===
        JSON.stringify(['n2', 'n1', 'n3', 'n4']),
      'Alice 全量 pull 按 server_time 升序（n2→n1→n3→n4）'
    );

    const bobPull = await post(env, '/sync/pull', { device_id: 'd2', since: null }, bobToken);
    assert(bobPull.body.envelopes.length === 1, 'Bob 名下仅 1 条');
    assert(bobPull.body.envelopes[0].payload.title === 'Bobs-N1', 'Bob 只看到自己的 n1');
  }

  // --- 19) 旧令牌仍有效 ---
  {
    const r = await get(env, '/sync/manifest', aliceToken2);
    assert(r.body.count === 4, 'Alice 的旧登录令牌仍指向 Alice 命名空间');
  }

  // --- 20) 未知路径 → 404 ---
  {
    const r = await get(env, '/sync/nope', aliceToken);
    assert(r.status === 404 && r.body.error === 'not found', '未知路径 → 404 not found');
  }

  // --- 20b) 方法不匹配 → 404 ---
  {
    const r = await post(env, '/sync/manifest', {}, aliceToken);
    assert(r.status === 404 && r.body.error === 'not found', 'POST /sync/manifest → 404 not found');
  }

  // --- 21) OPTIONS 预检 → 204 带 CORS 头 ---
  {
    const res = await handleFetch(makeRequest('OPTIONS', '/sync/push', {}), { SYNC_KV: env.kv });
    assert(res.status === 204, 'OPTIONS 预检 → 204');
    assert(
      res.headers.get('access-control-allow-origin') === '*' &&
        res.headers.get('access-control-allow-methods') === 'GET, POST, OPTIONS' &&
        res.headers.get('access-control-allow-headers') === 'Content-Type, Authorization',
      'OPTIONS 响应带完整 CORS 头'
    );
  }

  // --- 22) 大批量分页：push 300 条（超过 KV list 单页 256）→ pull 全量取回 ---
  {
    const fresh = makeEnv();
    const reg = await post(fresh, '/auth/register', { username: 'bulk', password: 'bulkbulk1234' }, '');
    const token = reg.body.token;
    const bulk = [];
    for (let i = 0; i < 300; i++) bulk.push(mkEnvId('notes', `bulk-${i}`, 'd1', { i }));
    const pushRes = await post(fresh, '/sync/push', { device_id: 'd1', envelopes: bulk }, token);
    assert(pushRes.body.received === 300, '批量 push 300 条 → received=300');

    const manifest = await get(fresh, '/sync/manifest', token);
    assert(manifest.body.count === 300, 'manifest count=300');

    const pull = await post(fresh, '/sync/pull', { device_id: 'd1', since: null }, token);
    assert(pull.body.envelopes.length === 300, 'pull 全量取回全部 300 条（256 单页翻页未漏）');
    assert(fresh.kv.listCalls >= 2, `list 至少翻 2 页（实际 ${fresh.kv.listCalls} 次）`);

    const ids = new Set(pull.body.envelopes.map((e) => e.entity_id));
    assert(ids.size === 300, '300 条互不重复');

    assert(
      pull.body.envelopes.every((e) => e.op === 'upsert' && typeof e.payload.i === 'number'),
      '批量数据 payload 还原正确'
    );
  }

  // --- 23) entity_id 带点号/美元符/斜杠/下划线也能正确 upsert ---
  {
    const fresh = makeEnv();
    const reg = await post(fresh, '/auth/register', { username: 'dotted', password: 'dotted12345' }, '');
    const token = reg.body.token;
    const dottedId = 'a.b$c/d_e';
    await post(fresh, '/sync/push', { device_id: 'd1', envelopes: [mkEnvId('notes', dottedId, 'd1', { v: 1 })] }, token);
    await post(fresh, '/sync/push', { device_id: 'd1', envelopes: [mkEnvId('notes', dottedId, 'd1', { v: 2 })] }, token);
    const manifest = await get(fresh, '/sync/manifest', token);
    assert(manifest.body.count === 1, '带特殊字符的 entity_id 覆盖而非新增');
    const pull = await post(fresh, '/sync/pull', { device_id: 'd1', since: null }, token);
    assert(pull.body.envelopes[0].entity_id === dottedId, 'entity_id 原样返回给 App');
    assert(pull.body.envelopes[0].payload.v === 2, '特殊字符 id 下 upsert 仍覆盖最新态');
  }

  // --- 23b) 同一批 push 里重复的 key 只留一条（批内 upsert）---
  {
    const fresh = makeEnv();
    const reg = await post(fresh, '/auth/register', { username: 'dupkey', password: 'poqiwuey1284' }, '');
    const token = reg.body.token;
    await post(
      fresh,
      '/sync/push',
      {
        device_id: 'd1',
        envelopes: [
          mkEnvId('notes', 'same', 'd1', { v: 'first' }),
          mkEnvId('notes', 'same', 'd1', { v: 'last' }),
        ],
      },
      token
    );
    const manifest = await get(fresh, '/sync/manifest', token);
    assert(manifest.body.count === 1, '同一批内重复 key 只保留一条');
    const pull = await post(fresh, '/sync/pull', { device_id: 'd1', since: null }, token);
    assert(pull.body.envelopes[0].payload.v === 'last', '同一批内后到的覆盖先到的');
  }

  // --- 24) KV 未绑定 → 503 可读报错 ---
  {
    const res = await handleFetch(makeRequest('GET', '/sync/manifest', {}), {}); // env 为空 → 无 SYNC_KV
    assert(res.status === 503, 'KV 未绑定时 GET /sync/manifest → 503');
    const body = await res.json();
    assert(body.ok === false && typeof body.error === 'string' && body.error.includes('SYNC_KV'),
      '503 响应带可读的 SYNC_KV 绑定指引');
  }

  // --- 25) 请求体超 900KB（EdgeOne 1MB 上限）→ 413 ---
  {
    const res = await handleFetch(
      makeRequest('POST', '/sync/push', { headers: { 'content-length': '1000000' }, rawBody: '' }),
      { SYNC_KV: env.kv }
    );
    assert(res.status === 413, '超大 body（content-length 1MB） → 413');
  }

  // --- 26) effectiveSince 单元 ---
  {
    assert(effectiveSince(null) === null, 'effectiveSince(null) → null');
    assert(effectiveSince('garbage') === null, 'effectiveSince(非法 ISO) → null');
    const recent = new Date(Date.now() - 10000).toISOString();
    const def = effectiveSince(recent);
    assert(def !== null, 'effectiveSince(近 10s) 不返回 null');
    const now = Date.now();
    assert(
      Date.parse(def) <= now - 65000 + 2000 && Date.parse(def) >= now - 67000 - 2000,
      '默认 lookback 把起点压到 ≈ now-65s'
    );
    const zero = effectiveSince(recent, { SYNC_PULL_LOOKBACK_MS: '0' });
    assert(zero === recent, 'lookback=0 时严格等于 since');
  }

  // --- 27) 入口级测试：真实 onRequest（context.request / context.env）---
  await runEntryTests();

  console.log(`\n结果：通过 ${passed}，失败 ${failed}`);
  if (failed > 0) process.exit(1);
}

// ---------------- 入口级测试（真实 onRequest）----------------

async function runEntryTests() {
  console.log('\n入口级测试（onRequest(context) 适配）：');
  let mod;
  try {
    const here = path.dirname(fileURLToPath(import.meta.url));
    const url = pathToFileURL(path.join(here, 'edge-functions', '[[default]].js')).href;
    mod = await import(url);
  } catch (e) {
    assert(false, `加载 [[default]].js 失败：${e.message}`);
    return;
  }

  const mock = makeEnv();
  const ctx = (m, p, opts) => ({ request: makeRequest(m, p, opts), env: { SYNC_KV: mock.kv } });

  // 根路径健康检查（经真实 onRequest）
  {
    const res = await mod.onRequest(ctx('GET', '/'));
    const body = JSON.parse(await res.text());
    assert(res.status === 200 && body.ok === true && body.version === '1.0.0', '入口 GET / 健康检查 200 + 服务标识');
  }

  // KV 未绑定 → 503
  {
    const res = await mod.onRequest({ request: makeRequest('GET', '/sync/manifest', {}), env: {} });
    assert(res.status === 503, '入口 KV 未绑定 → 503');
  }

  // 完整往返：register → push → pull → manifest
  {
    const regRes = await mod.onRequest(
      ctx('POST', '/auth/register', { body: { username: 'entryuser', password: 'wnebirty1284' } })
    );
    assert(regRes.status === 200, '入口 register → 200');
    const reg = JSON.parse(await regRes.text());
    assert(reg.token && reg.token.length === 64, '入口 register 返回 64 位令牌');

    const pushRes = await mod.onRequest(
      ctx('POST', '/sync/push', {
        body: { device_id: 'd1', envelopes: [mkEnvId('notes', 'e1', 'd1', { title: 'via-entry' })] },
        headers: { Authorization: `Bearer ${reg.token}` },
      })
    );
    assert(pushRes.status === 200, '入口 push → 200');
    const push = JSON.parse(await pushRes.text());
    assert(push.received === 1 && push.accepted === 1, '入口 push received/accepted = 1');

    const pullRes = await mod.onRequest(
      ctx('POST', '/sync/pull', { body: { device_id: 'd1', since: null }, headers: { authorization: `bearer ${reg.token}` } })
    );
    const pull = JSON.parse(await pullRes.text());
    assert(pullRes.status === 200 && pull.envelopes.length === 1, '入口 pull 全量 1 条');
    assert(pull.envelopes[0].payload.title === 'via-entry', '入口 pull payload 还原正确');

    const manifestRes = await mod.onRequest(
      ctx('GET', '/sync/manifest', { headers: { Authorization: `Bearer ${reg.token}` } })
    );
    const manifest = JSON.parse(await manifestRes.text());
    assert(manifest.count === 1, '入口 manifest count=1');
  }
}

run().catch((e) => {
  console.error('测试异常：', e);
  process.exit(1);
});

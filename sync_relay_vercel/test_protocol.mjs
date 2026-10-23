/**
 * sync_relay_vercel 协议冒烟测试（不联网、不需要 Vercel/KV 账号）。
 *
 * 用一个内存版 Redis mock 替换 ``@vercel/kv`` 的客户端，直接驱动 ``core.js``
 * 的请求处理函数，验证 HTTP 契约与 ``sync_relay_cf/worker.js`` /
 * ``sync_relay_cn`` 完全一致（断言口径照搬 ``sync_relay_cn/test_protocol.mjs``）。
 *
 * 运行：node test_protocol.mjs     全绿退出码 0，有失败退出码 1。
 *
 * 覆盖（在 cn 版 45 条断言的基础上追加 Vercel/KV 专属项）：
 * - 根路径健康检查；
 * - 账号：register / login / 重名 409 / 弱密码 400 / 短用户名 400 / 错误密码 401 /
 *   非法 JSON / 密码不明文存储且带盐；
 * - 鉴权：未带令牌 401、无效令牌 401、小写 bearer 前缀可用、旧令牌仍有效；
 * - 数据通路：push → manifest → pull 全量、payload 还原、deleted_at 保留 null、
 *   upsert 覆盖、since 增量、多租户隔离、server_time 严格递增排序；
 * - 分页：push 1200 条后 pull 必须取回全部 1200 条且无重复（验证 LIMIT offset 翻页）；
 *   SYNC_PULL_PAGE_SIZE 调小后同样不漏；
 * - 事务分块：SYNC_WRITE_CHUNK 控制 multi() 事务条数（1200 条 = 12 次 zadd）；
 * - entity_id 含 `. $ /` 及 `_` 时 upsert 正确覆盖、原值返回、member 不冲突；
 * - ZSET 白盒：score = Date.parse(server_time)，member = table__entity；
 * - isConfigured() 环境变量判断；
 * - 入口级（真实 Vercel 函数）：OPTIONS 204、KV 未绑定 503 可读报错、
 *   经 Request/Response 的完整注册→push→pull 往返（需已 npm i，未安装则自动跳过）。
 */

import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

import { createHandler } from './core.js';
import {
  createStore,
  isConfigured,
  memberKey,
  escapeKeySegment,
  envZsetKey,
  KEY_USERS,
} from './db.js';

// ---------------- 内存版 Redis（只实现 db.js 用到的命令）----------------

/**
 * 刻意保持与 @vercel/kv（@upstash/redis）一致的方法形状：
 *   hget(key, field) → string|null
 *   hset(key, {field: value}) → number
 *   hsetnx(key, field, value) → 0|1
 *   hmget(key, ...fields) → {field: value|null} | null
 *   zadd(key, {score, member}, ...) → number
 *   zrange(key, min, max, {byScore, offset, count}) → member[]
 *   zcard(key) → number
 *   multi() → 链式事务，exec() 顺序执行
 */
class MockRedis {
  constructor() {
    this.hashes = new Map(); // key → Map(field → string)
    this.zsets = new Map(); // key → Map(member → score)
    this.commandLog = []; // 白盒：命令流水，用于验证事务分块
  }

  _hash(key) {
    if (!this.hashes.has(key)) this.hashes.set(key, new Map());
    return this.hashes.get(key);
  }

  _zset(key) {
    if (!this.zsets.has(key)) this.zsets.set(key, new Map());
    return this.zsets.get(key);
  }

  async hget(key, field) {
    const h = this.hashes.get(key);
    return h && h.has(field) ? h.get(field) : null;
  }

  async hset(key, kv) {
    const h = this._hash(key);
    let n = 0;
    for (const [f, v] of Object.entries(kv)) {
      h.set(f, String(v));
      n++;
    }
    return n;
  }

  async hsetnx(key, field, value) {
    const h = this._hash(key);
    if (h.has(field)) return 0;
    h.set(field, String(value));
    return 1;
  }

  async hmget(key, ...fields) {
    const h = this.hashes.get(key);
    const out = {};
    for (const f of fields) out[f] = h && h.has(f) ? h.get(f) : null;
    return out;
  }

  async zadd(key, ...pairs) {
    const z = this._zset(key);
    let added = 0;
    for (const p of pairs) {
      if (!z.has(p.member)) added++;
      z.set(p.member, p.score); // 已存在则更新 score（刷新游标位置）
    }
    return added;
  }

  async zrange(key, min, max, opts = {}) {
    if (!opts || opts.byScore !== true) {
      throw new Error('mock 仅实现 byScore 模式的 zrange（db.js 只用了这一种）');
    }
    const z = this.zsets.get(key);
    if (!z) return [];
    const lo = parseBound(min);
    const hi = parseBound(max);
    const entries = [...z.entries()].filter(
      ([, s]) =>
        (lo.exclusive ? s > lo.value : s >= lo.value) &&
        (hi.exclusive ? s < hi.value : s <= hi.value)
    );
    // Redis 语义：score 相同时按 member 字典序，保证全序、翻页不重不漏。
    entries.sort((a, b) => a[1] - b[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
    const offset = opts.offset || 0;
    const count = opts.count;
    const sliced = count == null ? entries.slice(offset) : entries.slice(offset, offset + count);
    return sliced.map(([member]) => member);
  }

  async zcard(key) {
    const z = this.zsets.get(key);
    return z ? z.size : 0;
  }

  multi() {
    const ops = [];
    const self = this;
    const tx = {
      hset(key, kv) {
        ops.push(() => self.hset(key, kv));
        return tx;
      },
      zadd(key, ...pairs) {
        ops.push(() => self.zadd(key, ...pairs));
        return tx;
      },
      async exec() {
        const results = [];
        for (const op of ops) {
          self.commandLog.push('cmd');
          results.push(await op());
        }
        self.commandLog.push('tx');
        return results;
      },
    };
    return tx;
  }
}

/** 解析 ZRANGE 的 score 边界：'(123' 开区间 / '-inf' / '+inf' / 数字。 */
function parseBound(b) {
  const s = String(b);
  if (s.startsWith('(')) return { value: Number(s.slice(1)), exclusive: true };
  if (s === '-inf') return { value: -Infinity, exclusive: false };
  if (s === '+inf') return { value: Infinity, exclusive: false };
  return { value: Number(s), exclusive: false };
}

// ---------------- 测试脚手架 ----------------

let passed = 0;
let failed = 0;
let skipped = 0;

function assert(cond, msg) {
  if (cond) {
    passed++;
    console.log(`  ✓ ${msg}`);
  } else {
    failed++;
    console.error(`  ✗ ${msg}`);
  }
}

function skip(msg) {
  skipped++;
  console.log(`  - ${msg}（跳过）`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 临时改环境变量跑一段用例，结束后原样恢复。 */
async function withEnv(overrides, fn) {
  const saved = {};
  for (const [k, v] of Object.entries(overrides)) {
    saved[k] = process.env[k];
    if (v === null) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return await fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

function makeEnv() {
  const client = new MockRedis();
  const store = createStore(client);
  return { client, store, handle: createHandler(store) };
}

/**
 * 驱动一次 HTTP 请求（core 的输入形状）。返回 { status, body }。
 * rawBody 用来自造非法 JSON 的场景。
 */
async function call(env, options) {
  const {
    method = 'GET',
    path: reqPath = '/',
    body,
    rawBody,
    token,
    authHeader,
  } = options;

  const headers = {};
  if (authHeader) headers.Authorization = authHeader;
  else if (token) headers.Authorization = `Bearer ${token}`;

  const res = await env.handle({
    method,
    path: reqPath,
    headers,
    body: rawBody !== undefined ? rawBody : body === undefined ? '' : JSON.stringify(body),
  });
  let parsed = null;
  try {
    parsed = JSON.parse(res.body);
  } catch {
    parsed = null;
  }
  return { status: res.status, body: parsed, raw: res };
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

// ---------------- 白盒辅助 ----------------

/** 直接从内存库里取一行用户文档，用于校验哈希格式（测试专用）。 */
function findUserRow(client, username) {
  const users = client.hashes.get(KEY_USERS);
  if (!users) return null;
  for (const raw of users.values()) {
    const doc = JSON.parse(raw);
    if (doc.username === username) return doc;
  }
  return null;
}

/** 取某 owner 的 ZSET 全量条目（member → score），用于校验游标语义。 */
function zsetEntries(client, ownerId) {
  return new Map(client.zsets.get(envZsetKey(ownerId)) || new Map());
}

// ---------------- 用例 ----------------

async function run() {
  console.log('sync_relay_vercel（Vercel 版）协议自测开始：');
  const env = makeEnv();
  const { client, store, handle } = env;
  const alicePassword = 'password123';
  const bobPassword = 'password456';

  // --- 0) 根路径健康检查（CF 版这里是 404，本版必须是 200）---
  {
    const r = await get(env, '/', '');
    assert(
      r.status === 200 && r.body.ok === true && r.body.service === 'aimindtree-sync-relay',
      'GET / 返回 200 + {ok, service, version}'
    );
    assert(r.body.version === '1.0.0', 'GET / version = 1.0.0');
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
    const userRow = findUserRow(client, 'carol');
    const parts = String(userRow.pwHash).split(':');
    assert(userRow.pwHash !== alicePassword, '密码不以明文存储');
    assert(
      parts.length === 2 && parts[0].length === 32 && parts[1].length === 64,
      'pwHash 形如 saltHex:hashHex（16/32 字节）'
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

  // --- 11) Alice push 计数 + ZSET 游标白盒 ---
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

    const z = zsetEntries(client, aliceUserId);
    assert(z.size === 2, 'ZSET 成员数 = 2（table__entity 唯一）');
    assert(
      z.get('notes__n1') === Date.parse(pushTime1) && z.get('notes__n2') === Date.parse(pushTime1),
      'ZSET score = Date.parse(server_time)，member = table__entity'
    );
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

  // --- 14) 覆盖同 key（upsert）：count 不变、payload 更新、游标 score 后移 ---
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

    const z = zsetEntries(client, aliceUserId);
    assert(z.size === 2, '覆盖后 ZSET 成员数不变（同 member 只更新 score）');
    assert(z.get('notes__n1') === Date.parse(pushTime1b), '覆盖后 n1 的游标 score 刷新为新 server_time');

    const pull = await post(env, '/sync/pull', { device_id: 'd1', since: null }, aliceToken);
    const n1 = pull.body.envelopes.find((e) => e.entity_id === 'n1');
    assert(n1.payload.title === 'A-updated', '覆盖后拉取到新 payload');
    // 全量 pull 必须按 server_time 升序：n2（旧）→ n1（刷新后）→ n3 → n4
    assert(
      JSON.stringify(pull.body.envelopes.map((e) => e.entity_id)) === JSON.stringify(['n2', 'n1']),
      '全量 pull 按 server_time 升序（被覆盖的条目后移）'
    );
  }

  // --- 15) since 增量过滤 ---
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
    const pull = await post(env, '/sync/pull', { device_id: 'd1', since: t3 }, aliceToken);
    assert(
      pull.body.envelopes.length === 1 && pull.body.envelopes[0].entity_id === 'n4',
      'since 增量仅返回 n4'
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
    const res = await handle({ method: 'OPTIONS', path: '/sync/push', headers: {} });
    assert(res.status === 204, 'OPTIONS 预检 → 204');
    assert(
      res.headers['Access-Control-Allow-Origin'] === '*' &&
        res.headers['Access-Control-Allow-Methods'] === 'GET, POST, OPTIONS' &&
        res.headers['Access-Control-Allow-Headers'] === 'Content-Type, Authorization',
      'OPTIONS 响应带完整 CORS 头'
    );
  }

  // --- 22) 大批量分页：push 1200 条，pull 必须取回全部 ---
  // ZSET 单命令不返回全量，pullSince 用 LIMIT offset count 循环翻页；
  // member 唯一保证全序，这里验证翻页不重不漏。
  {
    const fresh = makeEnv();
    const reg = await post(fresh, '/auth/register', { username: 'bulk', password: 'bulkbulk1234' }, '');
    const token = reg.body.token;
    const bulk = [];
    for (let i = 0; i < 1200; i++) {
      bulk.push(mkEnvId('notes', `bulk-${i}`, 'd1', { i }));
    }
    const pushRes = await post(fresh, '/sync/push', { device_id: 'd1', envelopes: bulk }, token);
    assert(pushRes.body.received === 1200, '批量 push 1200 条 → received=1200');

    const manifest = await get(fresh, '/sync/manifest', token);
    assert(manifest.body.count === 1200, 'manifest count=1200');

    const pull = await post(fresh, '/sync/pull', { device_id: 'd1', since: null }, token);
    assert(pull.body.envelopes.length === 1200, 'pull 全量取回全部 1200 条（翻页未漏数据）');

    const ids = new Set(pull.body.envelopes.map((e) => e.entity_id));
    assert(ids.size === 1200, '1200 条互不重复');

    assert(
      pull.body.envelopes.every((e) => e.op === 'upsert' && typeof e.payload.i === 'number'),
      '批量数据 payload 还原正确'
    );

    const incr = await post(fresh, '/sync/pull', { device_id: 'd1', since: pushRes.body.server_time }, token);
    assert(incr.body.envelopes.length === 0, 'since = 本次 server_time 时增量为空');

    // 默认 SYNC_WRITE_CHUNK=100 → 1200 条 = 12 个 multi() 事务（12 次 zadd）。
    const zaddCount = fresh.client.commandLog.filter((c, i) => c === 'cmd').length;
    assert(zaddCount === 24, '默认分块：1200 条 = 12 事务（12×hset + 12×zadd）');
  }

  // --- 22b) SYNC_PULL_PAGE_SIZE 调小后翻页仍然不重不漏 ---
  {
    const fresh = makeEnv();
    const reg = await post(fresh, '/auth/register', { username: 'paged', password: 'qmwnebrv1234' }, '');
    const token = reg.body.token;
    const bulk = [];
    for (let i = 0; i < 10; i++) bulk.push(mkEnvId('notes', `p-${i}`, 'd1', { i }));
    await post(fresh, '/sync/push', { device_id: 'd1', envelopes: bulk }, token);

    await withEnv({ SYNC_PULL_PAGE_SIZE: '3' }, async () => {
      const pull = await post(fresh, '/sync/pull', { device_id: 'd1', since: null }, token);
      assert(pull.body.envelopes.length === 10, 'SYNC_PULL_PAGE_SIZE=3 时 10 条全部取回（4 页翻页）');
      const ids = new Set(pull.body.envelopes.map((e) => e.entity_id));
      assert(ids.size === 10, '小分页下拉取结果无重复');
    });
  }

  // --- 22c) SYNC_WRITE_CHUNK 控制事务大小 ---
  {
    const fresh = makeEnv();
    const reg = await post(fresh, '/auth/register', { username: 'chunky', password: 'rtvybuni1234' }, '');
    const token = reg.body.token;
    await withEnv({ SYNC_WRITE_CHUNK: '500' }, async () => {
      const bulk = [];
      for (let i = 0; i < 1200; i++) bulk.push(mkEnvId('notes', `c-${i}`, 'd1', { i }));
      const pushRes = await post(fresh, '/sync/push', { device_id: 'd1', envelopes: bulk }, token);
      assert(pushRes.body.received === 1200, 'SYNC_WRITE_CHUNK=500 时 received 仍为 1200');
      assert(
        fresh.client.commandLog.filter((c) => c === 'cmd').length === 6,
        'SYNC_WRITE_CHUNK=500 → 1200 条 = 3 事务（3×hset + 3×zadd）'
      );
      const manifest = await get(fresh, '/sync/manifest', token);
      assert(manifest.body.count === 1200, '大分块写入后 manifest 仍准确');
    });
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
    assert(pull.body.envelopes[0].payload.v === 2, 'member 转义后 upsert 仍然覆盖了最新态');

    // 转义可逆且分隔符无歧义：('notes__x','y') 与 ('notes','x__y') 必须是不同 member
    assert(
      memberKey('notes', 'x__y') !== memberKey('notes__x', 'y'),
      '转义后 table__entity 拼接无歧义（_ 也被转义）'
    );
    assert(escapeKeySegment('a_b') === 'a%5Fb', 'escapeKeySegment 把 _ 转成 %5F');
    assert(
      memberKey('notes', 'n1') === 'notes__n1' && memberKey('notes', 'a.b') === 'notes__a%2Eb',
      '普通键不变、点号转义（member 形状符合预期）'
    );
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

  // --- 24) isConfigured() 环境变量判断 ---
  {
    await withEnv(
      { KV_REST_API_URL: null, KV_REST_API_TOKEN: null, KV_URL: null, KV_API_TOKEN: null },
      async () => {
        assert(isConfigured() === false, 'isConfigured() 无变量时为 false');
        await withEnv({ KV_REST_API_URL: 'https://fake.upstash.io', KV_REST_API_TOKEN: 't' }, async () => {
          assert(isConfigured() === true, 'isConfigured() KV_REST_API_URL/TOKEN 就绪为 true');
        });
        await withEnv({ KV_URL: 'https://fake', KV_API_TOKEN: 't' }, async () => {
          assert(isConfigured() === true, 'isConfigured() 兼容旧变量名 KV_URL/KV_API_TOKEN');
        });
      }
    );
  }

  // --- 25) 入口级测试：驱动真实 Vercel 函数（需已 npm i；否则跳过）---
  await runEntryTests();

  console.log(`\n结果：通过 ${passed}，失败 ${failed}${skipped ? `，跳过 ${skipped}` : ''}`);
  if (failed > 0) process.exit(1);
}

// ---------------- 入口级测试（真实 api/[[...path]].js）----------------

async function runEntryTests() {
  console.log('\n入口级测试（Web Request → Response 适配）：');
  let entry;
  try {
    const here = path.dirname(fileURLToPath(import.meta.url));
    const entryUrl = pathToFileURL(path.join(here, 'api', '[[...path]].js')).href;
    entry = await import(entryUrl);
  } catch (e) {
    skip(`加载 api/[[...path]].js 失败（未执行 npm i？）：${e.message}`);
    return;
  }

  // OPTIONS 预检不过库、不看配置，部署成功就该放行。
  {
    const res = await entry.default(
      new Request('https://relay.local/sync/push', { method: 'OPTIONS' })
    );
    assert(res.status === 204, '入口 OPTIONS → 204');
    assert(res.headers.get('Access-Control-Allow-Origin') === '*', '入口 OPTIONS 带 CORS 头');
  }

  // KV 未绑定 → 503 + 可读报错（而不是 @vercel/kv 那句看不懂的异常）。
  {
    const res = await entry.default(new Request('https://relay.local/'));
    const body = await res.json();
    assert(res.status === 503, 'KV 未绑定时 GET / → 503');
    assert(body.ok === false && typeof body.error === 'string' && body.error.includes('KV'), '503 响应带可读的 KV 绑定指引');
  }

  // 完整往返：注册 → push → pull → manifest（走真实 Request/Response 适配）。
  {
    const mock = makeEnv();
    entry.__setStoreForTesting(mock.store);
    await withEnv(
      { KV_REST_API_URL: 'https://fake.upstash.io', KV_REST_API_TOKEN: 'fake-token' },
      async () => {
        const regRes = await entry.default(
          new Request('https://relay.local/auth/register', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ username: 'entryuser', password: 'wnebirty1284' }),
          })
        );
        assert(regRes.status === 200, '入口 register → 200');
        const reg = await regRes.json();
        assert(reg.token && reg.token.length === 64, '入口 register 返回 64 位令牌');

        const pushRes = await entry.default(
          new Request('https://relay.local/sync/push', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', authorization: `Bearer ${reg.token}` },
            body: JSON.stringify({
              device_id: 'd1',
              envelopes: [mkEnvId('notes', 'e1', 'd1', { title: 'via-entry' })],
            }),
          })
        );
        assert(pushRes.status === 200, '入口 push → 200');
        const push = await pushRes.json();
        assert(push.received === 1 && push.accepted === 1, '入口 push received/accepted = 1');

        const pullRes = await entry.default(
          new Request('https://relay.local/sync/pull', {
            method: 'POST',
            headers: { authorization: `bearer ${reg.token}` },
            body: JSON.stringify({ device_id: 'd1', since: null }),
          })
        );
        const pull = await pullRes.json();
        assert(pullRes.status === 200 && pull.envelopes.length === 1, '入口 pull 全量 1 条');
        assert(pull.envelopes[0].payload.title === 'via-entry', '入口 pull payload 还原正确');

        const manifestRes = await entry.default(
          new Request('https://relay.local/sync/manifest', {
            headers: { Authorization: `Bearer ${reg.token}` },
          })
        );
        const manifest = await manifestRes.json();
        assert(manifest.count === 1, '入口 manifest count=1');

        const healthRes = await entry.default(new Request('https://relay.local/'));
        const health = await healthRes.json();
        assert(
          healthRes.status === 200 && health.ok === true && health.version === '1.0.0',
          '入口 GET / 健康检查 200 + 服务标识'
        );
      }
    );
  }
}

run().catch((e) => {
  console.error('测试异常：', e);
  process.exit(1);
});

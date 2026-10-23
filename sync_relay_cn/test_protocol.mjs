/**
 * sync_relay_cn 协议冒烟测试（不联网、不需要腾讯云账号）。
 *
 * 用一个内存版「CloudBase 文档型数据库」替换 ``app.database()`` 句柄，直接驱动
 * ``index.js`` 的请求处理函数，验证 HTTP 契约与 ``sync_relay_cf/worker.js``
 * 完全一致（断言口径照搬 ``sync_relay_cf/test_worker.mjs``）。
 *
 * 运行：node test_protocol.mjs     全绿退出码 0，有失败退出码 1。
 *
 * 覆盖：
 * - 根路径健康检查；
 * - 账号：register / login / 重名 409 / 弱密码 400 / 短用户名 400 / 错误密码 401 / 非法 JSON；
 * - 鉴权：/sync/* 未带令牌 401、错误令牌 401、小写 bearer 前缀可用、旧令牌仍有效；
 * - 数据通路：push → manifest → pull 全量、覆盖同 key、since 增量、多租户隔离；
 * - 分页：push 1200 条后 pull 必须取回全部（验证 CloudBase get() 单次 100 条限制的处理）。
 */

import relay from './index.js';

const { handle, makeStore } = relay;

// ---------------- 内存版 CloudBase 文档型数据库 ----------------

/**
 * 只实现 db.js 实际用到的那部分 SDK 行为：
 *   database.collection(name) / database.command.gt(v)
 *   collection.doc(id).set(data) / .get()
 *   collection.where(cond).orderBy(f, d).skip(n).limit(n).get() / .count()
 * 刻意保持与真实 SDK 一致的结果形状（get → { data: [] }，count → { total }）。
 */
class MockDatabase {
  constructor() {
    this.collections = new Map();
    this.command = {
      gt: (value) => ({ __cmp: 'gt', value }),
    };
  }

  collection(name) {
    if (!this.collections.has(name)) this.collections.set(name, new Map());
    const docs = this.collections.get(name);
    return new MockCollection(docs, this.command);
  }
}

class MockCollection {
  constructor(docs, command) {
    this.docs = docs;
    this.command = command;
  }

  doc(id) {
    const key = String(id);
    const self = this;
    return {
      /** CloudBase 语义：不存在则创建，存在则整篇覆盖（upsert）。 */
      async set(data) {
        self.docs.set(key, { ...data, _id: key });
        return { upsertedId: key, updated: 1 };
      },
      async get() {
        const doc = self.docs.get(key);
        return { data: doc ? [doc] : [] };
      },
    };
  }

  where(condition) {
    return new MockQuery(this.docs, this.command).where(condition);
  }
}

class MockQuery {
  constructor(docs, command) {
    this.docs = docs;
    this.command = command;
    this.filters = [];
    this.sorts = [];
    this.limitCount = null; // 不指定 limit 时，默认 100 条
    this.skipCount = 0;
  }

  where(condition) {
    for (const [field, expected] of Object.entries(condition)) {
      this.filters.push({ field, expected });
    }
    return this;
  }

  orderBy(field, direction) {
    this.sorts.push({ field, direction: direction === 'desc' ? 'desc' : 'asc' });
    return this;
  }

  limit(n) {
    this.limitCount = n;
    return this;
  }

  skip(n) {
    this.skipCount = n;
    return this;
  }

  _matches(doc) {
    return this.filters.every(({ field, expected }) => {
      const actual = doc[field];
      if (expected && typeof expected === 'object' && expected.__cmp) {
        // 目前 db.js 只用到了 gt（server_time > since），其余指令显式报错。
        if (expected.__cmp !== 'gt') throw new Error(`mock 未实现的指令: ${expected.__cmp}`);
        return typeof actual === 'string'
          ? actual > expected.value
          : actual > expected.value;
      }
      return actual === expected;
    });
  }

  _results() {
    let rows = [...this.docs.values()].filter((doc) => this._matches(doc));
    if (this.sorts.length) {
      rows.sort((a, b) => {
        for (const { field, direction } of this.sorts) {
          const av = a[field];
          const bv = b[field];
          if (av < bv) return direction === 'asc' ? -1 : 1;
          if (av > bv) return direction === 'asc' ? 1 : -1;
        }
        return 0;
      });
    }
    const limit = this.limitCount == null ? 100 : this.limitCount;
    return rows.slice(this.skipCount, this.skipCount + limit);
  }

  async get() {
    return { data: this._results() };
  }

  async count() {
    return { total: [...this.docs.values()].filter((doc) => this._matches(doc)).length };
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

function makeEnv() {
  return makeStore(new MockDatabase());
}

/**
 * 驱动一次 HTTP 请求。返回 { status, body }。
 * rawBody 用来自造非法 JSON 的场景。
 */
async function call(store, options) {
  const {
    method = 'GET',
    path = '/',
    body,
    rawBody,
    token,
    authHeader,
    base64 = false,
  } = options;

  const headers = {};
  if (authHeader) headers.Authorization = authHeader;
  else if (token) headers.Authorization = `Bearer ${token}`;

  const event = {
    path,
    httpMethod: method,
    headers,
    queryStringParameters: {},
    requestContext: { requestId: 'test' },
    isBase64Encoded: base64,
    body: rawBody !== undefined ? rawBody : body === undefined ? '' : JSON.stringify(body),
  };

  const res = await handle(store, event);
  let parsed = null;
  try {
    parsed = JSON.parse(res.body);
  } catch {
    parsed = null;
  }
  return { status: res.statusCode, body: parsed, raw: res };
}

async function post(store, path, body, token) {
  return call(store, { method: 'POST', path, body, token: token || '' });
}

async function get(store, path, token) {
  return call(store, { method: 'GET', path, token: token || '' });
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

// ---------------- 用例 ----------------

async function run() {
  console.log('sync_relay_cn（CloudBase 版）协议自测开始：');
  const database = new MockDatabase();
  const store = makeStore(database);
  const alicePassword = 'password123';
  const bobPassword = 'password456';

  // --- 0) 根路径健康检查（CF 版这里是 404，本版必须是 200）---
  {
    const r = await get(store, '/', '');
    assert(
      r.status === 200 && r.body.ok === true && r.body.service === 'aimindtree-sync-relay',
      'GET / 返回 200 + {ok, service, version}'
    );
    assert(r.body.version === '1.0.0', 'GET / version = 1.0.0');
  }

  // --- 1) 未带令牌的 push → 401 ---
  {
    const r = await post(store, '/sync/push', { device_id: 'd1', envelopes: [] }, '');
    assert(r.status === 401 && r.body.error === 'unauthorized', '未带令牌 push → 401 unauthorized');
  }

  // --- 2) 注册成功 → user_id + 64 位十六进制 token ---
  let aliceToken;
  {
    const r = await post(store, '/auth/register', { username: 'alice', password: alicePassword }, '');
    assert(r.status === 200 && typeof r.body.token === 'string', 'register 成功返回 token');
    assert(r.body.token.length === 64, 'token 为 64 位十六进制');
    assert(typeof r.body.user_id === 'string' && r.body.user_id.startsWith('u_'), 'user_id 形如 u_xxx');
    aliceToken = r.body.token;
  }

  // --- 3) 重名注册 → 409 ---
  {
    const r = await post(store, '/auth/register', { username: 'alice', password: alicePassword }, '');
    assert(r.status === 409 && r.body.error === 'username taken', '重复用户名注册 → 409');
  }

  // --- 4) 弱密码 → 400 ---
  {
    const r = await post(store, '/auth/register', { username: 'bob', password: 'short' }, '');
    assert(r.status === 400 && r.body.error === 'password too short (>=8)', '弱密码注册 → 400');
  }

  // --- 5) 短用户名 → 400 ---
  {
    const r = await post(store, '/auth/register', { username: 'ab', password: alicePassword }, '');
    assert(r.status === 400 && r.body.error === 'username too short (>=3)', '短用户名注册 → 400');
  }

  // --- 6) 非法 JSON → 400 ---
  {
    const r = await call(store, { method: 'POST', path: '/auth/register', rawBody: '{oops' });
    assert(r.status === 400 && r.body.error === 'invalid json', '非法 JSON → 400 invalid json');
  }

  // --- 7) 密码没有被明文存储，且带 PBKDF2 盐 ---
  {
    await post(store, '/auth/register', { username: 'carol', password: alicePassword }, '');
    const login = await post(store, '/auth/login', { username: 'carol', password: alicePassword }, '');
    assert(login.status === 200, '第二个账号登录成功');
    const userRow = findUserRow(database, 'carol');
    const parts = String(userRow.pw_hash).split(':');
    assert(userRow.pw_hash !== alicePassword, '密码不以明文存储');
    assert(parts.length === 2 && parts[0].length === 32 && parts[1].length === 64, 'pw_hash 形如 saltHex:hashHex（16/32 字节）');
  }

  // --- 8) 登录正确 → 200 且拿到新 token ---
  let aliceToken2;
  {
    const r = await post(store, '/auth/login', { username: 'alice', password: alicePassword }, '');
    assert(r.status === 200 && typeof r.body.token === 'string', 'login 成功返回 token');
    aliceToken2 = r.body.token;
  }

  // --- 9) 错误密码 → 401 ---
  {
    const r = await post(store, '/auth/login', { username: 'alice', password: 'wrong' }, '');
    assert(r.status === 401 && r.body.error === 'invalid credentials', '错误密码登录 → 401');
  }

  // --- 10) 不存在的用户 → 401 ---
  {
    const r = await post(store, '/auth/login', { username: 'nobody', password: alicePassword }, '');
    assert(r.status === 401, '登录不存在的用户 → 401');
  }

  // --- 11) Alice push 计数 ---
  {
    const envelopes = [mkEnvId('notes', 'n1', 'd1', { title: 'A' }), mkEnvId('notes', 'n2', 'd1', { title: 'B' })];
    const r = await post(store, '/sync/push', { device_id: 'd1', envelopes }, aliceToken);
    assert(r.status === 200 && r.body.received === 2, 'Alice push received=2');
    assert(r.body.accepted === 2, 'Alice push accepted=2（兼容旧版 App）');
    assert(typeof r.body.server_time === 'string' && r.body.server_time.endsWith('Z'), 'server_time 为 ISO 8601 UTC');
  }

  // --- 12) manifest ---
  {
    const r = await get(store, '/sync/manifest', aliceToken);
    assert(r.body.count === 2, 'Alice manifest count=2');
  }

  // --- 13) pull 全量 ---
  {
    const r = await post(store, '/sync/pull', { device_id: 'd1', since: null }, aliceToken);
    assert(r.body.envelopes.length === 2, 'Alice pull 全量 2 条');
    assert(r.body.envelopes[0].payload.title === 'A', 'Alice payload 还原正确');
    assert(r.body.envelopes[0].deleted_at === null, 'envelope 字段完整（deleted_at 保留 null）');
  }

  // --- 14) 覆盖同 key（upsert）---
  {
    await post(store, '/sync/push', { device_id: 'd1', envelopes: [mkEnvId('notes', 'n1', 'd1', { title: 'A-updated' })] }, aliceToken);
    const manifest = await get(store, '/sync/manifest', aliceToken);
    assert(manifest.body.count === 2, '覆盖同 key 后 count 仍为 2');
    const pull = await post(store, '/sync/pull', { device_id: 'd1', since: null }, aliceToken);
    const n1 = pull.body.envelopes.find((e) => e.entity_id === 'n1');
    assert(n1.payload.title === 'A-updated', '覆盖后拉取到新 payload');
  }

  // --- 15) since 增量过滤 ---
  {
    const p3 = await post(store, '/sync/push', { device_id: 'd1', envelopes: [mkEnvId('notes', 'n3', 'd1', { title: 'C' })] }, aliceToken);
    const t3 = p3.body.server_time;
    await new Promise((r) => setTimeout(r, 15));
    await post(store, '/sync/push', { device_id: 'd1', envelopes: [mkEnvId('notes', 'n4', 'd1', { title: 'D' })] }, aliceToken);
    const pull = await post(store, '/sync/pull', { device_id: 'd1', since: t3 }, aliceToken);
    assert(
      pull.body.envelopes.length === 1 && pull.body.envelopes[0].entity_id === 'n4',
      'since 增量仅返回 n4'
    );
  }

  // --- 16) 无效令牌 → 401 ---
  {
    const r = await get(store, '/sync/manifest', 'deadbeef');
    assert(r.status === 401, '无效令牌 → 401');
  }

  // --- 17) lowercase bearer 前缀也能识别 ---
  {
    const r = await call(store, { method: 'GET', path: '/sync/manifest', authHeader: `bearer ${aliceToken}` });
    assert(r.status === 200, '小写 bearer 前缀同样可用');
  }

  // --- 18) 多租户隔离 ---
  let bobToken;
  {
    const reg = await post(store, '/auth/register', { username: 'bob', password: bobPassword }, '');
    bobToken = reg.body.token;
    await post(store, '/sync/push', { device_id: 'd2', envelopes: [mkEnvId('notes', 'n1', 'd2', { title: 'Bobs-N1' })] }, bobToken);

    const alicePull = await post(store, '/sync/pull', { device_id: 'd1', since: null }, aliceToken);
    assert(alicePull.body.envelopes.length === 4, 'Alice 名下 4 条（n1,n2,n3,n4）');
    assert(
      !alicePull.body.envelopes.some((e) => e.payload && e.payload.title === 'Bobs-N1'),
      'Alice 拉不到 Bob 的 n1'
    );

    const bobPull = await post(store, '/sync/pull', { device_id: 'd2', since: null }, bobToken);
    assert(bobPull.body.envelopes.length === 1, 'Bob 名下仅 1 条');
    assert(bobPull.body.envelopes[0].payload.title === 'Bobs-N1', 'Bob 只看到自己的 n1');
  }

  // --- 19) 旧令牌仍有效 ---
  {
    const r = await get(store, '/sync/manifest', aliceToken2);
    assert(r.body.count === 4, 'Alice 的旧登录令牌仍指向 Alice 命名空间');
  }

  // --- 20) 未知路径 → 404 ---
  {
    const r = await get(store, '/sync/nope', aliceToken);
    assert(r.status === 404 && r.body.error === 'not found', '未知路径 → 404 not found');
  }

  // --- 21) OPTIONS 预检 → 204 带 CORS 头 ---
  {
    const res = await handle(store, { path: '/sync/push', httpMethod: 'OPTIONS', headers: {} });
    assert(res.statusCode === 204, 'OPTIONS 预检 → 204');
    assert(res.headers['Access-Control-Allow-Origin'] === '*', 'OPTIONS 响应带 CORS 头');
  }

  // --- 22) 大批量分页：push 1200 条，pull 必须取回全部 ---
  // CloudBase 单次 get() 默认只返回 100 条（上限 1000），这里验证 pullSince 的
  // 循环翻页逻辑没有漏数据。
  {
    const fresh = makeEnv(); // 独立环境
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
    assert(pull.body.envelopes.length === 1200, 'pull 全量取回全部 1200 条（分页未漏数据）');

    const ids = new Set(pull.body.envelopes.map((e) => e.entity_id));
    assert(ids.size === 1200, '1200 条互不重复');
    assert(
      pull.body.envelopes.every((e) => e.op === 'upsert' && typeof e.payload.i === 'number'),
      '批量数据 payload 还原正确'
    );

    const incr = await post(fresh, '/sync/pull', { device_id: 'd1', since: pushRes.body.server_time }, token);
    assert(incr.body.envelopes.length === 0, 'since = 本次 server_time 时增量为空');
  }

  // --- 23) entity_id 带点号也能正确 upsert（_id 转义）---
  {
    const fresh = makeEnv();
    const reg = await post(fresh, '/auth/register', { username: 'dotted', password: 'dotted12345' }, '');
    const token = reg.body.token;
    const dottedId = 'a.b$c/d';
    await post(fresh, '/sync/push', { device_id: 'd1', envelopes: [mkEnvId('notes', dottedId, 'd1', { v: 1 })] }, token);
    await post(fresh, '/sync/push', { device_id: 'd1', envelopes: [mkEnvId('notes', dottedId, 'd1', { v: 2 })] }, token);
    const manifest = await get(fresh, '/sync/manifest', token);
    assert(manifest.body.count === 1, '带特殊字符的 entity_id 覆盖而非新增');
    const pull = await post(fresh, '/sync/pull', { device_id: 'd1', since: null }, token);
    assert(pull.body.envelopes[0].entity_id === dottedId, 'entity_id 原样返回给 App');
    assert(pull.body.envelopes[0].payload.v === 2, '_id 转义后 upsert 仍然覆盖了最新态');
  }

  console.log(`\n结果：通过 ${passed}，失败 ${failed}`);
  if (failed > 0) process.exit(1);
}

/** 直接从内存库里取一行用户文档，用于校验哈希格式（测试专用白盒断言）。 */
function findUserRow(database, username) {
  for (const doc of database.collections.get('sync_users').values()) {
    if (doc.username === username) return doc;
  }
  return null;
}

run().catch((e) => {
  console.error('测试异常：', e);
  process.exit(1);
});

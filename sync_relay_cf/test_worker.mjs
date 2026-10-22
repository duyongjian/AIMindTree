/**
 * 方案 B 中继逻辑自测（多租户账号版，无需 wrangler / D1 真实实例）。
 *
 * 用最简内存版 D1 模拟 ``DB`` 绑定，直接驱动 ``worker.js`` 的 ``fetch`` handler，
 * 验证与 App 端契约一致：
 * - 账号：register / login（密码 PBKDF2 哈希、错误密码 401、重名 409）；
 * - 同步：/sync/* 必须带用户令牌，且按 owner_id 隔离（A 看不到 B 的数据）；
 * - 数据通路：push → pull → manifest、INSERT OR REPLACE 覆盖、since 增量过滤、404。
 *
 * 运行：node test_worker.mjs   （须在含 package.json {"type":"module"} 的目录）
 */

import { webcrypto } from 'node:crypto';
// worker.js 依赖全局 Web Crypto（crypto.subtle / getRandomValues）。
if (!globalThis.crypto) globalThis.crypto = webcrypto;

import worker from './worker.js';

// ---------------- 最简内存 D1 模拟（支持账号表 + owner 隔离） ----------------

class MockD1 {
  constructor() {
    this.tables = {
      sync_envelopes: new Map(),
      sync_users: new Map(),
      sync_tokens: new Map(),
    };
  }

  _pk(table, row) {
    if (table === 'sync_envelopes') {
      return `${row.owner_id}|${row.entity_table}|${row.entity_id}`;
    }
    if (table === 'sync_users') return row.id;
    if (table === 'sync_tokens') return row.token;
    return JSON.stringify(row);
  }

  prepare(sql) {
    const self = this;
    const make = (params) => ({
      _sql: sql,
      _params: params,
      bind(...p) {
        return make(p);
      },
      async all() {
        return { results: self._select(this._sql, this._params) };
      },
      async first() {
        const res = self._select(this._sql, this._params);
        return res && res.length ? res[0] : null;
      },
      async run() {
        self._exec(this._sql, this._params);
        return { success: true };
      },
    });
    return make([]);
  }

  async batch(statements) {
    for (const stmt of statements) await stmt.run();
    return statements.map(() => ({ success: true }));
  }

  _exec(sql, params) {
    const m = sql.match(/INSERT(?: OR REPLACE)? INTO (\w+)\s*\(([^)]+)\)\s*VALUES\s*\(([^)]+)\)/);
    if (m) {
      const table = m[1];
      const cols = m[2].split(',').map((s) => s.trim());
      const row = {};
      cols.forEach((c, i) => (row[c] = params[i]));
      this.tables[table].set(this._pk(table, row), row);
    }
  }

  _select(sql, params) {
    const tm = sql.match(/FROM (\w+)/);
    const table = tm[1];
    const list = [...this.tables[table].values()];
    const filter = this._where(sql, params);
    let out = list.filter(filter);
    if (sql.includes('COUNT(*)')) return [{ count: out.length }];
    if (sql.includes('ORDER BY server_time')) {
      out.sort((a, b) =>
        a.server_time < b.server_time ? -1 : a.server_time > b.server_time ? 1 : 0
      );
    }
    return out;
  }

  /** 解析 WHERE col = ? / col > ?（占位符按 SQL 中 ? 的出现顺序对应 params）。 */
  _where(sql, params) {
    const idx = sql.indexOf('WHERE');
    if (idx < 0) return () => true;
    let rest = sql.slice(idx + 5);
    const ob = rest.indexOf('ORDER BY');
    if (ob >= 0) rest = rest.slice(0, ob);
    rest = rest.trim();
    if (!rest) return () => true;
    const clauses = rest.split(/\s+AND\s+/i);
    // 每个 clause 的 ? 对应 SQL 中第几个占位符（占位符只在 WHERE 之后，全局计数）。
    // 注意：索引必须在闭包外按 clause 位置预计算，不能随每行自增（否则多行会错位）。
    let running = 0;
    const clauseParamIndex = clauses.map((cl) => {
      const before = running;
      running += (cl.match(/\?/g) || []).length;
      return before;
    });
    return (row) =>
      clauses.every((cl, i) => {
        const cm = cl.match(/(\w+)\s*(=|>)\s*\?/);
        if (!cm) return true;
        const col = cm[1];
        const op = cm[2];
        const val = params[clauseParamIndex[i]];
        if (op === '=') return String(row[col]) === String(val);
        if (op === '>') return row[col] > val;
        return true;
      });
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
  return { DB: new MockD1() };
}

async function post(path, body, env, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  return worker.fetch(
    new Request(`https://relay.test${path}`, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
    }),
    env
  );
}

async function get(path, env, token) {
  const headers = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  return worker.fetch(
    new Request(`https://relay.test${path}`, { method: 'GET', headers }),
    env
  );
}

function mkEnv(table, id, device, payload) {
  return {
    device_id: device,
    entity_table: table,
    entity_id: id,
    op: 'upsert',
    payload,
    base_version: 1,
    updated_at: '2024-10-23T00:00:00.000Z',
    deleted_at: null,
  };
}

async function json(r) {
  return { status: r.status, body: await r.json() };
}

// ---------------- 用例 ----------------

async function run() {
  console.log('方案 B 多租户中继自测开始：');

  // --- 账号 ---
  const env = makeEnv();

  // 1) 未带令牌的 push → 401
  {
    const r = await json(await post('/sync/push', { device_id: 'd1', envelopes: [] }, env, ''));
    assert(r.status === 401, '未带用户令牌 push → 401 unauthorized');
  }

  // 2) 注册 → 拿到 user_id + token
  let aliceToken;
  {
    const r = await json(await post('/auth/register', { username: 'alice', password: 'password123' }, env, ''));
    assert(r.status === 200 && typeof r.body.token === 'string', 'register 成功返回 token');
    assert(r.body.token.length === 64, 'token 为 64 位十六进制');
    aliceToken = r.body.token;
  }

  // 3) 重名注册 → 409
  {
    const r = await json(await post('/auth/register', { username: 'alice', password: 'password123' }, env, ''));
    assert(r.status === 409, '重复用户名注册 → 409');
  }

  // 4) 弱密码 → 400
  {
    const r = await json(await post('/auth/register', { username: 'bob', password: 'short' }, env, ''));
    assert(r.status === 400, '弱密码注册 → 400');
  }

  // 5) 登录正确 → 200 且 token 不同
  let aliceToken2;
  {
    const r = await json(await post('/auth/login', { username: 'alice', password: 'password123' }, env, ''));
    assert(r.status === 200 && typeof r.body.token === 'string', 'login 成功返回 token');
    aliceToken2 = r.body.token;
  }

  // 6) 错误密码 → 401
  {
    const r = await json(await post('/auth/login', { username: 'alice', password: 'wrong' }, env, ''));
    assert(r.status === 401, '错误密码登录 → 401');
  }

  // --- 数据通路（Alice）---
  // 7) Alice push 计数
  {
    const envelopes = [
      mkEnv('notes', 'n1', 'd1', { title: 'A' }),
      mkEnv('notes', 'n2', 'd1', { title: 'B' }),
    ];
    const r = await json(await post('/sync/push', { device_id: 'd1', envelopes }, env, aliceToken));
    assert(r.status === 200 && r.body.received === 2, 'Alice push 接收 2 条');
  }

  // 8) Alice manifest
  {
    const r = await json(await get('/sync/manifest', env, aliceToken));
    assert(r.body.count === 2, 'Alice manifest count=2');
  }

  // 9) Alice pull 全量
  {
    const r = await json(await post('/sync/pull', { device_id: 'd1', since: null }, env, aliceToken));
    assert(r.body.envelopes.length === 2, 'Alice pull 全量 2 条');
    assert(r.body.envelopes[0].payload.title === 'A', 'Alice payload 还原正确');
  }

  // 10) INSERT OR REPLACE 覆盖同 key（仍属 Alice 名下）
  {
    await post('/sync/push', { device_id: 'd1', envelopes: [mkEnv('notes', 'n1', 'd1', { title: 'A-updated' })] }, env, aliceToken);
    const manifest = await json(await get('/sync/manifest', env, aliceToken));
    assert(manifest.body.count === 2, '覆盖同 key 后 count 仍为 2');
    const pull = await json(await post('/sync/pull', { device_id: 'd1', since: null }, env, aliceToken));
    const n1 = pull.body.envelopes.find((e) => e.entity_id === 'n1');
    assert(n1.payload.title === 'A-updated', '覆盖后拉取到新 payload');
  }

  // 11) since 增量过滤（确定性）
  {
    const p3 = await post('/sync/push', { device_id: 'd1', envelopes: [mkEnv('notes', 'n3', 'd1', { title: 'C' })] }, env, aliceToken);
    const t3 = (await json(p3)).body.server_time;
    await new Promise((r) => setTimeout(r, 10));
    await post('/sync/push', { device_id: 'd1', envelopes: [mkEnv('notes', 'n4', 'd1', { title: 'D' })] }, env, aliceToken);
    const pull = await json(await post('/sync/pull', { device_id: 'd1', since: t3 }, env, aliceToken));
    assert(pull.body.envelopes.length === 1 && pull.body.envelopes[0].entity_id === 'n4', 'since 增量仅返回 n4');
  }

  // --- 多租户隔离 ---
  // 12) Bob 注册并 push，互相不可见
  let bobToken;
  {
    const reg = await json(await post('/auth/register', { username: 'bob', password: 'password456' }, env, ''));
    bobToken = reg.body.token;
    await post('/sync/push', { device_id: 'd2', envelopes: [mkEnv('notes', 'n1', 'd2', { title: 'Bobs-N1' })] }, env, bobToken);
  }

  // 13) Alice 看不到 Bob 的数据（按 owner_id 隔离）
  {
    const alicePull = await json(await post('/sync/pull', { device_id: 'd1', since: null }, env, aliceToken));
    assert(alicePull.body.envelopes.every((e) => e.entity_table === 'notes'), 'Alice 拉到的都是 notes');
    assert(!alicePull.body.envelopes.some((e) => e.payload && e.payload.title === 'Bobs-N1'), 'Alice 拉不到 Bob 的 n1');
    assert(alicePull.body.envelopes.length === 4, 'Alice 名下 4 条（n1,n2,n3,n4）');

    const bobPull = await json(await post('/sync/pull', { device_id: 'd2', since: null }, env, bobToken));
    assert(bobPull.body.envelopes.length === 1, 'Bob 名下仅 1 条');
    assert(bobPull.body.envelopes[0].payload.title === 'Bobs-N1', 'Bob 只看到自己的 n1');
  }

  // 14) Bob 用 Alice 的旧令牌仍可访问（令牌有效，独立鉴权；此测验证令牌机制本身）
  {
    const bobWithAliceToken = await json(await get('/sync/manifest', env, aliceToken2));
    assert(bobWithAliceToken.body.count === 4, 'Alice 的旧登录令牌仍指向 Alice 命名空间');
  }

  // 15) 未知路径 404
  {
    const r = await json(await get('/sync/nope', env, aliceToken));
    assert(r.status === 404, '未知路径 → 404');
  }

  console.log(`\n结果：通过 ${passed}，失败 ${failed}`);
  if (failed > 0) process.exit(1);
}

run().catch((e) => {
  console.error('测试异常：', e);
  process.exit(1);
});

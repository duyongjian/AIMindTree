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
    // DELETE：管理接口用到（DELETE FROM t [WHERE col = ?]）。
    const del = sql.match(/^DELETE\s+FROM\s+(\w+)/i);
    if (del) {
      const table = del[1];
      const filter = this._where(sql, params);
      for (const [k, row] of [...this.tables[table].entries()]) {
        if (filter(row)) this.tables[table].delete(k);
      }
      return;
    }
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
    // GROUP BY：管理接口的聚合查询（COUNT(*) + MAX(server_time)）。
    const gm = sql.match(/GROUP\s+BY\s+(\w+)/i);
    if (gm) {
      const gcol = gm[1];
      const groups = new Map();
      for (const row of out) {
        const k = row[gcol];
        const cur = groups.get(k) || { [gcol]: k, c: 0, latest: null };
        cur.c += 1;
        const ts = row.server_time;
        if (ts && (cur.latest === null || ts > cur.latest)) cur.latest = ts;
        groups.set(k, cur);
      }
      return [...groups.values()];
    }
    // 聚合查询（COUNT(*) 且可选地同句带 MAX(col)）：manifest / admin stats。
    // COUNT 与 MAX 同句时必须合成**同一行**返回（manifest 读的就是这一行）。
    if (sql.includes('COUNT(*)')) {
      const alias = (sql.match(/COUNT\(\*\)\s+(?:AS\s+)?(\w+)/i) || [])[1] || 'count';
      const row = { [alias]: out.length };
      const mm = sql.match(/MAX\((\w+)\)/i);
      if (mm) {
        const mAlias = (sql.match(/MAX\(\w+\)\s+(?:AS\s+)?(\w+)/i) || [])[1] || 'max';
        let m = 0;
        for (const r of out) {
          const v = Number(r[mm[1]]);
          if (Number.isFinite(v) && v > m) m = v;
        }
        row[mAlias] = m;
      }
      return [row];
    }
    if (sql.includes('ORDER BY server_time') || sql.includes('ORDER BY owner_id, server_time')) {
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

async function del(path, env, token) {
  const headers = {};
  if (token) headers['Authorization'] = `Bearer ${token}`;
  return worker.fetch(
    new Request(`https://relay.test${path}`, { method: 'DELETE', headers }),
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
    // 服务端权威版本：响应必须带 versions 对象，且非空（本次推了 2 个实体）。
    assert(typeof r.body.versions === 'object' && r.body.versions !== null, 'push 返回 versions 对象');
    assert(Object.keys(r.body.versions).length === 2, 'push versions 含 2 个实体');
    assert(r.body.versions['notes:n1'] === 2 && r.body.versions['notes:n2'] === 2, 'versions 为 max(既有, 声明)+1 = 2');
  }

  // 8) Alice manifest（count + max_version）
  {
    const r = await json(await get('/sync/manifest', env, aliceToken));
    assert(r.body.count === 2, 'Alice manifest count=2');
    // 两条都是 base_version=1 的首次上传 → 服务端版本 = max(0,1)+1 = 2。
    assert(r.body.max_version === 2, 'Alice manifest max_version=2');
    // 旧版 App 只读 count，字段必须保留（向后兼容）。
    assert(typeof r.body.count === 'number', 'manifest 仍保留 count 字段');
  }

  // 9) Alice pull 全量
  {
    const r = await json(await post('/sync/pull', { device_id: 'd1', since: null }, env, aliceToken));
    assert(r.body.envelopes.length === 2, 'Alice pull 全量 2 条');
    assert(r.body.envelopes[0].payload.title === 'A', 'Alice payload 还原正确');
  }

  // 10) INSERT OR REPLACE 覆盖同 key（仍属 Alice 名下）
  {
    // 基于既有版本 2 重新上传（声明 base_version=2）→ 服务端递增到 3。
    await post('/sync/push', {
      device_id: 'd1',
      envelopes: [{ device_id: 'd1', entity_table: 'notes', entity_id: 'n1', op: 'upsert', payload: { title: 'A-updated' }, base_version: 2, updated_at: '2024-10-23T00:00:00.000Z', deleted_at: null }],
    }, env, aliceToken);
    const manifest = await json(await get('/sync/manifest', env, aliceToken));
    assert(manifest.body.count === 2, '覆盖同 key 后 count 仍为 2');
    // 覆盖会再次递增该实体版本：max(既有 2, 声明 2)+1 = 3 → 命名空间最大版本 3。
    assert(manifest.body.max_version === 3, '覆盖同 key 后 max_version 递增到 3');
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
    // 命名空间隔离：Alice 的最大版本只由她自己的 4 条决定（n1=3, 其余=2）。
    assert(bobWithAliceToken.body.max_version === 3, 'Alice manifest max_version=3（隔离自 Bob）');
  }

  // 14b) 空命名空间 → max_version=0（SQLite MAX() 对空集返回 NULL → 回落 0）
  {
    const fresh = makeEnv();
    const reg = await json(await post('/auth/register', { username: 'empty', password: 'kdmvnzqa1029' }, fresh, ''));
    const m = await json(await get('/sync/manifest', fresh, reg.body.token));
    assert(m.body.count === 0 && m.body.max_version === 0, '空命名空间 manifest count=0 max_version=0');
  }

  // 15) 未知路径 404
  {
    const r = await json(await get('/sync/nope', env, aliceToken));
    assert(r.status === 404, '未知路径 → 404');
  }

  // ---------------- 管理接口 /admin/* ----------------
  // 与 Netlify 版契约逐字一致（同一组断言在 test_protocol.mjs 里也有一份）。
  const ADMIN = 'adm_secret_123';
  const adminEnv = { ...env, ADMIN_TOKEN: ADMIN };

  // 16a) CORS 预检：OPTIONS 早退分支下发的必须是同一套 Allow-Methods（含 DELETE）
  {
    // 带部署前缀也不影响：OPTIONS 在路由判定之前就返回。
    const r1 = await worker.fetch(
      new Request('https://relay.test/admin/user/u_abc', { method: 'OPTIONS' }),
      env
    );
    const m1 = r1.headers.get('access-control-allow-methods') || '';
    assert(r1.status === 204, 'OPTIONS /admin/user/{id} → 204');
    assert(m1.includes('DELETE'), 'admin 预检 Allow-Methods 含 DELETE');

    const r2 = await worker.fetch(
      new Request('https://relay.test/sync/push', { method: 'OPTIONS' }),
      env
    );
    const m2 = r2.headers.get('access-control-allow-methods') || '';
    assert(r2.status === 204, 'OPTIONS /sync/push → 204');
    assert(
      m2 === m1 && m2.includes('DELETE'),
      '用户侧与 admin 侧共用同一套 Allow-Methods（未为 admin 单开分支）'
    );

    // 浏览器预检不带 Authorization：未配 ADMIN_TOKEN 时也必须放行（不能 404）
    const r3 = await worker.fetch(
      new Request('https://relay.test/admin/stats', { method: 'OPTIONS' }),
      { DB: env.DB }
    );
    assert(r3.status === 204 && r3.headers.get('access-control-allow-origin') === '*', '未配 ADMIN_TOKEN 时 admin 预检仍 204');
  }

  // 16) 未配置 ADMIN_TOKEN → 全部 404（端点不可见）
  {
    const r = await json(await get('/admin/ping', env, 'whatever'));
    assert(
      r.status === 404 && r.body.error === 'not_found',
      '未配 ADMIN_TOKEN → /admin/ping 404 not_found'
    );
    const r2 = await json(
      await post('/admin/reset', { scope: 'all', confirm: 'RESET' }, env, 'whatever')
    );
    assert(r2.status === 404, '未配 ADMIN_TOKEN → /admin/reset 404');
    const r3 = await json(await get('/admin/ping', { ...env, ADMIN_TOKEN: '   ' }, ''));
    assert(r3.status === 404, 'ADMIN_TOKEN 为空白串 → 404');
  }

  // 17) 令牌不符 → 401 + WWW-Authenticate
  {
    const raw = await get('/admin/ping', adminEnv, 'wrong-token');
    assert(raw.status === 401, '错管理令牌 → 401');
    assert(raw.headers.get('www-authenticate') === 'Bearer', '401 带 WWW-Authenticate: Bearer');
    const body = await raw.json();
    assert(body.error === 'unauthorized', '401 body error=unauthorized');
    const noAuth = await json(await get('/admin/ping', adminEnv, ''));
    assert(noAuth.status === 401, '缺管理令牌 → 401');
  }

  // 18) ping
  {
    const r = await json(await get('/admin/ping', adminEnv, ADMIN));
    assert(
      r.status === 200 && r.body.ok === true && r.body.storage === 'd1',
      'ping → 200 {ok:true, storage:"d1"}'
    );
    assert(
      typeof r.body.server_time === 'string' && r.body.server_time.endsWith('Z'),
      'ping 带 ISO server_time'
    );
  }

  // 19) stats：2 用户 / 3 令牌 / 5 envelopes（alice 4 + bob 1）
  let aliceId = null;
  let bobId = null;
  {
    const r = await json(await get('/admin/stats', adminEnv, ADMIN));
    assert(r.status === 200 && r.body.storage === 'd1', 'stats 200 storage=d1');
    assert(r.body.users === 2, 'stats users=2');
    assert(r.body.tokens === 3, 'stats tokens=3（alice 2 + bob 1）');
    assert(r.body.envelopes === 5, 'stats envelopes=5');
    assert(Array.isArray(r.body.per_user) && r.body.per_user.length === 2, 'per_user 2 条');
    const top = r.body.per_user[0];
    assert(top.username === 'alice' && top.envelopes === 4, 'per_user 按 envelopes 降序（alice 4 首条）');
    assert(top.tokens === 2, 'per_user alice tokens=2');
    assert(
      typeof top.last_server_time === 'string' && top.last_server_time.endsWith('Z'),
      'per_user last_server_time 为 ISO 串'
    );
    assert(r.body.per_user[1].username === 'bob' && r.body.per_user[1].envelopes === 1, 'per_user 次条 bob 1 条');
    aliceId = top.user_id;
    bobId = r.body.per_user[1].user_id;
  }

  // 20) users 列表形状
  {
    const r = await json(await get('/admin/users', adminEnv, ADMIN));
    assert(r.status === 200 && Array.isArray(r.body.users) && r.body.users.length === 2, 'users 2 条');
    const a = r.body.users[0];
    assert(a.user_id === aliceId && a.username === 'alice', 'users 首条为 alice');
    assert(typeof a.created_at === 'string' && a.created_at.length > 0, 'users 带 created_at');
    assert(a.tokens === 2 && a.envelopes === 4, 'users alice tokens=2 / envelopes=4');
  }

  // 21) export 全量
  {
    const r = await json(await get('/admin/export', adminEnv, ADMIN));
    assert(r.status === 200 && r.body.user_id === null, 'export 全量 user_id=null');
    assert(typeof r.body.exported_at === 'string' && r.body.truncated === false, 'export 带 exported_at / truncated=false');
    assert(r.body.envelopes.length === 5, 'export 全量 5 条 envelope');
    assert(r.body.users.length === 2, 'export 全量 2 个 user');
    const e = r.body.envelopes[0];
    const keys = Object.keys(e).sort().join(',');
    assert(
      keys === 'base_version,deleted_at,device_id,entity_id,entity_table,op,payload,updated_at',
      'export envelope 形状与 pull 一致（payload 已反序列化）'
    );
    assert(e.payload && typeof e.payload === 'object', 'export payload 是对象而非字符串');
  }

  // 22) export?user_id= 过滤
  {
    const r = await json(await get(`/admin/export?user_id=${bobId}`, adminEnv, ADMIN));
    assert(r.status === 200 && r.body.user_id === bobId, 'export 回显 user_id');
    assert(r.body.envelopes.length === 1 && r.body.envelopes[0].payload.title === 'Bobs-N1', 'export 仅返回该用户的 envelope');
    assert(r.body.users.length === 1 && r.body.users[0].user_id === bobId, 'export users 也按 user_id 过滤');
  }

  // 23) reset 参数校验（三种 400；且不得误删数据）
  {
    const r1 = await json(await post('/admin/reset', { scope: 'all' }, adminEnv, ADMIN));
    assert(r1.status === 400 && r1.body.error === 'confirm_required', 'reset 缺 confirm → 400 confirm_required');
    const r2 = await json(await post('/admin/reset', { scope: 'all', confirm: 'reset' }, adminEnv, ADMIN));
    assert(r2.status === 400 && r2.body.error === 'confirm_required', 'confirm 非大写 RESET → 400');
    const r3 = await json(await post('/admin/reset', { scope: 'user', confirm: 'RESET' }, adminEnv, ADMIN));
    assert(r3.status === 400 && r3.body.error === 'user_id_required', 'scope=user 缺 user_id → 400 user_id_required');
    const r4 = await json(await post('/admin/reset', { scope: 'bogus', confirm: 'RESET' }, adminEnv, ADMIN));
    assert(r4.status === 400 && r4.body.error === 'invalid_scope', '未知 scope → 400 invalid_scope');
    const s = await json(await get('/admin/stats', adminEnv, ADMIN));
    assert(s.body.envelopes === 5 && s.body.users === 2, '校验失败不删数据');
  }

  // 24) reset scope=user（bob）→ 计数正确 + 幂等
  {
    const r = await json(
      await post('/admin/reset', { scope: 'user', user_id: bobId, confirm: 'RESET' }, adminEnv, ADMIN)
    );
    assert(
      r.status === 200 &&
        r.body.scope === 'user' &&
        r.body.deleted.envelopes === 1 &&
        r.body.deleted.tokens === 1 &&
        r.body.deleted.users === 1,
      'reset user 删除 bob：1 envelope / 1 token / 1 user'
    );
    const again = await json(
      await post('/admin/reset', { scope: 'user', user_id: bobId, confirm: 'RESET' }, adminEnv, ADMIN)
    );
    assert(
      again.body.deleted.envelopes === 0 &&
        again.body.deleted.tokens === 0 &&
        again.body.deleted.users === 0,
      'reset user 重复调用 → 全 0（幂等）'
    );
    const s = await json(await get('/admin/stats', adminEnv, ADMIN));
    assert(s.body.users === 1 && s.body.tokens === 2 && s.body.envelopes === 4, 'reset user 后 stats 1/2/4');
  }

  // 25) DELETE /admin/user/{id}：已删除的 bob → 404
  {
    const r = await json(await del(`/admin/user/${bobId}`, adminEnv, ADMIN));
    assert(r.status === 404 && r.body.error === 'user_not_found', 'DELETE 不存在的用户 → 404 user_not_found');
  }

  // 26) reset scope=envelopes：只删 envelope，令牌/用户不动 + 幂等
  {
    const r = await json(await post('/admin/reset', { scope: 'envelopes', confirm: 'RESET' }, adminEnv, ADMIN));
    assert(
      r.status === 200 &&
        r.body.deleted.envelopes === 4 &&
        r.body.deleted.tokens === 0 &&
        r.body.deleted.users === 0,
      'reset envelopes 删 4 条，token/users 记 0'
    );
    const again = await json(await post('/admin/reset', { scope: 'envelopes', confirm: 'RESET' }, adminEnv, ADMIN));
    assert(again.body.deleted.envelopes === 0, 'reset envelopes 重复调用 → 0（幂等）');
    const s = await json(await get('/admin/stats', adminEnv, ADMIN));
    assert(s.body.envelopes === 0 && s.body.users === 1 && s.body.tokens === 2, 'reset envelopes 后仅 envelope 归零');
    assert(
      s.body.per_user[0].envelopes === 0 && s.body.per_user[0].last_server_time === null,
      '无数据时 per_user envelopes=0 / last_server_time=null'
    );
  }

  // 27) reset scope=all：全清 + 幂等 + 令牌失效
  {
    const r = await json(await post('/admin/reset', { scope: 'all', confirm: 'RESET' }, adminEnv, ADMIN));
    assert(
      r.status === 200 &&
        r.body.scope === 'all' &&
        r.body.deleted.envelopes === 0 &&
        r.body.deleted.tokens === 2 &&
        r.body.deleted.users === 1,
      'reset all 删 2 token / 1 user（envelope 已空）'
    );
    const again = await json(await post('/admin/reset', { scope: 'all', confirm: 'RESET' }, adminEnv, ADMIN));
    assert(
      again.body.deleted.envelopes === 0 &&
        again.body.deleted.tokens === 0 &&
        again.body.deleted.users === 0,
      'reset all 重复调用 → 全 0（幂等）'
    );
    const s = await json(await get('/admin/stats', adminEnv, ADMIN));
    assert(s.body.users === 0 && s.body.tokens === 0 && s.body.envelopes === 0, 'reset all 后全 0');
    const sync = await json(await get('/sync/manifest', env, aliceToken));
    assert(sync.status === 401, 'reset all 后旧用户令牌失效（401）');
  }

  // 28) export 截断：>10000 条时 truncated=true 且只回 10000 条
  {
    const reg = await json(await post('/auth/register', { username: 'carl', password: 'password789' }, env, ''));
    const carlToken = reg.body.token;
    const bulk = [];
    for (let i = 0; i < 10001; i++) {
      bulk.push(mkEnv('notes', 'bulk' + i, 'd9', { i }));
    }
    await post('/sync/push', { device_id: 'd9', envelopes: bulk }, env, carlToken);
    const r = await json(await get(`/admin/export?user_id=${reg.body.user_id}`, adminEnv, ADMIN));
    assert(
      r.status === 200 && r.body.truncated === true && r.body.envelopes.length === 10000,
      'export 超 10000 条 → truncated=true 且截到 10000'
    );
  }

  // 29) per_user / users 上限 100（另起干净环境直接造 150 个账号）
  {
    const env2 = makeEnv();
    for (let i = 0; i < 150; i++) {
      env2.DB.tables.sync_users.set(`u_x${i}`, {
        id: `u_x${i}`,
        username: `user${i}`,
        pw_hash: 'salt:hash',
        created_at: '2026-01-01T00:00:00.000Z',
      });
    }
    const mkRow = (owner, id) => ({
      owner_id: owner,
      entity_table: 'notes',
      entity_id: id,
      device_id: 'd',
      op: 'upsert',
      payload_json: '{}',
      base_version: 1,
      updated_at: '2026-01-01T00:00:00.000Z',
      deleted_at: null,
      server_time: '2026-01-01T00:00:00.000Z',
    });
    env2.DB.tables.sync_envelopes.set('u_x0|notes|a', mkRow('u_x0', 'a'));
    env2.DB.tables.sync_envelopes.set('u_x0|notes|b', mkRow('u_x0', 'b'));
    env2.DB.tables.sync_envelopes.set('u_x1|notes|c', mkRow('u_x1', 'c'));

    const adminEnv2 = { ...env2, ADMIN_TOKEN: ADMIN };
    const s = await json(await get('/admin/stats', adminEnv2, ADMIN));
    assert(s.body.users === 150, '150 账号时 stats.users 仍统计全量');
    assert(s.body.per_user.length === 100, 'per_user 最多 100 条');
    assert(s.body.per_user[0].user_id === 'u_x0' && s.body.per_user[0].envelopes === 2, 'per_user 首条为 envelope 最多的 u_x0');
    const u = await json(await get('/admin/users', adminEnv2, ADMIN));
    assert(u.body.users.length === 100, 'users 列表最多 100 条');
  }

  // --- 防陈旧覆盖 · 契约可区分化（skipped / accepted） ---
  {
    const env3 = makeEnv();
    const reg = await json(await post('/auth/register', { username: 'stale', password: 'stalewq7731' }, env3, ''));
    const token = reg.body.token;
    const mk = (id, v, title) => ({
      device_id: 'devS', entity_table: 'notes', entity_id: id,
      op: 'upsert', payload: { title }, base_version: v,
      updated_at: '2026-06-01T00:00:00.000Z', deleted_at: null,
    });

    // 单条陈旧：先把云端推到版本 3，再用落后声明推同一 key。
    await post('/sync/push', { device_id: 'devS', envelopes: [mk('n-stale', 2, 'new')] }, env3, token);
    const r = await json(await post('/sync/push', {
      device_id: 'devS', envelopes: [mk('n-stale', 1, 'OLD')],
    }, env3, token));
    assert(r.status === 200, '陈旧 push 仍返回 200');
    assert(r.body.received === 1 && r.body.accepted === 0, '陈旧 push received=1 / accepted=0');
    assert(Array.isArray(r.body.skipped) && JSON.stringify(r.body.skipped) === JSON.stringify(['notes:n-stale']), '陈旧 push skipped=["notes:n-stale"]');
    assert(r.body.versions['notes:n-stale'] === 3, '陈旧 push 回写服务端权威版本 3');
    const m = await json(await get('/sync/manifest', env3, token));
    assert(m.body.count === 1 && m.body.max_version === 3, '陈旧 push 不递增版本（保持 3）');
    const pull = await json(await post('/sync/pull', { device_id: 'devS', since: null }, env3, token));
    const s = pull.body.envelopes.find((e) => e.entity_id === 'n-stale');
    assert(s && s.payload.title === 'new', '云端较新内容 new 未被陈旧 push 覆盖');

    // 混合批次：1 条接受 + 1 条陈旧。
    await post('/sync/push', {
      device_id: 'devS',
      envelopes: [mk('mix-ok', 5, 'v5'), mk('mix-stale', 5, 'v5')],
    }, env3, token);
    const r2 = await json(await post('/sync/push', {
      device_id: 'devS',
      envelopes: [mk('mix-ok', 6, 'v6'), mk('mix-stale', 1, 'OLD')],
    }, env3, token));
    assert(r2.body.received === 2, '混合批次 received=2');
    assert(r2.body.accepted === 1, '混合批次 accepted=1（只计真实写入）');
    assert(Array.isArray(r2.body.skipped) && JSON.stringify(r2.body.skipped) === JSON.stringify(['notes:mix-stale']), '混合批次 skipped 只含 ["notes:mix-stale"]');
    assert(r2.body.versions['notes:mix-ok'] === 7 && r2.body.versions['notes:mix-stale'] === 6, '混合批次 versions：mix-ok=7 / mix-stale=6');
  }

  // --- 同批「先 accepted 后 stale」：versions 不得回退到 existing ---
  {
    const env4 = makeEnv();
    const reg = await json(await post('/auth/register', { username: 'regress', password: 'pzkdmv8260' }, env4, ''));
    const token = reg.body.token;
    const mk = (v, title) => ({
      device_id: 'devR', entity_table: 'notes', entity_id: 'n-regress',
      op: 'upsert', payload: { title }, base_version: v,
      updated_at: '2026-06-01T00:00:00.000Z', deleted_at: null,
    });
    // 先把云端权威版本推到 5。
    await post('/sync/push', { device_id: 'devR', envelopes: [mk(4, 'seed')] }, env4, token);
    // 同一批：第一条 bv=10 被接受（versions 抬到 11），第二条 bv=1 陈旧。
    const r = await json(await post('/sync/push', {
      device_id: 'devR', envelopes: [mk(10, 'new'), mk(1, 'OLD')],
    }, env4, token));
    assert(r.body.accepted === 1, '同批先接受后陈旧 accepted=1');
    assert(Array.isArray(r.body.skipped) && JSON.stringify(r.body.skipped) === JSON.stringify(['notes:n-regress']), '同批先接受后陈旧 skipped=["notes:n-regress"]');
    assert(r.body.versions['notes:n-regress'] === 11, 'versions 不回退：notes:n-regress=11（而非批前 5）');
    const m = await json(await get('/sync/manifest', env4, token));
    assert(m.body.max_version === 11, '云端实际版本保持 11');
  }

  // --- 带非空 since 的增量 pull：stale 行因旧 server_time 被游标过滤 ---
  {
    const env5 = makeEnv();
    const reg = await json(await post('/auth/register', { username: 'since', password: 'wqmdzt7148' }, env5, ''));
    const token = reg.body.token;
    const mk = (v, title) => ({
      device_id: 'devI', entity_table: 'notes', entity_id: 'n-inc',
      op: 'upsert', payload: { title }, base_version: v,
      updated_at: '2026-06-01T00:00:00.000Z', deleted_at: null,
    });
    // 首次 push 落库（server_time = now），再把该行的 server_time 改写成很久以前，
    // 模拟「云端这条记录是很早以前写的、本轮 stale push 没有刷新它」。
    await post('/sync/push', { device_id: 'devI', envelopes: [mk(5, 'cloud-new')] }, env5, token);
    for (const [k, row] of env5.DB.tables.sync_envelopes) {
      if (row.entity_id === 'n-inc') {
        env5.DB.tables.sync_envelopes.set(k, { ...row, server_time: '2020-01-01T00:00:00.000Z' });
      }
    }
    // 陈旧 push：跳过 INSERT，行的 server_time 仍是 2020。
    const s = await json(await post('/sync/push', {
      device_id: 'devI', envelopes: [mk(1, 'OLD')],
    }, env5, token));
    assert(s.body.accepted === 0 && JSON.stringify(s.body.skipped) === JSON.stringify(['notes:n-inc']), 'since 用例的陈旧 push accepted=0 / skipped 正确');
    // 非空 since 的增量 pull：旧 server_time 落在游标之外 → 该行不返回。
    const inc = await json(await post('/sync/pull', { device_id: 'devI', since: '2021-01-01T00:00:00.000Z' }, env5, token));
    assert(Array.isArray(inc.body.envelopes) && !inc.body.envelopes.some((e) => e.entity_id === 'n-inc'), '增量 pull（非空 since）stale 行不返回');
    // 全量 pull 仍能取到云端较新内容，证明行未被删除、只是游标外。
    const full = await json(await post('/sync/pull', { device_id: 'devI', since: null }, env5, token));
    const row = full.body.envelopes.find((e) => e.entity_id === 'n-inc');
    assert(row && row.payload.title === 'cloud-new', '全量 pull 仍返回云端较新内容 cloud-new');
    // App 收到 skipped 后 adopt 到云端权威版本 6，再以 base_version=6 重推：
    // 命中覆盖分支 → 写入新 payload + 新 server_time。相同 since 再 pull 应能取到。
    const re = await json(await post('/sync/push', {
      device_id: 'devI', envelopes: [mk(6, 'retry-new')],
    }, env5, token));
    assert(re.body.accepted === 1 && Array.isArray(re.body.skipped) && re.body.skipped.length === 0, '重推被接受（accepted=1 / skipped 空）');
    const inc2 = await json(await post('/sync/pull', { device_id: 'devI', since: '2021-01-01T00:00:00.000Z' }, env5, token));
    const row2 = inc2.body.envelopes.find((e) => e.entity_id === 'n-inc');
    assert(!!row2, '重推后相同 since 增量 pull 返回该行');
    assert(row2 && row2.payload.title === 'retry-new', '重推后 payload 是新内容 retry-new');
    // pull 响应不含 server_time（worker.js:203-213 rowToEnvelope），直接查 D1 行本身：
    // 证明重推确实写入了新时间戳，而不是沿用被改写成 2020 的旧值。
    let storedTime = null;
    for (const [, r] of env5.DB.tables.sync_envelopes) {
      if (r.entity_id === 'n-inc') storedTime = r.server_time;
    }
    assert(typeof storedTime === 'string' && storedTime > '2021-01-01T00:00:00.000Z', '重推后存储行 server_time 严格晚于 2021');
  }

  // --- 同批同键「先高后低」边界：authStart=6，[bv=6, bv=1] → versions 不回退到 6，应为 7 ---
  {
    const env6 = makeEnv();
    const reg = await json(await post('/auth/register', { username: 'edge', password: 'kdmzt7148' }, env6, ''));
    const token = reg.body.token;
    const mk = (v, title) => ({
      device_id: 'devE', entity_table: 'notes', entity_id: 'x',
      op: 'upsert', payload: { title }, base_version: v,
      updated_at: '2026-06-01T00:00:00.000Z', deleted_at: null,
    });
    // 先把云端权威版本推到 6。
    await post('/sync/push', { device_id: 'devE', envelopes: [mk(5, 'seed')] }, env6, token);
    const r = await json(await post('/sync/push', {
      device_id: 'devE', envelopes: [mk(6, 'high'), mk(1, 'LOW')],
    }, env6, token));
    assert(r.body.accepted === 1, 'authStart=6 边界 accepted=1');
    assert(Array.isArray(r.body.skipped) && JSON.stringify(r.body.skipped) === JSON.stringify(['notes:x']), 'authStart=6 边界 skipped=["notes:x"]');
    assert(r.body.versions['notes:x'] === 7, 'authStart=6 边界 versions["notes:x"]=7（不回退到 6）');
  }

  console.log(`\n结果：通过 ${passed}，失败 ${failed}`);
  if (failed > 0) process.exit(1);
}

run().catch((e) => {
  console.error('测试异常：', e);
  process.exit(1);
});

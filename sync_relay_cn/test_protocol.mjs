/**
 * sync_relay_cn 协议冒烟测试（不联网、不需要腾讯云账号）。
 *
 * 背景：数据层已从文档型数据库改写为 PostgreSQL（``db.js`` 走 ``app.rdb()``
 * 的 PostgREST 客户端）。为了不引真实 PG 驱动、不联网，本测试用
 * **node:sqlite 内存库 + PostgREST 翻译层** 替代真实客户端：
 * 翻译层把 ``from(table).select().eq().order().range()`` /
 * ``insert()`` / ``upsert(rows, {onConflict})`` 等调用翻成等价的 SQLite
 * SQL（含 ``ON CONFLICT (...) DO UPDATE SET ... = excluded.*``），由
 * SQLite 真执行——唯一索引、复合主键、分页边界都是引擎级验证，不是
 * 「手写 fake 按记忆演一遍」。
 *
 * SQLite 与 PG 的方言差异（``ON CONFLICT``/``excluded``/位置参数）两者
 * 一致，DDL 直接照搬 ``cloudbase/migrations/`` 的 PG 建表语句即可在
 * SQLite 上执行（见下方 SCHEMA_SQL 注释）。
 *
 * 断言口径照搬 ``sync_relay_cf/test_worker.mjs``，45 条一条不许少。
 *
 * 运行：node test_protocol.mjs     全绿退出码 0，有失败退出码 1。
 *
 * 覆盖：
 * - 根路径健康检查；
 * - 账号：register / login / 重名 409 / 弱密码 400 / 短用户名 400 / 错误密码 401 / 非法 JSON；
 * - 鉴权：/sync/* 未带令牌 401、错误令牌 401、小写 bearer 前缀可用、旧令牌仍有效；
 * - 数据通路：push → manifest → pull 全量、覆盖同 key、since 增量、多租户隔离；
 * - 分页：push 1200 条后 pull 必须取回全部（验证 pullSince 的 range 翻页逻辑）；
 * - entity_id 含 `. $ /` 时复合主键 upsert 仍然覆盖且原样返回。
 */

import relay from './index.js';
import { DatabaseSync } from 'node:sqlite';

const { handle, makeStore } = relay;

// node:sqlite 在 Node 22 仍是实验特性，屏蔽它的 ExperimentalWarning 噪音，
// 避免淹没测试输出（不影响逻辑与退出码；其余 warning 照常打印）。
const originalEmit = process.emit;
process.emit = function (event, ...args) {
  if (event === 'warning' && args[0] && args[0].name === 'ExperimentalWarning') return false;
  return originalEmit.call(this, event, ...args);
};

// ---------------- 内存版 PostgreSQL（node:sqlite + PostgREST 翻译层） ----------------

/**
 * 建表 DDL：与 cloudbase/migrations/20261024002320_init_sync_relay.sql
 * 保持一致的内联副本（测试不依赖仓库里未跟踪/可能变动的 migration 文件）。
 * PG 方言在这里与 SQLite 完全兼容：TEXT/INTEGER、复合 PRIMARY KEY、
 * CREATE [UNIQUE] INDEX IF NOT EXISTS、ON CONFLICT ... DO UPDATE、
 * excluded 伪表——两者语法一致，无需适配。
 */
const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS sync_envelopes (
    owner_id     TEXT NOT NULL,
    entity_table TEXT NOT NULL,
    entity_id    TEXT NOT NULL,
    device_id    TEXT NOT NULL,
    op           TEXT NOT NULL,
    payload_json TEXT,
    base_version INTEGER NOT NULL DEFAULT 0,
    updated_at   TEXT,
    deleted_at   TEXT,
    server_time  TEXT NOT NULL,
    PRIMARY KEY (owner_id, entity_table, entity_id)
);
CREATE INDEX IF NOT EXISTS idx_sync_env_owner_time
    ON sync_envelopes (owner_id, server_time);
CREATE TABLE IF NOT EXISTS sync_users (
    id         TEXT NOT NULL,
    username   TEXT NOT NULL,
    pw_hash    TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (id)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_users_username
    ON sync_users (username);
CREATE TABLE IF NOT EXISTS sync_tokens (
    token      TEXT NOT NULL,
    user_id    TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (token)
);
CREATE INDEX IF NOT EXISTS idx_sync_tokens_user
    ON sync_tokens (user_id);
`;

/** PostgREST 过滤运算符 → SQL 运算符。 */
const SQL_OPS = {
  eq: '=',
  neq: '!=',
  gt: '>',
  gte: '>=',
  lt: '<',
  lte: '<=',
  like: 'LIKE',
  ilike: 'LIKE',
};

/**
 * PostgREST 风格的查询构造器（thenable，可 await）。
 *
 * 链式收集 method / values / filters / orders / limit / range / single
 * 等，``then()`` 时一次性翻译成 SQL 交 SQLite 执行，返回与真实
 * PostgREST 一致的 ``{data, count, error}`` 形状。
 */
class QueryBuilder {
  constructor(db, table) {
    this.db = db;
    this.table = table;
    this.method = null;
    this.values = null;
    this.upsertOpts = {};
    this.cols = '*';
    this.head = false;
    this.count = null;
    this.filters = [];
    this.orders = [];
    this.limitCount = null;
    this.rangeFrom = null;
    this.rangeTo = null;
    this.singleMode = null; // 'single' | 'maybeSingle'
  }

  select(cols = '*', options = {}) {
    this.method = 'select';
    this.cols = cols;
    if (options.head) this.head = true;
    if (options.count) this.count = options.count;
    return this;
  }

  insert(values) {
    this.method = 'insert';
    this.values = values;
    return this;
  }

  upsert(values, options = {}) {
    this.method = 'upsert';
    this.values = values;
    this.upsertOpts = options;
    return this;
  }

  update(values) {
    this.method = 'update';
    this.values = values;
    return this;
  }

  delete() {
    this.method = 'delete';
    return this;
  }

  eq(column, value) {
    this.filters.push([column, 'eq', value]);
    return this;
  }

  neq(column, value) {
    this.filters.push([column, 'neq', value]);
    return this;
  }

  gt(column, value) {
    this.filters.push([column, 'gt', value]);
    return this;
  }

  gte(column, value) {
    this.filters.push([column, 'gte', value]);
    return this;
  }

  lt(column, value) {
    this.filters.push([column, 'lt', value]);
    return this;
  }

  lte(column, value) {
    this.filters.push([column, 'lte', value]);
    return this;
  }

  is(column, value) {
    this.filters.push([column, 'is', value]);
    return this;
  }

  in(column, values) {
    this.filters.push([column, 'in', values]);
    return this;
  }

  order(column, options = {}) {
    this.orders.push([column, options.ascending === false ? 'DESC' : 'ASC']);
    return this;
  }

  limit(n) {
    this.limitCount = n;
    return this;
  }

  range(from, to) {
    this.rangeFrom = from;
    this.rangeTo = to;
    return this;
  }

  single() {
    this.singleMode = 'single';
    return this;
  }

  maybeSingle() {
    this.singleMode = 'maybeSingle';
    return this;
  }

  /** 组装 WHERE 子句与位置参数（值由 SQLite 绑定，无注入面）。 */
  _where() {
    if (!this.filters.length) return { sql: '', params: [] };
    const parts = [];
    const params = [];
    for (const [column, op, value] of this.filters) {
      if (op === 'is') {
        parts.push(`${column} IS ?`);
        params.push(value);
      } else if (op === 'in') {
        const list = Array.isArray(value) ? value : [value];
        parts.push(`${column} IN (${list.map(() => '?').join(', ')})`);
        params.push(...list);
      } else if (SQL_OPS[op]) {
        parts.push(`${column} ${SQL_OPS[op]} ?`);
        params.push(value);
      } else {
        throw new Error(`mock 未实现的过滤器: ${op}`);
      }
    }
    return { sql: ` WHERE ${parts.join(' AND ')}`, params };
  }

  _orderLimit() {
    let sql = '';
    if (this.orders.length) {
      sql += ` ORDER BY ${this.orders.map(([c, d]) => `${c} ${d}`).join(', ')}`;
    }
    // PostgREST 语义：range 优先于 limit（range 是闭区间，0 基）。
    if (this.rangeFrom != null && this.rangeTo != null) {
      sql += ` LIMIT ${this.rangeTo - this.rangeFrom + 1} OFFSET ${this.rangeFrom}`;
    } else if (this.limitCount != null) {
      sql += ` LIMIT ${this.limitCount}`;
    }
    return sql;
  }

  /** 执行收集到的查询，返回 PostgREST 形状的响应。 */
  _execute() {
    try {
      return this._run();
    } catch (e) {
      // 真实 PostgREST 出错时返回 {data:null, error}，不 throw；
      // 唯一约束冲突等走这条路（db.js 统一检查 error 再抛可读错误）。
      return { data: null, count: null, error: { message: e && e.message ? e.message : String(e) } };
    }
  }

  _run() {
    if (this.method === 'select') {
      const where = this._where();
      if (this.head && this.count === 'exact') {
        const row = this.db
          .prepare(`SELECT COUNT(*) AS count FROM ${this.table}${where.sql}${this._orderLimit()}`)
          .get(...where.params);
        return { data: null, count: Number(row.count), error: null };
      }
      const rows = this.db
        .prepare(`SELECT ${this.cols} FROM ${this.table}${where.sql}${this._orderLimit()}`)
        .all(...where.params);
      return { data: this._applySingle(rows), count: null, error: null };
    }

    if (this.method === 'insert' || this.method === 'upsert') {
      const rows = Array.isArray(this.values) ? this.values : [this.values];
      const cols = Object.keys(rows[0]);
      const placeholders = rows.map(() => `(${cols.map(() => '?').join(', ')})`).join(', ');
      const params = rows.flatMap((r) => cols.map((c) => (r[c] === undefined ? null : r[c])));
      let sql = `INSERT INTO ${this.table} (${cols.join(', ')}) VALUES ${placeholders}`;
      if (this.method === 'upsert') {
        // 与 PG 的 INSERT ... ON CONFLICT (...) DO UPDATE 等价：
        // SQLite 与 PG 的 ON CONFLICT/excluded 语法一致。
        const conflictCols = String(this.upsertOpts.onConflict || '')
          .split(',')
          .map((s) => s.trim())
          .filter(Boolean);
        if (this.upsertOpts.ignoreDuplicates) {
          sql += ` ON CONFLICT (${conflictCols.join(', ')}) DO NOTHING`;
        } else {
          const setCols = cols.filter((c) => !conflictCols.includes(c));
          sql +=
            ` ON CONFLICT (${conflictCols.join(', ')}) DO UPDATE SET ` +
            setCols.map((c) => `${c} = excluded.${c}`).join(', ');
        }
      }
      this.db.prepare(sql).run(...params);
      return { data: null, count: null, error: null };
    }

    if (this.method === 'update') {
      const cols = Object.keys(this.values);
      const where = this._where();
      const sql =
        `UPDATE ${this.table} SET ${cols.map((c) => `${c} = ?`).join(', ')}` +
        `${where.sql}${this._orderLimit()}`;
      this.db.prepare(sql).run(...cols.map((c) => this.values[c]), ...where.params);
      return { data: null, count: null, error: null };
    }

    if (this.method === 'delete') {
      const where = this._where();
      this.db.prepare(`DELETE FROM ${this.table}${where.sql}`).run(...where.params);
      return { data: null, count: null, error: null };
    }

    throw new Error(`mock 未实现的方法: ${this.method}`);
  }

  /** single / maybeSingle：把行数组收敛成单对象（PostgREST 语义）。 */
  _applySingle(rows) {
    if (this.singleMode === 'maybeSingle') return rows.length ? rows[0] : null;
    if (this.singleMode === 'single') {
      if (rows.length !== 1) {
        throw new Error(`PGRST116: single() 期望 1 行，实际 ${rows.length} 行`);
      }
      return rows[0];
    }
    return rows;
  }

  then(onFulfilled, onRejected) {
    return Promise.resolve()
      .then(() => this._execute())
      .then(onFulfilled, onRejected);
  }
}

/** 等价于 app.rdb() 的最小 PostgREST 客户端（存储引擎是 node:sqlite 内存库）。 */
class SqlitePostgrest {
  constructor(db) {
    this.db = db;
  }

  from(table) {
    return new QueryBuilder(this.db, table);
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

/** 每个用例一套独立的内存库 + 建表，互不影响。 */
function makeEnv() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA_SQL);
  const store = makeStore(new SqlitePostgrest(db));
  store.__sqlite = db; // 白盒：测试直接查库校验哈希格式（见 findUserRow）
  return store;
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
  console.log('sync_relay_cn（CloudBase 版 · PostgreSQL）协议自测开始：');
  const store = makeEnv();
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
    const userRow = findUserRow(store, 'carol');
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

  // --- 14) 覆盖同 key（upsert / ON CONFLICT DO UPDATE）---
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
  // PG 本身没有文档库那种单次 100 条上限，但一次全量可能上千条，pullSince
  // 用 range 翻页把结果取干净；三级排序保证同 server_time 时分页不重不漏。
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

  // --- 23) entity_id 带点号/美元符/斜杠也能正确 upsert（复合主键，无需转义）---
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
    assert(pull.body.envelopes[0].payload.v === 2, '复合主键 upsert 仍然覆盖了最新态');
  }

  console.log(`\n结果：通过 ${passed}，失败 ${failed}`);
  if (failed > 0) process.exit(1);
}

/** 直接从内存库里取一行用户，用于校验哈希格式（测试专用白盒断言）。 */
function findUserRow(store, username) {
  // makeEnv() 把 sqlite 句柄挂在 store.__sqlite 上（见上方白盒注释）。
  const db = store.__sqlite;
  if (db) return db.prepare('SELECT pw_hash FROM sync_users WHERE username = ?').get(username);
  return null;
}

run().catch((e) => {
  console.error('测试异常：', e);
  process.exit(1);
});

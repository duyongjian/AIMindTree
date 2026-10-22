/**
 * 方案 B 中继逻辑自测（无需 wrangler / D1 真实实例）。
 *
 * 用一个最简内存版 D1 模拟 ``DB`` 绑定，直接驱动 ``worker.js`` 的
 * ``fetch`` handler，验证 push → pull → manifest 全链路与 App 契约一致：
 * - 字段名、envelope 结构；
 * - push 的 INSERT OR REPLACE（同 key 覆盖）；
 * - pull 的 since 增量过滤；
 * - manifest 计数；
 * - 空 token 放行 / 设 token 后需 Bearer。
 *
 * 运行：node test_worker.mjs   （须在含 package.json {"type":"module"} 的目录）
 */

import worker from './worker.js';

// ---------------- 最简内存 D1 模拟 ----------------

class MockD1 {
  constructor() {
    /** @type {Map<string, object>} key = `${table}|${id}` */
    this.rows = new Map();
  }

  _key(table, id) {
    return `${table}|${id}`;
  }

  prepare(sql) {
    const self = this;
    // 返回一条 statement：既可直接 .all()/.first()/.run()（对应 worker 里
    // prepare(...).first() 的写法），也可 .bind(...).all()（pull 用），且
    // bind() 返回「全新的」已绑定语句（D1 语义，避免 batch 共享 _params）。
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
    for (const stmt of statements) {
      await stmt.run();
    }
    return statements.map(() => ({ success: true }));
  }

  _select(sql, params) {
    if (sql.includes('COUNT(*) AS count')) {
      return [{ count: this.rows.size }];
    }
    let list = [...this.rows.values()];
    if (sql.includes('WHERE server_time >')) {
      const since = params[0];
      list = list.filter((r) => r.server_time > since);
    }
    list.sort((a, b) => (a.server_time < b.server_time ? -1 : a.server_time > b.server_time ? 1 : 0));
    return list;
  }

  _exec(sql, params) {
    if (sql.includes('INSERT OR REPLACE INTO sync_envelopes')) {
      const [table, id, device, op, payload, base, updated, deleted, server] = params;
      this.rows.set(this._key(table, id), {
        entity_table: table,
        entity_id: id,
        device_id: device,
        op,
        payload_json: payload,
        base_version: base,
        updated_at: updated,
        deleted_at: deleted,
        server_time: server,
      });
    }
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

function makeEnv(token = '') {
  return { DB: new MockD1(), SYNC_TOKEN: token };
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

// ---------------- 用例 ----------------

async function run() {
  console.log('方案 B 中继自测开始：');

  // 1) 空 token 放行
  {
    const env = makeEnv('');
    const r = await post('/sync/push', { device_id: 'd1', envelopes: [] }, env, '');
    assert(r.status === 200, '空 SYNC_TOKEN 时 push 放行 (200)');
  }

  // 2) 设 token 后无 token 拒绝
  {
    const env = makeEnv('secret-123');
    const r = await post('/sync/push', { device_id: 'd1', envelopes: [] }, env, '');
    assert(r.status === 401, '设 token 后缺 Bearer 返回 401');
    const r2 = await post('/sync/push', { device_id: 'd1', envelopes: [] }, env, 'secret-123');
    assert(r2.status === 200, '正确 Bearer 放行 (200)');
  }

  // 数据通路用例（3~7）共用同一个 relay 实例，模拟真实「上传后拉回」。
  const env = makeEnv('');

  // 3) push 接收计数
  {
    const envelopes = [
      mkEnv('notes', 'n1', 'd1', { title: 'A' }),
      mkEnv('notes', 'n2', 'd1', { title: 'B' }),
    ];
    const r = await post('/sync/push', { device_id: 'd1', envelopes }, env, '');
    const j = await r.json();
    assert(j.received === 2, 'push 返回 received=2');
    assert(typeof j.server_time === 'string', 'push 返回 server_time(ISO)');
  }

  // 4) manifest 计数
  {
    const r = await get('/sync/manifest', env, '');
    const j = await r.json();
    assert(j.count === 2, 'manifest 返回 count=2');
  }

  // 5) pull 全量
  {
    const r = await post('/sync/pull', { device_id: 'd1', since: null }, env, '');
    const j = await r.json();
    assert(j.envelopes.length === 2, 'pull 全量返回 2 条');
    const first = j.envelopes[0];
    assert(first.device_id === 'd1' && first.entity_table === 'notes', 'envelope 字段还原正确');
    assert(first.payload && first.payload.title === 'A', 'payload 反序列化正确');
  }

  // 6) INSERT OR REPLACE 覆盖同 key
  {
    const updated = [mkEnv('notes', 'n1', 'd1', { title: 'A-updated' })];
    await post('/sync/push', { device_id: 'd1', envelopes: updated }, env, '');
    const r = await get('/sync/manifest', env, '');
    const j = await r.json();
    assert(j.count === 2, '覆盖同 key 后 count 仍为 2（未新增）');
    const pull = await (await post('/sync/pull', { device_id: 'd1', since: null }, env, '')).json();
    const n1 = pull.envelopes.find((e) => e.entity_id === 'n1');
    assert(n1.payload.title === 'A-updated', '覆盖后拉取拿到新 payload');
  }

  // 7) pull since 增量过滤（确定性：用刚推的 n3 时间戳作游标，只看 n4）
  {
    // 先推 n3，记录其 server_time 作为增量起点；
    // 再推 n4（server_time 必然晚于 n3）。以 n3 的 server_time 为 since，
    // 过滤 server_time > since 应只命中 n4，与前面的 n1/n2/n3 无关。
    const p3 = await post('/sync/push', { device_id: 'd1', envelopes: [mkEnv('notes', 'n3', 'd1', { title: 'C' })] }, env, '');
    const t3 = (await p3.json()).server_time;
    // 确保 n4 的 server_time 严格晚于 n3（避免同毫秒导致 > 过滤误判）。
    await new Promise((r) => setTimeout(r, 10));
    await post('/sync/push', { device_id: 'd1', envelopes: [mkEnv('notes', 'n4', 'd1', { title: 'D' })] }, env, '');

    const pull = await (await post('/sync/pull', { device_id: 'd1', since: t3 }, env, '')).json();
    assert(pull.envelopes.length === 1, 'since 增量过滤只返回 1 条');
    assert(pull.envelopes[0] && pull.envelopes[0].entity_id === 'n4', '增量过滤命中的是 n4');
  }

  // 8) 未知路径 404
  {
    const env = makeEnv('');
    const r = await get('/sync/nope', env, '');
    assert(r.status === 404, '未知路径返回 404');
  }

  console.log(`\n结果：通过 ${passed}，失败 ${failed}`);
  if (failed > 0) process.exit(1);
}

run().catch((e) => {
  console.error('测试异常：', e);
  process.exit(1);
});

/**
 * AIMindTree 同步中继 · Netlify 版协议冒烟测试（零依赖，内存 store 直驱）。
 *
 * 与另四版（CF / CloudBase / Vercel / EdgeOne）契约逐字一致，本测试验证：
 * 根健康检查、注册/登录/重复注册/错误密码、Bearer 鉴权、push / pull（全量+增量）、
 * manifest、多租户隔离、请求体 413 守卫。
 *
 * 运行：``node test_protocol.mjs``（期望：通过 N，失败 0）。
 */

import { handleFetch, makeMemoryStore } from './relay.js';

let pass = 0;
let fail = 0;
function check(name, cond) {
  if (cond) {
    pass++;
  } else {
    fail++;
    console.error('  ✗ FAIL:', name);
  }
}

function req(method, path, body, headers = {}) {
  const init = { method, headers: { ...headers } };
  if (body !== undefined) {
    init.body = typeof body === 'string' ? body : JSON.stringify(body);
    if (!init.headers['Content-Type']) init.headers['Content-Type'] = 'application/json';
  }
  return new Request('https://relay.test' + path, init);
}

async function json(reqObj) {
  const r = await reqObj;
  const text = await r.text();
  let data = null;
  try { data = JSON.parse(text); } catch {}
  return { status: r.status, data };
}

async function main() {
  const store = makeMemoryStore();
  const h = (r) => handleFetch(r, store);

  // 1) 根健康检查
  {
    const { status, data } = await json(h(req('GET', '/')));
    check('root health 200', status === 200);
    check('root ok flag', data && data.ok === true);
    check('root service name', data && data.service === 'aimindtree-sync-relay');
    check('root runtime tag', data && data.runtime === 'netlify-functions-node');
  }

  // 2) 注册
  let tokenA = null;
  {
    const { status, data } = await json(h(req('POST', '/auth/register', { username: 'alice', password: 'password123' })));
    check('register 200', status === 200);
    check('register returns user_id', data && typeof data.user_id === 'string' && data.user_id.startsWith('u_'));
    check('register returns token', data && typeof data.token === 'string' && data.token.length === 64);
    tokenA = data && data.token;
  }

  // 3) 重复注册 → 409
  {
    const { status } = await json(h(req('POST', '/auth/register', { username: 'alice', password: 'password123' })));
    check('duplicate register 409', status === 409);
  }

  // 4) 注册校验：短用户名 / 短密码
  {
    const { status: s1 } = await json(h(req('POST', '/auth/register', { username: 'ab', password: 'password123' })));
    check('short username 400', s1 === 400);
    const { status: s2 } = await json(h(req('POST', '/auth/register', { username: 'bob', password: 'short' })));
    check('short password 400', s2 === 400);
  }

  // 5) 登录（alice）
  {
    const { status, data } = await json(h(req('POST', '/auth/login', { username: 'alice', password: 'password123' })));
    check('login 200', status === 200);
    check('login returns token', data && typeof data.token === 'string' && data.token.length === 64);
    // 登录发的 token 与注册时不同（每次签发新 token）
    check('login token differs from register', data && data.token !== tokenA);
  }

  // 5b) 注册并登录 bob（用于多租户隔离测试）
  let tokenB = null;
  {
    const r1 = await json(h(req('POST', '/auth/register', { username: 'bob', password: 'password456' })));
    check('bob register 200', r1.status === 200);
    const r2 = await json(h(req('POST', '/auth/login', { username: 'bob', password: 'password456' })));
    check('bob login 200', r2.status === 200);
    tokenB = r2.data && r2.data.token;
  }

  // 6) 错误密码 → 401
  {
    const { status } = await json(h(req('POST', '/auth/login', { username: 'alice', password: 'wrongpass' })));
    check('wrong password 401', status === 401);
  }

  // 7) 未授权访问 sync → 401
  {
    const { status: s1 } = await json(h(req('POST', '/sync/push', { device_id: 'd', envelopes: [] })));
    check('push without auth 401', s1 === 401);
    const { status: s2 } = await json(h(req('POST', '/sync/pull', { device_id: 'd', since: null })));
    check('pull without auth 401', s2 === 401);
    const { status: s3 } = await json(h(req('GET', '/sync/manifest')));
    check('manifest without auth 401', s3 === 401);
  }

  // 8) 用错误 token → 401
  {
    const { status } = await json(h(req('GET', '/sync/manifest', undefined, { Authorization: 'Bearer deadbeef' })));
    check('bad token 401', status === 401);
  }

  // 9) push（alice）
  const envA = { Authorization: 'Bearer ' + tokenA };
  let serverTime = null;
  {
    const envs = [
      { device_id: 'devA', entity_table: 'notes', entity_id: 'n1', op: 'upsert', payload: { title: 'A note' }, base_version: 0, updated_at: '2026-01-01T00:00:00Z', deleted_at: null },
      { device_id: 'devA', entity_table: 'notes', entity_id: 'n2', op: 'upsert', payload: { title: 'A note 2' }, base_version: 0, updated_at: '2026-01-02T00:00:00Z', deleted_at: null },
    ];
    const { status, data } = await json(h(req('POST', '/sync/push', { device_id: 'devA', envelopes: envs }, envA)));
    check('push 200', status === 200);
    check('push received=2', data && data.received === 2);
    check('push accepted=2', data && data.accepted === 2);
    check('push server_time present', data && typeof data.server_time === 'string');
    serverTime = data && data.server_time;
  }

  // 10) manifest（alice）= 2
  {
    const { status, data } = await json(h(req('GET', '/sync/manifest', undefined, envA)));
    check('manifest 200', status === 200);
    check('manifest count=2', data && data.count === 2);
  }

  // 11) pull 全量（alice）
  {
    const { status, data } = await json(h(req('POST', '/sync/pull', { device_id: 'devA', since: null }, envA)));
    check('pull 200', status === 200);
    check('pull returns 2 envelopes', data && data.envelopes.length === 2);
    // 按 server_time 升序
    const titles = data.envelopes.map((e) => e.payload && e.payload.title).sort();
    check('pull payload intact', titles[0] === 'A note' && titles[1] === 'A note 2');
    // entity_id 原样回传
    check('pull entity_id intact', data.envelopes.every((e) => e.entity_id === 'n1' || e.entity_id === 'n2'));
  }

  // 12) pull 增量（alice, lookback=0 严格语义）：since=serverTime 应拿空
  {
    const { status, data } = await json(
      handleFetch(req('POST', '/sync/pull', { device_id: 'devA', since: serverTime }, envA), store, { SYNC_PULL_LOOKBACK_MS: '0' }),
    );
    check('incremental pull strict (since=now) empty', status === 200 && data.envelopes.length === 0);
  }

  // 12b) 默认 lookback（1s）行为（2026-10-24 用户实测回归：push 后 30s 内的
  // pull 曾把整个快照重投，表现为「只有快照没有增量」；窗口收紧到 1s 后）：
  //   窗口内 since=刚拿到的 server_time 仍重复返回（App 端自回声 + LWW 幂等）；
  //   窗口（>1s）过后同参数 pull 必须只返回新 envelope（严格增量）。
  {
    const { data: w } = await json(h(req('POST', '/sync/pull', { device_id: 'devA', since: serverTime }, envA)));
    check('default lookback: within-window re-returns idempotently', w && w.envelopes.length === 2);
    const { data: p2 } = await json(h(req('POST', '/sync/push', { device_id: 'devA', envelopes: [{ device_id: 'devA', entity_table: 'notes', entity_id: 'n3', op: 'upsert', payload: { title: 'A note 3' }, base_version: 0, updated_at: '2026-01-03T00:00:00Z', deleted_at: null }] }, envA)));
    const t2 = p2 && p2.server_time;
    await new Promise((r) => setTimeout(r, 1200)); // 等 1s 回退窗口过去
    const { data: inc } = await json(h(req('POST', '/sync/pull', { device_id: 'devA', since: serverTime }, envA)));
    check('default lookback: after-window pull returns only new envelope', inc && inc.envelopes.length === 1 && inc.envelopes[0].entity_id === 'n3');
    const { data: inc2 } = await json(
      handleFetch(req('POST', '/sync/pull', { device_id: 'devA', since: t2 }, envA), store, { SYNC_PULL_LOOKBACK_MS: '0' }),
    );
    check('strict pull after new push empty', inc2 && inc2.envelopes.length === 0);
  }

  // 13) 多租户隔离：bob 看不到 alice 的数据
  {
    const envB = { Authorization: 'Bearer ' + tokenB };
    const { status, data } = await json(h(req('POST', '/sync/pull', { device_id: 'devB', since: null }, envB)));
    check('bob pull 200', status === 200);
    check('bob sees 0 envelopes (isolation)', data && data.envelopes.length === 0);
    const { data: m } = await json(h(req('GET', '/sync/manifest', undefined, envB)));
    check('bob manifest count=0', m && m.count === 0);
  }

  // 14) bob 也能正常 push 自己的数据
  {
    const envB = { Authorization: 'Bearer ' + tokenB };
    const envs = [{ device_id: 'devB', entity_table: 'notes', entity_id: 'b1', op: 'upsert', payload: { title: 'B note' }, base_version: 0, updated_at: '2026-02-01T00:00:00Z', deleted_at: null }];
    const { status, data } = await json(h(req('POST', '/sync/push', { device_id: 'devB', envelopes: envs }, envB)));
    check('bob push 200', status === 200 && data.received === 1);
    const { data: p } = await json(h(req('POST', '/sync/pull', { device_id: 'devB', since: null }, envB)));
    check('bob pull sees only own', p.envelopes.length === 1 && p.envelopes[0].entity_id === 'b1');
  }

  // 15) 请求体 413 守卫（真实超 4MB 的 body）
  {
    const huge = 'x'.repeat(4 * 1024 * 1024 + 1024); // > 4MB
    const { status } = await json(h(req('POST', '/sync/push', huge, envA)));
    check('oversized body 413', status === 413);
  }

  // 16) 未知路径 → 404
  {
    const { status } = await json(h(req('GET', '/nope')));
    check('unknown path 404', status === 404);
  }

  // 17) OPTIONS 预检 → 204
  {
    const r = await h(req('OPTIONS', '/sync/push'));
    check('OPTIONS 204', r.status === 204);
  }

  console.log(`\nNetlify 中继协议测试：通过 ${pass}，失败 ${fail}`);
  if (fail > 0) process.exit(1);
}

main().catch((e) => {
  console.error('测试运行异常：', e);
  process.exit(1);
});

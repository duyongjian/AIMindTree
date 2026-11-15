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
    // 服务端权威版本：响应必须带 versions 对象，且非空（本次推了 2 个实体）。
    check('push versions is object', data && typeof data.versions === 'object' && data.versions !== null);
    check('push versions non-empty', data && Object.keys(data.versions).length === 2);
    check('push versions = max(既有, 声明)+1 (=1 since base_version=0)', data && data.versions['notes:n1'] === 1 && data.versions['notes:n2'] === 1);
    serverTime = data && data.server_time;
  }

  // 10) manifest（alice）= 2，且带 max_version
  {
    const { status, data } = await json(h(req('GET', '/sync/manifest', undefined, envA)));
    check('manifest 200', status === 200);
    check('manifest count=2', data && data.count === 2);
    // 两条都是 base_version=0 的首次上传 → 服务端版本 = max(0,0)+1 = 1。
    check('manifest max_version=1', data && data.max_version === 1);
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
    check('bob manifest max_version=0（空命名空间不返回 null）', m && m.max_version === 0);
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

  // 17a) CORS 预检：Allow-Methods 含 DELETE，且 admin 与用户侧共用同一个头
  {
    const r1 = await h(req('OPTIONS', '/admin/user/u_abc'));
    const m1 = r1.headers.get('access-control-allow-methods') || '';
    check('OPTIONS /admin/user/{id} 204', r1.status === 204);
    check('admin 预检 Allow-Methods 含 DELETE', m1.includes('DELETE'));
    // 浏览器预检不带 Authorization，且此时 env 无 ADMIN_TOKEN：必须仍放行、不能 404
    check('未配 ADMIN_TOKEN 时 admin 预检仍放行', r1.headers.get('access-control-allow-origin') === '*');

    const r2 = await h(req('OPTIONS', '/sync/push'));
    const m2 = r2.headers.get('access-control-allow-methods') || '';
    check('用户侧与 admin 侧 Allow-Methods 完全一致', m2 === m1 && m2.includes('DELETE'));
  }

  // ---------------- 管理接口 /admin/* ----------------
  // 与 CF 版契约逐字一致（同一组断言在 sync_relay_cf/test_worker.mjs 里也有一份）。
  const ADMIN = 'adm_secret_123';
  const envAdmin = { ADMIN_TOKEN: ADMIN };
  const ha = (r) => handleFetch(r, store, envAdmin);

  // 18) 未配置 ADMIN_TOKEN → 全部 404（端点不可见）
  {
    const { status, data } = await json(h(req('GET', '/admin/ping', undefined, { Authorization: 'Bearer whatever' })));
    check('no ADMIN_TOKEN: ping 404', status === 404 && data && data.error === 'not_found');
    const { status: s2 } = await json(h(req('POST', '/admin/reset', { scope: 'all', confirm: 'RESET' }, { Authorization: 'Bearer whatever' })));
    check('no ADMIN_TOKEN: reset 404', s2 === 404);
    const { status: s3 } = await json(handleFetch(req('GET', '/admin/ping'), store, { ADMIN_TOKEN: '   ' }));
    check('blank ADMIN_TOKEN: 404', s3 === 404);
  }

  // 19) 令牌不符 → 401 + WWW-Authenticate
  {
    const raw = await ha(req('GET', '/admin/ping', undefined, { Authorization: 'Bearer wrong' }));
    check('bad admin token 401', raw.status === 401);
    check('401 has WWW-Authenticate', raw.headers.get('www-authenticate') === 'Bearer');
    const body = await raw.clone().json();
    check('401 body unauthorized', body && body.error === 'unauthorized');
    const { status } = await json(await ha(req('GET', '/admin/ping')));
    check('missing admin token 401', status === 401);
  }

  // 20) ping
  {
    const { status, data } = await json(await ha(req('GET', '/admin/ping', undefined, { Authorization: 'Bearer ' + ADMIN })));
    check('admin ping 200', status === 200 && data.ok === true);
    check('admin ping storage', data && data.storage === 'netlify-blobs');
    check('admin ping server_time ISO', typeof data.server_time === 'string' && data.server_time.endsWith('Z'));
  }

  // 21) stats：2 用户 / 4 令牌 / 4 envelopes（alice 3 + bob 1）
  const adminAuth = { Authorization: 'Bearer ' + ADMIN };
  let aliceId = null;
  let bobId = null;
  {
    const { status, data } = await json(await ha(req('GET', '/admin/stats', undefined, adminAuth)));
    check('stats 200', status === 200);
    check('stats users=2', data && data.users === 2);
    check('stats tokens=4', data && data.tokens === 4);
    check('stats envelopes=4', data && data.envelopes === 4);
    check('stats per_user 2 条', data && data.per_user.length === 2);
    const top = data.per_user[0];
    check('per_user 降序 alice 3 条', top && top.username === 'alice' && top.envelopes === 3);
    check('per_user alice tokens=2', top && top.tokens === 2);
    check('per_user last_server_time ISO', typeof top.last_server_time === 'string' && top.last_server_time.endsWith('Z'));
    check('per_user bob 1 条', data.per_user[1].username === 'bob' && data.per_user[1].envelopes === 1);
    aliceId = top.user_id;
    bobId = data.per_user[1].user_id;
  }

  // 22) users 列表
  {
    const { status, data } = await json(await ha(req('GET', '/admin/users', undefined, adminAuth)));
    check('users 200 / 2 条', status === 200 && data.users.length === 2);
    const a = data.users[0];
    check('users 首条 alice', a.user_id === aliceId && a.username === 'alice');
    check('users 带 created_at', typeof a.created_at === 'string' && a.created_at.length > 0);
    check('users alice 用量', a.tokens === 2 && a.envelopes === 3);
  }

  // 23) export 全量
  {
    const { status, data } = await json(await ha(req('GET', '/admin/export', undefined, adminAuth)));
    check('export 200 user_id=null', status === 200 && data.user_id === null);
    check('export truncated=false', data && data.truncated === false && typeof data.exported_at === 'string');
    check('export 4 envelopes', data && data.envelopes.length === 4);
    check('export 2 users', data && data.users.length === 2);
    const keys = Object.keys(data.envelopes[0]).sort().join(',');
    check(
      'export envelope 形状',
      keys === 'base_version,deleted_at,device_id,entity_id,entity_table,op,payload,updated_at',
    );
    check('export payload 反序列化', data.envelopes[0].payload && typeof data.envelopes[0].payload === 'object');
  }

  // 24) export?user_id= 过滤
  {
    const { status, data } = await json(await ha(req('GET', `/admin/export?user_id=${bobId}`, undefined, adminAuth)));
    check('export 回显 user_id', status === 200 && data.user_id === bobId);
    check('export 仅该用户 envelope', data.envelopes.length === 1 && data.envelopes[0].entity_id === 'b1');
    check('export users 按 user_id 过滤', data.users.length === 1 && data.users[0].user_id === bobId);
  }

  // 25) reset 参数校验（三种 400，且不误删数据）
  {
    const { status: s1, data: d1 } = await json(await ha(req('POST', '/admin/reset', { scope: 'all' }, adminAuth)));
    check('reset 缺 confirm → confirm_required', s1 === 400 && d1.error === 'confirm_required');
    const { status: s2 } = await json(await ha(req('POST', '/admin/reset', { scope: 'all', confirm: 'reset' }, adminAuth)));
    check('confirm 非大写 → 400', s2 === 400);
    const { status: s3, data: d3 } = await json(await ha(req('POST', '/admin/reset', { scope: 'user', confirm: 'RESET' }, adminAuth)));
    check('scope=user 缺 user_id → user_id_required', s3 === 400 && d3.error === 'user_id_required');
    const { status: s4, data: d4 } = await json(await ha(req('POST', '/admin/reset', { scope: 'bogus', confirm: 'RESET' }, adminAuth)));
    check('未知 scope → invalid_scope', s4 === 400 && d4.error === 'invalid_scope');
    const { data: s } = await json(await ha(req('GET', '/admin/stats', undefined, adminAuth)));
    check('校验失败不删数据', s.envelopes === 4 && s.users === 2);
  }

  // 26) reset scope=user（bob）→ 计数 + 幂等
  {
    const { status, data } = await json(
      await ha(req('POST', '/admin/reset', { scope: 'user', user_id: bobId, confirm: 'RESET' }, adminAuth)),
    );
    check(
      'reset user：1 envelope / 2 token / 1 user',
      status === 200 && data.scope === 'user' && data.deleted.envelopes === 1 && data.deleted.tokens === 2 && data.deleted.users === 1,
    );
    const { data: again } = await json(
      await ha(req('POST', '/admin/reset', { scope: 'user', user_id: bobId, confirm: 'RESET' }, adminAuth)),
    );
    check('reset user 幂等 → 全 0', again.deleted.envelopes === 0 && again.deleted.tokens === 0 && again.deleted.users === 0);
    const { data: s } = await json(await ha(req('GET', '/admin/stats', undefined, adminAuth)));
    check('reset user 后 stats 1/2/3', s.users === 1 && s.tokens === 2 && s.envelopes === 3);
  }

  // 27) DELETE /admin/user/{id}：已删除的 bob → 404
  {
    const { status, data } = await json(await ha(req('DELETE', `/admin/user/${bobId}`, undefined, adminAuth)));
    check('DELETE 不存在用户 → 404', status === 404 && data.error === 'user_not_found');
  }

  // 28) reset scope=envelopes
  {
    const { data } = await json(await ha(req('POST', '/admin/reset', { scope: 'envelopes', confirm: 'RESET' }, adminAuth)));
    check('reset envelopes 删 3 条，token/users 记 0', data.deleted.envelopes === 3 && data.deleted.tokens === 0 && data.deleted.users === 0);
    const { data: again } = await json(await ha(req('POST', '/admin/reset', { scope: 'envelopes', confirm: 'RESET' }, adminAuth)));
    check('reset envelopes 幂等 → 0', again.deleted.envelopes === 0);
    const { data: s } = await json(await ha(req('GET', '/admin/stats', undefined, adminAuth)));
    check('reset envelopes 后仅 envelope 归零', s.envelopes === 0 && s.users === 1 && s.tokens === 2);
    check('无数据时 per_user 0 / null', s.per_user[0].envelopes === 0 && s.per_user[0].last_server_time === null);
  }

  // 29) reset scope=all
  {
    const { data } = await json(await ha(req('POST', '/admin/reset', { scope: 'all', confirm: 'RESET' }, adminAuth)));
    check('reset all：2 token / 1 user', data.scope === 'all' && data.deleted.envelopes === 0 && data.deleted.tokens === 2 && data.deleted.users === 1);
    const { data: again } = await json(await ha(req('POST', '/admin/reset', { scope: 'all', confirm: 'RESET' }, adminAuth)));
    check('reset all 幂等 → 全 0', again.deleted.envelopes === 0 && again.deleted.tokens === 0 && again.deleted.users === 0);
    const { data: s } = await json(await ha(req('GET', '/admin/stats', undefined, adminAuth)));
    check('reset all 后全 0', s.users === 0 && s.tokens === 0 && s.envelopes === 0);
    const { status } = await json(h(req('GET', '/sync/manifest', undefined, envA)));
    check('reset all 后旧令牌失效 401', status === 401);
  }

  // 30) export 截断：>10000 条 → truncated=true 且只回 10000
  {
    const { data: reg } = await json(h(req('POST', '/auth/register', { username: 'carl', password: 'password789' })));
    const envC = { Authorization: 'Bearer ' + reg.token };
    const bulk = [];
    for (let i = 0; i < 10001; i++) {
      bulk.push({ device_id: 'd9', entity_table: 'notes', entity_id: 'bulk' + i, op: 'upsert', payload: { i }, base_version: 1, updated_at: '2026-01-01T00:00:00Z', deleted_at: null });
    }
    const { status: ps } = await json(h(req('POST', '/sync/push', { device_id: 'd9', envelopes: bulk }, envC)));
    check('bulk push 10001 条成功', ps === 200);
    const { data } = await json(await ha(req('GET', `/admin/export?user_id=${reg.user_id}`, undefined, adminAuth)));
    check('export 截断 truncated=true / 10000 条', data.truncated === true && data.envelopes.length === 10000);
  }

  // 31) per_user / users 上限 100（另起干净 store 直接造 150 个账号）
  {
    const store2 = makeMemoryStore();
    // 键编码与 relay.js 的 [hexEncode] 一致：每 UTF-16 码元 → 4 位 hex。
    const hexOf = (s) => {
      let out = '';
      for (let i = 0; i < s.length; i++) out += s.charCodeAt(i).toString(16).padStart(4, '0');
      return out;
    };
    for (let i = 0; i < 150; i++) {
      const id = 'u_x' + i;
      await store2.set('u_' + hexOf('user' + i), JSON.stringify({ id, username: 'user' + i, pw_hash: 'salt:hash', created_at: '2026-01-01T00:00:00.000Z' }));
    }
    const putEnv = (owner, entity) =>
      store2.set('e_' + hexOf(owner) + '_' + hexOf('notes') + '_' + hexOf(entity), JSON.stringify({
        device_id: 'd', entity_table: 'notes', entity_id: entity, op: 'upsert',
        payload: '{}', base_version: 1, updated_at: '2026-01-01T00:00:00.000Z',
        deleted_at: null, server_time: '2026-01-01T00:00:00.000Z',
      }));
    await putEnv('u_x0', 'a');
    await putEnv('u_x0', 'b');
    await putEnv('u_x1', 'c');

    const h2 = (r) => handleFetch(r, store2, envAdmin);
    const { data: s } = await json(await h2(req('GET', '/admin/stats', undefined, adminAuth)));
    check('150 账号 stats.users 全量', s.users === 150);
    check('per_user 最多 100 条', s.per_user.length === 100);
    check('per_user 首条 envelope 最多', s.per_user[0].user_id === 'u_x0' && s.per_user[0].envelopes === 2);
    const { data: u } = await json(await h2(req('GET', '/admin/users', undefined, adminAuth)));
    check('users 列表最多 100 条', u.users.length === 100);
  }

  // 32) manifest 的 max_version 随覆盖递增（另起干净 store，不污染上面的统计）
  {
    const store3 = makeMemoryStore();
    const h3 = (r) => handleFetch(r, store3, {});
    const { data: reg } = await json(h3(req('POST', '/auth/register', { username: 'ver', password: 'mnbvcxz12345' })));
    const envV = { Authorization: 'Bearer ' + reg.token };
    const env = (id, v) => ({ device_id: 'dV', entity_table: 'notes', entity_id: id, op: 'upsert', payload: { v }, base_version: v, updated_at: '2026-01-01T00:00:00Z', deleted_at: null });

    await json(h3(req('POST', '/sync/push', { device_id: 'dV', envelopes: [env('k1', 5)] }, envV)));
    let m = (await json(h3(req('GET', '/sync/manifest', undefined, envV)))).data;
    check('首次 push（base_version=5）→ max_version=6', m.count === 1 && m.max_version === 6);

    // 覆盖同 key：客户端基于既有版本 6 重新上传（声明 base_version=6）→ 7。
    await json(h3(req('POST', '/sync/push', { device_id: 'dV', envelopes: [env('k1', 6)] }, envV)));
    m = (await json(h3(req('GET', '/sync/manifest', undefined, envV)))).data;
    check('覆盖同 key 后 count 仍 1 / max_version=7', m.count === 1 && m.max_version === 7);
  }

  // 33) 防陈旧覆盖：声明版本落后时不覆盖云端较新内容、不递增版本（与 EO 23a 对称）
  {
    const store4 = makeMemoryStore();
    const h4 = (r) => handleFetch(r, store4, {});
    const { data: reg } = await json(h4(req('POST', '/auth/register', { username: 'stl', password: 'stalewq7731' })));
    const envS = { Authorization: 'Bearer ' + reg.token };
    // devA 先推 n-stale（声明 base_version=2 → 服务端 3，内容 new）。
    await json(h4(req('POST', '/sync/push', {
      device_id: 'devA',
      envelopes: [{ device_id: 'devA', entity_table: 'notes', entity_id: 'n-stale', op: 'upsert', payload: { title: 'new' }, base_version: 2, updated_at: '2026-06-01T00:00:00Z', deleted_at: null }],
    }, envS)));
    // devB 用落后的 base_version=1 推同一 key（过期本地副本，内容 OLD）。
    const r = await json(h4(req('POST', '/sync/push', {
      device_id: 'devB',
      envelopes: [{ device_id: 'devB', entity_table: 'notes', entity_id: 'n-stale', op: 'upsert', payload: { title: 'OLD' }, base_version: 1, updated_at: '2024-01-01T00:00:00Z', deleted_at: null }],
    }, envS)));
    check('陈旧 push 回写服务端权威版本 3', r.data.versions && r.data.versions['notes:n-stale'] === 3);
    check('陈旧 push 仍返回 200', r.status === 200);
    check('陈旧 push received=1 / accepted=0', r.data.received === 1 && r.data.accepted === 0);
    check('陈旧 push skipped=["notes:n-stale"]', Array.isArray(r.data.skipped) && JSON.stringify(r.data.skipped) === JSON.stringify(['notes:n-stale']));
    const m2 = (await json(h4(req('GET', '/sync/manifest', undefined, envS)))).data;
    check('陈旧 push 不递增版本（保持 3）', m2.count === 1 && m2.max_version === 3);
    const pull = (await json(h4(req('POST', '/sync/pull', { device_id: 'devB', since: null }, envS)))).data;
    const s = pull.envelopes.find((e) => e.entity_id === 'n-stale');
    check('云端较新内容 new 未被陈旧 push 覆盖', s && s.payload.title === 'new');
  }

  // 34) 混合批次：1 条接受 + 1 条陈旧，accepted 只计真实写入、skipped 只列被跳过那条
  {
    const store5 = makeMemoryStore();
    const h5 = (r) => handleFetch(r, store5, {});
    const { data: reg } = await json(h5(req('POST', '/auth/register', { username: 'mix', password: 'hqkdwzt8391' })));
    const envM = { Authorization: 'Bearer ' + reg.token };
    const mk = (id, v, title) => ({ device_id: 'devM', entity_table: 'notes', entity_id: id, op: 'upsert', payload: { title }, base_version: v, updated_at: '2026-06-01T00:00:00Z', deleted_at: null });

    // 先把两个 key 都推到云端权威版本 6。
    await json(h5(req('POST', '/sync/push', {
      device_id: 'devM',
      envelopes: [mk('mix-ok', 5, 'v5'), mk('mix-stale', 5, 'v5')],
    }, envM)));
    // 混合批次：mix-ok 声明 6（>= authStart 6，接受）；mix-stale 声明 1（< 6，陈旧）。
    const r = await json(h5(req('POST', '/sync/push', {
      device_id: 'devM',
      envelopes: [mk('mix-ok', 6, 'v6'), mk('mix-stale', 1, 'OLD')],
    }, envM)));
    check('混合批次 received=2', r.data && r.data.received === 2);
    check('混合批次 accepted=1（只计真实写入）', r.data && r.data.accepted === 1);
    check('混合批次 skipped 只含 ["notes:mix-stale"]', r.data && Array.isArray(r.data.skipped) && JSON.stringify(r.data.skipped) === JSON.stringify(['notes:mix-stale']));
    check('混合批次 versions：mix-ok=7 / mix-stale=6', r.data && r.data.versions['notes:mix-ok'] === 7 && r.data.versions['notes:mix-stale'] === 6);
  }

  // 35) 同批「先 accepted 后 stale」：versions 不得回退到批前 authStart
  {
    const store6 = makeMemoryStore();
    const h6 = (r) => handleFetch(r, store6, {});
    const { data: reg } = await json(h6(req('POST', '/auth/register', { username: 'regress', password: 'pzkdmv8260' })));
    const envR = { Authorization: 'Bearer ' + reg.token };
    const mk = (v, title) => ({ device_id: 'devR', entity_table: 'notes', entity_id: 'n-regress', op: 'upsert', payload: { title }, base_version: v, updated_at: '2026-06-01T00:00:00Z', deleted_at: null });

    // 先把云端权威版本推到 5。
    await json(h6(req('POST', '/sync/push', { device_id: 'devR', envelopes: [mk(4, 'seed')] }, envR)));
    // 同一批：第一条 bv=10 被接受（versions 抬到 11），第二条 bv=1 陈旧。
    const r = await json(h6(req('POST', '/sync/push', {
      device_id: 'devR', envelopes: [mk(10, 'new'), mk(1, 'OLD')],
    }, envR)));
    check('同批先接受后陈旧 accepted=1', r.data && r.data.accepted === 1);
    check('同批先接受后陈旧 skipped=["notes:n-regress"]', r.data && Array.isArray(r.data.skipped) && JSON.stringify(r.data.skipped) === JSON.stringify(['notes:n-regress']));
    check('versions 不回退：notes:n-regress=11（而非批前 5）', r.data && r.data.versions['notes:n-regress'] === 11);
    const m = (await json(h6(req('GET', '/sync/manifest', undefined, envR)))).data;
    check('云端实际版本保持 11', m.max_version === 11);
  }

  // 36) 带非空 since 的增量 pull：stale 行因旧 server_time 被游标过滤（重推前不返回）
  {
    const store7 = makeMemoryStore();
    const h7 = (r) => handleFetch(r, store7, {});
    const { data: reg } = await json(h7(req('POST', '/auth/register', { username: 'since', password: 'wqmdzt7148' })));
    const envI = { Authorization: 'Bearer ' + reg.token };
    const mk = (v, title) => ({ device_id: 'devI', entity_table: 'notes', entity_id: 'n-inc', op: 'upsert', payload: { title }, base_version: v, updated_at: '2026-06-01T00:00:00Z', deleted_at: null });

    // 首次 push 落库（server_time = now），再把该 blob 的 server_time 改写成很久以前，
    // 模拟「云端这条记录是很早以前写的、本轮 stale push 没有刷新它」。
    await json(h7(req('POST', '/sync/push', { device_id: 'devI', envelopes: [mk(5, 'cloud-new')] }, envI)));
    for (const [k, raw] of store7._dump()) {
      try {
        const rec = JSON.parse(raw);
        if (rec && rec.entity_id === 'n-inc') {
          rec.server_time = '2020-01-01T00:00:00.000Z';
          await store7.set(k, JSON.stringify(rec));
        }
      } catch {}
    }
    // 陈旧 push：跳过写入，blob 的 server_time 仍是 2020。
    const s = await json(h7(req('POST', '/sync/push', { device_id: 'devI', envelopes: [mk(1, 'OLD')] }, envI)));
    check('since 用例的陈旧 push accepted=0 / skipped 正确', s.data && s.data.accepted === 0 && JSON.stringify(s.data.skipped) === JSON.stringify(['notes:n-inc']));
    // 非空 since 的增量 pull：旧 server_time 落在游标之外 → 该行不返回。
    const inc = (await json(h7(req('POST', '/sync/pull', { device_id: 'devI', since: '2021-01-01T00:00:00.000Z' }, envI)))).data;
    check('增量 pull（非空 since）stale 行不返回', Array.isArray(inc.envelopes) && !inc.envelopes.some((e) => e.entity_id === 'n-inc'));
    // 全量 pull 仍能取到云端较新内容，证明 blob 未被删除、只是游标外。
    const full = (await json(h7(req('POST', '/sync/pull', { device_id: 'devI', since: null }, envI)))).data;
    const row = full.envelopes.find((e) => e.entity_id === 'n-inc');
    check('全量 pull 仍返回云端较新内容 cloud-new', row && row.payload.title === 'cloud-new');
    // App 收到 skipped 后 adopt 到云端权威版本 6，再以 base_version=6 重推：
    // 命中覆盖分支 → 写入新 payload + 新 server_time。相同 since 再 pull 应能取到。
    const re = await json(h7(req('POST', '/sync/push', {
      device_id: 'devI', envelopes: [mk(6, 'retry-new')],
    }, envI)));
    check('重推被接受（accepted=1 / skipped 空）', re.data && re.data.accepted === 1 && Array.isArray(re.data.skipped) && re.data.skipped.length === 0);
    const inc2 = (await json(h7(req('POST', '/sync/pull', { device_id: 'devI', since: '2021-01-01T00:00:00.000Z' }, envI)))).data;
    const row2 = inc2.envelopes.find((e) => e.entity_id === 'n-inc');
    check('重推后相同 since 增量 pull 返回该行', !!row2);
    check('重推后 payload 是新内容 retry-new', row2 && row2.payload.title === 'retry-new');
    // pull 响应不含 server_time（relay.js:459-468），直接查存储记录本身：
    // 证明重推确实写入了新时间戳，而不是沿用被改写成 2020 的旧值。
    let storedTime = null;
    for (const [, raw] of store7._dump()) {
      try { const rec = JSON.parse(raw); if (rec && rec.entity_id === 'n-inc') storedTime = rec.server_time; } catch {}
    }
    check('重推后存储记录 server_time 严格晚于 2021', typeof storedTime === 'string' && storedTime > '2021-01-01T00:00:00.000Z');
  }

  // 37) 同批同键「先高后低」边界：authStart=6，[bv=6, bv=1] → versions 不回退到 6，应为 7
  {
    const store8 = makeMemoryStore();
    const h8 = (r) => handleFetch(r, store8, {});
    const { data: reg } = await json(h8(req('POST', '/auth/register', { username: 'edge', password: 'kdmzt7148' })));
    const envE = { Authorization: 'Bearer ' + reg.token };
    const mk = (v, title) => ({ device_id: 'devE', entity_table: 'notes', entity_id: 'x', op: 'upsert', payload: { title }, base_version: v, updated_at: '2026-06-01T00:00:00Z', deleted_at: null });

    // 先把云端权威版本推到 6。
    await json(h8(req('POST', '/sync/push', { device_id: 'devE', envelopes: [mk(5, 'seed')] }, envE)));
    const r = await json(h8(req('POST', '/sync/push', {
      device_id: 'devE', envelopes: [mk(6, 'high'), mk(1, 'LOW')],
    }, envE)));
    check('authStart=6 边界 accepted=1', r.data && r.data.accepted === 1);
    check('authStart=6 边界 skipped=["notes:x"]', r.data && Array.isArray(r.data.skipped) && JSON.stringify(r.data.skipped) === JSON.stringify(['notes:x']));
    check('authStart=6 边界 versions["notes:x"]=7（不回退到 6）', r.data && r.data.versions['notes:x'] === 7);
  }

  console.log(`\nNetlify 中继协议测试：通过 ${pass}，失败 ${fail}`);
  if (fail > 0) process.exit(1);
}

main().catch((e) => {
  console.error('测试运行异常：', e);
  process.exit(1);
});

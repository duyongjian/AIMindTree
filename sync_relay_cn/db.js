/**
 * 同步中继数据访问适配层（腾讯云开发 CloudBase · PostgreSQL）。
 *
 * 这一层刻意做得很薄：整个服务只有这里会碰数据库客户端，账号、路由、
 * 密码散列都在 ``index.js`` 里。将来若再换平台（换回 D1、或换 MySQL），
 * 只需要重写本文件，其余代码不用动。
 *
 * 背景（重要，踩过的坑）：目标环境是 **PostgreSQL 环境**，不是文档型
 * （NoSQL）环境。文档型 API（``app.database()`` / ``db.collection()`` /
 * ``db.command.gt``）在该环境直接报错：
 *   ``This environment has no document database instance. It is
 *   provisioned with PostgreSQL instance [postgres-xxx], so
 *   document-database actions such as CreateTable are not available.``
 * 因此本版改走 ``app.rdb()`` —— ``@cloudbase/node-sdk`` 对 PostgreSQL
 * 的 PostgREST 客户端（与官方文档一致，见 README「数据层选型」一节）。
 *
 * 关于「为什么代码里没有 SQL 字符串」：查证结论（README 有完整引用），
 * node-sdk 的 PostgreSQL 访问面只有 PostgREST 风格的
 * ``from(table).select()/insert()/upsert()/update()/delete()`` 加
 * ``eq/gt/order/range/limit`` 修饰；``app.models.$runSQL`` 属于
 * MySQL 数据模型（文档原文 "MySQL data model provides two SQL query
 * methods"），PG 环境不可用；``exec-pgsql`` HTTP API 仅管理员可调用，
 * 云函数运行时没有管理员凭证。PostgREST 的 ``upsert()`` 底层就是
 * ``INSERT ... ON CONFLICT (...) DO UPDATE``，与 CF 版 ``worker.js`` 的
 * ``INSERT OR REPLACE`` 语义等价。
 *
 * 依赖注入：所有导出函数由 ``createStore(pg)`` 生产，``pg`` 为
 * ``app.rdb()`` 客户端（或测试里的等价 mock —— ``test_protocol.mjs``
 * 用 ``node:sqlite`` 内存库 + PostgREST 翻译层，不联网、不装驱动）。
 *
 * 表（由 ``cloudbase/migrations/`` 管理，与 CF 版 schema.sql 一一对应）：
 * - sync_envelopes：每 (owner_id, entity_table, entity_id) 一条最新态；
 * - sync_users：账号；
 * - sync_tokens：登录会话令牌。
 */

'use strict';

const TABLE_ENVELOPES = 'sync_envelopes';
const TABLE_USERS = 'sync_users';
const TABLE_TOKENS = 'sync_tokens';

/**
 * upsert 的冲突判定列：正是表的复合主键。
 * PostgREST 会把它翻成 ``ON CONFLICT (owner_id, entity_table, entity_id)``。
 */
const ENVELOPE_CONFLICT_COLS = 'owner_id,entity_table,entity_id';

/** pull 分页大小：PG 本身没有文档库那种 100/1000 上限，但一次全量可能上千条，仍要分页。 */
const DEFAULT_PAGE_SIZE = 100;
const MAX_PAGE_SIZE = 1000;

/** push 分块大小：控制单次 upsert 请求体（envelope 的 payload 可能是整篇笔记）。 */
const DEFAULT_PUSH_CHUNK = 100;
const MAX_PUSH_CHUNK = 1000;

function pageSizeFromEnv() {
  const n = parseInt(process.env.CB_PAGE_SIZE, 10);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_PAGE_SIZE;
  return Math.min(n, MAX_PAGE_SIZE);
}

function pushChunkFromEnv() {
  const n = parseInt(process.env.CB_PUSH_CHUNK, 10);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_PUSH_CHUNK;
  return Math.min(n, MAX_PUSH_CHUNK);
}

/** 把 PostgREST 返回的 error 对象转成带上下文的可读错误（由 index.js 统一转 500）。 */
function raise(error, context) {
  const msg = error && error.message ? error.message : JSON.stringify(error);
  throw new Error(`${context}: ${msg}`);
}

/** 取 ``from(table)`` 查询构造器；客户端没就绪时给出可读错误（而不是 undefined TypeError）。 */
function tableOf(pg, table) {
  if (!pg || typeof pg.from !== 'function') {
    throw new Error(
      'PostgreSQL 客户端未就绪：createStore 需要一个 app.rdb() 客户端' +
        '（云函数内由 index.js 的 getStore() 注入；本地测试用等价 mock）'
    );
  }
  return pg.from(table);
}

/**
 * @param {object} pg ``app.rdb()`` 返回的 PostgREST 客户端（或等价 mock）
 */
function createStore(pg) {
  return {
    /** 连接是否就绪（有可用的 PostgREST 客户端）。没就绪时各方法会抛可读错误。 */
    isConfigured() {
      return !!(pg && typeof pg.from === 'function');
    },

    // ---------------- 账号 ----------------

    /** 按用户名查账号；不存在返回 null。依赖 sync_users.username 唯一索引。 */
    async getUserByUsername(username) {
      const { data, error } = await tableOf(pg, TABLE_USERS)
        .select('id, username, pw_hash, created_at')
        .eq('username', username)
        .limit(1)
        .maybeSingle();
      if (error) raise(error, 'getUserByUsername 失败');
      return data || null;
    },

    /**
     * 建账号（user_id 即表主键）。
     * @param {{id:string, username:string, pw_hash:string, created_at:string}} user
     */
    async createUser(user) {
      const { error } = await tableOf(pg, TABLE_USERS).insert({
        id: user.id,
        username: user.username,
        pw_hash: user.pw_hash,
        created_at: user.created_at,
      });
      if (error) raise(error, 'createUser 失败');
      return user;
    },

    /** 落一条会话令牌（明文令牌即表主键，查询走主键索引）。 */
    async createToken(token, userId, createdAt) {
      const { error } = await tableOf(pg, TABLE_TOKENS).insert({
        token,
        user_id: userId,
        created_at: createdAt,
      });
      if (error) raise(error, 'createToken 失败');
      return token;
    },

    /** 令牌 → 归属 user_id；无效令牌返回 null。 */
    async resolveToken(token) {
      const { data, error } = await tableOf(pg, TABLE_TOKENS)
        .select('token, user_id')
        .eq('token', token)
        .limit(1)
        .maybeSingle();
      if (error) raise(error, 'resolveToken 失败');
      return data ? data.user_id : null;
    },

    // ---------------- 同步数据 ----------------

    /**
     * 批量 upsert：以 (owner_id, entity_table, entity_id) 为键覆盖最新态。
     *
     * 底层是 PostgREST 的 ``INSERT ... ON CONFLICT (owner_id, entity_table,
     * entity_id) DO UPDATE SET device_id/op/payload_json/base_version/
     * updated_at/deleted_at/server_time = excluded.*``，与 CF 版 D1 的
     * ``INSERT OR REPLACE`` 等价：整行按本次 push 的内容覆盖（LWW 已在
     * App 端完成，服务端不比较 base_version，直接写新值）。
     *
     * 按块切分（默认 100 条/块，CB_PUSH_CHUNK 可调）只为控制单次请求体
     * 大小，语义上仍是「一条 upsert 语句批量处理一块」。
     *
     * payload 一律以 ``payload_json`` 字符串落库（与 CF 版一致）：PG 的
     * text 列同样不关心 JSON 结构，字符串化最稳。
     */
    async upsertEnvelopes(ownerId, envelopes, serverTime) {
      const rows = envelopes.map((e) => ({
        owner_id: ownerId,
        entity_table: e.entity_table,
        entity_id: e.entity_id,
        device_id: e.device_id,
        op: e.op,
        payload_json: e.payload == null ? null : JSON.stringify(e.payload),
        base_version: parseInt(e.base_version, 10) || 0,
        updated_at: e.updated_at == null ? null : e.updated_at,
        deleted_at: e.deleted_at == null ? null : e.deleted_at,
        server_time: serverTime,
      }));

      const chunkSize = pushChunkFromEnv();
      for (let i = 0; i < rows.length; i += chunkSize) {
        const { error } = await tableOf(pg, TABLE_ENVELOPES)
          .upsert(rows.slice(i, i + chunkSize), { onConflict: ENVELOPE_CONFLICT_COLS });
        if (error) raise(error, `upsertEnvelopes 失败（第 ${i / chunkSize + 1} 块）`);
      }
      return rows.length;
    },

    /**
     * 按 server_time 升序取出 owner 名下 since 之后的全部 envelope；
     * since 为空取全量。内部按页循环取回全部结果。
     *
     * 三级排序 ``server_time + entity_table + entity_id``：同一批 push 的
     * server_time 完全相同，只按时间排会让分页边界不确定（PG 不保证同值
     * 行的稳定序），加上主键后两列兜底，翻页不重不漏（文档型旧版用
     * server_time + _id 二级排序，PG 版主键本身就是三列，取其后两列）。
     */
    async pullSince(ownerId, since) {
      const cols =
        'owner_id, entity_table, entity_id, device_id, op, payload_json, ' +
        'base_version, updated_at, deleted_at';
      const pageSize = pageSizeFromEnv();
      const out = [];
      for (let offset = 0; ; offset += pageSize) {
        let q = tableOf(pg, TABLE_ENVELOPES)
          .select(cols)
          .eq('owner_id', ownerId)
          .order('server_time', { ascending: true })
          .order('entity_table', { ascending: true })
          .order('entity_id', { ascending: true })
          .range(offset, offset + pageSize - 1);
        if (since) q = q.gt('server_time', since);
        const { data, error } = await q;
        if (error) raise(error, 'pullSince 失败');
        const rows = data || [];
        out.push(...rows);
        if (rows.length < pageSize) break;
      }
      return out;
    },

    /** owner 名下 envelope 总数（manifest）。head+exact 底层是 COUNT(*)。 */
    async countEnvelopes(ownerId) {
      const { count, error } = await tableOf(pg, TABLE_ENVELOPES)
        .select('*', { count: 'exact', head: true })
        .eq('owner_id', ownerId);
      if (error) raise(error, 'countEnvelopes 失败');
      return typeof count === 'number' ? count : 0;
    },
  };
}

module.exports = {
  createStore,
  TABLE_ENVELOPES,
  TABLE_USERS,
  TABLE_TOKENS,
  ENVELOPE_CONFLICT_COLS,
  DEFAULT_PAGE_SIZE,
  MAX_PAGE_SIZE,
  DEFAULT_PUSH_CHUNK,
  MAX_PUSH_CHUNK,
};

/**
 * 同步中继数据访问适配层（腾讯云开发 CloudBase 云数据库 · 文档型）。
 *
 * 这一层刻意做得很薄：整个服务只有这里会碰 ``database`` 句柄，账号、路由、
 * 密码散列都在 ``index.js`` 里。将来若再换平台（比如换回 D1、或换成 MySQL
 * 型云数据库），只需要重写本文件，其余代码不用动。
 *
 * 依赖注入：所有导出函数都由 ``createStore(database)`` 生产，``database`` 为
 * ``@cloudbase/node-sdk`` 的 ``app.database()`` 句柄。这样本地自测可以直接塞一个
 * 内存 mock 进来，不必联网、不必有腾讯云账号（见 ``test_protocol.mjs``）。
 *
 * 集合（与 Cloudflare 版 schema.sql 一一对应）：
 * - sync_envelopes：每条文档存一个 (owner_id, entity_table, entity_id) 的最新态；
 * - sync_users：账号；
 * - sync_tokens：登录会话令牌。
 */

'use strict';

const COLLECTION_ENVELOPES = 'sync_envelopes';
const COLLECTION_USERS = 'sync_users';
const COLLECTION_TOKENS = 'sync_tokens';

/**
 * 单次 ``get()`` 的分页大小。
 *
 * CloudBase 文档型数据库的自述存在两个版本（以云函数运行时的实际行为为准）：
 * - 官方文档 增删改查：默认 100 条，最多 1000 条；
 * - node-sdk 仓库 docs/database/database.md：默认 100 条，最大 100 条。
 *
 * 取两者都安全的 100 作为默认分页大小，并用 ``while`` 循环翻页把结果取干净；
 * server_time + _id 二级排序保证翻页不重不漏。1000 只是「上限」，若运行时确实
 */
const DEFAULT_PAGE_SIZE = 100;
const MAX_PAGE_SIZE = 1000;

/** 写入并发度：一次 push 可能有上千条 envelope，串行 set 会拖慢整次调用。 */
const DEFAULT_WRITE_CONCURRENCY = 20;

function pageSizeFromEnv() {
  const n = parseInt(process.env.CB_PAGE_SIZE, 10);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_PAGE_SIZE;
  return Math.min(n, MAX_PAGE_SIZE);
}

function writeConcurrencyFromEnv() {
  const n = parseInt(process.env.CB_WRITE_CONCURRENCY, 10);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_WRITE_CONCURRENCY;
  return n;
}

/**
 * document ``_id`` 段转义。
 *
 * 我们用 ``owner_id``、``entity_table``、``entity_id`` 拼成的字符串当 ``_id``，
 * 从而实现「每个业务键只保留最新态」的 upsert 语义。CloudBase 文档型数据库的
 * ``_id`` 是字符串，UUID 里的短横线是合法的，但**点号（.）、美元符（$）、斜杠
 * 这类字符不合法**——而 App 端的 ``entity_id`` 由各张表自己决定，并不保证不含
 * 这些字符。因此对每段做一次百分号风格的转义（``%`` 本身先转义，保证可逆）。
 *
 * 仅影响 ``_id``：``owner_id/entity_table/entity_id`` 依然以独立字段原样落库，
 * 查询和返回都读原值，转义不会泄漏给 App。
 */
function escapeKeySegment(s) {
  return String(s).replace(/[%$./\\]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());
}

/**
 * envelope 文档主键：``owner__table__entity``。
 *
 * owner_id 固定为 ``u_`` + 24 位十六进制，本身不含 ``__``，故拼接无歧义。
 */
function envelopeDocId(ownerId, entityTable, entityId) {
  return (
    escapeKeySegment(ownerId) +
    '__' +
    escapeKeySegment(entityTable) +
    '__' +
    escapeKeySegment(entityId)
  );
}

/**
 * ``doc().get()`` 在不同版本的 SDK 里返回的形状不完全一致（有的给 ``data: [doc]``，
 * 有的给 ``data: doc``），这里统一成「文档或 null」。
 */
function pickDoc(res) {
  const data = res && res.data;
  if (!data) return null;
  if (Array.isArray(data)) return data.length ? data[0] : null;
  return data;
}

/** 有限并发地执行一批写任务（避免上千条 envelope 串行跑）。 */
async function mapWithConcurrency(items, concurrency, fn) {
  const queue = items.slice();
  const workers = [];
  for (let i = 0; i < Math.min(concurrency, queue.length); i++) {
    workers.push(
      (async () => {
        while (queue.length) {
          const item = queue.shift();
          await fn(item);
        }
      })()
    );
  }
  await Promise.all(workers);
}

/**
 * @param {object} database @cloudbase/node-sdk 的 app.database() 句柄（或等价 mock）
 */
function createStore(database) {
  const col = (name) => database.collection(name);

  return {
    // ---------------- 账号 ----------------

    /** 按用户名查账号文档；不存在返回 null。依赖 sync_users.username 唯一索引。 */
    async getUserByUsername(username) {
      const res = await col(COLLECTION_USERS).where({ username }).limit(1).get();
      const docs = (res && res.data) || [];
      return docs.length ? docs[0] : null;
    },

    /**
     * 建账号。用 user_id 本身当 ``_id``，天然带上主键索引。
     * @param {{id:string, username:string, pw_hash:string, created_at:string}} user
     */
    async createUser(user) {
      await col(COLLECTION_USERS).doc(user.id).set(user);
      return user;
    },

    /** 落一条会话令牌。用明文令牌当 ``_id``，查询走主键索引。 */
    async createToken(token, userId, createdAt) {
      await col(COLLECTION_TOKENS).doc(token).set({
        token,
        user_id: userId,
        created_at: createdAt,
      });
      return token;
    },

    /** 令牌 → 归属 user_id；无效令牌返回 null。 */
    async resolveToken(token) {
      const doc = pickDoc(await col(COLLECTION_TOKENS).doc(token).get());
      return doc ? doc.user_id : null;
    },

    // ---------------- 同步数据 ----------------

    /**
     * 批量 upsert：以 (owner_id, entity_table, entity_id) 为键，``doc().set()``
     * 在 CloudBase 里是「存在则整篇覆盖、不存在则新建」，等价于 D1 的
     * ``INSERT OR REPLACE``。
     *
     * 注意 payload 一律以 ``payload_json`` 字符串落库（与 CF 版一致），不直接存对象：
     * 文档型数据库的字段名有字符集限制，App 端 payload 的键不可控，字符串化最稳。
     */
    async upsertEnvelopes(ownerId, envelopes, serverTime) {
      const envelopeCol = col(COLLECTION_ENVELOPES);
      await mapWithConcurrency(envelopes, writeConcurrencyFromEnv(), async (e) => {
        const doc = {
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
        };
        await envelopeCol
          .doc(envelopeDocId(ownerId, e.entity_table, e.entity_id))
          .set(doc);
      });
    },

    /**
     * 按 server_time 升序取出 owner 名下 since 之后的全部 envelope；
     * since 为空取全量。内部按页循环取回全部结果。
     */
    async pullSince(ownerId, since) {
      const _ = database.command;
      const condition = since
        ? { owner_id: ownerId, server_time: _.gt(since) }
        : { owner_id: ownerId };

      const pageSize = pageSizeFromEnv();
      const out = [];
      for (let skip = 0; ; skip += pageSize) {
        const res = await col(COLLECTION_ENVELOPES)
          .where(condition)
          .orderBy('server_time', 'asc')
          .orderBy('_id', 'asc')
          .skip(skip)
          .limit(pageSize)
          .get();
        const rows = (res && res.data) || [];
        out.push(...rows);
        if (rows.length < pageSize) break;
      }
      return out;
    },

    /** owner 名下 envelope 总数（manifest）。 */
    async countEnvelopes(ownerId) {
      const res = await col(COLLECTION_ENVELOPES).where({ owner_id: ownerId }).count();
      const total = res && res.total;
      return typeof total === 'number' ? total : 0;
    },
  };
}

module.exports = {
  createStore,
  envelopeDocId,
  escapeKeySegment,
  COLLECTION_ENVELOPES,
  COLLECTION_USERS,
  COLLECTION_TOKENS,
  DEFAULT_PAGE_SIZE,
  MAX_PAGE_SIZE,
};

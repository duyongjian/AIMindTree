/**
 * 同步中继数据访问适配层（Vercel KV · Upstash Redis）。
 *
 * 这一层刻意做得很薄：整个服务只有这里会碰 Redis 客户端，账号、路由、密码散列都在
 * ``core.js`` 里。**本文件不 import ``@vercel/kv``**——客户端由调用方注入
 * （``api/[[...path]].js`` 注入真实的 ``kv``，本地自测注入内存 mock），因此
 * ``node test_protocol.mjs`` 不需要安装任何依赖、不联网、不需要 Vercel 账号。
 *
 * 数据模型（与 CF 版 schema.sql 的三张表一一对应）：
 *
 * - ``sync:users``          HASH：field=username，value=账号 JSON
 *                           （对应 sync_users；username 唯一）
 * - ``sync:tokens``         HASH：field=明文令牌，value={userId, createdAt}
 *                           （对应 sync_tokens）
 * - ``sync:env:{ownerId}``  HASH：field=转义后的 ``table__entity``，
 *                           value=envelope 文档 JSON（payload 以字符串存）
 * - ``sync:z:{ownerId}``    ZSET：member=同一个转义键，score=server_time 毫秒数
 *
 * 为什么 envelope 要拆成 HASH + ZSET 两个 key：
 * - HASH 提供「每个 (owner, entity_table, entity_id) 只保留最新态」的 upsert
 *   语义（HSET 同 field 即覆盖），与 D1 的 ``INSERT OR REPLACE`` 等价；
 * - ZSET 提供「按 server_time 排序的增量游标」，与 D1 的
 *   ``WHERE owner_id = ? AND server_time > ? ORDER BY server_time`` 等价。
 *
 * 增量游标的关键点（ZADD 的 score 是数字，member 必须唯一）：
 * - score = ``Date.parse(serverTime)``，即 ISO 8601 UTC 的毫秒数；
 * - member = 转义后的 ``table__entity``（**不含 ownerId**，owner 已由 key 前缀
 *   ``sync:z:{ownerId}`` 隔离）。同一批 push 的 server_time 可能完全相同
 *   （同一次 nowIso()），若 member 不唯一，同批条目会在 ZSET 里互相覆盖导致
 *   count 偏小；用 ``table__entity`` 做 member 天然唯一，排序是全序，
 *   ``LIMIT offset count`` 翻页不重不漏。
 */

// ---------------- Redis key 规划 ----------------

/** HASH：field=username，value=账号 JSON（对应 CF 版 sync_users 表）。 */
const KEY_USERS = 'sync:users';

/** HASH：field=明文令牌，value={userId, createdAt}（对应 sync_tokens 表）。 */
const KEY_TOKENS = 'sync:tokens';

/** HASH：某 owner 的 envelope 文档体，field=转义键，value=文档 JSON。 */
const envHashKey = (ownerId) => `sync:env:${ownerId}`;

/** ZSET：某 owner 的时间游标，member=转义键，score=server_time 毫秒数。 */
const envZsetKey = (ownerId) => `sync:z:${ownerId}`;

// ---------------- 可调参数 ----------------

/** 单次 zrange 分页大小（Upstash 对单命令返回条数没有 100 条硬限，取 100 兼顾延迟）。 */
const DEFAULT_PAGE_SIZE = 100;
const MAX_PAGE_SIZE = 1000;

/** 单个 multi() 事务写入的 envelope 条数（1200 条 = 12 个事务，控制请求体大小）。 */
const DEFAULT_WRITE_CHUNK = 100;

function pageSizeFromEnv() {
  const n = parseInt(process.env.SYNC_PULL_PAGE_SIZE, 10);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_PAGE_SIZE;
  return Math.min(n, MAX_PAGE_SIZE);
}

function writeChunkFromEnv() {
  const n = parseInt(process.env.SYNC_WRITE_CHUNK, 10);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_WRITE_CHUNK;
  return n;
}

// ---------------- key 转义 ----------------

/**
 * ZSET member / HASH field 段转义（可逆，百分号风格，``%`` 自身先转义）。
 *
 * 参照 ``sync_relay_cn/db.js``：App 端的 ``entity_id`` 由各张表自己决定，并不保证
 * 不含 ``. $ / \`` 这类字符；与 CloudBase 的 ``_id`` 不同，Redis 的 member/field
 * 本身二进制安全，但我们的 member 是 ``table__entity`` **拼接**出来的，所以还要
 * 转义分隔符 ``_``——否则 ``('notes__x', 'y')`` 和 ``('notes', 'x__y')`` 会拼出
 * 同一个 member，两个不同实体互相覆盖。转义后段内不可能出现裸 ``_``，``__`` 只作为
 * 分隔符出现，拼接无歧义。
 *
 * 仅影响 member/field：``entity_table / entity_id`` 依然以独立字段原样存在文档里，
 * 查询和返回都读原值，转义不会泄漏给 App。
 */
function escapeKeySegment(s) {
  return String(s).replace(/[%$./\\_]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());
}

/**
 * envelope 的 ZSET member / HASH field：``table__entity``。
 * owner 不进 member——key 前缀 ``sync:z:{ownerId}`` 已完成租户隔离。
 */
function memberKey(entityTable, entityId) {
  return escapeKeySegment(entityTable) + '__' + escapeKeySegment(entityId);
}

// ---------------- 环境就绪判断 ----------------

/**
 * KV 环境变量是否就绪（Vercel 绑定 KV 数据库后会自动注入这两个变量）。
 * 没绑定时由入口返回可读的 503，而不是抛 ``@vercel/kv`` 那句看不懂的异常。
 */
export function isConfigured() {
  const url = process.env.KV_REST_API_URL || process.env.KV_URL;
  const token = process.env.KV_REST_API_TOKEN || process.env.KV_API_TOKEN;
  return Boolean(url && token);
}

// ---------------- store ----------------

/**
 * 由 Redis 客户端合成业务 store。
 *
 * @param {object} client 注入的客户端（``@vercel/kv`` 的 ``kv`` 或等价 mock），
 *   需实现：hget / hset / hsetnx / hmget / zadd / zrange / zcard / multi()。
 */
export function createStore(client) {
  if (!client) {
    throw new Error('createStore 需要一个 Redis 客户端（入口传 @vercel/kv 的 kv，自测传内存 mock）');
  }

  return {
    // ---------------- 账号 ----------------

    /** 按用户名查账号；不存在返回 null。 */
    async getUserByUsername(username) {
      const raw = await client.hget(KEY_USERS, String(username));
      return raw ? JSON.parse(raw) : null;
    },

    /**
     * 建账号。``hsetnx`` 原子占位：并发注册同一用户名时只有一个成功，
     * 与 core 里的「先查后插」互为双保险（对应 D1 的 username 唯一索引）。
     * @returns {Promise<boolean>} true=创建成功；false=用户名已被占用
     */
    async createUser({ id, username, pwHash, createdAt }) {
      const ok = await client.hsetnx(
        KEY_USERS,
        String(username),
        JSON.stringify({ id, username, pwHash, createdAt })
      );
      return ok === 1;
    },

    /** 落一条会话令牌（明文令牌即 HASH field，查询走字段定位）。 */
    async createToken({ token, userId, createdAt }) {
      await client.hset(KEY_TOKENS, { [token]: JSON.stringify({ userId, createdAt }) });
    },

    /** 令牌 → 归属 userId；无效令牌返回 null。 */
    async resolveToken(token) {
      const raw = await client.hget(KEY_TOKENS, String(token));
      if (!raw) return null;
      try {
        const doc = JSON.parse(raw);
        return doc && typeof doc.userId === 'string' ? doc.userId : null;
      } catch {
        return null;
      }
    },

    // ---------------- 同步数据 ----------------

    /**
     * 批量 upsert：以 (owner_id, entity_table, entity_id) 为键覆盖最新态，
     * 并刷新 ZSET 里对应 member 的 score（即刷新游标位置）。
     *
     * 按块走 ``multi()`` 事务：每个事务里 HSET（文档体）+ ZADD（游标）同时生效，
     * 不会出现「hash 有、zset 无」导致 pull 漏数据；块与块之间非原子，大批量
     * push 中途失败时前几块已生效——App 侧 push 是幂等 upsert，重推同一批即收敛。
     */
    async upsertEnvelopes(ownerId, envelopes, serverTime) {
      if (!envelopes || envelopes.length === 0) return;
      const score = Date.parse(serverTime);
      const hashKey = envHashKey(ownerId);
      const zKey = envZsetKey(ownerId);
      const chunk = writeChunkFromEnv();

      for (let i = 0; i < envelopes.length; i += chunk) {
        const fields = {};
        const pairs = [];
        for (const e of envelopes.slice(i, i + chunk)) {
          const member = memberKey(e.entity_table, e.entity_id);
          // payload 一律以 JSON 字符串落库（与 CF 版一致）：文档型/字段型存储对
          // 键名字符集都有限制，App 端 payload 的键不可控，字符串化最稳。
          fields[member] = JSON.stringify({
            device_id: e.device_id,
            entity_table: e.entity_table,
            entity_id: e.entity_id,
            op: e.op,
            payload_json: e.payload == null ? null : JSON.stringify(e.payload),
            base_version: parseInt(e.base_version, 10) || 0,
            updated_at: e.updated_at == null ? null : e.updated_at,
            deleted_at: e.deleted_at == null ? null : e.deleted_at,
            server_time: serverTime,
          });
          pairs.push({ score, member });
        }
        const tx = client.multi();
        tx.hset(hashKey, fields);
        tx.zadd(zKey, ...pairs);
        await tx.exec();
      }
    },

    /**
     * 按 server_time 升序取出 owner 名下 since 之后的全部 envelope；
     * since 为空 = 全量。内部循环翻页取回全部结果。
     *
     * 游标语义与 CF 版 SQL 逐字对应：``server_time > since`` → ZSET 的
     * **开区间** ``(sinceMs +inf``（``(`` 前缀 = 严格大于），排序即 score 升序。
     * 翻页用 ``LIMIT offset count``：member 唯一保证全序，offset 分页不重不漏。
     *
     * @param {string|null} sinceIso ISO 8601 UTC；不可解析时退回全量
     *   （CF 版是字符串比较，宽口径；全量拉取对 App 是无害的幂等合并）
     * @param {number} [pageSize] 单页条数，默认读环境变量 SYNC_PULL_PAGE_SIZE
     */
    async pullSince(ownerId, sinceIso, pageSize = pageSizeFromEnv()) {
      const hashKey = envHashKey(ownerId);
      const zKey = envZsetKey(ownerId);
      let sinceMs = sinceIso ? Date.parse(sinceIso) : NaN;
      if (!Number.isFinite(sinceMs)) sinceMs = -Infinity;
      const min = sinceMs === -Infinity ? '-inf' : `(${sinceMs}`;

      const out = [];
      for (let offset = 0; ; offset += pageSize) {
        const members = await client.zrange(zKey, min, '+inf', {
          byScore: true,
          offset,
          count: pageSize,
        });
        if (!members || members.length === 0) break;
        // hmget 一次取回本页全部文档；逐 member 回填保证输出顺序 = score 升序。
        const raw = await client.hmget(hashKey, ...members);
        for (const member of members) {
          const doc = raw ? raw[member] : null;
          if (doc) out.push(JSON.parse(doc));
        }
        if (members.length < pageSize) break;
      }
      return out;
    },

    /** owner 名下 envelope 总数（manifest）。 */
    async countEnvelopes(ownerId) {
      return await client.zcard(envZsetKey(ownerId));
    },
  };
}

export {
  KEY_USERS,
  KEY_TOKENS,
  envHashKey,
  envZsetKey,
  escapeKeySegment,
  memberKey,
  DEFAULT_PAGE_SIZE,
  DEFAULT_WRITE_CHUNK,
};

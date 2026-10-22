-- Cloudflare D1 同步中继表结构（方案 B，多租户账号版）。
-- 用法：wrangler d1 execute aimindtree_sync --remote --file=./schema.sql
--
-- 设计要点：
-- - sync_envelopes 以 (owner_id, entity_table, entity_id) 为唯一键，按用户命名空间
--   隔离（LWW 已在 App 端完成，服务端只存每个 key 的最新态 + server_time）。
-- - sync_users / sync_tokens 支撑「账号登录」多租户：普通用户用用户名+密码自助
--   注册/登录，登录后拿到每用户令牌，服务端据此隔离数据；无需共享 SYNC_TOKEN。

CREATE TABLE IF NOT EXISTS sync_envelopes (
    owner_id     TEXT NOT NULL,
    entity_table TEXT NOT NULL,
    entity_id    TEXT NOT NULL,
    device_id   TEXT NOT NULL,
    op          TEXT NOT NULL,
    payload_json TEXT,
    base_version INTEGER NOT NULL DEFAULT 0,
    updated_at  TEXT,
    deleted_at  TEXT,
    server_time TEXT NOT NULL,
    PRIMARY KEY (owner_id, entity_table, entity_id)
);

CREATE INDEX IF NOT EXISTS idx_sync_env_owner_time
    ON sync_envelopes (owner_id, server_time);

-- 账号表：pw_hash 存 "saltHex:hashHex"（PBKDF2-SHA256，见 worker.js）。
CREATE TABLE IF NOT EXISTS sync_users (
    id         TEXT NOT NULL,
    username   TEXT NOT NULL,
    pw_hash    TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_users_username
    ON sync_users (username);

-- 登录会话令牌表：每个令牌映射到一个 user_id（Bearer 鉴权）。
CREATE TABLE IF NOT EXISTS sync_tokens (
    token      TEXT NOT NULL,
    user_id    TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (token)
);

CREATE INDEX IF NOT EXISTS idx_sync_tokens_user
    ON sync_tokens (user_id);

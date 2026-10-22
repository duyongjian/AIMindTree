-- Cloudflare D1 同步中继表结构（方案 B）。
-- 用法：wrangler d1 execute aimindtree_sync --file=./schema.sql
--
-- 只存每个 (entity_table, entity_id) 的「最新态」——LWW 已在 App 端完成，
-- 服务端仅需保存最新态 + server_time 供增量拉取（拉取按 server_time > since）。

CREATE TABLE IF NOT EXISTS sync_envelopes (
    entity_table TEXT NOT NULL,
    entity_id    TEXT NOT NULL,
    device_id   TEXT NOT NULL,
    op          TEXT NOT NULL,
    payload_json TEXT,
    base_version INTEGER NOT NULL DEFAULT 0,
    updated_at  TEXT,
    deleted_at  TEXT,
    server_time TEXT NOT NULL,
    PRIMARY KEY (entity_table, entity_id)
);

-- 增量拉取按 server_time 过滤，建索引加速（可选，表小可省略）。
CREATE INDEX IF NOT EXISTS idx_sync_server_time
    ON sync_envelopes (server_time);

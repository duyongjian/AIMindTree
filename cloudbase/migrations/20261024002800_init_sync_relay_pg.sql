-- AIMindTree sync relay: initial tables (PostgreSQL-mode CloudBase environment).
--
-- Environment mindtree-d7glv6crkd8e9fba9 is provisioned with a PostgreSQL
-- instance (not a document/NoSQL database), so the relay stores rows in real
-- tables. Mirrors sync_relay_cf/schema.sql (D1/SQLite) 1:1.
--
-- NOTE: this file is intentionally single-statement-per-line so it can be fed
-- to managePgDatabase(action=applyMigration) via the CLI without newline
-- mangling.
CREATE TABLE IF NOT EXISTS sync_envelopes (owner_id TEXT NOT NULL, entity_table TEXT NOT NULL, entity_id TEXT NOT NULL, device_id TEXT NOT NULL, op TEXT NOT NULL, payload_json TEXT, base_version INTEGER NOT NULL DEFAULT 0, updated_at TEXT, deleted_at TEXT, server_time TEXT NOT NULL, PRIMARY KEY (owner_id, entity_table, entity_id));
CREATE INDEX IF NOT EXISTS idx_sync_env_owner_time ON sync_envelopes (owner_id, server_time);
CREATE TABLE IF NOT EXISTS sync_users (id TEXT NOT NULL, username TEXT NOT NULL, pw_hash TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY (id));
CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_users_username ON sync_users (username);
CREATE TABLE IF NOT EXISTS sync_tokens (token TEXT NOT NULL, user_id TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY (token));
CREATE INDEX IF NOT EXISTS idx_sync_tokens_user ON sync_tokens (user_id);

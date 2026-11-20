CREATE TABLE jm_origin_control (
 slot INTEGER PRIMARY KEY CHECK(slot=1), generation INTEGER NOT NULL DEFAULT 0,
 primary_id TEXT, paused INTEGER NOT NULL DEFAULT 0, lease TEXT, lease_until INTEGER NOT NULL DEFAULT 0
);
INSERT INTO jm_origin_control(slot) VALUES(1);
CREATE TABLE jm_origin_enrollments (
 id TEXT PRIMARY KEY, machine TEXT NOT NULL, commitment TEXT NOT NULL,
 actor_id TEXT NOT NULL REFERENCES jm_accounts(id), session_id TEXT NOT NULL,
 generation INTEGER NOT NULL, expires INTEGER NOT NULL, claimed INTEGER NOT NULL DEFAULT 0,
 cursor TEXT NOT NULL DEFAULT '', activated INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX jm_enroll_expiry ON jm_origin_enrollments(expires);
ALTER TABLE jm_storage_transfers ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE jm_storage_transfers ADD COLUMN last_error TEXT;


CREATE TABLE jm_origin_nonces(origin TEXT NOT NULL, nonce TEXT NOT NULL, expires INTEGER NOT NULL, PRIMARY KEY(origin,nonce));
CREATE TABLE jm_storage_backups(hash TEXT PRIMARY KEY, origin TEXT NOT NULL, created_at TEXT NOT NULL);

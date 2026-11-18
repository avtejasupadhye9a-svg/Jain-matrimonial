CREATE TABLE jm_notifications (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL, kind TEXT NOT NULL, entity_id TEXT NOT NULL,
  created_at TEXT NOT NULL, read_at TEXT
);
CREATE INDEX jm_notifications_account ON jm_notifications(account_id,created_at DESC,id DESC);
CREATE INDEX jm_notifications_unread ON jm_notifications(account_id) WHERE read_at IS NULL;
CREATE TABLE jm_audit (
  id TEXT PRIMARY KEY, actor_id TEXT, entity_id TEXT NOT NULL, action TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE INDEX jm_audit_recent ON jm_audit(created_at DESC,id DESC);
CREATE TABLE jm_email_jobs (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL
    CHECK(status IN ('pending','sending','sent','failed','skipped')),
  attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL, last_error TEXT, lease TEXT
);
CREATE INDEX jm_email_due ON jm_email_jobs(status,next_at);
CREATE TABLE jm_storage_jobs (
  id TEXT PRIMARY KEY, file_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL
    CHECK(state IN ('queued','copying','confirmed','retry','retired')),
  attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER, last_error TEXT, confirmed_at TEXT
);

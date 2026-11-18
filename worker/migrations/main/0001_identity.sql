CREATE TABLE jm_accounts (
  id TEXT PRIMARY KEY, email TEXT NOT NULL COLLATE NOCASE UNIQUE,
  role TEXT NOT NULL DEFAULT 'customer' CHECK(role IN ('customer','admin')),
  status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','suspended','closed')),
  verified_at TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE jm_sessions (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES jm_accounts(id),
  access_hash TEXT NOT NULL UNIQUE, refresh_hash TEXT NOT NULL UNIQUE,
  access_until INTEGER NOT NULL, refresh_until INTEGER NOT NULL,
  rotated_at INTEGER NOT NULL, revoked_at INTEGER
);
CREATE INDEX jm_sessions_account ON jm_sessions(account_id);
CREATE TABLE jm_otp (
  id TEXT PRIMARY KEY, email TEXT NOT NULL COLLATE NOCASE,
  purpose TEXT NOT NULL CHECK(purpose IN ('login','claim','security','email_change')),
  channel TEXT NOT NULL DEFAULT 'email' CHECK(channel = 'email'),
  code_hash TEXT NOT NULL, expires INTEGER NOT NULL, attempts INTEGER NOT NULL,
  issued_at INTEGER NOT NULL, consumed_at INTEGER
);
CREATE INDEX jm_otp_email ON jm_otp(email, purpose, issued_at DESC);
CREATE TABLE jm_rate (
  bucket TEXT PRIMARY KEY, window INTEGER NOT NULL, count INTEGER NOT NULL
);
CREATE TABLE jm_idempotency (
  actor TEXT NOT NULL, route TEXT NOT NULL, key TEXT NOT NULL,
  digest TEXT NOT NULL, status INTEGER, response TEXT, created_at INTEGER NOT NULL,
  PRIMARY KEY(actor, route, key)
);
CREATE TABLE jm_outbox (
  id TEXT PRIMARY KEY, actor_id TEXT REFERENCES jm_accounts(id), entity_id TEXT NOT NULL,
  action TEXT NOT NULL, account_id TEXT REFERENCES jm_accounts(id),
  created_at TEXT NOT NULL, processed_at TEXT
);
CREATE INDEX jm_outbox_pending ON jm_outbox(created_at,id) WHERE processed_at IS NULL;

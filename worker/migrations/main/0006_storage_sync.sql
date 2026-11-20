-- One attempt = one immutable B2 key. Reserving before PUT makes a lost response recoverable.
CREATE TABLE jm_storage_transfers (
  ticket TEXT PRIMARY KEY,
  file_id TEXT NOT NULL REFERENCES jm_file_metadata(id),
  actor_id TEXT NOT NULL REFERENCES jm_accounts(id),
  bytes INTEGER NOT NULL CHECK(bytes BETWEEN 1 AND 8388608),
  version TEXT,
  next_attempt INTEGER NOT NULL,
  cleaned_at TEXT
);
CREATE INDEX jm_storage_due ON jm_storage_transfers(next_attempt) WHERE cleaned_at IS NULL;
CREATE TABLE jm_storage_receipts (
  ticket TEXT PRIMARY KEY REFERENCES jm_storage_transfers(ticket),
  origin_id TEXT NOT NULL, version TEXT NOT NULL, sha256 TEXT NOT NULL,
  bytes INTEGER NOT NULL, verified_at TEXT NOT NULL
);
CREATE TRIGGER jm_storage_receipt_immutable BEFORE UPDATE ON jm_storage_receipts BEGIN
  SELECT RAISE(ABORT, 'Receipt is immutable');
END;
CREATE TRIGGER jm_storage_receipt_keep BEFORE DELETE ON jm_storage_receipts BEGIN
  SELECT RAISE(ABORT, 'Receipt is durable');
END;


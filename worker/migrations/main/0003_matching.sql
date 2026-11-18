CREATE TABLE jm_blocks (
  account_id TEXT NOT NULL REFERENCES jm_accounts(id), blocked_id TEXT NOT NULL REFERENCES jm_accounts(id),
  created_at TEXT NOT NULL, PRIMARY KEY(account_id,blocked_id), CHECK(account_id<>blocked_id)
);
CREATE INDEX jm_blocks_reverse ON jm_blocks(blocked_id,account_id);
CREATE TABLE jm_favorites (
  account_id TEXT NOT NULL REFERENCES jm_accounts(id), profile_id TEXT NOT NULL REFERENCES jm_profiles(id),
  created_at TEXT NOT NULL, PRIMARY KEY(account_id,profile_id)
);
CREATE TABLE jm_saved_searches (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES jm_accounts(id),
  name TEXT NOT NULL, filters TEXT NOT NULL CHECK(json_valid(filters)), created_at TEXT NOT NULL,
  UNIQUE(account_id,name)
);
CREATE TABLE jm_interests (
  id TEXT PRIMARY KEY, sender TEXT NOT NULL REFERENCES jm_profiles(id), recipient TEXT NOT NULL REFERENCES jm_profiles(id),
  pair TEXT NOT NULL UNIQUE, actor_id TEXT NOT NULL REFERENCES jm_accounts(id),
  status TEXT NOT NULL CHECK(status IN ('pending_admin_review','pending_recipient','rejected','declined',
    'pending_contact_authorization','authorized','withdrawn','cancelled','expired')),
  version INTEGER NOT NULL DEFAULT 1, reason TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  expires_at TEXT NOT NULL, CHECK(sender<>recipient)
);
CREATE INDEX jm_interests_recipient ON jm_interests(recipient,updated_at);
CREATE INDEX jm_interests_sender ON jm_interests(sender,updated_at);
CREATE TABLE jm_interest_events (
  id TEXT PRIMARY KEY, interest_id TEXT NOT NULL REFERENCES jm_interests(id),
  actor_id TEXT NOT NULL REFERENCES jm_accounts(id), status TEXT NOT NULL, reason TEXT, created_at TEXT NOT NULL
);
CREATE TABLE jm_consents (
  interest_id TEXT NOT NULL REFERENCES jm_interests(id), account_id TEXT NOT NULL REFERENCES jm_accounts(id),
  scope TEXT NOT NULL CHECK(scope='verified_email'), granted_at TEXT NOT NULL, revoked_at TEXT,
  PRIMARY KEY(interest_id,account_id)
);
CREATE TABLE jm_consent_events (
  id TEXT PRIMARY KEY, interest_id TEXT NOT NULL REFERENCES jm_interests(id),
  account_id TEXT NOT NULL REFERENCES jm_accounts(id), scope TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('granted','revoked')), created_at TEXT NOT NULL
);
CREATE TABLE jm_reports (
  id TEXT PRIMARY KEY, reporter_id TEXT NOT NULL REFERENCES jm_accounts(id),
  profile_id TEXT NOT NULL REFERENCES jm_profiles(id), reason TEXT NOT NULL, created_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','closed')),
  closed_by TEXT REFERENCES jm_accounts(id), closed_at TEXT
);
CREATE TABLE jm_privacy_requests (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES jm_accounts(id),
  kind TEXT NOT NULL CHECK(kind IN ('export','deletion')), created_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','closed'))
);
CREATE TABLE jm_file_metadata (
  id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES jm_profiles(id),
  category TEXT NOT NULL CHECK(category IN ('photo','identity_document')), sha256 TEXT NOT NULL,
  mime TEXT NOT NULL, staging_provider TEXT, state TEXT NOT NULL CHECK(state IN ('staged','copying','confirmed','failed','deleted')),
  access_policy TEXT NOT NULL CHECK(access_policy IN ('owner','admin')), confirmed_at TEXT, retain_until TEXT,
  deleted_at TEXT, created_at TEXT NOT NULL
);
CREATE TRIGGER jm_interest_changed AFTER UPDATE OF status ON jm_interests WHEN OLD.status<>NEW.status BEGIN
  INSERT INTO jm_interest_events VALUES(NEW.id || ':' || NEW.version,NEW.id,NEW.actor_id,NEW.status,NEW.reason,NEW.updated_at);
  INSERT INTO jm_outbox
    SELECT NEW.id || ':' || NEW.version || ':' || o.account_id,NEW.actor_id,NEW.id,'interest.' || NEW.status,
      o.account_id,NEW.updated_at,NULL FROM jm_ownership o
    WHERE o.profile_id IN (NEW.sender,NEW.recipient) AND o.authority='owner'
      AND (NEW.status NOT IN ('rejected','withdrawn','cancelled','expired') OR OLD.status<>'pending_admin_review' OR o.profile_id=NEW.sender);
END;
CREATE TRIGGER jm_interest_created AFTER INSERT ON jm_interests BEGIN
  INSERT INTO jm_interest_events VALUES(NEW.id || ':1',NEW.id,NEW.actor_id,NEW.status,NULL,NEW.created_at);
  INSERT INTO jm_outbox VALUES(NEW.id || ':created',NEW.actor_id,NEW.id,'interest.requested',NULL,NEW.created_at,NULL);
END;
CREATE TRIGGER jm_consent_added AFTER INSERT ON jm_consents BEGIN
  INSERT INTO jm_consent_events VALUES(lower(hex(randomblob(16))),NEW.interest_id,NEW.account_id,NEW.scope,'granted',NEW.granted_at);
END;
CREATE TRIGGER jm_consent_changed AFTER UPDATE ON jm_consents
WHEN OLD.revoked_at IS NOT NEW.revoked_at BEGIN
  INSERT INTO jm_consent_events VALUES(lower(hex(randomblob(16))),NEW.interest_id,NEW.account_id,NEW.scope,
    CASE WHEN NEW.revoked_at IS NULL THEN 'granted' ELSE 'revoked' END,COALESCE(NEW.revoked_at,NEW.granted_at));
END;


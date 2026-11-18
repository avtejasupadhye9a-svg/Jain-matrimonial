CREATE TABLE jm_profiles (
  id TEXT PRIMARY KEY, creator_id TEXT NOT NULL REFERENCES jm_accounts(id),
  claim_email TEXT COLLATE NOCASE, candidate_consent_at TEXT NOT NULL,
  consent_evidence TEXT, visible INTEGER NOT NULL DEFAULT 1 CHECK(visible IN (0,1)),
  suspended INTEGER NOT NULL DEFAULT 0 CHECK(suspended IN (0,1)),
  published_id TEXT REFERENCES jm_revisions(id), created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE jm_ownership (
  profile_id TEXT NOT NULL REFERENCES jm_profiles(id), account_id TEXT NOT NULL REFERENCES jm_accounts(id),
  authority TEXT NOT NULL CHECK(authority IN ('owner','delegate')),
  granted_at TEXT NOT NULL, PRIMARY KEY(profile_id,account_id)
);
CREATE UNIQUE INDEX jm_one_owner ON jm_ownership(profile_id) WHERE authority='owner';
CREATE INDEX jm_ownership_account ON jm_ownership(account_id,authority);
CREATE TABLE jm_drafts (
  profile_id TEXT PRIMARY KEY REFERENCES jm_profiles(id), data TEXT NOT NULL CHECK(json_valid(data)),
  version INTEGER NOT NULL, author TEXT NOT NULL REFERENCES jm_accounts(id), updated_at TEXT NOT NULL
);
CREATE TABLE jm_revisions (
  id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES jm_profiles(id),
  base_id TEXT REFERENCES jm_revisions(id), draft_version INTEGER NOT NULL,
  data TEXT NOT NULL CHECK(json_valid(data)), author TEXT NOT NULL REFERENCES jm_accounts(id),
  status TEXT NOT NULL CHECK(status IN ('pending_review','approved','rejected','changes_requested')),
  created_at TEXT NOT NULL, reviewer TEXT REFERENCES jm_accounts(id), reviewed_at TEXT, reason TEXT
);
CREATE UNIQUE INDEX jm_one_pending_revision ON jm_revisions(profile_id) WHERE status='pending_review';
CREATE INDEX jm_revision_queue ON jm_revisions(status,created_at,id);
CREATE INDEX jm_revision_history ON jm_revisions(profile_id,created_at DESC);
CREATE TABLE jm_claims (
  id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES jm_profiles(id), account_id TEXT NOT NULL REFERENCES jm_accounts(id),
  challenge_id TEXT NOT NULL UNIQUE REFERENCES jm_otp(id),
  status TEXT NOT NULL CHECK(status IN ('pending','approved','rejected')),
  created_at TEXT NOT NULL, reviewer TEXT REFERENCES jm_accounts(id), reviewed_at TEXT, reason TEXT
);
CREATE UNIQUE INDEX jm_pending_claim ON jm_claims(profile_id) WHERE status='pending';
CREATE TABLE jm_publication (
  profile_id TEXT PRIMARY KEY REFERENCES jm_profiles(id),
  revision_id TEXT NOT NULL UNIQUE REFERENCES jm_revisions(id), data TEXT NOT NULL CHECK(json_valid(data)),
  dob TEXT GENERATED ALWAYS AS (json_extract(data,'$.dob')) STORED,
  city TEXT GENERATED ALWAYS AS (json_extract(data,'$.city')) STORED COLLATE NOCASE,
  education TEXT GENERATED ALWAYS AS (json_extract(data,'$.qualification')) STORED COLLATE NOCASE,
  tradition TEXT GENERATED ALWAYS AS (json_extract(data,'$.tradition')) STORED COLLATE NOCASE,
  height INTEGER GENERATED ALWAYS AS (json_extract(data,'$.heightCm')) STORED,
  published_at TEXT NOT NULL
);
CREATE INDEX jm_public_city ON jm_publication(city, education, tradition, dob);
CREATE INDEX jm_public_dob ON jm_publication(dob);
CREATE INDEX jm_public_height ON jm_publication(height);
CREATE INDEX jm_public_recent ON jm_publication(published_at DESC,profile_id DESC);
CREATE TRIGGER jm_revision_submitted AFTER INSERT ON jm_revisions BEGIN
  INSERT INTO jm_outbox(id,actor_id,entity_id,action,created_at)
  VALUES(NEW.id || ':submit',NEW.author,NEW.profile_id,'profile.submitted',NEW.created_at);
END;
CREATE TRIGGER jm_revision_reviewed AFTER UPDATE OF status ON jm_revisions
WHEN OLD.status='pending_review' AND NEW.status<>'pending_review' BEGIN
  UPDATE jm_profiles SET published_id=NEW.id,updated_at=NEW.reviewed_at
    WHERE id=NEW.profile_id AND NEW.status='approved';
  INSERT INTO jm_publication(profile_id,revision_id,data,published_at)
    SELECT NEW.profile_id,NEW.id,NEW.data,NEW.reviewed_at WHERE NEW.status='approved'
    ON CONFLICT(profile_id) DO UPDATE SET revision_id=excluded.revision_id,data=excluded.data,published_at=excluded.published_at;
  INSERT INTO jm_outbox(id,actor_id,entity_id,action,account_id,created_at)
    VALUES(NEW.id || ':review',NEW.reviewer,NEW.profile_id,'profile.' || NEW.status,
      (SELECT account_id FROM jm_ownership WHERE profile_id=NEW.profile_id AND authority='owner'),NEW.reviewed_at);
END;
CREATE TRIGGER jm_claim_reviewed AFTER UPDATE OF status ON jm_claims
WHEN OLD.status='pending' AND NEW.status<>'pending' BEGIN
  INSERT INTO jm_ownership(profile_id,account_id,authority,granted_at)
    SELECT NEW.profile_id,NEW.account_id,'owner',NEW.reviewed_at WHERE NEW.status='approved';
  INSERT INTO jm_outbox(id,actor_id,entity_id,action,account_id,created_at)
    VALUES(NEW.id || ':review',NEW.reviewer,NEW.profile_id,'claim.' || NEW.status,NEW.account_id,NEW.reviewed_at);
END;
CREATE TRIGGER jm_claim_requested AFTER INSERT ON jm_claims BEGIN
  INSERT INTO jm_outbox(id,actor_id,entity_id,action,created_at)
    VALUES(NEW.id || ':request',NEW.account_id,NEW.profile_id,'claim.requested',NEW.created_at);
END;


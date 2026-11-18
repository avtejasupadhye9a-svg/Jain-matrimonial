CREATE TABLE jm_moderation_actions (
  id TEXT PRIMARY KEY, actor_id TEXT NOT NULL REFERENCES jm_accounts(id), entity_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('profile.suspended','profile.reactivated','account.suspended',
    'account.reactivated','report.closed','privacy.closed')),
  reason TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE INDEX jm_moderation_entity ON jm_moderation_actions(entity_id,created_at DESC,id);
CREATE TRIGGER jm_moderation_audit AFTER INSERT ON jm_moderation_actions BEGIN
  INSERT INTO jm_outbox(id,actor_id,entity_id,action,account_id,created_at)
    VALUES(NEW.id,NEW.actor_id,NEW.entity_id,NEW.kind,
      CASE WHEN NEW.kind IN ('account.suspended','account.reactivated') THEN NEW.entity_id END,NEW.created_at);
END;
ALTER TABLE jm_privacy_requests ADD COLUMN closed_by TEXT REFERENCES jm_accounts(id);
ALTER TABLE jm_privacy_requests ADD COLUMN closed_at TEXT;

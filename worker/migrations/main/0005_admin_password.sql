CREATE TABLE jm_admin_credentials (
  slot INTEGER PRIMARY KEY CHECK(slot=1),
  account_id TEXT NOT NULL UNIQUE REFERENCES jm_accounts(id),
  verifier TEXT NOT NULL CHECK(
    length(verifier)=151 AND substr(verifier,1,22)='pbkdf2-sha256-100k:v1:'
    AND substr(verifier,23,64) NOT GLOB '*[^0-9a-f]*'
    AND substr(verifier,87,1)=':' AND substr(verifier,88,64) NOT GLOB '*[^0-9a-f]*'
  ),
  version INTEGER NOT NULL CHECK(version>=1),
  changed_at TEXT NOT NULL
);

CREATE TABLE jm_admin_session_versions (
  session_id TEXT PRIMARY KEY REFERENCES jm_sessions(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  version INTEGER NOT NULL CHECK(version>=1)
);

-- The owner may reuse an existing administrator or provision the first one.
CREATE TRIGGER jm_admin_install_once BEFORE INSERT ON jm_admin_credentials
WHEN EXISTS(SELECT 1 FROM jm_admin_credentials WHERE slot=1)
BEGIN
  SELECT RAISE(ABORT,'Administrator credential is already configured');
END;

CREATE TRIGGER jm_admin_preserve_credential BEFORE DELETE ON jm_admin_credentials
BEGIN
  SELECT RAISE(ABORT,'Administrator credential cannot be deleted');
END;

CREATE TRIGGER jm_admin_install_account BEFORE INSERT ON jm_admin_credentials
WHEN NOT EXISTS(SELECT 1 FROM jm_accounts WHERE id=NEW.account_id AND role='admin' AND status='active')
BEGIN
  INSERT INTO jm_accounts(id,email,role,verified_at,created_at)
    SELECT NEW.account_id,'jain-matrimonial-admin@internal.invalid','admin',NEW.changed_at,NEW.changed_at
    WHERE NOT EXISTS(SELECT 1 FROM jm_accounts WHERE role='admin');
  SELECT CASE WHEN NOT EXISTS(
    SELECT 1 FROM jm_accounts WHERE id=NEW.account_id AND role='admin' AND status='active'
  ) THEN RAISE(ABORT,'Select an existing active administrator') END;
END;

CREATE TRIGGER jm_admin_session_gate BEFORE INSERT ON jm_sessions
WHEN EXISTS(SELECT 1 FROM jm_accounts WHERE id=NEW.account_id AND role='admin')
  AND NOT EXISTS(SELECT 1 FROM jm_admin_credentials c JOIN jm_admin_session_versions v ON v.version=c.version
    WHERE c.slot=1 AND c.account_id=NEW.account_id AND v.session_id=NEW.id)
BEGIN
  SELECT RAISE(ABORT,'An administrator password session is required');
END;

CREATE TRIGGER jm_admin_bootstrapped AFTER INSERT ON jm_admin_credentials
BEGIN
  UPDATE jm_sessions SET revoked_at=unixepoch()
    WHERE revoked_at IS NULL AND account_id IN (SELECT id FROM jm_accounts WHERE role='admin');
  INSERT INTO jm_outbox(id,actor_id,entity_id,action,created_at)
    VALUES(NEW.account_id || ':password-initialized',NEW.account_id,NEW.account_id,'admin.password_initialized',NEW.changed_at);
END;

CREATE TRIGGER jm_admin_password_changed AFTER UPDATE OF version ON jm_admin_credentials
WHEN NEW.version<>OLD.version
BEGIN
  UPDATE jm_sessions SET revoked_at=unixepoch()
    WHERE account_id=NEW.account_id AND revoked_at IS NULL;
  INSERT INTO jm_outbox(id,actor_id,entity_id,action,created_at)
    VALUES(NEW.account_id || ':password:' || NEW.version,NEW.account_id,NEW.account_id,'admin.password_changed',NEW.changed_at);
END;

CREATE TRIGGER jm_admin_password_version_guard BEFORE UPDATE ON jm_admin_credentials
WHEN NEW.slot<>OLD.slot OR NEW.account_id<>OLD.account_id OR NEW.version<>OLD.version+1 OR NEW.verifier=OLD.verifier
BEGIN
  SELECT RAISE(ABORT,'Administrator identity is fixed and the credential version must advance');
END;

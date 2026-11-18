import { Actor, Env, JsonObject, audit, bool, change, choice, conflict, email, listing, now, object, page, rows, statement, str, uid, unix } from './core';
import { AuthContext, mailConfigured, sendMail, verifyCode } from './auth';

interface Outbox {
  id: string; actor_id: string | null; entity_id: string; action: string;
  account_id: string | null; created_at: string;
}

export async function reconcile(env: Env) {
  const events = await rows<Outbox>(env.DB_MAIN, `SELECT id,actor_id,entity_id,action,account_id,created_at
    FROM jm_outbox WHERE processed_at IS NULL ORDER BY created_at,id LIMIT 50`);
  for (const event of events) {
    const ops = env.DB_OPERATIONS;
    const updates = [statement(ops, 'INSERT OR IGNORE INTO jm_audit VALUES(?,?,?,?,?)',
      event.id, event.actor_id, event.entity_id, event.action, event.created_at)];
    if (event.account_id) {
      updates.push(statement(ops, 'INSERT OR IGNORE INTO jm_notifications VALUES(?,?,?,?,?,NULL)',
        event.id, event.account_id, event.action, event.entity_id, event.created_at));
      updates.push(statement(ops, `INSERT OR IGNORE INTO jm_email_jobs(id,account_id,kind,status,next_at)
        VALUES(?,?,?,'pending',?)`, event.id, event.account_id, event.action, unix()));
    }
    await ops.batch(updates);
    await change(env.DB_MAIN, 'UPDATE jm_outbox SET processed_at=? WHERE id=? AND processed_at IS NULL', now(), event.id);
  }
  return events.length;
}

const mailLabels: Record<string, string> = {
  'profile.approved': 'Your profile submission was approved.',
  'profile.rejected': 'Your profile submission was declined.',
  'profile.changes_requested': 'Your profile submission needs changes.',
  'claim.approved': 'Your profile claim was approved.',
  'claim.rejected': 'Your profile claim was declined.',
  'account.email_changed': 'Your sign-in email changed.',
};

interface MailJob { id: string; account_id: string; kind: string; attempts: number }
export async function deliverEmails(env: Env, sender: typeof fetch = fetch) {
  if (!mailConfigured(env)) return;
  const ops = env.DB_OPERATIONS;
  const jobs = await rows<MailJob>(ops, `SELECT id,account_id,kind,attempts FROM jm_email_jobs
    WHERE status IN ('pending','sending') AND next_at<=? ORDER BY next_at,id LIMIT 20`, unix());
  for (const job of jobs) {
    const lease = uid();
    const time = unix();
    const acquired = await change(ops, `UPDATE jm_email_jobs SET status='sending',next_at=?,lease=?
      WHERE id=? AND next_at<=? AND status IN ('pending','sending')`, time + 90, lease, job.id, time);
    if (!acquired) continue;
    const account = await statement(env.DB_MAIN, "SELECT email FROM jm_accounts WHERE id=? AND status='active'", job.account_id)
      .first<{ email: string }>();
    let status = 'skipped';
    let error: string | null = null;
    if (account) {
      try {
        await sendMail(env, account.email, 'Jain Matrimonial update',
          (mailLabels[job.kind] ?? 'You have an update in Jain Matrimonial.') + ' Sign in to see details.', job.id, sender);
        status = 'sent';
      } catch {
        error = 'provider_error';
        status = job.attempts + 1 >= 6 ? 'failed' : 'pending';
      }
    }
    await change(ops, 'UPDATE jm_email_jobs SET status=?,attempts=attempts+1,next_at=?,last_error=?,lease=NULL WHERE id=? AND lease=?',
      status, time + Math.min(3600, 60 * 2 ** job.attempts), error, job.id, lease);
  }
}

export async function notificationList(env: Env, actor: Actor, url: URL) {
  const { limit, offset } = page(url);
  const db = env.DB_OPERATIONS;
  const [items, unread] = await Promise.all([
    rows(db, `SELECT id,kind,entity_id AS entityId,created_at AS createdAt,read_at AS readAt
      FROM jm_notifications WHERE account_id=? ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?`, actor.id, limit + 1, offset),
    statement(db, 'SELECT count(*) AS count FROM jm_notifications WHERE account_id=? AND read_at IS NULL', actor.id).first<{ count: number }>(),
  ]);
  return { ...listing(items, limit, offset), unread: unread?.count ?? 0 };
}

export async function readNotification(env: Env, actor: Actor, id: string) {
  await change(env.DB_OPERATIONS, 'UPDATE jm_notifications SET read_at=? WHERE id=? AND account_id=? AND read_at IS NULL', now(), id, actor.id);
  return {};
}

export async function privacyRequest(context: AuthContext, actor: Actor, input: JsonObject) {
  const kind = choice(input.kind, 'kind', ['export', 'deletion']);
  await verifyCode(context, input, 'security', actor.email);
  const id = uid();
  const db = context.env.DB_MAIN;
  await db.batch([
    statement(db, 'INSERT INTO jm_privacy_requests(id,account_id,kind,created_at) VALUES(?,?,?,?)', id, actor.id, kind, now()),
    audit(db, actor, id, 'privacy.requested'),
  ]);
  return { id, status: 'open' };
}

export async function changeEmail(context: AuthContext, actor: Actor, input: JsonObject) {
  const address = email(input.email);
  await verifyCode(context, object(input.current), 'security', actor.email);
  await verifyCode(context, object(input.next), 'email_change', address);
  const db = context.env.DB_MAIN;
  const time = now();
  const event = uid();
  const result = await db.batch([
    statement(db, `INSERT INTO jm_outbox(id,actor_id,entity_id,action,account_id,created_at)
      SELECT ?,id,id,'account.email_changed',id,? FROM jm_accounts WHERE id=? AND email=? AND status='active'
      AND NOT EXISTS(SELECT 1 FROM jm_accounts WHERE email=?)`, event, time, actor.id, actor.email, address),
    statement(db, `UPDATE jm_accounts SET email=?,verified_at=?
      WHERE id=? AND EXISTS(SELECT 1 FROM jm_outbox WHERE id=?)`, address, time, actor.id, event),
    statement(db, `UPDATE jm_sessions SET revoked_at=? WHERE account_id=? AND revoked_at IS NULL
      AND EXISTS(SELECT 1 FROM jm_outbox WHERE id=?)`, unix(), actor.id, event),
    statement(db, `UPDATE jm_consents SET revoked_at=? WHERE account_id=? AND revoked_at IS NULL
      AND EXISTS(SELECT 1 FROM jm_outbox WHERE id=?)`, time, actor.id, event),
  ]);
  if (!result[1].meta.changes) return conflict();
  return { signInAgain: true };
}

export async function setAccountStatus(env: Env, actor: Actor, id: string, input: JsonObject) {
  const suspended = bool(input.suspended, 'suspended');
  str(input.reason, 'reason', 700);
  const db = env.DB_MAIN;
  const status = suspended ? 'suspended' : 'active';
  const result = await db.batch([
    statement(db, `INSERT INTO jm_outbox(id,actor_id,entity_id,action,account_id,created_at)
      SELECT ?,?,id,?,id,? FROM jm_accounts WHERE id=? AND role='customer' AND status IN ('active','suspended')`,
      uid(), actor.id, suspended ? 'account.suspended' : 'account.reactivated', now(), id),
    statement(db, "UPDATE jm_accounts SET status=? WHERE id=? AND role='customer' AND status IN ('active','suspended')", status, id),
    statement(db, `UPDATE jm_sessions SET revoked_at=? WHERE account_id=? AND revoked_at IS NULL
      AND EXISTS(SELECT 1 FROM jm_accounts WHERE id=? AND role='customer' AND status='suspended')`, unix(), id, id),
  ]);
  if (!result[1].meta.changes) return conflict();
  return { status };
}

const adminQueries = {
  profiles: `SELECT p.id,json_extract(d.data,'$.name') AS name,p.visible,p.suspended,p.updated_at AS updatedAt,
    p.published_id AS publishedId FROM jm_profiles p JOIN jm_drafts d ON d.profile_id=p.id
    WHERE (? IS NULL OR p.id=? OR instr(lower(json_extract(d.data,'$.name')),lower(?))>0) ORDER BY p.updated_at DESC,p.id DESC`,
  revisions: `SELECT r.id,r.profile_id AS profileId,r.status,r.created_at AS createdAt,
    json_extract(r.data,'$.name') AS name FROM jm_revisions r
    WHERE r.status='pending_review' ORDER BY r.created_at,r.id`,
  claims: `SELECT c.id,c.profile_id AS profileId,c.created_at AS createdAt,c.status,a.email,p.consent_evidence AS consentEvidence
    FROM jm_claims c JOIN jm_profiles p ON p.id=c.profile_id JOIN jm_accounts a ON a.id=c.account_id
    WHERE c.status='pending' ORDER BY c.created_at,c.id`,
  accounts: `SELECT id,email,status,role,created_at AS createdAt FROM jm_accounts
    WHERE (? IS NULL OR id=? OR instr(lower(email),lower(?))>0) ORDER BY created_at DESC,id DESC`,
  reports: `SELECT id,reporter_id AS reporterId,profile_id AS profileId,reason,status,created_at AS createdAt
    FROM jm_reports ORDER BY status DESC,created_at DESC,id DESC`,
  blocks: `SELECT account_id AS accountId,blocked_id AS blockedId,created_at AS createdAt
    FROM jm_blocks ORDER BY created_at DESC,account_id,blocked_id`,
  'privacy-requests': `SELECT id,account_id AS accountId,kind,status,created_at AS createdAt
    FROM jm_privacy_requests ORDER BY status DESC,created_at DESC,id DESC`,
  audit: 'SELECT id,actor_id AS actorId,entity_id AS entityId,action,created_at AS createdAt FROM jm_audit ORDER BY created_at DESC,id DESC',
} as const;

export type AdminQueue = keyof typeof adminQueries;
export const adminQueues = Object.keys(adminQueries) as AdminQueue[];

export async function adminList(env: Env, url: URL, type: AdminQueue) {
  const { limit, offset } = page(url);
  const text = url.searchParams.get('q');
  const search = text ? str(text, 'q', 150) : null;
  const searched = type === 'profiles' || type === 'accounts';
  const items = await rows(type === 'audit' ? env.DB_OPERATIONS : env.DB_MAIN,
    adminQueries[type] + ' LIMIT ? OFFSET ?', ...(searched ? [search, search, search] : []), limit + 1, offset);
  return listing(items, limit, offset);
}

export async function closeReport(env: Env, actor: Actor, id: string, input: JsonObject) {
  str(input.reason, 'reason', 700);
  const db = env.DB_MAIN;
  const result = await db.batch([
    statement(db, `INSERT INTO jm_outbox(id,actor_id,entity_id,action,created_at)
      SELECT ?,?,id,'report.closed',? FROM jm_reports WHERE id=? AND status='open'`, uid(), actor.id, now(), id),
    statement(db, "UPDATE jm_reports SET status='closed',closed_by=?,closed_at=? WHERE id=? AND status='open'", actor.id, now(), id),
  ]);
  if (!result[1].meta.changes) return conflict();
  return { status: 'closed' };
}

export async function dashboard(env: Env) {
  return statement(env.DB_MAIN, `SELECT
    (SELECT count(*) FROM jm_accounts WHERE role='customer' AND status='active') AS accounts,
    (SELECT count(*) FROM jm_revisions WHERE status='pending_review') AS revisions,
    (SELECT count(*) FROM jm_claims WHERE status='pending') AS claims,
    (SELECT count(*) FROM jm_interests WHERE status IN ('pending_admin_review','pending_contact_authorization')) AS interests,
    (SELECT count(*) FROM jm_reports WHERE status='open') AS reports,
    (SELECT count(*) FROM jm_privacy_requests WHERE status='open') AS privacyRequests`).first();
}



import { Actor, Env, JsonObject, audit, bool, change, choice, conflict, forbidden, identifier, integer, listing, missing, now, page, rows, statement, str, uid } from './core';
import { publicDetail } from './discovery';

const relation = `FROM jm_interests i
  JOIN jm_ownership so ON so.profile_id=i.sender AND so.authority='owner'
  JOIN jm_ownership ro ON ro.profile_id=i.recipient AND ro.authority='owner'`;
const eligibility = `EXISTS(SELECT 1 FROM jm_profiles sp JOIN jm_profiles rp ON rp.id=i.recipient
    JOIN jm_accounts sa ON sa.id=so.account_id JOIN jm_accounts ra ON ra.id=ro.account_id
    WHERE sp.id=i.sender AND sp.visible=1 AND rp.visible=1 AND sp.suspended=0 AND rp.suspended=0
    AND sp.published_id IS NOT NULL AND rp.published_id IS NOT NULL AND sa.status='active' AND ra.status='active')
  AND NOT EXISTS(SELECT 1 FROM jm_blocks b WHERE
    (b.account_id=so.account_id AND b.blocked_id=ro.account_id) OR
    (b.account_id=ro.account_id AND b.blocked_id=so.account_id))`;
const mutual = `(SELECT count(*) FROM jm_consents c WHERE c.interest_id=i.id AND c.revoked_at IS NULL
    AND c.scope='verified_email' AND c.account_id IN (so.account_id,ro.account_id))=2`;
const fields = `i.id,i.sender,i.recipient,i.status,i.version,i.updated_at AS updatedAt,i.expires_at AS expiresAt`;

export async function sendInterest(env: Env, actor: Actor, data: JsonObject) {
  const target = identifier(data.recipient, 'recipient');
  const sender = identifier(data.sender, 'sender');
  const time = now();
  const expiration = new Date(Date.now() + 30 * 86400000).toISOString();
  const pair = [sender, target].sort().join(':');
  const result = await statement(env.DB_MAIN, `INSERT OR IGNORE INTO jm_interests
    (id,sender,recipient,pair,actor_id,status,created_at,updated_at,expires_at)
    SELECT ?,i.sender,i.recipient,?,?,'pending_admin_review',?,?,? FROM (SELECT ? AS sender,? AS recipient) i
    JOIN jm_ownership so ON so.profile_id=i.sender AND so.authority='owner'
    JOIN jm_ownership ro ON ro.profile_id=i.recipient AND ro.authority='owner'
    WHERE so.account_id=? AND ro.account_id<>so.account_id AND ${eligibility}
    RETURNING id,status,version`, uid(), pair, actor.id, time, time, expiration, sender, target, actor.id).first();
  return result ?? conflict();
}

export async function interests(env: Env, actor: Actor, url: URL) {
  const { limit, offset } = page(url);
  const statusParam = url.searchParams.get('status');
  const statuses = ['pending_admin_review', 'pending_recipient', 'rejected', 'declined', 'pending_contact_authorization',
    'authorized', 'withdrawn', 'cancelled', 'expired'] as const;
  const status = statusParam ? choice(statusParam, 'status', statuses) : null;
  const admin = actor.role === 'admin';
  const result = await rows(env.DB_MAIN, `SELECT ${fields},
    CASE WHEN so.account_id=? THEN 'sent' WHEN ro.account_id=? THEN 'received' ELSE 'administration' END AS direction,
    (SELECT count(*) FROM jm_consents c WHERE c.interest_id=i.id AND c.revoked_at IS NULL
      AND c.account_id IN (so.account_id,ro.account_id) AND (?=1 OR c.account_id=?)) AS activeConsents,
    CASE WHEN ?=1 THEN i.reason ELSE NULL END AS reviewReason
    ${relation} WHERE (? IS NULL OR i.status=?) AND (?=1 OR so.account_id=? OR
      (ro.account_id=? AND EXISTS(SELECT 1 FROM jm_interest_events e WHERE e.interest_id=i.id AND e.status='pending_recipient')))
    ORDER BY i.updated_at DESC,i.id DESC LIMIT ? OFFSET ?`,
    actor.id, actor.id, Number(admin), actor.id, Number(admin), status, status, Number(admin), actor.id, actor.id, limit + 1, offset);
  return listing(result, limit, offset);
}

const transitions = {
  admin_approve: { from: ['pending_admin_review'], to: 'pending_recipient', who: 'admin' },
  admin_reject: { from: ['pending_admin_review'], to: 'rejected', who: 'admin' },
  accept: { from: ['pending_recipient'], to: 'pending_contact_authorization', who: 'recipient' },
  decline: { from: ['pending_recipient'], to: 'declined', who: 'recipient' },
  authorize: { from: ['pending_contact_authorization'], to: 'authorized', who: 'admin' },
  withdraw: { from: ['pending_admin_review', 'pending_recipient', 'pending_contact_authorization', 'authorized'], to: 'withdrawn', who: 'sender' },
  cancel: { from: ['pending_admin_review', 'pending_recipient', 'pending_contact_authorization', 'authorized'], to: 'cancelled', who: 'admin' },
} as const;

export async function transition(env: Env, actor: Actor, id: string, data: JsonObject) {
  const action = choice(data.action, 'action', Object.keys(transitions) as (keyof typeof transitions)[]);
  const rule = transitions[action];
  if ((rule.who === 'admin') !== (actor.role === 'admin')) return forbidden();
  const version = integer(data.version, 'version', 1, 2147483646);
  const reason = rule.who === 'admin' ? str(data.reason, 'reason', 700) : null;
  const time = now();
  const who = rule.who === 'sender' ? 'so.account_id=?' : rule.who === 'recipient' ? 'ro.account_id=?' : '1';
  const progresses = ['admin_approve', 'accept', 'authorize'].includes(action);
  const result = await statement(env.DB_MAIN, `UPDATE jm_interests SET status=?,version=version+1,actor_id=?,reason=?,updated_at=?
    WHERE id=? AND version=? AND status IN (${rule.from.map(() => '?').join(',')})
    AND EXISTS(SELECT 1 ${relation} WHERE i.id=jm_interests.id AND ${who}
      ${progresses ? 'AND i.expires_at>? AND ' + eligibility : ''}
      ${action === 'authorize' ? 'AND ' + mutual : ''})
    RETURNING id,status,version`, rule.to, actor.id, reason, time, id, version, ...rule.from,
    ...(rule.who === 'admin' ? [] : [actor.id]), ...(progresses ? [time] : [])).first();
  if (result) return result;
  return await statement(env.DB_MAIN, `SELECT i.id,i.status,i.version ${relation} WHERE i.id=? AND i.status=?
    AND i.version=? AND i.actor_id=? AND i.reason IS ? AND ${who}`, id, rule.to, version + 1, actor.id, reason,
    ...(rule.who === 'admin' ? [] : [actor.id])).first() ?? conflict();
}

export async function consent(env: Env, actor: Actor, id: string, data: JsonObject) {
  const granted = bool(data.granted, 'granted');
  const time = now();
  const db = env.DB_MAIN;
  const clause = `EXISTS(SELECT 1 ${relation} WHERE i.id=? AND ? IN (so.account_id,ro.account_id))`;
  if (!granted) {
    if (!await statement(db, 'SELECT 1 WHERE ' + clause, id, actor.id).first()) return missing();
    await change(db, 'UPDATE jm_consents SET revoked_at=? WHERE interest_id=? AND account_id=? AND revoked_at IS NULL', time, id, actor.id);
  } else {
    const result = await statement(db, `INSERT INTO jm_consents (interest_id,account_id,scope,granted_at)
      SELECT i.id,?,'verified_email',? ${relation} WHERE i.id=? AND ? IN (so.account_id,ro.account_id)
      AND i.status='pending_contact_authorization' AND i.expires_at>? AND ${eligibility}
      ON CONFLICT(interest_id,account_id) DO UPDATE SET revoked_at=NULL,granted_at=excluded.granted_at
        WHERE jm_consents.revoked_at IS NOT NULL RETURNING interest_id`, actor.id, time, id, actor.id, time).first();
    if (!result && !await statement(db, 'SELECT 1 FROM jm_consents WHERE interest_id=? AND account_id=? AND revoked_at IS NULL',
      id, actor.id).first()) return conflict();
  }
  return { granted, scope: 'verified_email' };
}

export async function contact(env: Env, actor: Actor, id: string) {
  const result = await statement(env.DB_MAIN, `SELECT a.email ${relation} JOIN jm_accounts a ON a.id=
    CASE WHEN so.account_id=? THEN ro.account_id ELSE so.account_id END
    WHERE i.id=? AND ? IN (so.account_id,ro.account_id) AND i.status='authorized'
      AND i.expires_at>? AND ${mutual} AND ${eligibility}`, actor.id, id, actor.id, now()).first<{ email: string }>();
  return result ?? missing();
}

export async function block(env: Env, actor: Actor, target: string, enabled: boolean) {
  const db = env.DB_MAIN;
  if (enabled) {
    await publicDetail(env, actor, target);
    await db.batch([
      statement(db, `INSERT OR IGNORE INTO jm_blocks SELECT ?,account_id,? FROM jm_ownership
        WHERE profile_id=? AND authority='owner' AND account_id<>?`, actor.id, now(), target, actor.id),
      audit(db, actor, target, 'privacy.blocked'),
    ]);
  } else {
    await db.batch([
      statement(db, "DELETE FROM jm_blocks WHERE account_id=? AND blocked_id IN (SELECT account_id FROM jm_ownership WHERE profile_id=? AND authority='owner')",
        actor.id, target), audit(db, actor, target, 'privacy.unblocked'),
    ]);
  }
  return { blocked: enabled };
}

export async function report(env: Env, actor: Actor, input: JsonObject) {
  const profile = identifier(input.profileId, 'profileId');
  await publicDetail(env, actor, profile);
  const id = uid();
  const db = env.DB_MAIN;
  await db.batch([
    statement(db, 'INSERT INTO jm_reports(id,reporter_id,profile_id,reason,created_at) VALUES(?,?,?,?,?)',
      id, actor.id, profile, str(input.reason, 'reason', 1000), now()),
    audit(db, actor, id, 'report.opened'),
  ]);
  return { id };
}

export async function expireInterests(env: Env) {
  const time = now();
  await change(env.DB_MAIN, `UPDATE jm_interests SET status='expired',version=version+1,updated_at=?,reason=NULL
    WHERE status IN ('pending_admin_review','pending_recipient','pending_contact_authorization','authorized') AND expires_at<=?`, time, time);
}


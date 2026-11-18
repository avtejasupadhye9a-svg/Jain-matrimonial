import { Actor, Env, JsonObject, conflict, listing, now, page, rows, statement, str, uid } from './core';

export async function closePrivacyRequest(env: Env, actor: Actor, id: string, input: JsonObject) {
  const reason = str(input.reason, 'reason', 700);
  const time = now();
  const db = env.DB_MAIN;
  const result = await db.batch([
    statement(
      db,
      `INSERT INTO jm_moderation_actions
      SELECT ?,?,id,'privacy.closed',?,? FROM jm_privacy_requests WHERE id=? AND status='open'`,
      uid(),
      actor.id,
      reason,
      time,
      id,
    ),
    statement(
      db,
      "UPDATE jm_privacy_requests SET status='closed',closed_by=?,closed_at=? WHERE id=? AND status='open'",
      actor.id,
      time,
      id,
    ),
  ]);
  if (!result[1].meta.changes) return conflict();
  return { status: 'closed' };
}

export async function privacyRequests(env: Env, actor: Actor, url: URL) {
  const { limit, offset } = page(url);
  const found = await rows(
    env.DB_MAIN,
    `SELECT id,kind,status,created_at AS createdAt,closed_at AS closedAt
    FROM jm_privacy_requests WHERE account_id=? ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?`,
    actor.id,
    limit + 1,
    offset,
  );
  return listing(found, limit, offset);
}

export async function ownClaims(env: Env, actor: Actor, url: URL) {
  const { limit, offset } = page(url);
  const found = await rows(
    env.DB_MAIN,
    `SELECT id,profile_id AS profileId,status,created_at AS createdAt,reviewed_at AS reviewedAt
    FROM jm_claims WHERE account_id=? ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?`,
    actor.id,
    limit + 1,
    offset,
  );
  return listing(found, limit, offset);
}

export async function moderationHistory(env: Env, id: string) {
  return {
    items: await rows(
      env.DB_MAIN,
      `SELECT id,actor_id AS actorId,kind,reason,created_at AS createdAt FROM jm_moderation_actions
    WHERE entity_id=? ORDER BY created_at DESC,id DESC LIMIT 30`,
      id,
    ),
  };
}

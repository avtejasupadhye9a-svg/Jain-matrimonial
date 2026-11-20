import {
  Actor,
  Env,
  JsonObject,
  Failure,
  statement,
  rows,
  change,
  unix,
  now,
  keyed,
  digest,
  same,
  identifier,
  conflict,
  forbidden,
  audit,
} from './core';
import { transport } from './origin';
import { b2Transport } from './b2';

interface Control {
  primary_id: string | null;
  generation: number;
  paused: number;
  lease_until: number;
}
interface Enrollment {
  id: string;
  commitment: string;
  machine: string;
  actor_id: string;
  session_id: string;
  generation: number;
  expires: number;
  claimed: number;
  cursor: string;
  activated: number;
}
function enabled(env: Env) {
  if (env.MANAGED_STORAGE_ENABLED !== 'true')
    throw new Failure(503, 'management_disabled', 'Storage management awaits owner activation.');
}
const control = (env: Env) =>
  statement(env.DB_MAIN, 'SELECT * FROM jm_origin_control WHERE slot=1').first<Control>();
const entry = (env: Env, id: string) =>
  statement(env.DB_MAIN, 'SELECT * FROM jm_origin_enrollments WHERE id=?', id).first<Enrollment>();
const credential = (env: Env, e: Enrollment) => keyed(env, 'storage-origin-v1/' + e.id + '/' + e.commitment);
async function scoped(env: Env, e: Enrollment) {
  return {
    ...env,
    STORAGE_ORIGIN_ID: e.id,
    STORAGE_ORIGIN_TOKEN: await credential(env, e),
    ORIGIN_SIGNED: true,
  };
}
export async function active(env: Env) {
  if (env.MANAGED_STORAGE_ENABLED !== 'true') return env;
  const c = await control(env);
  const e = c?.primary_id && !c.paused ? await entry(env, c.primary_id) : null;
  return e ? scoped(env, e) : { ...env, STORAGE_ORIGIN_ID: undefined, STORAGE_ORIGIN_TOKEN: undefined };
}
export async function enroll(env: Env, actor: Actor, input: JsonObject) {
  enabled(env);
  if (actor.role !== 'admin') return forbidden();
  const commitment = String(input.commitment),
    machine = String(input.machine);
  if (!/^[0-9a-f]{64}$/.test(commitment) || !/^[A-Za-z0-9_.-]{1,63}$/.test(machine))
    throw new Failure(400, 'identity', 'Invalid PC identity.');
  const c = await control(env);
  if (!c || (c.primary_id && !c.paused)) return conflict();
  const id = crypto.randomUUID();
  await env.DB_MAIN.batch([
    statement(
      env.DB_MAIN,
      'INSERT INTO jm_origin_enrollments(id,machine,commitment,actor_id,session_id,generation,expires) VALUES(?,?,?,?,?,?,?)',
      id,
      machine,
      commitment,
      actor.id,
      actor.sessionId,
      c.generation,
      unix() + 300,
    ),
    audit(env.DB_MAIN, actor, id, 'storage.enrollment_requested'),
  ]);
  return { id };
}
export async function claim(env: Env, input: JsonObject) {
  enabled(env);
  const id = identifier(input.id),
    seed = String(input.seed);
  if (!/^[a-f0-9]{64}$/.test(seed)) return forbidden();
  const e = await entry(env, id);
  if (!e || !same(e.commitment, await digest(seed))) return forbidden();
  const ok = await change(
    env.DB_MAIN,
    `UPDATE jm_origin_enrollments SET claimed=1,expires=? WHERE id=? AND claimed=0 AND expires>? AND generation=(SELECT generation FROM jm_origin_control) AND EXISTS(SELECT 1 FROM jm_sessions s JOIN jm_accounts a ON a.id=s.account_id WHERE s.id=session_id AND s.revoked_at IS NULL AND a.role='admin' AND a.status='active' AND s.access_until>?)`,
    unix() + 86400,
    id,
    unix(),
    unix(),
  );
  if (!ok) return forbidden();
  return {
    id,
    credential: await credential(env, e),
    connector: input.connectorNeeded === true ? env.STORAGE_CONNECTOR_TOKEN : undefined,
  };
}
export async function promote(env: Env, actor: Actor, input: JsonObject) {
  enabled(env);
  if (actor.role !== 'admin') return forbidden();
  const id = identifier(input.id);
  const e = await entry(env, id),
    c = await control(env);
  if (c?.primary_id === id && !c.paused) return { complete: true };
  if (
    !e ||
    !c ||
    !e.claimed ||
    e.activated ||
    e.expires <= unix() ||
    e.actor_id !== actor.id ||
    e.generation !== c.generation ||
    (c.primary_id && !c.paused) ||
    c.lease_until > unix()
  )
    return conflict();
  const send = transport({ ...(await scoped(env, e)), FILE_TRANSFER_ENABLED: 'true' });
  if (!send) throw new Failure(503, 'vpc_missing', 'The private Worker binding is unavailable.');
  const health = await send('/health').catch(() => null);
  await health?.body?.cancel();
  if (health?.status !== 200)
    throw new Failure(
      503,
      'private_path',
      'The replacement PC has not answered through the existing private tunnel.',
    );
  const files = await rows<{ id: string; sha256: string; category: string }>(
    env.DB_MAIN,
    "SELECT id,sha256,category FROM jm_file_metadata WHERE state='confirmed' AND deleted_at IS NULL AND id>? ORDER BY id LIMIT 5",
    e.cursor,
  );
  for (const f of files) {
    const r = await send((f.category === 'photo' ? '/photos/' : '/objects/') + f.id);
    if (!r.ok) {
      await r.body?.cancel();
      return conflict();
    }
    const m = await r.json<{ sha256: string; id: string }>();
    if (m.id !== f.id || m.sha256 !== f.sha256)
      throw new Failure(
        409,
        'restore_required',
        'Restore the verified backup on the replacement PC before continuing.',
      );
  }
  if (files.length) {
    await change(
      env.DB_MAIN,
      'UPDATE jm_origin_enrollments SET cursor=? WHERE id=? AND cursor=?',
      files[files.length - 1].id,
      id,
      e.cursor,
    );
    return { complete: false };
  }
  const results = await env.DB_MAIN.batch([
    statement(
      env.DB_MAIN,
      'UPDATE jm_origin_control SET primary_id=?,generation=generation+1,paused=0 WHERE slot=1 AND generation=? AND lease_until<=? AND (primary_id IS NULL OR paused=1)',
      id,
      e.generation,
      unix(),
    ),
    statement(
      env.DB_MAIN,
      'UPDATE jm_origin_enrollments SET activated=1 WHERE id=? AND EXISTS(SELECT 1 FROM jm_origin_control WHERE primary_id=?)',
      id,
      id,
    ),
    statement(
      env.DB_MAIN,
      "INSERT OR IGNORE INTO jm_outbox(id,actor_id,entity_id,action,created_at) SELECT ?,?,?, 'storage.primary_activated',? WHERE EXISTS(SELECT 1 FROM jm_origin_control WHERE primary_id=?)",
      id + ':activated',
      actor.id,
      id,
      now(),
      id,
    ),
  ]);
  if (!results[0].meta.changes) return conflict();
  return { complete: true };
}
export async function transition(env: Env, actor: Actor, input: JsonObject) {
  enabled(env);
  if (actor.role !== 'admin') return forbidden();
  const action = String(input.action);
  const c = await control(env);
  if (!c || input.generation !== c.generation) return conflict();
  if (action === 'retry') {
    await env.DB_MAIN.batch([
      statement(
        env.DB_MAIN,
        'UPDATE jm_storage_transfers SET next_attempt=0 WHERE cleaned_at IS NULL AND last_error IS NOT NULL AND (SELECT lease_until FROM jm_origin_control)<=?',
        unix(),
      ),
      audit(env.DB_MAIN, actor, 'storage', 'storage.retry'),
    ]);
    return {};
  }
  if (!['pause', 'resume', 'revoke'].includes(action) || !c.primary_id) return conflict();
  const results = await env.DB_MAIN.batch([
    statement(
      env.DB_MAIN,
      'UPDATE jm_origin_control SET paused=?,primary_id=CASE WHEN ?=1 THEN NULL ELSE primary_id END,generation=generation+1 WHERE slot=1 AND generation=? AND lease_until<=?',
      action === 'pause' ? 1 : 0,
      action === 'revoke' ? 1 : 0,
      c.generation,
      unix(),
    ),
    statement(
      env.DB_MAIN,
      'INSERT INTO jm_outbox(id,actor_id,entity_id,action,created_at) SELECT ?,?,?,?,? WHERE changes()=1',
      crypto.randomUUID(),
      actor.id,
      c.primary_id,
      'storage.' + action,
      now(),
    ),
  ]);
  if (!results[0].meta.changes) return conflict();
  return {};
}
export async function status(env: Env) {
  enabled(env);
  const c = await control(env);
  const e = c?.primary_id ? await entry(env, c.primary_id) : null;
  const aggregate = await statement(
    env.DB_MAIN,
    'SELECT count(CASE WHEN cleaned_at IS NULL THEN 1 END) pending,count(cleaned_at) completed,count(CASE WHEN last_error IS NOT NULL AND cleaned_at IS NULL THEN 1 END) failed,coalesce(sum(CASE WHEN cleaned_at IS NULL THEN bytes END),0) stagedBytes FROM jm_storage_transfers',
  ).first();
  const last = await statement(
    env.DB_MAIN,
    'SELECT MAX(verified_at) lastSync FROM jm_storage_receipts',
  ).first();
  const send = e ? transport({ ...(await scoped(env, e)), FILE_TRANSFER_ENABLED: 'true' }) : null;
  let health = null;
  if (send) {
    try {
      const r = await send('/health');
      if (r.ok) health = await r.json();
      else await r.body?.cancel();
    } catch {}
  }
  const b2 = b2Transport(env);
  let b2Status = 'Disabled or unconfigured';
  if (b2) {
    try {
      const r = await b2('HEAD', '00000000-0000-0000-0000-000000000000');
      await r.body?.cancel();
      b2Status = r.status === 404 || r.ok ? 'Reachable' : 'Access not verified';
    } catch {
      b2Status = 'Unreachable';
    }
  }
  const summary = await statement(
    env.DB_MAIN,
    "SELECT (SELECT sum(bytes) FROM (SELECT file_id,max(bytes) bytes FROM jm_storage_transfers WHERE file_id IN (SELECT id FROM jm_file_metadata WHERE state='confirmed' AND deleted_at IS NULL) GROUP BY file_id)) confirmedBytes,(SELECT last_error FROM jm_storage_transfers WHERE cleaned_at IS NULL AND last_error IS NOT NULL ORDER BY next_attempt DESC LIMIT 1) lastError,(SELECT hash FROM jm_storage_backups ORDER BY created_at DESC LIMIT 1) backupHash",
  ).first();
  const backups = await rows(
    env.DB_MAIN,
    'SELECT hash,created_at AS createdAt FROM jm_storage_backups ORDER BY created_at DESC LIMIT 30',
  );
  return {
    ...summary,
    backups,
    budgetBytes: Number(env.B2_STAGING_BUDGET_BYTES) || null,
    b2Status,
    generation: c?.generation,
    paused: !!c?.paused,
    origin: e?.id ?? null,
    machine: e?.machine ?? null,
    health,
    binding: !!env.STORAGE_ORIGIN,
    b2Configured: !!b2Transport(env),
    transfersEnabled: env.FILE_TRANSFER_ENABLED === 'true',
    ...aggregate,
    ...last,
  };
}

export async function backupApi(env: Env, input: JsonObject) {
  enabled(env);
  const id = identifier(input.id),
    nonce = identifier(input.nonce),
    stamp = Number(input.stamp),
    kind = String(input.kind),
    arg = String(input.arg);
  if (
    !['files', 'receipts', 'confirm'].includes(kind) ||
    !Number.isSafeInteger(stamp) ||
    Math.abs(unix() - stamp) > 60 ||
    !/^[a-z0-9-]{0,64}$/.test(arg)
  )
    return forbidden();
  const c = await control(env),
    e = await entry(env, id);
  if (!e || c?.primary_id !== id) return forbidden();
  const expected = await keyed(
    { ...env, AUTH_SECRET: await credential(env, e) },
    [id, nonce, stamp, kind, arg].join('|'),
  );
  if (!same(expected, String(input.proof))) return forbidden();
  await change(env.DB_MAIN, 'DELETE FROM jm_origin_nonces WHERE expires<?', unix());
  if (
    !(await change(
      env.DB_MAIN,
      'INSERT OR IGNORE INTO jm_origin_nonces VALUES(?,?,?)',
      id,
      nonce,
      unix() + 125,
    ))
  )
    return forbidden();
  if (kind === 'confirm') {
    if (!/^[a-f0-9]{64}$/.test(arg)) return forbidden();
    await change(
      env.DB_MAIN,
      'INSERT OR IGNORE INTO jm_storage_backups(hash,origin,created_at) SELECT ?,?,? WHERE EXISTS(SELECT 1 FROM jm_origin_control WHERE primary_id=?)',
      arg,
      id,
      now(),
      id,
    );
    const recorded = await statement(
      env.DB_MAIN,
      'SELECT 1 AS ok FROM jm_storage_backups b JOIN jm_origin_control c ON c.primary_id=b.origin WHERE b.hash=? AND b.origin=? AND c.slot=1',
      arg,
      id,
    ).first();
    if (!recorded) return conflict();
    return { recorded: true };
  }
  return {
    items:
      kind === 'files'
        ? await rows(
            env.DB_MAIN,
            'SELECT id,profile_id,category,sha256,mime,state,confirmed_at FROM jm_file_metadata WHERE deleted_at IS NULL AND id>? ORDER BY id LIMIT 100',
            arg,
          )
        : await rows(
            env.DB_MAIN,
            'SELECT * FROM jm_storage_receipts WHERE ticket>? ORDER BY ticket LIMIT 100',
            arg,
          ),
  };
}

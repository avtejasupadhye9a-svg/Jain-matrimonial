import {
  Actor,
  Env,
  Failure,
  audit,
  change,
  conflict,
  digestBytes,
  identifier,
  listing,
  missing,
  now,
  page,
  rows,
  statement,
} from './core';

import { active } from './infrastructure';
import { bytes, transport } from './origin';
import { b2Transport, stage, synchronize } from './b2';
const checksumPattern = /^[a-f0-9]{64}$/;
const signatures: Record<string, readonly number[]> = {
  'application/pdf': [37, 80, 68, 70, 45],
  'image/jpeg': [255, 216, 255],
  'image/png': [137, 80, 78, 71, 13, 10, 26, 10],
};
interface FileRecord {
  id: string;
  profileId: string;
  sha256: string;
  mime: string;
  state: string;
  confirmedAt: string | null;
  createdAt: string;
}
const select = `SELECT id,profile_id AS profileId,sha256,mime,state,confirmed_at AS confirmedAt,created_at AS createdAt
  FROM jm_file_metadata WHERE category='identity_document' AND access_policy='admin' AND deleted_at IS NULL`;

function unavailable(): never {
  throw new Failure(
    503,
    'storage_unavailable',
    'Storage is unavailable. Retry the upload using the same document ID.',
  );
}

export async function storageStatus(env: Env) {
  if (env.FILE_TRANSFER_ENABLED !== 'true') return 'disabled';
  const send = transport(await active(env));
  if (!send) return 'unconfigured';
  try {
    const response = await send('/health');
    await response.body?.cancel();
    return response.status === 200 ? 'online' : 'offline';
  } catch {
    return 'offline';
  }
}

export async function documents(env: Env, profileId: string, url: URL) {
  const { limit, offset } = page(url);
  const items = await rows<FileRecord>(
    env.DB_MAIN,
    `${select} AND profile_id=? ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?`,
    profileId,
    limit + 1,
    offset,
  );
  return listing(items, limit, offset);
}

function record(env: Env, id: string) {
  return statement(env.DB_MAIN, select + ' AND id=?', id).first<FileRecord>();
}

export async function upload(env: Env, actor: Actor, id: string, request: Request, url: URL) {
  const send = transport(await active(env));
  const profileId = identifier(url.searchParams.get('profileId'), 'profileId');
  const mime = request.headers.get('content-type') ?? '';
  const sha256 = request.headers.get('x-content-sha256') ?? '';
  if (!Object.hasOwn(signatures, mime)) throw new Failure(415, 'file_type', 'Use a PDF, JPEG, or PNG file.');
  if (!checksumPattern.test(sha256))
    throw new Failure(400, 'checksum_required', 'Supply the file SHA-256 checksum.');
  const data = await bytes(request.body);
  const signature = signatures[mime];
  if (data.length < signature.length || !signature.every((value, index) => data[index] === value))
    throw new Failure(415, 'file_type', 'The file content does not match its type.');
  if ((await digestBytes(data)) !== sha256)
    throw new Failure(422, 'checksum_mismatch', 'The file checksum does not match.');
  const db = env.DB_MAIN;
  const managed = env.MANAGED_STORAGE_ENABLED === 'true';
  const customer = actor.role === 'customer';
  const photo = customer && url.searchParams.get('kind') === 'photo';
  if (customer && (!managed || !['photo', 'document'].includes(url.searchParams.get('kind') ?? '')))
    return unavailable();
  if (photo && !mime.startsWith('image/')) throw new Failure(415, 'file_type', 'Select a JPEG or PNG photo.');
  if (env.FILE_TRANSFER_ENABLED !== 'true' || (!managed && !send)) return unavailable();
  const access = photo ? 'owner' : 'admin',
    category = photo ? 'photo' : 'identity_document';
  const profile = customer
    ? statement(
        db,
        "SELECT p.id FROM jm_profiles p JOIN jm_ownership o ON o.profile_id=p.id WHERE p.id=? AND p.suspended=0 AND o.account_id=? AND o.authority='owner'",
        profileId,
        actor.id,
      )
    : statement(db, 'SELECT id FROM jm_profiles WHERE id=?', profileId);
  if (!(await profile.first())) return missing();
  await change(
    db,
    `INSERT OR IGNORE INTO jm_file_metadata(id,profile_id,category,sha256,mime,state,access_policy,created_at)
    VALUES(?,?,?,?,?,'copying',?,?)`,
    id,
    profileId,
    category,
    sha256,
    mime,
    access,
    now(),
  );
  const lookup = () =>
    statement(
      db,
      'SELECT id, profile_id AS profileId,sha256,mime,state,confirmed_at AS confirmedAt,created_at AS createdAt FROM jm_file_metadata WHERE id=? AND category=? AND access_policy=? AND deleted_at IS NULL',
      id,
      category,
      access,
    ).first<FileRecord>();
  const saved = await lookup();
  if (
    !saved ||
    saved.sha256 !== sha256 ||
    saved.mime !== mime ||
    saved.profileId !== profileId ||
    !['copying', 'failed', 'staged', 'confirmed'].includes(saved.state)
  )
    return conflict();
  if (saved.state === 'confirmed' || saved.state === 'staged') return saved;

  try {
    if (managed) {
      const staging = b2Transport(env);
      if (!staging) return unavailable();
      await stage(db, staging, actor.id, id, data, sha256, Number(env.B2_STAGING_BUDGET_BYTES ?? 0));
      return await lookup();
    }
    if (!send) return unavailable();
    const response = await send('/objects/' + id, 'PUT', data, mime, sha256).catch(
      () => new Response(null, { status: 503 }),
    );
    if (response.status >= 500) {
      const b2 = b2Transport(env);
      if (b2) {
        await response.body?.cancel();
        await stage(db, b2, actor.id, id, data, sha256);
        return await record(env, id);
      }
    }
    if (response.status === 422) {
      await response.body?.cancel();
      throw new Failure(422, 'origin_rejected', 'The permanent storage scanner rejected the file.');
    }
    if (response.status !== 200) {
      await response.body?.cancel();
      return unavailable();
    }
    const receipt = await response.json<{ id: string; sha256: string; bytes: number }>();
    if (receipt.id !== id || receipt.sha256 !== sha256 || receipt.bytes !== data.length) return unavailable();
  } catch (error) {
    await db.batch([
      statement(db, `UPDATE jm_file_metadata SET state='failed' WHERE id=? AND state='copying'`, id),
      audit(db, actor, id, 'storage.upload_failed'),
    ]);
    if (error instanceof Failure) throw error;
    return unavailable();
  }
  const confirmedAt = now();
  await db.batch([
    statement(
      db,
      `INSERT OR IGNORE INTO jm_outbox(id,actor_id,entity_id,action,created_at)
      SELECT ?,?,id,'storage.confirmed',? FROM jm_file_metadata WHERE id=? AND state IN ('copying','failed')`,
      id + ':storage-confirmed',
      actor.id,
      confirmedAt,
      id,
    ),
    statement(
      db,
      `UPDATE jm_file_metadata SET state='confirmed',confirmed_at=? WHERE id=? AND state IN ('copying','failed')`,
      confirmedAt,
      id,
    ),
  ]);
  return await record(env, id);
}

export async function download(env: Env, actor: Actor, id: string) {
  const send = transport(await active(env)) ?? unavailable();
  const customer = actor.role === 'customer';
  const saved = customer
    ? await statement(
        env.DB_MAIN,
        "SELECT f.id,f.mime,f.sha256,f.state FROM jm_file_metadata f JOIN jm_ownership o ON o.profile_id=f.profile_id JOIN jm_profiles p ON p.id=f.profile_id WHERE f.id=? AND o.account_id=? AND o.authority='owner' AND p.suspended=0 AND f.category='photo' AND f.access_policy='owner' AND f.deleted_at IS NULL",
        id,
        actor.id,
      ).first<FileRecord>()
    : await record(env, id);
  if (!saved || saved.state !== 'confirmed') return missing();
  let data: Uint8Array<ArrayBuffer>;
  try {
    const response = await send((customer ? '/photos/' : '/objects/') + id + '/content');
    if (response.status !== 200) {
      await response.body?.cancel();
      return unavailable();
    }
    data = await bytes(response.body);
    if ((await digestBytes(data)) !== saved.sha256) return unavailable();
  } catch {
    await audit(env.DB_MAIN, actor, id, 'storage.download_failed').run();
    return unavailable();
  }
  await audit(env.DB_MAIN, actor, id, 'storage.downloaded').run();
  return { data, mime: saved.mime, sha256: saved.sha256 };
}

export async function syncPending(env: Env) {
  const b2 = b2Transport(env);
  if (!b2 || env.FILE_TRANSFER_ENABLED !== 'true') return;
  const managed = env.MANAGED_STORAGE_ENABLED === 'true',
    lease = crypto.randomUUID();
  if (
    managed &&
    !(await change(
      env.DB_MAIN,
      'UPDATE jm_origin_control SET lease=?,lease_until=unixepoch()+900 WHERE slot=1 AND paused=0 AND primary_id IS NOT NULL AND lease_until<=unixepoch()',
      lease,
    ))
  )
    return;
  try {
    const selected = await active(env),
      send = transport(selected);
    if (!send) return;
    const r = await send('/health').catch(() => null);
    await r?.body?.cancel();
    if (r?.ok) await synchronize({ ...selected, ORIGIN_LEASE: lease }, send, b2);
  } finally {
    if (managed)
      await change(env.DB_MAIN, 'UPDATE jm_origin_control SET lease=NULL,lease_until=0 WHERE lease=?', lease);
  }
}

export async function ownFiles(env: Env, actor: Actor, profile: string, url: URL) {
  const { limit, offset } = page(url);
  const items = await rows(
    env.DB_MAIN,
    "SELECT f.id,f.category,f.state,f.sha256,f.mime FROM jm_file_metadata f JOIN jm_ownership o ON o.profile_id=f.profile_id JOIN jm_profiles p ON p.id=f.profile_id WHERE f.profile_id=? AND o.account_id=? AND o.authority='owner' AND p.suspended=0 AND f.deleted_at IS NULL ORDER BY f.created_at DESC,f.id LIMIT ? OFFSET ?",
    profile,
    actor.id,
    limit + 1,
    offset,
  );
  return listing(items, limit, offset);
}

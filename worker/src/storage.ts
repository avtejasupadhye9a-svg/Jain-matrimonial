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

const maxBytes = 8 * 1024 * 1024;
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
    'Permanent storage is unavailable. No offline copy will be made.',
  );
}

function transport(env: Env) {
  if (
    env.FILE_TRANSFER_ENABLED !== 'true' ||
    !env.STORAGE_ORIGIN_TOKEN ||
    env.STORAGE_ORIGIN_TOKEN.length < 32
  )
    return null;
  const local =
    env.JAIN_LOCAL_TEST === 'true' && /^http:\/\/127\.0\.0\.1:[0-9]+$/.test(env.STORAGE_LOCAL_URL ?? '');
  if (!env.STORAGE_ORIGIN && !local) return null;
  const base = local ? env.STORAGE_LOCAL_URL : 'http://jain-storage.internal';
  return async (
    path: string,
    method = 'GET',
    body?: Uint8Array<ArrayBuffer>,
    mime?: string,
    sha256?: string,
  ) => {
    const headers = new Headers({ authorization: `Bearer ${env.STORAGE_ORIGIN_TOKEN}` });
    if (body) {
      headers.set('content-type', mime!);
      headers.set('x-content-sha256', sha256!);
    }
    const request = new Request(base + path, {
      method,
      headers,
      body,
      redirect: 'manual',
      signal: AbortSignal.timeout(8000),
    });
    return local ? fetch(request) : env.STORAGE_ORIGIN!.fetch(request);
  };
}

export async function storageStatus(env: Env) {
  if (env.FILE_TRANSFER_ENABLED !== 'true') return 'disabled';
  const send = transport(env);
  if (!send) return 'unconfigured';
  try {
    const response = await send('/health');
    await response.body?.cancel();
    return response.status === 200 ? 'online' : 'offline';
  } catch {
    return 'offline';
  }
}

async function bytes(body: ReadableStream<Uint8Array> | null) {
  if (!body) return new Uint8Array(0);
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const next = await reader.read();
      if (next.done) break;
      length += next.value.byteLength;
      if (length > maxBytes) {
        await reader.cancel();
        throw new Failure(413, 'file_too_large', 'Files must be 8 MiB or smaller.');
      }
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  const data = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    data.set(chunk, offset);
    offset += chunk.length;
  }
  return data;
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
  const send = transport(env) ?? unavailable();
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
  if (!(await statement(db, 'SELECT id FROM jm_profiles WHERE id=?', profileId).first())) return missing();
  await change(
    db,
    `INSERT OR IGNORE INTO jm_file_metadata(id,profile_id,category,sha256,mime,state,access_policy,created_at)
    VALUES(?,?,'identity_document',?,?,'copying','admin',?)`,
    id,
    profileId,
    sha256,
    mime,
    now(),
  );
  const saved = await record(env, id);
  if (
    !saved ||
    saved.sha256 !== sha256 ||
    saved.mime !== mime ||
    saved.profileId !== profileId ||
    !['copying', 'failed', 'confirmed'].includes(saved.state)
  )
    return conflict();
  if (saved.state === 'confirmed') return saved;

  try {
    const response = await send('/objects/' + id, 'PUT', data, mime, sha256);
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
  const send = transport(env) ?? unavailable();
  const saved = await record(env, id);
  if (!saved || saved.state !== 'confirmed') return missing();
  let data: Uint8Array<ArrayBuffer>;
  try {
    const response = await send('/objects/' + id + '/content');
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

import { AwsClient } from 'aws4fetch';
import { Env, change, digestBytes, now, rows, statement, unix } from './core';
import { bytes, type OriginSend } from './origin';

type B2Request = (
  method: string,
  ticket: string,
  version?: string,
  data?: Uint8Array<ArrayBuffer>,
  hash?: string,
) => Promise<Response>;

export function b2Transport(env: Env): B2Request | null {
  if (
    env.B2_STAGING_ENABLED !== 'true' ||
    !env.B2_KEY_ID ||
    !env.B2_APPLICATION_KEY ||
    env.B2_BUCKET !== 'jain-matrimonial-temp-9a' ||
    env.B2_REGION !== 'us-east-005' ||
    env.B2_ENDPOINT !== 'https://s3.us-east-005.backblazeb2.com'
  )
    return null;
  const client = new AwsClient({
    accessKeyId: env.B2_KEY_ID,
    secretAccessKey: env.B2_APPLICATION_KEY,
    region: env.B2_REGION,
    service: 's3',
    retries: 0,
  });
  return async (method, ticket, version, data, hash) => {
    if (!/^[a-f0-9-]{36}$/.test(ticket) || (method === 'DELETE' && !version))
      throw new Error('Invalid storage key');
    const url = new URL(env.B2_ENDPOINT + '/' + env.B2_BUCKET + '/pending/' + ticket);
    if (version) url.searchParams.set('versionId', version);
    const headers = new Headers();
    if (data && hash) {
      headers.set('x-amz-server-side-encryption', 'AES256');
      headers.set('x-amz-content-sha256', hash);
      headers.set('content-type', 'application/octet-stream');
    }
    const signed = await client.sign(url.toString(), { method, headers, body: data, redirect: 'manual' });
    return fetch(signed, { redirect: 'manual', signal: AbortSignal.timeout(15000) });
  };
}

function objectVersion(response: Response) {
  const id = response.headers.get('x-amz-version-id');
  if (!id || id === 'null' || id.length > 1024) throw new Error('B2 version unavailable');
  return id;
}

export async function stage(
  db: D1Database,
  b2: B2Request,
  actor: string,
  file: string,
  data: Uint8Array<ArrayBuffer>,
  sha: string,
  budget = 0,
) {
  const ticket = crypto.randomUUID();
  const reserved = await change(
    db,
    'INSERT INTO jm_storage_transfers(ticket,file_id,actor_id,bytes,next_attempt) SELECT ?,?,?,?,? WHERE ?=0 OR (SELECT coalesce(sum(bytes),0) FROM jm_storage_transfers WHERE cleaned_at IS NULL)+?<=?',
    ticket,
    file,
    actor,
    data.length,
    unix() + 120,
    budget,
    data.length,
    budget,
  );
  if (!reserved) throw new Error('Staging budget reached');
  const response = await b2('PUT', ticket, undefined, data, sha);
  await response.body?.cancel();
  if (response.status !== 200) throw new Error('Private staging unavailable');
  await saveVersion(db, ticket, file, objectVersion(response));
}

async function saveVersion(db: D1Database, ticket: string, file: string, version: string) {
  await db.batch([
    statement(
      db,
      'UPDATE jm_storage_transfers SET version=?,next_attempt=? WHERE ticket=? AND version IS NULL',
      version,
      unix(),
      ticket,
    ),
    statement(
      db,
      "UPDATE jm_file_metadata SET state='staged',staging_provider='b2' WHERE id=? AND state IN ('failed','copying') AND deleted_at IS NULL",
      file,
    ),
  ]);
}

interface Transfer {
  ticket: string;
  category: string;
  file_id: string;
  bytes: number;
  version: string | null;
  sha256: string;
  mime: string;
}

class SyncFailure extends Error {}

// Only the scheduler can call this. Receipts live in D1 across PC migrations.
export async function synchronize(env: Env, send: OriginSend, b2: B2Request) {
  const db = env.DB_MAIN;
  if (!env.STORAGE_ORIGIN_ID) return;
  const due = await rows<Transfer>(
    db,
    "SELECT t.*,f.sha256,f.mime,f.category FROM jm_storage_transfers t JOIN jm_file_metadata f ON f.id=t.file_id WHERE t.cleaned_at IS NULL AND t.next_attempt<=? AND f.deleted_at IS NULL AND ((f.category='identity_document' AND f.access_policy='admin') OR (f.category='photo' AND f.access_policy='owner')) AND f.state IN ('staged','confirmed','failed','copying') ORDER BY t.next_attempt,t.ticket LIMIT 3",
    unix(),
  );
  for (const item of due) {
    const claimed = await change(
      db,
      "UPDATE jm_storage_transfers SET next_attempt=?+min(86400,60*(1 << min(attempts,10))),attempts=attempts+1,last_error='Copy or cleanup awaiting verification' WHERE ticket=? AND cleaned_at IS NULL AND next_attempt<=?",
      unix(),
      item.ticket,
      unix(),
    );
    if (!claimed) continue;
    try {
      await syncTransfer(env, item, send, b2);
    } catch (failure) {
      const reason = failure instanceof SyncFailure ? failure.message : 'Storage request interrupted';
      await change(
        db,
        'UPDATE jm_storage_transfers SET last_error=? WHERE ticket=? AND cleaned_at IS NULL',
        reason,
        item.ticket,
      );
      console.warn('Storage sync deferred');
    }
  }
}

async function syncTransfer(env: Env, item: Transfer, send: OriginSend, b2: B2Request) {
  const db = env.DB_MAIN;
  const { ticket, file_id: file, sha256: sha } = item;
  let version = item.version;
  if (!version) {
    const head = await b2('HEAD', ticket);
    await head.body?.cancel();
    if (!head.ok) {
      // A PUT may have failed before reaching B2. Keep the reservation for
      // ambiguity recovery without allowing empty tickets to dominate retries.
      if (head.status === 404)
        await change(
          db,
          'UPDATE jm_storage_transfers SET next_attempt=? WHERE ticket=? AND version IS NULL',
          unix() + 86400,
          ticket,
        );
      return;
    }
    version = objectVersion(head);
    await saveVersion(db, ticket, file, version);
  }
  const hasReceipt = () =>
    statement(
      db,
      "SELECT r.ticket FROM jm_storage_receipts r JOIN jm_storage_transfers t USING(ticket) JOIN jm_file_metadata f ON f.id=t.file_id WHERE r.ticket=? AND r.version=? AND r.sha256=f.sha256 AND r.bytes=t.bytes AND f.state='confirmed' AND f.deleted_at IS NULL",
      ticket,
      version,
    ).first();
  const path = (item.category === 'photo' ? '/photos/' : '/objects/') + file;
  async function verified() {
    const response = await send(path);
    if (!response.ok) {
      await response.body?.cancel();
      return false;
    }
    const info = await response.json<{ id: string; sha256: string; bytes: number }>();
    return info.id === file && info.sha256 === sha && info.bytes === item.bytes;
  }
  if (!(await hasReceipt()) || !(await verified())) {
    const staged = await b2('GET', ticket, version);
    if (!staged.ok || staged.headers.get('x-amz-version-id') !== version) {
      await staged.body?.cancel();
      return;
    }
    const data = await bytes(staged.body);
    if (data.length !== item.bytes || (await digestBytes(data)) !== sha)
      throw new SyncFailure('Staged file integrity mismatch');
    const written = await send(path, 'PUT', data, item.mime, sha);
    await written.body?.cancel();
    if (!written.ok)
      throw new SyncFailure(
        written.status === 507
          ? 'Permanent disk capacity insufficient'
          : written.status === 422
            ? 'Origin rejected file validation or scan'
            : 'Permanent write unavailable',
      );
    if (!(await verified())) throw new SyncFailure('Permanent checksum verification failed');
    const time = now();
    await db.batch([
      statement(
        db,
        "INSERT OR IGNORE INTO jm_storage_receipts SELECT ?,?,?,sha256,?,? FROM jm_file_metadata WHERE id=? AND sha256=? AND deleted_at IS NULL AND state IN ('staged','copying','failed','confirmed')",
        ticket,
        env.STORAGE_ORIGIN_ID,
        version,
        item.bytes,
        time,
        file,
        sha,
      ),
      statement(
        db,
        "UPDATE jm_file_metadata SET state='confirmed',confirmed_at=coalesce(confirmed_at,?) WHERE id=? AND deleted_at IS NULL AND EXISTS (SELECT 1 FROM jm_storage_receipts WHERE ticket=?)",
        time,
        file,
        ticket,
      ),
      statement(
        db,
        "INSERT OR IGNORE INTO jm_outbox(id,actor_id,entity_id,action,created_at) SELECT ?,actor_id,file_id,'storage.confirmed',? FROM jm_storage_transfers WHERE ticket=? AND EXISTS (SELECT 1 FROM jm_storage_receipts WHERE ticket=?)",
        file + ':storage-confirmed',
        time,
        ticket,
        ticket,
      ),
    ]);
  }
  // A crash after the receipt or after deletion re-enters here. Never delete by key alone.
  if (!(await hasReceipt()) || !(await verified())) return;
  if (env.ORIGIN_SIGNED) {
    const copy = await send(path + '/content');
    if (!copy.ok) {
      await copy.body?.cancel();
      return;
    }
    const data = await bytes(copy.body);
    if (data.length !== item.bytes || (await digestBytes(data)) !== sha) return;
    if (
      !(await statement(
        db,
        'SELECT slot FROM jm_origin_control WHERE slot=1 AND primary_id=? AND paused=0 AND lease=? AND lease_until>unixepoch()+30',
        env.STORAGE_ORIGIN_ID,
        env.ORIGIN_LEASE,
      ).first())
    )
      return;
  }
  const removed = await b2('DELETE', ticket, version);
  await removed.body?.cancel();
  if (removed.status === 204 || removed.status === 404) {
    await change(
      db,
      'UPDATE jm_storage_transfers SET cleaned_at=?,last_error=NULL WHERE ticket=? AND version=?',
      now(),
      ticket,
      version,
    );
  }
}

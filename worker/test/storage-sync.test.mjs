import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { readdirSync, readFileSync } from 'node:fs';
import { build } from 'esbuild';

const bundle = await build({ entryPoints: ['src/storage.ts'], bundle: true, write: false, format: 'esm' });
const { upload, syncPending, download } = await import(
  'data:text/javascript;base64,' + Buffer.from(bundle.outputFiles[0].contents).toString('base64')
);

test('offline upload, quarantine, durable receipt, replay and exact-version cleanup', async (t) => {
  const sqlite = new DatabaseSync(':memory:');
  t.after(() => sqlite.close());
  for (const sql of readdirSync('migrations/main').sort())
    sqlite.exec(readFileSync('migrations/main/' + sql, 'utf8'));
  const db = {
    prepare(sql) {
      return {
        bind(...params) {
          const stmt = sqlite.prepare(sql);
          return {
            first: () => stmt.get(...params),
            all: () => ({ results: stmt.all(...params) }),
            run: () => ({ meta: stmt.run(...params) }),
          };
        },
      };
    },
    batch(items) {
      sqlite.exec('BEGIN');
      try {
        const out = items.map((i) => i.run());
        sqlite.exec('COMMIT');
        return out;
      } catch (e) {
        sqlite.exec('ROLLBACK');
        throw e;
      }
    },
  };
  const row = (query) => sqlite.prepare(query).get();
  const actor = { id: randomUUID(), role: 'admin' };
  const profile = randomUUID(),
    id = randomUUID(),
    origin = randomUUID(),
    version = 'test-version';
  sqlite
    .prepare("INSERT INTO jm_accounts VALUES(?,'admin@example.test','admin','active','now','now')")
    .run(actor.id);
  sqlite
    .prepare(
      "INSERT INTO jm_profiles(id,creator_id,candidate_consent_at,created_at,updated_at) VALUES(?,?,'now','now','now')",
    )
    .run(profile, actor.id);
  let wrongOrigin = true;
  let online = false,
    body,
    corrupted = true,
    reject = true,
    stagedBytes,
    deleted = false,
    dropDeleteReply = true,
    simulateDiskLoss = false;
  const data = Buffer.from('%PDF-1.4\nexample');
  const sha = createHash('sha256').update(data).digest('hex');
  const env = {
    DB_MAIN: db,
    STORAGE_ORIGIN_ID: origin,
    STORAGE_ORIGIN_TOKEN: randomBytes(32).toString('hex'),
    FILE_TRANSFER_ENABLED: 'true',
    B2_STAGING_ENABLED: 'true',
    B2_KEY_ID: randomUUID(),
    B2_APPLICATION_KEY: randomUUID(),
    B2_BUCKET: 'jain-matrimonial-temp-9a',
    B2_REGION: 'us-east-005',
    B2_ENDPOINT: 'https://s3.us-east-005.backblazeb2.com',
    STORAGE_ORIGIN: {
      async fetch(request) {
        assert.equal(request.headers.get('x-jain-origin'), origin);
        assert.ok(request.headers.get('authorization') === 'Bearer ' + env.STORAGE_ORIGIN_TOKEN);
        if (!online) throw new Error('offline');
        const headers = { 'x-jain-origin': wrongOrigin ? randomUUID() : origin };
        if (new URL(request.url).pathname === '/health') return Response.json({ status: 'ok' }, { headers });
        if (request.method === 'PUT') {
          if (reject) return new Response(null, { status: 422, headers });
          body = Buffer.from(await request.arrayBuffer());
          return Response.json({ id, sha256: sha, bytes: body.length }, { headers });
        }
        return Response.json({ id, sha256: simulateDiskLoss ? 'bad' : sha, bytes: body.length }, { headers });
      },
    },
  };
  let uploads = 0,
    cleanups = 0;
  t.mock.method(globalThis, 'fetch', async (req) => {
    const url = new URL(req.url);
    assert.equal(url.origin, env.B2_ENDPOINT);
    assert.match(url.pathname, /^\/jain-matrimonial-temp-9a\/pending\/[a-f0-9-]{36}$/);
    assert.ok(req.headers.get('authorization')?.startsWith('AWS4-HMAC-SHA256 '));
    const headers = { 'x-amz-version-id': version };
    if (req.method === 'PUT') {
      assert.equal(++uploads, 1);
      assert.equal(req.headers.get('x-amz-server-side-encryption'), 'AES256');
      stagedBytes = Buffer.from(await req.arrayBuffer());
      assert.deepEqual(stagedBytes, data);
      return new Response(null, { headers });
    }
    if (req.method === 'HEAD') return new Response(null, { headers });
    assert.equal(url.searchParams.get('versionId'), version);
    if (req.method === 'GET') return new Response(corrupted ? Buffer.from('bad') : stagedBytes, { headers });
    assert.equal(req.method, 'DELETE');
    assert.equal(row('SELECT version FROM jm_storage_receipts').version, version);
    assert.equal(row('SELECT state FROM jm_file_metadata').state, 'confirmed');
    assert.deepEqual(body, data);
    cleanups++;
    if (dropDeleteReply) {
      deleted = true;
      dropDeleteReply = false;
      throw new Error('lost reply');
    }
    assert.equal(deleted, true);
    return new Response(null, { status: 404 });
  });
  const url = new URL('https://worker.invalid/admin/documents/' + id + '?profileId=' + profile);
  const put = () =>
    upload(
      env,
      actor,
      id,
      new Request(url, {
        method: 'PUT',
        headers: { 'content-type': 'application/pdf', 'x-content-sha256': sha },
        body: data,
      }),
      url,
    );
  online = true;
  await assert.rejects(put, (e) => e.status === 503);
  assert.equal(uploads, 0);
  assert.equal(body, undefined);
  online = false;
  wrongOrigin = false;
  assert.equal((await put()).state, 'staged');
  assert.equal((await put()).state, 'staged');
  await assert.rejects(
    () => download(env, actor, id),
    (e) => e.status === 404,
  );
  const retry = async () => {
    sqlite.exec('UPDATE jm_storage_transfers SET next_attempt=0');
    await syncPending(env);
  };
  await retry();
  assert.equal(uploads, 1);
  assert.equal(cleanups, 0);
  online = true;
  sqlite.exec('UPDATE jm_storage_transfers SET version=NULL'); // lost PUT acknowledgement
  await retry();
  assert.equal(body, undefined);
  assert.equal(cleanups, 0);
  corrupted = false;
  await retry();
  assert.equal(cleanups, 0);
  assert.equal(row('SELECT count(*) n FROM jm_storage_receipts').n, 0);
  reject = false;
  sqlite.exec(
    "CREATE TRIGGER fail_receipt BEFORE INSERT ON jm_storage_receipts BEGIN SELECT RAISE(ABORT,'disk full'); END",
  );
  await retry();
  assert.equal(cleanups, 0);
  assert.equal(row('SELECT state FROM jm_file_metadata').state, 'staged');
  sqlite.exec('DROP TRIGGER fail_receipt');
  await retry();
  assert.equal(cleanups, 1);
  assert.equal(row('SELECT cleaned_at FROM jm_storage_transfers').cleaned_at, null);
  simulateDiskLoss = true;
  await retry();
  assert.equal(cleanups, 1);
  simulateDiskLoss = false;
  await retry();
  assert.equal(cleanups, 2);
  assert.ok(row('SELECT cleaned_at FROM jm_storage_transfers').cleaned_at);
  assert.throws(() => sqlite.exec('DELETE FROM jm_storage_receipts'), /durable/);
  await retry();
  assert.equal(cleanups, 2);
});

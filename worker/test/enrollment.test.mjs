import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readdirSync, readFileSync, mkdtempSync, mkdirSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createHash, createHmac, randomBytes, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { build } from 'esbuild';

const bytes = (
  await build({ entryPoints: ['src/infrastructure.ts'], bundle: true, format: 'esm', write: false })
).outputFiles[0].contents;
const infra = await import('data:text/javascript;base64,' + Buffer.from(bytes).toString('base64'));
test('enrollment proof, expiry, replay, VPC authentication, restart and migration fencing', async (t) => {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  for (const p of readdirSync('migrations/main').sort())
    db.exec(readFileSync('migrations/main/' + p, 'utf8'));
  const adapter = {
    prepare(sql) {
      return {
        bind(...values) {
          const q = db.prepare(sql);
          return {
            first: () => q.get(...values),
            all: () => ({ results: q.all(...values) }),
            run: () => ({ meta: q.run(...values) }),
          };
        },
      };
    },
    batch(ops) {
      db.exec('BEGIN');
      try {
        const out = ops.map((q) => q.run());
        db.exec('COMMIT');
        return out;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
    },
  };
  const actor = { id: randomUUID(), sessionId: randomUUID(), role: 'admin' };
  db.prepare("INSERT INTO jm_accounts VALUES(?,'owner@test.invalid','admin','active','now','now')").run(
    actor.id,
  );
  db.prepare("INSERT INTO jm_admin_credentials VALUES(1,?,?,1,'now')").run(
    actor.id,
    'pbkdf2-sha256-100k:v1:' + randomBytes(32).toString('hex') + ':' + randomBytes(32).toString('hex'),
  );
  db.exec('BEGIN');
  db.prepare('INSERT INTO jm_admin_session_versions VALUES(?,1)').run(actor.sessionId);
  db.prepare('INSERT INTO jm_sessions VALUES(?,?,?, ?,unixepoch()+600,unixepoch()+900,unixepoch(),NULL)').run(
    actor.sessionId,
    actor.id,
    randomUUID(),
    randomUUID(),
  );
  db.exec('COMMIT');
  const env = {
    AUTH_SECRET: randomBytes(32).toString('hex'),
    DB_MAIN: adapter,
    MANAGED_STORAGE_ENABLED: 'true',
    FILE_TRANSFER_ENABLED: 'true',
  };
  const seed = randomBytes(32).toString('hex'),
    commitment = createHash('sha256').update(seed).digest('hex');
  const register = () => infra.enroll(env, actor, { commitment, machine: 'QA-PC' });
  await assert.rejects(() =>
    infra.enroll({ ...env, MANAGED_STORAGE_ENABLED: 'false' }, actor, { commitment, machine: 'QA' }),
  );
  let { id } = await register();
  db.prepare('UPDATE jm_origin_enrollments SET expires=0 WHERE id=?').run(id);
  await assert.rejects(() => infra.claim(env, { id, seed }));
  ({ id } = await register());
  await assert.rejects(() => infra.claim(env, { id, seed: randomBytes(32).toString('hex') }));
  const credential = (await infra.claim(env, { id, seed })).credential;
  await assert.rejects(() => infra.claim(env, { id, seed }));
  async function startOrigin(id, credential) {
    const root = mkdtempSync(join(tmpdir(), 'origin-qa-'));
    mkdirSync(join(root, 'docs'));
    const python = spawn(
      'python',
      [
        '-u',
        '-c',
        [
          'import json,sys',
          'from pathlib import Path',
          'from local_storage_service.service import Storage,server',
          'r=Path(sys.argv[1]); c=json.loads(sys.stdin.readline()); s=server(Storage(r/"docs",lambda *_:True),c["token"],0,origin_id=c["id"],nonces=r/"replay.db",photos=Storage(r/"photos",lambda *_:True))',
          'print(s.server_port,flush=True);s.serve_forever()',
        ].join('\n'),
        root,
      ],
      { cwd: resolve('..'), stdio: ['pipe', 'pipe', 'inherit'] },
    );
    python.stdin.end(JSON.stringify({ id, token: credential }) + '\n');
    t.after(() => python.kill());
    const [line] = await once(python.stdout, 'data');
    return { root, port: Number(line.toString().trim()) };
  }
  const firstOrigin = await startOrigin(id, credential);
  let port = firstOrigin.port;
  let requestCopy;
  const network = globalThis.fetch;
  env.STORAGE_ORIGIN = {
    async fetch(req) {
      requestCopy = req.clone();
      return network('http://127.0.0.1:' + port + new URL(req.url).pathname, {
        headers: req.headers,
        method: req.method,
        body: req.method === 'PUT' ? await req.arrayBuffer() : undefined,
      });
    },
  };
  assert.equal((await infra.promote(env, actor, { id })).complete, true);
  assert.equal((await env.STORAGE_ORIGIN.fetch(requestCopy)).status, 401);
  assert.equal((await infra.active(env)).STORAGE_ORIGIN_ID, id);
  const storageBytes = (
    await build({ entryPoints: ['src/storage.ts'], bundle: true, format: 'esm', write: false })
  ).outputFiles[0].contents;
  const storage = await import('data:text/javascript;base64,' + Buffer.from(storageBytes).toString('base64'));
  const profile = randomUUID(),
    customer = { id: randomUUID(), role: 'customer' },
    file = randomUUID();
  db.prepare("INSERT INTO jm_accounts VALUES(?,'customer@test.invalid','customer','active','now','now')").run(
    customer.id,
  );
  db.prepare(
    "INSERT INTO jm_profiles(id,creator_id,candidate_consent_at,created_at,updated_at) VALUES(?,?,'now','now','now')",
  ).run(profile, customer.id);
  db.prepare("INSERT INTO jm_ownership VALUES(?,?,'owner','now')").run(profile, customer.id);
  Object.assign(env, {
    B2_BUCKET: 'jain-matrimonial-temp-9a',
    B2_ENDPOINT: 'https://s3.us-east-005.backblazeb2.com',
    B2_REGION: 'us-east-005',
    B2_KEY_ID: randomUUID(),
    B2_APPLICATION_KEY: randomUUID(),
    B2_STAGING_ENABLED: 'true',
  });
  const photo = Buffer.from('89504e470d0a1a0a73796e746865746963', 'hex');
  const hash = createHash('sha256').update(photo).digest('hex');
  const url = new URL('https://worker.invalid/customer/files/' + file + '?kind=photo&profileId=' + profile);
  const request = () =>
    new Request(url, {
      method: 'PUT',
      headers: { 'content-type': 'image/png', 'x-content-sha256': hash },
      body: photo,
    });
  let staged = null,
    deleted = false;
  t.mock.method(globalThis, 'fetch', async (req) => {
    assert.equal(new URL(req.url).origin, env.B2_ENDPOINT);
    assert.ok(req.headers.get('authorization')?.startsWith('AWS4-HMAC-SHA256 '));
    if (req.method === 'PUT') {
      staged = Buffer.from(await req.arrayBuffer());
      return new Response(null, { headers: { 'x-amz-version-id': 'qa-version' } });
    }
    assert.equal(new URL(req.url).searchParams.get('versionId'), 'qa-version');
    if (req.method === 'GET') return new Response(staged, { headers: { 'x-amz-version-id': 'qa-version' } });
    assert.equal(req.method, 'DELETE');
    assert.ok(db.prepare('SELECT ticket FROM jm_storage_receipts WHERE origin_id=?').get(id));
    deleted = true;
    return new Response(null, { status: 204 });
  });
  await assert.rejects(() => storage.upload(env, { ...customer, id: randomUUID() }, file, request(), url));
  assert.equal((await storage.upload(env, customer, file, request(), url)).state, 'staged');
  await assert.rejects(() => storage.download(env, customer, file));
  await storage.syncPending(env);
  assert.equal(deleted, true);
  assert.deepEqual(Buffer.from((await storage.download(env, customer, file)).data), photo);
  await assert.rejects(() => storage.download(env, { ...customer, id: randomUUID() }, file));
  await assert.rejects(register);
  await infra.transition(env, actor, { action: 'pause', generation: 1 });
  assert.equal((await infra.active(env)).STORAGE_ORIGIN_ID, undefined);
  function backupRequest(kind, arg) {
    const nonce = randomUUID(),
      stamp = Math.floor(Date.now() / 1000);
    const proof = createHmac('sha256', credential)
      .update([id, nonce, stamp, kind, arg].join('|'))
      .digest('hex');
    return { id, nonce, stamp, kind, arg, proof };
  }
  const exportRequest = backupRequest('files', '');
  assert.equal((await infra.backupApi(env, exportRequest)).items[0].id, file);
  await assert.rejects(() => infra.backupApi(env, exportRequest));
  assert.equal((await infra.backupApi(env, backupRequest('receipts', ''))).items[0].sha256, hash);
  const manifestHash = createHash('sha256').update('backup manifest fixture').digest('hex');
  assert.equal((await infra.backupApi(env, backupRequest('confirm', manifestHash))).recorded, true);
  const next = await register();
  await infra.claim(env, { id: next.id, seed });
  await assert.rejects(() => infra.promote(env, actor, next));
  await infra.transition(env, actor, { action: 'resume', generation: 2 });
  await assert.rejects(() => infra.promote(env, actor, next));
  assert.equal((await infra.active(env)).STORAGE_ORIGIN_ID, id);
  await infra.transition(env, actor, { action: 'pause', generation: 3 });
  const replacement = await register();
  const replacementKey = (await infra.claim(env, { id: replacement.id, seed })).credential;
  const secondOrigin = await startOrigin(replacement.id, replacementKey);
  port = secondOrigin.port;
  await assert.rejects(() => infra.promote(env, actor, replacement));
  copyFileSync(join(firstOrigin.root, 'photos', file), join(secondOrigin.root, 'photos', file));
  assert.equal((await infra.promote(env, actor, replacement)).complete, false);
  assert.equal((await infra.promote(env, actor, replacement)).complete, true);
  assert.equal((await infra.active(env)).STORAGE_ORIGIN_ID, replacement.id);
  await assert.rejects(() => infra.backupApi(env, backupRequest('files', '')));
  assert.deepEqual(Buffer.from((await storage.download(env, customer, file)).data), photo);
  await infra.transition(env, actor, { action: 'revoke', generation: 5 });
  assert.equal((await infra.active(env)).STORAGE_ORIGIN_ID, undefined);
  assert.ok(db.prepare("SELECT count(*) n FROM jm_outbox WHERE action LIKE 'storage.%'").get().n >= 6);
});

import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { execFileSync, spawn } from 'node:child_process';
import { resolve } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { test } from 'node:test';
import { build } from 'esbuild';
import { unstable_dev } from 'wrangler';

const secret = 'local-test-fixture-key-of-at-least-32-characters';
const harness = `
import app from './src/index.ts';
import { deliverEmails } from './src/operations.ts';
export default {
  fetch(request, env, ctx) {
    const path = new URL(request.url).pathname;
    if (path.startsWith('/__test-') && request.headers.get('x-local-fixture-key') === env.LOCAL_FIXTURE_KEY) {
      if (path === '/__test-db') return runSql(request, env);
      if (path === '/__test-email-failure') {
        return deliverEmails({...env, BREVO_API_KEY: 'unused', BREVO_SENDER_EMAIL: 'sender@example.test'},
          async () => new Response(null, {status: 503})).then(() => Response.json({ok: true}));
      }
    }
    const origin = request.headers.get('x-test-storage-origin');
    if (origin && request.headers.get('x-local-fixture-key') === env.LOCAL_FIXTURE_KEY) {
      env = {...env, FILE_TRANSFER_ENABLED: 'true', STORAGE_LOCAL_URL: origin,
        STORAGE_ORIGIN_TOKEN: request.headers.get('x-test-storage-token') || env.LOCAL_FIXTURE_KEY};
    }
    return app.fetch(request, env, ctx);
  },
};
async function runSql(request, env) {
  const { database, queries } = await request.json();
  const db = env[database];
  try {
    const results = await db.batch(queries.map(({sql,params}) => db.prepare(sql).bind(...params)));
    return Response.json(results);
  } catch (error) {
    return Response.json({message: error.message, cause: String(error.cause)}, {status: 500});
  }
}
`;
let instance;

async function setup() {
  await mkdir('.wrangler', { recursive: true });
  const root = await mkdtemp('.wrangler/t');
  const script = root + '/entry.mjs';
  await build({
    stdin: { contents: harness, resolveDir: '.' },
    bundle: true,
    format: 'esm',
    outfile: script,
  });
  const persistTo = resolve(root);
  const varsFile = resolve(root, 'test-only.vars');
  await writeFile(varsFile, '# Test values are injected by the harness');
  for (const binding of ['DB_MAIN', 'DB_OPERATIONS']) {
    execFileSync(
      process.execPath,
      [
        resolve('node_modules/wrangler/wrangler-dist/cli.js'),
        'd1',
        'migrations',
        'apply',
        binding,
        '--local',
        '--persist-to',
        persistTo,
      ],
      {
        env: {
          ...process.env,
          CI: 'true',
          WRANGLER_SEND_METRICS: 'false',
          WRANGLER_LOG_PATH: resolve(root, 'wrangler.log'),
        },
        stdio: 'pipe',
      },
    );
  }
  instance = await unstable_dev(script, {
    config: 'wrangler.toml',
    local: true,
    ip: '127.0.0.1',
    port: 0,
    bundle: false,
    logLevel: 'error',
    persist: true,
    persistTo,
    envFiles: [varsFile],
    vars: {
      AUTH_SECRET: secret,
      LOCAL_FIXTURE_KEY: secret,
      JAIN_LOCAL_TEST: 'true',
      BREVO_API_KEY: '',
      BREVO_SENDER_EMAIL: '',
    },
    experimental: {
      disableDevRegistry: true,
      disableExperimentalWarning: true,
      forceLocal: true,
      watch: false,
    },
  });
}

async function sqlBatch(database, queries) {
  const response = await fetch('http://127.0.0.1:' + instance.port + '/__test-db', {
    method: 'POST',
    headers: { 'x-local-fixture-key': secret },
    body: JSON.stringify({ database, queries }),
  });
  const payload = await response.json();
  assert.equal(response.status, 200, JSON.stringify(payload));
  return payload;
}
async function request(
  method,
  path,
  token,
  input,
  { status = 200, key = randomUUID(), fixtures = true } = {},
) {
  const headers = { 'Idempotency-Key': key };
  if (token) headers.Authorization = 'Bearer ' + token;
  if (fixtures) headers['x-local-fixture-key'] = secret;
  if (input !== undefined) headers['Content-Type'] = 'application/json';
  const response = await fetch('http://127.0.0.1:' + instance.port + path, {
    method,
    headers,
    body: input === undefined ? undefined : JSON.stringify(input),
  });
  const json = await response.json();
  assert.equal(response.status, status, method + ' ' + path + ' ' + JSON.stringify(json));
  assert.equal(typeof json.requestId, 'string');
  return status < 400 ? json.data : json;
}

const otp = (email) => request('POST', '/auth/otp/request', null, { email }, { status: 202 });
const verify = (code) =>
  request('POST', '/auth/otp/verify', null, { challengeId: code.challengeId, code: code.localTestCode });
const as = (account) => account.accessToken;

async function startStorage(directory) {
  const origin = spawn(
    'python',
    [
      '-u',
      '-c',
      'import sys; from local_storage_service.service import Storage,server; s=server(Storage(sys.argv[1],lambda *_:True),sys.argv[2],0); print(s.server_port,flush=True); s.serve_forever()',
      directory,
      secret,
    ],
    { cwd: process.env.JAIN_STORAGE_REPO || resolve('..'), stdio: ['ignore', 'pipe', 'inherit'] },
  );
  const [port] = await Promise.race([
    once(origin.stdout, 'data'),
    once(origin, 'exit').then(([code]) => {
      throw new Error('Python origin exited: ' + code);
    }),
  ]);
  const stop = async () => {
    if (origin.exitCode !== null || origin.signalCode !== null) return;
    const closed = once(origin, 'exit');
    origin.kill();
    await closed;
  };
  return { url: 'http://127.0.0.1:' + String(port).trim(), stop };
}

const draft = (name = 'Synthetic Candidate', occupation = 'Engineer') => ({
  name,
  dob: '1995-05-05',
  gender: 'woman',
  heightCm: 168,
  city: 'Pune',
  country: 'India',
  tradition: 'Digambara',
  qualification: 'BSc',
  occupation,
  parentsGuardians: 'Private example',
  employer: 'Private workplace',
  languages: ['Marathi'],
  preferences: { city: 'Pune' },
});

async function published(customer, admin, data) {
  const profile = await request('POST', '/profiles', as(customer), { consent: true, data }, { status: 201 });
  const revision = await request(
    'POST',
    '/profiles/' + profile.id + '/submit',
    as(customer),
    { version: profile.version },
    { status: 201 },
  );
  assert.deepEqual((await request('GET', '/search?id=' + profile.id, as(admin.viewer))).items, []);
  await request('POST', '/admin/revisions/' + revision.id + '/decision', as(admin), { decision: 'approved' });
  return profile;
}

test('local D1 acceptance scenarios across customer and administrator APIs', async (t) => {
  t.after(() => instance?.stop());
  await setup();
  await t.test('OTP, replay, throttling, authorization and rotating sessions', async () => {
    const address = 'locked@example.test';
    assert.equal(
      (await request('POST', '/auth/otp/request', null, { email: address }, { status: 503, fixtures: false }))
        .code,
      'email_unavailable',
    );
    const code = await otp(address);
    await request('POST', '/auth/otp/request', null, { email: address }, { status: 429 });
    const invalid = code.localTestCode === '000000' ? '111111' : '000000';
    for (let attempt = 0; attempt < 5; attempt++) {
      await request(
        'POST',
        '/auth/otp/verify',
        null,
        { challengeId: code.challengeId, code: invalid },
        { status: 400 },
      );
    }
    await request(
      'POST',
      '/auth/otp/verify',
      null,
      { challengeId: code.challengeId, code: code.localTestCode },
      { status: 400 },
    );
    const fixture = await otp('rotation@example.test');
    const session = await verify(fixture);
    await request(
      'POST',
      '/auth/otp/verify',
      null,
      { challengeId: fixture.challengeId, code: fixture.localTestCode },
      { status: 400 },
    );
    const next = await request('POST', '/auth/refresh', null, { refreshToken: session.refreshToken });
    await request('POST', '/auth/refresh', null, { refreshToken: session.refreshToken }, { status: 401 });
    await request('GET', '/me', as(session), undefined, { status: 401 });
    await request('GET', '/admin/dashboard', as(next), undefined, { status: 403 });
    await request('POST', '/auth/logout', as(next), {});
    await request('GET', '/me', as(next), undefined, { status: 401 });
    await request(
      'POST',
      '/_local/admin',
      null,
      { email: 'untouchable@example.test' },
      { status: 404, fixtures: false },
    );
  });

  await request('POST', '/_local/admin', null, { email: 'admin@example.test' }, { status: 201 });
  const admin = await verify(await otp('admin@example.test'));
  const sender = await verify(await otp('sender@example.test'));
  const recipient = await verify(await otp('recipient@example.test'));
  const viewer = await verify(await otp('viewer@example.test'));
  admin.viewer = viewer;

  let first;
  let second;
  await t.test(
    'review, drafts, corrections, privacy, combined filters, favorites and recommendations',
    async () => {
      first = await published(sender, admin, draft('Synthetic Sender'));
      second = await published(recipient, admin, draft('Synthetic Recipient', 'Designer'));
      assert.equal((await request('GET', '/readiness', as(admin))).uploads, 'disabled');
      await request('GET', '/files', as(sender), undefined, { status: 503 });
      await request('GET', '/profiles/' + first.id, as(viewer), undefined, { status: 404 });
      const page =
        '/search?city=Pune&qualification=BSc&tradition=Digambara&minAge=25&maxAge=40&language=Marathi&limit=1';
      const p1 = await request('GET', page, as(viewer));
      assert.equal(p1.items.length, 1);
      assert.equal(p1.nextOffset, 1);
      const p2 = await request('GET', page + '&offset=1', as(viewer));
      assert.equal(p2.nextOffset, null);
      assert.notEqual(p2.items[0].id, p1.items[0].id);
      assert.equal(typeof p1.nextCursor, 'string');
      const cursor = '&cursor=' + encodeURIComponent(p1.nextCursor);
      assert.equal((await request('GET', page + cursor, as(viewer))).items[0].id, p2.items[0].id);
      await request('GET', page + cursor, as(sender), undefined, { status: 400 });
      const inspect = () => request('GET', '/discover/' + first.id, as(viewer));
      for (const field of ['name', 'dob', 'email', 'parentsGuardians', 'employer', 'preferences']) {
        assert.equal((await inspect())[field], undefined);
      }
      const edit = await request('PUT', '/profiles/' + first.id, as(sender), {
        version: 1,
        data: draft('Synthetic Sender', 'Doctor'),
      });
      const revision = await request(
        'POST',
        '/profiles/' + first.id + '/submit',
        as(sender),
        { version: edit.version },
        { status: 201 },
      );
      assert.equal((await inspect()).occupation, 'Engineer');
      const key = randomUUID();
      const review = { decision: 'rejected', reason: 'Synthetic test' };
      const endpoint = '/admin/revisions/' + revision.id + '/decision';
      await request('POST', endpoint, as(sender), review, { status: 403 });
      const rejection = await request('POST', endpoint, as(admin), review, { key });
      assert.deepEqual(await request('POST', endpoint, as(admin), review, { key }), rejection);
      assert.equal((await inspect()).occupation, 'Engineer');
      const newer = await request('PUT', '/profiles/' + first.id, as(sender), {
        version: edit.version,
        data: draft('Synthetic Sender', 'Architect'),
      });
      const change = await request(
        'POST',
        '/profiles/' + first.id + '/submit',
        as(sender),
        { version: newer.version },
        { status: 201 },
      );
      await request('POST', '/admin/revisions/' + change.id + '/decision', as(admin), {
        decision: 'approved',
      });
      assert.equal((await inspect()).occupation, 'Architect');
      assert.equal((await inspect()).favorite, false);
      const inProgress = await request('PUT', '/profiles/' + first.id, as(sender), {
        version: newer.version,
        data: draft('Synthetic Sender', 'Pilot'),
      });
      const correction = await request(
        'POST',
        '/profiles/' + first.id + '/submit',
        as(sender),
        { version: inProgress.version },
        { status: 201 },
      );
      await request(
        'POST',
        '/profiles/' + first.id + '/submit',
        as(sender),
        { version: inProgress.version },
        { status: 409 },
      );
      await request('POST', '/admin/revisions/' + correction.id + '/decision', as(admin), {
        decision: 'changes_requested',
        reason: 'Confirm occupation wording',
      });
      assert.equal((await inspect()).occupation, 'Architect');
      assert.equal(
        (await request('GET', '/profiles', as(sender))).items[0].reviewStatus,
        'changes_requested',
      );
      assert.equal((await inspect()).favorite, false);
      await request('PUT', '/favorites/' + first.id, as(viewer), {});
      await request('PUT', '/favorites/' + first.id, as(viewer), {});
      assert.equal((await request('GET', '/favorites', as(viewer))).items.length, 1);
      assert.equal((await inspect()).favorite, true);
      assert.equal((await request('GET', '/discover/' + first.id, as(recipient))).favorite, false);
      assert.equal((await request('GET', '/favorites', as(recipient))).items.length, 0);
      assert.equal((await request('GET', '/recommendations', as(sender))).items[0].id, second.id);
      const saved = await request(
        'POST',
        '/saved-searches',
        as(viewer),
        { name: 'Pune', filters: { city: 'Pune' } },
        { status: 201 },
      );
      assert.equal((await request('GET', '/saved-searches', as(sender))).items.length, 0);
      await request('PUT', '/saved-searches/' + saved.id, as(viewer), {
        name: 'Region',
        filters: { state: 'Maharashtra' },
      });
      assert.equal((await request('GET', '/saved-searches', as(viewer))).items[0].name, 'Region');
    },
  );

  await t.test('admin candidate requires claim OTP, matching email and review', async () => {
    const claimant = await verify(await otp('claimant@example.test'));
    const account = await request(
      'POST',
      '/admin/profiles',
      as(admin),
      {
        consent: true,
        consentEvidence: 'Synthetic signed consent reference',
        claimEmail: 'claimant@example.test',
        data: draft(),
      },
      { status: 201 },
    );
    const wrong = await request('POST', '/auth/claim-code', as(viewer), {}, { status: 202 });
    const revision = await request(
      'POST',
      '/profiles/' + account.id + '/submit',
      as(admin),
      { version: account.version },
      { status: 201 },
    );
    await request('POST', '/admin/revisions/' + revision.id + '/decision', as(admin), {
      decision: 'approved',
    });
    assert.equal((await request('GET', '/profiles/' + account.id, as(admin))).publication.id, revision.id);
    await request(
      'POST',
      '/profiles/claim',
      as(viewer),
      { profileId: account.id, challengeId: wrong.challengeId, code: wrong.localTestCode },
      { status: 404 },
    );
    const code = await request('POST', '/auth/claim-code', as(claimant), {}, { status: 202 });
    const claim = await request(
      'POST',
      '/profiles/claim',
      as(claimant),
      { profileId: account.id, challengeId: code.challengeId, code: code.localTestCode },
      { status: 201 },
    );
    await request('GET', '/profiles/' + account.id, as(claimant), undefined, { status: 404 });
    await request('POST', '/admin/claims/' + claim.id + '/decision', as(admin), {
      decision: 'approved',
      reason: 'Identity and consent confirmed',
    });
    assert.equal((await request('GET', '/profiles/' + account.id, as(claimant))).visible, 0);
    assert.equal((await request('GET', '/claims', as(claimant))).items[0].status, 'approved');
    assert.deepEqual((await request('GET', '/claims', as(viewer))).items, []);
  });

  await t.test('interest moderation and live mutual consent, revocation and blocks', async () => {
    const creation = await request(
      'POST',
      '/interests',
      as(sender),
      { sender: first.id, recipient: second.id },
      { status: 201 },
    );
    const id = creation.id;
    await request(
      'POST',
      '/interests',
      as(recipient),
      { sender: second.id, recipient: first.id },
      { status: 409 },
    );
    assert.deepEqual((await request('GET', '/interests', as(recipient))).items, []);
    const adminPath = '/admin/interests/' + id + '/decision';
    const customerPath = '/interests/' + id + '/decision';
    const contact = '/interests/' + id + '/contact';
    const selected = '/interests?id=' + id;
    const selectedForAdmin = '/admin' + selected;
    assert.deepEqual((await request('GET', selected, as(viewer))).items, []);
    assert.deepEqual((await request('GET', selected, as(recipient))).items, []);
    await request('POST', adminPath, as(admin), {
      version: 1,
      action: 'admin_approve',
      reason: 'Both profiles eligible',
    });
    await request('POST', customerPath, as(sender), { version: 2, action: 'accept' }, { status: 409 });
    await request('POST', customerPath, as(recipient), { version: 2, action: 'accept' });
    assert.equal((await request('GET', selectedForAdmin, as(admin))).items[0].canAuthorize, 0);
    await request(
      'POST',
      adminPath,
      as(admin),
      { version: 3, action: 'authorize', reason: 'Test denied' },
      { status: 409 },
    );
    await request('PUT', '/interests/' + id + '/consent', as(sender), { granted: true });
    await request('PUT', '/interests/' + id + '/consent', as(recipient), { granted: true });
    assert.equal((await request('GET', selectedForAdmin, as(admin))).items[0].canAuthorize, 1);
    assert.equal((await request('GET', selected, as(recipient))).items[0].canAuthorize, 0);
    await request('POST', adminPath, as(admin), {
      version: 3,
      action: 'authorize',
      reason: 'Both consented',
    });
    assert.equal((await request('GET', contact, as(sender))).email, 'recipient@example.test');
    assert.equal((await request('GET', selected, as(sender))).items[0].canViewContact, 1);
    await request('GET', contact, as(viewer), undefined, { status: 404 });
    await request('PUT', '/interests/' + id + '/consent', as(recipient), { granted: false });
    assert.equal((await request('GET', selected, as(sender))).items[0].canViewContact, 0);
    await request('GET', contact, as(sender), undefined, { status: 404 });
    await request('PUT', '/blocks/' + second.id, as(sender), {});
    await request('GET', '/discover/' + first.id, as(recipient), undefined, { status: 404 });
    assert.equal((await request('GET', '/blocks', as(sender))).items[0].profileId, second.id);
    assert.deepEqual((await request('GET', '/blocks', as(recipient))).items, []);
    await request('DELETE', '/blocks/' + second.id, as(sender));
    assert.deepEqual((await request('GET', '/blocks', as(sender))).items, []);
    await request('GET', '/discover/' + first.id, as(recipient));
  });

  await t.test(
    'privacy requests require fresh verification; admin moderation reasons are recorded',
    async () => {
      const code = await request('POST', '/auth/security-code', as(viewer), {}, { status: 202 });
      const privacy = await request(
        'POST',
        '/privacy-requests',
        as(viewer),
        { kind: 'export', challengeId: code.challengeId, code: code.localTestCode },
        { status: 201 },
      );
      await request('POST', '/admin/privacy-requests/' + privacy.id + '/close', as(admin), {
        reason: 'Synthetic export fulfilled',
      });
      assert.equal((await request('GET', '/privacy-requests', as(viewer))).items[0].status, 'closed');
      assert.deepEqual((await request('GET', '/privacy-requests', as(sender))).items, []);
      const moderation = await request('GET', '/admin/moderation/' + privacy.id, as(admin));
      assert.equal(moderation.items[0].reason, 'Synthetic export fulfilled');
    },
  );

  await t.test('notifications survive reconciliation replay and remain scoped to account', async () => {
    const endpoint = '/notifications';
    await request('POST', '/_local/reconcile', null, {});
    const delivery = await fetch('http://127.0.0.1:' + instance.port + '/__test-email-failure', {
      headers: { 'x-local-fixture-key': secret },
    });
    assert.equal(delivery.status, 200);
    const retried = (
      await sqlBatch('DB_OPERATIONS', [
        {
          sql: "SELECT count(*) AS count FROM jm_email_jobs WHERE status='pending' AND attempts=1 AND last_error='provider_error'",
          params: [],
        },
      ])
    )[0].results[0];
    assert(retried.count > 0);
    const before = await request('GET', endpoint, as(sender));
    assert(before.unread > 0);
    const notification = before.items[0].id;
    await sqlBatch('DB_MAIN', [
      { sql: 'UPDATE jm_outbox SET processed_at=NULL WHERE id=?', params: [notification] },
    ]);
    await request('POST', '/_local/reconcile', null, {});
    const notificationQuery = (
      await sqlBatch('DB_OPERATIONS', [
        { sql: 'SELECT count(*) AS count FROM jm_notifications WHERE id=?', params: [notification] },
      ])
    )[0].results[0];
    assert.equal(notificationQuery.count, 1);
    await request('POST', endpoint + '/' + notification + '/read', as(viewer), {});
    assert.equal((await request('GET', endpoint, as(sender))).unread, before.unread);
    await request('POST', endpoint + '/' + notification + '/read', as(sender), {});
    assert.equal((await request('GET', endpoint, as(sender))).unread, before.unread - 1);
    const adminBefore = await request('GET', endpoint, as(admin));
    const review = adminBefore.items.find((item) => item.kind === 'profile.submitted');
    assert(review);
    await request('POST', endpoint + '/' + review.id + '/read', as(viewer), {});
    assert.equal((await request('GET', endpoint, as(admin))).unread, adminBefore.unread);
    await request('POST', endpoint + '/' + review.id + '/read', as(admin), {});
    assert.equal((await request('GET', endpoint, as(admin))).unread, adminBefore.unread - 1);
  });

  await t.test(
    'admin documents are private, verified, and retryable after the PC is unavailable',
    async (storageTest) => {
      const directory = resolve(await mkdtemp('.wrangler/objects'));
      const origin = await startStorage(directory);
      storageTest.after(origin.stop);
      const png = Buffer.from('89504e470d0a1a0a73796e746865746963', 'hex');
      const checksum = createHash('sha256').update(png).digest('hex');
      const file = randomUUID();
      const retry = randomUUID();
      const docs = '/admin/profiles/' + first.id + '/documents';
      async function transfer(
        method,
        path,
        { target = origin.url, token = as(admin), hash = checksum, status = 200, originToken } = {},
      ) {
        const headers = { 'x-local-fixture-key': secret, 'x-test-storage-origin': target };
        if (token) headers.Authorization = 'Bearer ' + token;
        if (originToken) headers['x-test-storage-token'] = originToken;
        if (method === 'PUT') {
          headers['Content-Type'] = 'image/png';
          headers['X-Content-SHA256'] = hash;
        }
        const response = await fetch('http://127.0.0.1:' + instance.port + path, {
          method,
          headers,
          body: method === 'PUT' ? png : undefined,
        });
        assert.equal(response.status, status, response.status === status ? '' : await response.text());
        return response;
      }
      const url = (id) => '/admin/documents/' + id;
      const upload = (id, options) => transfer('PUT', url(id) + '?profileId=' + first.id, options);
      await transfer('GET', docs, { token: null, status: 401 });
      await transfer('GET', docs, { token: as(sender), status: 403 });
      await upload(file, { token: 'a'.repeat(64), status: 401 });
      await upload(file, { hash: '0'.repeat(64), status: 422 });
      await upload(file, { originToken: 'x'.repeat(32), status: 503 });
      assert.equal((await (await transfer('GET', '/readiness')).json()).data.uploads, 'online');
      assert.equal((await (await upload(file)).json()).data.state, 'confirmed');
      await upload(file);
      await transfer('GET', url(file), { token: as(sender), status: 403 });
      const download = await transfer('GET', url(file));
      assert.equal(download.headers.get('cache-control'), 'no-store');
      assert.equal(download.headers.get('content-disposition'), 'attachment');
      assert.deepEqual(Buffer.from(await download.arrayBuffer()), png);
      await origin.stop();
      await upload(retry, { status: 503 });
      await transfer('GET', url(file), { status: 503 });
      const failed = (await (await transfer('GET', docs)).json()).data.items;
      assert.equal(failed.find((row) => row.id === retry).state, 'failed');
      const restarted = await startStorage(directory);
      storageTest.after(restarted.stop);
      assert.equal((await (await upload(retry, { target: restarted.url })).json()).data.state, 'confirmed');
      await writeFile(resolve(directory, file), 'synthetic corrupted bytes');
      await transfer('GET', url(file), { target: restarted.url, status: 503 });
      await request('POST', '/_local/reconcile', null, {});
      const [audit] = await sqlBatch('DB_OPERATIONS', [
        { sql: 'SELECT action FROM jm_audit WHERE entity_id=?', params: [file] },
      ]);
      assert.deepEqual(audit.results.map((row) => row.action).sort(), [
        'storage.confirmed',
        'storage.download_failed',
        'storage.download_failed',
        'storage.downloaded',
        'storage.upload_failed',
      ]);
    },
  );
});

import {
  Actor,
  Env,
  Failure,
  JsonObject,
  body,
  change,
  digest,
  forbidden,
  identifier,
  missing,
  object,
  rate,
  statement,
  unix,
} from './core';
import * as auth from './auth';
import * as adminAuth from './admin-auth';
import * as profile from './profiles';
import * as discovery from './discovery';
import * as matching from './matching';
import * as ops from './operations';
import * as moderation from './moderation';
import * as storage from './storage';
import * as infra from './infrastructure';

interface Context extends auth.AuthContext {
  url: URL;
  actor?: Actor;
  input: JsonObject;
  id?: string;
}
type Handler = (context: Context) => unknown | Promise<unknown>;
type Access = 'public' | 'signed_in' | 'customer' | 'admin';
interface Route {
  method: string;
  path: string;
  access: Access;
  handler: Handler;
  status: number;
  idempotent: boolean;
}
const routes: Route[] = [];
function route(
  method: string,
  path: string,
  access: Access,
  handler: Handler,
  status = 200,
  idempotent = false,
) {
  routes.push({ method, path, access, handler, status, idempotent });
}
const providerActor = (c: Context) => c.actor!;
const id = (c: Context) => c.id!;

route('GET', '/admin/infrastructure', 'admin', (c) => infra.status(c.env));
route('POST', '/admin/infrastructure/enroll', 'admin', (c) => infra.enroll(c.env, providerActor(c), c.input));
route('POST', '/admin/infrastructure/activate', 'admin', (c) =>
  infra.promote(c.env, providerActor(c), c.input),
);
route('POST', '/admin/infrastructure/control', 'admin', (c) =>
  infra.transition(c.env, providerActor(c), c.input),
);
route('POST', '/storage/origin/backup', 'public', (c) => infra.backupApi(c.env, c.input));
route('POST', '/storage/enrollment/claim', 'public', async (c) => {
  await rate(
    c.env.DB_MAIN,
    'origin-claim:' + (c.request.headers.get('cf-connecting-ip') ?? 'unknown'),
    20,
    300,
  );
  return infra.claim(c.env, c.input);
});
route('GET', '/customer/profiles/:id/files', 'customer', (c) =>
  storage.ownFiles(c.env, providerActor(c), id(c), c.url),
);
route('GET', '/customer/files/:id', 'customer', async (c) => {
  const f = await storage.download(c.env, providerActor(c), id(c));
  return new Response(f.data, {
    headers: { 'content-type': f.mime, 'content-disposition': 'attachment', 'x-content-sha256': f.sha256 },
  });
});
route('PUT', '/customer/files/:id', 'customer', (c) =>
  storage.upload(c.env, providerActor(c), id(c), c.request, c.url),
);
route('GET', '/health', 'public', () => ({ status: 'ok' }));
route('GET', '/readiness', 'admin', async (c) => {
  await Promise.all([
    c.env.DB_MAIN.prepare('SELECT id FROM jm_accounts LIMIT 1').first(),
    c.env.DB_OPERATIONS.prepare('SELECT id FROM jm_audit LIMIT 1').first(),
  ]);
  return {
    status: 'ok',
    emailConfigured: auth.mailConfigured(c.env),
    uploads: await storage.storageStatus(c.env),
    push: 'unavailable',
  };
});
route('POST', '/auth/otp/request', 'public', (c) => auth.loginRequest(c, c.input), 202);
route('POST', '/auth/otp/verify', 'public', (c) => auth.loginVerify(c, c.input));
route('POST', '/admin/auth/login', 'public', (c) => adminAuth.login(c, c.input));
route('POST', '/admin/auth/password', 'admin', (c) => adminAuth.changePassword(c.env, providerActor(c), c.input));
route('POST', '/auth/refresh', 'public', (c) => auth.refresh(c.env, c.input));
route('POST', '/auth/logout', 'signed_in', (c) => auth.logout(c.env, providerActor(c)));
route('POST', '/auth/claim-code', 'customer', (c) => auth.claimCode(c, providerActor(c)), 202);
route('POST', '/auth/security-code', 'customer', (c) => auth.securityCode(c, providerActor(c)), 202);
route('POST', '/auth/new-email-code', 'customer', (c) => auth.newEmailCode(c, c.input), 202);
route('POST', '/auth/change-email', 'customer', (c) =>
  ops.changeEmail(c, providerActor(c), {
    ...c.input,
    current: object(c.input.current),
    next: object(c.input.next),
  }),
);
route('GET', '/me', 'signed_in', (c) => {
  const { id, role, email } = providerActor(c);
  return role === 'admin' ? { id, role } : { id, role, email };
});
route('GET', '/profiles', 'customer', (c) => profile.myProfiles(c.env, providerActor(c)));
route(
  'POST',
  '/profiles',
  'customer',
  (c) => profile.createProfile(c.env, providerActor(c), c.input),
  201,
  true,
);
route(
  'POST',
  '/profiles/claim',
  'customer',
  (c) => profile.claimProfile(c, providerActor(c), c.input),
  201,
  true,
);
route('GET', '/profiles/:id', 'signed_in', (c) => profile.getProfile(c.env, providerActor(c), id(c)));
route('PUT', '/profiles/:id', 'signed_in', (c) => profile.saveDraft(c.env, providerActor(c), id(c), c.input));
route(
  'POST',
  '/profiles/:id/submit',
  'signed_in',
  (c) => profile.submitProfile(c.env, providerActor(c), id(c), c.input),
  201,
  true,
);
route(
  'PUT',
  '/profiles/:id/visibility',
  'customer',
  (c) => profile.updateVisibility(c.env, providerActor(c), id(c), c.input),
  200,
  true,
);
route('GET', '/search', 'customer', (c) => discovery.search(c.env, providerActor(c), c.url));
route('GET', '/discover/:id', 'customer', (c) => discovery.publicDetail(c.env, providerActor(c), id(c)));
route('GET', '/recommendations', 'customer', (c) =>
  discovery.recommendations(c.env, providerActor(c), c.url),
);
route('GET', '/favorites', 'customer', (c) => discovery.favorites(c.env, providerActor(c), c.url));
route('PUT', '/favorites/:id', 'customer', (c) => discovery.favorite(c.env, providerActor(c), id(c), true));
route('DELETE', '/favorites/:id', 'customer', (c) =>
  discovery.favorite(c.env, providerActor(c), id(c), false),
);
route('GET', '/saved-searches', 'customer', (c) => discovery.saved(c.env, providerActor(c), c.url));
route(
  'POST',
  '/saved-searches',
  'customer',
  (c) => discovery.saveSearch(c.env, providerActor(c), c.input),
  201,
  true,
);
route('PUT', '/saved-searches/:id', 'customer', (c) =>
  discovery.saveSearch(c.env, providerActor(c), c.input, id(c)),
);
route('DELETE', '/saved-searches/:id', 'customer', (c) =>
  discovery.removeSearch(c.env, providerActor(c), id(c)),
);
route('GET', '/interests', 'customer', (c) => matching.interests(c.env, providerActor(c), c.url));
route(
  'POST',
  '/interests',
  'customer',
  (c) => matching.sendInterest(c.env, providerActor(c), c.input),
  201,
  true,
);
route(
  'POST',
  '/interests/:id/decision',
  'customer',
  (c) => matching.transition(c.env, providerActor(c), id(c), c.input),
  200,
  true,
);
route(
  'PUT',
  '/interests/:id/consent',
  'customer',
  (c) => matching.consent(c.env, providerActor(c), id(c), c.input),
  200,
  true,
);
route('GET', '/interests/:id/contact', 'customer', (c) => matching.contact(c.env, providerActor(c), id(c)));
route('GET', '/blocks', 'customer', (c) => matching.blockedProfiles(c.env, providerActor(c), c.url));
route(
  'PUT',
  '/blocks/:id',
  'customer',
  (c) => matching.block(c.env, providerActor(c), id(c), true),
  200,
  true,
);
route(
  'DELETE',
  '/blocks/:id',
  'customer',
  (c) => matching.block(c.env, providerActor(c), id(c), false),
  200,
  true,
);
route('POST', '/reports', 'customer', (c) => matching.report(c.env, providerActor(c), c.input), 201, true);
route('GET', '/claims', 'customer', (c) => moderation.ownClaims(c.env, providerActor(c), c.url));
route('GET', '/privacy-requests', 'customer', (c) =>
  moderation.privacyRequests(c.env, providerActor(c), c.url),
);
route(
  'POST',
  '/privacy-requests',
  'customer',
  (c) => ops.privacyRequest(c, providerActor(c), c.input),
  201,
  true,
);
route('GET', '/notifications', 'signed_in', (c) => ops.notificationList(c.env, providerActor(c), c.url));
route('POST', '/notifications/:notification/read', 'signed_in', (c) =>
  ops.readNotification(c.env, providerActor(c), id(c)),
);
route('GET', '/admin/dashboard', 'admin', (c) => ops.dashboard(c.env));
route('GET', '/admin/profiles/:id/documents', 'admin', (c) => storage.documents(c.env, id(c), c.url));
route('PUT', '/admin/documents/:id', 'admin', (c) =>
  storage.upload(c.env, providerActor(c), id(c), c.request, c.url),
);
route('GET', '/admin/documents/:id', 'admin', async (c) => {
  const file = await storage.download(c.env, providerActor(c), id(c));
  return new Response(file.data, {
    headers: {
      'content-type': file.mime,
      'content-disposition': 'attachment',
      'content-security-policy': "default-src 'none'; sandbox",
      'x-content-sha256': file.sha256,
    },
  });
});
for (const queue of ops.adminQueues)
  route('GET', '/admin/' + queue, 'admin', (c) => ops.adminList(c.env, c.url, queue));
route(
  'POST',
  '/admin/profiles',
  'admin',
  (c) => profile.createProfile(c.env, providerActor(c), c.input),
  201,
  true,
);
route(
  'PUT',
  '/admin/profiles/:id/suspension',
  'admin',
  (c) => profile.suspendProfile(c.env, providerActor(c), id(c), c.input),
  200,
  true,
);
route(
  'POST',
  '/admin/revisions/:id/decision',
  'admin',
  (c) => profile.reviewProfile(c.env, providerActor(c), id(c), c.input),
  200,
  true,
);
route(
  'POST',
  '/admin/claims/:id/decision',
  'admin',
  (c) => profile.reviewClaim(c.env, providerActor(c), id(c), c.input),
  200,
  true,
);
route('GET', '/admin/interests', 'admin', (c) => matching.interests(c.env, providerActor(c), c.url));
route(
  'POST',
  '/admin/interests/:id/decision',
  'admin',
  (c) => matching.transition(c.env, providerActor(c), id(c), c.input),
  200,
  true,
);
route(
  'PUT',
  '/admin/accounts/:id/suspension',
  'admin',
  (c) => ops.setAccountStatus(c.env, providerActor(c), id(c), c.input),
  200,
  true,
);
route(
  'POST',
  '/admin/reports/:id/close',
  'admin',
  (c) => ops.closeReport(c.env, providerActor(c), id(c), c.input),
  200,
  true,
);
route('GET', '/admin/moderation/:id', 'admin', (c) => moderation.moderationHistory(c.env, id(c)));
route(
  'POST',
  '/admin/privacy-requests/:id/close',
  'admin',
  (c) => moderation.closePrivacyRequest(c.env, providerActor(c), id(c), c.input),
  200,
  true,
);
route('POST', '/_local/reconcile', 'public', (c) =>
  auth.localFixture(c) ? ops.reconcile(c.env) : missing(),
);

function match(path: string, pattern: string): false | { id?: string } {
  const segments = path.split('/');
  const target = pattern.split('/');
  if (segments.length !== target.length) return false;
  let result: string | undefined;
  for (let i = 0; i < target.length; i++) {
    if (target[i].startsWith(':')) {
      if (!segments[i]) return false;
      if (target[i] === ':notification' && !/^[a-z0-9:-]{1,150}$/.test(segments[i])) return false;
      result = segments[i];
    } else if (segments[i] !== target[i]) return false;
  }
  return { id: result };
}

async function execute(c: Context, selected: Route) {
  if (!selected.idempotent) return selected.handler(c);
  const key = c.request.headers.get('idempotency-key') ?? '';
  if (!/^[a-zA-Z0-9_-]{16,100}$/.test(key))
    throw new Failure(400, 'idempotency_required', 'Provide a valid Idempotency-Key header.');
  const db = c.env.DB_MAIN;
  const actor = c.actor!.id;
  const path = c.request.method + ' ' + c.url.pathname;
  const hash = await digest(JSON.stringify(c.input));
  const reserved = await change(
    db,
    'INSERT OR IGNORE INTO jm_idempotency(actor,route,key,digest,created_at) VALUES(?,?,?,?,?)',
    actor,
    path,
    key,
    hash,
    unix(),
  );
  if (!reserved) {
    const saved = await statement(
      db,
      'SELECT digest,status,response FROM jm_idempotency WHERE actor=? AND route=? AND key=?',
      actor,
      path,
      key,
    ).first<{ digest: string; status: number | null; response: string | null }>();
    if (saved?.digest === hash && saved.status === selected.status && saved.response)
      return JSON.parse(saved.response);
    throw new Failure(
      409,
      'idempotency_conflict',
      'This request key is already in use. Refresh the record before retrying.',
    );
  }
  let result: unknown;
  try {
    result = await selected.handler(c);
  } catch (error) {
    if (error instanceof Failure && error.status < 500)
      await change(
        db,
        'DELETE FROM jm_idempotency WHERE actor=? AND route=? AND key=? AND status IS NULL',
        actor,
        path,
        key,
      );
    throw error;
  }
  await change(
    db,
    'UPDATE jm_idempotency SET status=?,response=? WHERE actor=? AND route=? AND key=?',
    selected.status,
    JSON.stringify(result),
    actor,
    path,
    key,
  );
  return result;
}

async function fetchApi(request: Request, env: Env, ctx: ExecutionContext) {
  const url = new URL(request.url);
  const requestId = crypto.randomUUID();
  const headers = new Headers({
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'x-request-id': requestId,
    'referrer-policy': 'no-referrer',
    vary: 'Origin',
  });
  const origin = request.headers.get('origin');
  const allowed = (env.ALLOWED_ORIGINS ?? '').split(',').map((item) => item.trim());
  const reply = (status: number, data: unknown) => Response.json(data, { status, headers });
  try {
    if (origin) {
      if (!allowed.includes(origin)) return forbidden();
      headers.set('access-control-allow-origin', origin);
      if (request.method === 'OPTIONS') {
        headers.set('access-control-allow-methods', 'GET, POST, PUT, DELETE, OPTIONS');
        headers.set('access-control-allow-headers', 'Authorization, Content-Type, Idempotency-Key');
        return new Response(null, { status: 204, headers });
      }
    }
    const c: Context = { env, request, url, input: {} };
    if (/^\/files(?:\/|$)/.test(url.pathname)) {
      await auth.authenticate(c);
      throw new Failure(503, 'storage_unavailable', 'Photo and document transfer is currently unavailable.');
    }
    for (const selected of routes) {
      if (selected.method !== request.method) continue;
      const hit = match(url.pathname, selected.path);
      if (!hit) continue;
      if (selected.access !== 'public') {
        c.actor = await auth.authenticate(c);
        if (selected.access !== 'signed_in' && selected.access !== c.actor.role) return forbidden();
        if (request.method !== 'GET') await rate(env.DB_MAIN, 'write:' + c.actor.id, 120, 300);
      }
      c.id = hit.id && !selected.path.includes(':notification') ? identifier(hit.id) : hit.id;
      if (
        ['POST', 'PUT'].includes(request.method) &&
        !['/admin/documents/:id', '/customer/files/:id'].includes(selected.path)
      )
        c.input = await body(request);
      const result = await execute(c, selected);
      if (c.actor && (request.method !== 'GET' || result instanceof Response))
        ctx.waitUntil(ops.reconcile(env).catch(() => undefined));
      if (result instanceof Response) {
        result.headers.forEach((value, key) => headers.set(key, value));
        return new Response(result.body, { status: result.status, headers });
      }
      return reply(selected.status, { code: 'ok', message: 'Request completed.', requestId, data: result });
    }
    return missing();
  } catch (error) {
    if (error instanceof Failure)
      return reply(error.status, {
        code: error.code,
        message: error.message,
        fields: error.fields,
        requestId,
      });
    console.error('Request failed', requestId, request.method);
    return reply(500, { code: 'internal_error', message: 'The request could not be completed.', requestId });
  }
}

export default {
  fetch: fetchApi,
  scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(storage.syncPending(env));
    ctx.waitUntil(
      (async () => {
        await matching.expireInterests(env);
        await ops.reconcile(env);
        await ops.deliverEmails(env);
        const time = unix();
        await env.DB_MAIN.batch([
          statement(
            env.DB_MAIN,
            'DELETE FROM jm_otp WHERE expires<? AND id NOT IN (SELECT challenge_id FROM jm_claims)',
            time - 86400,
          ),
          statement(env.DB_MAIN, 'DELETE FROM jm_sessions WHERE refresh_until<?', time - 86400),
          statement(
            env.DB_MAIN,
            'DELETE FROM jm_idempotency WHERE created_at<? AND status IS NOT NULL',
            time - 86400,
          ),
        ]);
      })(),
    );
  },
} satisfies ExportedHandler<Env>;

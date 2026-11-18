import { Actor, Env, Failure, JsonObject, change, digest, email, identifier, invalid, keyed, now, randomToken, rate, same, statement, str, uid, unix, unauthorized } from './core';

export interface AuthContext {
  env: Env;
  request: Request;
}

export function localFixture({ env, request }: AuthContext): boolean {
  const hostname = new URL(request.url).hostname;
  return env.JAIN_LOCAL_TEST === 'true' && (hostname === '127.0.0.1' || hostname === 'localhost') &&
    !!env.LOCAL_FIXTURE_KEY && env.LOCAL_FIXTURE_KEY.length >= 32 &&
    same(env.LOCAL_FIXTURE_KEY, request.headers.get('x-local-fixture-key') ?? '');
}

export function mailConfigured(env: Env) {
  return Boolean(env.BREVO_API_KEY && env.BREVO_SENDER_EMAIL);
}

export async function sendMail(env: Env, to: string, subject: string, message: string, key?: string, sender = fetch) {
  if (!mailConfigured(env)) throw new Failure(503, 'email_unavailable', 'Email delivery is temporarily unavailable.');
  const response = await sender('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    signal: AbortSignal.timeout(8000),
    headers: { 'Content-Type': 'application/json', 'api-key': env.BREVO_API_KEY! },
    body: JSON.stringify({
      sender: { email: env.BREVO_SENDER_EMAIL, name: env.BREVO_SENDER_NAME || 'Jain Matrimonial' },
      to: [{ email: to }], subject, textContent: message,
      ...(key ? { headers: { idempotencyKey: key } } : {}),
    }),
  });
  if (!response.ok) throw new Failure(503, 'email_unavailable', 'Email delivery is temporarily unavailable.');
}

function otpCode() {
  const space = 4294000000;
  const buffer = new Uint32Array(1);
  do crypto.getRandomValues(buffer); while (buffer[0] >= space);
  return String(buffer[0] % 1000000).padStart(6, '0');
}

async function requestCode(context: AuthContext, address: string, purpose: 'login' | 'claim' | 'security' | 'email_change') {
  const { env, request } = context;
  const db = env.DB_MAIN;
  const local = localFixture(context);
  if (!local && !mailConfigured(env)) throw new Failure(503, 'email_unavailable', 'Email delivery is temporarily unavailable.');
  const ip = request.headers.get('cf-connecting-ip') ?? 'local';
  const [ipBucket, addressBucket] = await Promise.all([keyed(env, 'ip:' + ip), keyed(env, 'address:' + address)]);
  await rate(db, 'issue-ip:' + ipBucket, 25, 900);
  await rate(db, 'issue-email:' + addressBucket, 5, 3600);
  const id = uid();
  const code = otpCode();
  const time = unix();
  const hash = await keyed(env, id + ':' + purpose + ':' + code);
  const accepted = await change(db, `INSERT INTO jm_otp (id,email,purpose,code_hash,expires,attempts,issued_at)
    SELECT ?,?,?,?,?,5,? WHERE NOT EXISTS(SELECT 1 FROM jm_otp WHERE email=? AND purpose=? AND issued_at>?)`,
    id, address, purpose, hash, time + 600, time, address, purpose, time - 45);
  if (!accepted) throw new Failure(429, 'rate_limited', 'Please wait before requesting another code.');
  if (!local) {
    try {
      await sendMail(env, address, 'Your Jain Matrimonial verification code',
        'Your verification code is ' + code + '. It expires in 10 minutes. Do not share it.');
    } catch {
      await change(db, 'UPDATE jm_otp SET consumed_at=? WHERE id=?', time, id);
      throw new Failure(503, 'email_unavailable', 'Email delivery is temporarily unavailable.');
    }
  }
  return local ? { challengeId: id, localTestCode: code } : { challengeId: id };
}

export const loginRequest = (context: AuthContext, data: JsonObject) => requestCode(context, email(data.email), 'login');
export const claimCode = (context: AuthContext, actor: Actor) => requestCode(context, actor.email, 'claim');
export const securityCode = (context: AuthContext, actor: Actor) => requestCode(context, actor.email, 'security');
export const newEmailCode = (context: AuthContext, data: JsonObject) => requestCode(context, email(data.email), 'email_change');

export async function verifyCode(context: AuthContext, data: JsonObject, purpose: string, expectedEmail?: string) {
  const id = identifier(data.challengeId, 'challengeId');
  const code = str(data.code, 'code', 6, 6);
  if (!/^\d{6}$/.test(code)) return invalid('code', 'Enter a six-digit verification code.');
  const { env, request } = context;
  const db = env.DB_MAIN;
  const ip = await keyed(env, 'verify:' + (request.headers.get('cf-connecting-ip') ?? 'local'));
  await rate(db, 'verify-ip:' + ip, 100, 900);
  const hash = await keyed(env, id + ':' + purpose + ':' + code);
  const time = unix();
  const result = await statement(db, `UPDATE jm_otp SET attempts=attempts-1,
    consumed_at=CASE WHEN code_hash=? THEN ? ELSE NULL END
    WHERE id=? AND purpose=? AND (? IS NULL OR email=?) AND attempts>0 AND expires>? AND consumed_at IS NULL
    AND NOT EXISTS(SELECT 1 FROM jm_otp AS newer WHERE newer.email=jm_otp.email AND newer.purpose=jm_otp.purpose AND newer.issued_at>jm_otp.issued_at)
    RETURNING email, consumed_at`, hash, time, id, purpose, expectedEmail ?? null, expectedEmail ?? null, time)
    .first<{ email: string; consumed_at: number | null }>();
  if (!result?.consumed_at) throw new Failure(400, 'invalid_code', 'The code is invalid or expired.');
  return { id, email: result.email };
}

async function newTokens() {
  const accessToken = randomToken();
  const refreshToken = randomToken();
  const [accessHash, refreshHash] = await Promise.all([digest(accessToken), digest(refreshToken)]);
  return { accessToken, refreshToken, accessHash, refreshHash };
}

export async function loginVerify(context: AuthContext, data: JsonObject) {
  const { email: address } = await verifyCode(context, data, 'login');
  const db = context.env.DB_MAIN;
  const time = now();
  const account = await statement(db, `INSERT INTO jm_accounts(id,email,verified_at,created_at)
    VALUES(?,?,?,?) ON CONFLICT(email) DO UPDATE SET verified_at=excluded.verified_at WHERE jm_accounts.status='active'
    RETURNING id,email,role`, uid(), address, time, time).first<{ id: string; email: string; role: string }>();
  if (!account) return unauthorized();
  const token = await newTokens();
  const seconds = unix();
  await statement(db, 'INSERT INTO jm_sessions VALUES(?,?,?,?,?,?,?,NULL)',
    uid(), account.id, token.accessHash, token.refreshHash, seconds + 900, seconds + 2592000, seconds).run();
  return { account, accessToken: token.accessToken, refreshToken: token.refreshToken, expiresIn: 900 };
}

export async function authenticate(context: AuthContext): Promise<Actor> {
  const token = context.request.headers.get('authorization')?.match(/^Bearer ([a-f0-9]{64})$/)?.[1];
  if (!token) return unauthorized();
  const actor = await statement(context.env.DB_MAIN, `SELECT a.id,a.email,a.role,s.id AS sessionId
    FROM jm_sessions s JOIN jm_accounts a ON a.id=s.account_id
    WHERE s.access_hash=? AND s.access_until>? AND s.revoked_at IS NULL AND a.status='active'`,
    await digest(token), unix()).first<Actor>();
  return actor ?? unauthorized();
}

export async function refresh(env: Env, data: JsonObject) {
  const previous = str(data.refreshToken, 'refreshToken', 64, 64);
  const next = await newTokens();
  const time = unix();
  const updated = await change(env.DB_MAIN, `UPDATE jm_sessions SET access_hash=?,refresh_hash=?,access_until=?,rotated_at=?
    WHERE refresh_hash=? AND refresh_until>? AND revoked_at IS NULL
    AND EXISTS(SELECT 1 FROM jm_accounts WHERE id=account_id AND status='active')`,
    next.accessHash, next.refreshHash, time + 900, time, await digest(previous), time);
  if (!updated) return unauthorized();
  return { accessToken: next.accessToken, refreshToken: next.refreshToken, expiresIn: 900 };
}

export async function logout(env: Env, actor: Actor) {
  await change(env.DB_MAIN, 'UPDATE jm_sessions SET revoked_at=? WHERE id=? AND revoked_at IS NULL', unix(), actor.sessionId);
  return {};
}

export async function fixtureAdmin(context: AuthContext, data: JsonObject) {
  if (!localFixture(context)) throw new Failure(404, 'not_found', 'The requested record is unavailable.');
  const address = email(data.email);
  if (!address.endsWith('@example.test')) return invalid('email', 'Use a synthetic example.test identity.');
  const time = now();
  const account = await statement(context.env.DB_MAIN, `INSERT INTO jm_accounts(id,email,role,verified_at,created_at)
    VALUES(?,?,'admin',?,?) ON CONFLICT(email) DO UPDATE SET role='admin' RETURNING id`, uid(), address, time, time).first();
  return account;
}


import { AuthContext, issueSession } from './auth';
import {
  Actor,
  Env,
  Failure,
  JsonObject,
  change,
  conflict,
  invalid,
  keyed,
  now,
  randomToken,
  rate,
  statement,
  unix,
} from './core';

const scheme = 'pbkdf2-sha256-100k:v1';
const iterations = 100_000;
const encoding = new TextEncoder();
const verifierPattern = /^pbkdf2-sha256-100k:v1:([a-f0-9]{64}):([a-f0-9]{64})$/;
const unavailable = () =>
  new Failure(503, 'admin_sign_in_unavailable', 'Administrator sign-in is unavailable.');

interface Credential {
  id: string;
  verifier: string;
  version: number;
}

function fromHex(value: string) {
  return Uint8Array.from(value.match(/../g)!, (byte) => parseInt(byte, 16));
}

async function derive(env: Env, password: string, salt: string) {
  const pepper = env.ADMIN_PASSWORD_PEPPER ?? '';
  if (!/^[a-f0-9]{64}$/.test(pepper)) throw unavailable();
  const prf = await crypto.subtle.importKey(
    'raw',
    fromHex(pepper),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const material = await crypto.subtle.sign('HMAC', prf, encoding.encode(password));
  const key = await crypto.subtle.importKey('raw', material, 'PBKDF2', false, ['deriveBits']);
  return new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: 'PBKDF2', salt: fromHex(salt), iterations, hash: 'SHA-256' },
      key,
      256,
    ),
  );
}

function passwordField(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value.length || /[\ud800-\udfff]/u.test(value))
    return invalid(field, 'Enter a password.');
  return value;
}

function credential(env: Env, sessionId: string | null = null) {
  return statement(
    env.DB_MAIN,
    `SELECT a.id,c.verifier,c.version FROM jm_admin_credentials c
    JOIN jm_accounts a ON a.id=c.account_id WHERE c.slot=1 AND a.role='admin' AND a.status='active'
    AND (? IS NULL OR EXISTS(SELECT 1 FROM jm_admin_session_versions v JOIN jm_sessions s ON s.id=v.session_id
      WHERE v.session_id=? AND v.version=c.version AND s.account_id=a.id AND s.revoked_at IS NULL))`,
    sessionId,
    sessionId,
  ).first<Credential>();
}

async function matches(env: Env, password: string, verifier: string) {
  const parsed = verifierPattern.exec(verifier);
  if (!parsed) throw unavailable();
  return crypto.subtle.timingSafeEqual(await derive(env, password, parsed[1]), fromHex(parsed[2]));
}

export async function login(context: AuthContext, input: JsonObject) {
  const { env, request } = context;
  const network = await keyed(env, 'admin-login:' + (request.headers.get('cf-connecting-ip') ?? 'local'));
  await rate(env.DB_MAIN, 'admin-login:ip:' + network, 6, 600);
  await rate(env.DB_MAIN, 'admin-login:account', 30, 600);
  const password = passwordField(input.password, 'password');
  const saved = await credential(env);
  if (!saved) throw unavailable();
  if (!(await matches(env, password, saved.verifier))) {
    throw new Failure(401, 'invalid_admin_password', 'The administrator password is incorrect.');
  }
  return issueSession(env, { id: saved.id, role: 'admin' }, saved.version);
}

export async function changePassword(env: Env, actor: Actor, input: JsonObject) {
  await rate(env.DB_MAIN, 'admin-password-change:' + actor.id, 6, 600);
  const current = passwordField(input.currentPassword, 'currentPassword');
  const next = passwordField(input.newPassword, 'newPassword');
  if (next !== input.confirmPassword) return invalid('confirmPassword', 'The new passwords do not match.');
  if (next === current) return invalid('newPassword', 'Choose a different password.');
  const saved = await credential(env, actor.sessionId);
  if (!saved || saved.id !== actor.id) return conflict();
  if (!(await matches(env, current, saved.verifier)))
    throw new Failure(403, 'invalid_current_password', 'The current password is incorrect.');
  const salt = randomToken();
  const derived = await derive(env, next, salt);
  const verifier =
    scheme + ':' + salt + ':' + Array.from(derived, (byte) => byte.toString(16).padStart(2, '0')).join('');
  const updated = await change(
    env.DB_MAIN,
    `UPDATE jm_admin_credentials
    SET verifier=?,version=version+1,changed_at=? WHERE slot=1 AND account_id=? AND version=?
    AND EXISTS(SELECT 1 FROM jm_sessions s JOIN jm_accounts a ON a.id=s.account_id
      JOIN jm_admin_session_versions v ON v.session_id=s.id
      WHERE s.id=? AND s.account_id=jm_admin_credentials.account_id AND s.revoked_at IS NULL
        AND v.version=jm_admin_credentials.version AND s.refresh_until>? AND a.status='active' AND a.role='admin')`,
    verifier,
    now(),
    actor.id,
    saved.version,
    actor.sessionId,
    unix(),
  );
  if (!updated) return conflict();
  return {};
}

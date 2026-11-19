export interface Env {
  DB_MAIN: D1Database;
  DB_OPERATIONS: D1Database;
  AUTH_SECRET?: string;
  ADMIN_PASSWORD_PEPPER?: string;
  BREVO_API_KEY?: string;
  BREVO_SENDER_EMAIL?: string;
  BREVO_SENDER_NAME?: string;
  ALLOWED_ORIGINS?: string;
  ACTIVE_PROFILE_LIMIT?: string;
  DISCOVERY_DETAILS?: string;
  JAIN_LOCAL_TEST?: string;
  LOCAL_FIXTURE_KEY?: string;
  FILE_TRANSFER_ENABLED?: string;
  STORAGE_ORIGIN_TOKEN?: string;
  STORAGE_ORIGIN?: { fetch(request: Request): Promise<Response> };
  STORAGE_LOCAL_URL?: string;
  PUSH_ENABLED?: string;
}

export interface Actor {
  id: string;
  email: string;
  role: 'customer' | 'admin';
  sessionId: string;
}

export class Failure extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public fields?: Record<string, string>,
  ) {
    super(message);
  }
}

export type JsonObject = Record<string, unknown>;
export const now = () => new Date().toISOString();
export const uid = () => crypto.randomUUID();
export const unix = () => Math.floor(Date.now() / 1000);
export const invalid = (field: string, message: string): never => {
  throw new Failure(400, 'invalid_input', 'Check the submitted fields.', { [field]: message });
};
export const conflict = (): never => {
  throw new Failure(
    409,
    'conflict',
    'The record changed or the action is unavailable. Refresh and try again.',
  );
};
export const missing = (): never => {
  throw new Failure(404, 'not_found', 'The requested record is unavailable.');
};
export const forbidden = (): never => {
  throw new Failure(403, 'forbidden', 'You do not have permission for this action.');
};
export const unauthorized = (): never => {
  throw new Failure(401, 'unauthenticated', 'Sign in to continue.');
};

export function object(value: unknown): JsonObject {
  if (value && typeof value === 'object' && !Array.isArray(value)) return value as JsonObject;
  return invalid('body', 'Expected an object.');
}

export async function body(request: Request): Promise<JsonObject> {
  if (!request.headers.get('content-type')?.toLowerCase().startsWith('application/json')) {
    throw new Failure(415, 'content_type', 'Send JSON.');
  }
  const reader = request.body?.getReader();
  if (!reader) return invalid('body', 'Expected JSON.');
  let size = 0;
  let raw = '';
  const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: false });
  try {
    for (;;) {
      const next = await reader.read();
      if (next.done) break;
      size += next.value.byteLength;
      if (size > 32768) {
        await reader.cancel();
        throw new Failure(413, 'payload_too_large', 'The request is too large.');
      }
      raw += decoder.decode(next.value, { stream: true });
    }
    return object(JSON.parse(raw + decoder.decode()));
  } catch (error) {
    if (error instanceof Failure) throw error;
    return invalid('body', 'Expected valid UTF-8 JSON.');
  }
}

export function str(value: unknown, field: string, max = 120, min = 1): string {
  if (typeof value !== 'string') return invalid(field, 'Expected text.');
  const cleaned = value.normalize('NFC').trim();
  if (
    cleaned.length < min ||
    cleaned.length > max ||
    /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.test(cleaned)
  ) {
    return invalid(field, 'Enter text within the allowed length.');
  }
  return cleaned;
}

export function choice<T extends string>(value: unknown, field: string, options: readonly T[]): T {
  if (typeof value === 'string' && (options as readonly string[]).includes(value)) return value as T;
  return invalid(field, 'Choose a supported value.');
}

export function integer(value: unknown, field: string, min: number, max: number): number {
  if (typeof value === 'number' && Number.isInteger(value) && value >= min && value <= max) return value;
  return invalid(field, 'Enter an integer between ' + min + ' and ' + max + '.');
}

export function bool(value: unknown, field: string): boolean {
  if (typeof value === 'boolean') return value;
  return invalid(field, 'Expected true or false.');
}

export function email(value: unknown): string {
  const address = str(value, 'email', 254).toLowerCase();
  if (
    !/^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/.test(
      address,
    )
  )
    return invalid('email', 'Enter a valid email address.');
  return address;
}

export function identifier(value: unknown, field = 'id'): string {
  const id = str(value, field, 36);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id))
    return invalid(field, 'Enter a valid ID.');
  return id;
}

export function statement(db: D1Database, sql: string, ...values: unknown[]) {
  return db.prepare(sql).bind(...values);
}

export async function rows<T>(db: D1Database, sql: string, ...values: unknown[]): Promise<T[]> {
  return (await statement(db, sql, ...values).all<T>()).results;
}

export async function change(db: D1Database, sql: string, ...values: unknown[]): Promise<boolean> {
  return (await statement(db, sql, ...values).run()).meta.changes > 0;
}

export async function rate(db: D1Database, bucket: string, limit: number, interval: number) {
  const window = Math.floor(unix() / interval);
  const row = await statement(
    db,
    'INSERT INTO jm_rate VALUES(?,?,1) ON CONFLICT(bucket) DO UPDATE SET window=excluded.window,count=CASE WHEN jm_rate.window=excluded.window THEN jm_rate.count+1 ELSE 1 END WHERE jm_rate.window<>excluded.window OR jm_rate.count<? RETURNING count',
    bucket,
    window,
    limit,
  ).first();
  if (!row) throw new Failure(429, 'rate_limited', 'Please wait before trying again.');
}

export function profileLimit(env: Env): number {
  const count = Number(env.ACTIVE_PROFILE_LIMIT ?? '1');
  return Number.isInteger(count) && count >= 1 && count <= 20 ? count : 1;
}

const utf8 = new TextEncoder();
const hex = (data: ArrayBuffer | Uint8Array) =>
  [...new Uint8Array(data)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
export const randomToken = () => hex(crypto.getRandomValues(new Uint8Array(32)));
export const digest = async (text: string) => hex(await crypto.subtle.digest('SHA-256', utf8.encode(text)));
export const digestBytes = async (data: Uint8Array<ArrayBuffer>) =>
  hex(await crypto.subtle.digest('SHA-256', data));
export async function keyed(env: Env, text: string) {
  if (!env.AUTH_SECRET || env.AUTH_SECRET.length < 32)
    throw new Failure(503, 'auth_unavailable', 'Authentication is temporarily unavailable.');
  const key = await crypto.subtle.importKey(
    'raw',
    utf8.encode(env.AUTH_SECRET),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return hex(await crypto.subtle.sign('HMAC', key, utf8.encode(text)));
}

export function same(a: string, b: string): boolean {
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++)
    diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

export function page(url: URL) {
  const read = (name: string, fallback: number, min: number, max: number) => {
    const value = url.searchParams.get(name);
    return value === null ? fallback : integer(Number(value), name, min, max);
  };
  return { limit: read('limit', 20, 1, 50), offset: read('offset', 0, 0, 10000) };
}

export function listing<T>(items: T[], limit: number, offset: number) {
  return { items: items.slice(0, limit), nextOffset: items.length > limit ? offset + limit : null };
}

export function audit(db: D1Database, actor: Actor, entity: string, action: string) {
  return statement(
    db,
    'INSERT INTO jm_outbox(id,actor_id,entity_id,action,created_at) VALUES(?,?,?,?,?)',
    uid(),
    actor.id,
    entity,
    action,
    now(),
  );
}

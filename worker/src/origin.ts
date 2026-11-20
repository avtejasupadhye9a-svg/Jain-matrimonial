import { Env, Failure, keyed, digestBytes, unix, same } from './core';
const maxBytes = 8 * 1024 * 1024;
export function transport(env: Env) {
  if (
    env.FILE_TRANSFER_ENABLED !== 'true' ||
    !env.STORAGE_ORIGIN_TOKEN ||
    env.STORAGE_ORIGIN_TOKEN.length < 32
  )
    return null;
  const local =
    env.JAIN_LOCAL_TEST === 'true' && /^http:\/\/127\.0\.0\.1:[0-9]+$/.test(env.STORAGE_LOCAL_URL ?? '');
  if (
    !local &&
    (!env.STORAGE_ORIGIN || !/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(env.STORAGE_ORIGIN_ID ?? ''))
  )
    return null;
  const base = local ? env.STORAGE_LOCAL_URL : 'http://127.0.0.1:8765';
  return async (
    path: string,
    method = 'GET',
    body?: Uint8Array<ArrayBuffer>,
    mime?: string,
    sha256?: string,
  ) => {
    if (env.ORIGIN_SIGNED) {
      const sign = (message: string) => keyed({ ...env, AUTH_SECRET: env.STORAGE_ORIGIN_TOKEN }, message);
      const call = async (route: string, verb: string, payload?: Uint8Array<ArrayBuffer>) => {
        const nonce = crypto.randomUUID(),
          time = String(unix()),
          hash = payload ? sha256! : '';
        const h = new Headers({
          'x-jain-origin': env.STORAGE_ORIGIN_ID!,
          'x-origin-time': time,
          'x-origin-nonce': nonce,
          'x-origin-mac': await sign([env.STORAGE_ORIGIN_ID, time, nonce, verb, route, hash].join('|')),
        });
        if (payload) {
          h.set('content-type', mime!);
          h.set('x-content-sha256', hash);
        }
        const req = new Request(base + route, {
          method: verb,
          headers: h,
          body: payload,
          redirect: 'manual',
          signal: AbortSignal.timeout(12000),
        });
        const res = await (local ? fetch(req) : env.STORAGE_ORIGIN!.fetch(req));
        if (!res.ok) return res;
        const data = await bytes(res.body);
        const mac = await sign([nonce, String(res.status), await digestBytes(data)].join('|'));
        if (!same(mac, res.headers.get('x-origin-proof') ?? '')) return new Response(null, { status: 403 });
        return new Response(data, { status: res.status, headers: res.headers });
      };
      if (body) {
        const probe = await call('/health', 'GET');
        await probe.body?.cancel();
        if (!probe.ok) return new Response(null, { status: probe.status });
      }
      return call(path, method, body);
    }
    const headers = new Headers({ authorization: `Bearer ${env.STORAGE_ORIGIN_TOKEN}` });
    if (env.STORAGE_ORIGIN_ID) headers.set('x-jain-origin', env.STORAGE_ORIGIN_ID);
    // A legacy listener may know the token but ignore the designation header.
    // Authenticate the designated origin before sending any document bytes.
    if (!local && body) {
      const health = await env.STORAGE_ORIGIN!.fetch(
        new Request(base + '/health', { headers, redirect: 'manual', signal: AbortSignal.timeout(8000) }),
      );
      await health.body?.cancel();
      if (health.status !== 200 || health.headers.get('x-jain-origin') !== env.STORAGE_ORIGIN_ID) {
        return new Response(null, { status: health.status >= 500 ? 503 : 403 });
      }
    }
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
    const response = await (local ? fetch(request) : env.STORAGE_ORIGIN!.fetch(request));
    if (
      response.ok &&
      env.STORAGE_ORIGIN_ID &&
      response.headers.get('x-jain-origin') !== env.STORAGE_ORIGIN_ID
    ) {
      await response.body?.cancel();
      return new Response(null, { status: 403 });
    }
    return response;
  };
}

export async function bytes(body: ReadableStream<Uint8Array> | null) {
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

export type OriginSend = NonNullable<ReturnType<typeof transport>>;

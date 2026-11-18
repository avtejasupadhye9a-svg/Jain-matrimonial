import {
  Actor,
  Env,
  JsonObject,
  bool,
  change,
  choice,
  identifier,
  integer,
  invalid,
  keyed,
  listing,
  missing,
  now,
  object,
  page,
  rows,
  statement,
  str,
  uid,
} from './core';
import { ageAt, preferences } from './profiles';

const textFilters = [
  'city',
  'qualification',
  'tradition',
  'maritalStatus',
  'country',
  'state',
  'district',
  'degree',
  'occupation',
  'employmentType',
  'incomeBand',
  'subCommunity',
  'diet',
  'language',
] as const;
const indexed: Record<string, string> = {
  city: 'pub.city',
  qualification: 'pub.education',
  tradition: 'pub.tradition',
};
const query = `SELECT p.id,pub.data,pub.dob,pub.published_at AS publishedAt FROM jm_publication pub
  JOIN jm_profiles p ON p.id=pub.profile_id
  JOIN jm_ownership o ON o.profile_id=p.id AND o.authority='owner'
  JOIN jm_accounts a ON a.id=o.account_id
  WHERE p.visible=1 AND p.suspended=0 AND a.status='active' AND o.account_id<>?
  AND NOT EXISTS(SELECT 1 FROM jm_ownership self WHERE self.profile_id=p.id AND self.account_id=?)
  AND NOT EXISTS(SELECT 1 FROM jm_blocks b WHERE (b.account_id=? AND b.blocked_id=o.account_id)
    OR (b.account_id=o.account_id AND b.blocked_id=?))`;

interface PublicRow {
  id: string;
  data: string;
  publishedAt: string;
  dob: string;
}
function candidate(row: PublicRow, detail = false) {
  const data = object(JSON.parse(row.data));
  const preview: JsonObject & { id: string; publishedAt: string } = {
    id: row.id,
    age: ageAt(String(data.dob)),
    publishedAt: row.publishedAt,
  };
  const fields = ['city', 'state', 'country', 'tradition', 'qualification', 'occupation', 'heightCm'];
  if (detail)
    fields.push(
      'degree',
      'maritalStatus',
      'subCommunity',
      'diet',
      'languages',
      'relocate',
      'motherTongue',
      'employmentType',
    );
  for (const key of fields) if (data[key] != null) preview[key] = data[key];
  return preview;
}

export function filters(input: JsonObject): JsonObject {
  const normalized: JsonObject = {};
  for (const field of textFilters)
    if (input[field] != null && input[field] !== '') normalized[field] = str(input[field], field);
  if (input.id != null && input.id !== '') normalized.id = identifier(input.id);
  for (const key of ['minAge', 'maxAge', 'minHeight', 'maxHeight']) {
    if (input[key] != null && input[key] !== '') {
      const value = typeof input[key] === 'string' ? Number(input[key]) : input[key];
      normalized[key] = key.endsWith('Age') ? integer(value, key, 21, 120) : integer(value, key, 100, 250);
    }
  }
  for (const [min, max] of [
    ['minAge', 'maxAge'],
    ['minHeight', 'maxHeight'],
  ]) {
    if (
      typeof normalized[min] === 'number' &&
      typeof normalized[max] === 'number' &&
      normalized[min] > normalized[max]
    ) {
      invalid(max, 'Must be at least the minimum.');
    }
  }
  if (input.relocate != null)
    normalized.relocate =
      input.relocate === 'true' || input.relocate === 'false'
        ? input.relocate === 'true'
        : bool(input.relocate, 'relocate');
  if (input.sort != null) normalized.sort = choice(input.sort, 'sort', ['recent', 'age_asc', 'age_desc']);
  return normalized;
}

function ageBoundary(age: number) {
  const today = now().slice(0, 10);
  const year = Number(today.slice(0, 4)) - age;
  return String(year) + today.slice(4);
}

interface SearchCursor {
  profileId: string;
  boundary: string;
  asOf: string;
}

const encoder = new TextEncoder();

async function cursorKey(env: Env, context: string) {
  const material = await keyed(env, context);
  return crypto.subtle.importKey(
    'raw',
    await crypto.subtle.digest('SHA-256', encoder.encode(material)),
    { name: 'AES-GCM' },
    false,
    ['encrypt', 'decrypt'],
  );
}

async function readCursor(env: Env, context: string, value: string): Promise<SearchCursor> {
  if (value.length > 440) return invalid('cursor', 'Start a fresh search.');
  try {
    const content = Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
    const text = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: content.slice(0, 12) },
      await cursorKey(env, context),
      content.slice(12),
    );
    return JSON.parse(new TextDecoder().decode(text)) as SearchCursor;
  } catch {
    return invalid('cursor', 'Start a fresh search.');
  }
}

async function writeCursor(env: Env, context: string, cursor: SearchCursor) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv },
    await cursorKey(env, context),
    encoder.encode(JSON.stringify(cursor)),
  );
  return btoa(String.fromCharCode(...iv, ...new Uint8Array(encrypted)));
}
export async function search(env: Env, actor: Actor, url: URL) {
  const { limit, offset } = page(url);
  const input = filters(Object.fromEntries(url.searchParams));
  const token = url.searchParams.get('cursor');
  if (token && offset !== 0) return invalid('cursor', 'Use either a cursor or an offset.');
  const context = 'search:' + actor.id + ':' + JSON.stringify(input) + ':';
  const cursor = token ? await readCursor(env, context, token) : null;
  const asOf = cursor?.asOf ?? now();
  const conditions = ['pub.published_at<=?'];
  const values: unknown[] = [actor.id, actor.id, actor.id, actor.id, asOf];
  for (const key of textFilters) {
    if (!input[key]) continue;
    if (key === 'language')
      conditions.push(
        "EXISTS(SELECT 1 FROM json_each(pub.data,'$.languages') l WHERE l.value = ? COLLATE NOCASE)",
      );
    else conditions.push((indexed[key] ?? "json_extract(pub.data,'$." + key + "')") + ' = ? COLLATE NOCASE');
    values.push(input[key]);
  }
  if (input.id) {
    conditions.push('p.id=?');
    values.push(input.id);
  }
  if (typeof input.minAge === 'number') {
    conditions.push('pub.dob<=?');
    values.push(ageBoundary(input.minAge));
  }
  if (typeof input.maxAge === 'number') {
    conditions.push('pub.dob>?');
    values.push(ageBoundary(input.maxAge + 1));
  }
  if (typeof input.minHeight === 'number') {
    conditions.push('pub.height>=?');
    values.push(input.minHeight);
  }
  if (typeof input.maxHeight === 'number') {
    conditions.push('pub.height<=?');
    values.push(input.maxHeight);
  }
  if (typeof input.relocate === 'boolean') {
    conditions.push("json_extract(pub.data,'$.relocate')=?");
    values.push(Number(input.relocate));
  }
  const field = input.sort === 'age_asc' || input.sort === 'age_desc' ? 'pub.dob' : 'pub.published_at';
  const ascending = input.sort === 'age_desc';
  if (cursor) {
    conditions.push('(' + field + (ascending ? ' > ?' : ' < ?') + ' OR (' + field + ' = ? AND p.id < ?))');
    values.push(cursor.boundary, cursor.boundary, cursor.profileId);
  }
  const order = field + (ascending ? ' ASC' : ' DESC') + ',p.id DESC';
  const items = await rows<PublicRow>(
    env.DB_MAIN,
    query + ' AND ' + conditions.join(' AND ') + ' ORDER BY ' + order + ' LIMIT ? OFFSET ?',
    ...values,
    limit + 1,
    offset,
  );
  let nextCursor: string | null = null;
  if (items.length > limit) {
    const last = items[limit - 1];
    nextCursor = await writeCursor(env, context, {
      profileId: last.id,
      asOf,
      boundary: field === 'pub.dob' ? last.dob : last.publishedAt,
    });
  }
  return {
    ...listing(
      items.map((item) => candidate(item)),
      limit,
      offset,
    ),
    nextCursor,
  };
}

export async function publicDetail(env: Env, actor: Actor, id: string) {
  const result = await statement(
    env.DB_MAIN,
    query + ' AND p.id=?',
    actor.id,
    actor.id,
    actor.id,
    actor.id,
    id,
  ).first<PublicRow>();
  if (!result) return missing();
  const saved = await statement(
    env.DB_MAIN,
    'SELECT 1 FROM jm_favorites WHERE account_id=? AND profile_id=?',
    actor.id,
    id,
  ).first();
  return { ...candidate(result, env.DISCOVERY_DETAILS !== 'false'), favorite: !!saved };
}

export async function favorite(env: Env, actor: Actor, id: string, add: boolean) {
  if (add) {
    await publicDetail(env, actor, id);
    await change(env.DB_MAIN, 'INSERT OR IGNORE INTO jm_favorites VALUES(?,?,?)', actor.id, id, now());
  } else
    await change(env.DB_MAIN, 'DELETE FROM jm_favorites WHERE account_id=? AND profile_id=?', actor.id, id);
  return { favorite: add };
}

export async function favorites(env: Env, actor: Actor, url: URL) {
  const { limit, offset } = page(url);
  const items = await rows<PublicRow>(
    env.DB_MAIN,
    query +
      ` AND EXISTS(SELECT 1 FROM jm_favorites f
    WHERE f.account_id=? AND f.profile_id=p.id) ORDER BY pub.published_at DESC,p.id DESC LIMIT ? OFFSET ?`,
    actor.id,
    actor.id,
    actor.id,
    actor.id,
    actor.id,
    limit + 1,
    offset,
  );
  return listing(
    items.map((item) => candidate(item)),
    limit,
    offset,
  );
}

interface SavedRow {
  id: string;
  name: string;
  filters: string;
  createdAt: string;
}
export async function saved(env: Env, actor: Actor, url: URL) {
  const { limit, offset } = page(url);
  const result = await rows<SavedRow>(
    env.DB_MAIN,
    `SELECT id,name,filters,created_at AS createdAt FROM jm_saved_searches
    WHERE account_id=? ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?`,
    actor.id,
    limit + 1,
    offset,
  );
  return listing(
    result.map((item) => ({ ...item, filters: JSON.parse(item.filters) })),
    limit,
    offset,
  );
}

export async function saveSearch(env: Env, actor: Actor, input: JsonObject, existing?: string) {
  const db = env.DB_MAIN;
  const name = str(input.name, 'name', 80);
  const data = JSON.stringify(filters(object(input.filters)));
  const id = existing ?? uid();
  const result = existing
    ? await change(
        db,
        'UPDATE OR IGNORE jm_saved_searches SET name=?,filters=? WHERE id=? AND account_id=?',
        name,
        data,
        id,
        actor.id,
      )
    : await change(
        db,
        'INSERT OR IGNORE INTO jm_saved_searches VALUES(?,?,?,?,?)',
        id,
        actor.id,
        name,
        data,
        now(),
      );
  if (!result) invalid('name', 'Choose a unique name or refresh the saved search.');
  return { id };
}

export async function removeSearch(env: Env, actor: Actor, id: string) {
  await change(env.DB_MAIN, 'DELETE FROM jm_saved_searches WHERE id=? AND account_id=?', id, actor.id);
  return {};
}

function matches(target: JsonObject, preferred: JsonObject) {
  const reasons: string[] = [];
  for (const [key, label] of Object.entries({
    city: 'City',
    country: 'Country',
    state: 'State',
    qualification: 'Education',
    occupation: 'Occupation',
    diet: 'Diet',
    tradition: 'Jain tradition',
    subCommunity: 'Jain community',
    maritalStatus: 'Marital status',
  })) {
    if (
      typeof target[key] === 'string' &&
      typeof preferred[key] === 'string' &&
      target[key].toLowerCase() === preferred[key].toLowerCase()
    )
      reasons.push(label);
  }
  for (const [min, max, value, label] of [
    ['minAge', 'maxAge', ageAt(String(target.dob)), 'Age'],
    ['minHeight', 'maxHeight', target.heightCm, 'Height'],
  ] as const) {
    if (typeof value !== 'number') continue;
    if (
      (typeof preferred[min] === 'number' || typeof preferred[max] === 'number') &&
      (typeof preferred[min] !== 'number' || value >= preferred[min]) &&
      (typeof preferred[max] !== 'number' || value <= preferred[max])
    )
      reasons.push(label);
  }
  return reasons;
}

export async function recommendations(env: Env, actor: Actor, url: URL) {
  const { limit, offset } = page(url);
  const source = await statement(
    env.DB_MAIN,
    `SELECT pub.data FROM jm_publication pub
    JOIN jm_profiles p ON p.id=pub.profile_id JOIN jm_ownership o ON o.profile_id=p.id
    WHERE o.account_id=? AND o.authority='owner' AND p.suspended=0
    ORDER BY pub.published_at DESC,p.id LIMIT 1`,
    actor.id,
  ).first<{ data: string }>();
  if (!source) return { items: [], nextOffset: null };
  const self = object(JSON.parse(source.data));
  const selfPrefs = preferences(self.preferences ?? {});
  const pool = await rows<PublicRow>(
    env.DB_MAIN,
    query + ' ORDER BY pub.published_at DESC,p.id DESC LIMIT 500',
    actor.id,
    actor.id,
    actor.id,
    actor.id,
  );
  const rank = pool
    .map((row) => {
      const data = object(JSON.parse(row.data));
      const forward = matches(data, selfPrefs);
      const reverse = matches(self, preferences(data.preferences ?? {}));
      return {
        ...candidate(row),
        score: forward.length * 2 + reverse.length,
        reasons: [
          ...forward.map((label) => label + ' matches your preferences'),
          ...(reverse.length ? ['Matches some of their preferences'] : []),
        ],
      };
    })
    .filter((item) => item.score > 0)
    .sort(
      (a, b) =>
        b.score - a.score ||
        String(b.publishedAt).localeCompare(String(a.publishedAt)) ||
        String(b.id).localeCompare(String(a.id)),
    );
  return listing(rank.slice(offset, offset + limit + 1), limit, offset);
}

import {
  Actor,
  Env,
  JsonObject,
  audit,
  bool,
  change,
  choice,
  conflict,
  email,
  identifier,
  integer,
  invalid,
  missing,
  now,
  object,
  profileLimit,
  rows,
  statement,
  str,
  uid,
} from './core';
import { AuthContext, verifyCode } from './auth';

export const required = ['name', 'dob', 'gender', 'country', 'city', 'tradition'] as const;
const textFields: Record<string, number> = {
  name: 120,
  motherTongue: 80,
  country: 80,
  state: 100,
  district: 100,
  city: 100,
  hometown: 100,
  biography: 1500,
  tradition: 100,
  subCommunity: 100,
  customs: 500,
  religiousPractice: 500,
  qualification: 120,
  degree: 120,
  specialization: 120,
  institution: 150,
  occupation: 120,
  jobBusiness: 120,
  employer: 150,
  workLocation: 120,
  incomeBand: 80,
  parentsGuardians: 300,
  familyType: 80,
  siblings: 250,
  familyLocation: 120,
  familyIntroduction: 800,
  diet: 100,
  hobbies: 300,
  interests: 300,
};
const enums = {
  gender: ['woman', 'man', 'another_identity', 'prefer_not_to_say'],
  maritalStatus: ['never_married', 'divorced', 'widowed', 'separated'],
  employmentType: ['employed', 'self_employed', 'student', 'not_employed', 'retired', 'other'],
};

export function ageAt(dob: string, today = now().slice(0, 10)): number {
  return Number(today.slice(0, 4)) - Number(dob.slice(0, 4)) - Number(today.slice(5) < dob.slice(5));
}

export function preferences(value: unknown): JsonObject {
  const input = object(value);
  const result: JsonObject = {};
  for (const key of ['minAge', 'maxAge', 'minHeight', 'maxHeight']) {
    if (input[key] != null)
      result[key] = key.endsWith('Age')
        ? integer(input[key], key, 21, 120)
        : integer(input[key], key, 100, 250);
  }
  for (const [min, max] of [
    ['minAge', 'maxAge'],
    ['minHeight', 'maxHeight'],
  ]) {
    if (typeof result[min] === 'number' && typeof result[max] === 'number' && result[min] > result[max])
      invalid(max, 'Must be at least the minimum.');
  }
  for (const key of [
    'maritalStatus',
    'country',
    'state',
    'city',
    'qualification',
    'occupation',
    'diet',
    'tradition',
    'subCommunity',
  ]) {
    if (input[key] != null && input[key] !== '')
      result[key] =
        key === 'maritalStatus' ? choice(input[key], key, enums.maritalStatus) : str(input[key], key);
  }
  return result;
}

export function profileData(value: unknown, submitting = false): JsonObject {
  const input = object(value);
  const result: JsonObject = {};
  for (const [key, max] of Object.entries(textFields)) {
    if (input[key] != null && input[key] !== '') result[key] = str(input[key], key, max);
  }
  for (const [key, values] of Object.entries(enums)) {
    if (input[key] != null && input[key] !== '') result[key] = choice(input[key], key, values);
  }
  if (input.dob != null && input.dob !== '') {
    const dob = str(input.dob, 'dob', 10, 10);
    const date = new Date(dob + 'T00:00:00Z');
    if (
      !/^\d{4}-\d{2}-\d{2}$/.test(dob) ||
      !Number.isFinite(date.getTime()) ||
      date.toISOString().slice(0, 10) !== dob ||
      ageAt(dob) < 21 ||
      ageAt(dob) > 120
    )
      invalid('dob', 'Enter a valid date. Candidate age must be between 21 and 120.');
    result.dob = dob;
  }
  if (input.heightCm != null) result.heightCm = integer(input.heightCm, 'heightCm', 100, 250);
  if (input.relocate != null) result.relocate = bool(input.relocate, 'relocate');
  if (input.languages != null) {
    if (!Array.isArray(input.languages) || input.languages.length > 12)
      return invalid('languages', 'Enter up to 12 languages.');
    result.languages = [...new Set(input.languages.map((item) => str(item, 'languages', 50)))];
  }
  if (input.preferences != null) result.preferences = preferences(input.preferences);
  if (submitting)
    for (const key of required) if (result[key] == null) invalid(key, 'Required to submit the profile.');
  return result;
}

interface DraftRow {
  id: string;
  data: string;
  version: number;
  publishedId: string | null;
  updatedAt: string;
  visible: number;
  suspended: number;
  consentEvidence?: string | null;
}
interface Revision {
  id: string;
  profileId: string;
  status: string;
  baseId: string | null;
  draftVersion: number;
  data: string;
  reason: string | null;
  reviewer: string | null;
  reviewedAt: string | null;
  createdAt: string;
}

const draftQuery = `SELECT p.id,d.data,d.version,p.published_id AS publishedId,p.updated_at AS updatedAt,
  p.visible,p.suspended FROM jm_profiles p JOIN jm_drafts d ON p.id=d.profile_id`;
const revisionQuery = `SELECT id,profile_id AS profileId,status,base_id AS baseId,draft_version AS draftVersion,data,reason,
  reviewer,reviewed_at AS reviewedAt,created_at AS createdAt FROM jm_revisions`;
const ownerExists = `EXISTS(SELECT 1 FROM jm_ownership WHERE profile_id=p.id AND account_id=? AND authority IN ('owner','delegate'))`;
const draftDto = (draft: DraftRow) => ({ ...draft, data: JSON.parse(draft.data) as JsonObject });
const revisionDto = (rev: Revision) => ({ ...rev, data: JSON.parse(rev.data) as JsonObject });

export async function owned(db: D1Database, actor: Actor, id: string): Promise<DraftRow> {
  const draft = await statement(
    db,
    draftQuery + ' WHERE p.id=? AND ' + (actor.role === 'admin' ? '1' : ownerExists),
    id,
    ...(actor.role === 'admin' ? [] : [actor.id]),
  ).first<DraftRow>();
  return draft ?? missing();
}

export async function myProfiles(env: Env, actor: Actor) {
  return {
    items: (
      await rows<DraftRow>(
        env.DB_MAIN,
        draftQuery + ' WHERE ' + ownerExists + ' ORDER BY p.created_at DESC',
        actor.id,
      )
    ).map(draftDto),
  };
}

export async function createProfile(env: Env, actor: Actor, input: JsonObject) {
  const db = env.DB_MAIN;
  if (input.consent !== true) invalid('consent', 'Candidate authorization is required.');
  const admin = actor.role === 'admin';
  const claimEmail = admin ? email(input.claimEmail) : null;
  const evidence = admin ? str(input.consentEvidence, 'consentEvidence', 600, 12) : null;
  const draft = profileData(input.data ?? {});
  const id = uid();
  const time = now();
  const creation = statement(
    db,
    `INSERT INTO jm_profiles(id,creator_id,claim_email,candidate_consent_at,consent_evidence,visible,created_at,updated_at)
    SELECT ?,?,?,?,?,?,?,? WHERE ?=1 OR (SELECT count(*) FROM jm_ownership WHERE account_id=? AND authority='owner')<?`,
    id,
    actor.id,
    claimEmail,
    time,
    evidence,
    admin ? 0 : 1,
    time,
    time,
    Number(admin),
    actor.id,
    profileLimit(env),
  );
  const batch = [
    creation,
    statement(
      db,
      'INSERT INTO jm_drafts SELECT id,?,1,?,? FROM jm_profiles WHERE id=?',
      JSON.stringify(draft),
      actor.id,
      time,
      id,
    ),
  ];
  if (!admin)
    batch.push(
      statement(
        db,
        "INSERT INTO jm_ownership SELECT id,?,'owner',? FROM jm_profiles WHERE id=?",
        actor.id,
        time,
        id,
      ),
    );
  batch.push(
    statement(
      db,
      `INSERT INTO jm_outbox(id,actor_id,entity_id,action,created_at)
    SELECT ?,?,id,'profile.created',? FROM jm_profiles WHERE id=?`,
      uid(),
      actor.id,
      time,
      id,
    ),
  );
  const result = await db.batch(batch);
  if (!result[0].meta.changes) return conflict();
  return { id, version: 1 };
}

export async function getProfile(env: Env, actor: Actor, id: string) {
  const draft = await owned(env.DB_MAIN, actor, id);
  const history = await rows<Revision>(
    env.DB_MAIN,
    revisionQuery + ' WHERE profile_id=? ORDER BY created_at DESC,id DESC LIMIT 30',
    id,
  );
  const review =
    actor.role === 'admin'
      ? await statement(
          env.DB_MAIN,
          `SELECT candidate_consent_at AS candidateConsentAt,
    consent_evidence AS consentEvidence,claim_email AS claimEmail FROM jm_profiles WHERE id=?`,
          id,
        ).first()
      : {};
  const media = await rows(
    env.DB_MAIN,
    'SELECT id,category,state FROM jm_file_metadata WHERE profile_id=? AND (category=? OR ?=1)',
    id,
    'photo',
    Number(actor.role === 'admin'),
  );
  const publication = draft.publishedId
    ? await statement(env.DB_MAIN, revisionQuery + ' WHERE id=?', draft.publishedId).first<Revision>()
    : null;
  return {
    ...draftDto(draft),
    ...review,
    publication: publication ? revisionDto(publication) : null,
    history: history.map(revisionDto),
    media,
  };
}

export async function saveDraft(env: Env, actor: Actor, id: string, input: JsonObject) {
  const db = env.DB_MAIN;
  await owned(db, actor, id);
  const version = integer(input.version, 'version', 1, 2147483646);
  const data = profileData(input.data);
  const ok = await change(
    db,
    `UPDATE jm_drafts SET data=?,version=version+1,author=?,updated_at=?
    WHERE profile_id=? AND version=? AND EXISTS(SELECT 1 FROM jm_profiles p WHERE p.id=? AND p.suspended=0 AND
    (?=1 OR ${ownerExists}))`,
    JSON.stringify(data),
    actor.id,
    now(),
    id,
    version,
    id,
    Number(actor.role === 'admin'),
    actor.id,
  );
  if (!ok) return conflict();
  return { id, version: version + 1 };
}

export async function submitProfile(env: Env, actor: Actor, id: string, input: JsonObject) {
  const db = env.DB_MAIN;
  const draft = await owned(db, actor, id);
  const version = integer(input.version, 'version', 1, 2147483646);
  if (version !== draft.version) return conflict();
  profileData(JSON.parse(draft.data), true);
  const revisionId = uid();
  const result = await statement(
    db,
    `INSERT INTO jm_revisions(id,profile_id,base_id,draft_version,data,author,status,created_at)
    SELECT ?,p.id,p.published_id,d.version,d.data,?,'pending_review',? FROM jm_profiles p JOIN jm_drafts d ON d.profile_id=p.id
    WHERE p.id=? AND p.suspended=0 AND d.version=? AND (?=1 OR ${ownerExists})
      AND NOT EXISTS(SELECT 1 FROM jm_revisions WHERE profile_id=p.id AND (status='pending_review' OR draft_version=d.version))
    RETURNING id`,
    revisionId,
    actor.id,
    now(),
    id,
    version,
    Number(actor.role === 'admin'),
    actor.id,
  ).first();
  return result ?? conflict();
}

export async function reviewProfile(env: Env, actor: Actor, id: string, input: JsonObject) {
  const db = env.DB_MAIN;
  const decision = choice(input.decision, 'decision', ['approved', 'rejected', 'changes_requested']);
  const reason = decision === 'approved' && !input.reason ? null : str(input.reason, 'reason', 700);
  const updated = await statement(
    db,
    `UPDATE jm_revisions SET status=?,reason=?,reviewer=?,reviewed_at=?
    WHERE id=? AND status='pending_review' AND EXISTS(SELECT 1 FROM jm_profiles p
      WHERE p.id=profile_id AND p.suspended=0 AND p.published_id IS base_id) RETURNING id,status`,
    decision,
    reason,
    actor.id,
    now(),
    id,
  ).first();
  if (updated) return updated;
  return (
    (await statement(
      db,
      'SELECT id,status FROM jm_revisions WHERE id=? AND status=? AND reviewer=? AND reason IS ?',
      id,
      decision,
      actor.id,
      reason,
    ).first()) ?? conflict()
  );
}

export async function updateVisibility(env: Env, actor: Actor, id: string, input: JsonObject) {
  const db = env.DB_MAIN;
  await owned(db, actor, id);
  const visible = bool(input.visible, 'visible');
  const time = now();
  await db.batch([
    audit(db, actor, id, visible ? 'profile.visibility_enabled' : 'profile.visibility_disabled'),
    statement(
      db,
      `UPDATE jm_profiles AS p SET visible=?,updated_at=? WHERE p.id=? AND ${ownerExists}`,
      Number(visible),
      time,
      id,
      actor.id,
    ),
  ]);
  return { visible };
}

export async function suspendProfile(env: Env, actor: Actor, id: string, input: JsonObject) {
  const db = env.DB_MAIN;
  await owned(db, actor, id);
  const suspended = bool(input.suspended, 'suspended');
  const reason = str(input.reason, 'reason', 700);
  await db.batch([
    statement(
      db,
      'INSERT INTO jm_moderation_actions VALUES(?,?,?,?,?,?)',
      uid(),
      actor.id,
      id,
      suspended ? 'profile.suspended' : 'profile.reactivated',
      reason,
      now(),
    ),
    statement(db, 'UPDATE jm_profiles SET suspended=?,updated_at=? WHERE id=?', Number(suspended), now(), id),
  ]);
  return { suspended };
}

export async function claimProfile(context: AuthContext, actor: Actor, input: JsonObject) {
  const db = context.env.DB_MAIN;
  const id = identifier(input.profileId, 'profileId');
  const challenge = await verifyCode(context, input, 'claim', actor.email);
  const claimId = uid();
  const created = await statement(
    db,
    `INSERT INTO jm_claims(id,profile_id,account_id,challenge_id,status,created_at)
    SELECT ?,p.id,?,?,'pending',? FROM jm_profiles p WHERE p.id=? AND p.claim_email=? AND p.consent_evidence IS NOT NULL
    AND p.suspended=0 AND NOT EXISTS(SELECT 1 FROM jm_ownership WHERE profile_id=p.id AND authority='owner')
    AND NOT EXISTS(SELECT 1 FROM jm_claims WHERE profile_id=p.id AND status='pending')
    AND (SELECT count(*) FROM jm_ownership WHERE account_id=? AND authority='owner')<?
    RETURNING id,status`,
    claimId,
    actor.id,
    challenge.id,
    now(),
    id,
    actor.email,
    actor.id,
    profileLimit(context.env),
  ).first();
  return created ?? missing();
}

export async function reviewClaim(env: Env, actor: Actor, id: string, input: JsonObject) {
  const db = env.DB_MAIN;
  const status = choice(input.decision, 'decision', ['approved', 'rejected']);
  const reason = str(input.reason, 'reason', 700);
  const updated = await statement(
    db,
    `UPDATE jm_claims SET status=?,reviewer=?,reviewed_at=?,reason=?
    WHERE id=? AND status='pending' AND (?='rejected' OR (
      EXISTS(SELECT 1 FROM jm_profiles p JOIN jm_accounts a ON a.id=jm_claims.account_id
        WHERE p.id=profile_id AND p.claim_email=a.email AND a.status='active' AND p.suspended=0 AND p.consent_evidence IS NOT NULL)
      AND NOT EXISTS(SELECT 1 FROM jm_ownership o WHERE o.profile_id=jm_claims.profile_id AND o.authority='owner')
      AND (SELECT count(*) FROM jm_ownership o WHERE o.account_id=jm_claims.account_id AND o.authority='owner')<?))
    RETURNING id,status`,
    status,
    actor.id,
    now(),
    reason,
    id,
    status,
    profileLimit(env),
  ).first();
  return (
    updated ??
    (await statement(
      db,
      'SELECT id,status FROM jm_claims WHERE id=? AND status=? AND reviewer=? AND reason=?',
      id,
      status,
      actor.id,
      reason,
    ).first()) ??
    conflict()
  );
}

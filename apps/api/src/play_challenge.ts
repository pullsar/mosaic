import {createHash, randomBytes} from 'node:crypto';
import type {Pool, PoolClient} from 'pg';
import {canonicalJson, type CanonicalJsonValue} from './media.js';

const DAY_MS = 24 * 60 * 60 * 1000;
export const CHALLENGE_EXPIRY_MS = 30 * DAY_MS;
const INVITE_PATTERN = /^pc_[A-Za-z0-9_-]{22}$/;
const IDENTITY_LIMIT = 200;
const SCORING_VERSION_LIMIT = 100;

export type ChallengeMode = 'async_same_round';
export type ChallengeRevealPolicy = 'after_participant_submission';

export interface ChallengeResult {
  readonly outcome: 'correct' | 'incorrect' | 'completed';
  readonly score: number;
  readonly wrongAnswerCount: number;
}

export interface CreatePlayChallengeInput {
  readonly creatorActorId: string;
  readonly idempotencyKey: string;
  readonly playId: string;
  readonly revisionId: string;
  readonly presentation?: Readonly<Record<string, CanonicalJsonValue>>;
  readonly mode: ChallengeMode;
  readonly scoringVersion: string;
  readonly revealPolicy: ChallengeRevealPolicy;
  readonly creatorResult?: ChallengeResult;
}

export interface SubmitPlayChallengeInput {
  readonly inviteId: string;
  readonly actorId: string;
  readonly result: ChallengeResult;
}

export interface PlayChallengeDescriptor {
  readonly inviteId: string;
  readonly playId: string;
  readonly revisionId: string;
  readonly presentation?: Readonly<Record<string, CanonicalJsonValue>>;
  readonly mode: ChallengeMode;
  readonly scoringVersion: string;
  readonly revealPolicy: ChallengeRevealPolicy;
  readonly expiresAt: string;
}

export interface PlayChallengeComparison extends PlayChallengeDescriptor {
  readonly self: ChallengeResult;
  readonly creator: ChallengeResult | null;
}

export class ChallengeInputError extends Error {}
export class ChallengeNotFoundError extends Error {}
export class ChallengeUnavailableError extends Error {}
export class ChallengeIdempotencyConflictError extends Error {}
export class ChallengeSubmissionConflictError extends Error {}
export class ChallengeAuthorizationError extends Error {}

export interface PlayChallengeRepository {
  create(input: CreatePlayChallengeInput): Promise<PlayChallengeDescriptor>;
  readInvite(inviteId: string): Promise<PlayChallengeDescriptor>;
  submit(input: SubmitPlayChallengeInput): Promise<PlayChallengeComparison>;
  readComparison(inviteId: string, actorId: string): Promise<PlayChallengeComparison>;
  revoke(inviteId: string, creatorActorId: string): Promise<void>;
}

type ChallengeRow = {
  invite_id: string;
  creator_actor_id: string;
  creator_idempotency_key: string;
  creation_fingerprint: string;
  play_id: string;
  revision_id: string;
  presentation: Record<string, CanonicalJsonValue> | null;
  mode: ChallengeMode;
  scoring_version: string;
  reveal_policy: ChallengeRevealPolicy;
  creator_result: ChallengeResult | null;
  expires_at: Date;
  revoked_at: Date | null;
};

/** PostgreSQL policy store for asynchronous, fixed-round challenges. */
export class PostgresPlayChallengeRepository implements PlayChallengeRepository {
  constructor(
    private readonly pool: Pool,
    private readonly now: () => Date = () => new Date(),
    private readonly inviteIdFactory: () => string = defaultInviteId,
  ) {}

  async create(input: CreatePlayChallengeInput): Promise<PlayChallengeDescriptor> {
    const normalized = normalizeCreate(input);
    const fingerprint = fingerprintCreate(normalized);
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      await assertPublishedRevision(client, normalized.playId, normalized.revisionId);
      const existing = await client.query<ChallengeRow>(
        `select invite_id, creator_actor_id, creator_idempotency_key,
                creation_fingerprint, play_id, revision_id, presentation, mode,
                scoring_version, reveal_policy, creator_result, expires_at, revoked_at
           from play_challenges
          where creator_actor_id = $1 and creator_idempotency_key = $2
          for update`,
        [normalized.creatorActorId, normalized.idempotencyKey],
      );
      if (existing.rowCount === 1) {
        const row = existing.rows[0]!;
        if (row.creation_fingerprint !== fingerprint) {
          throw new ChallengeIdempotencyConflictError('Challenge key was reused with a different payload.');
        }
        await client.query('commit');
        return descriptorFromRow(row);
      }
      const expiresAt = new Date(this.now().getTime() + CHALLENGE_EXPIRY_MS);
      const inviteId = validInviteId(this.inviteIdFactory());
      const inserted = await client.query<ChallengeRow>(
        `insert into play_challenges (
           invite_id, creator_actor_id, creator_idempotency_key, creation_fingerprint,
           play_id, revision_id, presentation, mode, scoring_version, reveal_policy,
           creator_result, expires_at
         ) values ($1, $2, $3, $4, $5, $6, $7::jsonb, $8, $9, $10, $11::jsonb, $12)
         returning invite_id, creator_actor_id, creator_idempotency_key,
                   creation_fingerprint, play_id, revision_id, presentation, mode,
                   scoring_version, reveal_policy, creator_result, expires_at, revoked_at`,
        [
          inviteId,
          normalized.creatorActorId,
          normalized.idempotencyKey,
          fingerprint,
          normalized.playId,
          normalized.revisionId,
          normalized.presentation === undefined ? null : canonicalJson(normalized.presentation),
          normalized.mode,
          normalized.scoringVersion,
          normalized.revealPolicy,
          normalized.creatorResult === undefined ? null : canonicalJson(normalized.creatorResult),
          expiresAt,
        ],
      );
      await client.query('commit');
      return descriptorFromRow(inserted.rows[0]!);
    } catch (error) {
      await client.query('rollback').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  }

  async readInvite(inviteId: string): Promise<PlayChallengeDescriptor> {
    const row = await this.readRow(inviteId);
    assertOpen(row, this.now());
    return descriptorFromRow(row);
  }

  async submit(input: SubmitPlayChallengeInput): Promise<PlayChallengeComparison> {
    const normalized = normalizeSubmit(input);
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      const row = await this.readRow(normalized.inviteId, client, true);
      assertOpen(row, this.now());
      if (row.creator_actor_id === normalized.actorId) {
        throw new ChallengeAuthorizationError('The creator result is fixed at creation.');
      }
      const existing = await client.query<{result: ChallengeResult}>(
        `select result from play_challenge_submissions where invite_id = $1 and actor_id = $2`,
        [normalized.inviteId, normalized.actorId],
      );
      if (existing.rowCount === 1) {
        const result = normalizeResult(existing.rows[0]!.result);
        if (canonicalJson(result) !== canonicalJson(normalized.result)) {
          throw new ChallengeSubmissionConflictError('A ranked submission already exists.');
        }
        await client.query('commit');
        return comparisonFrom(row, result);
      }
      await client.query(
        `insert into play_challenge_submissions (invite_id, actor_id, result)
         values ($1, $2, $3::jsonb)`,
        [normalized.inviteId, normalized.actorId, canonicalJson(normalized.result)],
      );
      await client.query('commit');
      return comparisonFrom(row, normalized.result);
    } catch (error) {
      await client.query('rollback').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  }

  async readComparison(inviteId: string, actorId: string): Promise<PlayChallengeComparison> {
    const id = validInviteId(inviteId);
    const actor = identifier(actorId, 'actorId');
    const row = await this.readRow(id);
    if (row.creator_actor_id === actor) {
      const creator = row.creator_result === null ? null : normalizeResult(row.creator_result);
      if (creator === null) throw new ChallengeNotFoundError('Creator result has not been submitted.');
      return comparisonFrom(row, creator, creator);
    }
    const submission = await this.pool.query<{result: ChallengeResult}>(
      `select result from play_challenge_submissions where invite_id = $1 and actor_id = $2`,
      [id, actor],
    );
    if (submission.rowCount !== 1) throw new ChallengeNotFoundError('No ranked submission exists.');
    return comparisonFrom(row, normalizeResult(submission.rows[0]!.result));
  }

  async revoke(inviteId: string, creatorActorId: string): Promise<void> {
    const id = validInviteId(inviteId);
    const creator = identifier(creatorActorId, 'creatorActorId');
    const updated = await this.pool.query(
      `update play_challenges
          set revoked_at = coalesce(revoked_at, now())
        where invite_id = $1 and creator_actor_id = $2`,
      [id, creator],
    );
    if (updated.rowCount !== 1) throw new ChallengeAuthorizationError('Only the creator can revoke this challenge.');
  }

  private async readRow(
    inviteId: string,
    client: Pool | PoolClient = this.pool,
    lock = false,
  ): Promise<ChallengeRow> {
    const id = validInviteId(inviteId);
    const result = await client.query<ChallengeRow>(
      `select invite_id, creator_actor_id, creator_idempotency_key,
              creation_fingerprint, play_id, revision_id, presentation, mode,
              scoring_version, reveal_policy, creator_result, expires_at, revoked_at
         from play_challenges where invite_id = $1${lock ? ' for update' : ''}`,
      [id],
    );
    const row = result.rows[0];
    if (row === undefined) throw new ChallengeNotFoundError('Challenge invite was not found.');
    return row;
  }
}

function normalizeCreate(input: CreatePlayChallengeInput): CreatePlayChallengeInput {
  const mode = input.mode;
  const revealPolicy = input.revealPolicy;
  if (mode !== 'async_same_round' || revealPolicy !== 'after_participant_submission') {
    throw new ChallengeInputError('Unsupported challenge policy.');
  }
  return Object.freeze({
    creatorActorId: identifier(input.creatorActorId, 'creatorActorId'),
    idempotencyKey: identifier(input.idempotencyKey, 'idempotencyKey'),
    playId: identifier(input.playId, 'playId'),
    revisionId: identifier(input.revisionId, 'revisionId'),
    ...(input.presentation === undefined ? {} : {presentation: normalizedPresentation(input.presentation)}),
    mode,
    scoringVersion: bounded(input.scoringVersion, 'scoringVersion', SCORING_VERSION_LIMIT),
    revealPolicy,
    ...(input.creatorResult === undefined ? {} : {creatorResult: normalizeResult(input.creatorResult)}),
  });
}

function normalizeSubmit(input: SubmitPlayChallengeInput): SubmitPlayChallengeInput {
  return Object.freeze({
    inviteId: validInviteId(input.inviteId),
    actorId: identifier(input.actorId, 'actorId'),
    result: normalizeResult(input.result),
  });
}

function normalizedPresentation(
  presentation: Readonly<Record<string, CanonicalJsonValue>>,
): Readonly<Record<string, CanonicalJsonValue>> {
  const json = canonicalJson(presentation);
  if (json.length > 8 * 1024) throw new ChallengeInputError('presentation is too large.');
  const parsed = JSON.parse(json) as unknown;
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new ChallengeInputError('presentation must be an object.');
  }
  return Object.freeze(parsed as Record<string, CanonicalJsonValue>);
}

function normalizeResult(value: ChallengeResult): ChallengeResult {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new ChallengeInputError('result must be an object.');
  }
  const outcome = value.outcome;
  if (outcome !== 'correct' && outcome !== 'incorrect' && outcome !== 'completed') {
    throw new ChallengeInputError('result.outcome is invalid.');
  }
  if (!Number.isFinite(value.score) || value.score < 0 || value.score > 1) {
    throw new ChallengeInputError('result.score must be from zero to one.');
  }
  if (!Number.isInteger(value.wrongAnswerCount) || value.wrongAnswerCount < 0 || value.wrongAnswerCount > 128) {
    throw new ChallengeInputError('result.wrongAnswerCount is invalid.');
  }
  return Object.freeze({outcome, score: value.score, wrongAnswerCount: value.wrongAnswerCount});
}

function descriptorFromRow(row: ChallengeRow): PlayChallengeDescriptor {
  return Object.freeze({
    inviteId: row.invite_id,
    playId: row.play_id,
    revisionId: row.revision_id,
    ...(row.presentation === null ? {} : {presentation: normalizedPresentation(row.presentation)}),
    mode: row.mode,
    scoringVersion: row.scoring_version,
    revealPolicy: row.reveal_policy,
    expiresAt: row.expires_at.toISOString(),
  });
}

function comparisonFrom(
  row: ChallengeRow,
  self: ChallengeResult,
  creatorOverride?: ChallengeResult,
): PlayChallengeComparison {
  return Object.freeze({
    ...descriptorFromRow(row),
    self,
    creator: creatorOverride ?? (row.creator_result === null ? null : normalizeResult(row.creator_result)),
  });
}

function assertOpen(row: ChallengeRow, now: Date): void {
  if (row.revoked_at !== null || row.expires_at.getTime() <= now.getTime()) {
    throw new ChallengeUnavailableError('Challenge is no longer open.');
  }
}

async function assertPublishedRevision(client: PoolClient, playId: string, revisionId: string): Promise<void> {
  const result = await client.query(
    `select 1
       from feed_catalog_entries
      where play_id = $1 and revision_id = $2 and state in ('eligible', 'suspended')`,
    [playId, revisionId],
  );
  if (result.rowCount !== 1) throw new ChallengeInputError('Challenge Play revision is unavailable.');
}

function fingerprintCreate(value: CreatePlayChallengeInput): string {
  const fingerprintPayload = {
    playId: value.playId,
    revisionId: value.revisionId,
    ...(value.presentation === undefined ? {} : {presentation: value.presentation}),
    mode: value.mode,
    scoringVersion: value.scoringVersion,
    revealPolicy: value.revealPolicy,
    ...(value.creatorResult === undefined ? {} : {creatorResult: value.creatorResult}),
  };
  return createHash('sha256').update(canonicalJson(fingerprintPayload), 'utf8').digest('hex');
}

function defaultInviteId(): string {
  return `pc_${randomBytes(16).toString('base64url')}`;
}

function validInviteId(value: string): string {
  if (!INVITE_PATTERN.test(value)) throw new ChallengeInputError('inviteId is invalid.');
  return value;
}

function identifier(value: string, name: string): string {
  return bounded(value, name, IDENTITY_LIMIT);
}

function bounded(value: string, name: string, maxLength: number): string {
  if (typeof value !== 'string') throw new ChallengeInputError(`${name} must be text.`);
  const normalized = value.trim();
  if (normalized.length === 0 || normalized.length > maxLength || /[\u0000-\u001F\u007F]/.test(normalized)) {
    throw new ChallengeInputError(`${name} is invalid.`);
  }
  return normalized;
}

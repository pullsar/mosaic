import {randomUUID} from 'node:crypto';
import type {Pool} from 'pg';
import {
  canonicalJson,
  mediaDerivativeKey,
  normalizeMediaDerivativePlan,
  normalizeSha256,
  type CanonicalJsonValue,
  type MediaAssetKind,
  type MediaAssetState,
  type MediaDerivativePlan,
  type MediaDerivativePurpose,
  type MediaDerivativeState,
} from './media.js';

export class MediaIdentityConflictError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'MediaIdentityConflictError';
  }
}

export interface MediaSourceInput {
  storageKey: string;
  sourceSha256: string;
  mimeType: string;
  sizeBytes: number;
  width?: number;
  height?: number;
  durationMs?: number;
  metadata?: Readonly<Record<string, CanonicalJsonValue>>;
}

export interface MediaDerivativeOutput {
  storageKey: string;
  mimeType: string;
  sizeBytes: number;
  width?: number;
  height?: number;
  durationMs?: number;
  container?: string;
  videoCodec?: string;
  videoProfile?: string;
  audioCodec?: string;
  colorSpace?: string;
  dynamicRange?: 'sdr' | 'hdr';
  metadata?: Readonly<Record<string, CanonicalJsonValue>>;
}

export interface MediaAssetRecord {
  id: string;
  ownerActorId: string;
  kind: MediaAssetKind;
  state: MediaAssetState;
  sourceStorageKey: string | null;
  sourceSha256: string | null;
  sourceMimeType: string | null;
  sourceSizeBytes: number | null;
  sourceWidth: number | null;
  sourceHeight: number | null;
  sourceDurationMs: number | null;
  sourceMetadata: Readonly<Record<string, CanonicalJsonValue>>;
  errorCode: string | null;
}

export interface MediaDerivativeRecord {
  assetId: string;
  derivativeKey: string;
  purpose: MediaDerivativePurpose;
  state: MediaDerivativeState;
  sourceSha256: string;
  planVersion: number;
  plan: MediaDerivativePlan;
  attemptCount: number;
  leaseExpiresAt: Date | null;
  storageKey: string | null;
  mimeType: string | null;
  sizeBytes: number | null;
  width: number | null;
  height: number | null;
  durationMs: number | null;
  container: string | null;
  videoCodec: string | null;
  videoProfile: string | null;
  audioCodec: string | null;
  colorSpace: string | null;
  dynamicRange: 'sdr' | 'hdr' | null;
  errorCode: string | null;
  outputMetadata: Readonly<Record<string, CanonicalJsonValue>>;
  completedAt: Date | null;
}

export interface MediaDerivativeClaim {
  derivative: MediaDerivativeRecord;
  claimToken: string;
}

type AssetRow = {
  id: string;
  owner_actor_id: string;
  kind: MediaAssetKind;
  state: MediaAssetState;
  source_storage_key: string | null;
  source_sha256: string | null;
  source_mime_type: string | null;
  source_size_bytes: string | null;
  source_width: number | null;
  source_height: number | null;
  source_duration_ms: string | null;
  source_metadata: Record<string, CanonicalJsonValue>;
  error_code: string | null;
};

type DerivativeRow = {
  asset_id: string;
  derivative_key: string;
  purpose: MediaDerivativePurpose;
  state: MediaDerivativeState;
  source_sha256: string;
  plan_version: number;
  plan: MediaDerivativePlan;
  attempt_count: number;
  lease_expires_at: Date | null;
  storage_key: string | null;
  mime_type: string | null;
  size_bytes: string | null;
  width: number | null;
  height: number | null;
  duration_ms: string | null;
  container: string | null;
  video_codec: string | null;
  video_profile: string | null;
  audio_codec: string | null;
  color_space: string | null;
  dynamic_range: 'sdr' | 'hdr' | null;
  error_code: string | null;
  output_metadata: Record<string, CanonicalJsonValue>;
  completed_at: Date | null;
};

const ASSET_KINDS = new Set<MediaAssetKind>(['image', 'video', 'audio']);
const DEFAULT_LEASE_MS = 5 * 60 * 1000;
const MAX_LEASE_MS = 60 * 60 * 1000;

export class PostgresMediaRepository {
  constructor(private readonly pool: Pool) {}

  async createAsset(assetId: string, ownerActorId: string, kind: MediaAssetKind): Promise<'inserted' | 'duplicate'> {
    const id = requiredText(assetId, 'assetId');
    const owner = requiredText(ownerActorId, 'ownerActorId');
    if (!ASSET_KINDS.has(kind)) throw new TypeError(`Unsupported media asset kind: ${String(kind)}`);
    const inserted = await this.pool.query<{id: string}>(
      `insert into media_assets (id, owner_actor_id, kind)
       values ($1, $2, $3)
       on conflict (id) do nothing
       returning id`,
      [id, owner, kind],
    );
    if (inserted.rowCount === 1) return 'inserted';

    const existing = await this.getAsset(id);
    if (existing === null) throw new Error(`Media asset ${id} disappeared after conflict`);
    if (existing.ownerActorId !== owner || existing.kind !== kind) {
      throw new MediaIdentityConflictError(`Media asset ${id} already belongs to a different identity`);
    }
    return 'duplicate';
  }

  async getAsset(assetId: string): Promise<MediaAssetRecord | null> {
    const result = await this.pool.query<AssetRow>(
      `select id, owner_actor_id, kind, state, source_storage_key, source_sha256,
              source_mime_type, source_size_bytes, source_width, source_height,
              source_duration_ms, source_metadata, error_code
       from media_assets where id = $1`,
      [requiredText(assetId, 'assetId')],
    );
    return result.rows[0] ? assetFromRow(result.rows[0]) : null;
  }

  async attachSource(assetId: string, input: MediaSourceInput): Promise<MediaAssetRecord> {
    const id = requiredText(assetId, 'assetId');
    const normalized = normalizeSource(input);
    const result = await this.pool.query<AssetRow>(
      `update media_assets
       set source_storage_key = $2,
           source_sha256 = $3,
           source_mime_type = $4,
           source_size_bytes = $5,
           source_width = $6,
           source_height = $7,
           source_duration_ms = $8,
           source_metadata = $9::jsonb,
           state = 'uploaded',
           error_code = null,
           updated_at = now()
       where id = $1 and state = 'registered' and source_sha256 is null
       returning id, owner_actor_id, kind, state, source_storage_key, source_sha256,
                 source_mime_type, source_size_bytes, source_width, source_height,
                 source_duration_ms, source_metadata, error_code`,
      [
        id,
        normalized.storageKey,
        normalized.sourceSha256,
        normalized.mimeType,
        normalized.sizeBytes,
        normalized.width,
        normalized.height,
        normalized.durationMs,
        canonicalJson(normalized.metadata),
      ],
    );
    if (result.rows[0]) return assetFromRow(result.rows[0]);

    const existing = await this.getAsset(id);
    if (existing === null) throw new Error(`Unknown media asset ${id}`);
    if (existing.state === 'revoked') throw new MediaIdentityConflictError(`Media asset ${id} is revoked`);
    if (sourceMatches(existing, normalized)) return existing;
    throw new MediaIdentityConflictError(`Media asset ${id} source identity is immutable once attached`);
  }

  async registerDerivative(assetId: string, plan: MediaDerivativePlan): Promise<{status: 'inserted' | 'duplicate'; derivative: MediaDerivativeRecord}> {
    const id = requiredText(assetId, 'assetId');
    const normalizedPlan = normalizeMediaDerivativePlan(plan);
    const asset = await this.getAsset(id);
    if (asset === null) throw new Error(`Unknown media asset ${id}`);
    if (asset.state === 'revoked') throw new MediaIdentityConflictError(`Media asset ${id} is revoked`);
    if (asset.sourceSha256 === null) throw new MediaIdentityConflictError(`Media asset ${id} has no verified source digest`);

    const derivativeKey = mediaDerivativeKey(asset.sourceSha256, normalizedPlan);
    const inserted = await this.pool.query<DerivativeRow>(
      `insert into media_derivatives (
         asset_id, derivative_key, purpose, source_sha256, plan_version, plan
       )
       select a.id, $2, $3, a.source_sha256, $4, $5::jsonb
       from media_assets a
       where a.id = $1 and a.state <> 'revoked' and a.source_sha256 = $6
       on conflict (asset_id, derivative_key) do nothing
       returning asset_id, derivative_key, purpose, state, source_sha256,
                 plan_version, plan, attempt_count, lease_expires_at, storage_key,
                 mime_type, size_bytes, width, height, duration_ms, container,
                 video_codec, video_profile, audio_codec, color_space, dynamic_range,
                 error_code, output_metadata, completed_at`,
      [
        id,
        derivativeKey,
        normalizedPlan.purpose,
        normalizedPlan.version,
        canonicalJson(normalizedPlan),
        asset.sourceSha256,
      ],
    );
    if (inserted.rows[0]) return {status: 'inserted', derivative: derivativeFromRow(inserted.rows[0])};

    const existing = await this.getDerivative(id, derivativeKey);
    if (existing !== null) {
      if (
        existing.sourceSha256 !== asset.sourceSha256 ||
        existing.purpose !== normalizedPlan.purpose ||
        existing.planVersion !== normalizedPlan.version ||
        canonicalJson(existing.plan) !== canonicalJson(normalizedPlan)
      ) {
        throw new MediaIdentityConflictError(`Media derivative key collision for ${derivativeKey}`);
      }
      return {status: 'duplicate', derivative: existing};
    }
    const refreshed = await this.getAsset(id);
    if (refreshed?.state === 'revoked') throw new MediaIdentityConflictError(`Media asset ${id} is revoked`);
    throw new MediaIdentityConflictError(`Media asset ${id} source changed while registering derivative`);
  }

  async claimDerivative(
    assetId: string,
    derivativeKey: string,
    leaseMs = DEFAULT_LEASE_MS,
    claimToken = randomUUID(),
  ): Promise<MediaDerivativeClaim | null> {
    const id = requiredText(assetId, 'assetId');
    const key = requiredText(derivativeKey, 'derivativeKey');
    const token = requiredText(claimToken, 'claimToken');
    leaseDuration(leaseMs);
    const result = await this.pool.query<DerivativeRow>(
      `update media_derivatives d
       set state = 'processing',
           attempt_count = d.attempt_count + 1,
           claim_token = $3,
           lease_expires_at = now() + ($4 * interval '1 millisecond'),
           error_code = null,
           completed_at = null,
           updated_at = now()
       from media_assets a
       where d.asset_id = $1 and d.derivative_key = $2
         and a.id = d.asset_id and a.state <> 'revoked'
         and a.source_sha256 = d.source_sha256
         and (
           d.state in ('pending', 'failed')
           or (d.state = 'processing' and d.lease_expires_at <= now())
         )
       returning d.asset_id, d.derivative_key, d.purpose, d.state, d.source_sha256,
                 d.plan_version, d.plan, d.attempt_count, d.lease_expires_at,
                 d.storage_key, d.mime_type, d.size_bytes, d.width, d.height,
                 d.duration_ms, d.container, d.video_codec, d.video_profile,
                 d.audio_codec, d.color_space, d.dynamic_range, d.error_code,
                 d.output_metadata, d.completed_at`,
      [id, key, token, leaseMs],
    );
    return result.rows[0]
      ? {claimToken: token, derivative: derivativeFromRow(result.rows[0])}
      : null;
  }

  async markDerivativeReady(
    assetId: string,
    derivativeKey: string,
    claimToken: string,
    output: MediaDerivativeOutput,
  ): Promise<MediaDerivativeRecord> {
    const id = requiredText(assetId, 'assetId');
    const key = requiredText(derivativeKey, 'derivativeKey');
    const token = requiredText(claimToken, 'claimToken');
    const normalized = normalizeOutput(output);
    const result = await this.pool.query<DerivativeRow>(
      `update media_derivatives d
       set state = 'ready',
           claim_token = null,
           lease_expires_at = null,
           storage_key = $4,
           mime_type = $5,
           size_bytes = $6,
           width = $7,
           height = $8,
           duration_ms = $9,
           container = $10,
           video_codec = $11,
           video_profile = $12,
           audio_codec = $13,
           color_space = $14,
           dynamic_range = $15,
           error_code = null,
           output_metadata = $16::jsonb,
           completed_at = now(),
           updated_at = now()
       from media_assets a
       where d.asset_id = $1 and d.derivative_key = $2 and d.claim_token = $3
         and d.state = 'processing' and d.lease_expires_at > now()
         and a.id = d.asset_id and a.state <> 'revoked'
         and a.source_sha256 = d.source_sha256
       returning d.asset_id, d.derivative_key, d.purpose, d.state, d.source_sha256,
                 d.plan_version, d.plan, d.attempt_count, d.lease_expires_at,
                 d.storage_key, d.mime_type, d.size_bytes, d.width, d.height,
                 d.duration_ms, d.container, d.video_codec, d.video_profile,
                 d.audio_codec, d.color_space, d.dynamic_range, d.error_code,
                 d.output_metadata, d.completed_at`,
      [
        id,
        key,
        token,
        normalized.storageKey,
        normalized.mimeType,
        normalized.sizeBytes,
        normalized.width,
        normalized.height,
        normalized.durationMs,
        normalized.container,
        normalized.videoCodec,
        normalized.videoProfile,
        normalized.audioCodec,
        normalized.colorSpace,
        normalized.dynamicRange,
        canonicalJson(normalized.metadata),
      ],
    );
    if (result.rows[0]) return derivativeFromRow(result.rows[0]);

    const existing = await this.getDerivative(id, key);
    if (existing?.state === 'ready' && outputMatches(existing, normalized)) return existing;
    throw new MediaIdentityConflictError(`Media derivative ${id}/${key} has no active matching claim`);
  }

  async markDerivativeFailed(
    assetId: string,
    derivativeKey: string,
    claimToken: string,
    errorCode: string,
  ): Promise<MediaDerivativeRecord> {
    const id = requiredText(assetId, 'assetId');
    const key = requiredText(derivativeKey, 'derivativeKey');
    const token = requiredText(claimToken, 'claimToken');
    const code = requiredText(errorCode, 'errorCode');
    const result = await this.pool.query<DerivativeRow>(
      `update media_derivatives d
       set state = 'failed', claim_token = null, lease_expires_at = null,
           error_code = $4, completed_at = now(), updated_at = now()
       from media_assets a
       where d.asset_id = $1 and d.derivative_key = $2 and d.claim_token = $3
         and d.state = 'processing' and d.lease_expires_at > now()
         and a.id = d.asset_id and a.state <> 'revoked'
         and a.source_sha256 = d.source_sha256
       returning d.asset_id, d.derivative_key, d.purpose, d.state, d.source_sha256,
                 d.plan_version, d.plan, d.attempt_count, d.lease_expires_at,
                 d.storage_key, d.mime_type, d.size_bytes, d.width, d.height,
                 d.duration_ms, d.container, d.video_codec, d.video_profile,
                 d.audio_codec, d.color_space, d.dynamic_range, d.error_code,
                 d.output_metadata, d.completed_at`,
      [id, key, token, code],
    );
    if (result.rows[0]) return derivativeFromRow(result.rows[0]);

    const existing = await this.getDerivative(id, key);
    if (existing?.state === 'failed' && existing.errorCode === code) return existing;
    throw new MediaIdentityConflictError(`Media derivative ${id}/${key} has no active matching claim`);
  }

  async getDerivative(assetId: string, derivativeKey: string): Promise<MediaDerivativeRecord | null> {
    const result = await this.pool.query<DerivativeRow>(
      `select asset_id, derivative_key, purpose, state, source_sha256,
              plan_version, plan, attempt_count, lease_expires_at, storage_key,
              mime_type, size_bytes, width, height, duration_ms, container,
              video_codec, video_profile, audio_codec, color_space, dynamic_range,
              error_code, output_metadata, completed_at
       from media_derivatives where asset_id = $1 and derivative_key = $2`,
      [requiredText(assetId, 'assetId'), requiredText(derivativeKey, 'derivativeKey')],
    );
    return result.rows[0] ? derivativeFromRow(result.rows[0]) : null;
  }

  async revokeAsset(assetId: string): Promise<boolean> {
    const id = requiredText(assetId, 'assetId');
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      const current = await client.query<{state: MediaAssetState}>(
        'select state from media_assets where id = $1 for update',
        [id],
      );
      if (!current.rows[0]) {
        await client.query('rollback');
        return false;
      }
      if (current.rows[0].state !== 'revoked') {
        await client.query(
          `update media_assets
           set state = 'revoked', error_code = null, updated_at = now()
           where id = $1`,
          [id],
        );
        await client.query(
          `update media_derivatives
           set state = 'revoked', claim_token = null, lease_expires_at = null,
               error_code = null, updated_at = now()
           where asset_id = $1 and state <> 'revoked'`,
          [id],
        );
      }
      await client.query('commit');
      return true;
    } catch (error) {
      await client.query('rollback');
      throw error;
    } finally {
      client.release();
    }
  }
}

interface NormalizedSource {
  storageKey: string;
  sourceSha256: string;
  mimeType: string;
  sizeBytes: number;
  width: number | null;
  height: number | null;
  durationMs: number | null;
  metadata: Readonly<Record<string, CanonicalJsonValue>>;
}

interface NormalizedOutput {
  storageKey: string;
  mimeType: string;
  sizeBytes: number;
  width: number | null;
  height: number | null;
  durationMs: number | null;
  container: string | null;
  videoCodec: string | null;
  videoProfile: string | null;
  audioCodec: string | null;
  colorSpace: string | null;
  dynamicRange: 'sdr' | 'hdr' | null;
  metadata: Readonly<Record<string, CanonicalJsonValue>>;
}

function normalizeSource(input: MediaSourceInput): NormalizedSource {
  positiveInteger(input.sizeBytes, 'sizeBytes');
  optionalPositiveInteger(input.width, 'width');
  optionalPositiveInteger(input.height, 'height');
  optionalNonNegativeInteger(input.durationMs, 'durationMs');
  const metadata = input.metadata ?? {};
  canonicalJson(metadata);
  return {
    storageKey: requiredText(input.storageKey, 'storageKey'),
    sourceSha256: normalizeSha256(input.sourceSha256),
    mimeType: requiredText(input.mimeType, 'mimeType'),
    sizeBytes: input.sizeBytes,
    width: input.width ?? null,
    height: input.height ?? null,
    durationMs: input.durationMs ?? null,
    metadata,
  };
}

function normalizeOutput(output: MediaDerivativeOutput): NormalizedOutput {
  positiveInteger(output.sizeBytes, 'sizeBytes');
  optionalPositiveInteger(output.width, 'width');
  optionalPositiveInteger(output.height, 'height');
  optionalNonNegativeInteger(output.durationMs, 'durationMs');
  const metadata = output.metadata ?? {};
  canonicalJson(metadata);
  return {
    storageKey: requiredText(output.storageKey, 'storageKey'),
    mimeType: requiredText(output.mimeType, 'mimeType'),
    sizeBytes: output.sizeBytes,
    width: output.width ?? null,
    height: output.height ?? null,
    durationMs: output.durationMs ?? null,
    container: optionalText(output.container),
    videoCodec: optionalText(output.videoCodec),
    videoProfile: optionalText(output.videoProfile),
    audioCodec: optionalText(output.audioCodec),
    colorSpace: optionalText(output.colorSpace),
    dynamicRange: output.dynamicRange ?? null,
    metadata,
  };
}

function sourceMatches(asset: MediaAssetRecord, source: NormalizedSource): boolean {
  return asset.sourceStorageKey === source.storageKey &&
    asset.sourceSha256 === source.sourceSha256 &&
    asset.sourceMimeType === source.mimeType &&
    asset.sourceSizeBytes === source.sizeBytes &&
    asset.sourceWidth === source.width &&
    asset.sourceHeight === source.height &&
    asset.sourceDurationMs === source.durationMs &&
    canonicalJson(asset.sourceMetadata) === canonicalJson(source.metadata);
}

function outputMatches(derivative: MediaDerivativeRecord, output: NormalizedOutput): boolean {
  return derivative.storageKey === output.storageKey &&
    derivative.mimeType === output.mimeType &&
    derivative.sizeBytes === output.sizeBytes &&
    derivative.width === output.width &&
    derivative.height === output.height &&
    derivative.durationMs === output.durationMs &&
    derivative.container === output.container &&
    derivative.videoCodec === output.videoCodec &&
    derivative.videoProfile === output.videoProfile &&
    derivative.audioCodec === output.audioCodec &&
    derivative.colorSpace === output.colorSpace &&
    derivative.dynamicRange === output.dynamicRange &&
    canonicalJson(derivative.outputMetadata) === canonicalJson(output.metadata);
}

function assetFromRow(row: AssetRow): MediaAssetRecord {
  return {
    id: row.id,
    ownerActorId: row.owner_actor_id,
    kind: row.kind,
    state: row.state,
    sourceStorageKey: row.source_storage_key,
    sourceSha256: row.source_sha256,
    sourceMimeType: row.source_mime_type,
    sourceSizeBytes: nullableInteger(row.source_size_bytes),
    sourceWidth: row.source_width,
    sourceHeight: row.source_height,
    sourceDurationMs: nullableInteger(row.source_duration_ms),
    sourceMetadata: row.source_metadata,
    errorCode: row.error_code,
  };
}

function derivativeFromRow(row: DerivativeRow): MediaDerivativeRecord {
  return {
    assetId: row.asset_id,
    derivativeKey: row.derivative_key,
    purpose: row.purpose,
    state: row.state,
    sourceSha256: row.source_sha256,
    planVersion: row.plan_version,
    plan: row.plan,
    attemptCount: row.attempt_count,
    leaseExpiresAt: row.lease_expires_at,
    storageKey: row.storage_key,
    mimeType: row.mime_type,
    sizeBytes: nullableInteger(row.size_bytes),
    width: row.width,
    height: row.height,
    durationMs: nullableInteger(row.duration_ms),
    container: row.container,
    videoCodec: row.video_codec,
    videoProfile: row.video_profile,
    audioCodec: row.audio_codec,
    colorSpace: row.color_space,
    dynamicRange: row.dynamic_range,
    errorCode: row.error_code,
    outputMetadata: row.output_metadata,
    completedAt: row.completed_at,
  };
}

function nullableInteger(value: string | null): number | null {
  if (value === null) return null;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) throw new RangeError(`Database integer ${value} exceeds JavaScript safe range`);
  return parsed;
}

function requiredText(value: string, name: string): string {
  const normalized = value.trim();
  if (!normalized) throw new TypeError(`${name} must not be empty`);
  return normalized;
}

function optionalText(value: string | undefined): string | null {
  if (value === undefined) return null;
  return requiredText(value, 'optional media field');
}

function positiveInteger(value: number, name: string): void {
  if (!Number.isSafeInteger(value) || value <= 0) throw new TypeError(`${name} must be a positive safe integer`);
}

function optionalPositiveInteger(value: number | undefined, name: string): void {
  if (value !== undefined) positiveInteger(value, name);
}

function optionalNonNegativeInteger(value: number | undefined, name: string): void {
  if (value !== undefined && (!Number.isSafeInteger(value) || value < 0)) {
    throw new TypeError(`${name} must be a non-negative safe integer`);
  }
}

function leaseDuration(value: number): void {
  if (!Number.isSafeInteger(value) || value <= 0 || value > MAX_LEASE_MS) {
    throw new TypeError(`leaseMs must be a positive safe integer no greater than ${MAX_LEASE_MS}`);
  }
}

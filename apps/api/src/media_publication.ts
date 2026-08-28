import type {Pool, PoolClient} from 'pg';
import type {
  MediaAssetKind,
  MediaAssetState,
  MediaDerivativePurpose,
  MediaDerivativeState,
} from './media.js';

export type MediaPublicationBlockReason =
  | 'asset_not_found'
  | 'asset_revoked'
  | 'asset_not_ready'
  | 'source_unverified'
  | 'image_delivery_not_implemented'
  | 'playback_not_ready'
  | 'playback_incompatible'
  | 'poster_not_ready'
  | 'poster_incompatible'
  | 'audio_not_ready'
  | 'audio_incompatible'
  | 'captions_not_ready'
  | 'captions_incompatible';

export class MediaPublicationBlockedError extends Error {
  constructor(
    public readonly assetId: string,
    public readonly reason: MediaPublicationBlockReason,
  ) {
    super(`Media asset ${assetId} is not publishable: ${reason}`);
    this.name = 'MediaPublicationBlockedError';
  }
}

export interface MediaPublicationAsset {
  id: string;
  kind: MediaAssetKind;
  state: MediaAssetState;
  sourceSha256: string | null;
}

export interface MediaPublicationDerivative {
  derivativeKey: string;
  purpose: MediaDerivativePurpose;
  state: MediaDerivativeState;
  sourceSha256: string;
  planVersion: number;
  processor: string | null;
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
}

export interface MediaDeliveryObject {
  derivativeKey: string;
  purpose: MediaDerivativePurpose;
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
}

export interface MediaDeliverySelection {
  assetId: string;
  kind: 'video' | 'audio';
  sourceSha256: string;
  primary: MediaDeliveryObject;
  poster: MediaDeliveryObject | null;
  captions: MediaDeliveryObject | null;
}

type AssetRow = {
  id: string;
  kind: MediaAssetKind;
  state: MediaAssetState;
  source_sha256: string | null;
};

type DerivativeRow = {
  derivative_key: string;
  purpose: MediaDerivativePurpose;
  state: MediaDerivativeState;
  source_sha256: string;
  plan_version: number;
  processor: string | null;
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
};

const PLAYBACK_PROCESSOR = 'ffmpeg-video-normalize-v1';
const POSTER_PROCESSOR = 'ffmpeg-poster-v1';
const AUDIO_PROCESSOR = 'ffmpeg-audio-normalize-v1';
const CAPTIONS_PROCESSOR = 'speech-transcript-v1';

/**
 * Selects only managed, verified derivatives. Source object keys are deliberately
 * absent from the returned shape so callers cannot accidentally expose a
 * quarantined HEVC/HDR source as a playback fallback.
 */
export function selectMediaDelivery(
  asset: MediaPublicationAsset,
  derivatives: readonly MediaPublicationDerivative[],
): MediaDeliverySelection {
  if (asset.state === 'revoked') block(asset.id, 'asset_revoked');
  if (asset.sourceSha256 === null) block(asset.id, 'source_unverified');
  if (asset.kind === 'image') block(asset.id, 'image_delivery_not_implemented');

  const current = derivatives.filter(
    (derivative) => derivative.sourceSha256 === asset.sourceSha256,
  );
  const captions = selectOptionalCaptions(asset.id, current);

  if (asset.kind === 'video') {
    const primary = requireCompatible(
      asset.id,
      current,
      'playback',
      'playback_not_ready',
      'playback_incompatible',
      isCompatiblePlayback,
    );
    const poster = requireCompatible(
      asset.id,
      current,
      'poster',
      'poster_not_ready',
      'poster_incompatible',
      isCompatiblePoster,
    );
    return Object.freeze({
      assetId: asset.id,
      kind: 'video',
      sourceSha256: asset.sourceSha256,
      primary,
      poster,
      captions,
    });
  }

  const primary = requireCompatible(
    asset.id,
    current,
    'audio',
    'audio_not_ready',
    'audio_incompatible',
    isCompatibleAudio,
  );
  return Object.freeze({
    assetId: asset.id,
    kind: 'audio',
    sourceSha256: asset.sourceSha256,
    primary,
    poster: null,
    captions,
  });
}

export class PostgresMediaPublicationGate {
  constructor(private readonly pool: Pool) {}

  /**
   * Atomically promotes an asset to READY only after its current-source
   * derivatives satisfy the launch delivery profile.
   */
  async promoteReady(assetId: string): Promise<MediaDeliverySelection> {
    const id = requiredText(assetId, 'assetId');
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      const asset = await loadAsset(client, id, true);
      if (asset === null) block(id, 'asset_not_found');
      const derivatives = await loadDerivatives(client, id, asset.sourceSha256);
      const selection = selectMediaDelivery(asset, derivatives);
      const promoted = await client.query<{id: string}>(
        `update media_assets
         set state = 'ready', error_code = null, updated_at = now()
         where id = $1 and state <> 'revoked' and source_sha256 = $2
         returning id`,
        [id, selection.sourceSha256],
      );
      if (promoted.rowCount !== 1) block(id, 'asset_revoked');
      await client.query('commit');
      return selection;
    } catch (error) {
      await client.query('rollback').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  }

  /**
   * Revalidates a READY asset before a delivery URL is resolved. A revoked or
   * tampered derivative therefore cannot remain deliverable merely because the
   * asset was READY at an earlier point in time.
   */
  async resolveReady(assetId: string): Promise<MediaDeliverySelection> {
    const id = requiredText(assetId, 'assetId');
    const client = await this.pool.connect();
    try {
      await client.query('begin transaction isolation level repeatable read read only');
      const asset = await loadAsset(client, id, false);
      if (asset === null) block(id, 'asset_not_found');
      if (asset.state !== 'ready') block(id, asset.state === 'revoked' ? 'asset_revoked' : 'asset_not_ready');
      const derivatives = await loadDerivatives(client, id, asset.sourceSha256);
      const selection = selectMediaDelivery(asset, derivatives);
      await client.query('commit');
      return selection;
    } catch (error) {
      await client.query('rollback').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  }
}

function requireCompatible(
  assetId: string,
  derivatives: readonly MediaPublicationDerivative[],
  purpose: MediaDerivativePurpose,
  missingReason: MediaPublicationBlockReason,
  incompatibleReason: MediaPublicationBlockReason,
  compatible: (derivative: MediaPublicationDerivative) => boolean,
): MediaDeliveryObject {
  const candidates = derivatives.filter((derivative) => derivative.purpose === purpose);
  const ready = candidates.filter((derivative) => derivative.state === 'ready');
  if (ready.length === 0) block(assetId, missingReason);
  const selected = ordered(ready).find(compatible);
  if (selected === undefined) block(assetId, incompatibleReason);
  return deliveryObject(selected);
}

function selectOptionalCaptions(
  assetId: string,
  derivatives: readonly MediaPublicationDerivative[],
): MediaDeliveryObject | null {
  const candidates = derivatives.filter((derivative) => derivative.purpose === 'captions');
  if (candidates.length === 0) return null;
  const ready = candidates.filter((derivative) => derivative.state === 'ready');
  if (ready.length === 0) block(assetId, 'captions_not_ready');
  const selected = ordered(ready).find(isCompatibleCaptions);
  if (selected === undefined) block(assetId, 'captions_incompatible');
  return deliveryObject(selected);
}

function ordered(
  derivatives: readonly MediaPublicationDerivative[],
): readonly MediaPublicationDerivative[] {
  return [...derivatives].sort((left, right) =>
    right.planVersion - left.planVersion ||
    left.derivativeKey.localeCompare(right.derivativeKey),
  );
}

function isCompatiblePlayback(value: MediaPublicationDerivative): boolean {
  return hasPublishedObject(value) &&
    value.processor === PLAYBACK_PROCESSOR &&
    value.mimeType === 'video/mp4' &&
    value.container === 'mp4' &&
    value.videoCodec === 'h264' &&
    value.videoProfile === 'main' &&
    (value.audioCodec === null || value.audioCodec === 'aac') &&
    value.colorSpace === 'bt709' &&
    value.dynamicRange === 'sdr' &&
    positiveDimension(value.width) &&
    positiveDimension(value.height);
}

function isCompatiblePoster(value: MediaPublicationDerivative): boolean {
  return hasPublishedObject(value) &&
    value.processor === POSTER_PROCESSOR &&
    value.mimeType === 'image/jpeg' &&
    value.dynamicRange === 'sdr' &&
    positiveDimension(value.width) &&
    positiveDimension(value.height);
}

function isCompatibleAudio(value: MediaPublicationDerivative): boolean {
  return hasPublishedObject(value) &&
    value.processor === AUDIO_PROCESSOR &&
    value.mimeType === 'audio/mp4' &&
    value.container === 'mp4' &&
    value.audioCodec === 'aac' &&
    nonNegativeDuration(value.durationMs);
}

function isCompatibleCaptions(value: MediaPublicationDerivative): boolean {
  return hasPublishedObject(value) &&
    value.processor === CAPTIONS_PROCESSOR &&
    value.mimeType === 'text/vtt';
}

function hasPublishedObject(
  value: MediaPublicationDerivative,
): value is MediaPublicationDerivative & {
  storageKey: string;
  mimeType: string;
  sizeBytes: number;
} {
  return value.state === 'ready' &&
    value.storageKey !== null &&
    value.storageKey.length > 0 &&
    value.mimeType !== null &&
    value.mimeType.length > 0 &&
    value.sizeBytes !== null &&
    Number.isSafeInteger(value.sizeBytes) &&
    value.sizeBytes > 0;
}

function deliveryObject(
  value: MediaPublicationDerivative & {
    storageKey: string;
    mimeType: string;
    sizeBytes: number;
  },
): MediaDeliveryObject {
  return Object.freeze({
    derivativeKey: value.derivativeKey,
    purpose: value.purpose,
    storageKey: value.storageKey,
    mimeType: value.mimeType,
    sizeBytes: value.sizeBytes,
    width: value.width,
    height: value.height,
    durationMs: value.durationMs,
    container: value.container,
    videoCodec: value.videoCodec,
    videoProfile: value.videoProfile,
    audioCodec: value.audioCodec,
    colorSpace: value.colorSpace,
    dynamicRange: value.dynamicRange,
  });
}

function positiveDimension(value: number | null): boolean {
  return value !== null && Number.isSafeInteger(value) && value > 0;
}

function nonNegativeDuration(value: number | null): boolean {
  return value !== null && Number.isSafeInteger(value) && value >= 0;
}

async function loadAsset(
  client: PoolClient,
  assetId: string,
  lock: boolean,
): Promise<MediaPublicationAsset | null> {
  const result = await client.query<AssetRow>(
    `select id, kind, state, source_sha256
     from media_assets
     where id = $1${lock ? ' for update' : ''}`,
    [assetId],
  );
  const row = result.rows[0];
  return row === undefined
    ? null
    : {
        id: row.id,
        kind: row.kind,
        state: row.state,
        sourceSha256: row.source_sha256,
      };
}

async function loadDerivatives(
  client: PoolClient,
  assetId: string,
  sourceSha256: string | null,
): Promise<readonly MediaPublicationDerivative[]> {
  if (sourceSha256 === null) return [];
  const result = await client.query<DerivativeRow>(
    `select derivative_key, purpose, state, source_sha256, plan_version,
            plan->>'processor' as processor, storage_key, mime_type, size_bytes,
            width, height, duration_ms, container, video_codec, video_profile,
            audio_codec, color_space, dynamic_range
     from media_derivatives
     where asset_id = $1 and source_sha256 = $2
     order by plan_version desc, created_at desc, derivative_key asc`,
    [assetId, sourceSha256],
  );
  return result.rows.map(derivativeFromRow);
}

function derivativeFromRow(row: DerivativeRow): MediaPublicationDerivative {
  return {
    derivativeKey: row.derivative_key,
    purpose: row.purpose,
    state: row.state,
    sourceSha256: row.source_sha256,
    planVersion: row.plan_version,
    processor: row.processor,
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
  };
}

function nullableInteger(value: string | null): number | null {
  if (value === null) return null;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    throw new RangeError(`Database integer ${value} exceeds JavaScript safe range`);
  }
  return parsed;
}

function requiredText(value: string, name: string): string {
  const normalized = value.trim();
  if (!normalized || normalized.includes('\u0000')) {
    throw new TypeError(`${name} must be non-empty and contain no NUL bytes`);
  }
  return normalized;
}

function block(assetId: string, reason: MediaPublicationBlockReason): never {
  throw new MediaPublicationBlockedError(assetId, reason);
}

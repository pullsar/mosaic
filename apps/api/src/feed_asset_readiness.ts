import {createHash} from 'node:crypto';
import type {Pool} from 'pg';
import {
  CANVAS_ASSET_SCHEMA_VERSION,
  normalizeCanvasAssetDocument,
} from './canvas_asset.js';
import {canonicalJson, type MediaAssetKind, type MediaAssetState, type MediaDerivativePurpose, type MediaDerivativeState} from './media.js';
import {
  MediaPublicationBlockedError,
  selectMediaDelivery,
  type MediaDeliverySelection,
  type MediaPublicationAsset,
  type MediaPublicationDerivative,
} from './media_publication.js';
import type {FeedCandidate} from './consumer_ranking.js';

export type FeedAssetKind = 'image' | 'video' | 'audio' | 'canvas';

export interface FeedAssetRequirement {
  assetId: string;
  kind: FeedAssetKind;
}

export interface FeedAssetReadinessResolver {
  filterDeliverable(
    candidates: readonly FeedCandidate[],
  ): Promise<FeedCandidate[]>;
}

export interface PostgresFeedAssetReadinessOptions {
  binaryDeliveryEnabled: boolean;
  batchSize?: number;
}

const DEFAULT_BATCH_SIZE = 500;
const MAX_BATCH_SIZE = 1000;
const MAX_ASSETS_PER_PLAY = 64;
const MAX_ASSET_ID_LENGTH = 200;

interface CandidateRequirements {
  candidate: FeedCandidate;
  requirements: readonly FeedAssetRequirement[];
}

type MediaReadinessRow = {
  asset_id: string;
  asset_kind: MediaAssetKind;
  asset_state: MediaAssetState;
  asset_source_sha256: string | null;
  derivative_key: string | null;
  purpose: MediaDerivativePurpose | null;
  derivative_state: MediaDerivativeState | null;
  derivative_source_sha256: string | null;
  plan_version: number | null;
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

type CanvasReadinessRow = {
  id: string;
  schema_version: number;
  state: 'ready' | 'revoked';
  content_sha256: string;
  document: unknown;
};

export class PostgresFeedAssetReadinessResolver
implements FeedAssetReadinessResolver {
  private readonly binaryDeliveryEnabled: boolean;
  private readonly batchSize: number;

  constructor(
    private readonly pool: Pool,
    options: PostgresFeedAssetReadinessOptions,
  ) {
    this.binaryDeliveryEnabled = options.binaryDeliveryEnabled;
    this.batchSize = boundedInteger(
      options.batchSize ?? DEFAULT_BATCH_SIZE,
      1,
      MAX_BATCH_SIZE,
      'batchSize',
    );
  }

  async filterDeliverable(
    candidates: readonly FeedCandidate[],
  ): Promise<FeedCandidate[]> {
    const parsed: CandidateRequirements[] = [];
    const mediaAssetIds = new Set<string>();
    const canvasAssetIds = new Set<string>();

    for (const candidate of candidates) {
      const requirements = extractFeedAssetRequirements(candidate.document);
      if (requirements === null) continue;
      parsed.push({candidate, requirements});
      for (const requirement of requirements) {
        if (requirement.kind === 'canvas') {
          canvasAssetIds.add(requirement.assetId);
        } else {
          mediaAssetIds.add(requirement.assetId);
        }
      }
    }

    const [media, canvas] = await Promise.all([
      this.binaryDeliveryEnabled
        ? this.loadReadyMedia([...mediaAssetIds])
        : Promise.resolve(new Map<string, MediaDeliverySelection>()),
      this.loadReadyCanvas([...canvasAssetIds]),
    ]);

    return parsed
      .filter(({requirements}) =>
        requirements.every((requirement) => {
          if (requirement.kind === 'canvas') {
            return canvas.has(requirement.assetId);
          }
          const selection = media.get(requirement.assetId);
          return selection?.kind === requirement.kind;
        }),
      )
      .map(({candidate}) => candidate);
  }

  private async loadReadyMedia(
    assetIds: readonly string[],
  ): Promise<Map<string, MediaDeliverySelection>> {
    const selections = new Map<string, MediaDeliverySelection>();
    for (const ids of chunks(assetIds, this.batchSize)) {
      if (ids.length === 0) continue;
      const result = await this.pool.query<MediaReadinessRow>(
        `select a.id as asset_id,
                a.kind as asset_kind,
                a.state as asset_state,
                a.source_sha256 as asset_source_sha256,
                d.derivative_key,
                d.purpose,
                d.state as derivative_state,
                d.source_sha256 as derivative_source_sha256,
                d.plan_version,
                d.plan->>'processor' as processor,
                d.storage_key,
                d.mime_type,
                d.size_bytes,
                d.width,
                d.height,
                d.duration_ms,
                d.container,
                d.video_codec,
                d.video_profile,
                d.audio_codec,
                d.color_space,
                d.dynamic_range
           from media_assets a
           left join media_derivatives d
             on d.asset_id = a.id
            and d.source_sha256 = a.source_sha256
          where a.id = any($1::text[])
          order by a.id,
                   d.plan_version desc nulls last,
                   d.created_at desc nulls last,
                   d.derivative_key asc nulls last`,
        [ids],
      );

      const grouped = new Map<string, MediaReadinessRow[]>();
      for (const row of result.rows) {
        const rows = grouped.get(row.asset_id);
        if (rows === undefined) grouped.set(row.asset_id, [row]);
        else rows.push(row);
      }

      for (const [assetId, rows] of grouped) {
        const first = rows[0];
        if (
          first === undefined ||
          first.asset_state !== 'ready' ||
          first.asset_source_sha256 === null
        ) {
          continue;
        }
        const asset: MediaPublicationAsset = {
          id: assetId,
          kind: first.asset_kind,
          state: first.asset_state,
          sourceSha256: first.asset_source_sha256,
        };
        try {
          const derivatives = rows
            .map(derivativeFromReadinessRow)
            .filter((value): value is MediaPublicationDerivative => value !== null);
          selections.set(assetId, selectMediaDelivery(asset, derivatives));
        } catch (error) {
          if (
            error instanceof MediaPublicationBlockedError ||
            error instanceof TypeError ||
            error instanceof RangeError
          ) {
            continue;
          }
          throw error;
        }
      }
    }
    return selections;
  }

  private async loadReadyCanvas(
    assetIds: readonly string[],
  ): Promise<Set<string>> {
    const ready = new Set<string>();
    for (const ids of chunks(assetIds, this.batchSize)) {
      if (ids.length === 0) continue;
      const result = await this.pool.query<CanvasReadinessRow>(
        `select id, schema_version, state, content_sha256, document
           from canvas_assets
          where id = any($1::text[])`,
        [ids],
      );
      for (const row of result.rows) {
        if (
          row.state !== 'ready' ||
          row.schema_version !== CANVAS_ASSET_SCHEMA_VERSION
        ) {
          continue;
        }
        try {
          const document = normalizeCanvasAssetDocument(row.document);
          if (document.id !== row.id) continue;
          const digest = createHash('sha256')
            .update(canonicalJson(document), 'utf8')
            .digest('hex');
          if (digest === row.content_sha256) ready.add(row.id);
        } catch (error) {
          if (error instanceof TypeError || error instanceof RangeError) continue;
          throw error;
        }
      }
    }
    return ready;
  }
}

export function extractFeedAssetRequirements(
  document: unknown,
): readonly FeedAssetRequirement[] | null {
  if (!isRecord(document) || !isRecord(document.states)) return null;
  const requirements = new Map<string, FeedAssetKind>();

  for (const rawState of Object.values(document.states)) {
    if (!isRecord(rawState) || !isRecord(rawState.presentation)) return null;
    const layers = rawState.presentation.layers;
    if (!Array.isArray(layers)) return null;
    for (const rawLayer of layers) {
      if (!isRecord(rawLayer) || typeof rawLayer.type !== 'string') return null;
      const kind = assetKindForPresentation(rawLayer.type);
      if (kind === null) continue;
      const assetId = normalizedAssetId(rawLayer.assetId);
      if (assetId === null) return null;
      const existing = requirements.get(assetId);
      if (existing !== undefined && existing !== kind) return null;
      requirements.set(assetId, kind);
      if (requirements.size > MAX_ASSETS_PER_PLAY) return null;
    }
  }

  return Object.freeze(
    [...requirements.entries()]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([assetId, kind]) => Object.freeze({assetId, kind})),
  );
}

function assetKindForPresentation(type: string): FeedAssetKind | null {
  switch (type) {
    case 'image':
      return 'image';
    case 'video_clip':
      return 'video';
    case 'audio':
      return 'audio';
    case 'canvas':
      return 'canvas';
    default:
      return null;
  }
}

function derivativeFromReadinessRow(
  row: MediaReadinessRow,
): MediaPublicationDerivative | null {
  if (row.derivative_key === null) return null;
  if (
    row.purpose === null ||
    row.derivative_state === null ||
    row.derivative_source_sha256 === null ||
    row.plan_version === null
  ) {
    throw new TypeError(
      `Media derivative ${row.asset_id}/${row.derivative_key} has incomplete identity metadata`,
    );
  }
  return {
    derivativeKey: row.derivative_key,
    purpose: row.purpose,
    state: row.derivative_state,
    sourceSha256: row.derivative_source_sha256,
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

function normalizedAssetId(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const normalized = value.trim();
  if (
    normalized.length === 0 ||
    normalized.length > MAX_ASSET_ID_LENGTH ||
    /[\u0000-\u001F\u007F]/.test(normalized)
  ) {
    return null;
  }
  return normalized;
}

function nullableInteger(value: string | null): number | null {
  if (value === null) return null;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    throw new RangeError(`Database integer ${value} exceeds JavaScript safe range`);
  }
  return parsed;
}

function chunks<T>(values: readonly T[], size: number): T[][] {
  const result: T[][] = [];
  for (let index = 0; index < values.length; index += size) {
    result.push(values.slice(index, index + size));
  }
  return result;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function boundedInteger(
  value: number,
  min: number,
  max: number,
  name: string,
): number {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new RangeError(`${name} must be an integer between ${min} and ${max}`);
  }
  return value;
}

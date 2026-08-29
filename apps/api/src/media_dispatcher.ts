import {randomUUID} from 'node:crypto';
import {type Pool} from 'pg';
import {
  PostgresMediaRepository,
  type MediaDerivativeClaim,
} from './media_repository.js';

export const FFMPEG_MEDIA_PROCESSORS = Object.freeze([
  'ffmpeg-image-normalize-v1',
  'ffmpeg-video-normalize-v1',
  'ffmpeg-poster-v1',
  'ffmpeg-audio-normalize-v1',
] as const);

const DEFAULT_LEASE_MS = 15 * 60 * 1000;
const MAX_LEASE_MS = 60 * 60 * 1000;
const MAX_PROCESSORS = 16;

export interface MediaDispatchClaim {
  claim: MediaDerivativeClaim;
}

export class PostgresMediaDispatcher {
  private readonly repository: PostgresMediaRepository;

  constructor(
    private readonly pool: Pool,
    repository?: PostgresMediaRepository,
  ) {
    this.repository = repository ?? new PostgresMediaRepository(pool);
  }

  async claimNext(
    processors: readonly string[] = FFMPEG_MEDIA_PROCESSORS,
    leaseMs = DEFAULT_LEASE_MS,
    claimToken: string = randomUUID(),
  ): Promise<MediaDerivativeClaim | null> {
    const normalizedProcessors = processorList(processors);
    const token = requiredText(claimToken, 'claimToken');
    leaseDuration(leaseMs);

    const result = await this.pool.query<{
      asset_id: string;
      derivative_key: string;
    }>(
      `with candidate as (
         select d.asset_id, d.derivative_key
         from media_derivatives d
         join media_assets a on a.id = d.asset_id
         where a.state <> 'revoked'
           and a.source_sha256 = d.source_sha256
           and d.plan->>'processor' = any($1::text[])
           and (
             d.state in ('pending', 'failed')
             or (d.state = 'processing' and d.lease_expires_at <= now())
           )
         order by
           case d.purpose
             when 'image' then 0
             when 'playback' then 0
             when 'poster' then 1
             when 'audio' then 2
             else 3
           end,
           d.created_at,
           d.asset_id,
           d.derivative_key
         for update of d skip locked
         limit 1
       )
       update media_derivatives d
       set state = 'processing',
           attempt_count = d.attempt_count + 1,
           claim_token = $2,
           lease_expires_at = now() + ($3 * interval '1 millisecond'),
           error_code = null,
           completed_at = null,
           updated_at = now()
       from candidate c
       where d.asset_id = c.asset_id
         and d.derivative_key = c.derivative_key
       returning d.asset_id, d.derivative_key`,
      [normalizedProcessors, token, leaseMs],
    );

    const row = result.rows[0];
    if (row === undefined) return null;
    const derivative = await this.repository.getDerivative(
      row.asset_id,
      row.derivative_key,
    );
    if (derivative === null) {
      throw new Error(
        `Claimed media derivative ${row.asset_id}/${row.derivative_key} disappeared`,
      );
    }
    if (derivative.state !== 'processing') {
      return null;
    }
    return {claimToken: token, derivative};
  }
}

function processorList(processors: readonly string[]): readonly string[] {
  if (processors.length === 0 || processors.length > MAX_PROCESSORS) {
    throw new TypeError(
      `processors must contain between 1 and ${MAX_PROCESSORS} values`,
    );
  }
  const normalized = processors.map((value, index) =>
    requiredText(value, `processors[${index}]`),
  );
  return Object.freeze([...new Set(normalized)]);
}

function requiredText(value: string, name: string): string {
  const normalized = value.trim();
  if (!normalized || normalized.includes('\u0000')) {
    throw new TypeError(`${name} must be non-empty and contain no NUL bytes`);
  }
  return normalized;
}

function leaseDuration(value: number): void {
  if (!Number.isSafeInteger(value) || value <= 0 || value > MAX_LEASE_MS) {
    throw new TypeError(
      `leaseMs must be a positive safe integer no greater than ${MAX_LEASE_MS}`,
    );
  }
}

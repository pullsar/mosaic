create table if not exists media_assets (
  id text primary key,
  owner_actor_id text not null references actors(id),
  kind text not null check (kind in ('image', 'video', 'audio')),
  state text not null default 'registered'
    check (state in ('registered', 'uploaded', 'processing', 'ready', 'failed', 'revoked')),
  source_storage_key text,
  source_sha256 text check (source_sha256 is null or source_sha256 ~ '^[0-9a-f]{64}$'),
  source_mime_type text,
  source_size_bytes bigint check (source_size_bytes is null or source_size_bytes > 0),
  source_width integer check (source_width is null or source_width > 0),
  source_height integer check (source_height is null or source_height > 0),
  source_duration_ms bigint check (source_duration_ms is null or source_duration_ms >= 0),
  source_metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(source_metadata) = 'object'),
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (source_sha256 is null and source_storage_key is null and source_mime_type is null and source_size_bytes is null)
    or
    (source_sha256 is not null and source_storage_key is not null and source_mime_type is not null and source_size_bytes is not null)
  )
);

create index if not exists media_assets_owner_updated_idx
  on media_assets(owner_actor_id, updated_at desc);

create table if not exists media_derivatives (
  asset_id text not null references media_assets(id) on delete cascade,
  derivative_key text not null,
  purpose text not null check (purpose in ('playback', 'poster', 'audio', 'captions')),
  state text not null default 'pending'
    check (state in ('pending', 'processing', 'ready', 'failed', 'revoked')),
  source_sha256 text not null check (source_sha256 ~ '^[0-9a-f]{64}$'),
  plan_version integer not null check (plan_version > 0),
  plan jsonb not null check (jsonb_typeof(plan) = 'object'),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  claim_token text,
  lease_expires_at timestamptz,
  storage_key text,
  mime_type text,
  size_bytes bigint check (size_bytes is null or size_bytes > 0),
  width integer check (width is null or width > 0),
  height integer check (height is null or height > 0),
  duration_ms bigint check (duration_ms is null or duration_ms >= 0),
  container text,
  video_codec text,
  video_profile text,
  audio_codec text,
  color_space text,
  dynamic_range text check (dynamic_range is null or dynamic_range in ('sdr', 'hdr')),
  error_code text,
  output_metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(output_metadata) = 'object'),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (asset_id, derivative_key),
  check (
    (state = 'processing' and claim_token is not null and lease_expires_at is not null)
    or
    (state <> 'processing' and claim_token is null and lease_expires_at is null)
  ),
  check (state <> 'failed' or error_code is not null),
  check (
    state <> 'ready'
    or (storage_key is not null and mime_type is not null and size_bytes is not null and error_code is null)
  )
);

create index if not exists media_derivatives_asset_purpose_state_idx
  on media_derivatives(asset_id, purpose, state, updated_at desc);

create index if not exists media_derivatives_work_idx
  on media_derivatives(state, lease_expires_at, updated_at)
  where state in ('pending', 'failed', 'processing');

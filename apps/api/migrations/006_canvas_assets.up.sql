create table if not exists canvas_assets (
  id text primary key,
  schema_version integer not null check (schema_version = 1),
  state text not null default 'ready' check (state in ('ready', 'revoked')),
  content_sha256 text not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
  document jsonb not null check (jsonb_typeof(document) = 'object'),
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  check (
    (state = 'ready' and revoked_at is null)
    or (state = 'revoked' and revoked_at is not null)
  ),
  check (document->>'id' = id),
  check ((document->>'schemaVersion')::integer = schema_version)
);

create index if not exists canvas_assets_ready_idx
  on canvas_assets(id)
  where state = 'ready';

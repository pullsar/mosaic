create table if not exists game_family_revisions (
  id text not null check (length(id) between 1 and 200),
  revision_id text not null check (length(revision_id) between 1 and 200),
  content_sha256 text not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
  document jsonb not null check (jsonb_typeof(document) = 'object'),
  published_at timestamptz not null default now(),
  primary key (id, revision_id)
);

create table if not exists game_theme_revisions (
  id text not null check (length(id) between 1 and 200),
  revision_id text not null check (length(revision_id) between 1 and 200),
  content_sha256 text not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
  document jsonb not null check (jsonb_typeof(document) = 'object'),
  published_at timestamptz not null default now(),
  primary key (id, revision_id)
);

create table if not exists actors (
  id text primary key,
  created_at timestamptz not null default now()
);

create table if not exists users (
  id text primary key,
  created_at timestamptz not null default now()
);

create table if not exists sessions (
  id text primary key,
  actor_id text not null references actors(id),
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

create table if not exists actor_user_merges (
  actor_id text primary key references actors(id),
  user_id text not null references users(id),
  merged_at timestamptz not null default now()
);

create table if not exists topics (
  id text primary key,
  label text not null,
  created_at timestamptz not null default now()
);

create table if not exists plays (
  id text primary key,
  created_at timestamptz not null default now()
);

create table if not exists play_revisions (
  play_id text not null references plays(id),
  revision_id text not null,
  schema_version integer not null,
  document jsonb not null,
  created_at timestamptz not null default now(),
  primary key (play_id, revision_id)
);

create table if not exists interaction_events (
  event_id text primary key,
  event_name text not null,
  event_version integer not null,
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  actor_id text not null,
  session_id text not null,
  feed_request_id text,
  play_revision_id text,
  payload jsonb not null default '{}'::jsonb
);

create index if not exists interaction_events_actor_received_idx
  on interaction_events(actor_id, received_at desc);

create index if not exists interaction_events_play_received_idx
  on interaction_events(play_revision_id, received_at desc)
  where play_revision_id is not null;

create table if not exists actor_topic_preferences (
  actor_id text not null references actors(id) on delete cascade,
  topic_id text not null references topics(id) on delete cascade,
  kind text not null check (kind in ('interest', 'learning')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (actor_id, topic_id, kind)
);

create index if not exists actor_topic_preferences_actor_kind_idx
  on actor_topic_preferences(actor_id, kind, topic_id);

create table if not exists play_revision_topics (
  play_id text not null,
  revision_id text not null,
  topic_id text not null references topics(id) on delete cascade,
  role text not null check (role in ('interest', 'learning')),
  created_at timestamptz not null default now(),
  primary key (play_id, revision_id, topic_id, role),
  foreign key (play_id, revision_id)
    references play_revisions(play_id, revision_id) on delete cascade
);

create index if not exists play_revision_topics_topic_role_idx
  on play_revision_topics(topic_id, role, play_id, revision_id);

create table if not exists feed_catalog_entries (
  play_id text not null,
  revision_id text not null,
  state text not null default 'eligible'
    check (state in ('eligible', 'suspended')),
  quality_prior double precision not null default 0.5
    check (quality_prior >= 0 and quality_prior <= 1),
  curated_order integer not null default 1000 check (curated_order >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (play_id, revision_id),
  foreign key (play_id, revision_id)
    references play_revisions(play_id, revision_id) on delete cascade
);

create index if not exists feed_catalog_entries_eligible_idx
  on feed_catalog_entries(curated_order, play_id, revision_id)
  where state = 'eligible';

create table if not exists feed_decisions (
  request_id text primary key,
  actor_id text not null references actors(id) on delete cascade,
  ranking_config_version text not null,
  capability_fingerprint text not null,
  fallback boolean not null default false,
  candidate_count integer not null check (candidate_count >= 0),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  check (expires_at > created_at)
);

create index if not exists feed_decisions_actor_created_idx
  on feed_decisions(actor_id, created_at desc, request_id);

create index if not exists feed_decisions_actor_expiry_idx
  on feed_decisions(actor_id, expires_at);

create table if not exists feed_decision_items (
  request_id text not null references feed_decisions(request_id) on delete cascade,
  position integer not null check (position >= 0),
  play_id text not null,
  revision_id text not null,
  source_bucket text not null
    check (source_bucket in ('known', 'adjacent', 'wildcard', 'curated_fallback')),
  score double precision not null,
  feature_contributions jsonb not null default '{}'::jsonb
    check (jsonb_typeof(feature_contributions) = 'object'),
  primary key (request_id, position),
  unique (request_id, play_id, revision_id),
  foreign key (play_id, revision_id)
    references play_revisions(play_id, revision_id)
);

create index if not exists feed_decision_items_revision_idx
  on feed_decision_items(play_id, revision_id, request_id);

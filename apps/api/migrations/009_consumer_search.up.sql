create index if not exists topics_search_label_prefix_idx
  on topics (lower(label) text_pattern_ops, id);

create index if not exists topics_search_id_prefix_idx
  on topics (lower(id) text_pattern_ops);

create index if not exists feed_catalog_search_play_prefix_idx
  on feed_catalog_entries (lower(play_id) text_pattern_ops, curated_order, play_id, revision_id)
  where state = 'eligible';

create table if not exists consumer_search_decisions (
  request_id text primary key,
  actor_id text not null references actors(id) on delete cascade,
  intent text not null check (intent in ('interest', 'learning')),
  query_sha256 text not null check (query_sha256 ~ '^[0-9a-f]{64}$'),
  capability_fingerprint text not null,
  result_count integer not null check (result_count >= 0 and result_count <= 60),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  check (expires_at > created_at)
);

create index if not exists consumer_search_decisions_actor_created_idx
  on consumer_search_decisions(actor_id, created_at desc, request_id);

create index if not exists consumer_search_decisions_expiry_idx
  on consumer_search_decisions(expires_at, request_id);

create table if not exists consumer_search_decision_items (
  request_id text not null references consumer_search_decisions(request_id) on delete cascade,
  position integer not null check (position >= 0 and position < 60),
  kind text not null check (kind in ('topic', 'play')),
  match_kind text not null check (
    match_kind in ('topic_exact', 'topic_prefix', 'play_exact', 'play_prefix')
  ),
  topic_id text references topics(id),
  play_id text,
  revision_id text,
  primary key (request_id, position),
  check (
    (kind = 'topic' and topic_id is not null and play_id is null and revision_id is null)
    or
    (kind = 'play' and topic_id is null and play_id is not null and revision_id is not null)
  ),
  foreign key (play_id, revision_id)
    references play_revisions(play_id, revision_id)
);

create index if not exists consumer_search_decision_items_play_idx
  on consumer_search_decision_items(play_id, revision_id, request_id)
  where kind = 'play';

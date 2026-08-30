create table if not exists consumer_signal_profiles (
  actor_id text primary key references actors(id) on delete cascade,
  profile_version integer not null default 1 check (profile_version = 1),
  checkpoint_received_at timestamptz,
  checkpoint_event_id text,
  interaction_affinity jsonb not null default '{}'::jsonb
    check (jsonb_typeof(interaction_affinity) = 'object'),
  recent_revisions jsonb not null default '[]'::jsonb
    check (jsonb_typeof(recent_revisions) = 'array'),
  topic_dismissal_counts jsonb not null default '{}'::jsonb
    check (jsonb_typeof(topic_dismissal_counts) = 'object'),
  format_dismissal_counts jsonb not null default '{}'::jsonb
    check (jsonb_typeof(format_dismissal_counts) = 'object'),
  more_like_topic_expiries jsonb not null default '{}'::jsonb
    check (jsonb_typeof(more_like_topic_expiries) = 'object'),
  format_last_dismissed_at jsonb not null default '{}'::jsonb
    check (jsonb_typeof(format_last_dismissed_at) = 'object'),
  updated_at timestamptz not null default now(),
  check (
    (checkpoint_received_at is null and checkpoint_event_id is null)
    or (checkpoint_received_at is not null and checkpoint_event_id is not null)
  )
);

create index if not exists consumer_signal_profiles_updated_idx
  on consumer_signal_profiles(updated_at, actor_id);

create table if not exists actor_saved_plays (
  actor_id text not null references actors(id) on delete cascade,
  play_id text not null,
  revision_id text not null,
  saved boolean not null,
  event_received_at timestamptz not null,
  event_id text not null,
  updated_at timestamptz not null default now(),
  primary key (actor_id, play_id),
  foreign key (play_id, revision_id)
    references play_revisions(play_id, revision_id) on delete cascade
);

create index if not exists actor_saved_plays_active_idx
  on actor_saved_plays(actor_id, updated_at desc, play_id)
  where saved = true;

create table if not exists actor_play_signals (
  actor_id text not null references actors(id) on delete cascade,
  play_id text not null,
  revision_id text not null,
  signal text not null check (signal in ('more_like_this', 'not_interested')),
  first_received_at timestamptz not null,
  first_event_id text not null,
  updated_at timestamptz not null default now(),
  primary key (actor_id, play_id, signal),
  foreign key (play_id, revision_id)
    references play_revisions(play_id, revision_id) on delete cascade
);

create index if not exists actor_play_signals_actor_signal_idx
  on actor_play_signals(actor_id, signal, play_id);

create table if not exists actor_topic_mutes (
  actor_id text not null references actors(id) on delete cascade,
  topic_id text not null references topics(id) on delete cascade,
  muted boolean not null,
  event_received_at timestamptz not null,
  event_id text not null,
  updated_at timestamptz not null default now(),
  primary key (actor_id, topic_id)
);

create index if not exists actor_topic_mutes_active_idx
  on actor_topic_mutes(actor_id, topic_id)
  where muted = true;

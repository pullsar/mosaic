create table if not exists play_challenges (
  invite_id text primary key check (invite_id ~ '^pc_[A-Za-z0-9_-]{22}$'),
  creator_actor_id text not null references actors(id) on delete cascade,
  creator_idempotency_key text not null check (length(creator_idempotency_key) between 1 and 200),
  creation_fingerprint text not null check (creation_fingerprint ~ '^[0-9a-f]{64}$'),
  play_id text not null,
  revision_id text not null,
  presentation jsonb,
  mode text not null check (mode = 'async_same_round'),
  scoring_version text not null check (length(scoring_version) between 1 and 100),
  reveal_policy text not null check (reveal_policy = 'after_participant_submission'),
  creator_result jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  foreign key (play_id, revision_id)
    references play_revisions(play_id, revision_id) on delete restrict,
  unique (creator_actor_id, creator_idempotency_key)
);

create index if not exists play_challenges_open_idx
  on play_challenges(expires_at, invite_id)
  where revoked_at is null;

create table if not exists play_challenge_submissions (
  invite_id text not null references play_challenges(invite_id) on delete cascade,
  actor_id text not null references actors(id) on delete cascade,
  result jsonb not null check (jsonb_typeof(result) = 'object'),
  submitted_at timestamptz not null default now(),
  primary key (invite_id, actor_id)
);

create index if not exists play_challenge_submissions_actor_idx
  on play_challenge_submissions(actor_id, submitted_at desc);

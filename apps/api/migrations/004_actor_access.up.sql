create table if not exists actor_access_credentials (
  actor_id text primary key references actors(id) on delete cascade,
  credential_digest text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (credential_digest ~ '^[0-9a-f]{64}$')
);

create index if not exists actor_access_credentials_digest_idx
  on actor_access_credentials(credential_digest);

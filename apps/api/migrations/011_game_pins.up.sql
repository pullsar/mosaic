create table if not exists actor_game_pins (
  actor_id text primary key references actors(id) on delete cascade,
  family_ids jsonb not null default '[]'::jsonb
    check (jsonb_typeof(family_ids) = 'array'),
  event_received_at timestamptz not null,
  event_id text not null,
  updated_at timestamptz not null default now()
);

create index if not exists actor_game_pins_updated_idx
  on actor_game_pins(updated_at desc, actor_id);

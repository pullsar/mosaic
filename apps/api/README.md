# Mosaic API

Small Fastify/PostgreSQL foundation for identity, immutable Play revisions, and idempotent interaction events.

## Local

```bash
docker compose up -d postgres
cd apps/api
cp .env.example .env
npm install
npm run migrate
npm run seed
npm run dev
```

The process requires `DATABASE_URL`; secrets are supplied through environment/configuration management and are never committed.

## Migrations

Migrations are ordered `*.up.sql` / `*.down.sql` pairs and recorded in `schema_migrations`.

```bash
npm run migrate
npm run migrate:status
npm run migrate:down
```

Production migrations are forward-first. A migration that has reached production should normally be repaired by a new forward migration instead of editing the historical file. `down` exists for local/test rollback and emergency procedures whose data implications have been reviewed.

Every migration runs transactionally when PostgreSQL permits it. CI applies migrations to a clean database and exercises the event/idempotency integration test.

## API foundation

- `GET /health` — process liveness.
- `GET /ready` — PostgreSQL readiness.
- `POST /v1/actors` — idempotent anonymous actor creation.
- `POST /v1/actors/:actorId/bind-user` — bind anonymous history to a durable user.
- `POST /v1/events` — idempotent event ingestion keyed by `eventId`; server stores independent `received_at`.
- `POST /v1/plays/:playId/revisions/:revisionId` — immutable revision retrieval after client capability eligibility check.

The Play eligibility matcher mirrors `packages/play_schema` and `contracts/` from issue #18. Server and client must remain conformant through pinned fixtures.

## Scope boundary

This service intentionally does **not** include ranking, creator Studio, media transcoding, Redis, queues, payments, or a generic ORM. Add those only when a concrete milestone requires them.

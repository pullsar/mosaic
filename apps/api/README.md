# Mosaic API

Small Fastify/PostgreSQL foundation for identity, immutable Play revisions, idempotent interaction events, and asynchronous media processing.

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

The API process requires `DATABASE_URL`; secrets are supplied through environment/configuration management and are never committed.

## Migrations

Migrations are ordered `*.up.sql` / `*.down.sql` pairs and recorded in `schema_migrations`.

```bash
npm run migrate
npm run migrate:status
npm run migrate:down
```

Production migrations are forward-first. A migration that has reached production should normally be repaired by a new forward migration instead of editing the historical file. `down` exists for local/test rollback and emergency procedures whose data implications have been reviewed.

Every migration runs transactionally when PostgreSQL permits it. CI applies migrations to a clean database and exercises the event/idempotency and media integration suites.

## API foundation

- `GET /health` — process liveness.
- `GET /ready` — PostgreSQL readiness.
- `POST /v1/actors` — idempotent anonymous actor creation.
- `POST /v1/actors/:actorId/bind-user` — bind anonymous history to a durable user.
- `POST /v1/events` — idempotent event ingestion keyed by `eventId`; server stores independent `received_at`.
- `POST /v1/plays/:playId/revisions/:revisionId` — immutable revision retrieval after client capability eligibility check.

The Play eligibility matcher mirrors `packages/play_schema` and `contracts/` from issue #18. Server and client must remain conformant through pinned fixtures.

## Media worker

Media normalization is a separate executable and never runs inside Fastify request handling.

```bash
npm run build
npm run worker:media
```

`worker:media:local` remains an alias for local/development deployments. The worker consumes PostgreSQL leases atomically, materializes the immutable source, runs FFmpeg/FFprobe, publishes a claim-scoped immutable derivative, and only then marks the leased derivative ready.

### Local filesystem mode

`MEDIA_WORKER_STORAGE_MODE=local` is the default and requires explicit absolute roots:

```text
MEDIA_WORKER_SOURCE_ROOT
MEDIA_WORKER_WORK_ROOT
MEDIA_WORKER_OBJECT_ROOT
```

No storage root is derived from the current working directory.

### S3-compatible production mode

Set `MEDIA_WORKER_STORAGE_MODE=s3` and configure:

```text
MEDIA_WORKER_WORK_ROOT
MEDIA_S3_ENDPOINT
MEDIA_S3_BUCKET
MEDIA_S3_REGION
MEDIA_S3_ACCESS_KEY_ID
MEDIA_S3_SECRET_ACCESS_KEY
MEDIA_S3_SESSION_TOKEN        # optional
MEDIA_WORKER_STORAGE_TIMEOUT_MS
```

The S3 endpoint must be an HTTPS origin. The worker uses a narrow SigV4 S3 client with path-style object addressing so AWS S3 and compatible providers such as Cloudflare R2 can implement the same storage contract.

Derivative publication is create-only (`If-None-Match: *`). Exact retries are accepted only after HEAD metadata proves the existing object's size, MIME type, and Mosaic SHA-256 identity. Source downloads stream into the isolated attempt directory and are revalidated against the immutable database size, MIME type, and SHA-256 before FFmpeg sees them.

Remote storage requests are individually bounded. Startup also rejects S3 lease settings that cannot accommodate the configured FFmpeg timeout, the maximum storage request budget, FFprobe verification, and the claim-completion margin. A claim-wide deadline aborts slow I/O before the lease expires.

The worker never exposes raw source object keys for consumer delivery. Publication is separately gated on compatible managed derivatives; HEVC/HDR source media cannot become the only consumable video representation.

## Scope boundary

This service intentionally avoids ranking infrastructure, creator Studio, Redis/queue infrastructure without measured need, payments, and a generic ORM. Media processing is deliberately narrow: deterministic FFmpeg normalization, managed immutable storage, transcript/caption work, and compatibility-safe publication required by the launch media contract. Add broader infrastructure only when a concrete milestone requires it.

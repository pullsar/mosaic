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

## Media workers

Media processing never runs inside Fastify request handling. Normalization and transcription are independently scalable executables sharing the same PostgreSQL lease and immutable object-store contracts.

```bash
npm run build
npm run worker:media
npm run worker:transcript
```

The normalization worker claims only FFmpeg playback/poster/audio plans. The transcript worker claims only `speech-transcript-v1` caption plans. Both use PostgreSQL `FOR UPDATE ... SKIP LOCKED`, isolated attempt directories, claim-wide completion deadlines, current-source validation, claim-scoped immutable publication keys and stale-worker fencing.

### Storage

`MEDIA_WORKER_STORAGE_MODE=local` is the default and requires explicit absolute roots:

```text
MEDIA_WORKER_SOURCE_ROOT
MEDIA_WORKER_OBJECT_ROOT
```

Set `MEDIA_WORKER_STORAGE_MODE=s3` for S3-compatible production storage and configure:

```text
MEDIA_S3_ENDPOINT
MEDIA_S3_BUCKET
MEDIA_S3_REGION
MEDIA_S3_ACCESS_KEY_ID
MEDIA_S3_SECRET_ACCESS_KEY
MEDIA_S3_SESSION_TOKEN        # optional
MEDIA_WORKER_STORAGE_TIMEOUT_MS
```

The S3 endpoint must be an HTTPS origin. Publication is create-only (`If-None-Match: *`); exact retries are accepted only after HEAD metadata proves the existing object's size, MIME type and Mosaic SHA-256 identity. Source downloads are streamed and revalidated before a worker sees them. No storage root is derived from the current working directory.

### Normalization worker

Configure an explicit work root and bounded lease/process timing:

```text
MEDIA_WORKER_WORK_ROOT
MEDIA_WORKER_LEASE_MS
MEDIA_WORKER_TIMEOUT_MS
MEDIA_WORKER_IDLE_MS
MEDIA_FFMPEG_PATH             # optional
MEDIA_FFPROBE_PATH            # optional
```

Startup rejects lease settings that cannot accommodate configured processing/storage verification plus the claim-completion margin.

### Transcript worker

The transcript worker converts the verified immutable source to 16 kHz mono PCM WAV with FFmpeg, runs a deployment-provisioned `whisper-cli`, validates bounded UTF-8 WebVTT cues/timestamps, publishes the `.vtt` immutably, and then completes the exact PostgreSQL claim.

```text
MEDIA_TRANSCRIPT_WORK_ROOT
MEDIA_TRANSCRIPT_MODEL_PATH
MEDIA_TRANSCRIPT_LEASE_MS
MEDIA_TRANSCRIPT_PREPARE_TIMEOUT_MS
MEDIA_TRANSCRIPT_WHISPER_TIMEOUT_MS
MEDIA_TRANSCRIPT_IDLE_MS
MEDIA_TRANSCRIPT_MAX_VTT_BYTES
MEDIA_TRANSCRIPT_WHISPER_THREADS
MEDIA_TRANSCRIPT_WHISPER_PATH     # optional; defaults to whisper-cli
MEDIA_FFMPEG_PATH                 # optional
```

`MEDIA_TRANSCRIPT_MODEL_PATH` must be an absolute path to a non-empty model file already provisioned by deployment. Mosaic does not fetch or select models at runtime. Thread count is runtime tuning only and does not alter derivative identity. Transcript startup separately validates that local/S3 I/O plus audio preparation, inference and completion margin fit inside the configured transcript lease.

The workers never expose raw source object keys for consumer delivery. Publication is separately gated on compatible managed derivatives; HEVC/HDR source media cannot become the only consumable video representation, and a registered caption plan blocks publication until a valid WebVTT derivative is ready.

## Scope boundary

This service intentionally avoids ranking infrastructure, creator Studio, Redis/queue infrastructure without measured need, payments, and a generic ORM. Media processing is deliberately narrow: deterministic FFmpeg normalization, managed immutable storage, transcript/caption work, and compatibility-safe publication required by the launch media contract. Add broader infrastructure only when a concrete milestone requires it.

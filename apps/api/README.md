# Mosaic API

Small Fastify/PostgreSQL foundation for identity, immutable Play revisions, idempotent interaction events, an interpretable anonymous consumer feed, and asynchronous media processing.

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

Every migration runs transactionally when PostgreSQL permits it. CI applies migrations to a clean database and exercises identity/event, consumer-feed, and media integration suites, including ordered rollback/reapply coverage.

## API foundation

- `GET /health` — process liveness.
- `GET /ready` — PostgreSQL readiness.
- `POST /v1/actors` — idempotent anonymous actor creation.
- `POST /v1/actors/:actorId/bind-user` — bind anonymous history to a durable user.
- `POST /v1/events` — idempotent event ingestion keyed by `eventId`; server stores independent `received_at`.
- `POST /v1/plays/:playId/revisions/:revisionId` — immutable revision retrieval after client capability eligibility check.
- `GET /v1/topics?q=<query>&limit=<1..100>` — bounded topic search/catalog listing.
- `GET /v1/actors/:actorId/preferences` — read separate explicit interest and learning topic selections.
- `PUT /v1/actors/:actorId/preferences` — atomically replace explicit interest and learning selections.
- `POST /v1/feed` — create or continue a bounded capability-compatible feed decision.

The Play eligibility matcher mirrors `packages/play_schema` and `contracts/` from issue #18. Server and client must remain conformant through pinned fixtures. The same capability parser is used for direct revision retrieval and feed selection.

## Anonymous consumer feed

The first M2 feed is intentionally rules-based and inspectable. Interest and learning intent remain separate inputs; `More Like This` is a distinct affinity, one dismissal is weak evidence, repeated dismissal is progressively stronger, explicit topic mute excludes a candidate, and ranking does not optimize raw session duration.

Only revisions explicitly present in `feed_catalog_entries` with `state = 'eligible'` can enter the feed. Compatibility is checked before ranking, so a persisted decision never contains a Play the requesting client cannot render. Seed fixtures materialize their authored `topics` and `learningTopics` into role-specific revision links and receive deterministic curated ordering for development/test supply.

A new feed request accepts:

```json
{
  "actorId": "anonymous-actor-id",
  "capabilities": {
    "schemaVersions": [1],
    "presentationTypes": ["text", "image", "canvas"],
    "inputTypes": ["tap", "single_choice"],
    "validatorTypes": ["none", "equals"],
    "platformFlags": []
  },
  "limit": 8
}
```

`limit` defaults to 8 and is capped at 20. The server considers at most 200 eligible candidates by default, persists at most a 64-item decision window by default, and hard-caps windows at 100. The response includes a server-generated `requestId`, ranking config version, whether curated fallback was used, Play documents, and an opaque `nextCursor` when more of the same decision remains.

Feed decisions expire after 24 hours. Cursor reads are fenced to the original actor and a SHA-256 fingerprint of the canonical client capability set; an expired, malformed, cross-actor, or capability-mismatched cursor returns `invalid_feed_cursor`. Anonymous first-use is order-independent: preference or feed persistence creates the actor if `/v1/actors` delivery has not completed yet.

Stage-1 ranking persists each selected revision's source bucket, score, and named feature contributions for reproducibility/debugging. A small exploration guarantee substitutes one wildcard only when a wildcard exists and the selected multi-item window otherwise contains none; there is no permanent fixed bucket split. If the ranking implementation/configuration throws, the service logs the failure and degrades to compatible curated ordering rather than trapping the client. Database/candidate-source failure is not hidden because no trustworthy fallback inventory exists in that case.

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

The current consumer ranker is deliberately a small weighted rules baseline with persisted explainability, not learned ranking infrastructure. This service still avoids creator Studio, Redis/queue infrastructure without measured need, payments, a generic ORM, pgvector/semantic ranking, and opaque engagement optimization. Add broader infrastructure only when a concrete milestone and measured need justify it.

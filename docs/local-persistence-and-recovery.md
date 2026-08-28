# Mosaic — Local Persistence & Recovery

## Purpose

Mosaic treats process death, suspension and intermittent connectivity as normal mobile conditions.

Persist **semantic state**, not UI/native resources.

## Durable local state

The v1 local SQLite store owns:

- anonymous `actor_id`;
- selected interests;
- selected learning interests;
- bounded feed resume cursor/window metadata;
- creator draft JSON;
- local creator asset references and upload session/state;
- canonical outbound interaction events awaiting acknowledgement.

Do not persist:

- Flutter widget trees;
- video/audio controllers;
- timers/animation controllers;
- unbounded media caches;
- authentication secrets that belong in platform-secure storage.

## Event outbox

Every canonical event has a stable client-generated `eventId` before entering the local outbox.

```text
USER ACTION
   ↓
CREATE EVENT ID
   ↓
COMMIT LOCAL OUTBOX
   ↓
ASYNC DELIVERY
   ↓
SERVER INSERT OR DUPLICATE ACK
   ↓
DELETE LOCAL OUTBOX ITEM
```

The API stores an independent `received_at`; it does not reinterpret client observation time as server receipt time.

Retries are idempotent because `eventId` is stable end to end.

## Bounded failure behavior

The outbox has count, byte and age limits.

Under pressure:

1. expired low/normal-priority events are removed;
2. oldest low-priority analytics are removed first;
3. critical pending mutations are never automatically discarded merely to satisfy the spool cap.

If critical items alone exceed the configured cap, the store may temporarily exceed that cap rather than silently lose the user's pending action.

## Retry

Failed deliveries receive bounded exponential backoff. A successful or duplicate server acknowledgement removes the local item.

Network status is a hint only; delivery attempts determine actual reachability.

## Process restart

On launch/recovery:

- reuse the existing actor ID;
- reload interest and learning-interest selections independently;
- restore enough feed metadata for a useful continuation, not an exact widget tree;
- preserve creator drafts/local asset/upload session metadata;
- replay due outbox items.

Native media controllers are reconstructed from semantic state; they are never restored from SQLite.

## Corruption

If SQLite reports an unreadable/corrupt database during opening/migration:

- quarantine the unreadable file where possible;
- create a fresh schema;
- do not enter a launch crash loop.

The quarantine exists for debugging/manual recovery and should not be uploaded automatically.

A database created by a newer unsupported Mosaic schema is a different condition from corruption and must not be silently treated as ordinary data loss.

## Schema evolution

Local SQLite uses `PRAGMA user_version` with monotonic migrations.

Rules:

- migrations are tested against persisted fixtures;
- never persist Dart/Flutter object serialization that cannot be migrated independently;
- add columns/tables rather than reinterpret existing stored meaning where practical;
- migrations that can lose drafts or pending mutations require explicit recovery design.

## Current implementation

`packages/local_state` uses `sqlite3` directly behind `MosaicLocalStore`.

This avoids generated ORM/codegen complexity while the local model is small. Introduce Drift only when relational/query complexity demonstrably warrants it.

## Acceptance

A test must be able to:

1. create actor/preferences/feed state/draft/upload metadata/outbox;
2. close the process-owned database handle;
3. reopen from the same file;
4. recover the semantic state;
5. replay the exact event ID;
6. receive a server duplicate/success acknowledgement safely.

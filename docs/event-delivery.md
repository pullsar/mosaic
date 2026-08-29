# Client event delivery

Mosaic uses one client event path for interaction analytics and operational playback diagnostics:

```text
Telemetry
  -> MosaicEventEnvelope
  -> durable outbox
  -> POST /v1/events
```

Renderers do not know about HTTP, SQLite, IndexedDB, actor registration, or retry policy.

## Runtime configuration

Production event delivery is enabled at Flutter build/run time with an HTTPS API base URL:

```text
--dart-define=MOSAIC_API_BASE_URL=https://api.example.com/
```

The runtime resolves `v1/actors` and `v1/events` relative to that base URL. Production URLs must use HTTPS.

Local development may opt into plain HTTP only for loopback hosts:

```text
--dart-define=MOSAIC_API_BASE_URL=http://localhost:3000/
--dart-define=MOSAIC_ALLOW_INSECURE_LOCAL_API=true
```

Do not enable the insecure-local flag for production builds.

If `MOSAIC_API_BASE_URL` is absent, the client keeps events in its bounded durable outbox and performs no outbound event requests. Invalid transport configuration also degrades to queue-only behavior and cannot block Play rendering or media lifecycle operations.

## Persistence

Native clients reuse the existing `MosaicLocalStore` SQLite database and its `event_outbox`; no second native queue is created. The anonymous actor ID is persisted in the same local store.

Web clients use IndexedDB database `mosaic_event_runtime`. Event records and anonymous actor identity survive page reload/browser restart. `localStorage` is not used for the event outbox.

Default outbox policy:

- maximum 1,000 queued events;
- maximum 1 MiB of queued event payloads;
- non-critical event maximum age of 14 days;
- exponential retry backoff capped at 1 hour;
- critical events are not evicted solely to satisfy count/byte pressure.

Storage failure degrades telemetry only. It must not prevent the app or a Play from starting.

## Delivery semantics

Each event receives a client-generated UUID before asynchronous context resolution. That `eventId` remains unchanged across retries.

Before sending an event for an anonymous actor, the transport idempotently registers that actor with `POST /v1/actors`. Successful actor registration is cached for the process.

For `POST /v1/events`:

- HTTP 202 (`inserted`) is success;
- HTTP 200 (`duplicate`) is also success and removes the exact queued event;
- HTTP 408, 425, 429, and 5xx responses are retryable;
- other non-success 4xx responses are treated as permanent rejection and the invalid event is discarded;
- request timeouts and transport failures are retryable.

Drain calls are coalesced and events are delivered serially. One retryable failure stops the current drain so an outage cannot fan out into a burst of doomed requests.

The app requests a drain at startup, after a durable enqueue succeeds, and on app resume. Draining is never awaited by renderer or media lifecycle transitions.

## Playback diagnostics privacy

`media_playback` records only compatibility-oriented first-frame/error dimensions such as selected container/codec/profile, source type, elapsed first-frame time, and coarse runtime/OS/browser family.

The client event path must not persist or send raw user-agent strings, playback exception messages, device fingerprint material, advertising identifiers, or client-derived IP/location data.

## Validation

Repository CI covers the shared runtime, HTTP classification, native SQLite reuse, stable event IDs, and offline -> reopen -> online drain. Platform CI runs the IndexedDB durability suite in Chrome and keeps web, Android release, and iOS simulator builds as merge gates. API CI verifies exact event retry remains idempotent in PostgreSQL.

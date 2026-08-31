# M2-A consumer runtime implementation plan

Issue: #49  
Branch: `agent/m2-flutter-consumer-loop-20260829`  
Base: merged anonymous actor ownership foundation `752d4bdc1bf339dd51618aaa581816f729fc4492`

## Objective

Build the cross-platform client/runtime boundary that later M2 onboarding, feed and search UI consume without putting HTTP, SQLite or IndexedDB behavior in widgets.

This PR is intentionally limited to #49. It must not add the onboarding screens, full-screen feed pager, consumer controls, signal projector or search UI tracked by #50–#54.

## Existing seams to reuse

- `ActorAccessIdentity`, `actorAuthorizationHeaders`, `secureActorAccessToken` and the actor registration wire contract are merged through #57/PR #59.
- `AppEventResources` already owns the anonymous actor credential, event outbox and platform-specific resource lifecycle.
- Native resources already open one `MosaicLocalStore` database at `mosaic_local_state.sqlite3`.
- Web resources already open one `IndexedDbEventStore` database named `mosaic_event_runtime`.
- `MosaicLocalStore` already contains separate interest/learning preference and feed-resume primitives from #14.
- `IndexedDbEventStore` already owns one metadata object store, actor credential state and one serialized write tail.
- `HttpEventTransport` already defines the approved HTTPS/explicit-localhost policy, bounded timeout style and retryable HTTP classes.
- PR #47 provides the production topic/preferences/feed API contracts and opaque feed cursors.
- `PlayCapabilityEnvelope` and `PlayCompatibilityChecker` already provide the client-side capability/decode gate.

## Architecture

### 1. Shared HTTP/actor-access policy

Do not duplicate security-sensitive transport policy between event delivery and the consumer client.

Extract or expose the smallest reusable helpers needed for:

- API base-URI validation/normalization;
- retryable status classification (`408`, `425`, `429`, `5xx`);
- actor Authorization headers;
- idempotent `POST /v1/actors` registration result classification.

Actor registration must not depend on telemetry having emitted an event. A fresh client with an empty outbox still has to register its actor before the first private preferences/feed call.

Registration semantics remain:

- `200` / `201`: accepted/idempotent;
- `409 actor_rotation_required`: identity recovery required;
- `401` / `403`: credential rejected;
- timeout / `408` / `425` / `429` / `5xx`: retryable;
- malformed/unexpected response: fail closed.

No actor secret may enter URLs, logs, Play documents, cursors or analytics payloads.

### 2. Typed consumer API client

Add an app/runtime client with strongly typed models for:

- topic summary;
- interest + learning preferences;
- feed item;
- feed page (`requestId`, ranking config version, fallback flag, opaque next cursor);
- bounded API failure classification.

Rules:

- production endpoint must be HTTPS; localhost HTTP is allowed only through the same explicit debug rule used by event delivery;
- request timeout is bounded and positive;
- JSON parsing is strict and fail closed;
- feed cursor is opaque and passed through unchanged;
- capabilities are emitted from the existing `PlayCapabilityEnvelope`;
- each feed `document` is decoded through `PlayCompatibilityChecker` before exposure;
- decoded `PlayDocument.id` must equal the feed envelope `playId`;
- decoded `PlayDocument.revisionId` must equal the feed envelope `revisionId`;
- invalid, unsupported or ID-mismatched content is rejected before cache or rendering;
- `401`/`403` and registration `409` are identity failures, not retry loops;
- `invalid_feed_cursor` is a distinct recoverable feed condition.

Use the existing approved `http` package. If the app imports it directly, declare it directly in the app pubspec rather than relying on a transitive dependency.

### 3. App-level consumer local-state contract

Define a narrow `ConsumerLocalState` abstraction with only the state M2 needs:

- `readPreferences()` / `writePreferences()`;
- `readFeedResume()` / `writeFeedResume()` / `clearFeedResume()`;
- `readRecentFeed()` / `writeRecentFeed()` / `clearRecentFeed()`.

Feed resume must preserve enough identity for deterministic recovery:

- feed request ID;
- opaque next cursor;
- last visible Play revision ID;
- last visible position;
- update timestamp.

The recent feed is one bounded recovery window, not a content database. Store only locally validated Play JSON plus feed request/revision identity. Enforce count, encoded-byte and age bounds and re-run the current capability/decode gate when reading it after restart/upgrade.

The contract must not own actor identity, analytics, networking or Play controllers.

### 4. Native adapter

Extend the existing app resource composition so the same already-open `MosaicLocalStore` backs both:

- `SqliteEventOutbox`;
- the native `ConsumerLocalState` adapter.

Use a targeted schema migration only for state the current local schema does not contain: request/visible-position resume fields and bounded validated Play cache storage.

Do not open a second SQLite connection/database for consumer state. The app resource owner closes the underlying database exactly once.

### 5. Web adapter

Do not create a second IndexedDB database or second owner for `mosaic_event_runtime`.

Expose a narrowly namespaced consumer-metadata surface from `IndexedDbEventStore`:

- only keys in the `consumer.*` namespace are accepted;
- reserved actor/access/binding keys cannot be addressed through this surface;
- writes participate in the existing serialized IndexedDB write tail;
- consumer writes cannot corrupt/clear actor identity or event outbox records;
- corrupt consumer metadata fails closed to empty/new state;
- no `localStorage` fallback;
- no IndexedDB version bump/object-store creation unless a concrete storage limitation is demonstrated.

Expected records are versioned JSON values such as:

- `consumer.preferences.v1`;
- `consumer.feed_resume.v1`;
- `consumer.recent_feed.v1`.

### 6. Resource composition

Evolve the existing resource bundle rather than introduce another top-level lifecycle owner.

Conceptually:

```text
App runtime resources
├── ActorAccessIdentity
├── EventOutbox
├── ConsumerLocalState
└── close()
```

Native and web factories create these from one underlying platform persistence owner. Close remains idempotent and closes the underlying store exactly once.

### 7. Immutable per-Play telemetry scope

The current demo runtime has one fixed `playRevisionId`. A real feed cannot mutate one global “current Play” context because delayed media callbacks can arrive after a swipe.

Refactor `AppEventRuntime` so it owns only stable session resources and can create lightweight telemetry handles scoped to fixed:

- `feedRequestId`;
- `playRevisionId`.

Every scope shares the same actor, session ID, outbox and drain controller. Creating or discarding a scope must not create/close a transport, session or persistence owner.

A delayed callback from Play A after Play B becomes visible must still enqueue an event carrying A’s request/revision IDs.

### 8. Consumer orchestration/failure behavior

Keep orchestration outside widgets.

- local preference writes happen before remote replacement;
- remote sync failure does not roll back local intent;
- actor registration is ensured before private calls;
- retryable remote failure exposes retry state but does not block local consumption;
- feed request failure may expose the bounded revalidated recovery window;
- `invalid_feed_cursor` clears only resume state and retries a fresh feed at most once;
- actor credential rejection/rotation-required is surfaced as identity recovery required and never retried forever;
- no background polling loop is introduced;
- no duplicate analytics/event queue is introduced.

## Planned implementation order

1. Shared API base-URI/status/actor-registration helpers with event transport regression coverage.
2. Pure typed consumer DTOs + strict JSON/Play-envelope validation tests.
3. Consumer API client + fake HTTP/timeout/registration/error/cursor tests.
4. `ConsumerLocalState` contract and native `MosaicLocalStore` migration/adapter.
5. Consumer-namespaced serialized metadata surface on `IndexedDbEventStore` + stub parity.
6. Web consumer-state adapter using the existing metadata store/connection.
7. Extend app resource factories to expose one consumer-state instance from the already-open platform store.
8. Refactor `AppEventRuntime` to immutable per-Play telemetry scopes.
9. Real Chrome reopen/corruption/isolation tests and app-level one-owner tests.
10. Exact-head repository/platform/local-recovery CI and PR review cleanup.

## Test matrix

### Pure Dart / VM

- DTO validation rejects missing/wrong types, unknown source buckets and malformed values;
- cursor is never decoded/re-encoded by the client;
- first private request registers actor even with zero queued telemetry;
- exact actor registration retry succeeds;
- timeout/retryable/identity/invalid-cursor classifications are deterministic;
- unsupported/malformed Play documents never reach the consumer model;
- feed envelope/document ID mismatch is rejected.

### Native

- same SQLite file/connection backs existing local state + event outbox + consumer adapter;
- interest/learning/feed resume/recent validated window survive close/reopen;
- count/byte/age bounds are enforced;
- cached Plays are revalidated on read;
- clearing consumer resume/cache does not clear actor/event data;
- no second database file/connection is created.

### Web / Chrome

- preferences/feed resume/recent window survive close/reopen;
- writes use the existing `mosaic_event_runtime` metadata store;
- consumer API rejects non-`consumer.*` metadata keys;
- actor identity/credential remain stable;
- event records remain intact;
- corrupt consumer JSON fails closed without deleting actor/outbox data;
- concurrent consumer/event writes remain serialized and complete.

### App integration

- one actor credential/outbox/consumer state resource bundle owns one close path;
- no networking is initiated by storage constructors;
- two Play telemetry scopes share one session/outbox;
- delayed callback from A after B exists still carries A’s request/revision context;
- no onboarding/feed widgets are introduced in this PR.

## Non-goals

- visual onboarding (#50);
- vertical feed pager/prefetch (#51);
- Save/More Like This/Not interested/mute/report (#52);
- interaction profile projector (#53);
- Play search (#54);
- account authentication/deletion (#58);
- learned ranking/pgvector (#11);
- a generic app-wide key-value database abstraction;
- a second web persistence implementation.

## Merge gate

Before this PR can leave draft:

- all #49 acceptance items are implemented;
- formatting and whole-workspace analysis pass;
- `local_state`, `event_delivery`, consumer runtime/state tests pass;
- real Chrome IndexedDB tests pass through the existing platform workflow;
- app-shell tests pass;
- local-recovery PR gate passes;
- the server-gated web release build passes, and manually requested or published-release Android/iOS validation passes when a mobile artifact is required;
- review threads are clean;
- final diff contains only #49 runtime/persistence/API work plus this plan.

After merge, #50 starts from the exact #49 merge SHA on a fresh branch.

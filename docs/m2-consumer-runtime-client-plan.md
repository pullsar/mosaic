# M2-A consumer runtime implementation plan

Issue: #49  
Branch: `agent/m2-flutter-consumer-loop-20260829`  
Base: merged M2 server foundation `bdfa4915bc1d09d6ce8aa019f34fc0d3957b3782`

## Objective

Build the cross-platform client/runtime boundary that later M2 onboarding, feed and search UI consume without putting HTTP, SQLite or IndexedDB behavior in widgets.

This PR is intentionally limited to #49. It must not add the onboarding screens, full-screen feed pager, consumer controls, signal projector or search UI tracked by #50–#54.

## Existing seams to reuse

- `AppEventResources` already owns the anonymous actor ID, event outbox and platform-specific resource lifecycle.
- Native resources already open one `MosaicLocalStore` database at `mosaic_local_state.sqlite3`.
- Web resources already open one `IndexedDbEventStore` database named `mosaic_event_runtime`.
- `MosaicLocalStore` already contains separate interest/learning preference and feed-resume primitives from #14.
- `IndexedDbEventStore` already owns one metadata object store, one actor identity and one serialized write tail.
- `event_delivery` already uses the approved `http` package and enforces the HTTPS/local-debug transport policy.
- PR #47 provides the production topic/preferences/feed API contracts and opaque feed cursors.

## Architecture

### 1. Typed consumer API client

Add an app/runtime client with strongly typed models for:

- topic summary;
- interest + learning preferences;
- feed item;
- feed page (`requestId`, ranking config version, fallback flag, opaque next cursor);
- bounded API failure classification.

Rules:

- production endpoint must be HTTPS; localhost HTTP is allowed only through the same explicit debug rule used by event delivery;
- request timeout is bounded;
- JSON parsing is strict and fail closed;
- feed cursor is opaque and passed through byte-for-byte;
- server Play documents are validated through `play_schema` before being exposed to future UI;
- invalid/unsupported server content is rejected/skipped safely and never enters `PlaySurface`.

Prefer reusing the existing workspace `http` dependency rather than adding another networking library.

### 2. App-level consumer local-state contract

Define a narrow `ConsumerLocalState` abstraction with only the state M2 needs:

- `readPreferences()` / `writePreferences()`;
- `readFeedResume()` / `writeFeedResume()` / `clearFeedResume()`;
- optional onboarding-completion marker only if needed by #50.

The contract must not own actor identity, analytics, networking or Play controllers.

### 3. Native adapter

Extend the existing app resource composition so the same already-open `MosaicLocalStore` backs both:

- `SqliteEventOutbox`;
- the native `ConsumerLocalState` adapter.

Do not open a second SQLite connection/database for consumer state. The app resource owner closes the underlying database exactly once.

### 4. Web adapter

Do not create a second IndexedDB database or second owner for `mosaic_event_runtime`.

Expose the smallest safe metadata-string surface from `IndexedDbEventStore` needed by the app adapter, or an equivalent narrowly scoped metadata interface. The web `ConsumerLocalState` adapter stores namespaced JSON records such as:

- `consumer.preferences.v1`;
- `consumer.feed_resume.v1`;
- optional `consumer.onboarding.v1`.

Requirements:

- writes participate in the existing serialized IndexedDB write tail;
- consumer writes cannot corrupt/clear actor identity or event outbox records;
- corrupt consumer metadata fails closed to empty/new state;
- no `localStorage` fallback for durable M2 state;
- no IndexedDB version bump/object-store creation unless a concrete storage limitation is demonstrated.

### 5. Resource composition

Evolve the app resource bundle rather than introduce another top-level lifecycle owner.

Conceptually:

```text
App runtime resources
├── actorId
├── EventOutbox
├── ConsumerLocalState
└── close()
```

Native and web factories create these from one underlying platform persistence owner.

### 6. Sync behavior

Local preference state is authoritative for immediate UX continuity; the server remains authoritative for feed ranking state.

- local preference write happens before remote replacement;
- remote sync failure does not roll back local intent;
- retry can occur on next explicit save/foreground/network opportunity;
- stale/expired `invalid_feed_cursor` clears only feed resume and starts a fresh decision;
- no background polling loop is introduced in this tranche;
- no duplicate analytics/event queue is introduced.

## Planned implementation order

1. Pure typed consumer DTOs + JSON validation tests.
2. Consumer API client + fake transport/timeout/error tests.
3. `ConsumerLocalState` contract and native `MosaicLocalStore` adapter.
4. Minimal serialized metadata surface on `IndexedDbEventStore` + stub parity.
5. Web consumer-state adapter using existing metadata store.
6. Extend app resource factories to expose one consumer-state instance from the already-open platform store.
7. Real Chrome reopen/corruption/isolation tests.
8. App-level integration tests proving actor/outbox/consumer state share one lifecycle owner.
9. Exact-head repository/platform CI and PR review cleanup.

## Test matrix

### Pure Dart / VM

- DTO validation rejects missing/wrong types and oversized/invalid values;
- cursor is never decoded/re-encoded by the client;
- local preference interest/learning arrays remain distinct;
- API timeout/non-success/error classification is deterministic;
- invalid Play documents never reach the consumer model.

### Native

- same SQLite file/connection backs existing local state + event outbox + consumer adapter;
- interest/learning/feed resume survive close/reopen;
- clearing feed resume does not clear actor/event data;
- no second database file/connection is created.

### Web / Chrome

- preferences/feed resume survive close/reopen;
- writes use the existing `mosaic_event_runtime` metadata store;
- actor identity remains stable;
- event records remain intact;
- corrupt consumer JSON fails closed without deleting actor/outbox data;
- concurrent consumer/event writes remain serialized and complete.

### App integration

- disabled persistence degrades telemetry/consumer state without blocking app startup;
- one resource close path is idempotent;
- no networking is initiated by storage constructors;
- no onboarding/feed widgets are introduced in this PR.

## Non-goals

- visual onboarding (#50);
- vertical feed pager/prefetch (#51);
- Save/More Like This/Not interested/mute/report (#52);
- interaction profile projector (#53);
- Play search (#54);
- learned ranking/pgvector (#11);
- a generic app-wide key-value database abstraction;
- a second web persistence implementation.

## Merge gate

Before this PR can leave draft:

- all #49 acceptance items are implemented;
- formatting and whole-workspace analysis pass;
- `local_state`, `event_delivery`, new consumer runtime/state tests pass;
- real Chrome IndexedDB tests pass;
- app-shell tests pass;
- web/Android/iOS release builds pass when touched paths trigger platform CI;
- review threads are clean;
- final diff contains only #49 runtime/persistence/API work plus this plan.

After merge, #50 starts from the exact #49 merge SHA on a fresh branch.
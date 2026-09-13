# Replay, Saved, and sharing implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Use `subagent-driven-development` only when the user selects delegated execution. Steps use checkbox syntax for tracking.

**Goal:** Make favorite games replayable, discoverable through Saved and family pins, and playable by a friend from a stable link.

**Architecture:** A bounded app attempt controller wraps the deterministic engine; exact published revisions remain unchanged. Extend existing consumer state, canonical event delivery, revision retrieval, and the shared Play composition rather than building a second save queue, player, or share renderer.

**Tech Stack:** Flutter/Dart, existing SQLite and IndexedDB stores, canonical analytics/event delivery, TypeScript/Fastify/PostgreSQL.

---

## Dependencies and product semantics

Read [the program plan](2026-09-10-replayable-games.md), `docs/growth-and-sharing-spec.md`, `docs/local-persistence-and-recovery.md`, `docs/event-delivery.md`, and the owning issues #5, #17, #55, #58. R1–R2 follow catalog repair. R3–R5 need A1 family metadata. R6–R7 need stable round/presentation and working Saved; new primitive links also need matching capability support.

`Replay` means the same immutable task and frozen presentation with a new attempt. `Another round` means another approved published Play in the same family. `Save` bookmarks an exact revision under the existing logical Play identity; `Pin game` puts a family among at most six ordered shortcuts. Saving must not send More Like This. Sharing must not require signup. No automatic conversion sheet interrupts the first solve, replay, save, or recipient attempt.

The existing saved table has one row per actor/play, with a selected revision. Keep this contract: saving a newer revision of the same Play updates that bookmark. Distinct generated rounds receive distinct play IDs; do not overload revision IDs to simulate new rounds. The six family pins are separate from saved puzzle bookmarks.

## File ownership

| Action | Paths | Responsibility |
| --- | --- | --- |
| Create | `apps/mosaic_app/lib/game_attempt_controller.dart`, `test/game_attempt_controller_test.dart` | Attempt identity, bounded recovery and replay lifecycle |
| Modify | `packages/play_engine/lib/play_engine.dart`, `test/play_engine_test.dart` | Explicit pure restoration from validated state/action history only if required |
| Modify | `packages/play_flutter/lib/src/play_surface.dart`, `test/play_surface_reuse_test.dart` | Terminal semantics and reset by attempt identity |
| Modify | `apps/mosaic_app/lib/main.dart`, `guest_home.dart`, `guest_engagement.dart`, `play_resolution_telemetry.dart` | Shared composition and navigation ownership |
| Modify | `apps/mosaic_app/test/guest_home_test.dart`, `guest_engagement_test.dart`, `play_resolution_telemetry_test.dart` | Terminal/replay/guest regression |
| Create | `apps/mosaic_app/lib/saved_games.dart`, `test/saved_games_test.dart` | Saved projection controller and compact library composition |
| Create | `apps/mosaic_app/lib/game_family_rounds.dart`, `test/game_family_rounds_test.dart` | Bounded next-round selection and pins |
| Modify | `apps/mosaic_app/lib/consumer_action_controller.dart`, `consumer_action_controls.dart`, `consumer_api_client.dart`, `consumer_local_state.dart`, `consumer_local_state_native.dart`, `consumer_local_state_web.dart` | Existing mutation/delivery/read boundaries |
| Modify | `apps/mosaic_app/test/consumer_action_controller_test.dart`, `consumer_local_state_native_test.dart`, `consumer_local_state_web_test.dart` | Offline and reconciliation evidence |
| Modify | `packages/analytics_contract/lib/analytics_contract.dart`, `packages/event_delivery/lib/src/event_delivery_core.dart`, `sqlite_event_outbox.dart`, `indexed_db_event_store.dart` | Attempt fields and transactional mutation receipts in existing delivery |
| Modify | `packages/local_state/lib/local_state.dart` | Native atomic event/derived-state transaction and bounded enumeration |
| Modify | `apps/api/src/app.ts`, `repository.ts`, `consumer_repository.ts`, `consumer_actions.ts` | Saved reads, availability policy, pin projection, revision retrieval |
| Create | `apps/api/src/saved_games.ts`, `apps/api/test/saved_games.test.ts`, `apps/api/test/saved_games_postgres.test.ts` | Bounded queries and reconciliation contract |
| Create | `apps/api/migrations/011_game_collection.up.sql`, `011_game_collection.down.sql` | Pin projection and query/receipt indexes |
| Create | `apps/mosaic_app/lib/play_share.dart`, `test/play_share_test.dart` | Share action and route parsing |
| Create | `apps/api/src/play_share.ts`, `test/play_share.test.ts` | Public preview/link descriptors and revision availability |
| Create | `apps/api/src/play_challenge.ts`, `test/play_challenge.test.ts`, `test/play_challenge_postgres.test.ts` | Challenge state, authorization, hidden reveal |
| Create | `apps/api/migrations/012_play_challenge.up.sql`, `012_play_challenge.down.sql` | Challenge/participant/reveal state |
| Modify | `docs/growth-and-sharing-spec.md`, `docs/local-persistence-and-recovery.md`, `docs/recommendation-and-analytics-spec.md` | Behavioral and event contracts |

R3 and R7 extend existing package test suites as well as the new files; do not test persistence through in-memory doubles alone. Migration IDs follow A1 and must be reconciled against main before first application.

## R1: Give each run its own attempt and bounded recovery

- [ ] Add tests that replaying identical Play bytes creates a distinct attempt, engine state starts fresh, saved/theme identities remain unchanged, and a callback from attempt A cannot mutate B. Use an injected ID source in tests; production generates a random attempt identifier at the app boundary.
- [ ] Run `cd apps/mosaic_app && flutter test test/game_attempt_controller_test.dart`; expect the missing controller/identity assertions to fail.
- [ ] Implement the controller around `PlayEngine.start/apply`, keeping all input and validation deterministic. It owns the attempt ID, mode (`first`, `practice`, `challenge`), recorded actions, completed flag, resolved presentation, and active lease generation. The engine's transition-counting `attempts` field retains its current meaning.

Move session authority out of `_PlaySurfaceState` for app-owned attempts: add a controlled constructor accepting a `PlaySession` and `ValueChanged<PlayAction>`, with rendering delegated to the same internal composition. The controller applies actions and publishes the resulting session; the controlled surface never calls a second engine. Keep the existing constructor for isolated legacy consumers, with exactly one active session owner per instance. Do not import an app controller into play_flutter. Test benign parent rebuild preserves state in both modes and changing between ownership modes requires a new widget identity.

```dart
final class AttemptLease {
  int _generation = 0;
  int get generation => _generation;
  int invalidate() => ++_generation;
  bool accepts(int captured) => captured == _generation;
}
```

Every asynchronous load/media/result callback checks the captured lease plus exact attempt ID before changing presentation. Invalidation precedes release/reset. Scope widget keys and media ownership to play/revision/attempt, not just revision.
- [ ] Store at most one in-progress attempt recovery snapshot, at most 128 accepted actions and 64 KiB serialized data. Snapshot fields include play/revision/hash, capability version, attempt ID, mode, frozen presentation, and canonical action payloads. Validate the entire snapshot before replaying actions into the pure engine; never restore arbitrary state IDs without checking reachability. Missing revision, unsupported capabilities, corrupt actions, or excessive size discard only that snapshot, preserving healthy saved/user data.
- [ ] For current untimed puzzles, reload the exact locally available revision and rebuild state from actions. Timed/exposure games cannot restore a ranked attempt after an interruption; G4 marks it practice and restarts the cue on request. Never persist live controllers, clocks, sound authorization, or media handles.
- [ ] Test crash before/after snapshot write, truncated JSON, valid snapshot with another revision hash, action limit, and recovery with no network. Run app attempt tests and engine tests; commit with `feat: scope game runs to recoverable attempts`.

## R2: Make completion useful and replay explicit

- [ ] Add a widget test that the final Done input ceases to be actionable when `session.ended` is true. Assert `Replay` starts a new attempt; its first action is accepted; vertical swipe/back remains available before/after wrong answer and reveal.
- [ ] Run play_surface reuse and app guest/telemetry tests; expect the terminal input assertion to fail against the current rendered enabled control.
- [ ] Render terminal affordances from explicit app session state: keep the solved object dominant, replace inert task controls with `Replay`, and add contextual `Another round` only when an approved family round exists. Save and Share stay quiet utilities. Preserve the final reveal's single useful fact rather than adding a results dashboard.

```text
playing + correct -> reveal (task-defined)
reveal + done     -> ended (old task input disabled)
ended + replay    -> invalidate old lease; stop media; new attempt; entry state
ended + another   -> prepare approved next round; new attempt after readiness
any + swipe/back  -> release active input/media; navigate immediately
```

- [ ] Extend existing resolution telemetry with attempt ID and mode. Emit one completion per attempt through the existing durable event path with a stable event ID prepared once; UI rebuilds, delivery retries, and restored completed snapshots reuse it. Do not suppress the later attempt's event. Keep wrong-answer count separate from transition count, and do not count theme changes as attempts.
- [ ] Remove guest conversion triggers from these core actions; preserve an intentional account action and its currently supported behavior. Do not pretend unfinished account functionality is available.
- [ ] Verify terminal, replay, wrong-answer exit, duplicate callbacks, and stale sound events. Run the full affected widget suites and analytics contract tests; commit with `feat: add explicit replay and terminal actions`.

## R3: Build a crash-safe Saved read model on the existing outbox

- [ ] Add API tests for proof-of-possession authentication, exact saved revision retrieval, keyset pagination, unsave tombstones, unavailable historical content, and a retried event remaining a single mutation. Public `actorId` alone cannot authorize collection reads.
- [ ] Add a bounded Saved query in existing consumer repository, page size 24/max 48, stable order `(updated_at, play_id)` with an opaque validated cursor. A cursor carries a query cutoff; if the projection changes and a page is incomplete, clients restart the snapshot instead of claiming a complete immutable listing. Item responses include revision identity, availability, source event ID, and authoritative update version. A separate bounded status lookup for up to 48 pending play IDs returns tombstones too.

Migration 011 adds a per-actor collection revision incremented transactionally with an actual Saved/pin projection change. The first page returns this revision; subsequent pages require it, and mismatch returns `collection_changed`. Restart the background query with stable visible keys. Duplicate canonical events do not increment the revision. This supplies a concrete consistency check rather than inferring a snapshot from timestamps alone.
- [ ] Reuse existing `POST /v1/plays/:playId/revisions/:revisionId` for playable document retrieval. Add publication/moderation availability checks at the repository boundary: historical/feed-ineligible does not automatically mean withdrawn; unsafe/rights-revoked is unavailable. Apply the same policy to Saved, shares, and direct revision access.
- [ ] Preserve the round's resolved decorative presentation on Save as well as its revision. Add an optional validated presentation reference to local action state and the saved projection; a version-2 save event carries that reference, while version-1 events retain their exact existing interpretation and fall back to the document's presentation. Update analytics/server event validation together. A saved item reopens its stored presentation subject to mute/accessibility and revoked-decoration fallback, rather than rerolling on every visit. Do not persist sound authorization or task answers in this field.
- [ ] Add native and real IndexedDB tests for the following crash windows before implementing local collection projection:

```text
mutation prepared -> crash before atomic enqueue: no optimistic saved claim
event + local overlay committed -> crash before send: overlay survives
server accepted -> response lost: retry identical event; one server projection
ack received -> crash during local receipt/delete: transaction all-or-nothing
old list response -> newer unsave pending: unsave remains visible
save A -> unsave B -> save C: old A/B receipt never clears C overlay
outbox capacity reached: no silent eviction of user collection mutations
```

The native event outbox and consumer state already share `MosaicLocalStore`; web events and metadata share one IndexedDB database. Extend those transactions, rather than adding a queue: enqueue the canonical event and its local projection atomically; on delivery atomically record the acknowledged event ID and delete that event. Extend IndexedDB transactions across the existing events/metadata stores. A received acknowledgment is persisted before a pending overlay is considered reconciled.
- [ ] Protect canonical collection mutations from generic telemetry eviction/expiry. Bound undelivered collection mutations at 500; at capacity, reject the new mutation visibly and preserve existing data/retry. Do not show a successful Save that exists only in volatile UI state. Consolidate derived metadata only after acknowledgment, never by replacing the canonical bytes of a queued event.

Within the existing outbox, preserve enqueue sequence for each collection key (`saved:{playId}` or `pins`): a backed-off earlier mutation blocks later mutations for that key until delivered or explicitly rejected. Other keys and ordinary telemetry can progress. This prevents delayed Save A arriving after Unsave B and becoming the latest server receipt. Persist the ordering key/sequence with the canonical queued record, and test transport retry/restart with A→B→C. This is an extension of one delivery path, not a second queue or reliance on client wall-clock timestamps.
- [ ] Cache at most 500 synchronized Saved metadata entries in paged/indexed records, keeping pending mutations and six pins outside evictable read-cache entries. Use the existing bounded document/media caches for playable content; metadata survives media eviction. Do not put the whole collection into one 256 KiB IndexedDB metadata value. Additional online saves remain server-paginated; this is a bounded local cache, not a total collection limit.
- [ ] Merge responses with exact-event-aware overlays: pending local value wins; receipt A cannot clear newer pending C; clear a received overlay only when server status confirms that event or a later authoritative projection. Failed permission/withdrawal states render a specific recovery state, not a silently removed bookmark. For the current anonymous actor, retain authoritative server receipt ordering; cross-device account conflict policy belongs to #58 and must not be fabricated with client wall clocks.
- [ ] Run local_state/event_delivery/analytics tests, Chrome event tests, both app local-state tests, and API tests including PostgreSQL. Commit the storage/read boundary independently with `feat: reconcile Saved through durable event receipts`.

## R4: Compose Saved and retrieve exact rounds

- [ ] Add widget tests for populated, empty, offline, media-evicted, unsupported, withdrawn and failed-load collections. Selecting an item must open the shared Play composition and retain a predictable back path to the collection scroll position.
- [ ] Implement the existing Saved navigation destination. Use a compact thumbnail grid with family name, minimal availability indicators, and contextual unsave. Pinned families occupy one quiet row. Copy examples: `Saved`, `No saved games`, `Offline`, `Retry`, `Unavailable`. Do not append instructions describing where items live.
- [ ] Start from cached metadata, reconcile in the background, and preserve stable visible item keys/position. Route a selected revision through the same capability checker, document retrieval, media resolver, attempt controller and `PlaySurface` as feed/preview. Locally retained complete content plays offline; unavailable assets show compact retry with back/swipe available.
- [ ] Use explicit two-step selection only for destructive bulk actions if those are separately requested; this tranche has individual reversible unsave with `Undo`. Undo enqueues a new canonical save, not cancellation of an event already sent.
- [ ] Run Saved, action-controller, guest-home and composition tests at small/large screens, keyboard navigation, large text and screen-reader order. Commit with `feat: render playable Saved collections`.

## R5: Add fresh family rounds and six ordered pins

- [ ] Add deterministic next-round tests: same family/capabilities only; exclude current and last twenty round IDs where supply permits; prefer a new round; exhausted supply yields explicit replay availability; revoked assets cannot be prefetched as eligible. Never label an identical replay a new round.
- [ ] Add a family-round API/read contract backed by A1 manifests. Fetch at most one prepared next round and debit it from the existing feed warm budget; cancel/fence work on family change. A family with no compatible ready content stays operable through replay; user preference changes do not trigger generation on the interaction path.
- [ ] Add versioned `game_pins_changed` canonical event with a complete ordered list of zero to six distinct family IDs. Server validates families and projects using existing receipt-order conventions. The entire six-item list is one mutation; reorder cannot partially apply. Persist optimistic order and receipts through R3's existing transactional path.

```json
{"familyIds":["quiet-switch","one-move","echo-architect"]}
```

- [ ] Implement `Pin game`/`Unpin game` and reorder via pointer plus accessible `Move earlier`/`Move later` actions. At six pins, selecting a seventh opens a concise replacement choice; never silently drop an existing favorite. Pins are deliberate shortcuts, not recommendation votes.
- [ ] Test offline pin/reorder/restart, duplicate IDs, seven-item rejection, older response after newer reorder, withdrawn family, and next-round cache bound. Run family/Saved/action/local-state tests plus API persistence; commit with `feat: add family rounds and ordered game pins`.

## R6: Ship anonymous playable links and spoiler-free previews

- [ ] Add share route tests before implementation: exact play/revision/presentation round-trip, arbitrary query rejection, percent-encoding, HTML escaping, unavailable revision, unsupported capability, and no answer/reveal bytes in preview HTML/metadata. Inspect existing native/web link adapters before introducing a plugin dependency.
- [ ] Define canonical public route `/p/{playId}/{revisionId}` with an optional opaque share descriptor ID for a resolved decorative presentation. The descriptor stores bounded validated IDs and source attribution, never a client-controlled return URL. The server retrieves the same publication policy as R3. Static preview uses the opening composition's reviewed image, concise prompt and Mixli attribution; it is not a second interactive renderer.
- [ ] On Share, create/reuse an idempotent descriptor, then invoke the supported platform share sheet or copy-link fallback. Report success only when the platform operation succeeds; cancellation is neutral. Sharing a recipient's result is a separate deliberate action. Do not send messages to contacts automatically.
- [ ] Open links directly into the existing Play composition with anonymous actor access and one immediate action. Invalid/offline/unavailable state retains back and retry. Do not route through a marketing page or signup gate. Preserve referral attribution as analytics metadata outside immutable task bytes.
- [ ] Test native cold/warm deep links, web reload, copied links, preview scraping and large text. Run share/API tests and the corresponding platform/release gates. Commit with `feat: share exact playable rounds`.

## R7: Add bounded friend challenges and reveal rules

- [ ] Define the first challenge mode as asynchronous same-round play. No global leaderboard, wagering, or real-time room service. Store immutable play/revision/presentation, mode, scoring version, creator actor, creation/expiry, optional creator submitted result, and permitted reveal policy. Use an unguessable public invite ID; creator mutation/revocation still requires authenticated actor proof. Invite IDs are not account credentials.
- [ ] Add idempotent challenge creation and participant submission endpoints. Unique `(actor_id, idempotency_key)` creation returns the same descriptor for identical payload; key reuse with different canonical payload conflicts. Participant has one immutable ranked submission per challenge; replay becomes practice. Initial expiry is 30 days, with existing retention/deletion policy applied to personal result data.
- [ ] For `Your Read`, creator choice stays server-side until recipient commits their prediction. Never ship a supposedly hidden answer as a low-entropy hash or client JSON field. An ordinary deterministic puzzle document can reveal its answer to a determined inspector; do not claim anti-cheat security for it. `Second Thought` uses its published staged task state; remote role-specific clue delivery for `Two Halves` is outside this first asynchronous challenge service.

```text
challenge open + authenticated participant commits -> immutable submission
submission accepted + policy allows reveal          -> authorized comparison
duplicate same submission                          -> original response
duplicate changed submission                       -> conflict; offer practice
expired/revoked/withdrawn                           -> no new ranked submission
```

- [ ] Use existing durable delivery for result events; define an acknowledgment/read path so a lost response recovers the accepted result without resubmission. Offline challenge completion stays pending and shows no invented friend comparison. If media/timing/accessibility changes task equivalence, mark the attempt practice and disclose that compactly.
- [ ] Display one meaningful comparison, such as differing choices or observation misses; never infer a friend's motives or “intelligence” from the result. Exclude private responses from public preview/share cards unless that participant deliberately shares them. Reuse Report/creator controls and existing rate limits.
- [ ] Test duplicate/lost response, two concurrent commits, wrong actor, anonymous proof, expired/revoked invite, hidden-data leaks, withdrawn media, practice replay, and removal requests in API/PostgreSQL and app tests. Run final diff/platform gates, push the PR, and update #5 with actual evidence. Commit with `feat: add asynchronous same-round challenges`.

**Release acceptance:** first play, exact replay, fresh round, saved recovery, family pin, and recipient play are distinguishable in behavior and analytics; no core action requires signup; no unsent collection mutation disappears under pressure; no ranked comparison changes task identity silently.

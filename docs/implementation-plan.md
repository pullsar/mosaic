# Mosaic — Implementation Plan

## 1. Objective

Build the smallest product that validates three connected loops:

```text
FIND → PLAY → REACT → SWIPE
```

```text
SEE → REMIX → PUBLISH → OTHERS PLAY
```

```text
PLAY → SHARE → RECIPIENT PLAYS → RESPONDS / CONTINUES
```

The first controlled beta must prove that users prefer a personalized playable feed to a static game/content menu, creators can make good interactive supply without custom development, and Plays can spread without an install wall.

## 2. Product/engineering principles

- Flutter + Dart for consumer, shared Play renderer, and native creator surfaces.
- Mobile-first interaction; browser-playable shared Plays.
- The Play is the interface: visual/content weight dominates chrome and copy.
- Consumer Play surfaces target ~88% primary content/supporting visuals, ~9% controls/motion, ~3% visible text as an attention heuristic.
- Anonymous-first value; registration only when durable identity is needed.
- One versioned Play schema and deterministic pure-Dart engine; no per-Play application code.
- Separate interest, learning-intent, and interaction-affinity signals.
- PostgreSQL as system of record; pgvector before a separate vector/graph database.
- S3-compatible object storage + CDN for media.
- Resumable creator uploads for non-trivial media.
- Prefetch enough that swipe normally never waits on the network.
- Ship analytics/experiment contracts before ranking sophistication.
- Human-curated seed inventory before generated scale.
- No arbitrary creator code/plugins.
- Rights, moderation, kill switches, crash reporting, rollback, and performance telemetry exist before controlled launch.

See [`visual-language-and-copy-spec.md`](visual-language-and-copy-spec.md) and [`dependency-and-platform-decisions.md`](dependency-and-platform-decisions.md).

## 3. Repository shape

```text
apps/
  mosaic_app/          # Flutter iOS/Android/web consumer + native creator shell
  api/                 # server API/jobs (implementation language may differ)

packages/
  play_schema/         # pure Dart schema/model/validation
  play_engine/         # pure Dart deterministic state machine
  play_flutter/        # Flutter primitive renderers/adapters
  analytics_contract/  # canonical Dart event contracts
  platform_contracts/  # audio/upload/flags/share/auth interfaces

docs/
  ...
```

Use Dart pub workspaces initially. Avoid a monorepo orchestrator until commands materially benefit from one.

## 4. Baseline client stack

### Flutter app

- Flutter stable + Dart.
- Riverpod for app/service state.
- go_router for routes/deep links.
- first-party `video_player` for short clips initially.
- `flutter_soloud` behind Mosaic `AudioEngine` for timing-sensitive audio.
- Drift only when local relational persistence is justified.
- Flutter `CustomPainter`/Impeller before adding any separate game engine.
- Sentry Flutter before beta.

### Shared web Play

Use the same Flutter `play_flutter` renderer where the primitive is web-compatible.

Server/edge shell provides social metadata before Flutter boots.

Unsupported primitives must declare a clear web fallback; they may not silently render broken.

### API/data

- PostgreSQL.
- explicit SQL/query layer rather than heavy domain ORM.
- pgvector when similarity/search/duplicate detection is required.
- Redis/Valkey only for cache, rate limits, ephemeral ranking state, or queues where justified.

### Media

- object storage + CDN;
- signed/quarantined upload path;
- resumable tus-class transport;
- normalized server derivatives;
- FFmpeg-class server processing.

### Experimentation/operability

- Mosaic-owned canonical event stream;
- GrowthBook Flutter preferred behind Mosaic flag adapter after license/deployment review;
- Sentry Flutter for crash/performance telemetry.

## 5. Milestone 0 — Flutter workspace + contracts

### Deliverables

- Dart workspace scaffold;
- Flutter application shell;
- pure-Dart `play_schema` package;
- pure-Dart `play_engine` package;
- canonical analytics package;
- platform interfaces package;
- deterministic lint/format/test commands;
- CI running `dart analyze`, `dart test`, `flutter analyze`, and `flutter test` where applicable;
- Play schema v1;
- canonical analytics envelope;
- anonymous actor/session identity contracts;
- feature-flag interface;
- Sentry bootstrap interface;
- visual tokens/copy constants consistent with the visual-first spec.

### Exit criteria

- clean checkout resolves packages deterministically;
- core schema/engine run without importing Flutter;
- at least one fixture validates and executes through the engine;
- malformed graph validation is tested;
- Flutter shell can render a fixture through a thin renderer adapter;
- no consumer screen requires explanatory onboarding prose;
- CI enforces formatting/analyze/tests.

## 6. Milestone 1 — Play engine + first visual vertical slice

### Initial media

- text;
- image;
- short clip;
- audio.

### Initial input

- tap;
- single choice;
- multiple choice;
- basic drag;
- piano-key input.

### Initial logic

- correct/incorrect;
- branch;
- reveal;
- next/end.

### Reference Plays

1. **Where is this?** — short beautiful-place clip + four options.
2. **Four-day getaway** — situated Lisbon/Marrakech choice.
3. **Which piano key?** — audio identification.
4. **Play it back** — three-note keyboard sequence.
5. **Move one match** — compact visual puzzle.
6. **Which century?** — artwork identification.

### Visual acceptance

Each reference Play must pass:

- subject/object is visually dominant;
- initial copy is minimal;
- no paragraph on initial state;
- controls do not cover the focal subject;
- feedback is primarily visual/audio/haptic where possible;
- swipe/back interrupts safely;
- large text/reduced motion remain usable.

### Performance acceptance

- profile on representative iOS and Android devices;
- normal swipe/render path targets 60 fps minimum experience;
- 120 Hz devices are measured separately;
- expensive blur/clipping/layers are removed from feed-critical paths unless justified;
- inactive video/audio/custom-paint resources are released promptly.

## 7. Milestone 2 — Anonymous onboarding + personalized feed

### Onboarding

Exactly two optional preference screens:

1. **What are you into?**
2. **Want to learn more about?**

Use visual topic tiles/tag clusters. Do not merge the two signal sets.

### Feed

- full-screen vertical paging;
- bounded next-window prefetch;
- immediate dismiss;
- Save;
- Share;
- **More like this**;
- Not interested;
- mute topic/creator;
- report;
- gesture arbitration between feed and direct manipulation.

### Search

Lightweight intentional discovery:

- topic;
- learning topic;
- Play;
- creator later.

### Initial ranking

Interpretable weighted features:

- explicit interest affinity;
- explicit learning affinity;
- interaction affinity;
- content quality prior;
- freshness/novelty;
- exploration bucket;
- repetition/fatigue penalties;
- strong explicit negative controls.

### Exit criteria

- anonymous user reaches feed without login;
- ranking distinguishes interest vs learning intent;
- **More like this** remains distinct from Save;
- feed remains usable on constrained mobile connections;
- ranking decisions are internally traceable;
- search surfaces explicit intent immediately.

## 8. Milestone 3 — Shared Play web runtime

Sharing is a beta requirement.

### Deliverables

- canonical public Play URLs;
- Flutter web Play renderer for supported primitives;
- server/edge Open Graph metadata without answer leakage;
- challenge context;
- sender/recipient compare/reveal flow;
- `share_plus`/platform share integration;
- universal/app-link resolution;
- anonymous recipient events.

### Required flow

```text
NATIVE PLAY
  ↓ SHARE
HTTPS PLAY LINK
  ↓
RECIPIENT PLAYS IN BROWSER
  ↓
RESULT / SENDER COMPARISON
  ↓
PLAY ANOTHER / GET MOSAIC
```

### Exit criteria

- recipient can play without install or account;
- moderation/revocation propagates to shared links;
- sender answer remains hidden until appropriate;
- share → open → Play → next/install funnel is measurable;
- canonical links survive attribution-provider removal.

## 9. Milestone 4 — Launch Play breadth

Complete:

- Guess;
- Choose;
- Solve;
- Play;
- Discover.

Add primitives only when a launch-quality Play requires them.

Likely:

- map;
- draw/canvas;
- sequence/order;
- rhythm tap;
- image hotspot;
- timed response;
- lightweight animation.

### Exit criteria

- at least three strong templates per format;
- no arbitrary webview/plugin code;
- accessibility contract for each primitive;
- explicit web support/fallback per primitive;
- shared analytics events across formats.

## 10. Milestone 5 — Remix + Quick Create + resilient media

### Remix

- eligible Play exposes **Remix**;
- typed slots;
- production runtime preview;
- immutable published revision;
- structure/media/text rights enforced independently;
- lineage recorded.

### Quick Create

Creator chooses:

**Guess · Choose · Solve · Play · Discover**

Only required fields appear. Preview dominates the creator surface.

### Media

- Flutter camera/file import;
- resumable upload;
- normalized derivatives;
- upload state survives navigation/restart where supported;
- restricted inherited media clears automatically during remix;
- provenance/rights mandatory.

### Exit criteria

- normal user can remix without documentation;
- interrupted upload does not destroy creator work;
- creator cannot execute arbitrary code;
- factual Play cannot publish without required provenance;
- rights policy blocks unauthorized inherited media reuse.

## 11. Milestone 6 — Seed supply + trust/moderation

### Target inventory

500–1,000 excellent Plays across:

- travel + food;
- music;
- puzzles;
- art + culture;
- curiosity;
- optional faith + reflection.

### Required controls

- duplicate/similarity detection;
- factual provenance review;
- rights declarations;
- adult/sexual-content rejection;
- report workflow;
- asset/Play takedown;
- appeals intake;
- creator audit trail;
- distribution suspension independent of deletion;
- emergency kill switches;
- abuse-resistant qualified-event layer.

## 12. Milestone 7 — Validation beta

Required experiments:

1. Feed vs static menu.
2. Generic vs situated choices.
3. Interest-only vs interest + learning intent.
4. Topic-only vs topic + interaction affinity.
5. Blank create vs Remix.
6. Human-curated vs AI-heavy candidate supply.
7. Shared Play web-first vs install-first sharing.
8. **More like this** vs implicit-positive-only ranking.
9. Visual-first prompt variants where copy density differs.

### Consumer gates

- played impressions / eligible impressions;
- D1/D7 return;
- meaningful actions/session;
- save/share/replay;
- rapid-swipe rate;
- hide/report rate;
- learning-topic engagement;
- search → successful Play rate.

### Experience-health gates

- first-action latency;
- frame/jank distribution by device class;
- media-first-frame latency;
- prompt comprehension errors;
- abandon before first action;
- accessibility failures.

### Growth gates

- qualified recipient Plays/share;
- share open → Play start;
- shared Play completion;
- second-Play rate;
- challenge response;
- install/signup after value.

### Creator gates

- create → publish;
- median creation time;
- second creation;
- remix rate;
- template reuse;
- upload failure/recovery;
- community-supplied qualified consumption.

Do not advance because aggregate session time increased.

## 13. Milestone 8 — Creator moat expansion

Only after Remix/Quick Create prove supply.

Add:

- advanced visual Studio;
- reusable template publishing;
- topic reputation;
- Demand Board;
- search/demand gap aggregation;
- demand-to-template suggestions;
- creator analytics;
- richer lineage.

The creator metric remains **qualified community supply consumed**, not uploads.

## 14. Later scope

Deferred:

- creator payouts;
- sponsored Plays;
- template marketplace;
- multiplayer beyond sharing/challenges;
- public comments;
- long-form content;
- creator subscriptions;
- institutional publishing;
- advanced location/context Plays;
- standalone graph/vector infrastructure.

## 15. Data model priorities

First server migrations should cover:

- actors;
- sessions;
- device_installations;
- users;
- actor_user_merges;
- topics;
- user_interest_signals;
- user_learning_signals;
- plays;
- play_revisions;
- play_topics;
- templates;
- template_revisions;
- remix_lineage;
- assets;
- asset_rights;
- sources/provenance;
- saves;
- interaction_events;
- qualified event state;
- share_links;
- challenges;
- moderation actions;
- rights complaints/takedowns.

Derived recommendation features remain rebuildable from source events.

## 16. Internationalization

Architect from first UI/schema implementation:

- system copy uses localization keys;
- Play text supports localized variants;
- currency/unit formatting stays outside hardcoded authored text where practical;
- RTL does not break layouts;
- visual-first interactions do not rely on culture-specific icon meanings without labels/accessibility support.

## 17. Testing strategy

### Schema/engine

- JSON/model validation;
- graph reachability;
- transition property tests;
- malformed/looping graph rejection;
- revision fixtures.

### Flutter renderer

- golden tests for stable primitives where useful;
- widget tests for action/feedback states;
- semantics/accessibility tests;
- gesture conflict tests;
- reduced-motion tests;
- media resource lifecycle tests.

### Native/web parity

- same fixture outcome semantics;
- explicit unsupported primitive tests;
- challenge reveal parity.

### Consumer

- anonymous → registered merge;
- feed resume/interrupt;
- audio route/latency;
- low-network prefetch.

### Creator/media

- slot validation;
- lineage;
- resumable upload;
- rights inheritance;
- takedown descendant behavior.

### Ranking/growth

- candidate fixtures;
- negative suppression;
- exploration minimums;
- fatigue;
- share attribution/idempotency;
- abuse filtering.

## 18. Operability

Before controlled beta:

- core API SLOs/client health targets;
- crash reporting;
- frame/media/runtime/share traces;
- remote kill switches;
- backups/restore;
- staged rollout;
- validated/deduplicated analytics ingestion;
- launch dashboard for feed/runtime/media/creator/sharing/moderation.

## 19. Controlled-launch ready

Mosaic is ready when:

- anonymous user can play immediately;
- interests and learning intent are captured separately and visually;
- feed is fast, swipe-first, searchable, and supports **More like this**;
- Play surface is content-dominant and copy-light;
- all five Play formats run through the common Dart engine;
- travel clip, piano audio, puzzle, art, and situated choice feel native;
- recommendation uses interest + learning + interaction signals;
- a shared supported Play works on mobile web without install;
- Remix/Quick Create publish valid Plays with lineage and rights enforcement;
- media upload is resilient;
- seed inventory is high quality;
- moderation/takedown/kill switches work;
- crashes, frame health, latency, ranking, experiments, and growth funnels are measurable.

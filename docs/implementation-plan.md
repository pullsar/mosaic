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

## 2. Engineering principles

- Mobile-first interaction; web-first accessibility for shared Plays.
- Anonymous-first value; registration only when durable identity is needed.
- One versioned Play schema and deterministic execution model; no per-Play application code.
- Separate interest, learning-intent, and interaction-affinity signals.
- TypeScript end-to-end where practical.
- PostgreSQL as system of record; add pgvector before a separate vector/graph database.
- S3-compatible object storage + CDN for media.
- Resumable creator uploads for non-trivial media.
- Prefetch enough that swipe never waits on the network.
- Ship analytics/experiment contracts before ranking sophistication.
- Human-curated seed inventory before generated scale.
- No arbitrary creator JavaScript.
- Rights, moderation, kill switches, crash reporting, and rollback exist before controlled launch.

## 3. Repository shape

```text
apps/
  mobile/              # Expo/React Native consumer + native creator surface
  web/                 # public shared-Play renderer + creator/admin web
  api/                 # TypeScript HTTP API + jobs

packages/
  play-schema/         # versioned schema + runtime validation
  play-engine/         # platform-independent deterministic state machine
  play-native/         # native primitive renderers/adapters
  play-web/            # web primitive renderers/adapters
  ui/                  # tokens/components where portability is real
  analytics-contract/  # canonical event names/payloads
  ranking/             # candidate/ranking interfaces and heuristics
  platform/            # auth, flags, sharing, upload, audio provider interfaces

services/
  media/               # upload/transcode/provenance helpers if separated later

docs/
  ...
```

Use a pnpm monorepo initially. Keep deployment topology simple until independent scaling requires separation.

## 4. Baseline stack

### Consumer/native

- Expo + React Native + TypeScript.
- React Native Gesture Handler + Reanimated.
- FlashList for heterogeneous feed windowing.
- TanStack Query for server state/cache.
- Skia only for Play primitives that need custom graphics.
- React Native Audio API behind Mosaic `AudioEngine` for timing-sensitive music/rhythm interactions.
- Sentry React Native before beta.

### Web

- TypeScript web application capable of server-rendered/social-preview Play URLs.
- Same `play-schema` and `play-engine` packages as native.
- Web renderer must preserve Play semantics; unsupported native primitives fail/degrade explicitly.
- Creator preview runs production web/runtime primitives, not a mock renderer.

### API/data

- TypeScript + Fastify.
- PostgreSQL.
- Explicit SQL/Kysely-style query layer over heavy domain ORM.
- pgvector when semantic similarity/search/duplicate detection is required.
- Redis/Valkey only for cache, rate limits, ephemeral ranking/session state, or queues where justified.

### Media

- Object storage + CDN.
- Signed/quarantined uploads.
- Uppy + tus for creator-web/resumable transport; equivalent tus-capable native path.
- Server-generated normalized derivatives.
- FFmpeg-class processing server-side.

### Experimentation/operability

- Mosaic-owned canonical event stream.
- GrowthBook preferred for flags/experiments after deployment/license review.
- Sentry for crash/performance telemetry.
- PostHog may be used as a product-analysis UI, never as ranking source of truth.

See [`dependency-and-platform-decisions.md`](dependency-and-platform-decisions.md).

## 5. Milestone 0 — Repository and operational foundation

### Deliverables

- workspace scaffold;
- deterministic install/lockfile;
- lint/typecheck/test commands;
- CI for all packages;
- environment/config convention;
- database migrations;
- seed-data command;
- Play schema v1;
- canonical analytics envelope;
- anonymous `actor_id`, session, installation, and user identity model;
- feature-flag/config interface;
- Sentry/error instrumentation;
- dependency/license/security scanning.

### Exit criteria

- clean checkout installs deterministically;
- CI runs formatting, typecheck, tests, schema compatibility, and dependency checks;
- one fixture validates and executes through the Play engine;
- anonymous actor can later merge idempotently into a user account;
- a risky feature can be remotely disabled through the platform abstraction.

## 6. Milestone 1 — Play engine/runtime vertical slice

Implement the deterministic engine before a rich feed.

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

1. **Where is this?** short beautiful-place clip + four options.
2. **Four-day getaway** situated Lisbon/Marrakech choice.
3. **Which piano key?** audio identification.
4. **Play it back** three-note keyboard sequence.
5. **Move one match** compact puzzle.
6. **Which century?** artwork identification.

### Exit criteria

- every reference Play is data, not custom application code;
- engine can enter, exit, resume/restart per policy, and reject malformed graphs;
- swipe-away remains external to and available from every Play state;
- native renderer emits canonical events;
- published schema versions are compatibility-tested;
- timing-sensitive audio has device-latency instrumentation.

## 7. Milestone 2 — Anonymous onboarding + personalized feed

### Onboarding

Exactly two optional preference screens:

1. **What are you into?**
2. **What do you want to learn more about?**

Do not merge the two signal sets.

### Feed

- full-screen vertical paging;
- bounded next-window prefetch;
- immediate dismiss;
- Save;
- **More like this**;
- Not interested;
- mute topic;
- mute creator;
- report;
- primitive-aware gesture arbitration.

### Search

Add lightweight intentional discovery:

- topic;
- learning topic;
- Play;
- creator later.

Search remains secondary to the feed but feeds unmet-demand signals.

### Initial ranking

Use interpretable weighted features:

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
- same user receives different ranking from interest vs learning intent;
- **More like this** affects ranking separately from Save;
- ranking decisions are internally traceable;
- feed remains usable on constrained mobile connections;
- search can surface a requested topic immediately.

## 8. Milestone 3 — Shared Play web runtime

Sharing is a beta requirement, not a later marketing feature.

### Deliverables

- canonical public Play URLs;
- mobile web renderer using same schema/engine;
- Open Graph/social-preview metadata without answer leakage;
- challenge context;
- compare/reveal flow for competitive and preference Plays;
- native share sheet/copy link;
- app/universal-link resolution;
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

- supported shared Plays work without app installation or registration;
- moderation/revocation propagates quickly to shared links;
- sender answer can remain hidden until recipient responds;
- share → open → Play → next/install funnel is measurable;
- canonical links do not depend on one attribution vendor.

See [`growth-and-sharing-spec.md`](growth-and-sharing-spec.md).

## 9. Milestone 4 — Launch Play breadth

Complete the five product formats:

- Guess;
- Choose;
- Solve;
- Play;
- Discover.

Add primitives only when a launch-quality Play requires them.

Likely additions:

- map;
- draw/canvas;
- sequence/order;
- rhythm tap;
- image hotspot;
- timed response;
- lightweight animation.

### Exit criteria

- each format has at least three strong reusable templates;
- no standard Play depends on external webview/plugin code;
- accessibility behavior exists for every primitive;
- web compatibility/support state is explicit for every primitive;
- analytics compares formats through common events.

## 10. Milestone 5 — Remix + Quick Create + resilient media

Creation begins with reuse, not a blank canvas.

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

Only required fields appear.

### Media

- capture/import;
- resumable uploads;
- normalized derivatives;
- upload survives navigation/restart where supported;
- restricted upstream media clears automatically during remix;
- asset provenance/rights mandatory.

### Publication states

```text
DRAFT → VALIDATING → REVIEW/READY → PUBLISHED_LIMITED → PUBLISHED_ELIGIBLE → ARCHIVED
```

### Exit criteria

- normal user can remix without documentation;
- failed/interrupted media upload does not destroy creator work;
- creator cannot execute arbitrary code;
- factual Play cannot publish without required provenance;
- rights policy prevents unauthorized inherited media reuse.

See [`media-pipeline-spec.md`](media-pipeline-spec.md) and [`trust-rights-and-moderation-spec.md`](trust-rights-and-moderation-spec.md).

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

### Exit criteria

- every launch category contains multiple formats/media types;
- feed does not depend on generated filler;
- rights/takedown works through remix descendants;
- reports can remove content from distribution quickly;
- raw engagement is not directly trusted for reputation/economics.

## 12. Milestone 7 — Validation beta

### Required experiments

1. Feed vs static menu.
2. Generic vs situated choices.
3. Interest-only vs interest + learning intent.
4. Topic-only vs topic + interaction affinity.
5. Blank create vs Remix.
6. Human-curated vs AI-heavy candidate content.
7. Shared Play web-first value vs install-first share destination.
8. **More like this** vs implicit-positive-only ranking.

### Consumer gates

- played impressions / eligible impressions;
- D1/D7 return;
- meaningful actions/session;
- save/share/replay;
- rapid-swipe rate;
- hide/report rate;
- learning-topic engagement;
- search → successful Play rate.

### Growth gates

- qualified recipient Plays/share;
- share open → Play start;
- shared Play completion;
- second-Play rate;
- challenge response rate;
- install/signup after recipient value.

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

Only after Remix/Quick Create demonstrate supply.

Add:

- advanced Studio blocks;
- XYFlow-based graph authoring where useful;
- reusable template publishing;
- topic reputation;
- Demand Board;
- search/demand gap aggregation;
- demand-to-template suggestions;
- creator analytics;
- richer remix lineage.

The core creator metric remains **qualified community supply consumed**, not uploads.

## 14. Later scope

Deferred until core validation:

- creator payouts;
- sponsored Plays;
- template marketplace;
- multiplayer beyond share/challenge context;
- public comments;
- long-form content;
- creator subscriptions;
- institutional publishing;
- advanced local/context-aware Plays;
- standalone graph/vector infrastructure.

## 15. Data model priorities

First migrations should cover:

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
- qualified_events/validation state;
- share_links;
- challenges;
- moderation state/actions;
- rights complaints/takedowns.

Keep derived recommendation features rebuildable from source events.

## 16. Internationalization

Architect for localization from the first schema/UI implementation:

- consumer system copy uses localization keys;
- Play text can support localized variants;
- locale/currency/unit formatting stays outside authored hardcoded strings where practical;
- RTL does not break Play layouts;
- content can be regionally eligible without assuming sensitive user attributes.

Do not build a translation marketplace in v1.

## 17. Testing strategy

### Schema/engine

- schema validation;
- state-transition property tests;
- malformed/looping graph rejection;
- revision compatibility fixtures.

### Native/web parity

- same fixture outcome semantics across supported renderers;
- explicit unsupported-primitive tests;
- challenge reveal parity.

### Consumer

- deterministic gesture tests;
- resume/interrupt;
- audio timing/route tests;
- accessibility;
- low-network prefetch;
- anonymous → registered merge.

### Creator/media

- slot validation;
- remix lineage;
- preview/published parity;
- resumable upload;
- rights inheritance;
- media takedown descendant behavior;
- moderation gates.

### Ranking/growth

- deterministic candidate fixtures;
- negative-signal suppression;
- exploration minimums;
- fatigue;
- cold start;
- share attribution/idempotency;
- abuse/fraud filtering.

## 18. Operability and performance

Before controlled beta:

- core API SLOs and client health targets defined;
- crash reporting active;
- feed/runtime/media/share traces available;
- remote kill switches tested;
- backups and restore procedure documented;
- staged rollout path exists;
- analytics ingestion has validation/deduplication;
- launch dashboard covers feed, runtime, media, creator, sharing, and moderation.

See [`operability-and-slo-spec.md`](operability-and-slo-spec.md).

## 19. Security and trust

- signed/quarantined media uploads;
- server-side type verification;
- immutable published revisions;
- no secrets/provider credentials in Play data;
- declarative creator runtime only;
- rate limits on creation/reporting/sharing/events;
- provider-specific auth/flags/deep links hidden behind Mosaic interfaces;
- recommendation safety overrides engagement.

## 20. Definition of controlled-launch ready

Mosaic is ready when:

- anonymous user can play immediately;
- onboarding captures interests and learning intent separately;
- feed is fast, swipe-first, searchable, and supports **More like this**;
- all five Play formats run through the common engine;
- travel clip, piano audio, puzzle, art, and situated choice feel native;
- recommendation uses interest + learning + interaction signals;
- a shared supported Play works on mobile web without install;
- Remix/Quick Create publish valid Plays with lineage and rights enforcement;
- media upload is resilient;
- seed inventory is high quality;
- moderation/takedown/kill switches work;
- crashes, latency, ranking decisions, experiments, and growth funnels are measurable;
- no launch feature violates the core product loops.

# Mosaic — Implementation Plan

## 1. Objective

Build the smallest product that can validate both Mosaic loops:

```text
FIND → PLAY → REACT → SWIPE
```

```text
SEE → REMIX → PUBLISH → OTHERS PLAY
```

The first implementation must prove that users prefer a personalized playable feed to a static content/game menu, and that creators can make useful interactive content without custom development.

## 2. Engineering principles

- Mobile-first interaction.
- One deterministic Play runtime; no per-Play application code.
- TypeScript end-to-end where practical so schema/runtime types are shared.
- PostgreSQL as system of record; do not introduce a graph database before the product requires one.
- S3-compatible object storage + CDN for media.
- Redis/Valkey only for cache, rate limits, ephemeral ranking/session state, and jobs where justified.
- Prefetch aggressively enough that swiping never waits on the network.
- Ship analytics contracts before ranking sophistication.
- Human-curated seed inventory before generated scale.
- No arbitrary creator JavaScript.

## 3. Recommended repository shape

```text
apps/
  mobile/              # Expo/React Native consumer app
  creator-web/         # Next.js creator Studio/admin surface
  api/                 # TypeScript HTTP API + background jobs

packages/
  play-schema/         # versioned schema + validation
  play-runtime/        # deterministic state machine
  ui/                  # shared design tokens/components where portable
  analytics-contract/  # event names/payloads
  ranking/             # candidate/ranking interfaces and heuristics

services/
  media/               # upload/transcode/provenance helpers if separated later

docs/
  ...
```

A monorepo with pnpm workspaces is preferred initially. Do not add orchestration complexity until independent deployment is required.

## 4. Recommended baseline stack

### Consumer

- Expo + React Native + TypeScript.
- Reanimated/Gesture Handler for feed and direct manipulation.
- Native audio APIs through Expo/native modules as needed.
- Local persistence for feed window, user preferences, and interrupted Play state.

### Creator web

- Next.js + TypeScript.
- Same `play-schema` package as runtime.
- Browser preview runs the actual runtime renderer, not a mock implementation.

### API

- TypeScript + Fastify.
- PostgreSQL.
- Query layer should favor explicit SQL/Kysely-style access over a heavy domain ORM.
- Background jobs only for media processing, moderation, derived ranking features, and notifications.

### Media

- Object storage + CDN.
- Signed upload paths.
- Server-generated media derivatives.
- Video/audio normalized to a small supported codec/profile set.

## 5. Milestone 0 — Repository foundation

### Deliverables

- workspace scaffold;
- lint/typecheck/test commands;
- CI for all packages;
- environment/config convention;
- database migrations;
- seed-data command;
- shared identifiers/time conventions;
- analytics event contract;
- Play schema v1.

### Exit criteria

- clean checkout installs deterministically;
- CI runs typecheck, tests, formatting, and schema compatibility checks;
- one fixture Play validates against the schema and renders in a test harness.

## 6. Milestone 1 — Play runtime vertical slice

Implement the runtime before building a rich feed.

### First supported primitives

Media:

- text;
- image;
- short clip;
- audio.

Input:

- tap;
- single choice;
- multiple choice;
- basic drag;
- simple piano-key input.

Logic:

- correct/incorrect;
- branch;
- reveal;
- next/end.

### Reference Plays

Build these as fixtures:

1. **Where is this?** short travel clip + four options.
2. **Four-day getaway** situated Lisbon/Marrakech choice.
3. **Which piano key?** audio identification.
4. **Play it back** three-note keyboard sequence.
5. **Move one match** compact puzzle.
6. **Which century?** artwork identification.

### Exit criteria

- every reference Play is defined as data, not custom application code;
- runtime can enter, exit, and resume a Play safely;
- validation rejects malformed transitions;
- swipe-away works from every state;
- analytics events are emitted consistently.

## 7. Milestone 2 — Onboarding + feed

### Onboarding

Implement exactly two optional preference screens:

1. **What are you into?**
2. **What do you want to learn more about?**

Store those as distinct signal sets.

### Feed

- full-screen vertical paging;
- prefetch next candidate window;
- immediate dismiss;
- save;
- not interested;
- mute topic;
- report;
- tap/manipulate without accidentally triggering navigation.

### Initial ranking

Use a transparent heuristic first:

- explicit interest affinity;
- explicit learning affinity;
- format affinity from behavior;
- content quality prior;
- freshness/novelty;
- exploration bucket;
- repetition/fatigue penalties.

Do not start with a black-box recommender.

### Exit criteria

- user can complete onboarding and begin playing without another setup screen;
- feed remains responsive on constrained mobile connections;
- same user can receive materially different ranking from interest vs learning intent;
- ranking decisions can be logged/explained internally.

## 8. Milestone 3 — Launch Play breadth

Complete support for the five product-level formats:

- Guess;
- Choose;
- Solve;
- Play;
- Discover.

Add media/input primitives only when at least one launch-quality Play requires them.

Likely additions:

- map;
- draw/canvas;
- sequence/order;
- rhythm tap;
- image hotspot;
- timed response;
- lightweight animation.

### Exit criteria

- each format has at least three high-quality reference templates;
- no format depends on an external webview;
- accessibility behavior is defined for every primitive;
- analytics can compare formats without format-specific event names.

## 9. Milestone 4 — Remix + Quick Create

Creation starts with reuse, not a blank canvas.

### Remix

- eligible Play exposes **Remix**;
- creator edits typed slots;
- live preview uses production runtime;
- validation blocks broken publication;
- lineage is recorded.

### Quick Create

Creator chooses:

**Guess · Choose · Solve · Play · Discover**

Only required fields appear.

### Publication states

```text
DRAFT → VALIDATING → REVIEW/READY → PUBLISHED → ARCHIVED
```

### Exit criteria

- median simple remix can be completed without documentation;
- published Play has immutable revision + creator + template lineage;
- creator cannot execute arbitrary code;
- factual Play cannot publish without its required provenance fields.

## 10. Milestone 5 — Seed supply + moderation

Prepare the private beta inventory.

### Target

500–1,000 strong Plays across:

- travel + food;
- music;
- puzzles;
- art + culture;
- curiosity;
- optional faith + reflection.

### Quality controls

- duplicate detection;
- source/provenance review for factual Plays;
- rights metadata for uploaded media;
- content classification;
- no adult/erotic/sexually explicit content;
- basic abuse/report handling.

### Exit criteria

- every launch category contains multiple formats/media types;
- feed does not depend on generated filler for coverage;
- reports can remove content quickly from recommendation eligibility.

## 11. Milestone 6 — Validation beta

Run product experiments before widening scope.

### Required experiments

1. Feed vs static menu.
2. Generic vs situated choices.
3. Interest-only vs interest + learning intent.
4. Topic-only vs topic + interaction affinity.
5. Blank creation vs Remix.
6. Human-curated vs AI-heavy candidate content.

### Gate metrics

Consumer:

- played impressions / eligible impressions;
- D1/D7 return;
- meaningful actions/session;
- save/share/replay;
- rapid-swipe rate;
- report/hide rate.

Creator:

- create → publish;
- creation time;
- second creation;
- remix rate;
- template reuse;
- community-supplied qualified consumption.

Do not advance because aggregate session time increased.

## 12. Milestone 7 — Creator moat expansion

Only after Remix/Quick Create demonstrate real supply.

Add:

- advanced Studio blocks;
- reusable template publishing;
- topic reputation;
- Demand Board;
- demand-to-template suggestions;
- creator analytics;
- richer remix lineage.

The core creator metric is not uploads. It is **qualified community supply consumed**.

## 13. Later scope

Explicitly deferred until core validation:

- creator payouts;
- sponsored Plays;
- template marketplace;
- multiplayer;
- public comments;
- long-form content;
- creator subscriptions;
- institutional publishing;
- local/context-aware Plays;
- advanced graph infrastructure.

## 14. Data model priorities

First migrations should cover:

- users;
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
- sources/provenance;
- saves;
- interaction_events;
- moderation state.

Keep derived recommendation features rebuildable from source events.

## 15. Testing strategy

### Schema/runtime

- JSON/schema validation tests;
- state transition property tests;
- malformed/looping graph rejection;
- revision compatibility fixtures.

### Consumer

- deterministic feed gesture tests;
- resume/interrupt tests;
- audio-state tests;
- accessibility tests;
- low-network prefetch tests.

### Creator

- slot validation;
- remix lineage;
- preview/published parity;
- immutable published revisions;
- moderation gates.

### Ranking

- deterministic candidate fixtures;
- negative-signal suppression;
- exploration minimums;
- repeated-format fatigue;
- cold-start preference behavior.

## 16. Performance budgets

Initial product-level budgets:

- feed shell available without waiting for the next media asset;
- next Play metadata prefetched before the current Play is likely to finish;
- current + bounded next-window media retained; old media released promptly;
- no creator Play can introduce unbounded JS, DOM, network requests, or memory use;
- video clips should be short and encoded for rapid mobile start;
- audio should be small enough to prefetch selectively.

Concrete device/network thresholds should be captured from instrumentation and promoted to CI/performance gates once representative fixtures exist.

## 17. Security and trust

- signed media uploads;
- server-side content-type verification;
- creator permissions separate from consumer identity assumptions;
- immutable publication revisions;
- audit trail for moderation and source edits;
- rate limits on creation, reporting, sharing, and event ingestion;
- no secrets or source-provider credentials in Play data;
- creator runtime is declarative only.

## 18. Definition of launch-ready

Mosaic is ready for a controlled launch when:

- onboarding captures interests and learning intent cleanly;
- feed is fast and swipe-first;
- all five Play formats work through one runtime;
- travel clip, piano audio, puzzle, art, and situated-choice examples feel native rather than embedded;
- recommendation uses interest + learning + interaction signals;
- Remix and Quick Create publish valid Plays with lineage;
- seed inventory is high quality;
- moderation/reporting works;
- core events and validation experiments are measurable;
- no v1 feature violates the product loops.

# Mixli — Experience Readiness Plan

## Purpose

This plan turns Mixli's product, experience, runtime, visual-language, accessibility, and operability specifications into a practical launch-readiness bar. It is implementation-oriented but does not invent backend contracts that do not exist in the repository.

The evolving execution tracker remains GitHub issue #48. This document defines the experience bar that implementation must satisfy.

## Current repository reality

As of 2026-08-29, the upstream repository is already the real Flutter + Dart implementation—not a design shell or Next.js prototype. The shared client/runtime architecture is:

```text
Play data
  ↓
play_schema      # pure Dart model/validation
  ↓
play_engine      # pure Dart deterministic state machine
  ↓
play_flutter     # Flutter renderers/adapters
  ↓
iOS / Android / Web
```

The current `main` baseline includes:

- Flutter workspace, schema/engine, analytics and platform contracts;
- capability negotiation and cross-language contracts;
- PostgreSQL/API data foundation and immutable Play revisions;
- lifecycle, permissions, privacy, local recovery and durable cross-platform event delivery;
- production image/video/audio/canvas rendering plus managed media normalization/publication paths;
- anonymous actor proof-of-possession and browser ownership boundary;
- interpretable M2 ranking/data foundation;
- cross-platform consumer client/local state/runtime;
- the two-screen optional visual onboarding flow;
- full-screen bounded feed paging/recovery;
- managed mixed-media asset delivery and bounded warming.

The current consumer-loop critical path is #52 explicit controls/actions, followed by #53 interaction-signal projection, #54 intentional discovery/search, and #55 integrated M2 acceptance. Accessibility parity (#17) and physical 60/120 Hz evidence (#3) remain parallel release gates.

Do not regress these foundations while improving visual polish. Mixli's readiness problem is now integration quality, interaction clarity, accessibility, bounded performance, trustworthy recovery, creator/sharing completion, content quality, and launch evidence—not choosing a new frontend architecture.

## North star

> Open Mixli with no plan, find something worth doing immediately, and leave without friction.

The primary loop is:

```text
FIND → PLAY → REACT → SWIPE
```

The first-time experience should make the user infer:

> **This feed gives me things to do.**

## Launch experience surface

1. **Play** — full-screen feed; one Play owns the viewport.
2. **Saved** — lightweight collections, never framed as homework.
3. **Create** — Remix first, then Quick Create; preview before configuration.
4. **Me** — preferences, muted topics/creators, identity and settings.
5. **Optional onboarding** — exactly two visual preference screens: **What are you into?** and **Want to learn more about?**, with search, any-number selection, skip and **Surprise me** where specified.

Launch Play families are **Guess, Choose, Solve, Play, Discover**. A Play may generally move through `SETUP → ACTION → RESPONSE → REVEAL → OPTIONAL NEXT`, but every state stays dismissible.

## Experience acceptance criteria

### Feed and interaction

- App entry resolves into a Play, not a dashboard, course, tutorial or marketing screen.
- Vertical swipe advances from every Play state; an incorrect answer never locks the user in.
- Direct manipulation has explicit gesture ownership and cannot accidentally page the feed or leave paging disabled.
- The first viewport has one dominant object and one understandable action without explanatory prose.
- Save is one tap. Share represents the Play itself. More exposes the relevant secondary preference/safety actions without turning the viewport into a toolbar.
- **Save**, **More Like This**, **Not interested**, topic/creator mute and **Report** remain semantically and analytically distinct.
- No right-side engagement tower, forced completion, streak pressure, public comment dependency, or messaging dependency is required for the first release.

### Visual system

- Content dominates attention; target roughly **88% content, 9% controls/feedback, 3% visible text** as a hierarchy heuristic.
- Edge-to-edge or object-dominant media, stable control placement, quiet attribution and restrained transient material/glass.
- Puffy/posh means tactile depth, soft surfaces, polished transitions and premium restraint—not childish decoration.
- Use a small type hierarchy: Semibold prompts, Medium controls, Regular detail; no Thin/Light functional text.
- Content-specific color may lead. Decorative gradient stacks, blobs, nested cards, badge clutter and gratuitous blur fail review.
- Layout quality must survive small phones, desktop/web viewports and larger text settings without turning the Play into a card-heavy website.

### Motion and realtime

- Motion explains feed movement, cause/effect, answer resolution, placement, reveal, save/share state, media state and hierarchy.
- Motion is interruptible, spring-like where appropriate, reduced-motion aware and never blocks swipe/back.
- The visible state responds immediately to input before explanatory copy appears.
- No confetti for trivial answers, ambient bouncing, permanent animation, shame or streak reinforcement.
- Optimistic actions reconcile safely with server state: no duplicate pulses/events, jumps, stale overwrite, flashing, or surprise audio.
- Connection loss/recovery is compact; the current Play remains usable and locally held state is preserved where possible.
- A normal warm swipe never lands on an empty blocking spinner. Compose local structure first, primary media next, deferred assets last.
- Prefetch only a bounded next window; release inactive audio/video/custom-drawing resources quickly.
- 60 fps is the minimum product requirement; 120 Hz devices must remain meaningfully smooth where supported.

### Accessibility

- Semantic order follows the logical Play action sequence rather than paint order.
- Icon-only controls have accessible names and generous targets.
- Feedback never depends on color alone.
- Captions/transcripts exist when speech/audio conveys meaning.
- Scalable text, contrast, reduced motion, keyboard/non-gesture alternatives and alternate paths for drag/custom-canvas interactions are part of acceptance.
- Flutter web shared Plays must expose usable semantics rather than behaving like an inaccessible canvas.
- Accessibility metadata is part of authored/publication validation, not a post-launch patch.

### Network, recovery and failure

- Swipe, dismiss, back and retry remain available during loading, media failure, API latency and recovery.
- Existing/current content remains usable while next-page work retries.
- Local preference/action state is not discarded because remote sync failed.
- Stale async work cannot update a newer Play after rapid paging.
- Cursor/request retry stays bounded and idempotent.
- Ranking or transport failure degrades to safe recovered/curated supply instead of blocking the feed.
- Media failure preserves composition and provides a compact retry/fallback where the Play still makes sense.

## Readiness sequence from the current baseline

### 1. Close the anonymous consumer loop

Complete #52 → #53 → #54 → #55 without replacing the merged consumer runtime, local-state boundary, event spool or feed pager.

Required outcome:

```text
anonymous entry
  → optional visual preferences
  → useful Play
  → explicit action
  → durable event/state
  → interpretable ranking update
  → intentional search when desired
  → resilient return to feed
```

In parallel, close #17 accessibility parity and collect the physical 60/120 Hz evidence still required by #3.

### 2. Make the Play the viral object

Complete #5 so a shared supported Play opens and works in the browser before account creation or installation. Preserve the same immutable revision/capability model and never wrap a tiny Play in a marketing landing page.

### 3. Establish authoritative account lifecycle

Complete #58 before account-backed creator publishing, durable cross-device private state, moderation appeals or store deletion depend on ad-hoc identity.

Anonymous consumption remains first-class.

### 4. Complete creation, trust and store gates

- #6 — Remix, Quick Create and resilient media/drafts;
- #7 — rights, provenance, moderation and safety controls;
- #16 — App Store / Play Store privacy and UGC compliance.

Preview and publication must use the production schema/runtime; no second renderer and no arbitrary creator code.

### 5. Prove supply quality

- #20 — editorial seed-content tooling using the same publication gates;
- #8 — 500–1,000 excellent, human-reviewed Plays and controlled-beta experiments.

Do not fill categories with mass-generated trivia. Every launch family needs convincing examples that show why an interactive feed is better than a passive feed.

### 6. Close launch operability

Complete #9 with real-device/network evidence, SLOs, crash/frame/media telemetry, rollback/kill switches, backup/restore validation and staged rollout.

## QA matrix

### First-use and navigation

- fresh install/browser;
- onboarding completed;
- onboarding skipped;
- reopen after onboarding;
- back from a later Play;
- swipe during every state;
- swipe immediately after incorrect answer;
- rapid repeated swipes;
- direct manipulation then swipe;
- Save/More/Share action overlays do not steal feed gestures.

### Play behavior

- representative Guess, Choose, Solve, Play and Discover examples;
- objective answer, incorrect answer and retry;
- preference choice without manufactured correctness;
- Discover without forced quiz;
- audio replay and mute behavior;
- video first frame/poster/failure;
- canvas/drag/piano interaction;
- reduced-motion behavior.

### Failure and recovery

- slow/high-latency network;
- temporary offline;
- server timeout/5xx;
- stale/expired cursor;
- media derivative failure;
- process death/background-resume;
- browser reload;
- duplicate realtime/event delivery;
- retry of durable actions;
- local database migration/storage failure without destructive quarantine of healthy data.

### Accessibility

- large text/display scaling;
- VoiceOver and TalkBack on representative Plays;
- Flutter web screen-reader semantics;
- keyboard navigation where supported;
- non-color-only result state;
- captions/transcripts;
- non-drag alternative for manipulation;
- reduced motion;
- target sizing and focus order.

### Performance

- 30+ minute representative swipe session;
- 100+ Play churn test in automated/integration environment;
- bounded page/media/cache/controller counts;
- no stale callback mutations after rapid navigation;
- physical 60 Hz and 120 Hz profiling;
- cold/warm media first-frame evidence;
- audio readiness/route checks;
- decorative effects disabled/degraded before core interaction when budgets are exceeded.

## Launch gates

Mixli does not enter a public/controlled launch merely because the happy path works. The following must all be true:

- A first-time user understands the opening Play without a tutorial.
- The opening feed demonstrates at least two visibly different interaction types within representative supply.
- Swipe never depends on the network and never becomes trapped.
- Consumer actions are semantically distinct, durable and retry-safe.
- Interaction-derived ranking remains interpretable and rebuildable; explicit mutes are authoritative.
- Search provides intentional topic/learning/Play discovery without silently rewriting permanent preferences.
- Realtime/event reconciliation is calm and duplicate-safe.
- All five Play families have high-quality human-reviewed examples; no mass-generated filler.
- Realtime, media, network and local-recovery failure paths are designed and tested.
- Accessibility parity is evidenced on native and web targets.
- Physical frame/media/audio evidence satisfies the owning performance gates.
- Safety/reporting, provenance, rights, moderation and store privacy/deletion requirements exist before public UGC.
- Canonical analytics measure played impressions, meaningful actions, dismissals, saves, shares, repeats, reports, search success and interaction-format affinity without optimizing raw compulsive session time as the governing objective.

## Remaining product decisions to resolve before production

Several foundational choices are already made: shared Flutter/Dart runtime, PostgreSQL system of record, S3-compatible media architecture, immutable Play revisions and anonymous-first identity. Do not reopen them without measured evidence.

Still resolve explicitly before the relevant launch tranche:

- exact supported physical device/browser matrix and minimum OS/browser policy;
- account/auth provider behind the provider-neutral boundary;
- whether any dedicated realtime transport is justified beyond current durable request/event semantics;
- cold-start/wildcard ranking boundaries and exploration/fatigue policy;
- creator permissions, provenance review and moderation operating workflow;
- platform audio/haptic fallbacks and accessibility behavior;
- whether notifications ship in the first beta—if so, only sparse user-requested cases;
- final analytics retention/privacy boundaries and explicit guardrails against optimizing unhealthy session length.

## Review evidence

Every release claim should point to evidence, not aspiration:

- **contract evidence** — schema/API/runtime tests;
- **interaction evidence** — widget/golden/gesture/accessibility tests;
- **platform evidence** — Chrome/web, Android and iOS build/runtime gates;
- **physical evidence** — frame rate, audio route, screen reader and device/network smoke where required;
- **content evidence** — human-reviewed Play inventory and publication metadata;
- **operational evidence** — dashboards, SLOs, restore drill, kill switches and staged rollout;
- **trust evidence** — report/moderation/rights/deletion/store flows on the actual release build.

A checkbox without current evidence is not a launch gate passed.

## Definition of done

Mixli is experience-ready when it feels like a polished, calm, playful instrument: content is beautiful, the action is obvious, feedback is immediate, motion is purposeful, state reconciliation is trustworthy, accessibility is native to the interaction, resources remain bounded, and the user can always swipe away.

Before accepting any surface ask:

> **Can a first-time user know what to do by seeing and touching it, without reading an explanation?**

If a feature needs a paragraph to justify or operate it, it is not ready for the feed.

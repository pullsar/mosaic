# Mosaic

> **The feed you play.**

Mosaic is a personalized feed of tiny interactive experiences built around what a person is into and what they want to learn. Every Play can be dismissed immediately or engaged as a small **Guess, Choose, Solve, Play, or Discover** experience.

Examples: identify a beautiful place from a short clip, play back a piano phrase, solve a visual puzzle, choose a four-day getaway under real constraints, recognize an artwork, or answer a compact quiz about an interest.

Mosaic is not a course product and not a passive short-video clone.

## Core loops

```text
FIND → PLAY → REACT → SWIPE
```

```text
SEE → REMIX → PUBLISH → OTHERS PLAY
```

```text
PLAY → SHARE → RECIPIENT PLAYS → RESPONDS / CONTINUES
```

A shared public Play works in the browser before the recipient installs Mosaic.

## Product principles

- **The Play is the interface.** Content and direct interaction dominate chrome and copy.
- **Visual first.** Consumer Play surfaces target roughly 88% primary content/supporting visuals, 9% controls/motion, and 3% visible text as an attention heuristic.
- **Play, don't prescribe.** No forced routines, lessons, streak pressure, or completion gates.
- **Interests and learning intent are separate.** Mosaic learns both what users enjoy and what they want to know more about.
- **Swipe is freedom.** Any Play can be dismissed instantly.
- **Value before registration.** Anonymous users can play first.
- **Creation is the moat.** Templates, remix lineage, resilient media tooling, and a constrained Play runtime make interactive creation cheap enough to compound.
- **The Play is the viral object.** Shares open into a playable experience, not an install wall.
- **Quality over generated volume.** AI may assist creators; it does not author an unsourced feed.
- **Rights follow lineage.** Structure, text, and media reuse rights are enforced separately.
- **No adult content.** No adult, erotic, or sexually explicit content mode.

## Technology

Client/runtime: **Flutter + Dart**.

Architecture:

```text
Play data
  ↓
play_schema     # pure Dart
  ↓
play_engine     # pure Dart
  ↓
play_flutter    # Flutter renderers
  ↓
iOS / Android / Web
```

The Flutter choice is product-specific: Mosaic needs predictable, highly controlled media, gesture, animation, drawing, and audio interactions across native and shared-web surfaces.

## Launch surface

**Play · Saved · Create · Me**

Formats:

1. **Guess** — identify a place, sound, object, period, dish, language, etc.
2. **Choose** — preference decisions with meaningful constraints.
3. **Solve** — compact logic, spatial, word, route, or pattern challenges.
4. **Play** — manipulate sound, maps, rhythm, drawing, sequencing, and objects.
5. **Discover** — art, culture, travel, nature, history, faith, or curiosity where forced gamification would weaken the experience.

## Documentation

### Product and experience

- [`docs/product-spec.md`](docs/product-spec.md) — product contract and v1 scope.
- [`docs/experience-design-spec.md`](docs/experience-design-spec.md) — feed/onboarding/interaction behavior.
- [`docs/visual-language-and-copy-spec.md`](docs/visual-language-and-copy-spec.md) — content hierarchy, 88/9/3 attention budget, typography, motion, and copy rules.
- [`docs/growth-and-sharing-spec.md`](docs/growth-and-sharing-spec.md) — browser-playable sharing, challenges, deep links, and growth measurement.
- [`docs/identity-and-account-lifecycle-spec.md`](docs/identity-and-account-lifecycle-spec.md) — anonymous-first identity, account merge, reset, and deletion.

### Runtime, ranking, and creation

- [`docs/play-runtime-spec.md`](docs/play-runtime-spec.md) — Play schema, state machine, media/input primitives, and runtime constraints.
- [`docs/play-schema-evolution.md`](docs/play-schema-evolution.md) — schema-version support, client capabilities, conformance fixtures, and deprecation policy.
- [`contracts/play-v1.schema.json`](contracts/play-v1.schema.json) — language-neutral Play v1 wire contract.
- [`contracts/client-capabilities-v1.schema.json`](contracts/client-capabilities-v1.schema.json) — language-neutral client capability envelope.
- [`docs/creator-platform-spec.md`](docs/creator-platform-spec.md) — Remix, Quick Create, Studio, templates, lineage, and creator supply.
- [`docs/recommendation-and-analytics-spec.md`](docs/recommendation-and-analytics-spec.md) — interest/learning/interaction graphs, ranking, events, and metrics.
- [`docs/media-pipeline-spec.md`](docs/media-pipeline-spec.md) — capture/import, resumable upload, normalization, delivery, and rights metadata.

### Trust and engineering

- [`docs/trust-rights-and-moderation-spec.md`](docs/trust-rights-and-moderation-spec.md) — remix rights, factual trust, moderation, takedown, appeals, and abuse resistance.
- [`docs/operability-and-slo-spec.md`](docs/operability-and-slo-spec.md) — observability, SLOs, flags, rollback, incidents, and launch operations.
- [`docs/platform-runtime-and-release-gotchas.md`](docs/platform-runtime-and-release-gotchas.md) — Flutter/web/media lifecycle, permissions, store compliance, offline recovery, and release-device gates.
- [`docs/dependency-and-platform-decisions.md`](docs/dependency-and-platform-decisions.md) — Flutter stack, approved dependencies, abstraction boundaries, and dependency policy.
- [`docs/play-performance-profiling.md`](docs/play-performance-profiling.md) — physical 60/120 Hz Play profiling protocol, frame budgets, first-frame and audio-readiness evidence.
- [`docs/implementation-plan.md`](docs/implementation-plan.md) — staged implementation and validation gates.

## Current status

**Foundation and the core M1 declarative Play renderer are merged.**

The repository now includes the Flutter workspace/schema-engine foundation, capability negotiation, API/data foundation, lifecycle/permissions/privacy baseline, bounded process-death recovery, and production image/video/audio/canvas Play rendering. Issue #3 remains open only for the focused visual-regression/profiling acceptance tranche before the roadmap widens further into the consumer loop.

## Controlled-beta test

A feature belongs in the first release only if it materially improves:

```text
FIND → PLAY → REACT → SWIPE
```

or

```text
SEE → REMIX → PUBLISH → OTHERS PLAY
```

or

```text
PLAY → SHARE → RECIPIENT PLAYS
```

Everything else waits.

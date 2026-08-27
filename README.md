# Mosaic

> **The feed you play.**

Mosaic is a personalized feed of tiny interactive experiences built around what a person is into and what they want to learn. Every swipe can be dismissed immediately or engaged as a small **Guess, Choose, Solve, Play, or Discover** experience.

Examples include identifying a beautiful place from a short clip, playing back a piano phrase, solving a spatial puzzle, choosing a four-day getaway under specific constraints, recognizing an artwork, or answering a compact quiz about an interest.

Mosaic is not a course product and not a passive short-video clone.

## Core loops

Consumer:

```text
FIND → PLAY → REACT → SWIPE
```

Creator:

```text
SEE → REMIX → PUBLISH → OTHERS PLAY
```

Growth:

```text
PLAY → SHARE → RECIPIENT PLAYS → RESPONDS / CONTINUES
```

A shared public Play should work in the browser before the recipient installs Mosaic.

## Product principles

- **Play, don't prescribe.** No forced routines, lessons, streak pressure, or completion gates.
- **Interests and learning intent are separate signals.** Mosaic learns both what users already enjoy and what they want to know more about.
- **Swipe is freedom.** Any Play can be dismissed instantly.
- **Interaction beats passive consumption.** Short clips, images, audio, maps, and animation become playable media where appropriate.
- **Value before registration.** Anonymous users can play before creating an account.
- **Creation is the moat.** Remixable templates, resilient media capture/upload, and a constrained interaction runtime make interactive creation cheap enough to compound.
- **The Play is the viral object.** Shares open directly into a playable experience, not an install wall.
- **Quality over generated volume.** AI may assist creators, but factual content is source-backed and creator-approved.
- **Rights follow lineage.** Structure remix rights and media reuse rights are enforced separately.
- **No adult content.** Mosaic has no adult, erotic, or sexually explicit content mode.

## Launch surface

Primary navigation:

**Play · Saved · Create · Me**

Launch Play formats:

1. **Guess** — identify a place, sound, object, period, dish, language, etc.
2. **Choose** — make situated preference decisions with real constraints.
3. **Solve** — compact logic, spatial, word, route, or pattern challenges.
4. **Play** — manipulate sound, maps, rhythm, drawing, sequencing, or other direct interactions.
5. **Discover** — worthwhile art, culture, travel, nature, history, faith, or curiosity content where forced gamification would weaken the experience.

## Documentation

### Product and experience

- [`docs/product-spec.md`](docs/product-spec.md) — product contract and v1 scope.
- [`docs/experience-design-spec.md`](docs/experience-design-spec.md) — feed behavior, onboarding, interaction patterns, copy, accessibility, and performance rules.
- [`docs/growth-and-sharing-spec.md`](docs/growth-and-sharing-spec.md) — browser-playable sharing, challenges, deep links, and growth measurement.
- [`docs/identity-and-account-lifecycle-spec.md`](docs/identity-and-account-lifecycle-spec.md) — anonymous-first identity, account merge, reset, and deletion behavior.

### Runtime, ranking, and creation

- [`docs/play-runtime-spec.md`](docs/play-runtime-spec.md) — Play schema, state machine, media/input primitives, and runtime constraints.
- [`docs/creator-platform-spec.md`](docs/creator-platform-spec.md) — Remix, Quick Create, Studio, templates, lineage, and creator supply loop.
- [`docs/recommendation-and-analytics-spec.md`](docs/recommendation-and-analytics-spec.md) — interest/learning/interaction graphs, ranking, events, and success metrics.
- [`docs/media-pipeline-spec.md`](docs/media-pipeline-spec.md) — capture/import, resumable upload, media normalization, CDN delivery, and rights metadata.

### Trust and engineering

- [`docs/trust-rights-and-moderation-spec.md`](docs/trust-rights-and-moderation-spec.md) — remix rights, factual trust, moderation, takedown, appeals, and abuse-resistant reputation.
- [`docs/operability-and-slo-spec.md`](docs/operability-and-slo-spec.md) — observability, SLOs, feature flags, rollback, incident response, and launch operations.
- [`docs/dependency-and-platform-decisions.md`](docs/dependency-and-platform-decisions.md) — approved open-source shortlist, adoption stages, abstraction boundaries, and dependency policy.
- [`docs/implementation-plan.md`](docs/implementation-plan.md) — staged implementation and validation gates tying all specifications together.

## Current status

**Specification / pre-implementation.**

Implementation begins with the Play schema/engine and operational foundation, then a high-quality native vertical slice, anonymous personalized feed, and browser-playable sharing before widening creator supply.

## Controlled-beta test

A feature belongs in the first release only if it materially improves one of these:

```text
FIND → PLAY → REACT → SWIPE
```

```text
SEE → REMIX → PUBLISH → OTHERS PLAY
```

```text
PLAY → SHARE → RECIPIENT PLAYS
```

Everything else waits.

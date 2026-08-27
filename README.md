# Mosaic

> **The feed you play.**

Mosaic is a personalized feed of tiny interactive experiences built around what a person is into and what they want to learn. Every swipe can be dismissed immediately or engaged as a small **Guess, Choose, Solve, Play, or Discover** experience.

Examples include identifying a beautiful place from a short clip, playing back a piano phrase, solving a spatial puzzle, choosing a four-day getaway under specific constraints, recognizing an artwork, or answering a compact quiz about an interest.

Mosaic is not a course product and not a passive short-video clone. The core loop is intentionally small:

```text
FIND → PLAY → REACT → SWIPE
```

The supply loop is equally important:

```text
SEE → REMIX → PUBLISH → OTHERS PLAY
```

## Product principles

- **Play, don't prescribe.** No forced routines, lessons, streak pressure, or completion gates.
- **Interests and learning intent are separate signals.** Mosaic learns both what users already enjoy and what they want to know more about.
- **Swipe is freedom.** Any Play can be dismissed instantly.
- **Interaction beats passive consumption.** Short clips, images, audio, maps, and animation become playable media where appropriate.
- **Creation is the moat.** Remixable templates and a constrained interaction runtime make interactive creation fast enough to become a network effect.
- **Quality over generated volume.** AI may assist creators, but factual content is source-backed and creator-approved.
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

- [`docs/product-spec.md`](docs/product-spec.md) — product contract and v1 scope.
- [`docs/implementation-plan.md`](docs/implementation-plan.md) — staged implementation and validation gates.
- [`docs/play-runtime-spec.md`](docs/play-runtime-spec.md) — Play schema, state machine, media/input primitives, and runtime constraints.
- [`docs/creator-platform-spec.md`](docs/creator-platform-spec.md) — remix, Quick Create, Studio, templates, lineage, and creator supply loop.
- [`docs/recommendation-and-analytics-spec.md`](docs/recommendation-and-analytics-spec.md) — interest/learning/interaction graphs, ranking, events, and success metrics.
- [`docs/experience-design-spec.md`](docs/experience-design-spec.md) — feed behavior, onboarding, interaction patterns, copy, accessibility, and performance rules.

## Current status

**Specification / pre-implementation.**

Implementation should begin with the Play schema/runtime and a small vertical slice of high-quality Plays before adding social, monetization, advanced creator economics, or large-scale generated inventory.

## v1 test

A feature belongs in v1 only if it materially improves one of these two loops:

```text
FIND → PLAY → REACT → SWIPE
```

```text
SEE → REMIX → PUBLISH → OTHERS PLAY
```

Everything else waits.

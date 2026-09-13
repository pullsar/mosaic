# Replayable games implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Use `subagent-driven-development` only when the user selects delegated execution. Steps use checkbox syntax for tracking.

**Goal:** Deliver trustworthy, replayable Mixli games with curated sound/visual themes, meaningful favorites, and playable sharing.

**Architecture:** Extend `play_schema → play_engine → play_flutter` and the existing app/API, media, and durable-state boundaries. Freeze each round's task media and resolved presentation; separate immutable publication, attempt state, and user preferences. Introduce new capabilities only with matching server/Dart validation and fallback supply.

**Tech Stack:** Flutter/Dart, Fastify/TypeScript, PostgreSQL, current native local-state/SQLite and web IndexedDB stores, existing SoLoud adapter, managed media pipeline.

---

## Baseline and scope

Planning baseline: `origin/main` at `45b68d53da05104b8ca62626850f98d39842a980`; approved audit at `d69e3e52ac00748516dd0c41fd16a840c0bcf91b`. Fetched main again on 2026-09-10; it was unchanged. These plans extend [the approved design](../specs/2026-09-10-game-experience-audit-and-design.md), including the user's music/SFX/background requirement.

This is a program of separate PRs, not one implementation branch. Detailed tasks, file ownership, contracts, test cases, and commands are in the linked workstream plans. Implementation must reconcile each proposed signature against the immediately preceding merged tranche; names marked Create describe new files, not existing APIs.

| Order / PR boundary | Plan | Depends on | Reviewable outcome |
| --- | --- | --- | --- |
| P0 | Toolchain gate below | None | Correct SDK and baseline evidence |
| P1 | [Catalog repair](2026-09-10-games-01-catalog-integrity.md) | P0 | Defensible answers and accurate solved artwork; defective content retired without mutating old revisions |
| P2 | [Replay and terminal behavior](2026-09-10-games-03-replay-saved-sharing.md), tasks R1–R2 | P1 | Explicit replay, non-inert completion, unique attempt ownership |
| P3 | [Theme metadata and selection](2026-09-10-games-02-sound-and-themes.md), tasks A1–A2 | P2 | Approved pack definitions, deterministic random selection, explicit preference |
| P4 | [Audio ownership and feedback](2026-09-10-games-02-sound-and-themes.md), tasks A3–A5 | P3 | One bounded mix owner, audible keys, music/SFX controls, interruption safety |
| P5 | [Saved and family rounds](2026-09-10-games-03-replay-saved-sharing.md), tasks R3–R5 | P2/P3 | Local-first saved revisions, fresh rounds, six reorderable family pins |
| P6 | [Scene primitives and first games](2026-09-10-games-04-capabilities-and-generation.md), tasks G1–G3 | P1–P5 | One Move, Quiet Switch, Echo Architect quality pilot |
| P7 | [Playable links and challenges](2026-09-10-games-03-replay-saved-sharing.md), tasks R6–R7 | P2/P3/P5; P6 for new primitives | Same-round anonymous browser play; server-held friend reveal |
| P8 | [Timed magic](2026-09-10-games-04-capabilities-and-generation.md), task G4 | P6/P7 | Sleight, then tracking/rule tasks, with honest interruption behavior |
| P9 | [Generation/editorial release](2026-09-10-games-04-capabilities-and-generation.md), tasks G5–G7 | Prior mechanism gates; #6/#7/#20 | Validated theme-aware generated rounds, reviewed publication, remaining portfolio |

P4 and P5 can be worked in separate branches after their dependencies land. This is a dependency observation, not an instruction to spawn agents. Do not couple the first playable improvements to live multiplayer, account launch, a new game framework, or model-provider selection.

## P0: Prepare exact tooling and preserve the baseline

**Inspect:** `pubspec.yaml`, `pubspec.lock`, `ops/production/flutter/Dockerfile`, `ops/production/bin/server-ci.sh`, `.github/workflows/`, `apps/api/package.json`.

- [ ] Read the repository AGENTS.md and relevant owning issue before each implementation PR. Start from latest intended main in an isolated checkout; preserve unrelated work.
- [ ] Use the checked-in Flutter 3.44.7 builder or a matching isolated SDK with Dart >=3.12. Do not downgrade constraints to fit the global Dart 3.9.2 installation.
- [ ] Verify Node 24.x, resolve locked dependencies, and record versions and commit SHA. Do not silently upgrade flutter_soloud from locked 4.1.7.

Run from repository root in the compatible environment:

```bash
flutter --version
dart --version
node --version
flutter pub get --enforce-lockfile
pnpm install --frozen-lockfile
git status --short
```

Expected: accepted SDK versions, successful lockfile resolution, and no unexpected lockfile edits. If resolution fails, diagnose the toolchain before running tests. The earlier audit's unsuccessful tests are environment evidence, not a failing-code baseline.

- [ ] Run the unmodified baseline's applicable suites once. Record pre-existing failures with reproduction; do not weaken tests or redefine expected product behavior to absorb them.

## Shared data and naming decisions

| Identity | Meaning | Owner |
| --- | --- | --- |
| `playId + revisionId` | Published immutable puzzle and task media | Existing Play/revision storage |
| `familyId + familyRevisionId` | Approved mechanic and list of already published rounds | New family manifest in the existing publication model |
| `attemptId` | One run, including replay/practice state | App session wrapper around pure engine state |
| `themeId + themeRevisionId + variantId` | Frozen approved decorative treatment | Theme manifest resolved when preparing the round |
| `challengeId` | Bounded friend context and reveal policy | API; outside the immutable Play |

Do not rename the engine's existing `attempts` field opportunistically: it currently counts transitions. Add separate round identity and wrong-answer count where needed, preserving old analytics interpretation.

Theme selection uses approved packs, not arbitrary colors/audio chosen independently. The user's explicit choice is preferred when compatible. Random choice selects uniformly from sorted compatible candidates, excludes the last two pack IDs when alternatives exist, and is resolved once. Replays and challenges use their frozen presentation identity. Silent/reduced-motion choices always remain available and may mark a challenge as practice when they materially alter the task.

## Sound and visual production brief

| Pack | Visual material | Optional bed | Functional effects |
| --- | --- | --- | --- |
| Paper Studio | Warm paper, felt, precise wooden pieces | Sparse neutral instrumental texture | Soft wood contact, felt placement, short dry confirmation |
| Night Museum | Deep neutral surfaces, spotlighted objects | Low-density atmospheric texture | Restrained ceramic/glass contact; no startling transients |
| Glass Garden | Pale mineral surfaces, botanical imagery outside task targets | Gentle nonverbal ambience | Small rounded taps and placement tones |
| Orbital | Crisp dark field, quiet metallic objects | Restrained synth texture without attention-grabbing pulses | Short muted mechanical clicks |

Minimum initial library: two reviewed visual variants and one finite 20–30 second bed per pack, plus a five-event effect set (`contact`, `place`, `resolve`, `save`, `reveal`). These are asset-production requirements; assets are not fabricated in these plans. No outcome uses a shame sound; `resolve` is neutral and content-specific reveals carry correctness. Add voice/narration only when content needs it, with captions/transcript and compatible ducking.

Controls: master Sound on/off near the Play utilities through progressive disclosure; Music and Effects switches plus Theme choice in the settings sheet. Task Hear/replay remains attached to the task object. Backgrounds are visual treatments independent of whether audio is enabled. Default music is off; effects require explicit sound activation. A silent first impression still contains immediate visual response.

## Cross-cutting budgets and failure behavior

- One active Play owner; one music bed; eight total voices; sixteen decoded sources and 24 MiB PCM for the active sound session. Initial finite beds avoid assuming codec-perfect loops.
- Preserve twelve retained feed items, three warmed next items, and existing metadata/image concurrency ceilings. Prepare one same-family round without opening a parallel unbounded cache; share capacity with the feed warmer.
- Optional sounds missing a 100 ms input deadline are dropped; repeated same-event SFX within 80 ms are suppressed. Never play delayed feedback on network recovery. Task sounds require explicit readiness/retry instead.
- Perceptual cues and pitch/rhythm input suppress optional music/effects. Cosmetic randomness never changes the answer, timing, difficulty, or target audio.
- Exit/background/interruption immediately invalidates callbacks and stops sound; restore UI state without restoring audio authorization. No cross-Play music crossfade in the initial release.
- Locally held saved metadata survives media eviction. Remote reads cannot erase newer pending save, unsave, or pin mutations.
- Themes unavailable because of media failure fall back to a pre-approved static neutral treatment. Do not silently substitute task media or publish an incomparable score.

These are initial engineering/product budgets, not claims of measured performance. Adjust only from recorded device evidence and update the tests/contract together.

## Verification and release gates

Every implementation task uses the red → green → final-diff sequence: add the specific regression, run it to demonstrate the missing behavior, implement the bounded change, rerun focused tests, then commit. A code block in a workstream is the specified contract/algorithm; production integration must also satisfy every listed test and lifecycle transition.

Run the exact checked-in gate for the final diff. Current core commands are:

```bash
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed .
flutter analyze
(cd packages/play_schema && dart test)
(cd packages/play_engine && dart test)
(cd packages/analytics_contract && dart test)
(cd packages/local_state && dart test)
(cd packages/event_delivery && dart test)
(cd packages/event_delivery && dart test --platform chrome test_web)
(cd packages/play_flutter && flutter test)
(cd packages/platform_contracts && dart test)
(cd packages/platform_flutter && flutter test)
(cd apps/mosaic_app && flutter test)
(cd apps/mosaic_app && flutter test --platform chrome test/consumer_local_state_web_test.dart)
pnpm --dir apps/api typecheck
pnpm --dir apps/api test
```

Database tests require the disposable PostgreSQL environment used by checked-in server CI; a skipped PostgreSQL test is not a pass. Never point migration/test commands at production. Use `.github/workflows/review-dispatch.yml` and `ops/production/bin/review-ci.sh` for PR checks; `ci-request.sh` accepts main ancestry and is not an arbitrary feature-branch shortcut.

For relevant changes, run the checked-in web release, Android release, and iOS simulator/release gates on their supported hosts. Existing physical evidence requirements remain: 60/120 Hz profile-mode devices, speaker/headphone/Bluetooth routes, interruption, VoiceOver/TalkBack, small screens, large text, and reduced motion. A 1024-frame buffer estimate is not touch-to-sound measurement.

- [ ] Record frame build/raster budget violations separately from total-span latency. Reuse `PlayPerformanceProbe`; extend its metrics without relabeling old values.
- [ ] Complete 100-Play churn, a 30-minute representative soak, delayed asset/metadata resolution, and repeated background/foreground scripts. Resource counts return to their expected idle level.
- [ ] Review opening action, wrong answer, reveal, replay, sound controls, Saved retrieval, and recipient play with first-time users. No instructions should be needed to infer the principal action.
- [ ] Publish no cognitive-benefit claim based on familiar-round scores. Measure new-round behavior and qualified recipient completions separately from replay and raw duration.
- [ ] Commit and push each coherent boundary, resolve review findings, update its owning issue with exact evidence, and keep manual gates visibly outstanding. Do not mark the entire beta complete because a pilot family works.

## Completion checklist for the program

- [ ] Current visible answers and solved objects agree.
- [ ] Replay, fresh rounds, saved revisions, and family pins work offline where assets are retained.
- [ ] Curated themes support compatible random or explicit selection without mid-round rerolls.
- [ ] Music/SFX/input audio behave as one bounded, interruptible system.
- [ ] One Move, Quiet Switch, Echo Architect, and Sleight each meet the quality pilot gate.
- [ ] Shared links play without signup and challenges preserve round identity and reveal policy.
- [ ] Generated content passes independent model checks and human content/media review.
- [ ] Remaining eight game concepts have passed their mechanic-specific tests before eligibility.
- [ ] Required CI, physical performance/audio, accessibility, rights, and moderation evidence is attached to the release.

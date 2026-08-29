# Mixli — Agent Instructions

Mixli is **the feed you play**. Build it inside the repository's actual Flutter + Dart architecture:

```text
play_schema → play_engine → play_flutter → iOS / Android / Web
```

The Play is the interface. Every feed item must give the user one immediate reason to **Guess, Choose, Solve, Play, or Discover** while preserving a declarative, immutable, capability-safe runtime.

These instructions apply repository-wide unless a more specific `AGENTS.md` exists below the file being changed.

## Product naming

- The product and user-facing app name is **Mixli**, never Mosaic.
- Do not introduce new user-facing `Mosaic` copy in product UI, metadata, documentation, examples, screenshots, store copy, or tests that assert visible product text.
- The repository slug `pullsar/mosaic`, source path `apps/mosaic_app`, Dart package/library identifiers, bundle/package identifiers, database names, existing `MOSAIC_*` environment variables, and other compatibility-sensitive technical identifiers are **legacy implementation names**. Do not rename them opportunistically. A technical identifier migration must be an explicit, end-to-end change with compatibility and deployment review.

## Source of truth and review discipline

Before changing behavior:

1. Read the relevant contract/spec under `docs/`, especially `product-spec.md`, `experience-design-spec.md`, `visual-language-and-copy-spec.md`, `play-runtime-spec.md`, `dependency-and-platform-decisions.md`, and `experience-readiness-plan.md`.
2. Inspect the complete call path, existing abstractions, tests, persistence path, lifecycle ownership, and platform adapters before adding a new abstraction.
3. Prefer extending an existing contract over adding parallel state, queues, renderers, media ownership, or persistence mechanisms.
4. Treat immutable published revisions, capability negotiation, idempotency, bounded resource ownership, privacy, and offline/recovery behavior as correctness requirements.
5. Keep a tranche coherent. Do not mix unrelated dependency, lockfile, schema, formatting, or workflow churn into the same change.

Do not infer repository reality from an old plan or issue comment. Verify current `main`, the owning issue, current contracts, and the exact code path first.

## Architecture guardrails

### `play_schema`

- Pure Dart only; no Flutter, network, storage, device, or UI dependencies.
- Own versioned declarative Play data, validation, capability-safe constraints, and immutable model semantics.
- Reject malformed, unsafe, ambiguous, or unsupported authored state early and deterministically.
- Do not encode screen-specific widget behavior or product chrome into the schema.

### `play_engine`

- Pure Dart and deterministic.
- Own Play state transitions and validation semantics, not rendering or I/O.
- Given the same immutable Play, state, capability set, and input, produce the same result.
- Keep transitions replayable/testable and free of hidden clocks, network calls, controller state, or platform side effects.

### `play_flutter`

- Render schema/engine state; do not fork product semantics into widgets.
- Own only ephemeral presentation/controller resources and release them deterministically.
- Keep gesture arbitration explicit so drag, piano, canvas, media controls, and other direct manipulation cannot accidentally page the feed or permanently steal feed swipe.
- Unsupported/malformed media or primitives must fail safely without crashing or trapping navigation.
- Accessibility semantics are part of every primitive, not a later overlay.

### App/API composition

- `apps/mosaic_app` composes the Mixli product around the shared runtime; do not build a second renderer for feed, preview, or sharing.
- Keep the feed window, prefetch, media warm set, event spool, caches, and local recovery state bounded.
- Release inactive video/audio/custom drawing resources quickly.
- Preserve `actorId` as a public pseudonymous identifier, never an authorization secret. Anonymous proof-of-possession and later account identity remain separate security concepts.
- Keep **interest**, **learning intent**, and **interaction affinity** as separate recommendation signals.
- **Save ≠ More Like This**. **Report ≠ Not interested**. **Mute creator ≠ Block**.
- Canonical events/preferences are source data; derived ranking state must remain idempotent, bounded, inspectable, and rebuildable.
- Do not add a second local mutation/event queue when the existing durable delivery path can own retries.

## Experience posture

- Land directly in a full-screen Play; never open on a dashboard, course, tutorial, or marketing explanation.
- Keep vertical swipe available from every Play state. Users may leave instantly, including after an incorrect answer.
- Give each viewport one dominant object, one clear action, and minimal supporting copy. Target roughly **88% content, 9% controls/feedback, 3% visible text** as an attention heuristic, never as an accessibility excuse.
- Preserve stable grammar: **Play · Saved · Create · Me**; quiet Save, Share, More controls; attribution secondary; Remix contextual.
- Use progressive disclosure: reveal only what is needed now, then offer one concise fact, comparison, or next action.
- Do not turn a Play into a mini website, form, passive video post, generic social dashboard, or lesson.

## Premium visual language

- Feel puffy, posh, playful, and refined—not childish.
- Prefer soft dimensional surfaces, precise spacing, restrained material/glass for transient controls, elegant media treatment, and calm chrome.
- Let content-specific color lead the viewport. Keep the system palette disciplined.
- No decorative gradients, blobs, stacked cards, badge clutter, engagement towers, or visual effects that exist only to look futuristic.
- Default to **Inter Variable** or the established product type system. Use Semibold prompts, Medium controls, Regular detail; never rely on Thin/Light functional text.
- Prefer familiar icons with accessible names. Keep controls thumb-reachable, generous enough to touch, and visually subordinate to the Play.

## Reactive motion, media, and realtime

- Use spring-like, interruptible motion where appropriate for swipe, answer lock, placement, reveal, save/share, audio, and hierarchy changes.
- Motion must explain cause/effect. Never use confetti, permanent bouncing, ambient animation, shame, streak pressure, or blocking celebration modals.
- Respond immediately with visual state change, sound, or subtle haptic before explanatory text.
- Protect **60 fps as a product requirement** and keep 120 Hz devices meaningfully smooth. Budget blur, clipping, shaders, repaint boundaries, and layered effects deliberately.
- Respect reduced motion and platform accessibility settings.
- Realtime/optimistic updates must reconcile without moving the user off the current Play, duplicate pulses/events, stale overwrite, flashing, or surprise audio.
- Connection/recovery state stays compact. Core interaction, dismissal, back, and retry must remain usable on poor networks and where locally available offline.
- Prefetch only a bounded next window. Render local composition first, primary media next, deferred assets last. Degrade decorative effects before the Play itself.

## Copy and content

- Prefer literal **2–6 word prompts**: `Where is this?`, `Pick one.`, `Play it back.`, `Look closer.`
- Reveal one useful fact, comparison, or next action by default; do not append a mini article.
- Respect content semantics. Do not manufacture a correct answer for preference, and do not force a quiz onto Discover.
- Sound human, intelligent, curious, calm, and specific.
- Avoid `Let's dive in`, `Great job!`, `Unlock`, `journey`, AI self-reference, fake urgency, motivational filler, and corporate padding.
- Faith is opt-in.
- Mixli has no adult, erotic, or sexually explicit content mode.
- User controls must include the appropriate Not interested, mute topic/creator, and Report paths as those owning tranches land.

## Accessibility and resilience

Every Play and consumer control must provide, where applicable:

- semantic structure and logical screen-reader order;
- accessible names for icon-only controls;
- captions/transcripts when audio or speech conveys meaning;
- scalable text and adequate contrast;
- non-color-only feedback;
- reduced-motion behavior;
- keyboard/non-gesture alternatives on supported surfaces;
- alternate operation for drag/custom-canvas interactions where needed.

Never let loading, media failure, network latency, optimistic reconciliation, or recovery remove swipe, dismissal, back, or retry. A normal warm swipe must not land on a blank blocking spinner.

## Performance and reliability rules

- Measure before adding expensive visual effects to feed-critical paths.
- Fence stale async callbacks so rapid swipes cannot mutate the new current Play.
- Bound caches, feed pages, warmed assets, concurrent requests, retries, queues, and background work explicitly.
- Preserve exact-retry idempotency for durable mutations/events.
- Close/file-sync/transaction behavior must fail without corrupting or quarantining healthy user data.
- Prefer safe curated/recovered supply over trapping the feed when ranking, transport, or media delivery is unavailable.
- Never autoplay unexpected audio; lifecycle resume must not imply permission to start manual/unmuted playback.

## Testing and CI

Use the repository's checked-in workflows as the authoritative gate. For changes that touch the relevant paths, reproduce the applicable commands from `.github/workflows/` rather than relying on memory.

The baseline repository gate currently includes:

```bash
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed .
flutter analyze

(cd packages/play_schema && dart test)
(cd packages/play_engine && dart test)
(cd packages/analytics_contract && dart test)
(cd packages/local_state && dart test)
(cd packages/event_delivery && dart test)
(cd packages/play_flutter && flutter test)
(cd apps/mosaic_app && flutter test)
```

Platform-sensitive changes also require the applicable checked-in gates, including real Chrome IndexedDB tests, platform contract/adapter tests, web release build, Android release build, and iOS simulator build.

Add focused regression coverage for the bug or invariant being changed. Prefer deterministic unit/widget/contract tests before broad integration tests; then run the exact-head gates required by the diff. Physical 60/120 Hz, screen-reader, audio-route, or store checks are not replaceable by hosted CI when the owning acceptance criterion explicitly requires real-device evidence.

## Git and PR discipline

- Branch from the exact latest intended `main` baseline.
- Keep one coherent architectural boundary per PR.
- Reuse existing abstractions before adding infrastructure.
- Do not weaken tests, safety checks, capability negotiation, validation, or CI to make a change pass.
- Run exact-head validation after the final code/document change.
- Resolve review threads and verify the final diff contains only intended files.
- Update the owning issue/tracker when implementation state changes.
- Do not mark a milestone complete while code, UI, migration, manual, physical-device, accessibility, or store acceptance remains outstanding.
- Never leave completed project work only in a local workspace: commit and push the intended branch/PR state.

## Shipping guardrail

Before shipping any surface ask:

> **Can a first-time user know what to do by seeing and touching it, without reading an explanation?**

If not, simplify the Play, copy, chrome, motion, or state model before adding more UI.

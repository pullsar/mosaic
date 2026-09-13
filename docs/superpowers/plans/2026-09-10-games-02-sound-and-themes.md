# Sound and themes implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Use `subagent-driven-development` only when the user selects delegated execution. Steps use checkbox syntax for tracking.

**Goal:** Give curated and generated games coherent visual/music/SFX themes, responsive instrument feedback, and reliable user-controlled sound.

**Architecture:** Immutable theme manifests reference managed media; a pure resolver chooses compatible presentation once. One Play sound session implements the existing `ManagedMediaHandle` and delegates every voice to the current SoLoud adapter; app preferences and foreground authorization remain outside Play documents.

**Tech Stack:** Dart/Flutter, locked flutter_soloud 4.1.7, TypeScript/PostgreSQL, FFmpeg, existing media delivery and local state.

---

## Dependencies and inspected constraints

Read [the program plan](2026-09-10-replayable-games.md) and approved audio extension. A1–A2 follow R1–R2; A3–A5 follow them. Review issues #3, #8, #17, #20, and #55. Before implementation inspect the actual installed 4.1.7 package source: current public documentation is not proof that a pinned API exists.

Current `AudioEngine` exposes load/play/schedule/stop/release only. `SoLoudAudioEngine` discards voice handles; `OwnedPlayAudio` owns a private serialized media handle. `ActiveMediaCoordinator.activate` replaces/releases its previous handle, so independent music and task-audio owners would stop each other. AAC-LC MP4 normalization currently sets codec/sample rate, not loudness or verified sample-accurate looping. Do not solve these gaps with a second audio singleton or arbitrary remote URLs.

## File ownership

| Action | Paths | Responsibility |
| --- | --- | --- |
| Modify | `packages/play_schema/lib/src/model.dart`, `validation.dart`, `capability.dart` | Optional family/presentation references and capability preservation |
| Modify | `packages/play_schema/test/play_schema_test.dart`, `immutability_test.dart`, `contract_artifacts_test.dart` | Round-trip and strict manifest/reference validation |
| Modify | `contracts/play-v1.schema.json`, `contracts/client-capabilities-v1.schema.json`, `apps/api/src/contracts/compatibility.ts` | Matching JSON/server capability contract |
| Create | `apps/api/src/game_theme.ts`, `apps/api/test/game_theme.test.ts` | Immutable manifests and pure compatibility/selection |
| Modify | `apps/api/src/repository.ts`, `app.ts`, `media_publication.ts` | Theme publication and resolved document delivery |
| Create | `apps/api/migrations/010_game_presentation.up.sql`, `010_game_presentation.down.sql` | Versioned family/theme registry, no user sound preferences in published Plays |
| Create | `apps/mosaic_app/lib/game_sound_preferences.dart`, `test/game_sound_preferences_test.dart` | Sound/theme preferences and transient authorization |
| Modify | `apps/mosaic_app/lib/consumer_local_state.dart`, `consumer_local_state_native.dart`, `consumer_local_state_web.dart`, `consumer_api_client.dart`, `main.dart` | Persistence and composition |
| Modify | `packages/platform_contracts/lib/platform_contracts.dart` | Additive per-voice interface |
| Modify | `packages/play_flutter/lib/src/soloud_audio_engine.dart` | Same adapter's voice gain/fade/stop and metrics |
| Create | `packages/play_flutter/lib/src/play_sound_session.dart`, `test/play_sound_session_test.dart` | Single bounded sound owner and pure event policy |
| Modify | `packages/play_flutter/lib/src/play_audio_renderer.dart`, `play_media_layer_renderer.dart`, `play_input_primitives.dart`, `play_media_identity.dart`, `play_surface.dart` | Session-backed task audio and piano events |
| Modify | `packages/play_flutter/test/play_audio_renderer_test.dart`, `play_media_audio_binding_test.dart`, `play_media_lifecycle_integration_test.dart`, `play_input_primitives_test.dart` | Lifecycle and input regressions |
| Modify | `apps/api/src/media_ffmpeg.ts`, `media_ffprobe.ts`, `media_normalization.ts`, `media_publication.ts` | Versioned sound-purpose derivative checks |
| Create | `apps/api/test/game_sound_publication.test.ts` | Pack readiness, rights, gain and duration gates |
| Modify | `docs/media-pipeline-spec.md`, `docs/play-runtime-spec.md`, `docs/play-performance-profiling.md` | Contracts and physical audio evidence |
| Create | `docs/game-theme-production.md` | Actual rights, mastering and pack review ledger |

Update the checked-in JSON schema/compatibility artifacts alongside Dart/server contracts; do not create a competing schema. Migration numbers are allocated against latest main during execution; if 010 is occupied, assign the next free number before publication and update dependent plans. Never rename a deployed migration.

## A1: Define immutable family and theme references

- [ ] Add contract fixtures for a legacy document, a valid themed document, unknown theme revision, malformed variant, and unsupported required capability. Assert round-trip preservation of `requiredPlatformFlags`, which the inspected Dart model currently drops.
- [ ] Run schema and API tests before implementation; expect missing-field preservation/validation assertions to fail. Preserve legacy v1 documents unchanged.
- [ ] Add typed optional references with exact JSON forms:

```json
{
  "gameFamily": {"id": "quiet-switch", "revisionId": "family_1"},
  "presentation": {
    "themeId": "paper-studio", "themeRevisionId": "theme_1",
    "variantId": "felt-ivory"
  }
}
```

References contain no user sound authorization, score, attempt ID, direct asset URL, or local settings. Registry records bind each variant to immutable managed background/bed/effect asset IDs, permitted family revisions, contrast/target-exclusion constraints, and suppression flags. Enforce bounded identifiers, unique assets, finite gains/durations, maximum source count, and explicit media kinds. Theme registry revocation can remove decorative delivery; it cannot silently replace task media.
- [ ] Persist registry revisions with unique `(id, revision_id)` and immutable payload hashes using existing publication transactions. Family manifests map approved published round references, capability requirements, and compatible theme revisions; they are not executable templates. Reject mutation of an existing identity with different canonical bytes.
- [ ] Add API publication tests: unsupported family/theme fails before eligibility; managed asset not ready/rights denied fails; legacy unthemed Play passes; current capability set round-trips; duplicate identical publication is idempotent.
- [ ] Run `(cd packages/play_schema && dart test)` and API typecheck/tests with database coverage. Commit with `feat: define immutable game presentation references`.

## A2: Resolve compatible themes once and persist preferences

- [ ] Create pure resolver tests for an empty pool, explicit compatible choice, incompatible choice, deterministic random choice, short pools, history exclusion, and frozen replay. Persist the four pack definitions from the program brief only after their assets pass A5; use asset-free neutral fixtures for metadata tests.
- [ ] Specify selection independently of rendering:

```text
resolvePresentation(frozen, preference, candidates, recentPackIds, randomWord)
  frozen present: verify exact revision; return it or decorative-unavailable
  pool := approved compatible candidates sorted by (themeId, revisionId, variantId)
  explicit preference compatible: choose from that pack's approved variants
  explicit preference incompatible: neutral; preserve preference
  random mode: exclude last two pack IDs if at least one candidate remains
  choose pack uniformly, then variant uniformly; persist exact result
  empty pool: neutral
```

Use rejection sampling for bounded uniform integer selection, not modulo bias. Supply random words from the round-preparation boundary; the resolver itself has no clock/network/global RNG. A generated round uses its recorded seed and versioned deterministic PRNG; an existing published round freezes its resolved presentation in the attempt/share descriptor, not by mutating the Play. Persist a choice before exposing the first frame. Future preference changes apply to a fresh round; replay offers the frozen original presentation subject to accessibility/mute overrides.

```ts
export function uniformIndex(size: number, nextWord: () => number): number {
  if (!Number.isInteger(size) || size < 1 || size > 65536) {
    throw new Error('invalid_choice_count');
  }
  const limit = Math.floor(4294967296 / size) * size;
  for (let attempts = 0; attempts < 128; attempts++) {
    const word = nextWord();
    if (!Number.isInteger(word) || word < 0 || word >= 4294967296) {
      throw new Error('invalid_random_word');
    }
    if (word < limit) return word % size;
  }
  throw new Error('random_source_exhausted');
}
```

On the bounded RNG failure, round preparation uses neutral presentation and records a diagnostic; never hang the feed. Test rejection with `[4294967295, 4]` at size 3, expecting index 1.
- [ ] Store `masterMuted`, `musicEnabled`, `effectsEnabled`, and theme choice in existing native/web preference metadata, defaulting music off. Keep `foregroundSoundAuthorized` and task-specific authorization in memory. Existing unversioned/partial settings migrate by defaults without losing other preferences.
- [ ] Compose an accessible sound icon and a compact sheet: `Sound`, `Music`, `Effects`, `Theme`, `Random`, pack names. Each toggle has an explicit on/off semantic value. Keep sheet dismissal/swipe and large text usable. Avoid explanatory UI copy.
- [ ] Test restart preserves preferences but clears authorization; choosing another pack cannot alter an in-progress round; unavailable chosen pack uses neutral treatment and retains the user's choice. Run app native and real Chrome local-state tests plus resolver tests; commit with `feat: select stable game themes and sound preferences`.

## A3: Extend the existing adapter and establish one sound owner

- [ ] Inspect pinned 4.1.7 source and compile a minimal adapter test against its actual play/voice/fade signatures. If a required API is absent, propose a separately reviewed dependency change; do not write code against `latest` docs or switch engines. Initial beds may play once, so a verified loop API is not a launch dependency.
- [ ] Add an additive interface to platform_contracts; existing `AudioEngine` callers remain source-compatible. The opaque token prevents widgets from owning native handles:

```dart
final class AudioVoice {
  const AudioVoice(this.id);
  final int id;
}

abstract interface class VoiceAudioEngine implements AudioEngine {
  Future<AudioVoice> startVoice(String assetId, {double gain = 1});
  Future<void> setVoiceGain(AudioVoice voice, double gain);
  Future<void> fadeVoice(AudioVoice voice, double gain, Duration duration);
  Future<void> stopVoice(AudioVoice voice);
}
```

Validate finite gain in [0,1] and bounded nonnegative fade duration. Map wrapper IDs to current native handles; stopped/released/expired tokens are harmless no-ops. Keep legacy `play`, `schedule`, `stop`, and `release` on the same underlying sources and engine. Cleanup removes token mappings even after native errors.
- [ ] Add fake-engine tests before implementing `PlaySoundSession`: one bed/eight voices/sixteen sources/24 MiB decoded PCM; task capacity takes priority; optional oldest effect can be evicted, task notes cannot; release is idempotent; late load after release cannot play; fade completion after replacement cannot touch a new voice. Derive decoded budget from validated duration × sample rate × channels × bytes per decoded sample, with a measured conservative adapter overhead allowance.
- [ ] Implement the session as the single `ManagedMediaHandle` for the active Play. Lease identity includes immutable play/revision and R1 attempt ID. Serialize initialization/release, fence completions by generation, and await old source release before reusing a source identity. Pass the same session into piano and task-audio rendering. A session-backed `OwnedPlayAudio` path must not call coordinator.activate independently.

```text
inactive -> prepare: lease acquired, bounded task sources loaded
prepare -> ready: sources validated; no automatic audio authorization
ready + authorized cue: start voice under session budget
any + deactivate/mute/interruption: invalidate epoch, stop voices, clear authorization
any + release: drain owned loads, release sources, release exact coordinator handle
```

Initially themed families cannot contain `video_clip`: video and sound need a reviewed composite owner before simultaneous use. Unthemed video keeps its existing path. Do not change the coordinator into an unbounded registry.
- [ ] Run platform_contracts and play_flutter audio/lifecycle tests; assert coordinator ownership after rapid Play A→B→A and replay A→A. Verify no two sources play after ownership transfer. Commit with `feat: add bounded Play sound sessions`.

## A4: Bind functional audio and interruption policy

- [ ] Add event-policy tests using task phase, sound class (`task`, `music`, `effect`), readiness, preferences, authorization and elapsed input time. Use this truth table:

| Condition | Task audio | Music | Effects |
| --- | --- | --- | --- |
| Master muted | Silent; task waits or explicit alternate mode | Silent | Silent |
| No foreground sound authorization | Explicit `Hear` gesture only | Silent | Silent |
| Pitch/rhythm response or perceptual cue | Authorized task media only | Suppressed | Suppressed |
| Narration outside perceptual phase | Authorized speech | Duck to reviewed gain | Suppress masking events |
| Background/interrupted/inactive | Stop | Stop | Stop |
| Source not ready | Keep explicit retry/readiness | Drop | Drop |
| Optional SFX >100 ms late | Unaffected | Unaffected | Drop |

Sound on authorizes optional foreground sound; Hear authorizes that task's audio. Neither persists across background, route loss, interruption, or master mute. OS audio focus and browser context resume success are prerequisites, not inferred from a stored preference. Resume requires another intentional gesture. A mobile route callback that cannot be observed through the current adapter is a platform-contract task, not permission to claim interruption support.
- [ ] Connect `PlayPianoInput._press` to a typed note event supplied by the current session. Preload the bounded required notes before enabling scored input; keep immediate visual key depression even when silent. Pointer-down starts the note, release ends/sustains according to the authored bounded envelope, and repeated keys/polyphony obey the budget. Recording the sequence stays in the deterministic input path.
- [ ] Add widget tests: a key triggers exactly one matching task note, current sequence remains identical with effects off, rapid duplicate pointers do not duplicate logical notes, swipe cancels held notes, and a stale key-up cannot stop a new attempt's voice. Pitch identification is the initial shipped mode; timestamp-based rhythm scoring waits for G4 physical latency evidence.
- [ ] Bind contact/place/resolve/save/reveal once to actual state transitions. Optimistic save gets one local effect; server acknowledgment never repeats it. Errors use immediate visual state; no negative sound or interrupting completion fanfare. Suppress same optional event within 80 ms using the session's injected monotonic timing adapter.
- [ ] Implement spring-like visual answer lock/placement and short interruptible transitions with reduced-motion immediate equivalents. Sound does not delay visual state or block swipe. Run input/audio/media lifecycle tests and app sound-preference tests; commit with `feat: bind task audio and sound controls`.

## A5: Curate, master, and verify the four packs

- [ ] Produce the program brief's actual asset inventory and rights ledger in `docs/game-theme-production.md`: creator/source, license and redistribution/remix permission, immutable asset hash, theme revision, variant, usage purpose, duration, transcript where applicable, reviewer, and readiness result. Do not purchase or externally publish assets as part of local validation.
- [ ] Master finite beds as initial targets at approximately -24 LUFS integrated and <=-3 dBTP; short effects require measured peak plus listening review because integrated LUFS is unstable on very short clips. Start effects at <=-6 dBTP and test the maximum allowed simultaneous mix. These are review targets, not a guaranteed loudness standard or a cognitive intervention. Device listening can require lower gains.
- [ ] Add a new versioned derivative purpose/processor for reviewed game sound; preserve existing processor behavior and hash identity. Use two-pass `loudnorm` for suitable beds, parse measured loudness/true peak, and reject nonfinite/absent metadata, excess duration, unexpected channel count, or clipping. Store measurements and approved gain with the derivative. Existing speech/task normalization remains separately versioned.
- [ ] Add publication regressions: revoked rights, unready asset, excess PCM estimate, missing required note, unapproved theme variant, and insufficient visual contrast prevent eligibility; missing optional bed uses approved silent/static fallback. The managed resolver remains the only URI source.
- [ ] Listen to each pack with each permitted family on speakers, headphones, and Bluetooth. Confirm there is no audible seam requirement for initial finite beds, no target-colored background ambiguity, and no music masking. Pin or skip any combination that fails; randomness chooses only from the reviewed compatibility matrix.
- [ ] Measure touch-to-sound externally on representative native and web devices, including cold/warm audio activation. Record hardware, route, software SHA, distribution and failures; a suggested warm native target is p95 <=50 ms, web <=80 ms for optional feedback. Rhythm eligibility requires its own calibrated jitter/latency gate, not these cosmetic thresholds. Preserve quiet visual play on unsupported routes.
- [ ] Run changed-path media/API tests, complete web/Android/iOS gates, and record the physical evidence required by the program plan. Commit with `feat: publish reviewed game theme packs`. Do not mark pack readiness complete using fixtures or generated filenames alone.

## Research informing this design

Browser sound requires intentional activation and handling a suspended audio context: [MDN Web Audio best practices](https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API/Best_practices) and [autoplay guidance](https://developer.mozilla.org/en-US/docs/Web/Media/Guides/Autoplay). This supports separating persisted preference from ephemeral authorization.

FFmpeg documents loudness normalization, including measured-input linear normalization: [loudnorm](https://ffmpeg.org/ffmpeg-filters.html#loudnorm). The proposed mastering targets above are Mixli production choices.

The current SoLoud docs describe individual voice controls: [SoLoud API](https://pub.dev/documentation/flutter_soloud/latest/flutter_soloud/SoLoud-class.html). A3 deliberately verifies the repository's pinned release before implementation; this latest-documentation link is not compatibility evidence for 4.1.7.

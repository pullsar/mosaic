# Game capabilities and generation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Use `subagent-driven-development` only when the user selects delegated execution. Steps use checkbox syntax for tracking.

**Goal:** Ship the twelve approved games through a small verified runtime vocabulary and a curated, solver-checked generation pipeline.

**Architecture:** Extend declarative scene/input/validation contracts in lockstep across schema, pure engine, shared Flutter renderer and server compatibility. Generate bounded data for reviewed family versions; publish immutable rounds only after independent validation and production-renderer review.

**Tech Stack:** Dart/Flutter, TypeScript, existing canvas/media/publication pipeline, deterministic pure generators and solvers.

---

## Dependencies and exclusions

Read [the program plan](2026-09-10-replayable-games.md), [approved design](../specs/2026-09-10-game-experience-audit-and-design.md), `docs/play-runtime-spec.md`, `docs/play-schema-evolution.md`, `docs/creator-platform-spec.md`, and owning issues #3/#6/#7/#8/#10/#17/#20. G1–G3 follow replay, curated themes/audio, and family rounds. G4 follows stable sharing/challenges. G5–G7 follow the mechanics they publish.

The initial quality pilot contains at least six human-reviewed rounds each for One Move, Quiet Switch, and pitch-only Echo Architect. Sleight adds six after its timed-cue gate. These 24 rounds demonstrate craft; they do not satisfy the repository's full beta supply milestone. Generation does not excuse weak task design, unreliable art, or unlicensed sound.

No generated code, scripts, shaders, arbitrary network requests, new game framework, universal physics engine, or continuous live multiplayer belongs in this plan. Two Halves starts pass-and-play; remote coordination needs a separately approved capability. A1 family manifests describe approved rounds and lineage; G5's author-time template code does not execute in a recipient's client.

## File ownership

| Action | Paths | Responsibility |
| --- | --- | --- |
| Modify | `contracts/play-v1.schema.json`, `contracts/client-capabilities-v1.schema.json` | Explicit new primitive/validator/flag contracts |
| Modify | `packages/play_schema/lib/src/model.dart`, `validation.dart`, `capability.dart`, `packages/play_schema/lib/play_schema.dart` | Pure typed scene and action declarations, exports |
| Create | `packages/play_schema/lib/src/game_scene.dart`, `test/game_scene_test.dart` | Stable objects, constrained step/timed cues and transforms |
| Modify | `packages/play_schema/test/capability_m1_test.dart`, `contract_artifacts_test.dart`, `direct_constructor_contract_test.dart`, `immutability_test.dart` | Cross-contract, constructor and legacy regressions |
| Modify | `packages/play_engine/lib/play_engine.dart` | New typed actions and validator routing |
| Create | `packages/play_engine/lib/src/game_rules.dart`, `test/game_rules_test.dart` | Pure scene selection, piece moves, set/rule/graph evaluation |
| Create | `packages/play_flutter/lib/src/play_scene_renderer.dart`, `test/play_scene_renderer_test.dart` | Scene composition through existing canvas renderer |
| Modify | `packages/play_flutter/lib/src/play_canvas_renderer.dart`, `play_media_layer_renderer.dart`, `play_input_primitives.dart`, `play_surface.dart`, `play_performance_probe.dart` | Shared rendering/input/metrics integration |
| Create | `packages/play_flutter/lib/src/play_cue_controller.dart`, `test/play_cue_controller_test.dart` | Ephemeral monotonic cue sampling and cancellation |
| Modify | `apps/mosaic_app/lib/main.dart`, `consumer_api_client.dart`, `game_attempt_controller.dart`, `play_resolution_telemetry.dart` | Capability envelope, attempt/cue ownership and evidence |
| Modify | `apps/api/src/contracts/compatibility.ts`, `production_catalog.ts`, `media_publication.ts`, `game_theme.ts` | Eligibility, first-family content and compatible themes |
| Create | `apps/api/src/game_templates.ts`, `apps/api/src/game_generation.ts`, `apps/api/src/game_solvers.ts` | Typed author-time family generation and independent verification |
| Create | `apps/api/src/game_generation_cli.ts`, `apps/api/test/game_generation.test.ts`, `apps/api/test/game_solvers.test.ts` | Bounded draft generation and property fixtures |
| Create | `apps/api/src/game_editorial.ts`, `apps/api/test/game_editorial.test.ts` | Publication quality record and explicit approval gate |
| Create | `apps/api/src/game_portfolio.ts`, `apps/api/test/game_portfolio.test.ts` | Remaining curated family specifications and proofs |
| Create | `docs/game-family-contracts.md`, `docs/game-quality-review.md` | Versioned mechanic rules, validation cases and actual reviews |
| Modify | `docs/play-runtime-spec.md`, `docs/experience-readiness-plan.md`, `docs/play-performance-profiling.md` | Capability, launch and measured-performance evidence |

Names listed as Create are proposed files. Split a family into its own module if it grows beyond a reviewable unit; do not introduce a registry/plugin framework to avoid a short explicit template switch. Tests for the existing canvas/audio/drag paths remain mandatory because this renderer composes them.

## G1: Add narrow object selection and piece movement

- [ ] Write contract fixtures for legacy canvas, valid scene, duplicate object IDs, off-viewport hit region, missing piece/target, unsupported validator, malformed transform, nonfinite coordinate, excess object count, and mismatched task art. Direct Dart constructors must enforce the same invariants as decoded JSON.
- [ ] Specify the scene contract: normalized coordinates; up to twelve interactive objects; stable IDs; explicit z-order; task-owned geometry and semantic name; approved visual asset or existing canvas commands; bounded static transforms. All selectable regions use the same transform as visible objects. Decorative theme layers cannot overlap task hit regions, create decoys unintentionally, or encode the answer in semantics.

Use one new presentation layer type `scene` with role `media` and an inline, size-bounded `scene` property decoded to `GameSceneDefinition`; referenced visual assets still appear in the document's managed `assets` list. Negotiate `scene_v1` in required platform flags. Do not put interactive scene data into the old static canvas asset codec. The new layer delegates drawing to existing canvas/image composition and contributes object semantics/hit regions. Required wire fields are `version: 1`, `objects`, and `targets`; G2 adds explicit step states and G4 adds optional bounded `cues`. Object and target IDs are unique within their respective lists, and input references are validated against them. Add a total serialized scene ceiling of 64 KiB and reject cycles/external references.
- [ ] Add separately negotiated primitives `object_select` and `piece_move`, and validators `object_id` and `legal_piece_move`. Do not reinterpret legacy `drag`. A piece action contains both actual source and destination:

```dart
final class PieceMoveAction extends PlayAction {
  const PieceMoveAction({required this.pieceId, required this.targetId});
  final String pieceId;
  final String targetId;
}
```

Because `PlayAction` is sealed, declare new subclasses in its existing library or a Dart part of that library, not an unrelated importing library. Its payload has bounded IDs and no coordinates used as authoritative answer data. The validator lists every legal source/destination and all accepted solved configurations; wrong legal moves produce task feedback, nonexistent IDs are rejected as malformed input.

```text
select object -> selected ID (ephemeral presentation)
select destination -> PieceMoveAction(pieceId, targetId)
engine validates move -> resulting configuration/outcome
renderer animates that configuration using unchanged object IDs
```

- [ ] Add the pure discrete result to engine state/resolution with immutable ownership; this is the state the reveal renders. Never independently draw the “correct” scene from a hard-coded label. Add snapshot encoding for the new actions to R1 and replay equivalence tests.
- [ ] Build object-level semantics and pointer/keyboard/tap-source-tap-destination interaction inside the shared scene renderer. Selection and placement are interruptible, use existing tokens, and preserve identity. Reduced motion snaps to the result. Multi-pointer cancel and feed swipe release the current gesture lease.
- [ ] Run schema/engine tests, new scene tests, and existing drag/canvas alignment/feed-lock tests. Expect new capability fixtures to be rejected before implementation and pass afterward; legacy fixtures remain unchanged. Publish the capability in the app envelope only after server/Dart/rendering support all pass. Commit with `feat: add declarative scene object actions`.

## G2: Publish One Move and controlled Quiet Switch

- [ ] Author six One Move rounds with actual selectable pieces and at least two meaningful legal destinations. Use an independent enumerator over the finite legal move set; accept every solution that satisfies the authored rule. Difficulty initially varies one dimension, such as candidate count, rather than visual clutter and reasoning simultaneously.
- [ ] Test invariant preservation, multiple valid outcomes, invalid occupied target, arbitrary-source selection, and revealed configuration. Exhaustive tests compare the gameplay validator with independently computed valid configurations, not the generator's own answer field.
- [ ] Define a step-cue extension for Quiet Switch: `observe → occluded → choose → compare`, with explicit Ready/Continue actions. The first mode is untimed. Use a single scene plus one validated controlled transformation (object position, property, or relation); background/theme is identical across both views. Do not independently generate two pictures and assume they differ only once.

```text
before := validated scene
after  := apply one approved transformation(before, stableObjectId)
diff   := structural difference(before, after)
require diff equals the authored transformation and exactly one target is accepted
```

- [ ] Keep the changed property absent from pre-answer accessibility text. Provide a deliberate accessible alternate reasoning mode when vision is intrinsic; its identity/results differ from the visual task. Compare toggles/split view appear only after commitment. Occlusion/scene replacement uses local assets with no network-dependent exposure.
- [ ] Author six Quiet Switch rounds spanning object, position, and relationship changes. Each pack is reviewed for target visibility/contrast and suppressed during exposure if a decorative background would distort the task. Use the static neutral fallback if compatibility fails.
- [ ] Add golden/semantics tests for initial, selected, wrong, solved and compare states at both target viewports, large text and reduced motion. First-user observation must confirm source/destination and changed-object actions are understood without tutorial text. Run API solvers plus schema/engine/renderer/app tests; commit each family content boundary with `feat: publish verified One Move rounds` and `feat: publish controlled Quiet Switch rounds`.

## G3: Publish pitch-only Echo Architect

- [ ] Use A4's audible piano and existing ordered sequence semantics. Define an immutable motif as note IDs from a bounded reviewed instrument/sample set, three to seven notes initially, with reference playback timings and an explicit task Hear action. The scored value is pitch order only; human input timing does not affect correctness.
- [ ] Author six motifs with deliberate musical contour and distinguishable notes. Production review checks instrument sample pitch, tuning, onset, decay, comfortable loudness and motif identity. Changing decorative theme must not change the scored notes or reference instrument; task audio is frozen with the round.
- [ ] Add tests for repeated notes, wrong order, clearing/retry, sample unavailable, task Hear after mute, swipe during reference, and identical evaluation when response timing differs. Background music and optional UI SFX remain suppressed during listening/response.

```text
heard reference [C4, E4, D4]
response [C4, E4, D4] at any permitted untimed pace -> correct
response [C4, D4, E4]                             -> incorrect
effects/music preference change                  -> same validation result
```

- [ ] Reveal the motif and replay reference/response only through deliberate task controls. Wrong-note feedback identifies the differing position visually and semantically without punishing sound. A visual pattern alternative is a separate mode, not an audio-attention score.
- [ ] Run piano/audio/sequence/lifecycle suites, physical route measurements and the first-user interaction gate. Commit with `feat: publish audible Echo Architect motifs`. Keep rhythm scoring ineligible until G4's independent timing work passes.

## G4: Add bounded timed cues and ship Sleight

- [ ] Add a distinct `timed_scene_v1` capability and explicit cue ID/schedule/trajectory contract. Limits: twelve interactive objects, 128 total transform keyframes, twelve seconds per cue, finite normalized transforms, monotonic keyframe times, supported interpolation only. Existing stricter overall limits still apply. Scene cues cannot run generated code.
- [ ] The Flutter controller samples an injected monotonic elapsed time. Pure engine receives a typed cue-completion action with cue ID and ordinal; attempt controller additionally fences attempt ID and generation. Duplicate/stale/out-of-order completion cannot advance state. No DateTime, timers, network, or audio engine belongs in `play_engine`.

```text
prepared + explicit start -> running(cueId, epoch, monotonicOrigin)
running + animation tick -> sample authored paths; no state transition
running + final tick     -> emit completion once for expected cue/epoch
running + deactivate     -> cancel tick/audio; invalidate; practice/restart required
completed + duplicate    -> ignore at boundary; no duplicate result/event
```

- [ ] Test at t=0, between frames, final frame, overdue frame, background before final, duplicate callback, replay same revision, device rotation and reduced-motion mode. The last visible configuration must match the committed final position even after a delayed frame. A severe rendering stall during a perception cue invalidates comparative scoring rather than hiding a skip; start with a >100 ms unpresented interval rule and tune only from measured evidence.
- [ ] Author six Sleight rounds from explicit coin location, cup trajectories, occlusions and any transfers. Verify the coin path with a separate discrete simulator; final answer must follow that path. Revelation traces the actual frozen path and can step through events. Attention-guiding motion is part of the task and must be inspectable afterward; no unrelated pop-up or sound startle is a “magic” mechanic.
- [ ] Add Constellation-ready exact set validation: duplicate object IDs are invalid, selection order irrelevant, required cardinality explicit. Timed Rule Flip schedules use explicit trial IDs/rule versions so delayed input cannot apply to the next rule. Ship these only in G7 after their content gate.
- [ ] Extend performance probe with separate build/raster budget counters while preserving total-span metrics. Profile 60/120 Hz target devices; initial gate is p95 build and raster each below the device frame budget and fewer than 1% budget violations during a representative warm cue run, with raw traces and stalls reviewed. Targets are engineering acceptance, not a guarantee on every device.
- [ ] Rhythm scoring is an optional separate PR: collect monotonic input timestamps, calibration/route identity and scoring version; test jitter and audio output latency physically before capability advertisement. Disable comparable rhythm results when the route changes or measured uncertainty exceeds the approved tolerance. Pitch-only Echo remains fully useful if this gate fails.
- [ ] Run cue/engine/schema/renderer tests, existing media lifecycle suites, platform builds and real-device timing/accessibility checks. Commit with `feat: add deterministic timed scene cues` then `feat: publish inspectable Sleight rounds`. A stepping/slower mode is accessible practice with its own mode identity.

## G5: Generate bounded draft data from approved families

- [ ] Implement the first generator as a local author-time CLI using the existing API toolchain, not a background job service. Inputs: family/version, bounded difficulty parameters, seed, count (1–24), optional compatible theme preference. Outputs: draft Play JSON, provenance, solver report and media references in an explicitly selected local output directory. No eligibility mutation occurs during generation.

```text
parse bounded request
select explicit approved family implementation
generate task data from recorded seed/PRNG version
independent solver -> accepted solutions and communication checks
resolve approved theme/background/audio references
validate complete document against server and Dart compatibility fixtures
emit draft + canonical hash + solver report + provenance
```

Use at most 200 candidate generations per requested round and at most 24 requested rounds per invocation. Exhaustion returns fewer drafts plus typed rejection counts; no infinite retry. Treat an optional language/image model's output as untrusted slot data with strict byte/schema limits. Model use never supplies authoritative answers, arbitrary asset URLs, executable code, or unreviewed sounds. Record model/version/prompt-template provenance if used without persisting unnecessary personal data.
- [ ] Define exact first templates: One Move occupied-piece layout and move grammar; Quiet Switch base-scene object attributes plus one controlled transformation; Echo note IDs/contour/length from reviewed samples; Sleight verified trajectory/occlusion sequence after G4. Prefer non-model procedural generation when it already yields valid variation.
- [ ] Add golden seed fixtures, malformed-slot fixtures, bounded-retry test, repeated-seed exact bytes, changed-theme identical solution, unsupported capability rejection, and generator/solver disagreement. Solvers must be independently written from formal family rules, with curated counterexamples and exhaustive small-state checks; calling the gameplay validator as the only solver is insufficient.
- [ ] Deduplicate by structural canonical signature: remove theme/wording/option-order differences, normalize equivalent graph/object labels where the mechanic permits it, and hash the task structure and accepted outcome set. Compare within the draft batch and the approved family inventory. Palette swaps alone do not count as new rounds.
- [ ] Run `pnpm --dir apps/api exec node --import tsx --test test/game_generation.test.ts test/game_solvers.test.ts`, expecting stable hashes and zero solver disagreements in approved fixtures. Then run API typecheck and full tests. Commit with `feat: generate solver-checked game drafts`.

## G6: Review generated games in the production player

- [ ] Add an editorial record with immutable draft hash, generator/solver versions, structural signature, source/rights IDs, required capabilities, resolved presentation, media readiness, reviewer decisions, and approval timestamps. A record is invalid if any artifact hash changes after approval.
- [ ] Mount the same `PlaySurface`, attempt controller and media/theme session in creator preview. No second renderer, optimistic “preview looks similar,” or static screenshot-only approval. The review operator must actually play initial/wrong/correct/replay states and inspect accessible operations. Use existing creator/publication authorization; do not invent a public approval endpoint.
- [ ] Require separate checks for answer proof, visible clue fidelity, semantic leakage, input/reveal clarity, fresh structure, sound masking, asset rights, accessibility mode honesty, moderation and performance budget. A solver pass cannot substitute for the reviewer understanding the puzzle. Rejected drafts retain bounded diagnostic metadata and never enter the family manifest.
- [ ] Publish through the existing immutable revision and managed-media publication transaction only after explicit authorized creator/editor approval. The transaction verifies the current draft hash, capabilities, rights/readiness, approved theme revisions and review record. Repeating the same publication is idempotent; different bytes under an existing revision conflict.
- [ ] Add publication tests for changed draft after approval, reviewer lacking authority, revoked pack assets, unsupported recipient capability, incomplete solver report, duplicate structural signature, repeated publish and transaction rollback. No “publish anyway” bypass belongs in this tranche.
- [ ] Record actual reviewed rounds in `docs/game-quality-review.md`, with review evidence and outstanding physical checks. Run API publication/media/database and Flutter preview/shared-composition tests. Commit with `feat: gate generated game publication on reviewed evidence`.

## G7: Extend the remaining eight families in separate content/mechanic PRs

Each row is its own small implementation boundary: first encode the example and rejection tests, run them to fail, add the pure rule/input integration and approved rounds, rerun schema/engine/portfolio/rendering tests, observe first-time play, then commit/push with the owning issue evidence. Record formal inputs/actions/outcomes, capability flags, theme compatibility and difficulty dimension in `docs/game-family-contracts.md`. Do not enable all rows with one generic “game” capability.

| Family | Concrete implementation and initial example | Required proof and interaction test | Theme/replay/social behavior |
| --- | --- | --- | --- |
| **Constellation** | Initially mark two of six stable object IDs, move along G4 trajectories, unmark, then exact set selection; reveal tracked paths | Order-insensitive selection `{b,e}` equals `{e,b}`; duplicates rejected; no path collision that makes identity mathematically indeterminate; exit during cue releases controllers | Suppress optional sound during tracking; vary target count before speed; same frozen path for friend challenge |
| **Rule Flip** | Start with explicit discrete trials: sort by shape, then by fill under a visibly changed rule; bind input to trial/rule ID | An object with triangle shape and striped fill follows the active rule only; stale prior-trial input rejected; first untimed mode scores accuracy only | No decorative feature may resemble the sorting cue; timing mode waits for G4; fresh schedules and explicit practice replay |
| **Counterexample** | Bounded predicates over authored object attributes; claim `Every red tile is round.`; choose a red square | Evaluate `red && !round` as a counterexample; blue square insufficient; if no disproof exists among choices, include an explicit insufficient-evidence outcome | Finite rule grammar, no eval; decisive property shown on reveal; friends commit before comparison |
| **Evidence Lens** | Choose a claim then a stable source/region ID; initial chart shows 10→15→12 and asks about final vs initial, avoiding cropped-axis deception | Accepted claim follows stored data, chosen evidence must entail it; chart art and labels derive from data; source date/context retained; semantic text does not name correct option | Quiet background, source readable on demand; fresh datasets reviewed for truth; share preview excludes selected evidence and solution |
| **Second Thought** | Initial choice, then curated adviser statement and evidence, then keep/change; store both responses explicitly in deterministic history | Include correct advice, incorrect advice and justified uncertainty; final score against evidence, not agreement/disagreement; no confidence-calibration score without an explicit meaningful confidence response | Optional sound off during evidence inspection; comparison shows position change, not intelligence; simulated adviser identified without implying live authoritative advice |
| **Signal Repair** | Small directed graph, at most twelve nodes and 24 edges, rotate one switch to connect source to goal; render engine-computed propagation | Enumerate permitted one-move configurations; BFS proves each accepted connection; cycles terminate using visited set; disconnected decoys remain wrong | Placement sound after input, no continuous hum required; compare valid solutions/move count; cosmetic theme cannot alter ports |
| **Your Read** | Concrete preference scenario plus prediction of the invited friend's choice; classification remains preference | R7 server holds each participant's commitment; no correctness until friend's choice is available; missing/expired friend response stays pending/expired, never guessed | No relationship score/contact scraping; reciprocal new scenarios; private answers excluded from automatic share cards |
| **Two Halves** | Pass-and-play map puzzle with role A's horizontal constraint and role B's vertical constraint; one shared final choice after both inspect | Solver proves the clue intersection has exactly one destination; role swap requires explicit handoff screen and clears previous clue semantics; neither clue alone determines answer | First version acknowledges local co-presence, not cryptographic secrecy; swap roles on a fresh round; remote clue exchange is outside this release |

For Signal Repair the independent reachability oracle is a bounded BFS; the gameplay engine may use a different representation so fixtures can reveal divergent graph semantics:

```ts
export function reaches(
  edges: ReadonlyMap<string, readonly string[]>, start: string, goal: string,
): boolean {
  const queue = [start];
  const seen = new Set([start]);
  for (let i = 0; i < queue.length; i++) {
    const node = queue[i]!;
    if (node === goal) return true;
    for (const next of edges.get(node) ?? []) {
      if (!seen.has(next)) { seen.add(next); queue.push(next); }
    }
  }
  return false;
}
```

```ts
import { equal } from 'node:assert/strict';
import { test } from 'node:test';
import { reaches } from '../src/game_solvers.js';

test('a cycle does not imply a path to the goal', () => {
  const graph = new Map([['a', ['b']], ['b', ['a']], ['goal', []]]);
  equal(reaches(graph, 'a', 'goal'), false);
  graph.set('b', ['a', 'goal']);
  equal(reaches(graph, 'a', 'goal'), true);
});
```

- [ ] Publish at least six reviewed rounds per new family before evaluating its repeat-play experience; label that inventory as a pilot and keep larger supply requirements separate. For Two Halves, paired role views count as one round.
- [ ] Keep difficulty player-controlled initially. Change one documented parameter between fresh rounds; never secretly alter the active round. Add `Harder` only when a validated next band exists. Any later adaptive policy requires a separate evaluation of learning intent, interaction affinity and performance data.
- [ ] Run the program's exact-head CI and physical performance/audio/accessibility gates for each new primitive and family release. Update readiness with per-family evidence, not a single blanket “twelve games done” checkbox.

## Product acceptance experiment

- [ ] Observe a small formative cohort before expanding each family: record whether users infer the first action, understand the reveal, request a fresh round, replay knowingly, recover from wrong input, and use sound/accessibility controls. Use the observations to find concrete defects; do not treat a small usability cohort as efficacy evidence.
- [ ] Track fresh-round requests, saved-game revisits, qualified recipient completions, abandonment before first action, reports, and performance failures. Deduplicate by attempt and preserve practice/challenge modes. Never optimize a compulsory streak or raw time spent as the success criterion.
- [ ] If making cognitive-improvement claims, commission an appropriately designed evaluation with unfamiliar tasks and suitable comparison conditions. Until then describe the actual activity—observation, note matching, evidence judgment—rather than claiming increased intelligence or medical benefit.

**Release acceptance:** all twelve families have a formal task, honest feedback, reviewed compatible sound/visual presentation, explicit replay/fresh-round behavior, and the tests applicable to their actual capability. Unsupported or unreviewed families remain ineligible; safe curated supply keeps the feed playable.

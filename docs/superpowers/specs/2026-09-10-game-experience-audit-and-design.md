# Mixli game experience: current-state audit and improvement design

Date: 2026-09-10. Status: researched design and delivery direction; implementation and release acceptance remain outstanding.

## Decision

Build authored, reusable game mechanics with validated challenge variations. First repair the current catalog's correctness and completion behavior, then deliver replay and Saved, then introduce flagship observation, manipulation, and music games with browser-playable sharing. Add larger-scale generation only after those mechanics pass content, accessibility, and physical-device review.

The agreed twelve-game direction remains intact. The audit changes the dependency order: Sleight needs a new deterministic cue capability; Echo Architect needs audible instrument input; Saved and Share are unfinished product paths. They cannot be treated as catalog-only changes.

This document records findings and a sequence of separately reviewable tranches. It is not a claim that the features have shipped or an execution-ready code plan for all twelve games.

## Evidence and scope

- Fetched `origin/main` and verified that both it and local HEAD were `45b68d53da05104b8ca62626850f98d39842a980` before creating the documentation branch. The working tree was clean.
- Inspected the product, experience, copy, runtime, dependency, readiness, sharing, creator, and performance contracts; current app composition, engine, primitives, catalog, save delivery/persistence, media warming, tests, and CI entry points.
- Read the current owning issues: [renderer #3](https://github.com/pullsar/mosaic/issues/3), [sharing #5](https://github.com/pullsar/mosaic/issues/5), [inventory and experiments #8](https://github.com/pullsar/mosaic/issues/8), and [editorial tooling #20](https://github.com/pullsar/mosaic/issues/20). Account lifecycle #58 and accessibility #17 remain open dependencies.
- Inspected `https://mixli.app/` in the browser at 1280×720 and 390×844. Observed matchstick input/reveal/completion, Saved, Share, city choice, palette choice, pattern artwork/answer, and orbit artwork. The browser had existing anonymous state; this was not a clean-install experiment. The live deployment SHA was not independently established.
- Live observations support the source findings below, but are not physical-device frame, touch, screen-reader, or audio-route acceptance. Temporary viewport overrides were reset after inspection.
- This is focused research, not a systematic review of all cognitive-training or game-generation literature.

## Current reality

### Preserve the existing foundations

| Foundation | Evidence | Consequence |
| --- | --- | --- |
| One schema → engine → Flutter renderer | `packages/play_schema`, `packages/play_engine`, `packages/play_flutter`; `main.dart::_buildPlaySurface` | Extend this path for feed, replay, preview, and shared links. |
| Capability negotiation | `main.dart::consumerCapabilitiesForAssetDelivery` | Current advertised inputs are tap, single choice, piano key, and drag; validators are none, equals, ordered sequence, and target region. Schema enum membership alone is not executable support. |
| Unified viewport allocation | `play_viewport_composition.dart`, `guest_home.dart`, `play_surface.dart` | Keep a single owner for prompt, stage, input, utilities, and navigation. Recent landscape fixes should not be undone. |
| Bounded consumer supply | `ConsumerFeedCache.maxItems = 12`; feed warms three items ahead | Reuse those windows. A new game must not allocate its own unbounded feed or asset queue. |
| Bounded warm metadata | `asset_delivery_warm.dart`: twelve metadata assets, three concurrent workers by default | Use the existing warmer rather than adding a generator-specific prefetch service. |
| Durable Save action | `ConsumerActionController.toggleSave` → event outbox → `consumer_actions.ts` → `actor_saved_plays` | Preserve enqueue-before-best-effort-cache semantics, exact retry identity, and Save's separation from recommendation preference. |
| Existing revision-read endpoint | `app.ts`: POST `/v1/plays/:playId/revisions/:revisionId`; `repository.ts::getPlayRevision` | Reuse its capability negotiation for Saved/shared reads, adding the missing client integration and publication-availability policy. |
| Managed media lifecycle | `PlayMediaLayerBuilder`, media coordinator, audio/video adapters | Reuse ownership, disposal, stale callback protection, and explicit audio activation. |
| Existing regression and profiling infrastructure | renderer/widget/golden/gesture tests; `PlayPerformanceProbe` | Expand tests around real catalog behavior and measure devices; do not replace the harness. |

### Catalog and interaction findings

The release catalog in [production_catalog.ts](../../../apps/api/src/production_catalog.ts) declares six eligible `rev_2` starter Plays: one drag puzzle, three objective single-choice challenges, and two preferences. All six use static managed canvas artwork. The reference fixtures demonstrate richer image, video, and audio paths but are not this production starter inventory. The planned 24–36 art-directed opening Plays and 500–1,000 beta inventory are targets, not the current release set.

| Finding | Source and reproduction | Improvement |
| --- | --- | --- |
| Pattern answer is unsupported by the visible pattern | `releaseChoiceSpecs` answers Diamond; the canvas contains circle, square, circle, outlined square. The live mobile game displayed that sequence and revealed Diamond after Circle was selected. | Re-author a clearly constrained pattern and verify the solution independently. Do not merely change Diamond to another answer while leaving an ambiguous blank/continuation. |
| Orbit options have no visual referents | The canvas contains circles and a line but no A/B/C labels or mapped selectable paths. Live inspection confirmed that A/B/C buttons cannot be matched to identified paths. | Either author a scientifically defensible, labeled prediction with sufficient initial conditions, or replace this challenge. A still drawing alone cannot justify the current physical claim. |
| Matchstick solution contradicts the remaining object | `moveOneMatchV2` reuses the unsolved asset for reveal. Live reveal said `8 − 4 = 4` while the stage still showed `6 + 4 = 4`. | Represent the pieces and solved arrangement explicitly. One move must cause the displayed equation and its accessible description to change together. |
| Non-drag operation bypasses the decision | `PlayDragInput._activateWithoutDrag` submits the selected target, initially index zero; this catalog puzzle supplies one target. Activating Move match solved it immediately in the browser. | Offer meaningful source-piece and legal-destination choices, including legal but unsuccessful moves. Accessible operation must preserve the puzzle's reasoning rather than require dexterity or disclose the answer. |
| End state leaves an inert Done control | `PlaySurface._apply` ignores actions when ended; `build` still renders the last state's input. `main.dart` records the resolution without routing completion to a fresh round. Live Done remained after activation. | Define a terminal presentation contract and explicit Replay/Another round intents. Do not auto-page or silently reset the current Play. |
| Replay lacks stable attempt ownership | `PlaySurface` privately owns `PlaySession` and resets only on Play/revision change. `PlaySession.attempts` counts applied transitions, including the Done transition. | Introduce a distinct round-attempt identity at the existing session boundary. Keep action count separate from completed rounds and wrong answers. Do not reinterpret old telemetry. |
| Saved navigation is a placeholder | `guest_home.dart::_GuestNavigation` displays a coming-soon snackbar. Confirmed live. | Deliver a real local-first Saved destination, listing saved revisions and resolving them through the shared runtime. |
| Share is a placeholder | `main.dart::_buildFeedPlay` supplies a callback that only shows a snackbar. Confirmed live. | Implement the canonical-link and anonymous web-play work owned by #5. A visible icon is not sharing readiness. |
| Instrument input is not yet an audible instrument | `PlayPianoInput._press` records a sequence; its constructor exposes only `onSequence`. `PlaySurface` connects that to `SequenceAction`; there is no per-key audio callback in this path. | Bind key feedback to the existing audio owner. Audio presentation playback is a separate capability and does not prove audible key input. |
| Preference rounds provide little material outcome | City choice uses one generic skyline for both cities; both options lead to the same reveal. Palette options likewise share one composition and a generic response. | Show actual option-specific objects/scenes and preserve the selected result. Keep preference free of correctness; social prediction can add purpose later. |
| Current visuals underuse the stage | Desktop inspection showed a small portrait canvas surrounded by large black areas, detached prompt, and distant utilities. Mobile was clearer, but the artwork remained a static diagram with little direct response. | Author per-game object scale and responsive arrangements within the existing composition contract. Repair object/action coupling before adding visual effects. |
| Conversion interrupts play with an unfinished destination | `GuestHome` opens a modal with barrier dismissal and drag dismissal disabled, although an explicit Not now button exists. The destination is early access. This modal appeared in the existing browser session. | Remove automatic conversion prompts from the core round loop until a material account action exists. Offer account connection for cross-device state through #58. |

The relevant source paths are [PlaySurface](../../../packages/play_flutter/lib/src/play_surface.dart), [input primitives](../../../packages/play_flutter/lib/src/play_input_primitives.dart), [guest navigation](../../../apps/mosaic_app/lib/guest_home.dart), [app composition](../../../apps/mosaic_app/lib/main.dart), and [engine](../../../packages/play_engine/lib/play_engine.dart).

### What current tests do and do not establish

The catalog PostgreSQL test checks revision preservation, eligibility, assets, palettes, and exact document registration. Those are valuable structural guarantees; they do not independently prove that a visible pattern supports its answer. Existing goldens demonstrate selected fixtures and composition states, not all release-game solutions. New coverage must couple the published puzzle, legal actions, visible solution, and semantic solution.

Loading placeholders were visible during several browser transitions before assets appeared. No latency distribution or warm-cache conditions were measured, so this is a profiling lead rather than a quantified warm-swipe performance failure.

## Research and design implications

### Cognitive benefit: test mechanics and transfer separately

The 2016 review found strong evidence for improvement on trained tasks and much weaker evidence for broad transfer. That makes exact replay unsuitable as evidence of general improvement. [Simons et al., 2016](https://www.psychologicalscience.org/publications/brain-training.html)

A 2023 meta-analysis reported a positive overall training estimate, while also finding publication bias and substantial variation. Specific gameplay features were more informative than broad genre names. Its included games and training regimens do not establish effectiveness for Mixli's short rounds. [Smith and Basak, 2023](https://pmc.ncbi.nlm.nih.gov/articles/PMC10395941/)

Design inference: maintain an explicit mapping from each mechanic to the activity it exercises; measure fresh-round performance separately from familiar-puzzle replay. Any claim about improved attention outside Mixli requires a prospectively designed study with an active comparison condition, unfamiliar outcome tasks, retention measurement, and appropriate sample planning. Do not publish an IQ, brain-age, or overall cognitive score.

### Magic: make attention consequential, then explain the trick

An eye-tracking experiment demonstrated that misdirection can conceal an event that remains physically visible. This supports using fair choreography and an explanatory replay as interesting game material; it does not show that playing such games trains attention. [Barnhart and Goldinger, 2014](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2014.01461/full)

Design inference: Sleight must have a reproducible, inspectable path. Avoid impossible off-screen substitution, random post-answer outcomes, gaze surveillance, or guessing where the player looked. A player's chosen target is enough to run the game.

### AI-era judgment: independent answer before advice

An experiment with 199 participants found that cognitive forcing reduced overreliance relative to simple explainable-AI designs, with a usability tradeoff and unequal benefit across participants. [Buçinca et al., 2021](https://arxiv.org/abs/2102.09692)

Design inference: Second Thought should make a first judgment quick and tactile before showing a simulated adviser. Avoid turning every round into an evidence form. Include correct advice and evidence-supported revisions as well as misleading advice; the intended activity is appropriate reliance, not universal distrust.

### Generation: constrain the authored language

Research has demonstrated game generation through a video-game description language, including rules and levels. This is evidence that structured generation is possible, not evidence that unconstrained generated games are consistently fun, safe, accessible, or performant. [Hu et al., 2024](https://arxiv.org/abs/2404.08706)

The recommended approach is an engineering decision grounded in Mixli's declarative runtime: approved mechanics, typed slots, solver-checked configurations, authored presentation, shared-runtime preview, and creator approval. Do not introduce executable generated Dart, JavaScript, or arbitrary shaders.

### Performance: distinguish frame throughput from latency

Flutter documents separate build and raster budget checks and distinguishes those from total frame span, because pipelining can produce multi-frame latency without missing every frame. [Flutter frame timing API](https://api.flutter.dev/flutter/rendering/RendererBinding/addTimingsCallback.html)

The existing probe's `overBudgetFrames` counts total-span overruns. Preserve that metric's meaning; do not label it dropped-frame percentage. Add separate build/raster budget reporting when extending the profiling tranche. Use 16.67 ms at 60 Hz and 8.33 ms at 120 Hz, physical profile-mode devices, and end-to-end input/audio measurements. Localize rebuilds and audit saveLayer, opacity, clipping, and intrinsic layout only where measurement identifies cost. [Flutter performance guidance](https://docs.flutter.dev/perf/best-practices)

## Game portfolio and implementation direction

Each round keeps one immediate action, a useful in-place reveal, and unconditional exit. The labels below are proposed product prompts. Durations and difficulty are design targets to validate with playtesting.

| Game | Core interaction and reveal | Existing reuse / required extension | Replay and social |
| --- | --- | --- | --- |
| **Quiet Switch** — What changed? | Study a composed scene, activate Ready, then identify one change after an occlusion. Locally compare before/after. | Reuse image/canvas assets and composition. Add object selection and a bounded cue-completion contract; transformed artwork and hit regions share coordinates. | Fresh object relationships and changes; identical challenge for friends. Slower/step variants are explicitly identified. |
| **Sleight** — Follow the coin. | Track a concealed coin through fair choreography, choose a location, then inspect its path. | Reuse scene and choice components. Add deterministic trajectories, occlusion, cue playback and review controls. | New crossing/transfer patterns; exact practice replay. No ranked speed comparison in the initial version. |
| **Constellation** — Keep these in sight. | Track initially marked moving objects and select them when movement stops. Reveal their paths. | Reuse cue capability after Sleight; requires executable set selection/validation, not just the existing schema enum. | Vary targets, similarity, and speed separately. Optional short multi-round play with an exit after every round. |
| **Rule Flip** — Follow the shape. | Sort objects by an explicit active rule despite distracting features. Show the decisive feature after an error. | Choices can prototype the mechanic. Continuous timed input and rule schedules require reviewed action semantics. | Fresh schedules; optional speed mode only after timing validation. Accuracy first. |
| **Echo Architect** — Play it back. | Hear a short motif, reproduce it on an audible instrument, then compare. | Reuse sequence validator, piano widget and audio adapter; add per-key sound ownership. Pitch first; rhythm scoring follows timing/device evidence. | Fresh motifs within a difficulty band; approved motif exchange. Composition remains subjective. |
| **One Move** — Move one piece. | Select an actual piece and destination; the arrangement becomes a valid equation, shape, or bridge. | Extend existing drag and target validation. Data must represent selectable pieces, legal moves, and all accepted outcomes. | Solver-verified puzzles; compare valid solutions, not answer-memory speed. |
| **Counterexample** — Break the rule. | Choose or construct an object that disproves a small machine's claimed rule. The machine demonstrates the contradiction. | Choices can support curated cases; composition and symbolic rule evaluation extend the engine in a later tranche. | Fresh rule/attribute combinations; reviewed creator templates. Insufficient evidence is an explicit outcome. |
| **Evidence Lens** — Which claim holds? | Choose a claim and identify supporting evidence in a chart, passage, or image. Reveal one decisive relationship. | Reuse media and choices; add evidence-region input and source-linked validation. | Fresh artifacts, equivalent reasoning patterns; compare only after submission. Sources and regions must not leak the answer before play. |
| **Second Thought** — Keep or change? | Make a judgment, inspect advice/evidence, and revise or retain it. Compare the initial and final positions. | Curated choice graphs can demonstrate the flow. Add explicit response history and calibration semantics before scoring. | Balanced advice reliability. No model-generated authoritative answers or incentives for reflexive disagreement. |
| **Signal Repair** — Restore the signal. | Rotate/replace one element in a small circuit or chain; propagation exposes the consequence. | Reuse object input; add bounded discrete graph evaluation. Animation depicts the engine's result. | Solver-checked topologies and accepted alternatives; optional move-count comparison. |
| **Your Read** — What would Sam pick? | Predict a friend's situated preference; reveal both commitments together. | Reuse Choose semantics; depends on #5 challenge context and server-held reveal policy. | Reciprocal fresh scenarios. No relationship score and no access to contacts or messages. |
| **Two Halves** — Find the meeting point. | Combine complementary clues to agree on a map location or mechanism. Join both views on resolution. | Role-specific views and solver verification. Pass-and-play first; remote coordination is a separate later capability. | Swap roles or use fresh puzzles. A bounded clue exchange, not a general messaging system. |

The first quality cohort is One Move, Quiet Switch, and pitch-only Echo Architect. Sleight joins after the scene/cue capability is validated. This stages the originally agreed four flagships by actual dependencies rather than dropping one.

## Experience contract

### A round

1. Present the actual object and a 2–6 word prompt. Audio and perceptual exposure begin with explicit intent where needed.
2. Reflect contact immediately: press, lift, selection, or local visual response. No server call belongs in the feedback path.
3. Resolve through the engine. Preserve the object and the selected answer, and make the consequence visible and semantically available.
4. Offer a fresh round when available. Exact Replay is secondary and is practice. Never leave an enabled-looking inert terminal control.
5. Keep vertical swipe, back, and dismissal available throughout. Completion never moves the player to another Play without intent.

A wrong answer must be understandable without relying on red/green alone. Preference and Discover retain their own outcomes rather than becoming quizzes. Longer attention exercises are optional extensions, not mandatory feed sessions.

### Motion and visual craft

- Use the existing viewport contract. Compact portrait, landscape, desktop, and enlarged text may have different arrangements but identical game semantics.
- Treat each game as a coherent material composition: real match pieces, a responsive instrument, or an inspectable miniature scene. Do not apply one generic canvas illustration to every topic.
- Keep active object scale generous; keep controls near the action without overlapping Save/Share/More or feed navigation.
- Begin micro-feedback with the input frame. Use the existing roughly 140–240 ms transition range as a starting point, not a universal timing rule. Tracking cues follow their authored schedule.
- Preserve stable object identity through selection, placement, and reveal. Interrupt or cancel motion safely on exit.
- Reduced motion removes decorative translation and bounce. If motion is the task, provide a clearly named stepped/slower alternative; do not imply identical competitive conditions.
- Ambient movement, celebratory overlays, speculative holographic chrome, and decorative full-screen blur do not contribute to this design.

### Accessibility that retains the task

Offer tap-piece/tap-destination and keyboard choices for manipulation. Include all meaningful legal alternatives rather than only winning targets. Canvas semantics need object-level identity and logical operation order. Avoid semantic descriptions containing hidden changes or solutions before submission.

An audio or visual alternative can change the activity being exercised. Present it honestly as a different mode, preserve access to enjoyable play, and keep its results out of incompatible comparisons. Validate with real VoiceOver/TalkBack users/devices; a browser AX tree is only an inspection aid.

## Replay, Saved, pins, and sharing

### Identity and ownership

Use three distinct identities:

- **Game family/template:** the reusable mechanic and its approved version.
- **Published round:** an immutable Play/revision with resolved puzzle parameters and asset identities.
- **Attempt:** a new run of that exact round, with its own identifier and input history where required.

For the first release, fresh rounds come from an approved family manifest of already published Plays. A generator seed is provenance, not a substitute for storing the actual puzzle. Generated challenges also become immutable publications before public consumption. Family metadata belongs to the documented Play/template lineage model, not to a second renderer or content store. The current Dart `PlayDocument` has no family/template field; introducing the manifest and its linkage requires an explicit contract change rather than assuming that documentation is already implemented.

Replay creates a new attempt without changing the published round. Another round selects a fresh eligible family member at the same requested difficulty. Harder changes one defined difficulty dimension between rounds. If no fresh round is available locally or remotely, offer Replay or the feed without pretending an old round is new.

Move attempt lifetime above ephemeral widget mounting using the existing app/runtime composition boundary. Preserve the current attempt on benign rebuilds; invalidate old callbacks when a new attempt begins. Reuse local recovery facilities for a bounded active snapshot. Do not persist live controllers or serialize a new private queue.

### Saved and pins

The existing state records one saved revision per Play ID. Preserve that behavior in the first migration; reopening a saved item must resolve its saved revision, not whichever revision is currently ranked. Distinct generated rounds have distinct Play IDs. Supporting several saved revisions of one Play would be a separate explicit migration.

The missing capabilities are a paginated saved-item query, local enumeration/indexing, client integration with the existing revision-read endpoint, and the actual destination. The current per-Play cache and twelve-item recent-feed cache are not a complete Saved inventory.

Use the existing durable save event path. Add an indexed local saved projection and paginated server read path in the same persistence boundary; reconcile pending saves/unsaves without resurrecting stale remote state. Keep bookmarked metadata separate from evictable media. Never silently remove a bookmark because its cached asset was evicted.

Pin game saves a family shortcut, not another revision bookmark. Start with six manually ordered pins; replacement at the limit requires an explicit choice, and pin order must survive retries/restarts. This limit is a product default to evaluate, not a research-derived optimum. Do not add pins as a recommendation or learning-intent event by implication.

Keep Play · Saved · Create · Me. Saved contains compact family shortcuts and saved round previews, not a cognitive dashboard. Initial collections can follow once retrieval and reconciliation work. Cross-device private state depends on #58; local guest play and saves do not wait for account creation.

### Sharing and fairness

Implement #5's canonical HTTPS route, safe social-preview HTML, native/copy sharing, anonymous browser play, and unavailable-content behavior. The web route must mount the same PlaySurface and capability checks. Start with ordinary Play links; add result challenges after attempt identity and server reveal policy exist.

The current revision-read endpoint checks existence and compatibility; its repository query reads `play_revisions` directly without an availability check. Extend that existing path with a shared publication/removal policy before exposing it as the public sharing resolver. Distinguish a historical revision no longer recommended in the feed from content actually withdrawn or moderated; feed eligibility alone is not the correct saved-link policy.

A challenge freezes the exact round, relevant mode, and scoring version. Sender results are outside the immutable Play and hidden server-side until the recipient submits when the policy requires it. Do not rely on client-hidden strings or a guessable hash to conceal a small choice set.

Client-local/offline objective validation exposes enough information for determined cheating. Initial friend comparisons are recreational; do not market them as secure ranked competition. Any authoritative timed competition requires server-side validation and a separate threat model. Moderation/takedown eligibility applies even to old links; a historical revision is not permission to bypass removal.

## Generation and runtime extension

Pipeline: approved template → typed draft slots → bounded puzzle generation → independent solver/consistency checks → production-renderer preview → content/accessibility/rights review → creator approval → immutable publication → eligible family manifest.

Generate puzzle structure and artwork under the same stable object IDs. For Quiet Switch, begin with controlled scene transformations rather than independently generated before/after photographs, which can introduce unintended changes. For One Move, enumerate legal moves and accepted solutions. For Echo, validate pitch ranges, note count, sample readiness, and phrase structure. For Sleight, freeze the trajectory and transfer schedule and verify its reveal.

Reject contradictions, unreachable outcomes, excessive assets, unsupported capabilities, ambiguous required answers, accidental hidden-answer leakage, and repeated structural near-duplicates. A solver proves properties of its model; human review still establishes whether the scene communicates the model and whether playing it is worthwhile.

The first new scene capability should be narrow: stable objects, authored hit regions, deterministic transforms/occlusion, and bounded cue playback. Initial proposed publication ceilings are twelve interactive objects, 128 total transform keyframes, and twelve seconds per cue; these are conservative design budgets to validate against the physical target matrix before shipping. Existing stricter asset/state limits still apply.

Cue completion is an explicit action tagged to the attempt and cue. Presentation samples a monotonic timeline, but the pure engine does not read a clock. Reject duplicate, out-of-order, or stale completion. Stop cues on background/exit. A scored interrupted perception cue becomes practice or requires a new attempt; resuming must not accidentally grant an invisible competitive advantage. Audio resume never implies permission to play.

New capability declarations must flow through the checked JSON contract, Dart validation, server compatibility/publication checks, app envelope, renderer, and fixtures. Do not advertise a primitive merely because an enum name exists. Older clients receive compatible supply or a clear unsupported state.

## Delivery sequence and acceptance

Each row is a coherent implementation boundary and needs its own detailed execution plan and final validation. The sequence is the recommendation produced by this audit.

| Tranche | Owning paths and issues | Acceptance before expansion |
| --- | --- | --- |
| **1. Current catalog integrity** | `apps/api/src/production_catalog.ts`; catalog tests; `play_input_primitives.dart`; #3/#8/#17 | New immutable revisions for corrected content; pattern answer visibly justified; orbit either defensible or replaced; match solution and semantics agree; non-drag choices retain reasoning. Preserve historical revisions and update eligibility deliberately. |
| **2. Completion and attempt lifecycle** | `play_surface.dart`, engine session boundary, `main.dart`, resolution telemetry, recovery tests; #3/#55 | No inert Done; explicit exact replay; unique attempt identity; completion is emitted once per attempt; action counts retain old meaning; rebuild/exit/stale callback behavior proven. Remove automatic conversion interruption from this loop. |
| **3. Saved retrieval and family rounds** | `consumer_local_state*`, `consumer_api_client.dart`, existing local-state/event-delivery boundary, API saved projection/query, `guest_home.dart`; #4/#58 coordination | A guest saves, restarts, lists, opens the saved revision, replays, and unsaves. Pending local state survives remote reconciliation. Fresh family selection, explicit exhaustion, six pins and reorder persist. No second queue. |
| **4. First flagship content and shared links** | approved One Move/Quiet Switch/pitch-only Echo content; narrow scene/object capability; audio input binding; #3/#5/#8/#17 | At least six reviewed rounds per initial family as a quality pilot, not beta inventory completion. First action understood without tutorial. Browser links play anonymously and withhold spoilers. Test input/gesture/audio semantics across supported surfaces. |
| **5. Cue-driven magic and challenges** | scene/cue schema+engine+renderer, attempt/reveal APIs; #3/#5/#17 | Sleight's path is deterministic and inspectable; interrupted cues behave honestly; same-round friend challenges preserve rules; physical timing and motion variants measured. Constellation follows executable set-selection support. |
| **6. Generation and portfolio expansion** | existing template/publication/media pipeline; #6/#7/#10/#20/#8 | Independent content validation and human preview establish quality before generated supply becomes eligible. Expand Counterexample/Evidence Lens/Second Thought/Rule Flip/Signal Repair/Your Read with their required capabilities. Two Halves remote coordination remains a separate later tranche. |

The first PR should address tranche 1. Avoid bundling authentication, generator infrastructure, multiplayer, database changes, and renderer redesign into that repair. Sharing engineering can be prepared while flagship content is authored, but no social game depends on a placeholder link path.

### Required regression evidence

- Catalog: every new revision passes structural validation and independent solution checks; old revision bytes are unchanged; eligibility selects only intended supply.
- Object interaction: source/destination choices, incorrect legal moves, solved scene and semantics, cancel/exit/multi-pointer recovery, and landscape feed-swipe parity.
- Round lifecycle: exact replay resets only attempt state; new family round changes identity; repeated terminal input cannot duplicate completion; stale audio/cue callbacks cannot affect a new attempt.
- Saved/pins: offline save and unsave, restart before/after delivery, delayed stale server response, pagination, missing revision, removed content, pin reorder retries, and asset eviction without bookmark loss.
- Sharing: cold anonymous web entry, native routing, preview spoiler checks, recipient commitment/reveal ordering, unsupported clients, expired/removed content, and retry-safe challenge creation.
- Generation: reproducible frozen configurations, independent solver fixtures, ambiguity rejection, structural diversity, bounded work, source/rights metadata, and human-reviewed screenshots in the production renderer.
- Performance/accessibility: physical 60/120 Hz scripts, 100-Play churn and longer soak, bounded controllers/assets/queues, low-end device observation, actual screen-reader operation, reduced motion, enlarged text, and audio-route checks.

Use the checked-in workflows and their current server entry point, `ops/production/bin/server-ci.sh`, as the executable gate. It currently runs enforced-lockfile dependency resolution, Dart formatting, Flutter analysis, package/app tests, real Chrome IndexedDB/browser tests, platform checks, and web release build; platform-sensitive changes also require the applicable native release gates. Run relevant focused tests during implementation and the required final gate on the exact final code head.

## Product evaluation

The primary experience question is whether a new player understands the action by seeing and touching the object. Track first meaningful action, fresh-round requests, exact replay separately, saved-game revisits, recipient completions, abandonment, reports, and accessibility/performance failures. Do not optimize raw session duration as the governing metric.

For each mechanic, conduct an initial observed playtest on its core action and reveal before interpreting retention. Record where participants misunderstand the object or cannot explain why the result followed. Resolve those defects before adding content volume. Measure novelty by fresh structural challenges, not palette changes or shuffled choices alone.

Keep difficulty explicit initially. Later adaptation should change one dimension between rounds, with player override and no inferred cognitive diagnosis. Keep topic interest, learning intent, interaction affinity, and within-game performance separate. Compare unfamiliar rounds and external tasks if testing cognitive benefit; never infer it from a memorized challenge score.

## Validation performed for this audit

Source inspection and live browser checks produced the findings above. No application code, production catalog, database, or deployment was changed by this audit.

Two baseline test attempts did not execute the requested tests:

1. `cd packages/play_engine; dart test` stopped at dependency resolution because the available Dart SDK is 3.9.2 and the workspace requires `>=3.12.0 <4.0.0`.
2. `cd packages/play_flutter; flutter test --no-pub test/play_surface_reuse_test.dart test/play_input_primitives_test.dart test/play_drag_feed_lock_test.dart test/play_canvas_drag_alignment_test.dart test/play_performance_probe_test.dart` stopped with a missing test dependency-resolution error. The package does declare `flutter_test`; the local environment lacks a usable resolved workspace for this run. This is not evidence of a missing repository dependency or a failing game test.

The checked-in server builder selects Flutter 3.44.7. A compatible isolated toolchain is required before implementation validation; the audit did not upgrade the user's global Flutter installation. No passing test, release-build, cognitive-benefit, or physical-performance claim is made.

No owning issue is marked complete. This document changes design/planning state only.

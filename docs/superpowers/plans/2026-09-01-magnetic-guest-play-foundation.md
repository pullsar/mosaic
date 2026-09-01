# Magnetic Guest Play Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the colliding monochrome guest screen with one responsive, content-led Play composition and deploy a premium rewrite of the flagship six.

**Architecture:** Add an immutable viewport composition contract to `play_flutter`, make the app shell and Play renderer consume the same reserved regions, and constrain managed canvas to an aspect-aware stage. Publish new immutable canvas assets and Play revisions with semantic palettes, suspend superseded starter revisions, and preserve the dominant visual through reveal.

**Tech Stack:** Flutter 3.44.7, Dart, `play_schema`, `play_engine`, `play_flutter`, Fastify/TypeScript/PostgreSQL production catalog, server review CI, exact-SHA production deployment.

---

## Scope boundary

This tranche includes the shared composition foundation, the six production starter rewrites, truthful early-access conversion, responsive/accessible visual coverage, server verification, and deployment. It does not expand supply to 24–36 Plays or implement managed account authentication; those are separate testable tranches from the approved design.

## File map

- Create `packages/play_flutter/lib/src/play_viewport_composition.dart` — immutable responsive region and stage policy.
- Modify `packages/play_flutter/lib/play_flutter.dart` — export the composition contract.
- Modify `packages/play_flutter/lib/src/play_surface.dart` — render prompt, stage, reveal, and input within allocated regions.
- Modify `packages/play_flutter/lib/src/play_canvas_renderer.dart` — parse semantic palette and constrain painting to the authored stage.
- Modify `packages/play_flutter/lib/src/play_input_primitives.dart` — render object-shaped drag affordance and consume the input region.
- Modify `packages/play_flutter/lib/src/visual_tokens.dart` — centralize chrome, type, motion, and stage tokens.
- Modify `apps/mosaic_app/lib/guest_home.dart` — remove the wordmark, own only quiet chrome/navigation, and make conversion truthful.
- Modify `apps/mosaic_app/lib/consumer_action_controls.dart` — move quiet utilities into their reserved adaptive region and move More Like This into secondary disclosure.
- Modify `apps/mosaic_app/lib/main.dart` — provide one composition environment to guest chrome, Play surface, and utilities; configure Inter Variable.
- Add `apps/mosaic_app/assets/fonts/Inter-VariableFont_opsz,wght.ttf` — checked-in licensed variable font asset.
- Modify `apps/mosaic_app/pubspec.yaml` — register Inter Variable.
- Modify `apps/api/src/canvas_asset.ts` — validate an optional schema-v1 semantic palette without weakening legacy documents.
- Modify `apps/api/src/production_catalog.ts` — add immutable `_v2` canvas assets and `rev_2` Plays, preserve visuals in reveal, and suspend superseded starter revisions.
- Modify `apps/api/test/canvas_asset.test.ts` and `apps/api/test/production_catalog_postgres.test.ts` — palette and catalog migration regressions.
- Modify `packages/play_flutter/test/play_canvas_renderer_test.dart`, `packages/play_flutter/test/play_surface_layout_test.dart`, and `packages/play_flutter/test/play_surface_golden_test.dart` — renderer, geometry, and state continuity coverage.
- Modify `apps/mosaic_app/test/guest_home_test.dart` and `apps/mosaic_app/test/consumer_action_controls_test.dart` — full-shell geometry, conversion, navigation, and utility behavior.
- Create `apps/mosaic_app/test/guest_play_composition_golden_test.dart` and reference images under `apps/mosaic_app/test/goldens/` — production composition at required viewports and states.

### Task 1: Responsive viewport contract

**Files:**
- Create: `packages/play_flutter/lib/src/play_viewport_composition.dart`
- Modify: `packages/play_flutter/lib/play_flutter.dart`
- Test: `packages/play_flutter/test/play_surface_layout_test.dart`

- [ ] **Step 1: Write the failing geometry tests**

Add tests that construct the composition at `320×640`, `390×844`, `844×390`, `768×1024`, and `1440×900` and assert ordered non-overlapping regions:

```dart
final composition = PlayViewportComposition.fromConstraints(
  const BoxConstraints.tightFor(width: 390, height: 844),
  safeInsets: const EdgeInsets.only(top: 24, bottom: 16),
);
expect(composition.chrome.bottom <= composition.prompt.top, isTrue);
expect(composition.prompt.bottom <= composition.stage.top, isTrue);
expect(composition.stage.bottom <= composition.input.top, isTrue);
expect(composition.input.bottom <= composition.navigation.top, isTrue);
expect(composition.stage.width / composition.stage.height, inInclusiveRange(0.8, 1.4));
```

Landscape must assert `utilityPlacement == PlayUtilityPlacement.horizontalDock`; portrait and desktop may use `trailingRail` only when the minimum stage remains usable.

- [ ] **Step 2: Push the failing test commit and run the server review lane**

Run through the existing review dispatcher at the exact pushed SHA. Expected: the focused Flutter test fails because `PlayViewportComposition` does not exist. Do not execute Flutter tests locally.

- [ ] **Step 3: Implement the minimal immutable contract**

Create:

```dart
enum PlayUtilityPlacement { trailingRail, horizontalDock }

@immutable
final class PlayViewportComposition {
  const PlayViewportComposition({
    required this.chrome,
    required this.prompt,
    required this.stage,
    required this.input,
    required this.utilities,
    required this.navigation,
    required this.utilityPlacement,
  });

  factory PlayViewportComposition.fromConstraints(
    BoxConstraints constraints, {
    required EdgeInsets safeInsets,
    double textScale = 1,
  }) {
    final size = constraints.biggest;
    final scale = textScale.clamp(1.0, 2.0);
    final compactLandscape = size.width > size.height && size.height < 600;
    final useRail = !compactLandscape && size.width >= 360 && size.height >= 720;
    final top = safeInsets.top + 8;
    final bottom = size.height - safeInsets.bottom - 8;
    final chromeHeight = 48 * scale;
    final promptHeight = compactLandscape ? 48 * scale : 64 * scale;
    final navigationHeight = compactLandscape ? 48.0 : 64.0;
    final utilityHeight = useRail ? 0.0 : 56.0;
    final inputHeight = compactLandscape ? 64.0 : 120 * scale;
    final chrome = Rect.fromLTWH(16, top, size.width - 32, chromeHeight);
    final prompt = Rect.fromLTWH(
      20,
      chrome.bottom + 8,
      size.width - 40,
      promptHeight,
    );
    final navigation = Rect.fromLTWH(
      12,
      bottom - navigationHeight,
      size.width - 24,
      navigationHeight,
    );
    final utilities = useRail
        ? Rect.fromLTWH(size.width - 68, prompt.bottom + 8, 56,
            navigation.top - inputHeight - prompt.bottom - 24)
        : Rect.fromLTWH(16, navigation.top - utilityHeight, size.width - 32,
            utilityHeight);
    final input = Rect.fromLTWH(
      16,
      utilities.top - inputHeight,
      size.width - 32,
      inputHeight,
    );
    final stageRight = useRail ? utilities.left - 8 : size.width - 16;
    final stageBounds = Rect.fromLTRB(
      16,
      prompt.bottom + 8,
      stageRight,
      input.top - 8,
    );
    final stageWidth = math.min(stageBounds.width, 720.0);
    final stageHeight = math.min(stageBounds.height, stageWidth / 0.8);
    final stage = Alignment.center.inscribe(
      Size(math.min(stageWidth, stageHeight * 1.4), stageHeight),
      stageBounds,
    );
    return PlayViewportComposition(
      chrome: chrome,
      prompt: prompt,
      stage: stage,
      input: input,
      utilities: utilities,
      navigation: navigation,
      utilityPlacement: useRail
          ? PlayUtilityPlacement.trailingRail
          : PlayUtilityPlacement.horizontalDock,
    );
  }

  final Rect chrome;
  final Rect prompt;
  final Rect stage;
  final Rect input;
  final Rect utilities;
  final Rect navigation;
  final PlayUtilityPlacement utilityPlacement;
}
```

Use `LayoutBuilder` constraints, not `MediaQuery.size` inside child renderers. Export the type from `play_flutter.dart`.

- [ ] **Step 4: Run the focused server test and commit green**

Expected: all viewport cases pass with no negative, off-screen, or overlapping region.

### Task 2: Bounded canvas and semantic palette

**Files:**
- Modify: `apps/api/src/canvas_asset.ts`
- Modify: `packages/play_flutter/lib/src/play_canvas_renderer.dart`
- Test: `apps/api/test/canvas_asset.test.ts`
- Test: `packages/play_flutter/test/play_canvas_renderer_test.dart`

- [ ] **Step 1: Write failing API and Flutter tests**

API tests accept this optional palette while legacy assets remain valid:

```ts
palette: {
  background: '#17121F',
  foreground: '#FFF8ED',
  accent: '#FFB84D',
  muted: '#A99CB8',
  surface: '#3C2E47',
}
```

Reject missing roles, malformed `#RRGGBB`, identical background/foreground, unknown keys, and non-object palettes. Flutter tests assert parsing, role mapping, legacy fallback, and that `PlayCanvas` uses an `AspectRatio`-bounded stage rather than `SizedBox.expand` painting against the viewport.

- [ ] **Step 2: Verify red on the server**

Expected: API normalization rejects `palette` as an unknown key and Flutter cannot read the palette.

- [ ] **Step 3: Implement compatible palette parsing and stage rendering**

Keep `schemaVersion: 1`; add optional immutable `CanvasPalette`/`PlayCanvasPalette` because the extension is backward-compatible and capability-safe. Convert only validated six-digit sRGB values. `PlayCanvas` paints inside a centered `ConstrainedBox`/`AspectRatio`, using the asset background and semantic roles; legacy assets use the current theme fallback.

- [ ] **Step 4: Verify focused server tests and commit green**

Expected: legacy fixtures pass unchanged, invalid palettes fail closed, and the same normalized geometry retains its aspect on phone, landscape, and desktop.

### Task 3: One Play composition and continuous reveal

**Files:**
- Modify: `packages/play_flutter/lib/src/play_surface.dart`
- Modify: `packages/play_flutter/lib/src/play_input_primitives.dart`
- Modify: `packages/play_flutter/lib/src/visual_tokens.dart`
- Test: `packages/play_flutter/test/play_surface_layout_test.dart`
- Test: `packages/play_flutter/test/play_surface_test.dart`
- Test: `packages/play_flutter/test/play_drag_feed_lock_test.dart`

- [ ] **Step 1: Write failing composition tests**

Pump the real `PlaySurface` with a composition and assert:

```dart
expect(tester.getRect(find.byKey(const ValueKey('play-prompt')))
    .overlaps(tester.getRect(find.byKey(const ValueKey('play-stage')))), isFalse);
expect(tester.getRect(find.byKey(const ValueKey('play-input')))
    .overlaps(tester.getRect(find.byKey(const ValueKey('play-utilities-region')))), isFalse);
```

Add a transition fixture whose reveal repeats the canvas layer and assert the canvas element identity survives the state transition while concise reveal copy appears. Add 200% text, RTL, and reduced-motion cases. Drag tests assert a 48×48 minimum semantic target and an alternate activation path.

- [ ] **Step 2: Verify red on the server**

Expected: the prompt still overlays the stage, the existing renderer has no composition argument, and the drag handle remains generic.

- [ ] **Step 3: Implement region-based surface composition**

Add `PlayViewportScope`, an inherited immutable scope supplied by `GuestHome`. `PlaySurface` reads `PlayViewportScope.maybeOf(context)`; isolated previews without the app shell derive the same contract from their `LayoutBuilder` constraints. Render prompt, visual stage, input, and reveal feedback in allocated `Positioned.fromRect` regions. Replace generic drag-indicator chrome with an object-shaped match affordance whose hit box remains at least 48×48. Use motion tokens in the 140–240 ms range and bypass displacement in reduced-motion mode.

- [ ] **Step 4: Verify focused server tests and commit green**

Expected: no region overlap, reveal preserves the object, drag lock still releases deterministically, and accessibility cases pass.

### Task 4: Guest chrome, navigation, utilities, and conversion

**Files:**
- Modify: `apps/mosaic_app/lib/guest_home.dart`
- Modify: `apps/mosaic_app/lib/consumer_action_controls.dart`
- Modify: `apps/mosaic_app/lib/main.dart`
- Modify: `apps/mosaic_app/lib/guest_engagement.dart`
- Test: `apps/mosaic_app/test/guest_home_test.dart`
- Test: `apps/mosaic_app/test/consumer_action_controls_test.dart`
- Test: `apps/mosaic_app/test/guest_engagement_test.dart`

- [ ] **Step 1: Write failing shell and eligibility tests**

Assert there is no persistent `mixli` wordmark on the Play, `For You` and Search occupy the chrome region, and `Play · Saved · Create · Me` remains reachable. Assert Save/Share/More do not overlap contextual input at all reference sizes and More Like This appears only in secondary disclosure.

Update engagement tests to require either five distinct views plus one meaningful interaction or eight distinct views. Conversion tests expect `Get early access`, never `Join Mixli`, while the destination is the current placeholder.

- [ ] **Step 2: Verify red on the server**

Expected: old wordmark and `Join Mixli` assertions fail, and the bottom-centered action bar overlaps the input region.

- [ ] **Step 3: Implement the shared shell composition**

Create the composition once in `GuestHome` with `LayoutBuilder` and pass it down through an inherited immutable scope or explicit builder. Render only `For You`, Search, and adaptive navigation in the shell. Place Save/Share/More in the reserved utility region, preserve accessible labels, and move More Like This into the More menu. Keep conversion dismissal in place and apply the existing persistence/cooldown path.

- [ ] **Step 4: Verify focused server tests and commit green**

Expected: shell geometry, action semantics, navigation, safe prompt timing, and truthful conversion copy pass.

### Task 5: Inter Variable and production-composition goldens

**Files:**
- Add: `apps/mosaic_app/assets/fonts/Inter-VariableFont_opsz,wght.ttf`
- Modify: `apps/mosaic_app/pubspec.yaml`
- Modify: `apps/mosaic_app/lib/main.dart`
- Create: `apps/mosaic_app/test/guest_play_composition_golden_test.dart`
- Create: `apps/mosaic_app/test/goldens/*.png`

- [ ] **Step 1: Add the licensed Inter asset and failing font/composition tests**

Register:

```yaml
flutter:
  fonts:
    - family: Inter
      fonts:
        - asset: assets/fonts/Inter-VariableFont_opsz,wght.ttf
```

The test must verify the app theme resolves `fontFamily == 'Inter'` and pump the actual GuestHome → utilities → PlaySurface composition at the six reference viewports, 1.6/2.0 text, RTL, loading, reveal, menu, and prompt states. Tests must load real glyphs rather than block placeholders.

- [ ] **Step 2: Verify the theme assertion fails on the server**

Expected: current theme does not resolve Inter.

- [ ] **Step 3: Configure typography and generate intentional reference images**

Use Semibold prompts, Medium controls, and Regular details. Review each generated image for one dominant object, one primary action, readable hierarchy, safe-area clearance, and absence of decorative effects.

- [ ] **Step 4: Run focused goldens on the server and commit green**

Expected: every reference matches and geometry assertions remain authoritative when a golden needs regeneration.

### Task 6: Publish immutable flagship revisions

**Files:**
- Modify: `apps/api/src/production_catalog.ts`
- Modify: `apps/api/test/production_catalog_postgres.test.ts`

- [ ] **Step 1: Write the failing catalog migration test**

Seed `rev_1`, apply the new catalog twice, and assert:

```ts
assert.deepEqual(status, {eligiblePlays: 6, canvasAssets: 12});
assert.equal(eligibleRev2Count, 6);
assert.equal(suspendedRev1Count, 6);
assert.equal(revealStatesWithPrimaryVisual, 6);
```

Also assert the first six contain at least three distinct palettes, both choice and drag interactions, no consecutive topic duplicate, and exact immutable document equality.

- [ ] **Step 2: Verify red on the server with PostgreSQL**

Expected: current catalog has only `rev_1`, six canvases, and reveal states without media.

- [ ] **Step 3: Author `_v2` assets and `rev_2` Plays**

Give matchsticks a warm tactile palette, city a midnight/amber editorial palette, pattern a mineral rhythm palette, orbit deep indigo/cyan, preference an energetic editorial palette, and sequence a restrained typographic palette. Preserve each primary canvas in reveal and add only one concise fact or acknowledgment. Suspend prior eligible starter revisions transactionally before enabling the exact new set; never mutate published revisions or assets.

- [ ] **Step 4: Verify PostgreSQL catalog tests and commit green**

Expected: application is idempotent, unrelated creator content remains untouched, rev1 is retained but suspended, and exactly six rev2 starters are eligible.

### Task 7: Exact-head server gate, review, merge, and deploy

**Files:**
- No product file changes unless verification exposes a regression.

- [ ] **Step 1: Push the exact feature SHA and run the server review lane**

Use the repository's review dispatcher. The server gate must run the authoritative `ops/production/bin/server-ci.sh` suite, including formatting, analysis, Dart/Flutter tests, API/PostgreSQL integration, real Chrome IndexedDB, and web release build.

- [ ] **Step 2: Inspect results and fix failures test-first**

For each failure, add or refine the smallest reproducing test, confirm red on the server, implement the correction, and rerun the focused test before the full gate.

- [ ] **Step 3: Perform code and spec coverage review**

Compare the exact diff to this plan and the approved design. Confirm no user-auth implementation, recommendation rewrite, unrelated lockfile churn, or local build artifacts entered the branch.

- [ ] **Step 4: Merge the verified branch into latest `main` and push**

Reconcile against current `origin/main`, preserve a coherent history, and push only after exact-head server verification is green.

- [ ] **Step 5: Deploy the exact main SHA**

Trigger the existing short GitHub deployment dispatcher or invoke the restricted server deployment command. The origin runner must build, test, apply the catalog, switch atomically, and record the exact SHA.

- [ ] **Step 6: Verify live production through Cloudflare**

At `390×844`, `844×390`, and `1440×900`, confirm the old overlap is absent, the first six render distinct palettes, inputs and utilities do not collide, reveal preserves the object, Search and navigation work, and the truthful prompt appears only at eligibility. Record the deployed SHA and browser evidence.

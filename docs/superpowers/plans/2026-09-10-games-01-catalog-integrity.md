# Catalog integrity implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Use `subagent-driven-development` only when the user selects delegated execution. Steps use checkbox syntax for tracking.

**Goal:** Make every currently eligible Play defensible, visually accurate, and operable before adding more games.

**Architecture:** Publish corrected immutable revisions through the current production catalog. Extend existing input and canvas presentation without changing legacy primitive semantics or adding a renderer.

**Tech Stack:** TypeScript/PostgreSQL, Dart, Flutter, existing canvas assets and catalog publication.

---

## Boundary and evidence

Depends on P0 in [the program plan](2026-09-10-replayable-games.md). Owns the immediate corrections from the [approved audit](../specs/2026-09-10-game-experience-audit-and-design.md). Review issues #3, #8, and #20 at execution time. This tranche does not claim a new cognitive-training program, generated supply, or a general piece-moving engine.

The inspected eligible catalog contains six `rev_2` Plays. Preserve their stored documents and assets. New `rev_3` documents and new asset identities replace feed eligibility; a moderation/availability policy separately controls historical access. A poor puzzle can be removed from new recommendations without treating it as unsafe content.

## File ownership

| Action | Path | Responsibility |
| --- | --- | --- |
| Modify | `apps/api/src/production_catalog.ts` | Corrected revision definitions and desired eligibility |
| Modify | `apps/api/src/canvas_asset.ts` | Existing asset validation only if a corrected composition needs an already-supported field |
| Create | `apps/api/src/catalog_integrity.ts` | Pure author-time puzzle checks and solved-state construction |
| Modify | `apps/api/test/production_catalog_postgres.test.ts` | Immutable publication and eligibility regression |
| Create | `apps/api/test/catalog_integrity.test.ts` | Answer/artwork correspondence |
| Modify | `packages/play_flutter/lib/src/play_input_primitives.dart` | Explicit non-drag destination selection |
| Modify | `packages/play_flutter/test/play_input_primitives_test.dart` | Tap/keyboard/semantics alternate operation |
| Modify | `packages/play_flutter/test/play_drag_feed_lock_test.dart` | Gesture ownership/release |
| Modify | `packages/play_flutter/test/play_canvas_drag_alignment_test.dart` | Correct target mapping at actual viewport sizes |
| Modify | `apps/mosaic_app/test/guest_play_composition_golden_test.dart` | Updated intentional composition evidence |
| Modify | `docs/experience-readiness-plan.md` | Accurate readiness and outstanding device evidence |

## C1: Freeze the old catalog and encode corrected content

- [ ] Capture canonical JSON/hash and asset IDs for each stored `rev_2` in the existing PostgreSQL fixture. Assert applying the new catalog twice cannot change those values.
- [ ] Add explicit corrected-content fixtures with this acceptance matrix:

| Current item | Corrected task | Evidence required |
| --- | --- | --- |
| Pattern | A repeated, visually demonstrated motif; prompt `Repeat the pattern.` | The displayed motif and allowed next tile determine the same answer; no unlabeled missing square masquerading as a diamond |
| Orbit | A clearly labeled route-continuity task; prompt `Which path connects?` | Exactly one A/B/C path connects the marked endpoints; no unsupported orbital-physics inference |
| Number | A shown progression of gaps with an explicit repeated gap rule | Solver computes the accepted value; displayed numbers and gaps come from that solver input |
| Matchstick | One authored source piece and several real destinations; prompt `Move one match.` | Enumerate legal destinations, exactly one valid equation, reveal renders the resulting configuration |
| City preference | Two concrete, distinct destination scenarios | Every option gets its own truthful consequence; preference has no correct/incorrect judgment |
| Palette preference | Distinct composed scenes using each palette | Reveal preserves the chosen palette and a specific comparison; no identical generic outcome |

Use existing vector/canvas assets where sufficient. If a route or preference cannot be made coherent with current assets, remove it from eligible supply until a reviewed replacement exists; do not invent an answer to retain six items.

- [ ] Write the author-time checker and tests before replacing the catalog. For the constrained piece puzzle, represent a configuration as occupied segment IDs and apply a move to that set. Generate both problem and solved art from these configurations, never from independent answer strings.

```ts
export function moveSegment(
  occupied: ReadonlySet<string>, from: string, to: string,
): ReadonlySet<string> {
  if (!occupied.has(from) || occupied.has(to) || from === to) {
    throw new Error('invalid_segment_move');
  }
  const next = new Set(occupied);
  next.delete(from);
  next.add(to);
  return next;
}
```

The catalog fixture explicitly supplies the finite destination set and valid seven-segment digit/operator map. Evaluate only a parsed `integer operator integer = integer` grammar with bounded nonnegative integers; never use `eval`. Enumerate every allowed destination and compare the resulting valid equation with the accepted answer. The full arbitrary-source mechanic belongs to G1.

```ts
import { deepStrictEqual, throws } from 'node:assert';
import { test } from 'node:test';
import { moveSegment } from '../src/catalog_integrity.js';

test('moving a piece preserves count and the original configuration', () => {
  const before = new Set(['a', 'b']);
  deepStrictEqual([...moveSegment(before, 'a', 'c')].sort(), ['b', 'c']);
  deepStrictEqual([...before].sort(), ['a', 'b']);
  throws(() => moveSegment(before, 'missing', 'c'));
  throws(() => moveSegment(before, 'a', 'b'));
});
```

- [ ] Run `pnpm --dir apps/api test` in the disposable database environment. Before implementation, expect the new fixture assertions to fail on missing corrected revisions/answer-art correspondence; after implementation, expect no failed or unexpectedly skipped catalog tests.
- [ ] Publish `rev_3` and new assets using the existing catalog synchronization. Assert only the intended newest safe revisions become feed-eligible; a second synchronization is a no-op. Preserve historical revision bytes and foreign keys.
- [ ] Review each prompt, answer, and reveal together at 390×844 and 1280×720. The solved equation must visibly match the answer. Commit with `fix: publish verified catalog revisions` after API typecheck/tests and diff review.

## C2: Replace instant-solve alternate drag activation

- [ ] Add widget regressions for keyboard and screen reader operation: selecting the source does not submit; each destination has a semantic name; activating a destination submits its actual index; cancellation submits nothing. Verify a wrong destination can be chosen without dragging.
- [ ] Run `cd packages/play_flutter && flutter test test/play_input_primitives_test.dart test/play_drag_feed_lock_test.dart test/play_canvas_drag_alignment_test.dart`; expect the new no-auto-submit assertion to fail against `_activateWithoutDrag`.
- [ ] Replace the hard-coded destination-zero activation with ephemeral source selection and an explicit destination action. Keep engine input equal to the existing drag payload. The presentation transition table is:

```text
idle + activate-source             -> selecting; no engine input
selecting + activate-destination i -> idle; submit existing drag payload(i)
selecting + Escape/cancel          -> idle; no engine input
any + deactivate/dispose          -> idle; release gesture ownership
```

Do not change a `drag` document into a multi-source contract. Use the same normalized target geometry for pointer and alternate operation. No full-screen opaque gesture detector may trap vertical feed swipe. A tap on an unrelated canvas point must not map to the first destination.
- [ ] Assert pointer/tap/keyboard operations resolve the same authored destinations at both viewport sizes, including text scale 2.0 and reduced motion. Verify rapid paging during a held drag releases the feed lock.
- [ ] Rerun the three focused tests, the full play_flutter suite, and app composition tests. Update intentional goldens on the repository's canonical host, not by accepting unrelated platform font changes. Commit with `fix: require explicit alternate drag destination`.

## C3: Record the trust gate and rollout

- [ ] Add one catalog review record per eligible revision: task input, finite answer proof, solved asset identity, preference semantics, accessibility operation, and reviewer decision. Put the initial record in `docs/experience-readiness-plan.md`; the generated editorial record in G6 will formalize this data.
- [ ] Run the program's exact-head gates for changed paths. Verify a clean diff with no old revision mutations or unrelated assets/lockfile updates.
- [ ] Open/push the coherent PR and update the owning issues with evidence. Keep audio, replay, new primitives, and physical-device acceptance explicitly outstanding.

**Release acceptance:** zero known answer/art disagreements among eligible revisions; every visible alternate input can produce both a valid and an invalid choice where the task permits them; immutable revision hashes unchanged. This is a correctness release, not evidence of generalized cognitive benefit.

# Guest-First Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open Mixli directly into an interesting, media-complete guest feed and show a dismissible account invitation only after five distinct Plays.

**Architecture:** The server build injects the public API origin, and deployment applies a versioned idempotent starter catalog before candidate readiness. A pure guest-engagement controller deduplicates canonical feed visibility events and persists prompt state through the existing web/native stores. A focused `GuestHome` widget composes the feed, brand chrome, and non-blocking registration sheet without coupling ranking, media, or future authentication to UI code.

**Tech Stack:** Flutter/Dart, IndexedDB, SQLite, Fastify/TypeScript, PostgreSQL 18, Bats/ShellCheck, Docker Compose, existing server CI and blue/green deployment runner.

---

## File map

- Create `apps/api/src/production_catalog.ts` — owns starter canvas assets, starter Play documents, idempotent apply, and verification.
- Create `apps/api/src/bootstrap_catalog.ts` — narrow production CLI for `apply` and `verify`.
- Create `apps/api/test/production_catalog_postgres.test.ts` — proves idempotence, preservation, asset completeness, and minimum eligible content.
- Modify `apps/api/package.json` — exposes the catalog bootstrap command.
- Modify `ops/production/bin/server-ci.sh` — injects the HTTPS API origin into the Flutter web build.
- Modify `ops/production/tests/server_ci.bats` — locks the web build configuration contract.
- Modify `ops/production/bin/deployment.sh` — applies and verifies starter content after migration and before candidate start.
- Modify `ops/production/tests/deployment.bats` — locks catalog ordering and failure behavior.
- Create `apps/mosaic_app/lib/guest_engagement.dart` — state model, store contract, and pure prompt eligibility controller.
- Create `apps/mosaic_app/test/guest_engagement_test.dart` — controller deduplication, threshold, cooldown, and recovery tests.
- Modify `apps/mosaic_app/lib/consumer_local_state_web.dart` — persists guest prompt state in existing IndexedDB metadata.
- Modify `apps/mosaic_app/lib/consumer_local_state_native.dart` — adapts SQLite guest prompt persistence.
- Modify `packages/local_state/lib/local_state.dart` — adds narrowly scoped native metadata accessors.
- Modify `packages/local_state/test/consumer_recovery_v2_test.dart` — proves native persistence and malformed-state recovery.
- Modify `apps/mosaic_app/test/consumer_local_state_web_test.dart` — proves web persistence across reopen.
- Modify `apps/mosaic_app/test/consumer_local_state_native_test.dart` — proves the SQLite adapter persists guest state.
- Create `apps/mosaic_app/lib/guest_home.dart` — guest feed chrome, prompt sheet, and truthful early-access account surface.
- Create `apps/mosaic_app/test/guest_home_test.dart` — widget behavior, accessibility, and layout tests.
- Modify `apps/mosaic_app/lib/main.dart` — removes the startup onboarding gate and wires feed events into guest engagement.
- Modify `apps/mosaic_app/lib/consumer_feed.dart` — replaces the icon-only empty state with a branded feed recovery surface.
- Modify `apps/mosaic_app/test/app_test.dart` — asserts feed-first launch.
- Modify `apps/mosaic_app/test/consumer_feed_test.dart` — asserts friendly empty/retry behavior.
- Modify `ops/production/bin/verify-production.sh` and `ops/production/tests/verify_script.bats` — verify the public topics and guest-feed prerequisites after deployment.

## Server-only test policy

Do not run Flutter, Node, Docker builds, or test suites on the workstation. For each RED/GREEN checkpoint:

1. commit and push the current branch SHA;
2. fetch it into a detached build-owned checkout on `152.53.55.38`;
3. run the named command inside the pinned server CI image/runtime;
4. reserve the full `/opt/mixli/bin/server-ci.sh` run for integration checkpoints and final deployment.

Use the established key-only SSH command and never copy production secrets into the source checkout.

### Task 1: Configure the production web API origin

**Files:**
- Modify: `ops/production/tests/server_ci.bats`
- Modify: `ops/production/bin/server-ci.sh`

- [ ] **Step 1: Write the failing build-contract test**

Add this test to `ops/production/tests/server_ci.bats`:

```bash
@test "production Flutter build injects the exact HTTPS API origin" {
  script="$REPO_ROOT/ops/production/bin/server-ci.sh"

  grep -Fq 'MIXLI_WEB_API_BASE_URL:-https://api.mixli.app/' "$script"
  grep -Fq -- '-e MIXLI_WEB_API_BASE_URL="$WEB_API_BASE_URL"' "$script"
  grep -Fq -- '--dart-define="MOSAIC_API_BASE_URL=$MIXLI_WEB_API_BASE_URL"' "$script"
  grep -Fq '[[ "$WEB_API_BASE_URL" =~ ^https://[^[:space:]]+/$ ]]' "$script"
}
```

- [ ] **Step 2: Run the Bats test on the server and verify RED**

Run in the detached server checkout:

```bash
bats ops/production/tests/server_ci.bats --filter 'production Flutter build injects'
```

Expected: FAIL because the API-origin constant and `--dart-define` are absent.

- [ ] **Step 3: Add the validated build setting**

Near the other readonly settings in `server-ci.sh`, add:

```bash
readonly WEB_API_BASE_URL="${MIXLI_WEB_API_BASE_URL:-https://api.mixli.app/}"
```

At the start of `flutter_workspace()`, fail closed:

```bash
[[ "$WEB_API_BASE_URL" =~ ^https://[^[:space:]]+/$ ]]
```

Pass the value into the Flutter container and build with it:

```bash
docker run --rm --shm-size=1g \
  -e MIXLI_WEB_API_BASE_URL="$WEB_API_BASE_URL" \
  -v "$flutter_volume:/workspace" -w /workspace \
  "$FLUTTER_IMAGE" bash -c \
  'set -Eeuo pipefail
   flutter pub get --offline --enforce-lockfile
   dart format --output=none --set-exit-if-changed .
   flutter analyze
   (cd packages/play_schema && dart test)
   (cd packages/play_engine && dart test)
   (cd packages/analytics_contract && dart test)
   (cd packages/event_delivery && dart test)
   (cd packages/event_delivery && dart test --platform chrome test_web)
   (cd packages/local_state && dart test --reporter=expanded)
   (cd packages/play_flutter && flutter test)
   (cd packages/platform_contracts && dart test)
   (cd packages/platform_flutter && flutter test)
   (cd apps/mosaic_app && flutter test)
   (cd apps/mosaic_app && flutter build web --release --pwa-strategy=none \
     --dart-define="MOSAIC_API_BASE_URL=$MIXLI_WEB_API_BASE_URL")'
```

- [ ] **Step 4: Run the focused Bats suite on the server and verify GREEN**

Run:

```bash
bats ops/production/tests/server_ci.bats
shellcheck ops/production/bin/server-ci.sh
```

Expected: all `server_ci.bats` tests pass and ShellCheck exits 0.

- [ ] **Step 5: Commit**

```bash
git add ops/production/bin/server-ci.sh ops/production/tests/server_ci.bats
git commit -m "fix(web): configure production API origin"
```

### Task 2: Add a media-complete production starter catalog

**Files:**
- Create: `apps/api/src/production_catalog.ts`
- Create: `apps/api/src/bootstrap_catalog.ts`
- Create: `apps/api/test/production_catalog_postgres.test.ts`
- Modify: `apps/api/package.json`

- [ ] **Step 1: Write the failing PostgreSQL contract test**

Create `apps/api/test/production_catalog_postgres.test.ts` with a database-gated test that:

```ts
test('production catalog is idempotent, complete, and preserves unrelated content', {skip: !databaseUrl}, async () => {
  await runMigration();
  const pool = new Pool({connectionString: databaseUrl});
  const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
  const unrelated = `creator_owned_${suffix}`;
  try {
    await pool.query('insert into plays (id) values ($1)', [unrelated]);
    const first = await applyProductionCatalog(pool);
    const second = await applyProductionCatalog(pool);
    assert.equal(first.eligiblePlays, 6);
    assert.deepEqual(second, first);
    assert.equal((await verifyProductionCatalog(pool)).eligiblePlays, 6);
    assert.equal((await pool.query('select count(*)::int as count from plays where id = $1', [unrelated])).rows[0]?.count, 1);

    const documents = await pool.query<{document: {assets?: string[]}}>(
      `select revision.document
         from feed_catalog_entries catalog
         join play_revisions revision using (play_id, revision_id)
        where catalog.play_id like 'mixli_starter_%' and catalog.state = 'eligible'`,
    );
    const assetIds = new Set(documents.rows.flatMap((row) => row.document.assets ?? []));
    const registered = await pool.query<{id: string}>('select id from canvas_assets where id = any($1::text[])', [[...assetIds]]);
    assert.deepEqual(new Set(registered.rows.map((row) => row.id)), assetIds);
  } finally {
    await pool.query('delete from plays where id = $1', [unrelated]);
    await pool.end();
  }
});
```

Include the same `runMigration()` helper pattern used by `consumer_loop_acceptance_postgres.test.ts`.

- [ ] **Step 2: Run the API test on the server and verify RED**

Run inside the API CI image with the disposable PostgreSQL network used by `server-ci.sh`:

```bash
cd /workspace/apps/api
node --import tsx --test --test-concurrency=1 test/production_catalog_postgres.test.ts
```

Expected: FAIL because `production_catalog.ts` does not exist.

- [ ] **Step 3: Define six deterministic starter Plays**

Create `production_catalog.ts` and export:

```ts
export const productionStarterPrefix = 'mixli_starter_';
export const productionStarterCount = 6;
export type ProductionCatalogStatus = {eligiblePlays: number; canvasAssets: number};
export async function applyProductionCatalog(pool: Pool): Promise<ProductionCatalogStatus>;
export async function verifyProductionCatalog(pool: Pool): Promise<ProductionCatalogStatus>;
```

Define these exact starter identities and interaction mix:

```ts
const starters = [
  {id: 'mixli_starter_move_one_match', revisionId: 'rev_1', format: 'solve', topics: ['puzzles', 'logic'], assetId: 'mixli_canvas_matchsticks'},
  {id: 'mixli_starter_city_instinct', revisionId: 'rev_1', format: 'choose', topics: ['travel', 'city-breaks'], assetId: 'mixli_canvas_city_night'},
  {id: 'mixli_starter_finish_pattern', revisionId: 'rev_1', format: 'guess', topics: ['patterns', 'design'], assetId: 'mixli_canvas_pattern'},
  {id: 'mixli_starter_find_orbit', revisionId: 'rev_1', format: 'guess', topics: ['space', 'science'], assetId: 'mixli_canvas_orbit'},
  {id: 'mixli_starter_color_energy', revisionId: 'rev_1', format: 'choose', topics: ['design', 'culture'], assetId: 'mixli_canvas_color_energy'},
  {id: 'mixli_starter_quick_logic', revisionId: 'rev_1', format: 'guess', topics: ['logic', 'numbers'], assetId: 'mixli_canvas_quick_logic'},
] as const;
```

Use these exact prompts, choices, and outcomes:

```ts
const choiceSpecs = [
  {
    id: 'mixli_starter_city_instinct',
    prompt: 'Four days. Warm nights. Where are you going?',
    options: [['lisbon', 'Lisbon'], ['marrakech', 'Marrakech']],
    answer: null,
    reveal: 'Good instinct.',
  },
  {
    id: 'mixli_starter_finish_pattern',
    prompt: 'What completes the rhythm?',
    options: [['circle', 'Circle'], ['diamond', 'Diamond'], ['square', 'Square']],
    answer: 'diamond',
    reveal: 'Diamond. The shape alternates as the scale rises.',
  },
  {
    id: 'mixli_starter_find_orbit',
    prompt: 'Which path stays in orbit?',
    options: [['a', 'A'], ['b', 'B'], ['c', 'C']],
    answer: 'b',
    reveal: 'B. Sideways speed keeps the fall curving.',
  },
  {
    id: 'mixli_starter_color_energy',
    prompt: 'Pick tonight’s energy.',
    options: [['electric', 'Electric'], ['soft', 'Soft'], ['afterglow', 'Afterglow']],
    answer: null,
    reveal: 'That is your color story.',
  },
  {
    id: 'mixli_starter_quick_logic',
    prompt: '2 · 6 · 12 · 20 · ?',
    options: [['26', '26'], ['28', '28'], ['30', '30']],
    answer: '30',
    reveal: '30. Add 4, 6, 8, then 10.',
  },
] as const;
```

Generate each choice document with one entry state and one reveal state:

```ts
function choiceDocument(spec: typeof choiceSpecs[number], assetId: string, topics: readonly string[]) {
  const options = spec.options.map(([id, label]) => ({id, label}));
  const transition = spec.answer === null
    ? Object.fromEntries(options.map(({id}) => [id, 'reveal']))
    : {correct: 'reveal', incorrect: 'reveal'};
  return {
    schemaVersion: 1,
    id: spec.id,
    revisionId: 'rev_1',
    format: spec.answer === null ? 'choose' : 'guess',
    classification: spec.answer === null ? 'preference' : 'challenge',
    topics: [...topics],
    learningTopics: [],
    estimatedDurationSec: 15,
    assets: [assetId],
    sources: [],
    entryState: 'choice',
    states: {
      choice: {
        presentation: {layers: [
          {type: 'canvas', role: 'media', assetId},
          {type: 'text', role: 'prompt', value: spec.prompt},
        ]},
        input: {type: 'single_choice', options},
        validation: spec.answer === null ? {type: 'none'} : {type: 'equals', value: spec.answer},
        transition,
      },
      reveal: {
        presentation: {layers: [{type: 'text', role: 'reveal_title', value: spec.reveal}]},
        input: {type: 'tap', label: 'Done'},
        validation: {type: 'none'},
        transition: {default: '$end'},
      },
    },
  };
}
```

Use these bounded visual primitive sets for the six canvases; each shorthand tuple is expanded into the existing canvas element object shape:

```ts
const canvasRecipes = {
  mixli_canvas_matchsticks: [
    ['label', .18, .42, '6', .22], ['line', .29, .42, .38, .42, .016],
    ['line', .335, .35, .335, .49, .016, 'accent'], ['label', .50, .42, '4', .22],
    ['line', .62, .39, .71, .39, .012], ['line', .62, .45, .71, .45, .012],
    ['label', .82, .42, '4', .22],
  ],
  mixli_canvas_city_night: [
    ['circle', .78, .20, .075, 'accent'], ['rect', .12, .34, .22, .28, .03, 'surface'],
    ['rect', .39, .28, .18, .34, .03, 'muted'], ['rect', .62, .39, .18, .23, .03, 'surface'],
    ['line', .08, .76, .34, .68, .018], ['line', .34, .68, .60, .78, .018],
    ['line', .60, .78, .90, .67, .018],
  ],
  mixli_canvas_pattern: [
    ['circle', .18, .50, .08, 'accent'], ['rect', .34, .42, .16, .16, .02, 'surface'],
    ['circle', .62, .50, .12, 'accent'], ['rect', .78, .34, .24, .24, .02, 'muted'],
  ],
  mixli_canvas_orbit: [
    ['circle', .50, .50, .11, 'accent'], ['circle', .22, .28, .025, 'surface'],
    ['circle', .78, .30, .025, 'surface'], ['circle', .68, .76, .025, 'surface'],
    ['line', .18, .50, .82, .50, .008, 'muted'], ['line', .32, .20, .68, .80, .008, 'surface'],
  ],
  mixli_canvas_color_energy: [
    ['circle', .28, .46, .19, 'accent'], ['circle', .50, .38, .15, 'surface'],
    ['circle', .68, .56, .21, 'muted'], ['rect', .16, .72, .68, .035, .018, 'surface'],
  ],
  mixli_canvas_quick_logic: [
    ['label', .16, .46, '2', .13], ['label', .32, .46, '6', .13],
    ['label', .50, .46, '12', .13], ['label', .70, .46, '20', .13],
    ['circle', .87, .46, .07, 'accent'],
  ],
} as const;
```

Keep a small explicit `canvasAssetFromRecipe()` converter in this file. It must accept only the four tuple tags shown above, set `fill: true` for circles/rectangles, and throw on an unknown tuple tag. The matchstick Play document uses the exact drag origin `(0.335, 0.35)`, drag size `(0.03, 0.14)`, target `solution_a` at `(0.185, 0.29, 0.05, 0.14)`, `target_region` validation, and the prompt `Move one match.`.

Each document must use schema version 1, one registered canvas asset, concise copy, and only supported inputs/validators. Use drag/`target_region` for the matchstick Play, `single_choice` with `equals` for three Plays, and `single_choice` with `none` for the two preference Plays. Keep source text below three percent of the visual hierarchy.

Add six corresponding canvas definitions using only the supported `circle`, `rect`, `line`, and `label` primitives. Every coordinate must remain in normalized `0..1` bounds. Use the existing `foreground`, `surface`, `muted`, and `accent` tones; no image/audio/video IDs are permitted in the starter set.

- [ ] **Step 4: Implement immutable, idempotent application and verification**

For every canvas and Play revision:

```ts
await canvasRepository.register(asset);
await pool.query('insert into plays (id) values ($1) on conflict (id) do nothing', [play.id]);
await pool.query(
  `insert into play_revisions (play_id, revision_id, schema_version, document)
   values ($1, $2, 1, $3::jsonb)
   on conflict (play_id, revision_id) do nothing`,
  [play.id, play.revisionId, JSON.stringify(play.document)],
);
const stored = await pool.query<{matches: boolean}>(
  `select document = $3::jsonb as matches from play_revisions
    where play_id = $1 and revision_id = $2`,
  [play.id, play.revisionId, JSON.stringify(play.document)],
);
if (stored.rows[0]?.matches !== true) throw new Error(`Starter revision conflict: ${play.id}/${play.revisionId}`);
```

Upsert owned topics and `play_revision_topics`; upsert only the six owned `feed_catalog_entries` to `eligible`, with quality prior `0.85` and deterministic order `1..6`. Do not delete or update rows outside the starter prefix.

`verifyProductionCatalog()` must query the starter prefix, require exactly six eligible Plays, require every referenced asset to exist in `canvas_assets`, and throw on any mismatch.

- [ ] **Step 5: Add the production CLI**

Create `bootstrap_catalog.ts`:

```ts
import {Pool} from 'pg';
import {loadConfig} from './config.js';
import {applyProductionCatalog, verifyProductionCatalog} from './production_catalog.js';

const mode = process.argv[2];
if (mode !== 'apply' && mode !== 'verify') {
  console.error('Usage: bootstrap_catalog.js {apply|verify}');
  process.exitCode = 64;
} else {
  const pool = new Pool({connectionString: loadConfig().databaseUrl});
  try {
    const status = mode === 'apply'
      ? await applyProductionCatalog(pool)
      : await verifyProductionCatalog(pool);
    console.log(JSON.stringify(status));
  } finally {
    await pool.end();
  }
}
```

Add to `apps/api/package.json`:

```json
"bootstrap:catalog": "tsx src/bootstrap_catalog.ts apply"
```

- [ ] **Step 6: Run API typecheck/test/build on the server and verify GREEN**

Run:

```bash
npm run typecheck
npm test
npm run build
```

Expected: the catalog test passes twice against PostgreSQL, unrelated content remains, and TypeScript/build exit 0.

- [ ] **Step 7: Commit**

```bash
git add apps/api/src/production_catalog.ts apps/api/src/bootstrap_catalog.ts apps/api/test/production_catalog_postgres.test.ts apps/api/package.json apps/api/package-lock.json
git commit -m "feat(feed): add production starter catalog"
```

### Task 3: Gate deployment on starter content

**Files:**
- Modify: `ops/production/tests/deployment.bats`
- Modify: `ops/production/bin/deployment.sh`

- [ ] **Step 1: Write failing deployment-order tests**

Add assertions to `deployment.bats`:

```bash
@test "catalog bootstrap succeeds after migration and before candidate start" {
  run deploy "$SHA"
  [ "$status" -eq 0 ]
  migration_line="$(grep -n "^migrated:$SHA$" "$TEST_ROOT/log/deploy-events.log" | cut -d: -f1)"
  catalog_line="$(grep -n '^catalog-ready$' "$TEST_ROOT/log/deploy-events.log" | cut -d: -f1)"
  ready_line="$(grep -n '^ready:green:1$' "$TEST_ROOT/log/deploy-events.log" | cut -d: -f1)"
  [ "$migration_line" -lt "$catalog_line" ]
  [ "$catalog_line" -lt "$ready_line" ]
}

@test "catalog failure never switches API or web" {
  MIXLI_TEST_FAIL_STAGE=catalog run deploy "$SHA"
  [ "$status" -ne 0 ]
  [ "$(readlink "$TEST_ROOT/current")" = "$TEST_ROOT/releases/$OLD_SHA" ]
  ! grep -q "^deployed:$SHA:" "$TEST_ROOT/log/deploy-events.log"
}
```

- [ ] **Step 2: Run focused deployment tests on the server and verify RED**

Run:

```bash
bats ops/production/tests/deployment.bats --filter 'catalog'
```

Expected: FAIL because no `catalog-ready` stage exists.

- [ ] **Step 3: Implement the catalog stage**

Add:

```bash
bootstrap_catalog() {
  fail_if_requested catalog
  if [[ "$TEST_MODE" == '1' ]]; then
    log_event 'catalog-ready'
    return 0
  fi
  if [[ "$target_pool" == 'blue' ]]; then
    MIXLI_API_BLUE_IMAGE="mixli-api:$SHA" MIXLI_API_BLUE_RELEASE_SHA="$SHA" \
      compose run --rm --no-deps api-blue-1 node dist/bootstrap_catalog.js apply
  else
    MIXLI_API_GREEN_IMAGE="mixli-api:$SHA" MIXLI_API_GREEN_RELEASE_SHA="$SHA" \
      compose run --rm --no-deps api-green-1 node dist/bootstrap_catalog.js apply
  fi
  log_event 'catalog-ready'
}
```

Call `bootstrap_catalog` immediately after `backup_and_migrate "$current_sha"` and before `start_candidate`.

- [ ] **Step 4: Run deployment Bats and ShellCheck on the server**

Run:

```bash
bats ops/production/tests/deployment.bats
shellcheck ops/production/bin/deployment.sh
```

Expected: all tests pass; catalog failure leaves the old web/API active.

- [ ] **Step 5: Commit**

```bash
git add ops/production/bin/deployment.sh ops/production/tests/deployment.bats
git commit -m "feat(deploy): require starter catalog"
```

### Task 4: Build the guest engagement state machine

**Files:**
- Create: `apps/mosaic_app/lib/guest_engagement.dart`
- Create: `apps/mosaic_app/test/guest_engagement_test.dart`

- [ ] **Step 1: Write pure failing controller tests**

Cover these exact cases with an in-memory `GuestEngagementStore`:

```dart
test('five distinct visible revisions unlock one prompt', () async {
  final store = _MemoryGuestStore();
  final controller = GuestEngagementController(store: store, clock: () => now);
  await controller.initialize();
  for (var index = 0; index < 5; index += 1) {
    await controller.recordVisible(feedRequestId: 'request', revisionId: 'rev_$index');
  }
  expect(controller.shouldPrompt, isTrue);
  expect(store.state?.seenIdentities, hasLength(5));
});

test('duplicates rebuilds and retry visibility do not advance eligibility', () async {
  final controller = GuestEngagementController(store: _MemoryGuestStore(), clock: () => now);
  await controller.initialize();
  for (var index = 0; index < 8; index += 1) {
    await controller.recordVisible(feedRequestId: 'same', revisionId: 'rev_same');
  }
  expect(controller.shouldPrompt, isFalse);
});

test('dismissal suppresses the session and enforces a seven day cooldown', () async {
  final store = _MemoryGuestStore();
  var clock = now;
  final controller = GuestEngagementController(store: store, clock: () => clock);
  await controller.initialize();
  for (var index = 0; index < 5; index += 1) {
    await controller.recordVisible(feedRequestId: 'request', revisionId: 'rev_$index');
  }
  await controller.dismissPrompt();
  expect(controller.shouldPrompt, isFalse);
  clock = now.add(const Duration(days: 6, hours: 23));
  expect(controller.shouldPrompt, isFalse);
  clock = now.add(const Duration(days: 7));
  expect(controller.shouldPrompt, isTrue);
});
```

Also test malformed persisted JSON falls back to an empty state and a record arriving before `initialize()` completes is merged rather than lost.

- [ ] **Step 2: Run the focused Flutter test on the server and verify RED**

Run in the pinned Flutter image:

```bash
cd /workspace/apps/mosaic_app
flutter test test/guest_engagement_test.dart
```

Expected: FAIL because `guest_engagement.dart` does not exist.

- [ ] **Step 3: Implement the state, store, and controller**

Use this public surface:

```dart
final class GuestEngagementState {
  const GuestEngagementState({this.seenIdentities = const [], this.dismissedAt});
  final List<String> seenIdentities;
  final DateTime? dismissedAt;
  Map<String, Object?> toJson();
  factory GuestEngagementState.fromJson(Map<String, Object?> json);
}

abstract interface class GuestEngagementStore {
  Future<GuestEngagementState?> readGuestEngagement();
  Future<void> writeGuestEngagement(GuestEngagementState state);
}

final class GuestEngagementController extends ChangeNotifier {
  GuestEngagementController({required GuestEngagementStore store, DateTime Function()? clock});
  static const promptThreshold = 5;
  static const promptCooldown = Duration(days: 7);
  bool get shouldPrompt;
  Future<void> initialize();
  Future<void> recordVisible({required String feedRequestId, required String revisionId});
  Future<void> dismissPrompt();
}
```

Normalize identities as `feedRequestId\u0000revisionId`, bound storage to five identities, serialize writes behind one tail future, and call `notifyListeners()` only when eligibility changes. `shouldPrompt` must require initialization, five identities, no in-session dismissal, and no active cooldown.

- [ ] **Step 4: Run focused tests on the server and verify GREEN**

Run:

```bash
flutter test test/guest_engagement_test.dart
```

Expected: all controller tests pass without timers or network mocks.

- [ ] **Step 5: Commit**

```bash
git add apps/mosaic_app/lib/guest_engagement.dart apps/mosaic_app/test/guest_engagement_test.dart
git commit -m "feat(home): track guest engagement eligibility"
```

### Task 5: Persist guest prompt state on web and native

**Files:**
- Modify: `apps/mosaic_app/lib/consumer_local_state_web.dart`
- Modify: `apps/mosaic_app/lib/consumer_local_state_native.dart`
- Modify: `packages/local_state/lib/local_state.dart`
- Modify: `packages/local_state/test/consumer_recovery_v2_test.dart`
- Modify: `apps/mosaic_app/test/consumer_local_state_web_test.dart`

- [ ] **Step 1: Write failing reopen tests**

For web, write state through an `IndexedDbConsumerLocalState`, close/reopen the same database, and expect the five identities and UTC dismissal timestamp to survive. For native, write through `SqliteConsumerLocalState`, close/reopen the same SQLite file, and assert the same values. Add malformed JSON cases that return `null` and delete the invalid metadata.

- [ ] **Step 2: Run the two persistence tests on the server and verify RED**

Run:

```bash
cd /workspace/apps/mosaic_app
flutter test --platform chrome test/consumer_local_state_web_test.dart
flutter test test/consumer_local_state_native_test.dart
```

Expected: FAIL because the concrete stores do not implement `GuestEngagementStore`.

- [ ] **Step 3: Add narrowly scoped storage adapters**

Change both concrete classes to implement `GuestEngagementStore` and use the key `guest_engagement.v1`.

Web methods:

```dart
@override
Future<GuestEngagementState?> readGuestEngagement() async {
  final encoded = await _store.readConsumerMetadata(_guestEngagementKey);
  if (encoded == null) return null;
  try {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) throw const FormatException('guest engagement must be an object');
    return GuestEngagementState.fromJson(decoded.map((key, value) => MapEntry(key.toString(), value)));
  } on Object {
    await _store.deleteConsumerMetadata(_guestEngagementKey);
    return null;
  }
}

@override
Future<void> writeGuestEngagement(GuestEngagementState state) =>
    _store.writeConsumerMetadata(_guestEngagementKey, jsonEncode(state.toJson()));
```

Add equivalent specific `loadGuestEngagementJson()` and `saveGuestEngagementJson(String value)` methods to `MosaicLocalStore`; do not expose unrestricted metadata access. The SQLite adapter parses/cleans invalid JSON exactly like web.

- [ ] **Step 4: Run web/native persistence suites on the server and verify GREEN**

Run the two commands from Step 2 plus:

```bash
cd /workspace/packages/local_state
dart test --reporter=expanded
```

Expected: reopen and malformed-state tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/mosaic_app/lib/consumer_local_state_web.dart apps/mosaic_app/lib/consumer_local_state_native.dart apps/mosaic_app/test/consumer_local_state_web_test.dart apps/mosaic_app/test/consumer_local_state_native_test.dart packages/local_state/lib/local_state.dart packages/local_state/test/consumer_recovery_v2_test.dart
git commit -m "feat(home): persist guest prompt state"
```

### Task 6: Replace onboarding with the guest-first home

**Files:**
- Create: `apps/mosaic_app/lib/guest_home.dart`
- Create: `apps/mosaic_app/test/guest_home_test.dart`
- Modify: `apps/mosaic_app/lib/main.dart`
- Modify: `apps/mosaic_app/test/app_test.dart`

- [ ] **Step 1: Write failing guest-home widget tests**

Create tests that mount `GuestHome` with a memory controller and assert:

```dart
testWidgets('feed is visible before any registration request', (tester) async {
  await tester.pumpWidget(_app(controller: controller, child: const Text('First Play')));
  await tester.pumpAndSettle();
  expect(find.text('First Play'), findsOneWidget);
  expect(find.text('What are you into?'), findsNothing);
  expect(find.text('Your Mixli is getting good'), findsNothing);
});

testWidgets('eligible guest sees a dismissible signup sheet without losing feed', (tester) async {
  await _unlock(controller);
  await tester.pumpWidget(_app(controller: controller, child: const Text('Fifth Play')));
  await tester.pumpAndSettle();
  expect(find.text('Fifth Play'), findsOneWidget);
  expect(find.text('Your Mixli is getting good'), findsOneWidget);
  expect(find.text('Join Mixli'), findsOneWidget);
  expect(find.text('Not now'), findsOneWidget);
  await tester.tap(find.text('Not now'));
  await tester.pumpAndSettle();
  expect(find.text('Fifth Play'), findsOneWidget);
  expect(find.text('Your Mixli is getting good'), findsNothing);
});
```

Add a test that `Join Mixli` opens copy saying `Accounts are opening soon` and never says `Account created`. Add 390x844 at 1.6x text scale, RTL, semantics-label, and reduced-motion cases.

- [ ] **Step 2: Change `app_test.dart` first-launch expectation and verify RED on the server**

Replace the onboarding assertions with:

```dart
expect(find.text('What are you into?'), findsNothing);
expect(find.byKey(const ValueKey<String>('guest-home')), findsOneWidget);
expect(find.byKey(const ValueKey<String>('feed-empty-retry')), findsOneWidget);
```

Run:

```bash
flutter test test/guest_home_test.dart test/app_test.dart
```

Expected: FAIL because `GuestHome` does not exist and `MosaicApp` still uses `ConsumerOnboardingGate`.

- [ ] **Step 3: Implement `GuestHome`**

Expose:

```dart
final class GuestHome extends StatefulWidget {
  const GuestHome({required this.engagement, required this.child, required this.onSearch, super.key});
  final GuestEngagementController engagement;
  final Widget child;
  final VoidCallback onSearch;
}
```

Build a `Scaffold`/`Stack` with key `guest-home`, the full-bleed child, a safe-area top row containing a compact lowercase `mixli` wordmark, centered `For You`, and a semantic search button. Listen to the controller and schedule `showModalBottomSheet` after the current frame when eligibility changes. Use an opaque near-black sheet, 28px top corners, no blur, 48px minimum targets, and `useSafeArea: true`.

The sheet copy and actions are exactly:

```dart
Text('Your Mixli is getting good')
Text('Keep this feed and your progress.')
FilledButton(onPressed: openEarlyAccess, child: const Text('Join Mixli'))
TextButton(onPressed: dismiss, child: const Text('Not now'))
```

`openEarlyAccess` pushes a page with `Accounts are opening soon`, `Your guest feed stays right here.`, and `Back to exploring`. It must not collect credentials or claim registration.

- [ ] **Step 4: Wire `MosaicApp` directly to the feed**

In `_MosaicAppState`, create and initialize a `GuestEngagementController` using the local state when it implements `GuestEngagementStore`, otherwise a session-only in-memory store. Dispose it with the other controllers.

Extend `_recordFeedEvent`:

```dart
if (event == MosaicEventName.playVisible) {
  unawaited(_guestEngagement.recordVisible(
    feedRequestId: feedRequestId,
    revisionId: playRevisionId,
  ));
}
```

Replace `ConsumerOnboardingGate` at `home:` with `GuestHome`. Keep `ConsumerOnboarding` code available for later contextual preference editing, but it must not be mounted on startup.

- [ ] **Step 5: Run guest-home and app tests on the server and verify GREEN**

Run:

```bash
flutter test test/guest_engagement_test.dart test/guest_home_test.dart test/app_test.dart
```

Expected: direct feed launch and progressive prompt tests pass with no overflow or semantics errors.

- [ ] **Step 6: Commit**

```bash
git add apps/mosaic_app/lib/guest_home.dart apps/mosaic_app/lib/main.dart apps/mosaic_app/test/guest_home_test.dart apps/mosaic_app/test/app_test.dart
git commit -m "feat(home): launch into guest discovery feed"
```

### Task 7: Make feed loading and empty states brand-friendly

**Files:**
- Modify: `apps/mosaic_app/lib/consumer_feed.dart`
- Modify: `apps/mosaic_app/test/consumer_feed_test.dart`

- [ ] **Step 1: Write failing recovery-surface tests**

For a retryable empty response, assert:

```dart
expect(find.text('Fresh Plays are loading'), findsOneWidget);
expect(find.text('Try again'), findsOneWidget);
expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
expect(find.text('Topics unavailable'), findsNothing);
```

For a successful empty catalog response, assert `Nothing fresh yet` and `Refresh` rather than an icon-only surface.

- [ ] **Step 2: Run focused feed tests on the server and verify RED**

Run:

```bash
flutter test test/consumer_feed_test.dart
```

Expected: FAIL because `_FeedEmptyState` is icon-only.

- [ ] **Step 3: Implement the compact recovery surface**

Replace `_FeedEmptyState` with a centered constrained column on `Color(0xFF050505)`:

```dart
Icon(failed ? Icons.wifi_tethering_error_rounded : Icons.auto_awesome_rounded, size: 34)
Text(failed ? 'Fresh Plays are loading' : 'Nothing fresh yet')
Text(failed ? 'Your feed is safe. Give it another moment.' : 'Come back soon for a new mix.')
FilledButton.tonalIcon(
  key: const ValueKey<String>('feed-empty-retry'),
  onPressed: onRetry,
  icon: const Icon(Icons.refresh_rounded),
  label: Text(failed ? 'Try again' : 'Refresh'),
)
```

Keep text concise, support RTL/large text, and do not animate continuously.

- [ ] **Step 4: Run feed and app tests on the server and verify GREEN**

Run:

```bash
flutter test test/consumer_feed_test.dart test/app_test.dart
```

Expected: recovery copy, retry action, and feed-first launch pass.

- [ ] **Step 5: Commit**

```bash
git add apps/mosaic_app/lib/consumer_feed.dart apps/mosaic_app/test/consumer_feed_test.dart
git commit -m "feat(feed): add friendly recovery surface"
```

### Task 8: Extend independent production verification

**Files:**
- Modify: `ops/production/bin/verify-production.sh`
- Modify: `ops/production/tests/verify_script.bats`

- [ ] **Step 1: Write failing verification contracts**

Add a `guest catalog` origin check contract that requires:

```bash
check_guest_catalog() {
  local topics
  topics="$(curl_endpoint api.mixli.app '/v1/topics?limit=6')"
  [[ "$(jq '.topics | length' <<<"$topics")" -ge 6 ]]
}
```

Add `run_check 'guest catalog' check_guest_catalog` only in origin mode. In `verify_script.bats`, expect origin mode to report eight checks and public mode to remain three.

- [ ] **Step 2: Run verifier Bats on the server and verify RED**

Run:

```bash
bats ops/production/tests/verify_script.bats
```

Expected: FAIL because `guest catalog` is absent.

- [ ] **Step 3: Implement the check and preserve public verifier scope**

Add the function and origin-only `run_check` exactly as above. Do not add actor credentials or mutate production data during verification.

- [ ] **Step 4: Run verifier tests and ShellCheck on the server**

Run:

```bash
bats ops/production/tests/verify_script.bats
shellcheck ops/production/bin/verify-production.sh
```

Expected: origin contract passes with eight checks; public contract remains three.

- [ ] **Step 5: Commit**

```bash
git add ops/production/bin/verify-production.sh ops/production/tests/verify_script.bats
git commit -m "test(prod): verify guest catalog readiness"
```

### Task 9: Full server CI, review, merge, and deploy

**Files:**
- Review all files changed by Tasks 1–8.

- [ ] **Step 1: Run format/diff checks without local builds**

Run locally only:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only intended files changed.

- [ ] **Step 2: Push the candidate branch and run the full server gate**

Push the exact candidate SHA, create/fetch its detached build-owned checkout on the server, then run:

```bash
candidate_sha="$(git rev-parse HEAD)"
sudo -u mixli-build git -C /srv/mixli/repository fetch origin codex/low-cost-two-lane-ci
sudo -u mixli-build git -C /srv/mixli/repository cat-file -e "$candidate_sha^{commit}"
if [[ ! -e "/srv/mixli/builds/$candidate_sha" ]]; then
  sudo -u mixli-build git -C /srv/mixli/repository worktree add --detach \
    "/srv/mixli/builds/$candidate_sha" "$candidate_sha"
fi
sudo /opt/mixli/bin/server-ci.sh "/srv/mixli/builds/$candidate_sha" "$candidate_sha"
```

Expected stages, all successful:

```text
source-integrity
infrastructure-contracts
api-postgres-integration
flutter-workspace
platform-declarations
production-builds
```

- [ ] **Step 3: Perform code review**

Review for:

- no startup onboarding mount;
- no fake account-success claim;
- no unregistered asset references;
- no deletion of non-starter catalog content;
- no API URL path such as `/root`;
- bounded guest identity state and serialized persistence;
- no local build/test artifacts.

Fix any findings with new test-first commits and rerun affected server suites.

- [ ] **Step 4: Fast-forward `main` and let the lightweight dispatcher trigger server deployment**

Before pushing:

```bash
git fetch origin main
git merge-base --is-ancestor origin/main HEAD
git push origin HEAD:main
```

Expected: fast-forward succeeds. Set `short_sha="$(git rev-parse --short=12 HEAD)"` and follow `mixli-deploy-$short_sha.service` until it is inactive with `Result=success` and `ExecMainStatus=0`.

- [ ] **Step 5: Run fresh post-deploy verification**

On the server:

```bash
sudo /opt/mixli/bin/verify-production.sh --origin
sudo /opt/mixli/bin/verify-production.sh --public
```

Expected: origin `8 passed, 0 failed`; public `3 passed, 0 failed`.

Verify three container snapshots over at least 40 seconds. Require all eleven production containers to remain running with unchanged restart counts and Prometheus at `running:0`.

- [ ] **Step 6: Verify the browser-facing release**

From the workstation, use read-only HTTP checks:

```bash
curl -fsS https://api.mixli.app/v1/topics?limit=6
curl -fsSI https://mixli.app/
curl -fsSI https://api.mixli.app/ready
```

Expected: at least six topics, homepage/API HTTP 200, and `x-mixli-release` equals the merged SHA.

Open a clean/incognito browser profile and confirm:

1. first launch opens a playable feed, not `What are you into?`;
2. at least two interaction styles appear in the first window;
3. the sign-up sheet is absent for Plays 1–4;
4. it appears after the fifth distinct Play;
5. `Not now` returns to the same feed position;
6. refresh does not immediately reopen it;
7. `Join Mixli` truthfully shows early-access copy.

- [ ] **Step 7: Record final state**

Confirm:

```bash
git status --short
git rev-parse HEAD
git rev-parse origin/main
```

Expected: clean worktree and identical local/main/production SHA.

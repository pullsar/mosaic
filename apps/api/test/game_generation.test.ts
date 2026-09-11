import {deepEqual, equal, notDeepEqual, notEqual, throws} from 'node:assert/strict';
import {mkdtemp, readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';

import {normalizeCanvasAssetDocument} from '../src/canvas_asset.js';
import {checkPlayCompatibility} from '../src/contracts/compatibility.js';
import {approveEditorialDraft} from '../src/game_editorial.js';
import {generateOneMoveMatchstickDrafts} from '../src/game_generation.js';
import {
  parseOneMoveGenerationCliArgs,
  writeOneMoveGenerationDrafts,
} from '../src/game_generation_cli.js';
import {
  enumerateOneMoveMatchstickSolutions,
  oneMoveMatchstickSolverVersion,
} from '../src/game_solvers.js';

test('One Move generation is byte-stable and independently solver-checked', () => {
  const first = generateOneMoveMatchstickDrafts({seed: 734, count: 3});
  const repeated = generateOneMoveMatchstickDrafts({seed: 734, count: 3});

  deepEqual(first, repeated);
  equal(first.drafts.length, 3);
  equal(new Set(first.drafts.map((draft) => draft.structuralSignature)).size, 3);
  for (const draft of first.drafts) {
    deepEqual(
      enumerateOneMoveMatchstickSolutions(new Set(draft.sourceSegments)),
      [draft.solution],
    );
    equal(
      draft.media.sourceCanvasAssetId,
      `draft_matchsticks_${draft.themeId}_${draft.canonicalHash}_source`,
    );
    equal(
      draft.media.solvedCanvasAssetId,
      `draft_matchsticks_${draft.themeId}_${draft.canonicalHash}_solved`,
    );
    equal(draft.canvasAssets.length, 2);
    deepEqual(
      draft.canvasAssets.map((asset) => asset.id),
      [draft.media.sourceCanvasAssetId, draft.media.solvedCanvasAssetId],
    );
    for (const asset of draft.canvasAssets) {
      deepEqual(normalizeCanvasAssetDocument(asset), asset);
    }
    deepEqual(
      checkPlayCompatibility(draft.document, {
        schemaVersions: [1],
        presentationTypes: ['canvas', 'scene', 'text'],
        inputTypes: ['piece_move', 'tap'],
        validatorTypes: ['legal_piece_move', 'none'],
        platformFlags: [],
      }),
      {compatible: true, missing: []},
    );
    equal(draft.document.id, `draft_one_move_${draft.canonicalHash}`);
    deepEqual(draft.document.assets, [
      draft.media.sourceCanvasAssetId,
      draft.media.solvedCanvasAssetId,
    ]);
    deepEqual(draft.editorial.mediaAssetIds, draft.document.assets);
    equal(draft.editorial.draftHash, draft.canonicalHash);
    equal(draft.editorial.solverVersion, oneMoveMatchstickSolverVersion);
    equal(
      approveEditorialDraft(draft.editorial, {
        reviewerId: 'editor_1',
        approvedAt: '2026-09-11T12:00:00.000Z',
        checks: {
          answer_proof: true,
          visible_clue: true,
          semantic_leakage: true,
          input_reveal: true,
          fresh_structure: true,
          sound_masking: true,
          asset_rights: true,
          accessibility: true,
          moderation: true,
          performance: true,
        },
      }).draftHash,
      draft.canonicalHash,
    );
  }
});

test('a curated theme changes generated One Move material without changing its answer', () => {
  const random = generateOneMoveMatchstickDrafts({seed: 91, count: 1});
  const paper = generateOneMoveMatchstickDrafts({
    seed: 91,
    count: 1,
    themePreference: 'paper-studio',
  });

  deepEqual(random.drafts[0]!.sourceSegments, paper.drafts[0]!.sourceSegments);
  deepEqual(random.drafts[0]!.solution, paper.drafts[0]!.solution);
  equal(paper.drafts[0]!.themeId, 'paper-studio');
  equal(paper.drafts[0]!.themePreference, 'paper-studio');

  const orbital = generateOneMoveMatchstickDrafts({
    seed: 91,
    count: 1,
    themePreference: 'orbital',
  });
  deepEqual(paper.drafts[0]!.sourceSegments, orbital.drafts[0]!.sourceSegments);
  deepEqual(paper.drafts[0]!.solution, orbital.drafts[0]!.solution);
  equal(orbital.drafts[0]!.themeId, 'orbital');
  notDeepEqual(
    paper.drafts[0]!.canvasAssets[0]!.palette,
    orbital.drafts[0]!.canvasAssets[0]!.palette,
  );
  notEqual(paper.drafts[0]!.canonicalHash, orbital.drafts[0]!.canonicalHash);
});

test('One Move generation rejects unbounded requests', () => {
  throws(() => generateOneMoveMatchstickDrafts({seed: 1, count: 0}), /count/);
  throws(() => generateOneMoveMatchstickDrafts({seed: 1, count: 25}), /count/);
  throws(() => generateOneMoveMatchstickDrafts({seed: -1, count: 1}), /seed/);
  throws(
    () =>
      generateOneMoveMatchstickDrafts({
        seed: 1,
        count: 1,
        themePreference: 'unreviewed-neon',
      }),
    /curated theme/,
  );
});

test('local draft CLI requires an explicit output and writes no publication state', async () => {
  throws(
    () => parseOneMoveGenerationCliArgs(['--seed', '2', '--count', '1']),
    /output/,
  );
  const directory = await mkdtemp(join(tmpdir(), 'mixli-one-move-'));
  const request = parseOneMoveGenerationCliArgs([
    '--seed', '2', '--count', '1', '--theme', 'paper-studio',
    '--output', join(directory, 'drafts.json'),
  ]);
  const outputPath = await writeOneMoveGenerationDrafts(request);
  const value = JSON.parse(await readFile(outputPath, 'utf8')) as {
    drafts: Array<{
      themePreference?: string;
      canvasAssets?: Array<{id: string}>;
      document?: {assets: string[]};
    }>;
  };

  equal(value.drafts.length, 1);
  equal(value.drafts[0]!.themePreference, 'paper-studio');
  deepEqual(
    value.drafts[0]!.canvasAssets?.map((asset) => asset.id),
    value.drafts[0]!.document?.assets,
  );
});

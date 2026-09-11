import {deepEqual, equal, throws} from 'node:assert/strict';
import {mkdtemp, readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';

import {generateOneMoveMatchstickDrafts} from '../src/game_generation.js';
import {
  parseOneMoveGenerationCliArgs,
  writeOneMoveGenerationDrafts,
} from '../src/game_generation_cli.js';
import {enumerateOneMoveMatchstickSolutions} from '../src/game_solvers.js';

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
    equal(draft.media.sourceCanvasAssetId, `draft_matchsticks_${draft.canonicalHash}_source`);
    equal(draft.media.solvedCanvasAssetId, `draft_matchsticks_${draft.canonicalHash}_solved`);
  }
});

test('theme preference cannot change a generated One Move answer', () => {
  const random = generateOneMoveMatchstickDrafts({seed: 91, count: 1});
  const paper = generateOneMoveMatchstickDrafts({
    seed: 91,
    count: 1,
    themePreference: 'paper-studio',
  });

  deepEqual(random.drafts[0]!.sourceSegments, paper.drafts[0]!.sourceSegments);
  deepEqual(random.drafts[0]!.solution, paper.drafts[0]!.solution);
  equal(paper.drafts[0]!.themePreference, 'paper-studio');
});

test('One Move generation rejects unbounded requests', () => {
  throws(() => generateOneMoveMatchstickDrafts({seed: 1, count: 0}), /count/);
  throws(() => generateOneMoveMatchstickDrafts({seed: 1, count: 25}), /count/);
  throws(() => generateOneMoveMatchstickDrafts({seed: -1, count: 1}), /seed/);
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
    drafts: Array<{themePreference?: string}>;
  };

  equal(value.drafts.length, 1);
  equal(value.drafts[0]!.themePreference, 'paper-studio');
});

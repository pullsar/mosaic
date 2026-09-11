import {deepEqual, equal} from 'node:assert/strict';
import {test} from 'node:test';

import {
  enumerateOneMoveMatchstickSolutions,
  matchstickEquationFromSegments,
} from '../src/game_solvers.js';

test('independent matchstick solver derives the reviewed zero-plus-one move', () => {
  const source = new Set([
    'left.a', 'left.b', 'left.c', 'left.d', 'left.e', 'left.f',
    'operator.horizontal', 'operator.vertical',
    'right.b', 'right.c',
    'result.a', 'result.b', 'result.c', 'result.d', 'result.e', 'result.f', 'result.g',
  ]);

  equal(matchstickEquationFromSegments(source), '0 + 1 = 8');
  deepEqual(
    enumerateOneMoveMatchstickSolutions(source),
    [{from: 'result.e', to: 'left.g', equation: '8 + 1 = 9'}],
  );
});

test('independent matchstick solver rejects malformed and already-true equations', () => {
  equal(matchstickEquationFromSegments(new Set(['left.a'])), null);
  deepEqual(enumerateOneMoveMatchstickSolutions(new Set(['left.a'])), []);

  const trueEquation = new Set([
    'left.b', 'left.c',
    'operator.horizontal', 'operator.vertical',
    'right.b', 'right.c',
    'result.a', 'result.b', 'result.d', 'result.e', 'result.g',
  ]);
  equal(matchstickEquationFromSegments(trueEquation), '1 + 1 = 2');
  deepEqual(enumerateOneMoveMatchstickSolutions(trueEquation), []);
});

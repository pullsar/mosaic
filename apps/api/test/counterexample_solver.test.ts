import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  solveCounterexample,
  type CounterexampleClaim,
  type CounterexampleTile,
} from '../src/counterexample_solver.js';

const tiles: readonly CounterexampleTile[] = [
  {id: 'a', color: 'red', shape: 'round'},
  {id: 'b', color: 'red', shape: 'square'},
  {id: 'c', color: 'blue', shape: 'square'},
];

const claim: CounterexampleClaim = {color: 'red', shape: 'round'};

test('finds the one tile that disproves a bounded universal claim', () => {
  const solved = solveCounterexample(claim, tiles);

  assert.equal(solved.answerId, 'b');
  assert.deepEqual(solved.counterexampleIds, ['b']);
});

test('does not mistake a non-subject tile for a counterexample', () => {
  const solved = solveCounterexample(claim, [
    {id: 'a', color: 'red', shape: 'round'},
    {id: 'c', color: 'blue', shape: 'square'},
  ]);

  assert.equal(solved.answerId, 'insufficient');
  assert.deepEqual(solved.counterexampleIds, []);
});

test('rejects ambiguous or malformed finite predicate inputs', () => {
  assert.throws(
    () => solveCounterexample(claim, [
      ...tiles,
      {id: 'd', color: 'red', shape: 'square'},
    ]),
    /counterexample_ambiguous/,
  );
  assert.throws(
    () => solveCounterexample(claim, [
      {id: 'a', color: 'violet' as 'red', shape: 'round'},
    ]),
    /counterexample_tile/,
  );
});

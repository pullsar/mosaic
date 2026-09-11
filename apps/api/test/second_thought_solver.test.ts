import assert from 'node:assert/strict';
import {test} from 'node:test';
import {solveSecondThought} from '../src/second_thought_solver.js';

test('scores keep or change against evidence, independent of adviser agreement', () => {
  assert.deepEqual(solveSecondThought({initial: 'north', advice: 'south', evidence: 'north'}), {
    decision: 'keep', finalChoice: 'north', adviceAgrees: false,
  });
  assert.deepEqual(solveSecondThought({initial: 'south', advice: 'north', evidence: 'north'}), {
    decision: 'change', finalChoice: 'north', adviceAgrees: true,
  });
});

test('accepts an explicitly uncertain adviser without inventing advice', () => {
  assert.deepEqual(solveSecondThought({initial: 'south', advice: 'unsure', evidence: 'north'}), {
    decision: 'change', finalChoice: 'north', adviceAgrees: null,
  });
});
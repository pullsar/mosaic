import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  solveRuleFlip,
  type RuleFlipObject,
} from '../src/rule_flip_solver.js';

const object: RuleFlipObject = {shape: 'triangle', fill: 'striped'};

test('evaluates shape then fill as independent explicit trials', () => {
  assert.equal(solveRuleFlip('shape', object).side, 'left');
  assert.equal(solveRuleFlip('fill', object).side, 'right');
});

test('rejects unsupported trial, shape, or fill values', () => {
  assert.throws(() => solveRuleFlip('color' as 'shape', object), /rule_flip_trial/);
  assert.throws(
    () => solveRuleFlip('shape', {shape: 'square' as 'triangle', fill: 'solid'}),
    /rule_flip_object/,
  );
});
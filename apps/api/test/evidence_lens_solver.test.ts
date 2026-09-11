import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  solveEvidenceLens,
  type EvidenceLensClaim,
  type EvidenceLensPoint,
} from '../src/evidence_lens_solver.js';

const points: readonly EvidenceLensPoint[] = [
  {id: 'a', label: '2023', value: 10},
  {id: 'b', label: '2024', value: 15},
  {id: 'c', label: '2025', value: 12},
];

test('derives the exact source point for final, peak, and lowest claims', () => {
  const claims: readonly EvidenceLensClaim[] = [
    {id: 'final', kind: 'final', label: 'Final value: 12.'},
    {id: 'peak', kind: 'peak', label: 'Peak value: 15.'},
    {id: 'lowest', kind: 'lowest', label: 'Lowest value: 10.'},
  ];
  assert.deepEqual(
    claims.map((claim) => solveEvidenceLens(claim, points).answerId),
    ['c', 'b', 'a'],
  );
});

test('rejects ambiguous extrema and labels that disagree with data', () => {
  assert.throws(
    () => solveEvidenceLens(
      {id: 'peak', kind: 'peak', label: 'Peak value: 15.'},
      [...points, {id: 'd', label: '2026', value: 15}],
    ),
    /evidence_lens_ambiguous/,
  );
  assert.throws(
    () => solveEvidenceLens(
      {id: 'final', kind: 'final', label: 'Final value: 13.'}, points,
    ),
    /evidence_lens_claim_label/,
  );
});
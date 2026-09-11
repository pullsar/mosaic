import {deepEqual, equal, throws} from 'node:assert/strict';
import {simulateSleightTrajectory} from '../src/sleight_solver.js';
import {test} from 'node:test';

test('Sleight simulator follows the coin through cup swaps', () => {
  const result = simulateSleightTrajectory({
    cupIds: ['left', 'center', 'right'],
    coinStartCupId: 'left',
    events: [
      {atMs: 250, type: 'occlude', cupId: 'left'},
      {atMs: 600, type: 'swap', firstCupId: 'left', secondCupId: 'right'},
      {atMs: 1000, type: 'swap', firstCupId: 'center', secondCupId: 'right'},
    ],
  });

  equal(result.finalCupId, 'left');
  equal(result.finalPositionId, 'right');
  deepEqual(result.positionsByCupId, {
    left: 'right',
    center: 'left',
    right: 'center',
  });
});

test('Sleight simulator accounts for an authored coin transfer', () => {
  const result = simulateSleightTrajectory({
    cupIds: ['left', 'center', 'right'],
    coinStartCupId: 'left',
    events: [
      {atMs: 300, type: 'transfer', fromCupId: 'left', toCupId: 'center'},
      {atMs: 700, type: 'swap', firstCupId: 'center', secondCupId: 'right'},
    ],
  });

  equal(result.finalCupId, 'center');
  equal(result.finalPositionId, 'right');
});

test('Sleight simulator rejects ambiguous or impossible event streams', () => {
  expectTrajectoryFailure({
    cupIds: ['left', 'left', 'right'],
    coinStartCupId: 'left',
    events: [],
  });
  expectTrajectoryFailure({
    cupIds: ['left', 'center', 'right'],
    coinStartCupId: 'left',
    events: [{atMs: 100, type: 'transfer', fromCupId: 'center', toCupId: 'right'}],
  });
  expectTrajectoryFailure({
    cupIds: ['left', 'center', 'right'],
    coinStartCupId: 'left',
    events: [
      {atMs: 500, type: 'occlude', cupId: 'left'},
      {atMs: 200, type: 'occlude', cupId: 'left'},
    ],
  });
});

function expectTrajectoryFailure(input: Parameters<typeof simulateSleightTrajectory>[0]): void {
  throws(() => simulateSleightTrajectory(input), /sleight_/);
}

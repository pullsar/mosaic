import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  evaluateConstellationRound,
  type ConstellationTrajectory,
} from '../src/constellation_solver.js';

const trajectory: ConstellationTrajectory = {
  objectIds: ['a', 'b', 'c', 'd', 'e', 'f'],
  durationMs: 1200,
  tracks: [
    {objectId: 'a', keyframes: [{timeMs: 0, x: .1, y: .2, width: .06, height: .06}, {timeMs: 1200, x: .2, y: .2, width: .06, height: .06}]},
    {objectId: 'b', keyframes: [{timeMs: 0, x: .3, y: .2, width: .06, height: .06}, {timeMs: 1200, x: .4, y: .2, width: .06, height: .06}]},
    {objectId: 'c', keyframes: [{timeMs: 0, x: .5, y: .2, width: .06, height: .06}, {timeMs: 1200, x: .6, y: .2, width: .06, height: .06}]},
    {objectId: 'd', keyframes: [{timeMs: 0, x: .1, y: .6, width: .06, height: .06}, {timeMs: 1200, x: .2, y: .6, width: .06, height: .06}]},
    {objectId: 'e', keyframes: [{timeMs: 0, x: .3, y: .6, width: .06, height: .06}, {timeMs: 1200, x: .4, y: .6, width: .06, height: .06}]},
    {objectId: 'f', keyframes: [{timeMs: 0, x: .5, y: .6, width: .06, height: .06}, {timeMs: 1200, x: .6, y: .6, width: .06, height: .06}]},
  ],
};

test('Constellation accepts the marked pair in any selection order', () => {
  const result = evaluateConstellationRound(trajectory, ['b', 'e']);

  assert.deepEqual(result.acceptedObjectIds, ['b', 'e']);
  assert.deepEqual(result.finalRects.get('b'), {
    x: .4,
    y: .2,
    width: .06,
    height: .06,
  });
});

test('Constellation rejects duplicate targets and colliding paths', () => {
  assert.throws(
    () => evaluateConstellationRound(trajectory, ['b', 'b']),
    /constellation_duplicate_target/,
  );
  const colliding: ConstellationTrajectory = {
    ...trajectory,
    tracks: trajectory.tracks.map((track) =>
      track.objectId === 'b'
        ? {
            ...track,
            keyframes: [
              track.keyframes[0]!,
              {timeMs: 1200, x: .2, y: .2, width: .06, height: .06},
            ],
          }
        : track,
    ),
  };
  assert.throws(
    () => evaluateConstellationRound(colliding, ['b', 'e']),
    /constellation_path_collision/,
  );
});

test('Constellation catches a collision between millisecond samples', () => {
  const transient: ConstellationTrajectory = {
    ...trajectory,
    durationMs: 3001,
    tracks: trajectory.tracks.map((track, index) => {
      if (track.objectId === 'a') {
        return {
          ...track,
          keyframes: [
            {timeMs: 0, x: .1, y: .2, width: .00001, height: .00001},
            {timeMs: 3001, x: .7, y: .2, width: .00001, height: .00001},
          ],
        };
      }
      if (track.objectId === 'b') {
        return {
          ...track,
          keyframes: [
            {timeMs: 0, x: .7, y: .2, width: .00001, height: .00001},
            {timeMs: 3001, x: .1, y: .2, width: .00001, height: .00001},
          ],
        };
      }
      return {
        ...track,
        keyframes: [
          {timeMs: 0, x: .1 + index * .15, y: .8, width: .01, height: .01},
          {timeMs: 3001, x: .1 + index * .15, y: .8, width: .01, height: .01},
        ],
      };
    }),
  };

  assert.throws(
    () => evaluateConstellationRound(transient, ['b', 'e']),
    /constellation_path_collision/,
  );
});

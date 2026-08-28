import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mediaAttemptStorageKey} from '../src/media_ffmpeg_worker.js';

test('each worker claim receives a distinct immutable publication key', () => {
  const first = mediaAttemptStorageKey('asset', 'mdv1', 'claim-a', 'playback');
  const second = mediaAttemptStorageKey('asset', 'mdv1', 'claim-b', 'playback');
  assert.notEqual(first, second);
  assert.equal(first, 'media/asset/derivatives/mdv1/attempts/claim-a.mp4');
  assert.equal(second, 'media/asset/derivatives/mdv1/attempts/claim-b.mp4');
});

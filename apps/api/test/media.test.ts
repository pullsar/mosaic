import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  canonicalJson,
  mediaDerivativeKey,
  normalizeMediaDerivativePlan,
  normalizeSha256,
  type MediaDerivativePlan,
} from '../src/media.js';

const sourceHash = 'A'.repeat(64);

function plan(parameters: MediaDerivativePlan['parameters']): MediaDerivativePlan {
  return {
    version: 1,
    purpose: 'playback',
    processor: 'ffmpeg-normalize-v1',
    parameters,
  };
}

test('derivative identity is stable across object-key ordering and processor whitespace', () => {
  const first = mediaDerivativeKey(sourceHash, {
    ...plan({
      container: 'mp4',
      video: {codec: 'h264', pixelFormat: 'yuv420p'},
      audio: {codec: 'aac', channels: 2},
    }),
    processor: ' ffmpeg-normalize-v1 ',
  });
  const second = mediaDerivativeKey(sourceHash.toLowerCase(), plan({
    audio: {channels: 2, codec: 'aac'},
    video: {pixelFormat: 'yuv420p', codec: 'h264'},
    container: 'mp4',
  }));

  assert.equal(first, second);
  assert.match(first, /^mdv1_[0-9a-f]{64}$/);
  assert.equal(normalizeMediaDerivativePlan({...plan({}), processor: ' worker '}).processor, 'worker');
});

test('derivative identity changes with source or processing plan', () => {
  const base = mediaDerivativeKey(sourceHash, plan({container: 'mp4', maxFps: 30}));
  const differentSource = mediaDerivativeKey('b'.repeat(64), plan({container: 'mp4', maxFps: 30}));
  const differentPlan = mediaDerivativeKey(sourceHash, plan({container: 'mp4', maxFps: 60}));

  assert.notEqual(base, differentSource);
  assert.notEqual(base, differentPlan);
});

test('canonical JSON rejects values that cannot produce a stable processing identity', () => {
  assert.equal(canonicalJson({b: 2, a: -0}), '{"a":0,"b":2}');
  assert.throws(() => canonicalJson({bad: Number.NaN}), /non-finite/);
  assert.throws(() => canonicalJson({bad: undefined}), /undefined/);
  assert.throws(() => canonicalJson(new Date()), /plain objects/);

  const sparse = new Array<unknown>(1);
  assert.throws(() => canonicalJson(sparse), /sparse arrays/);

  const symbolKeyed = {[Symbol('hidden')]: 'value'};
  assert.throws(() => canonicalJson(symbolKeyed), /string object keys/);

  const accessor = Object.defineProperty({}, 'value', {enumerable: true, get: () => 'x'});
  assert.throws(() => canonicalJson(accessor), /enumerable data properties/);
});

test('source digest and plan identity fail closed on malformed input', () => {
  assert.equal(normalizeSha256(sourceHash), sourceHash.toLowerCase());
  assert.throws(() => normalizeSha256('not-a-hash'), /SHA-256/);
  assert.throws(() => mediaDerivativeKey(sourceHash, {...plan({}), version: 0}), /version/);
  assert.throws(() => mediaDerivativeKey(sourceHash, {...plan({}), processor: ' '}), /processor/);
  assert.throws(
    () => mediaDerivativeKey(sourceHash, {...plan({}), purpose: 'thumbnail' as MediaDerivativePlan['purpose']}),
    /purpose/,
  );
});

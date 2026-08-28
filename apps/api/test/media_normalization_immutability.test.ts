import assert from 'node:assert/strict';
import {test} from 'node:test';
import {type CanonicalJsonValue} from '../src/media.js';
import {planMediaNormalization} from '../src/media_normalization.js';

function record(value: CanonicalJsonValue): Readonly<Record<string, CanonicalJsonValue>> {
  assert.ok(value !== null && typeof value === 'object' && !Array.isArray(value));
  return value as Readonly<Record<string, CanonicalJsonValue>>;
}

test('normalization plans are deep-frozen immutable job-identity snapshots', () => {
  const plans = planMediaNormalization({
    kind: 'video',
    width: 1920,
    height: 1080,
    durationMs: 5_000,
    videoCodec: 'hevc',
    videoProfile: 'Main 10',
    dynamicRange: 'hdr',
    colorSpace: 'bt2020nc',
    variableFrameRate: true,
    nominalFrameRate: 29.97,
    rotationDegrees: 0,
    hasAudio: true,
    audioCodec: 'aac',
    audioSampleRateHz: 48_000,
    audioChannels: 2,
    speech: 'none',
  });

  const playback = plans[0];
  assert.ok(playback);
  const parameters = record(playback.parameters);
  const source = record(parameters.source as CanonicalJsonValue);
  const output = record(parameters.output as CanonicalJsonValue);
  const audio = record(output.audio as CanonicalJsonValue);

  assert.equal(source.videoProfile, 'main-10');
  assert.equal(Object.isFrozen(plans), true);
  assert.equal(Object.isFrozen(playback), true);
  assert.equal(Object.isFrozen(playback.parameters), true);
  assert.equal(Object.isFrozen(source), true);
  assert.equal(Object.isFrozen(output), true);
  assert.equal(Object.isFrozen(audio), true);
});

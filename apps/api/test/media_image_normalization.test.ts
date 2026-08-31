import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mediaDerivativeKey} from '../src/media.js';
import {
  FFMPEG_IMAGE_PROCESSOR,
  planImageNormalization,
} from '../src/media_image_normalization.js';

const sourceSha256 = 'd'.repeat(64);

function opaqueSdr() {
  return {
    kind: 'image' as const,
    width: 2400,
    height: 1600,
    rotationDegrees: 0 as const,
    dynamicRange: 'sdr' as const,
    hasAlpha: false,
  };
}

test('opaque still images receive one deterministic bounded managed JPEG plan', () => {
  const plan = planImageNormalization(opaqueSdr());
  assert.equal(plan.purpose, 'image');
  assert.equal(plan.processor, FFMPEG_IMAGE_PROCESSOR);
  assert.equal(plan.version, 1);
  assert.deepEqual({...plan.parameters.output as Record<string, unknown>}, {
    colorSpace: 'srgb',
    dynamicRange: 'sdr',
    evenDimensions: true,
    format: 'jpeg',
    maxLongEdge: 1280,
    orientation: 'pixels-normalized',
    quality: 82,
  });
  assert.equal(Object.isFrozen(plan), true);
  assert.equal(Object.isFrozen(plan.parameters), true);
  assert.equal(Object.isFrozen(plan.parameters.source), true);
  assert.equal(
    mediaDerivativeKey(sourceSha256, plan),
    mediaDerivativeKey(sourceSha256, planImageNormalization(opaqueSdr())),
  );
});

test('execution-relevant image orientation and HDR traits participate in derivative identity', () => {
  const base = planImageNormalization(opaqueSdr());
  const rotated = planImageNormalization({...opaqueSdr(), rotationDegrees: 90 as const});
  const hdr = planImageNormalization({
    ...opaqueSdr(),
    dynamicRange: 'hdr' as const,
    colorPrimaries: ' BT2020 ',
    colorTransfer: ' SMPTE2084 ',
    colorMatrix: ' BT2020NC ',
    colorRange: 'limited' as const,
  });
  assert.notEqual(
    mediaDerivativeKey(sourceSha256, base),
    mediaDerivativeKey(sourceSha256, rotated),
  );
  assert.notEqual(
    mediaDerivativeKey(sourceSha256, base),
    mediaDerivativeKey(sourceSha256, hdr),
  );
  assert.deepEqual({...hdr.parameters.source as Record<string, unknown>}, {
    colorMatrix: 'bt2020nc',
    colorPrimaries: 'bt2020',
    colorRange: 'limited',
    colorTransfer: 'smpte2084',
    dynamicRange: 'hdr',
    hasAlpha: false,
    height: 1600,
    rotationDegrees: 0,
    width: 2400,
  });
});

test('alpha and inconsistent HDR/color metadata fail closed before planning', () => {
  assert.throws(
    () => planImageNormalization({...opaqueSdr(), hasAlpha: true}),
    /does not support alpha/,
  );
  assert.throws(
    () => planImageNormalization({
      ...opaqueSdr(),
      dynamicRange: 'hdr',
    }),
    /HDR image requires color primaries/,
  );
  assert.throws(
    () => planImageNormalization({
      ...opaqueSdr(),
      colorPrimaries: 'bt709',
    }),
    /must be all present or all absent/,
  );
  assert.throws(
    () => planImageNormalization({...opaqueSdr(), width: 0}),
    /width/,
  );
});

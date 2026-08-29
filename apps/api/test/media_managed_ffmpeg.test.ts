import assert from 'node:assert/strict';
import {test} from 'node:test';
import {planImageNormalization} from '../src/media_image_normalization.js';
import {
  compileFfmpegInvocation,
  mediaOutputVerificationPlan,
  supportsFfmpegPlan,
} from '../src/media_managed_ffmpeg.js';
import {planMediaNormalization} from '../src/media_normalization.js';

function hdrImagePlan() {
  return planImageNormalization({
    kind: 'image',
    width: 3000,
    height: 2000,
    rotationDegrees: 90,
    dynamicRange: 'hdr',
    colorPrimaries: 'bt2020',
    colorTransfer: 'smpte2084',
    colorMatrix: 'bt2020nc',
    colorRange: 'limited',
    hasAlpha: false,
  });
}

test('managed image execution reuses bounded verified JPEG compilation with HDR tone mapping', () => {
  const plan = hdrImagePlan();
  const invocation = compileFfmpegInvocation(
    plan,
    {inputPath: '/tmp/mosaic/source.heic', outputPath: '/tmp/mosaic/output.jpg'},
  );

  assert.equal(invocation.expectedOutput.mimeType, 'image/jpeg');
  assert.equal(invocation.expectedOutput.dynamicRange, 'sdr');
  assert.ok(invocation.args.includes('-frames:v'));
  assert.ok(invocation.args.includes('1'));
  assert.ok(invocation.args.includes('mjpeg'));
  assert.ok(invocation.args.includes('-map_metadata'));
  const filterIndex = invocation.args.indexOf('-vf');
  assert.ok(filterIndex >= 0);
  const filters = invocation.args[filterIndex + 1] ?? '';
  assert.match(filters, /tonemap=tonemap=hable/);
  assert.match(filters, /min\(iw,1280\)/);
  assert.equal(supportsFfmpegPlan(plan), true);
});

test('image verification adapter changes execution identity only, not the persisted image plan', () => {
  const plan = hdrImagePlan();
  const verification = mediaOutputVerificationPlan(plan);
  assert.equal(plan.purpose, 'image');
  assert.equal(plan.processor, 'ffmpeg-image-normalize-v1');
  assert.equal(verification.purpose, 'poster');
  assert.equal(verification.processor, 'ffmpeg-poster-v1');
  assert.equal(verification.parameters.timestampMs, 0);
  assert.deepEqual(verification.parameters.output, plan.parameters.output);
});

test('managed wrapper delegates existing video plans unchanged', () => {
  const plan = planMediaNormalization({
    kind: 'video',
    width: 1280,
    height: 720,
    durationMs: 1_000,
    videoCodec: 'h264',
    videoProfile: 'main',
    dynamicRange: 'sdr',
    colorPrimaries: 'bt709',
    colorTransfer: 'bt709',
    colorMatrix: 'bt709',
    colorRange: 'limited',
    variableFrameRate: false,
    nominalFrameRate: 30,
    rotationDegrees: 0,
    hasAudio: false,
    speech: 'none',
  })[0];
  assert.ok(plan);
  assert.equal(supportsFfmpegPlan(plan), true);
  assert.equal(mediaOutputVerificationPlan(plan), plan);
});

test('tampered managed image plans fail closed rather than being silently adapted', () => {
  const plan = hdrImagePlan();
  const output = plan.parameters.output as Readonly<Record<string, unknown>>;
  const tampered = {
    ...plan,
    parameters: {
      ...plan.parameters,
      output: {...output, maxLongEdge: 4096},
    },
  };
  assert.throws(
    () => compileFfmpegInvocation(
      tampered,
      {inputPath: '/tmp/mosaic/source.heic', outputPath: '/tmp/mosaic/output.jpg'},
    ),
    /maxLongEdge/,
  );
});

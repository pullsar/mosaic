import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  compileFfmpegInvocation,
  MediaPlanCompileError,
  supportsFfmpegPlan,
  UnsupportedMediaProcessorError,
} from '../src/media_ffmpeg.js';
import {type MediaDerivativePlan} from '../src/media.js';
import {planMediaNormalization} from '../src/media_normalization.js';

const inputPath = '/tmp/mosaic/source.mov';
const videoOutputPath = '/tmp/mosaic/playback.mp4';

function hdrVideoPlans(): readonly MediaDerivativePlan[] {
  return planMediaNormalization({
    kind: 'video',
    width: 3840,
    height: 2160,
    durationMs: 8_000,
    videoCodec: 'hevc',
    videoProfile: 'Main 10',
    dynamicRange: 'hdr',
    colorPrimaries: 'bt2020',
    colorTransfer: 'smpte2084',
    colorMatrix: 'bt2020nc',
    colorRange: 'limited',
    variableFrameRate: true,
    nominalFrameRate: 59.94,
    rotationDegrees: 90,
    hasAudio: true,
    audioCodec: 'aac',
    audioSampleRateHz: 44_100,
    audioChannels: 6,
    speech: 'material',
    languageTag: 'en-US',
  });
}

function argAfter(args: readonly string[], option: string): string {
  const index = args.indexOf(option);
  assert.notEqual(index, -1, `Missing ${option}`);
  const value = args[index + 1];
  assert.ok(value, `Missing value after ${option}`);
  return value;
}

test('HDR playback compiles to explicit tone-map, bounded CFR H264/AAC and strips source metadata', () => {
  const playback = hdrVideoPlans()[0];
  assert.ok(playback);
  const invocation = compileFfmpegInvocation(playback, {
    inputPath,
    outputPath: videoOutputPath,
  });

  assert.equal(invocation.executable, 'ffmpeg');
  assert.equal(argAfter(invocation.args, '-i'), inputPath);
  assert.equal(invocation.args.at(-1), videoOutputPath);
  assert.equal(invocation.args.includes('-noautorotate'), false);
  assert.equal(argAfter(invocation.args, '-c:v'), 'libx264');
  assert.equal(argAfter(invocation.args, '-profile:v'), 'main');
  assert.equal(argAfter(invocation.args, '-pix_fmt'), 'yuv420p');
  assert.equal(argAfter(invocation.args, '-c:a'), 'aac');
  assert.equal(argAfter(invocation.args, '-profile:a'), 'aac_low');
  assert.equal(argAfter(invocation.args, '-ar'), '48000');
  assert.equal(argAfter(invocation.args, '-ac'), '2');
  assert.equal(argAfter(invocation.args, '-movflags'), '+faststart');
  assert.equal(argAfter(invocation.args, '-map_metadata'), '-1');
  assert.equal(argAfter(invocation.args, '-map_chapters'), '-1');
  assert.equal(argAfter(invocation.args, '-f'), 'mp4');

  const filter = argAfter(invocation.args, '-vf');
  assert.match(
    filter,
    /zscale=pin=bt2020:tin=smpte2084:min=bt2020nc:rin=limited:t=linear:npl=100/,
  );
  assert.match(filter, /format=gbrpf32le/);
  assert.match(filter, /tonemap=tonemap=hable:desat=0/);
  assert.match(filter, /zscale=p=bt709:t=bt709:m=bt709:r=limited/);
  assert.match(
    filter,
    /scale=w='min\(iw,1080\)':h='min\(ih,1920\)':force_original_aspect_ratio=decrease:force_divisible_by=2/,
  );
  assert.match(filter, /fps=fps=30:round=near/);
  assert.match(filter, /format=yuv420p$/);

  assert.deepEqual(invocation.expectedOutput, {
    mimeType: 'video/mp4',
    container: 'mp4',
    videoCodec: 'h264',
    videoProfile: 'main',
    audioCodec: 'aac',
    colorSpace: 'bt709',
    dynamicRange: 'sdr',
  });
});

test('SDR 24 fps video converts to BT709 without unnecessary tone mapping or frame duplication', () => {
  const playback = planMediaNormalization({
    kind: 'video',
    width: 1920,
    height: 1080,
    durationMs: 5_000,
    videoCodec: 'h264',
    videoProfile: 'main',
    dynamicRange: 'sdr',
    colorPrimaries: 'bt709',
    colorTransfer: 'bt709',
    colorMatrix: 'bt709',
    colorRange: 'limited',
    variableFrameRate: false,
    nominalFrameRate: 24,
    rotationDegrees: 0,
    hasAudio: false,
    speech: 'none',
  })[0];
  assert.ok(playback);

  const invocation = compileFfmpegInvocation(playback, {
    inputPath: '/tmp/mosaic/source;literal.mov',
    outputPath: '/tmp/mosaic/output literal.mp4',
  });
  const filter = argAfter(invocation.args, '-vf');
  assert.equal(filter.includes('tonemap='), false);
  assert.match(filter, /zscale=pin=bt709:tin=bt709:min=bt709:rin=limited:p=bt709:t=bt709:m=bt709:r=limited/);
  assert.match(filter, /fps=fps=24:round=near/);
  assert.equal(invocation.args.includes('-an'), true);
  assert.equal(argAfter(invocation.args, '-i'), '/tmp/mosaic/source;literal.mov');
  assert.equal(invocation.args.at(-1), '/tmp/mosaic/output literal.mp4');
});

test('poster plan compiles one SDR JPEG frame at the deterministic timestamp', () => {
  const poster = hdrVideoPlans()[1];
  assert.ok(poster);
  const invocation = compileFfmpegInvocation(poster, {
    inputPath,
    outputPath: '/tmp/mosaic/poster.jpg',
  });

  assert.equal(argAfter(invocation.args, '-ss'), '1.600');
  assert.equal(argAfter(invocation.args, '-frames:v'), '1');
  assert.equal(argAfter(invocation.args, '-c:v'), 'mjpeg');
  assert.equal(argAfter(invocation.args, '-q:v'), '3');
  assert.equal(argAfter(invocation.args, '-f'), 'image2');
  const filter = argAfter(invocation.args, '-vf');
  assert.match(filter, /tonemap=tonemap=hable:desat=0/);
  assert.match(
    filter,
    /scale=w='min\(iw,1280\)':h='min\(ih,1280\)':force_original_aspect_ratio=decrease:force_divisible_by=2/,
  );
  assert.deepEqual(invocation.expectedOutput, {
    mimeType: 'image/jpeg',
    dynamicRange: 'sdr',
  });
});

test('audio-only plan compiles AAC-LC 48 kHz stereo-bounded fast-start MP4', () => {
  const audio = planMediaNormalization({
    kind: 'audio',
    durationMs: 11_000,
    audioCodec: 'pcm_s24le',
    sampleRateHz: 96_000,
    channels: 8,
    speech: 'none',
  })[0];
  assert.ok(audio);
  const invocation = compileFfmpegInvocation(audio, {
    inputPath: '/tmp/mosaic/source.wav',
    outputPath: '/tmp/mosaic/audio.m4a',
  });

  assert.equal(argAfter(invocation.args, '-map'), '0:a:0');
  assert.equal(argAfter(invocation.args, '-c:a'), 'aac');
  assert.equal(argAfter(invocation.args, '-profile:a'), 'aac_low');
  assert.equal(argAfter(invocation.args, '-ar'), '48000');
  assert.equal(argAfter(invocation.args, '-ac'), '2');
  assert.equal(argAfter(invocation.args, '-movflags'), '+faststart');
  assert.equal(argAfter(invocation.args, '-f'), 'mp4');
  assert.deepEqual(invocation.expectedOutput, {
    mimeType: 'audio/mp4',
    container: 'mp4',
    audioCodec: 'aac',
  });
});

test('caption processor and tampered planner fields fail closed', () => {
  const captions = hdrVideoPlans()[2];
  assert.ok(captions);
  assert.equal(supportsFfmpegPlan(captions), false);
  assert.throws(
    () => compileFfmpegInvocation(captions, {
      inputPath,
      outputPath: '/tmp/mosaic/captions.vtt',
    }),
    UnsupportedMediaProcessorError,
  );

  const tampered: MediaDerivativePlan = {
    version: 1,
    purpose: 'audio',
    processor: 'ffmpeg-audio-normalize-v1',
    parameters: {
      source: {
        durationMs: 1000,
        audioCodec: 'aac',
        sampleRateHz: 48000,
        channels: 2,
      },
      output: {
        container: 'mp4',
        codec: 'aac',
        profile: 'lc',
        sampleRateHz: 48000,
        maxChannels: 2,
        fastStart: true,
        ignoredByOldWorker: true,
      },
    },
  };
  assert.throws(
    () => compileFfmpegInvocation(tampered, {
      inputPath: '/tmp/mosaic/source.m4a',
      outputPath: '/tmp/mosaic/output.m4a',
    }),
    /unsupported field ignoredByOldWorker/,
  );
  assert.throws(
    () => compileFfmpegInvocation(tampered, {
      inputPath: 'relative/source.m4a',
      outputPath: '/tmp/mosaic/output.m4a',
    }),
    MediaPlanCompileError,
  );
});

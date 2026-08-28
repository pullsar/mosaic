import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  createFfprobeOutputVerifier,
  ffprobeArgs,
} from '../src/media_ffprobe.js';
import {MediaOutputVerificationError} from '../src/media_ffmpeg_worker.js';
import {type MediaProcessRunner} from '../src/media_ffmpeg_worker.js';
import {planMediaNormalization} from '../src/media_normalization.js';

function videoPlan() {
  const plan = planMediaNormalization({
    kind: 'video' as const,
    width: 1920,
    height: 1080,
    durationMs: 5_000,
    videoCodec: 'hevc',
    videoProfile: 'Main 10',
    dynamicRange: 'hdr' as const,
    colorPrimaries: 'bt2020',
    colorTransfer: 'smpte2084',
    colorMatrix: 'bt2020nc',
    colorRange: 'limited' as const,
    variableFrameRate: true,
    nominalFrameRate: 59.94,
    rotationDegrees: 0 as const,
    hasAudio: true,
    audioCodec: 'aac',
    audioSampleRateHz: 44_100,
    audioChannels: 6,
    speech: 'none' as const,
  })[0];
  assert.ok(plan);
  return plan;
}

function probeRunner(document: unknown): MediaProcessRunner {
  return async (invocation, options) => {
    assert.equal(invocation.executable, 'ffprobe');
    assert.deepEqual(invocation.args, ffprobeArgs('/tmp/mosaic/playback.mp4'));
    assert.equal(options.captureStdout, true);
    assert.equal(options.timeoutMs, 5_000);
    return {
      durationMs: 10,
      stderrTail: '',
      stdoutText: JSON.stringify(document),
    };
  };
}

const validVideoProbe = {
  streams: [
    {
      index: 0,
      codec_type: 'video',
      codec_name: 'h264',
      profile: 'Main',
      width: 1280,
      height: 720,
      pix_fmt: 'yuv420p',
      color_range: 'tv',
      color_space: 'bt709',
      color_transfer: 'bt709',
      color_primaries: 'bt709',
      avg_frame_rate: '30/1',
      duration: '5.000000',
    },
    {
      index: 1,
      codec_type: 'audio',
      codec_name: 'aac',
      profile: 'LC',
      sample_rate: '48000',
      channels: 2,
      duration: '5.000000',
    },
  ],
  format: {
    format_name: 'mov,mp4,m4a,3gp,3g2,mj2',
    duration: '5.000000',
    size: '1000000',
  },
};

test('FFprobe verifier returns normalized ready metadata for compliant playback', async () => {
  const verifier = createFfprobeOutputVerifier({
    timeoutMs: 5_000,
    runProcess: probeRunner(validVideoProbe),
    statFile: async () => ({size: 1_000_000, isFile: () => true}),
  });
  const output = await verifier({
    outputPath: '/tmp/mosaic/playback.mp4',
    storageKey: 'public/playback.mp4',
    plan: videoPlan(),
    expectedOutput: {
      mimeType: 'video/mp4',
      container: 'mp4',
      videoCodec: 'h264',
      videoProfile: 'main',
      audioCodec: 'aac',
      colorSpace: 'bt709',
      dynamicRange: 'sdr',
    },
  });

  assert.equal(output.mimeType, 'video/mp4');
  assert.equal(output.container, 'mp4');
  assert.equal(output.videoCodec, 'h264');
  assert.equal(output.videoProfile, 'main');
  assert.equal(output.audioCodec, 'aac');
  assert.equal(output.colorSpace, 'bt709');
  assert.equal(output.dynamicRange, 'sdr');
  assert.equal(output.width, 1280);
  assert.equal(output.height, 720);
  assert.equal(output.durationMs, 5_000);
  assert.equal(output.sizeBytes, 1_000_000);
  assert.deepEqual(output.metadata, {
    pixelFormat: 'yuv420p',
    frameRate: 30,
    colorPrimaries: 'bt709',
    colorTransfer: 'bt709',
    colorMatrix: 'bt709',
    colorRange: 'tv',
    audioSampleRateHz: 48_000,
    audioChannels: 2,
  });
});

test('FFprobe verifier fails closed on HEVC, HDR tags, odd dimensions or excessive fps', async () => {
  const cases = [
    {...validVideoProbe, streams: [{...validVideoProbe.streams[0], codec_name: 'hevc'}, validVideoProbe.streams[1]]},
    {...validVideoProbe, streams: [{...validVideoProbe.streams[0], color_transfer: 'smpte2084'}, validVideoProbe.streams[1]]},
    {...validVideoProbe, streams: [{...validVideoProbe.streams[0], width: 1279}, validVideoProbe.streams[1]]},
    {...validVideoProbe, streams: [{...validVideoProbe.streams[0], avg_frame_rate: '60000/1001'}, validVideoProbe.streams[1]]},
  ];

  for (const document of cases) {
    const verifier = createFfprobeOutputVerifier({
      timeoutMs: 5_000,
      runProcess: probeRunner(document),
      statFile: async () => ({size: 1_000_000, isFile: () => true}),
    });
    await assert.rejects(
      verifier({
        outputPath: '/tmp/mosaic/playback.mp4',
        storageKey: 'public/playback.mp4',
        plan: videoPlan(),
        expectedOutput: {
          mimeType: 'video/mp4',
          container: 'mp4',
          videoCodec: 'h264',
          videoProfile: 'main',
          audioCodec: 'aac',
          colorSpace: 'bt709',
          dynamicRange: 'sdr',
        },
      }),
      MediaOutputVerificationError,
    );
  }
});

test('FFprobe verifier rejects duration drift, unexpected streams and empty files', async () => {
  const drifted = {
    ...validVideoProbe,
    format: {...validVideoProbe.format, duration: '4.000000'},
  };
  const extraStream = {
    ...validVideoProbe,
    streams: [...validVideoProbe.streams, {index: 2, codec_type: 'subtitle', codec_name: 'mov_text'}],
  };

  for (const document of [drifted, extraStream]) {
    const verifier = createFfprobeOutputVerifier({
      timeoutMs: 5_000,
      runProcess: probeRunner(document),
      statFile: async () => ({size: 1_000_000, isFile: () => true}),
    });
    await assert.rejects(
      verifier({
        outputPath: '/tmp/mosaic/playback.mp4',
        storageKey: 'public/playback.mp4',
        plan: videoPlan(),
        expectedOutput: {mimeType: 'video/mp4'},
      }),
      MediaOutputVerificationError,
    );
  }

  const emptyVerifier = createFfprobeOutputVerifier({
    timeoutMs: 5_000,
    runProcess: probeRunner(validVideoProbe),
    statFile: async () => ({size: 0, isFile: () => true}),
  });
  await assert.rejects(
    emptyVerifier({
      outputPath: '/tmp/mosaic/playback.mp4',
      storageKey: 'public/playback.mp4',
      plan: videoPlan(),
      expectedOutput: {mimeType: 'video/mp4'},
    }),
    /non-empty regular file/,
  );
});

test('FFprobe JSON must be present, bounded by runner and syntactically valid', async () => {
  for (const stdoutText of ['', '{not-json']) {
    const verifier = createFfprobeOutputVerifier({
      timeoutMs: 5_000,
      runProcess: async () => ({durationMs: 1, stderrTail: '', stdoutText}),
      statFile: async () => ({size: 10, isFile: () => true}),
    });
    await assert.rejects(
      verifier({
        outputPath: '/tmp/mosaic/playback.mp4',
        storageKey: 'public/playback.mp4',
        plan: videoPlan(),
        expectedOutput: {mimeType: 'video/mp4'},
      }),
      MediaOutputVerificationError,
    );
  }
});

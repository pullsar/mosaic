import assert from 'node:assert/strict';
import {test} from 'node:test';
import {canonicalJson, mediaDerivativeKey, type CanonicalJsonValue} from '../src/media.js';
import {
  MEDIA_NORMALIZATION_POLICY_VERSION,
  planMediaNormalization,
  type VerifiedAudioSourceMetadata,
  type VerifiedVideoSourceMetadata,
} from '../src/media_normalization.js';

const sourceSha256 = 'c'.repeat(64);

type VideoOverrides = {
  [Key in keyof VerifiedVideoSourceMetadata]?: VerifiedVideoSourceMetadata[Key] | undefined;
};

function record(value: CanonicalJsonValue): Readonly<Record<string, CanonicalJsonValue>> {
  assert.ok(value !== null && typeof value === 'object' && !Array.isArray(value));
  return value as Readonly<Record<string, CanonicalJsonValue>>;
}

function video(overrides: VideoOverrides = {}): VerifiedVideoSourceMetadata {
  const merged: Record<string, unknown> = {
    kind: 'video',
    width: 3840,
    height: 2160,
    durationMs: 8_000,
    videoCodec: 'HEVC',
    videoProfile: 'Main10',
    dynamicRange: 'hdr',
    colorSpace: 'BT2020',
    variableFrameRate: true,
    nominalFrameRate: 59.94,
    rotationDegrees: 90,
    hasAudio: true,
    audioCodec: 'AAC',
    audioSampleRateHz: 44_100,
    audioChannels: 6,
    speech: 'material',
    languageTag: 'EN-US',
    ...overrides,
  };
  for (const [key, value] of Object.entries(merged)) {
    if (value === undefined) delete merged[key];
  }
  return merged as unknown as VerifiedVideoSourceMetadata;
}

test('HDR HEVC VFR video plans an SDR H264/AAC baseline, poster and captions', () => {
  const plans = planMediaNormalization(video());
  assert.deepEqual(plans.map((plan) => plan.purpose), ['playback', 'poster', 'captions']);
  assert.ok(plans.every((plan) => plan.version === MEDIA_NORMALIZATION_POLICY_VERSION));

  const playback = plans[0];
  assert.ok(playback);
  assert.equal(playback.processor, 'ffmpeg-video-normalize-v1');
  const playbackParameters = record(playback.parameters);
  const playbackSource = record(playbackParameters.source as CanonicalJsonValue);
  const playbackOutput = record(playbackParameters.output as CanonicalJsonValue);
  assert.equal(playbackSource.videoCodec, 'hevc');
  assert.equal(playbackSource.videoProfile, 'main10');
  assert.equal(playbackSource.dynamicRange, 'hdr');
  assert.equal(playbackSource.colorSpace, 'bt2020');
  assert.equal(playbackSource.variableFrameRate, true);
  assert.equal(playbackSource.rotationDegrees, 90);
  assert.equal(playbackOutput.container, 'mp4');
  assert.equal(playbackOutput.videoCodec, 'h264');
  assert.equal(playbackOutput.videoProfile, 'main');
  assert.equal(playbackOutput.pixelFormat, 'yuv420p');
  assert.equal(playbackOutput.dynamicRange, 'sdr');
  assert.equal(playbackOutput.colorSpace, 'bt709');
  assert.equal(playbackOutput.frameRateMode, 'cfr');
  assert.equal(playbackOutput.maxFps, 30);
  assert.equal(playbackOutput.orientation, 'pixels-normalized');
  const outputAudio = record(playbackOutput.audio as CanonicalJsonValue);
  assert.equal(outputAudio.codec, 'aac');
  assert.equal(outputAudio.profile, 'lc');
  assert.equal(outputAudio.sampleRateHz, 48_000);
  assert.equal(outputAudio.maxChannels, 2);

  const poster = plans[1];
  assert.ok(poster);
  const posterParameters = record(poster.parameters);
  assert.equal(posterParameters.timestampMs, 1_600);
  assert.equal(record(posterParameters.output as CanonicalJsonValue).dynamicRange, 'sdr');

  const captions = plans[2];
  assert.ok(captions);
  const captionParameters = record(captions.parameters);
  assert.equal(record(captionParameters.output as CanonicalJsonValue).format, 'webvtt');
  assert.equal(record(captionParameters.output as CanonicalJsonValue).language, 'en-us');
});

test('source traits that change execution also change deterministic derivative identity', () => {
  const hdrPlayback = planMediaNormalization(video())[0];
  const sdrPlayback = planMediaNormalization(video({dynamicRange: 'sdr', colorSpace: 'bt709'}))[0];
  const uprightPlayback = planMediaNormalization(video({rotationDegrees: 0}))[0];
  assert.ok(hdrPlayback && sdrPlayback && uprightPlayback);

  const hdrKey = mediaDerivativeKey(sourceSha256, hdrPlayback);
  assert.notEqual(hdrKey, mediaDerivativeKey(sourceSha256, sdrPlayback));
  assert.notEqual(hdrKey, mediaDerivativeKey(sourceSha256, uprightPlayback));
});

test('already compatible H264 SDR video still receives the bounded launch profile', () => {
  const plans = planMediaNormalization(video({
    videoCodec: 'h264',
    videoProfile: 'main',
    dynamicRange: 'sdr',
    colorSpace: 'bt709',
    variableFrameRate: false,
    nominalFrameRate: 24,
    rotationDegrees: 0,
    speech: 'incidental',
    languageTag: undefined,
  }));

  assert.deepEqual(plans.map((plan) => plan.purpose), ['playback', 'poster']);
  const output = record(record(plans[0]!.parameters).output as CanonicalJsonValue);
  assert.equal(output.videoCodec, 'h264');
  assert.equal(output.dynamicRange, 'sdr');
  assert.equal(output.maxFps, 30);
  assert.equal(output.fastStart, true);
});

test('silent video omits audio and rejects contradictory speech/audio probe metadata', () => {
  const plans = planMediaNormalization(video({
    hasAudio: false,
    audioCodec: undefined,
    audioSampleRateHz: undefined,
    audioChannels: undefined,
    speech: 'none',
    languageTag: undefined,
  }));
  assert.deepEqual(plans.map((plan) => plan.purpose), ['playback', 'poster']);
  const output = record(record(plans[0]!.parameters).output as CanonicalJsonValue);
  assert.equal(output.audio, null);

  assert.throws(
    () => planMediaNormalization(video({
      hasAudio: false,
      audioCodec: undefined,
      audioSampleRateHz: undefined,
      audioChannels: undefined,
      speech: 'material',
    })),
    /Silent video/,
  );
});

test('audio source plans a 48 kHz stereo-bounded AAC derivative and optional captions', () => {
  const source: VerifiedAudioSourceMetadata = {
    kind: 'audio',
    durationMs: 11_000,
    audioCodec: 'PCM_S24LE',
    sampleRateHz: 96_000,
    channels: 8,
    speech: 'material',
  };
  const plans = planMediaNormalization(source);
  assert.deepEqual(plans.map((plan) => plan.purpose), ['audio', 'captions']);

  const output = record(record(plans[0]!.parameters).output as CanonicalJsonValue);
  assert.equal(output.container, 'mp4');
  assert.equal(output.codec, 'aac');
  assert.equal(output.profile, 'lc');
  assert.equal(output.sampleRateHz, 48_000);
  assert.equal(output.maxChannels, 2);
  assert.equal(record(record(plans[1]!.parameters).output as CanonicalJsonValue).language, 'auto');
});

test('planner output is deterministic and fail-closed for inconsistent verified metadata', () => {
  const first = planMediaNormalization(video({videoCodec: ' HEVC ', colorSpace: ' BT2020 '}));
  const second = planMediaNormalization(video({videoCodec: 'hevc', colorSpace: 'bt2020'}));
  assert.equal(canonicalJson(first), canonicalJson(second));

  assert.throws(() => planMediaNormalization(video({durationMs: 0})), /durationMs/);
  assert.throws(() => planMediaNormalization(video({rotationDegrees: 45 as 0})), /rotationDegrees/);
  assert.throws(
    () => planMediaNormalization(video({hasAudio: true, audioSampleRateHz: undefined})),
    /requires codec, sample rate and channel count/,
  );
  assert.throws(() => planMediaNormalization(video({languageTag: 'not a tag!'})), /languageTag/);
});

import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  MediaPublicationBlockedError,
  selectMediaDelivery,
  type MediaPublicationAsset,
  type MediaPublicationDerivative,
} from '../src/media_publication.js';

const sourceSha256 = 'a'.repeat(64);

function asset(
  kind: MediaPublicationAsset['kind'] = 'video',
  state: MediaPublicationAsset['state'] = 'uploaded',
): MediaPublicationAsset {
  return {id: 'asset_publication', kind, state, sourceSha256};
}

function derivative(
  purpose: MediaPublicationDerivative['purpose'],
  overrides: Partial<MediaPublicationDerivative> = {},
): MediaPublicationDerivative {
  const base: MediaPublicationDerivative = {
    derivativeKey: `mdv1_${purpose}`,
    purpose,
    state: 'ready',
    sourceSha256,
    planVersion: 1,
    processor: purpose === 'image'
      ? 'ffmpeg-image-normalize-v1'
      : purpose === 'playback'
        ? 'ffmpeg-video-normalize-v1'
        : purpose === 'poster'
          ? 'ffmpeg-poster-v1'
          : purpose === 'audio'
            ? 'ffmpeg-audio-normalize-v1'
            : 'speech-transcript-v1',
    storageKey: `media/asset_publication/${purpose}`,
    mimeType: purpose === 'image' || purpose === 'poster'
      ? 'image/jpeg'
      : purpose === 'playback'
        ? 'video/mp4'
        : purpose === 'audio'
          ? 'audio/mp4'
          : 'text/vtt',
    sizeBytes: 1_000,
    width: purpose === 'image' || purpose === 'playback' || purpose === 'poster'
      ? 1280
      : null,
    height: purpose === 'image' || purpose === 'playback' || purpose === 'poster'
      ? 720
      : null,
    durationMs: purpose === 'playback' || purpose === 'audio' ? 7_000 : null,
    container: purpose === 'playback' || purpose === 'audio' ? 'mp4' : null,
    videoCodec: purpose === 'playback' ? 'h264' : null,
    videoProfile: purpose === 'playback' ? 'main' : null,
    audioCodec: purpose === 'playback' || purpose === 'audio' ? 'aac' : null,
    colorSpace: purpose === 'playback' ? 'bt709' : null,
    dynamicRange: purpose === 'image' || purpose === 'playback' || purpose === 'poster'
      ? 'sdr'
      : null,
  };
  return {...base, ...overrides};
}

function reason(error: unknown): string | undefined {
  return error instanceof MediaPublicationBlockedError ? error.reason : undefined;
}

test('managed image publication requires a compatible current-source normalized JPEG', () => {
  const image = derivative('image');
  const selected = selectMediaDelivery(asset('image'), [image]);
  assert.equal(selected.kind, 'image');
  assert.equal(selected.primary.storageKey, image.storageKey);
  assert.equal(selected.primary.mimeType, 'image/jpeg');
  assert.equal(selected.poster, null);
  assert.equal(selected.captions, null);
  assert.equal('sourceStorageKey' in selected, false);

  assert.throws(
    () => selectMediaDelivery(asset('image'), []),
    (error) => reason(error) === 'image_not_ready',
  );
  assert.throws(
    () => selectMediaDelivery(asset('image'), [derivative('image', {mimeType: 'image/png'})]),
    (error) => reason(error) === 'image_incompatible',
  );
  assert.throws(
    () => selectMediaDelivery(asset('image'), [derivative('image', {dynamicRange: 'hdr'})]),
    (error) => reason(error) === 'image_incompatible',
  );
  assert.throws(
    () => selectMediaDelivery(asset('image'), [derivative('image', {
      processor: 'ffmpeg-poster-v1',
    })]),
    (error) => reason(error) === 'image_incompatible',
  );
});

test('video source is never deliverable without a compatible managed playback derivative', () => {
  assert.throws(
    () => selectMediaDelivery(asset(), []),
    (error) => reason(error) === 'playback_not_ready',
  );
});

test('HEVC/HDR output cannot satisfy the broadly compatible playback gate', () => {
  assert.throws(
    () => selectMediaDelivery(asset(), [
      derivative('playback', {
        videoCodec: 'hevc',
        videoProfile: 'main10',
        colorSpace: 'bt2020nc',
        dynamicRange: 'hdr',
      }),
      derivative('poster'),
    ]),
    (error) => reason(error) === 'playback_incompatible',
  );
});

test('video delivery exposes only compatible derivative object keys and requires poster fallback', () => {
  const playback = derivative('playback');
  const poster = derivative('poster');
  const selected = selectMediaDelivery(asset(), [playback, poster]);

  assert.equal(selected.kind, 'video');
  assert.equal(selected.primary.storageKey, playback.storageKey);
  assert.equal(selected.poster?.storageKey, poster.storageKey);
  assert.equal(selected.primary.videoCodec, 'h264');
  assert.equal(selected.primary.dynamicRange, 'sdr');
  assert.equal('sourceStorageKey' in selected, false);

  assert.throws(
    () => selectMediaDelivery(asset(), [playback]),
    (error) => reason(error) === 'poster_not_ready',
  );
});

test('registered caption work blocks publication until a valid WebVTT artifact is ready', () => {
  const playback = derivative('playback');
  const poster = derivative('poster');
  assert.throws(
    () => selectMediaDelivery(asset(), [
      playback,
      poster,
      derivative('captions', {
        state: 'pending',
        storageKey: null,
        mimeType: null,
        sizeBytes: null,
      }),
    ]),
    (error) => reason(error) === 'captions_not_ready',
  );

  assert.throws(
    () => selectMediaDelivery(asset(), [
      playback,
      poster,
      derivative('captions', {mimeType: 'text/plain'}),
    ]),
    (error) => reason(error) === 'captions_incompatible',
  );

  const selected = selectMediaDelivery(asset(), [
    playback,
    poster,
    derivative('captions'),
  ]);
  assert.equal(selected.captions?.mimeType, 'text/vtt');
});

test('audio publication requires normalized AAC/MP4 and honors caption dependency', () => {
  const normalized = derivative('audio');
  const selected = selectMediaDelivery(asset('audio'), [normalized]);
  assert.equal(selected.kind, 'audio');
  assert.equal(selected.primary.audioCodec, 'aac');
  assert.equal(selected.poster, null);

  assert.throws(
    () => selectMediaDelivery(asset('audio'), [
      derivative('audio', {audioCodec: 'opus', container: 'webm'}),
    ]),
    (error) => reason(error) === 'audio_incompatible',
  );
});

test('stale-source derivatives never satisfy publication for the current immutable source', () => {
  assert.throws(
    () => selectMediaDelivery(asset(), [
      derivative('playback', {sourceSha256: 'b'.repeat(64)}),
      derivative('poster', {sourceSha256: 'b'.repeat(64)}),
    ]),
    (error) => reason(error) === 'playback_not_ready',
  );
  assert.throws(
    () => selectMediaDelivery(asset('image'), [
      derivative('image', {sourceSha256: 'b'.repeat(64)}),
    ]),
    (error) => reason(error) === 'image_not_ready',
  );
});

test('revoked and unverified assets fail closed before derivative selection', () => {
  assert.throws(
    () => selectMediaDelivery(
      asset('video', 'revoked'),
      [derivative('playback'), derivative('poster')],
    ),
    (error) => reason(error) === 'asset_revoked',
  );
  assert.throws(
    () => selectMediaDelivery({...asset(), sourceSha256: null}, []),
    (error) => reason(error) === 'source_unverified',
  );
});

test('an incompatible newer candidate cannot hide a compatible ready derivative', () => {
  const selected = selectMediaDelivery(asset(), [
    derivative('playback', {
      derivativeKey: 'mdv1_bad',
      planVersion: 2,
      videoCodec: 'hevc',
    }),
    derivative('playback', {derivativeKey: 'mdv1_good', planVersion: 1}),
    derivative('poster'),
  ]);
  assert.equal(selected.primary.derivativeKey, 'mdv1_good');
});

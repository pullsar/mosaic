import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  processFfmpegDerivative,
  type MediaFfmpegWorkerRepository,
  type MediaOutputVerifier,
  type MediaProcessRunner,
} from '../src/media_ffmpeg_worker.js';
import {MediaProcessError} from '../src/media_process.js';
import {
  MediaIdentityConflictError,
  type MediaDerivativeClaim,
  type MediaDerivativeOutput,
  type MediaDerivativeRecord,
} from '../src/media_repository.js';
import {type MediaDerivativePlan} from '../src/media.js';
import {planMediaNormalization} from '../src/media_normalization.js';

const assetId = 'asset_worker';
const derivativeKey = 'mdv1_worker';

function playbackPlan(): MediaDerivativePlan {
  const plan = planMediaNormalization({
    kind: 'video',
    width: 1280,
    height: 720,
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
  assert.ok(plan);
  return plan;
}

function captionsPlan(): MediaDerivativePlan {
  const plans = planMediaNormalization({
    kind: 'audio',
    durationMs: 3_000,
    audioCodec: 'aac',
    sampleRateHz: 48_000,
    channels: 2,
    speech: 'material',
    languageTag: 'en',
  });
  const plan = plans.find((candidate) => candidate.purpose === 'captions');
  assert.ok(plan);
  return plan;
}

function derivative(plan: MediaDerivativePlan): MediaDerivativeRecord {
  return {
    assetId,
    derivativeKey,
    purpose: plan.purpose,
    state: 'pending',
    sourceSha256: 'a'.repeat(64),
    planVersion: plan.version,
    plan,
    attemptCount: 0,
    leaseExpiresAt: null,
    storageKey: null,
    mimeType: null,
    sizeBytes: null,
    width: null,
    height: null,
    durationMs: null,
    container: null,
    videoCodec: null,
    videoProfile: null,
    audioCodec: null,
    colorSpace: null,
    dynamicRange: null,
    errorCode: null,
    outputMetadata: {},
    completedAt: null,
  };
}

class FakeRepository implements MediaFfmpegWorkerRepository {
  constructor(public current: MediaDerivativeRecord | null) {}

  claimCalls = 0;
  readyCalls = 0;
  failedCalls = 0;
  lastErrorCode: string | null = null;
  staleOnReady = false;

  async getDerivative(_assetId: string, _derivativeKey: string): Promise<MediaDerivativeRecord | null> {
    return this.current;
  }

  async claimDerivative(
    _assetId: string,
    _derivativeKey: string,
    leaseMs?: number,
    claimToken?: string,
  ): Promise<MediaDerivativeClaim | null> {
    this.claimCalls += 1;
    if (this.current === null || !['pending', 'failed'].includes(this.current.state)) return null;
    const token = claimToken ?? 'claim-token';
    this.current = {
      ...this.current,
      state: 'processing',
      attemptCount: this.current.attemptCount + 1,
      leaseExpiresAt: new Date(Date.now() + (leaseMs ?? 60_000)),
    };
    return {claimToken: token, derivative: this.current};
  }

  async markDerivativeReady(
    _assetId: string,
    _derivativeKey: string,
    claimToken: string,
    output: MediaDerivativeOutput,
  ): Promise<MediaDerivativeRecord> {
    this.readyCalls += 1;
    if (this.staleOnReady) throw new MediaIdentityConflictError('stale claim');
    assert.equal(claimToken, 'claim-token');
    assert.ok(this.current);
    this.current = {
      ...this.current,
      state: 'ready',
      leaseExpiresAt: null,
      storageKey: output.storageKey,
      mimeType: output.mimeType,
      sizeBytes: output.sizeBytes,
      width: output.width ?? null,
      height: output.height ?? null,
      durationMs: output.durationMs ?? null,
      container: output.container ?? null,
      videoCodec: output.videoCodec ?? null,
      videoProfile: output.videoProfile ?? null,
      audioCodec: output.audioCodec ?? null,
      colorSpace: output.colorSpace ?? null,
      dynamicRange: output.dynamicRange ?? null,
      errorCode: null,
      outputMetadata: output.metadata ?? {},
      completedAt: new Date(),
    };
    return this.current;
  }

  async markDerivativeFailed(
    _assetId: string,
    _derivativeKey: string,
    claimToken: string,
    errorCode: string,
  ): Promise<MediaDerivativeRecord> {
    this.failedCalls += 1;
    assert.equal(claimToken, 'claim-token');
    assert.ok(this.current);
    this.lastErrorCode = errorCode;
    this.current = {
      ...this.current,
      state: 'failed',
      leaseExpiresAt: null,
      errorCode,
      completedAt: new Date(),
    };
    return this.current;
  }
}

const verifiedPlayback: Awaited<ReturnType<MediaOutputVerifier>> = {
  mimeType: 'video/mp4',
  sizeBytes: 1_234_567,
  width: 1280,
  height: 720,
  durationMs: 5_000,
  container: 'mp4',
  videoCodec: 'h264',
  videoProfile: 'main',
  colorSpace: 'bt709',
  dynamicRange: 'sdr',
  metadata: {frameRate: 24},
};

const successfulRunner: MediaProcessRunner = async (invocation, options) => {
  assert.equal(invocation.executable, 'ffmpeg');
  assert.ok(invocation.args.includes('-map_metadata'));
  assert.equal(options.timeoutMs, 10_000);
  return {durationMs: 50, stderrTail: ''};
};

const successfulVerifier: MediaOutputVerifier = async (request) => {
  assert.equal(request.storageKey, 'public/asset_worker/playback.mp4');
  assert.equal(request.expectedOutput.videoCodec, 'h264');
  return verifiedPlayback;
};

test('worker claims, runs, verifies and completes with the exact leased claim', async () => {
  const repository = new FakeRepository(derivative(playbackPlan()));
  const result = await processFfmpegDerivative(
    repository,
    {
      assetId,
      derivativeKey,
      inputPath: '/tmp/mosaic/source.mov',
      outputPath: '/tmp/mosaic/playback.mp4',
      outputStorageKey: 'public/asset_worker/playback.mp4',
    },
    successfulVerifier,
    {
      leaseMs: 60_000,
      timeoutMs: 10_000,
      runProcess: successfulRunner,
    },
  );

  assert.equal(result.status, 'ready');
  assert.equal(repository.claimCalls, 1);
  assert.equal(repository.readyCalls, 1);
  assert.equal(repository.failedCalls, 0);
  assert.equal(repository.current?.storageKey, 'public/asset_worker/playback.mp4');
  assert.equal(repository.current?.videoCodec, 'h264');
});

test('caption jobs are left for the transcript worker without taking a lease', async () => {
  const repository = new FakeRepository(derivative(captionsPlan()));
  let runnerCalled = false;
  const result = await processFfmpegDerivative(
    repository,
    {
      assetId,
      derivativeKey,
      inputPath: '/tmp/mosaic/source.m4a',
      outputPath: '/tmp/mosaic/captions.vtt',
      outputStorageKey: 'public/asset_worker/captions.vtt',
    },
    successfulVerifier,
    {
      leaseMs: 60_000,
      timeoutMs: 10_000,
      runProcess: async () => {
        runnerCalled = true;
        return {durationMs: 0, stderrTail: ''};
      },
    },
  );

  assert.equal(result.status, 'unsupported');
  assert.equal(repository.claimCalls, 0);
  assert.equal(runnerCalled, false);
});

test('output mismatch fails the active claim instead of publishing an unverified derivative', async () => {
  const repository = new FakeRepository(derivative(playbackPlan()));
  const result = await processFfmpegDerivative(
    repository,
    {
      assetId,
      derivativeKey,
      inputPath: '/tmp/mosaic/source.mov',
      outputPath: '/tmp/mosaic/playback.mp4',
      outputStorageKey: 'public/asset_worker/playback.mp4',
    },
    async () => ({...verifiedPlayback, videoCodec: 'hevc'}),
    {
      leaseMs: 60_000,
      timeoutMs: 10_000,
      runProcess: successfulRunner,
    },
  );

  assert.equal(result.status, 'failed');
  assert.equal(result.errorCode, 'media_output_invalid');
  assert.equal(repository.lastErrorCode, 'media_output_invalid');
  assert.equal(repository.readyCalls, 0);
  assert.equal(repository.failedCalls, 1);
});

test('process timeout becomes a stable retryable derivative failure code', async () => {
  const repository = new FakeRepository(derivative(playbackPlan()));
  let verifierCalled = false;
  const result = await processFfmpegDerivative(
    repository,
    {
      assetId,
      derivativeKey,
      inputPath: '/tmp/mosaic/source.mov',
      outputPath: '/tmp/mosaic/playback.mp4',
      outputStorageKey: 'public/asset_worker/playback.mp4',
    },
    async () => {
      verifierCalled = true;
      return verifiedPlayback;
    },
    {
      leaseMs: 60_000,
      timeoutMs: 10_000,
      runProcess: async () => {
        throw new MediaProcessError('timeout', 'timed out');
      },
    },
  );

  assert.equal(result.status, 'failed');
  assert.equal(result.errorCode, 'ffmpeg_timeout');
  assert.equal(repository.lastErrorCode, 'ffmpeg_timeout');
  assert.equal(verifierCalled, false);
});

test('stale completion cannot overwrite a replacement worker claim', async () => {
  const repository = new FakeRepository(derivative(playbackPlan()));
  repository.staleOnReady = true;
  const result = await processFfmpegDerivative(
    repository,
    {
      assetId,
      derivativeKey,
      inputPath: '/tmp/mosaic/source.mov',
      outputPath: '/tmp/mosaic/playback.mp4',
      outputStorageKey: 'public/asset_worker/playback.mp4',
    },
    successfulVerifier,
    {
      leaseMs: 60_000,
      timeoutMs: 10_000,
      runProcess: successfulRunner,
    },
  );

  assert.equal(result.status, 'stale');
  assert.equal(repository.readyCalls, 1);
  assert.equal(repository.failedCalls, 0);
  assert.equal(repository.current?.state, 'processing');
});

test('worker configuration requires process timeout to leave lease-completion margin', async () => {
  const repository = new FakeRepository(derivative(playbackPlan()));
  await assert.rejects(
    processFfmpegDerivative(
      repository,
      {
        assetId,
        derivativeKey,
        inputPath: '/tmp/mosaic/source.mov',
        outputPath: '/tmp/mosaic/playback.mp4',
        outputStorageKey: 'public/asset_worker/playback.mp4',
      },
      successfulVerifier,
      {leaseMs: 40_000, timeoutMs: 10_000, runProcess: successfulRunner},
    ),
    /leave at least 30000 ms/,
  );
  assert.equal(repository.claimCalls, 0);
});

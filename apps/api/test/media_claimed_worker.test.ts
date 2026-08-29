import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  processClaimedFfmpegDerivative,
  type MediaFfmpegWorkerRepository,
  type MediaOutputPublisher,
  type MediaOutputVerifier,
  type MediaProcessRunner,
} from '../src/media_ffmpeg_worker.js';
import {
  MediaIdentityConflictError,
  type MediaDerivativeClaim,
  type MediaDerivativeOutput,
  type MediaDerivativeRecord,
} from '../src/media_repository.js';
import {planMediaNormalization} from '../src/media_normalization.js';

function claim(leaseMs = 120_000): MediaDerivativeClaim {
  const plan = planMediaNormalization({
    kind: 'audio' as const,
    durationMs: 1_000,
    audioCodec: 'pcm_s16le',
    sampleRateHz: 44_100,
    channels: 2,
    speech: 'none' as const,
  })[0];
  assert.ok(plan);
  return {
    claimToken: 'dispatcher-claim',
    derivative: {
      assetId: 'asset_dispatcher',
      derivativeKey: 'mdv1_dispatcher',
      purpose: plan.purpose,
      state: 'processing',
      sourceSha256: 'a'.repeat(64),
      planVersion: plan.version,
      plan,
      attemptCount: 1,
      leaseExpiresAt: new Date(Date.now() + leaseMs),
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
    },
  };
}

class FakeClaimRepository implements MediaFfmpegWorkerRepository {
  constructor(public current: MediaDerivativeRecord) {}

  claimCalls = 0;
  readyCalls = 0;
  failedCalls = 0;
  lastErrorCode: string | null = null;

  async getDerivative(): Promise<MediaDerivativeRecord | null> {
    return this.current;
  }

  async claimDerivative(): Promise<MediaDerivativeClaim | null> {
    this.claimCalls += 1;
    throw new Error('dispatcher-owned work must not be claimed twice');
  }

  async markDerivativeReady(
    _assetId: string,
    _derivativeKey: string,
    token: string,
    output: MediaDerivativeOutput,
  ): Promise<MediaDerivativeRecord> {
    this.readyCalls += 1;
    assert.equal(token, 'dispatcher-claim');
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
    token: string,
    errorCode: string,
  ): Promise<MediaDerivativeRecord> {
    this.failedCalls += 1;
    assert.equal(token, 'dispatcher-claim');
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

const verifier: MediaOutputVerifier = async () => ({
  mimeType: 'audio/mp4',
  sizeBytes: 100,
  durationMs: 1_000,
  container: 'mp4',
  audioCodec: 'aac',
});

const publisher: MediaOutputPublisher = async () => undefined;

const runner: MediaProcessRunner = async () => ({durationMs: 10, stderrTail: ''});

test('dispatcher-owned claim is processed without a second repository claim', async () => {
  const ownedClaim = claim();
  const repository = new FakeClaimRepository(ownedClaim.derivative);
  const result = await processClaimedFfmpegDerivative(
    repository,
    ownedClaim,
    {
      inputPath: '/tmp/mosaic/source.wav',
      outputPath: '/tmp/mosaic/output.m4a',
    },
    verifier,
    publisher,
    {timeoutMs: 10_000, runProcess: runner},
  );

  assert.equal(result.status, 'ready');
  assert.equal(repository.claimCalls, 0);
  assert.equal(repository.readyCalls, 1);
  assert.equal(repository.failedCalls, 0);
});

test('already-aborted dispatcher claim is failed immediately for retry', async () => {
  const ownedClaim = claim();
  const repository = new FakeClaimRepository(ownedClaim.derivative);
  const controller = new AbortController();
  controller.abort();
  const result = await processClaimedFfmpegDerivative(
    repository,
    ownedClaim,
    {
      inputPath: '/tmp/mosaic/source.wav',
      outputPath: '/tmp/mosaic/output.m4a',
    },
    verifier,
    publisher,
    {timeoutMs: 10_000, signal: controller.signal, runProcess: runner},
  );

  assert.equal(result.status, 'failed');
  assert.equal(result.errorCode, 'ffmpeg_aborted');
  assert.equal(repository.failedCalls, 1);
});

test('claim that cannot outlive timeout plus completion margin fails closed', async () => {
  const ownedClaim = claim(20_000);
  const repository = new FakeClaimRepository(ownedClaim.derivative);
  const result = await processClaimedFfmpegDerivative(
    repository,
    ownedClaim,
    {
      inputPath: '/tmp/mosaic/source.wav',
      outputPath: '/tmp/mosaic/output.m4a',
    },
    verifier,
    publisher,
    {timeoutMs: 10_000, runProcess: runner},
  );

  assert.equal(result.status, 'failed');
  assert.equal(result.errorCode, 'media_claim_invalid');
  assert.equal(repository.failedCalls, 1);
});

test('stale dispatcher claim cannot be failed or completed by the worker', async () => {
  const ownedClaim = claim();
  const repository = new FakeClaimRepository(ownedClaim.derivative);
  repository.markDerivativeFailed = async () => {
    throw new MediaIdentityConflictError('claim was replaced');
  };
  const controller = new AbortController();
  controller.abort();
  const result = await processClaimedFfmpegDerivative(
    repository,
    ownedClaim,
    {
      inputPath: '/tmp/mosaic/source.wav',
      outputPath: '/tmp/mosaic/output.m4a',
    },
    verifier,
    publisher,
    {timeoutMs: 10_000, signal: controller.signal, runProcess: runner},
  );

  assert.equal(result.status, 'stale');
});

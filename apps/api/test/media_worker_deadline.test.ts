import assert from 'node:assert/strict';
import {test} from 'node:test';
import {planMediaNormalization} from '../src/media_normalization.js';
import {runMediaWorkerOnce, type MediaWorkerRepository} from '../src/media_worker_runtime.js';
import type {
  MediaAssetRecord,
  MediaDerivativeClaim,
  MediaDerivativeOutput,
  MediaDerivativeRecord,
} from '../src/media_repository.js';

function shortLeaseClaim(): MediaDerivativeClaim {
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
    claimToken: 'deadline-claim',
    derivative: {
      assetId: 'asset_deadline',
      derivativeKey: 'mdv1_deadline',
      purpose: 'audio',
      state: 'processing',
      sourceSha256: 'a'.repeat(64),
      planVersion: plan.version,
      plan,
      attemptCount: 1,
      leaseExpiresAt: new Date(Date.now() + 29_000),
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

function sourceAsset(): MediaAssetRecord {
  return {
    id: 'asset_deadline',
    ownerActorId: 'actor_deadline',
    kind: 'audio',
    state: 'uploaded',
    sourceStorageKey: 'quarantine/asset_deadline/source.wav',
    sourceSha256: 'a'.repeat(64),
    sourceMimeType: 'audio/wav',
    sourceSizeBytes: 10,
    sourceWidth: null,
    sourceHeight: null,
    sourceDurationMs: 1_000,
    sourceMetadata: {},
    errorCode: null,
  };
}

test('runtime fails a claim inside the completion margin before source I/O starts', async () => {
  const claim = shortLeaseClaim();
  let materializerCalled = false;
  const failedCodes: string[] = [];
  let current = claim.derivative;
  const repository: MediaWorkerRepository = {
    async getAsset() {
      return sourceAsset();
    },
    async getDerivative() {
      return current;
    },
    async claimDerivative() {
      throw new Error('dispatcher owns the claim');
    },
    async markDerivativeReady(
      _assetId: string,
      _derivativeKey: string,
      _claimToken: string,
      _output: MediaDerivativeOutput,
    ) {
      throw new Error('not reached');
    },
    async markDerivativeFailed(
      _assetId: string,
      _derivativeKey: string,
      claimToken: string,
      errorCode: string,
    ): Promise<MediaDerivativeRecord> {
      assert.equal(claimToken, claim.claimToken);
      failedCodes.push(errorCode);
      current = {
        ...current,
        state: 'failed',
        leaseExpiresAt: null,
        errorCode,
        completedAt: new Date(),
      };
      return current;
    },
  };

  const result = await runMediaWorkerOnce(
    {async claimNext() { return claim; }},
    repository,
    {
      workRoot: '/tmp/mosaic-deadline-test',
      leaseMs: 120_000,
      timeoutMs: 10_000,
      sourceMaterializer: async () => {
        materializerCalled = true;
        return {inputPath: '/tmp/not-reached.wav'};
      },
      verifyOutput: async () => {
        throw new Error('not reached');
      },
      publishOutput: async () => {
        throw new Error('not reached');
      },
    },
  );

  assert.equal(result.status, 'source_failed');
  assert.equal(result.errorCode, 'media_claim_invalid');
  assert.deepEqual(failedCodes, ['media_claim_invalid']);
  assert.equal(materializerCalled, false);
});

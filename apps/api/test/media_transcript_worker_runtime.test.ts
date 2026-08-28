import assert from 'node:assert/strict';
import {mkdtemp, readdir, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {planMediaNormalization} from '../src/media_normalization.js';
import {
  runTranscriptWorkerOnce,
  type TranscriptRuntimeRepository,
  type TranscriptWorkerDispatcher,
} from '../src/media_transcript_worker_runtime.js';
import {TRANSCRIPT_MEDIA_PROCESSOR} from '../src/media_transcript.js';
import type {
  MediaAssetRecord,
  MediaDerivativeClaim,
  MediaDerivativeOutput,
  MediaDerivativeRecord,
} from '../src/media_repository.js';

function captionClaim(leaseMs = 120_000): MediaDerivativeClaim {
  const plan = planMediaNormalization({
    kind: 'audio' as const,
    durationMs: 4_000,
    audioCodec: 'pcm_s16le',
    sampleRateHz: 44_100,
    channels: 2,
    speech: 'material' as const,
    languageTag: 'en',
  }).find((value) => value.purpose === 'captions');
  assert.ok(plan);
  return {
    claimToken: 'transcript-runtime-claim',
    derivative: {
      assetId: 'asset_transcript_runtime',
      derivativeKey: 'mdv1_transcript_runtime',
      purpose: 'captions',
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

function sourceAsset(): MediaAssetRecord {
  return {
    id: 'asset_transcript_runtime',
    ownerActorId: 'actor_transcript_runtime',
    kind: 'audio',
    state: 'uploaded',
    sourceStorageKey: 'quarantine/asset_transcript_runtime/source.wav',
    sourceSha256: 'a'.repeat(64),
    sourceMimeType: 'audio/wav',
    sourceSizeBytes: 10,
    sourceWidth: null,
    sourceHeight: null,
    sourceDurationMs: 4_000,
    sourceMetadata: {},
    errorCode: null,
  };
}

class FakeTranscriptRuntimeRepository implements TranscriptRuntimeRepository {
  constructor(
    public asset: MediaAssetRecord | null,
    public derivative: MediaDerivativeRecord,
  ) {}

  failedCodes: string[] = [];
  readyCalls = 0;

  async getAsset(): Promise<MediaAssetRecord | null> {
    return this.asset;
  }

  async getDerivative(): Promise<MediaDerivativeRecord | null> {
    return this.derivative;
  }

  async markDerivativeReady(
    _assetId: string,
    _derivativeKey: string,
    token: string,
    output: MediaDerivativeOutput,
  ): Promise<MediaDerivativeRecord> {
    assert.equal(token, 'transcript-runtime-claim');
    this.readyCalls += 1;
    this.derivative = {
      ...this.derivative,
      state: 'ready',
      leaseExpiresAt: null,
      storageKey: output.storageKey,
      mimeType: output.mimeType,
      sizeBytes: output.sizeBytes,
      durationMs: output.durationMs ?? null,
      outputMetadata: output.metadata ?? {},
      errorCode: null,
      completedAt: new Date(),
    };
    return this.derivative;
  }

  async markDerivativeFailed(
    _assetId: string,
    _derivativeKey: string,
    token: string,
    errorCode: string,
  ): Promise<MediaDerivativeRecord> {
    assert.equal(token, 'transcript-runtime-claim');
    this.failedCodes.push(errorCode);
    this.derivative = {
      ...this.derivative,
      state: 'failed',
      leaseExpiresAt: null,
      errorCode,
      completedAt: new Date(),
    };
    return this.derivative;
  }
}

function dispatcher(
  claim: MediaDerivativeClaim | null,
  onProcessors?: (processors: readonly string[]) => void,
): TranscriptWorkerDispatcher {
  return {
    async claimNext(processors) {
      onProcessors?.(processors);
      return claim;
    },
  };
}

test('transcript runtime claims only transcript plans, processes them and removes attempt state', async () => {
  const claim = captionClaim();
  const repository = new FakeTranscriptRuntimeRepository(sourceAsset(), claim.derivative);
  const workRoot = await mkdtemp(join(tmpdir(), 'mosaic-transcript-runtime-'));
  let processors: readonly string[] = [];
  let processCall = 0;

  const result = await runTranscriptWorkerOnce(
    dispatcher(claim, (value) => { processors = value; }),
    repository,
    {
      workRoot,
      whisperModelPath: '/models/model.bin',
      leaseMs: 120_000,
      prepareTimeoutMs: 10_000,
      whisperTimeoutMs: 10_000,
      sourceMaterializer: async (_asset, workDirectory) => {
        const inputPath = join(workDirectory, 'source.wav');
        await writeFile(inputPath, Buffer.from('source'));
        return {inputPath};
      },
      publishOutput: async () => undefined,
      runProcess: async (invocation) => {
        processCall += 1;
        if (processCall === 1) {
          const outputPath = invocation.args.at(-1);
          assert.ok(outputPath);
          await writeFile(outputPath, Buffer.from('wav'));
        } else {
          const outputIndex = invocation.args.indexOf('--output-file');
          const outputBase = invocation.args[outputIndex + 1];
          assert.ok(outputBase);
          await writeFile(
            `${outputBase}.vtt`,
            'WEBVTT\n\n00:00.000 --> 00:03.500\nhello\n',
          );
        }
        return {durationMs: 1, stderrTail: ''};
      },
    },
  );

  assert.deepEqual(processors, [TRANSCRIPT_MEDIA_PROCESSOR]);
  assert.equal(result.status, 'processed');
  assert.equal(result.workerResult?.status, 'ready');
  assert.equal(repository.readyCalls, 1);
  assert.deepEqual(await readdir(workRoot), []);
});

test('transcript runtime fails a missing source without invoking materialization', async () => {
  const claim = captionClaim();
  const repository = new FakeTranscriptRuntimeRepository(null, claim.derivative);
  const workRoot = await mkdtemp(join(tmpdir(), 'mosaic-transcript-missing-'));
  let materialized = false;

  const result = await runTranscriptWorkerOnce(dispatcher(claim), repository, {
    workRoot,
    whisperModelPath: '/models/model.bin',
    leaseMs: 120_000,
    prepareTimeoutMs: 10_000,
    whisperTimeoutMs: 10_000,
    sourceMaterializer: async () => {
      materialized = true;
      return {inputPath: '/tmp/not-reached.wav'};
    },
    publishOutput: async () => undefined,
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.errorCode, 'media_source_unavailable');
  assert.deepEqual(repository.failedCodes, ['media_source_unavailable']);
  assert.equal(materialized, false);
});

test('transcript runtime fences a claim already inside the completion margin before source I/O', async () => {
  const claim = captionClaim(29_000);
  const repository = new FakeTranscriptRuntimeRepository(sourceAsset(), claim.derivative);
  const workRoot = await mkdtemp(join(tmpdir(), 'mosaic-transcript-deadline-'));
  let materialized = false;

  const result = await runTranscriptWorkerOnce(dispatcher(claim), repository, {
    workRoot,
    whisperModelPath: '/models/model.bin',
    leaseMs: 120_000,
    prepareTimeoutMs: 10_000,
    whisperTimeoutMs: 10_000,
    sourceMaterializer: async () => {
      materialized = true;
      return {inputPath: '/tmp/not-reached.wav'};
    },
    publishOutput: async () => undefined,
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.errorCode, 'media_claim_invalid');
  assert.deepEqual(repository.failedCodes, ['media_claim_invalid']);
  assert.equal(materialized, false);
});

test('transcript runtime rejects timeout budgets that can strand a leased caption claim', async () => {
  const claim = captionClaim();
  const repository = new FakeTranscriptRuntimeRepository(sourceAsset(), claim.derivative);
  await assert.rejects(
    () => runTranscriptWorkerOnce(dispatcher(claim), repository, {
      workRoot: '/tmp/mosaic-transcript-budget',
      whisperModelPath: '/models/model.bin',
      leaseMs: 40_000,
      prepareTimeoutMs: 5_000,
      whisperTimeoutMs: 5_000,
      sourceMaterializer: async () => ({inputPath: '/tmp/not-reached.wav'}),
      publishOutput: async () => undefined,
    }),
    /completion margin/,
  );
});

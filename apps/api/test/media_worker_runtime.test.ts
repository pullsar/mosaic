import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readdir, symlink, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {
  createLocalMediaSourceMaterializer,
  runMediaWorkerOnce,
  type MediaWorkerDispatcher,
  type MediaWorkerRepository,
} from '../src/media_worker_runtime.js';
import {
  MediaIdentityConflictError,
  type MediaAssetRecord,
  type MediaDerivativeClaim,
  type MediaDerivativeOutput,
  type MediaDerivativeRecord,
} from '../src/media_repository.js';
import {sha256File} from '../src/media_object_store.js';
import {planMediaNormalization} from '../src/media_normalization.js';

function claimedDerivative(): MediaDerivativeClaim {
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
    claimToken: 'runtime-claim',
    derivative: {
      assetId: 'asset_runtime',
      derivativeKey: 'mdv1_runtime',
      purpose: 'audio',
      state: 'processing',
      sourceSha256: 'a'.repeat(64),
      planVersion: plan.version,
      plan,
      attemptCount: 1,
      leaseExpiresAt: new Date(Date.now() + 120_000),
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

function asset(sourceSha256 = 'a'.repeat(64), sizeBytes = 10): MediaAssetRecord {
  return {
    id: 'asset_runtime',
    ownerActorId: 'actor_runtime',
    kind: 'audio',
    state: 'uploaded',
    sourceStorageKey: 'quarantine/asset_runtime/source.wav',
    sourceSha256,
    sourceMimeType: 'audio/wav',
    sourceSizeBytes: sizeBytes,
    sourceWidth: null,
    sourceHeight: null,
    sourceDurationMs: 1_000,
    sourceMetadata: {},
    errorCode: null,
  };
}

class FakeRuntimeRepository implements MediaWorkerRepository {
  constructor(
    public currentAsset: MediaAssetRecord | null,
    public currentDerivative: MediaDerivativeRecord,
  ) {}

  failedCodes: string[] = [];
  readyCalls = 0;

  async getAsset(): Promise<MediaAssetRecord | null> {
    return this.currentAsset;
  }

  async getDerivative(): Promise<MediaDerivativeRecord | null> {
    return this.currentDerivative;
  }

  async claimDerivative(): Promise<MediaDerivativeClaim | null> {
    throw new Error('runtime uses dispatcher-owned claims');
  }

  async markDerivativeReady(
    _assetId: string,
    _derivativeKey: string,
    token: string,
    output: MediaDerivativeOutput,
  ): Promise<MediaDerivativeRecord> {
    assert.equal(token, 'runtime-claim');
    this.readyCalls += 1;
    this.currentDerivative = {
      ...this.currentDerivative,
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
      outputMetadata: output.metadata ?? {},
      errorCode: null,
      completedAt: new Date(),
    };
    return this.currentDerivative;
  }

  async markDerivativeFailed(
    _assetId: string,
    _derivativeKey: string,
    token: string,
    errorCode: string,
  ): Promise<MediaDerivativeRecord> {
    assert.equal(token, 'runtime-claim');
    this.failedCodes.push(errorCode);
    this.currentDerivative = {
      ...this.currentDerivative,
      state: 'failed',
      leaseExpiresAt: null,
      errorCode,
      completedAt: new Date(),
    };
    return this.currentDerivative;
  }
}

function dispatcher(claim: MediaDerivativeClaim | null): MediaWorkerDispatcher {
  return {
    async claimNext() {
      return claim;
    },
  };
}

test('runtime processes one dispatcher claim and removes its temporary work directory', async () => {
  const claim = claimedDerivative();
  const repository = new FakeRuntimeRepository(asset(), claim.derivative);
  const workRoot = await mkdtemp(join(tmpdir(), 'mosaic-worker-'));
  let materializedWorkDirectory: string | null = null;

  const result = await runMediaWorkerOnce(dispatcher(claim), repository, {
    workRoot,
    leaseMs: 120_000,
    timeoutMs: 10_000,
    sourceMaterializer: async (_asset, workDirectory) => {
      materializedWorkDirectory = workDirectory;
      return {inputPath: '/tmp/mosaic/source.wav'};
    },
    verifyOutput: async () => ({
      mimeType: 'audio/mp4',
      sizeBytes: 100,
      durationMs: 1_000,
      container: 'mp4',
      audioCodec: 'aac',
    }),
    publishOutput: async () => undefined,
    runProcess: async () => ({durationMs: 1, stderrTail: ''}),
  });

  assert.equal(result.status, 'processed');
  assert.equal(result.workerResult?.status, 'ready');
  assert.equal(repository.readyCalls, 1);
  assert.ok(materializedWorkDirectory);
  assert.deepEqual(await readdir(workRoot), []);
});

test('runtime fails claimed work immediately when immutable source metadata is unavailable', async () => {
  const claim = claimedDerivative();
  const repository = new FakeRuntimeRepository(null, claim.derivative);
  const workRoot = await mkdtemp(join(tmpdir(), 'mosaic-worker-'));
  let materializerCalled = false;

  const result = await runMediaWorkerOnce(dispatcher(claim), repository, {
    workRoot,
    leaseMs: 120_000,
    timeoutMs: 10_000,
    sourceMaterializer: async () => {
      materializerCalled = true;
      return {inputPath: '/tmp/mosaic/source.wav'};
    },
    verifyOutput: async () => {
      throw new Error('not reached');
    },
    publishOutput: async () => undefined,
  });

  assert.equal(result.status, 'source_failed');
  assert.equal(result.errorCode, 'media_source_unavailable');
  assert.deepEqual(repository.failedCodes, ['media_source_unavailable']);
  assert.equal(materializerCalled, false);
});

test('source failure reports stale if the dispatcher claim was replaced', async () => {
  const claim = claimedDerivative();
  const repository = new FakeRuntimeRepository(null, claim.derivative);
  repository.markDerivativeFailed = async () => {
    throw new MediaIdentityConflictError('replaced');
  };
  const workRoot = await mkdtemp(join(tmpdir(), 'mosaic-worker-'));

  const result = await runMediaWorkerOnce(dispatcher(claim), repository, {
    workRoot,
    leaseMs: 120_000,
    timeoutMs: 10_000,
    sourceMaterializer: async () => ({inputPath: '/tmp/mosaic/source.wav'}),
    verifyOutput: async () => {
      throw new Error('not reached');
    },
    publishOutput: async () => undefined,
  });

  assert.equal(result.status, 'stale');
});

test('runtime does no filesystem work when queue is idle or already aborted', async () => {
  const claim = claimedDerivative();
  const repository = new FakeRuntimeRepository(asset(), claim.derivative);

  const idle = await runMediaWorkerOnce(dispatcher(null), repository, {
    workRoot: '/path/that/does/not/need/to/exist',
    leaseMs: 120_000,
    timeoutMs: 10_000,
    sourceMaterializer: async () => {
      throw new Error('not reached');
    },
    verifyOutput: async () => {
      throw new Error('not reached');
    },
    publishOutput: async () => undefined,
  });
  assert.equal(idle.status, 'idle');

  const controller = new AbortController();
  controller.abort();
  const aborted = await runMediaWorkerOnce(dispatcher(claim), repository, {
    workRoot: '/path/that/does/not/need/to/exist',
    leaseMs: 120_000,
    timeoutMs: 10_000,
    signal: controller.signal,
    sourceMaterializer: async () => {
      throw new Error('not reached');
    },
    verifyOutput: async () => {
      throw new Error('not reached');
    },
    publishOutput: async () => undefined,
  });
  assert.equal(aborted.status, 'aborted');
});

test('local source materializer verifies realpath containment, size and SHA-256', async () => {
  const sourceRoot = await mkdtemp(join(tmpdir(), 'mosaic-source-'));
  const quarantine = join(sourceRoot, 'quarantine/asset_runtime');
  await mkdir(quarantine, {recursive: true});
  const source = join(quarantine, 'source.wav');
  await writeFile(source, Buffer.from('source-data'));
  const digest = await sha256File(source);
  const materializer = createLocalMediaSourceMaterializer(sourceRoot);
  const verifiedAsset = asset(digest, 11);

  const materialized = await materializer(
    verifiedAsset,
    await mkdtemp(join(tmpdir(), 'mosaic-work-')),
  );
  assert.equal(materialized.inputPath, source);

  await assert.rejects(
    materializer(asset('0'.repeat(64), 11), await mkdtemp(join(tmpdir(), 'mosaic-work-'))),
    /digest no longer matches/,
  );
  await assert.rejects(
    materializer(asset(digest, 999), await mkdtemp(join(tmpdir(), 'mosaic-work-'))),
    /size no longer matches/,
  );

  const outside = await mkdtemp(join(tmpdir(), 'mosaic-outside-'));
  const outsideFile = join(outside, 'source.wav');
  await writeFile(outsideFile, Buffer.from('source-data'));
  const link = join(sourceRoot, 'escape.wav');
  await symlink(outsideFile, link);
  const escaped = {...verifiedAsset, sourceStorageKey: 'escape.wav'};
  await assert.rejects(
    materializer(escaped, await mkdtemp(join(tmpdir(), 'mosaic-work-'))),
    /escapes its configured root/,
  );
});

test('runtime rejects lease/timeout combinations that can strand processing claims', async () => {
  const claim = claimedDerivative();
  const repository = new FakeRuntimeRepository(asset(), claim.derivative);
  await assert.rejects(
    runMediaWorkerOnce(dispatcher(claim), repository, {
      workRoot: '/tmp/mosaic',
      leaseMs: 40_000,
      timeoutMs: 10_000,
      sourceMaterializer: async () => ({inputPath: '/tmp/mosaic/source.wav'}),
      verifyOutput: async () => {
        throw new Error('not reached');
      },
      publishOutput: async () => undefined,
    }),
    /leave at least 30000 ms/,
  );
});

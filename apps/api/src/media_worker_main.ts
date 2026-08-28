import {mkdir} from 'node:fs/promises';
import {Pool} from 'pg';
import {PostgresMediaDispatcher} from './media_dispatcher.js';
import {createFfprobeOutputVerifier} from './media_ffprobe.js';
import {
  createMediaOutputPublisher,
  LocalMediaObjectStore,
} from './media_object_store.js';
import {
  createS3MediaSourceMaterializer,
  S3CompatibleMediaStorage,
} from './media_s3_storage.js';
import {PostgresMediaRepository} from './media_repository.js';
import {loadMediaWorkerConfig} from './media_worker_config.js';
import {
  createLocalMediaSourceMaterializer,
  type MediaSourceMaterializer,
  runMediaWorkerLoop,
} from './media_worker_runtime.js';
import type {MediaOutputPublisher} from './media_ffmpeg_worker.js';

async function main(): Promise<void> {
  const config = loadMediaWorkerConfig();
  await mkdir(config.workRoot, {recursive: true, mode: 0o700});

  let publisher: MediaOutputPublisher;
  let sourceMaterializer: MediaSourceMaterializer;
  if (config.storageMode === 'local') {
    await mkdir(config.objectRoot, {recursive: true, mode: 0o750});
    publisher = createMediaOutputPublisher(
      new LocalMediaObjectStore({rootPath: config.objectRoot}),
    );
    sourceMaterializer = createLocalMediaSourceMaterializer(config.sourceRoot);
  } else {
    const storage = new S3CompatibleMediaStorage({
      endpoint: config.s3Endpoint,
      bucket: config.s3Bucket,
      region: config.s3Region,
      accessKeyId: config.s3AccessKeyId,
      secretAccessKey: config.s3SecretAccessKey,
      requestTimeoutMs: config.storageTimeoutMs,
      ...(config.s3SessionToken === undefined
        ? {}
        : {sessionToken: config.s3SessionToken}),
    });
    publisher = createMediaOutputPublisher(storage);
    sourceMaterializer = createS3MediaSourceMaterializer(storage);
  }

  const pool = new Pool({connectionString: config.databaseUrl});
  const repository = new PostgresMediaRepository(pool);
  const dispatcher = new PostgresMediaDispatcher(pool, repository);
  const verifier = createFfprobeOutputVerifier({
    executable: config.ffprobeExecutable,
  });
  const controller = new AbortController();
  const stop = (): void => controller.abort();
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);

  try {
    await runMediaWorkerLoop(dispatcher, repository, {
      sourceMaterializer,
      verifyOutput: verifier,
      publishOutput: publisher,
      workRoot: config.workRoot,
      leaseMs: config.leaseMs,
      timeoutMs: config.timeoutMs,
      idleMs: config.idleMs,
      signal: controller.signal,
      ffmpegExecutable: config.ffmpegExecutable,
      onResult(result) {
        if (result.status === 'idle' || result.status === 'aborted') return;
        console.info(JSON.stringify({
          event: 'media_worker_iteration',
          status: result.status,
          assetId: result.claim?.derivative.assetId ?? null,
          derivativeKey: result.claim?.derivative.derivativeKey ?? null,
          purpose: result.claim?.derivative.purpose ?? null,
          workerStatus: result.workerResult?.status ?? null,
          errorCode: result.errorCode ?? result.workerResult?.errorCode ?? null,
        }));
      },
    });
  } finally {
    process.removeListener('SIGTERM', stop);
    process.removeListener('SIGINT', stop);
    await pool.end();
  }
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(JSON.stringify({event: 'media_worker_fatal', message}));
  process.exitCode = 1;
});

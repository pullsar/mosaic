import {mkdir, stat} from 'node:fs/promises';
import {Pool} from 'pg';
import {PostgresMediaDispatcher} from './media_dispatcher.js';
import {PostgresMediaRepository} from './media_repository.js';
import {createTranscriptProcessRunner} from './media_transcript_process.js';
import {loadTranscriptWorkerConfig} from './media_transcript_worker_config.js';
import {runTranscriptWorkerLoop} from './media_transcript_worker_runtime.js';
import {createMediaWorkerStorage} from './media_worker_storage.js';

async function main(): Promise<void> {
  const config = loadTranscriptWorkerConfig();
  await mkdir(config.workRoot, {recursive: true, mode: 0o700});
  await assertModelReady(config.whisperModelPath);
  const storage = await createMediaWorkerStorage(config);
  const runProcess = createTranscriptProcessRunner({
    whisperExecutable: config.whisperExecutable,
    whisperThreads: config.whisperThreads,
  });

  const pool = new Pool({connectionString: config.databaseUrl});
  const repository = new PostgresMediaRepository(pool);
  const dispatcher = new PostgresMediaDispatcher(pool, repository);
  const controller = new AbortController();
  const stop = (): void => controller.abort();
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);

  try {
    await runTranscriptWorkerLoop(dispatcher, repository, {
      sourceMaterializer: storage.sourceMaterializer,
      publishOutput: storage.publishOutput,
      workRoot: config.workRoot,
      whisperModelPath: config.whisperModelPath,
      leaseMs: config.leaseMs,
      prepareTimeoutMs: config.prepareTimeoutMs,
      whisperTimeoutMs: config.whisperTimeoutMs,
      idleMs: config.idleMs,
      maxVttBytes: config.maxVttBytes,
      signal: controller.signal,
      ffmpegExecutable: config.ffmpegExecutable,
      whisperExecutable: config.whisperExecutable,
      runProcess,
      onResult(result) {
        if (result.status === 'idle' || result.status === 'aborted') return;
        console.info(JSON.stringify({
          event: 'media_transcript_worker_iteration',
          status: result.status,
          assetId: result.claim?.derivative.assetId ?? null,
          derivativeKey: result.claim?.derivative.derivativeKey ?? null,
          workerStatus: result.workerResult?.status ?? null,
          errorCode: result.errorCode ?? null,
        }));
      },
    });
  } finally {
    process.removeListener('SIGTERM', stop);
    process.removeListener('SIGINT', stop);
    await pool.end();
  }
}

async function assertModelReady(path: string): Promise<void> {
  const info = await stat(path);
  if (!info.isFile() || !Number.isSafeInteger(info.size) || info.size <= 0) {
    throw new Error('MEDIA_TRANSCRIPT_MODEL_PATH must reference a non-empty regular file');
  }
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(JSON.stringify({event: 'media_transcript_worker_fatal', message}));
  process.exitCode = 1;
});

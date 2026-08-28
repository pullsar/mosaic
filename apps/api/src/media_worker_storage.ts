import {mkdir} from 'node:fs/promises';
import type {MediaOutputPublisher} from './media_ffmpeg_worker.js';
import {createMediaOutputPublisher, LocalMediaObjectStore} from './media_object_store.js';
import {
  createS3MediaSourceMaterializer,
  S3CompatibleMediaStorage,
} from './media_s3_storage.js';
import type {MediaStorageConfig} from './media_storage_config.js';
import {
  createLocalMediaSourceMaterializer,
  type MediaSourceMaterializer,
} from './media_worker_runtime.js';

export interface MediaWorkerStorage {
  publishOutput: MediaOutputPublisher;
  sourceMaterializer: MediaSourceMaterializer;
}

export async function createMediaWorkerStorage(
  config: MediaStorageConfig,
): Promise<MediaWorkerStorage> {
  if (config.storageMode === 'local') {
    await mkdir(config.objectRoot, {recursive: true, mode: 0o750});
    return {
      publishOutput: createMediaOutputPublisher(
        new LocalMediaObjectStore({rootPath: config.objectRoot}),
      ),
      sourceMaterializer: createLocalMediaSourceMaterializer(config.sourceRoot),
    };
  }

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
  return {
    publishOutput: createMediaOutputPublisher(storage),
    sourceMaterializer: createS3MediaSourceMaterializer(storage),
  };
}

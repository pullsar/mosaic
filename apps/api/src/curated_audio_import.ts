import {stat} from 'node:fs/promises';
import {dirname, isAbsolute, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {Pool} from 'pg';
import {echoArchitectAudioAssets, type CuratedAudioAsset} from './curated_audio.js';
import {planMediaNormalization} from './media_normalization.js';
import {LocalMediaObjectStore, type MediaObjectStore} from './media_object_store.js';
import {PostgresMediaRepository} from './media_repository.js';
import {S3CompatibleMediaStorage} from './media_s3_storage.js';
import {loadMediaStorageConfig, type MediaStorageConfig} from './media_storage_config.js';

const CURATED_AUDIO_OWNER = 'mixli_curated_audio';
const here = dirname(fileURLToPath(import.meta.url));

/**
 * Publishes reviewed source files into the worker's source store and schedules
 * the ordinary immutable audio derivative. The media worker, not this command,
 * produces the delivery object; feeds remain safely gated until that succeeds.
 */
export async function importCuratedAudio(
  pool: Pool,
  storage: MediaStorageConfig,
): Promise<{registeredAssets: number}> {
  const repository = new PostgresMediaRepository(pool);
  const store = sourceStore(storage);
  await pool.query(
    `insert into actors (id) values ($1) on conflict (id) do nothing`,
    [CURATED_AUDIO_OWNER],
  );
  for (const asset of echoArchitectAudioAssets) {
    await importOne(repository, store, asset);
  }
  return {registeredAssets: echoArchitectAudioAssets.length};
}

async function importOne(
  repository: PostgresMediaRepository,
  store: MediaObjectStore,
  asset: CuratedAudioAsset,
): Promise<void> {
  const sourcePath = resolve(here, '..', asset.sourcePath);
  if (!isAbsolute(sourcePath)) throw new Error('Curated audio path must be absolute.');
  const source = await stat(sourcePath);
  if (!source.isFile() || source.size <= 0) {
    throw new Error(`Curated audio source is missing: ${asset.sourcePath}`);
  }
  const storageKey = `curated/echo_architect/${asset.sourceSha256}.m4a`;
  await store.putFileIfAbsent({
    storageKey,
    sourcePath,
    sizeBytes: source.size,
    sha256: asset.sourceSha256,
    mimeType: 'audio/mp4',
  });
  await repository.createAsset(asset.assetId, CURATED_AUDIO_OWNER, 'audio');
  await repository.attachSource(asset.assetId, {
    storageKey,
    sourceSha256: asset.sourceSha256,
    mimeType: 'audio/mp4',
    sizeBytes: source.size,
    durationMs: asset.durationMs,
    metadata: {
      source: 'FreePats Upright Piano KW',
      license: 'CC0-1.0',
      sourcePath: asset.sourcePath,
    },
  });
  const plans = planMediaNormalization({
    kind: 'audio',
    durationMs: asset.durationMs,
    audioCodec: 'aac',
    sampleRateHz: 44100,
    channels: 2,
    speech: 'none',
  });
  for (const plan of plans) await repository.registerDerivative(asset.assetId, plan);
}

function sourceStore(config: MediaStorageConfig): MediaObjectStore {
  if (config.storageMode === 'local') {
    return new LocalMediaObjectStore({rootPath: config.sourceRoot});
  }
  return new S3CompatibleMediaStorage({
    endpoint: config.s3Endpoint,
    bucket: config.s3Bucket,
    region: config.s3Region,
    accessKeyId: config.s3AccessKeyId,
    secretAccessKey: config.s3SecretAccessKey,
    requestTimeoutMs: config.storageTimeoutMs,
    ...(config.s3SessionToken === undefined ? {} : {sessionToken: config.s3SessionToken}),
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const pool = new Pool({connectionString: process.env.DATABASE_URL});
  try {
    const result = await importCuratedAudio(pool, loadMediaStorageConfig());
    console.log(JSON.stringify(result));
  } finally {
    await pool.end();
  }
}

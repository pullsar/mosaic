import assert from 'node:assert/strict';
import {test} from 'node:test';
import {loadMediaWorkerConfig} from '../src/media_worker_config.js';

const localBase = {
  DATABASE_URL: 'postgres://mosaic:mosaic@localhost:5432/mosaic',
  MEDIA_WORKER_SOURCE_ROOT: '/srv/mosaic/quarantine',
  MEDIA_WORKER_WORK_ROOT: '/srv/mosaic/work',
  MEDIA_WORKER_OBJECT_ROOT: '/srv/mosaic/objects',
};

const s3Base = {
  DATABASE_URL: localBase.DATABASE_URL,
  MEDIA_WORKER_STORAGE_MODE: 's3',
  MEDIA_WORKER_WORK_ROOT: '/srv/mosaic/work',
  MEDIA_S3_ENDPOINT: 'https://account.r2.cloudflarestorage.com',
  MEDIA_S3_BUCKET: 'mosaic-media',
  MEDIA_S3_REGION: 'auto',
  MEDIA_S3_ACCESS_KEY_ID: 'ACCESS123',
  MEDIA_S3_SECRET_ACCESS_KEY: 'secret/with+symbols=',
};

test('local worker config requires explicit roots and applies bounded safe defaults', () => {
  const config = loadMediaWorkerConfig(localBase);
  assert.equal(config.storageMode, 'local');
  if (config.storageMode !== 'local') assert.fail('expected local config');
  assert.equal(config.databaseUrl, localBase.DATABASE_URL);
  assert.equal(config.sourceRoot, localBase.MEDIA_WORKER_SOURCE_ROOT);
  assert.equal(config.workRoot, localBase.MEDIA_WORKER_WORK_ROOT);
  assert.equal(config.objectRoot, localBase.MEDIA_WORKER_OBJECT_ROOT);
  assert.equal(config.leaseMs, 15 * 60 * 1000);
  assert.equal(config.timeoutMs, 10 * 60 * 1000);
  assert.equal(config.idleMs, 1_000);
  assert.equal(config.ffmpegExecutable, 'ffmpeg');
  assert.equal(config.ffprobeExecutable, 'ffprobe');
});

test('worker config accepts explicit executable and timing overrides', () => {
  const config = loadMediaWorkerConfig({
    ...localBase,
    MEDIA_WORKER_LEASE_MS: '120000',
    MEDIA_WORKER_TIMEOUT_MS: '60000',
    MEDIA_WORKER_IDLE_MS: '250',
    MEDIA_FFMPEG_PATH: '/opt/media/bin/ffmpeg',
    MEDIA_FFPROBE_PATH: '/opt/media/bin/ffprobe',
  });
  assert.equal(config.leaseMs, 120_000);
  assert.equal(config.timeoutMs, 60_000);
  assert.equal(config.idleMs, 250);
  assert.equal(config.ffmpegExecutable, '/opt/media/bin/ffmpeg');
  assert.equal(config.ffprobeExecutable, '/opt/media/bin/ffprobe');
});

test('local worker config rejects relative roots, malformed integers and unsafe lease margins', () => {
  assert.throws(
    () => loadMediaWorkerConfig({...localBase, MEDIA_WORKER_SOURCE_ROOT: 'relative'}),
    /must be an absolute path/,
  );
  assert.throws(
    () => loadMediaWorkerConfig({...localBase, MEDIA_WORKER_IDLE_MS: '1.5'}),
    /positive integer/,
  );
  assert.throws(
    () => loadMediaWorkerConfig({
      ...localBase,
      MEDIA_WORKER_LEASE_MS: '40000',
      MEDIA_WORKER_TIMEOUT_MS: '10000',
    }),
    /leave at least 30000 ms/,
  );
});

test('local worker config does not silently derive storage roots from current working directory', () => {
  assert.throws(
    () => loadMediaWorkerConfig({
      DATABASE_URL: localBase.DATABASE_URL,
      MEDIA_WORKER_WORK_ROOT: localBase.MEDIA_WORKER_WORK_ROOT,
    }),
    /MEDIA_WORKER_SOURCE_ROOT is required/,
  );
});

test('S3 worker config requires explicit remote identity and does not require local source/object roots', () => {
  const config = loadMediaWorkerConfig(s3Base);
  assert.equal(config.storageMode, 's3');
  if (config.storageMode !== 's3') assert.fail('expected S3 config');
  assert.equal(config.storageTimeoutMs, 60_000);
  assert.equal(config.s3Endpoint, s3Base.MEDIA_S3_ENDPOINT);
  assert.equal(config.s3Bucket, s3Base.MEDIA_S3_BUCKET);
  assert.equal(config.s3Region, 'auto');
  assert.equal(config.s3AccessKeyId, 'ACCESS123');
  assert.equal(config.s3SecretAccessKey, 'secret/with+symbols=');
});

test('S3 worker config rejects unsafe endpoints, missing credentials and remote lease budgets', () => {
  assert.throws(
    () => loadMediaWorkerConfig({...s3Base, MEDIA_S3_ENDPOINT: 'http://storage.test'}),
    /HTTPS origin/,
  );
  const {MEDIA_S3_SECRET_ACCESS_KEY: _secret, ...missingSecret} = s3Base;
  assert.throws(
    () => loadMediaWorkerConfig(missingSecret),
    /MEDIA_S3_SECRET_ACCESS_KEY is required/,
  );
  assert.throws(
    () => loadMediaWorkerConfig({
      ...s3Base,
      MEDIA_WORKER_LEASE_MS: '180000',
      MEDIA_WORKER_TIMEOUT_MS: '60000',
      MEDIA_WORKER_STORAGE_TIMEOUT_MS: '30000',
    }),
    /S3 worker timing is unsafe/,
  );
});

test('worker config rejects unknown storage modes instead of falling back', () => {
  assert.throws(
    () => loadMediaWorkerConfig({...localBase, MEDIA_WORKER_STORAGE_MODE: 'magic'}),
    /must be local or s3/,
  );
});

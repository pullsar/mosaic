import assert from 'node:assert/strict';
import {test} from 'node:test';
import {loadTranscriptWorkerConfig} from '../src/media_transcript_worker_config.js';

const localBase = {
  DATABASE_URL: 'postgres://mosaic:mosaic@localhost:5432/mosaic',
  MEDIA_WORKER_STORAGE_MODE: 'local',
  MEDIA_WORKER_SOURCE_ROOT: '/srv/mosaic/quarantine',
  MEDIA_WORKER_OBJECT_ROOT: '/srv/mosaic/objects',
  MEDIA_TRANSCRIPT_WORK_ROOT: '/srv/mosaic/transcript-work',
  MEDIA_TRANSCRIPT_MODEL_PATH: '/srv/mosaic/models/ggml-base.bin',
};

const s3Base = {
  DATABASE_URL: localBase.DATABASE_URL,
  MEDIA_WORKER_STORAGE_MODE: 's3',
  MEDIA_S3_ENDPOINT: 'https://storage.example.test',
  MEDIA_S3_BUCKET: 'mosaic-media',
  MEDIA_S3_REGION: 'auto',
  MEDIA_S3_ACCESS_KEY_ID: 'ACCESS123',
  MEDIA_S3_SECRET_ACCESS_KEY: 'secret/with+symbols=',
  MEDIA_TRANSCRIPT_WORK_ROOT: localBase.MEDIA_TRANSCRIPT_WORK_ROOT,
  MEDIA_TRANSCRIPT_MODEL_PATH: localBase.MEDIA_TRANSCRIPT_MODEL_PATH,
};

test('local transcript config requires explicit roots/model and applies safe defaults', () => {
  const config = loadTranscriptWorkerConfig(localBase);
  assert.equal(config.storageMode, 'local');
  assert.equal(config.databaseUrl, localBase.DATABASE_URL);
  assert.equal(config.workRoot, localBase.MEDIA_TRANSCRIPT_WORK_ROOT);
  assert.equal(config.whisperModelPath, localBase.MEDIA_TRANSCRIPT_MODEL_PATH);
  assert.equal(config.leaseMs, 30 * 60 * 1000);
  assert.equal(config.prepareTimeoutMs, 2 * 60 * 1000);
  assert.equal(config.whisperTimeoutMs, 20 * 60 * 1000);
  assert.equal(config.idleMs, 1_000);
  assert.equal(config.maxVttBytes, 4 * 1024 * 1024);
  assert.equal(config.whisperThreads, 4);
  assert.equal(config.ffmpegExecutable, 'ffmpeg');
  assert.equal(config.whisperExecutable, 'whisper-cli');
  if (config.storageMode !== 'local') assert.fail('expected local config');
  assert.equal(config.sourceRoot, localBase.MEDIA_WORKER_SOURCE_ROOT);
  assert.equal(config.objectRoot, localBase.MEDIA_WORKER_OBJECT_ROOT);
});

test('transcript config accepts explicit engine and bounded runtime tuning', () => {
  const config = loadTranscriptWorkerConfig({
    ...localBase,
    MEDIA_TRANSCRIPT_LEASE_MS: '1500000',
    MEDIA_TRANSCRIPT_PREPARE_TIMEOUT_MS: '60000',
    MEDIA_TRANSCRIPT_WHISPER_TIMEOUT_MS: '1200000',
    MEDIA_TRANSCRIPT_IDLE_MS: '250',
    MEDIA_TRANSCRIPT_MAX_VTT_BYTES: '8388608',
    MEDIA_TRANSCRIPT_WHISPER_THREADS: '8',
    MEDIA_TRANSCRIPT_WHISPER_PATH: '/opt/whisper/whisper-cli',
    MEDIA_FFMPEG_PATH: '/usr/bin/ffmpeg',
  });
  assert.equal(config.leaseMs, 1_500_000);
  assert.equal(config.prepareTimeoutMs, 60_000);
  assert.equal(config.whisperTimeoutMs, 1_200_000);
  assert.equal(config.idleMs, 250);
  assert.equal(config.maxVttBytes, 8_388_608);
  assert.equal(config.whisperThreads, 8);
  assert.equal(config.whisperExecutable, '/opt/whisper/whisper-cli');
  assert.equal(config.ffmpegExecutable, '/usr/bin/ffmpeg');
});

test('S3 transcript config shares storage identity and budgets GET/PUT/HEAD inside the lease', () => {
  const config = loadTranscriptWorkerConfig(s3Base);
  assert.equal(config.storageMode, 's3');
  if (config.storageMode !== 's3') assert.fail('expected s3 config');
  assert.equal(config.s3Endpoint, s3Base.MEDIA_S3_ENDPOINT);
  assert.equal(config.s3Bucket, s3Base.MEDIA_S3_BUCKET);
  assert.equal(config.storageTimeoutMs, 60_000);

  assert.throws(
    () => loadTranscriptWorkerConfig({
      ...s3Base,
      MEDIA_WORKER_STORAGE_TIMEOUT_MS: '300000',
    }),
    /Transcript worker timing is unsafe/,
  );
});

test('transcript config rejects unsafe paths, thread counts and lease budgets', () => {
  assert.throws(
    () => loadTranscriptWorkerConfig({
      ...localBase,
      MEDIA_TRANSCRIPT_MODEL_PATH: 'models/model.bin',
    }),
    /must be an absolute path/,
  );
  assert.throws(
    () => loadTranscriptWorkerConfig({
      ...localBase,
      MEDIA_TRANSCRIPT_WHISPER_THREADS: '65',
    }),
    /positive safe integer <= 64/,
  );
  assert.throws(
    () => loadTranscriptWorkerConfig({
      ...localBase,
      MEDIA_TRANSCRIPT_LEASE_MS: '1300000',
    }),
    /Transcript worker timing is unsafe/,
  );
  assert.throws(
    () => loadTranscriptWorkerConfig({
      DATABASE_URL: localBase.DATABASE_URL,
      MEDIA_WORKER_STORAGE_MODE: 'local',
      MEDIA_WORKER_SOURCE_ROOT: localBase.MEDIA_WORKER_SOURCE_ROOT,
      MEDIA_WORKER_OBJECT_ROOT: localBase.MEDIA_WORKER_OBJECT_ROOT,
    }),
    /MEDIA_TRANSCRIPT_WORK_ROOT is required/,
  );
});

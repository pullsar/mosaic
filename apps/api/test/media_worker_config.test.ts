import assert from 'node:assert/strict';
import {test} from 'node:test';
import {loadMediaWorkerConfig} from '../src/media_worker_config.js';

const base = {
  DATABASE_URL: 'postgres://mosaic:mosaic@localhost:5432/mosaic',
  MEDIA_WORKER_SOURCE_ROOT: '/srv/mosaic/quarantine',
  MEDIA_WORKER_WORK_ROOT: '/srv/mosaic/work',
  MEDIA_WORKER_OBJECT_ROOT: '/srv/mosaic/objects',
};

test('worker config requires explicit roots and applies bounded safe defaults', () => {
  const config = loadMediaWorkerConfig(base);
  assert.equal(config.databaseUrl, base.DATABASE_URL);
  assert.equal(config.sourceRoot, base.MEDIA_WORKER_SOURCE_ROOT);
  assert.equal(config.workRoot, base.MEDIA_WORKER_WORK_ROOT);
  assert.equal(config.objectRoot, base.MEDIA_WORKER_OBJECT_ROOT);
  assert.equal(config.leaseMs, 15 * 60 * 1000);
  assert.equal(config.timeoutMs, 10 * 60 * 1000);
  assert.equal(config.idleMs, 1_000);
  assert.equal(config.ffmpegExecutable, 'ffmpeg');
  assert.equal(config.ffprobeExecutable, 'ffprobe');
});

test('worker config accepts explicit executable and timing overrides', () => {
  const config = loadMediaWorkerConfig({
    ...base,
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

test('worker config rejects relative roots, malformed integers and unsafe lease margins', () => {
  assert.throws(
    () => loadMediaWorkerConfig({...base, MEDIA_WORKER_SOURCE_ROOT: 'relative'}),
    /must be an absolute path/,
  );
  assert.throws(
    () => loadMediaWorkerConfig({...base, MEDIA_WORKER_IDLE_MS: '1.5'}),
    /positive integer/,
  );
  assert.throws(
    () => loadMediaWorkerConfig({
      ...base,
      MEDIA_WORKER_LEASE_MS: '40000',
      MEDIA_WORKER_TIMEOUT_MS: '10000',
    }),
    /leave at least 30000 ms/,
  );
});

test('worker config does not silently derive roots from current working directory', () => {
  assert.throws(
    () => loadMediaWorkerConfig({DATABASE_URL: base.DATABASE_URL}),
    /MEDIA_WORKER_SOURCE_ROOT is required/,
  );
});

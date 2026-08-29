import assert from 'node:assert/strict';
import {test} from 'node:test';
import {loadMediaDeliveryStorageConfig} from '../src/media_delivery_config.js';

const s3 = {
  MEDIA_DELIVERY_STORAGE_MODE: 's3',
  MEDIA_S3_ENDPOINT: 'https://account.r2.cloudflarestorage.com',
  MEDIA_S3_BUCKET: 'mosaic-media',
  MEDIA_S3_REGION: 'auto',
  MEDIA_S3_ACCESS_KEY_ID: 'ACCESS123',
  MEDIA_S3_SECRET_ACCESS_KEY: 'secret/with+symbols=',
};

test('media delivery stays explicitly disabled by default', () => {
  assert.deepEqual(loadMediaDeliveryStorageConfig({}), {storageMode: 'disabled'});
});

test('local media delivery requires only an explicit immutable object root', () => {
  assert.deepEqual(
    loadMediaDeliveryStorageConfig({
      MEDIA_DELIVERY_STORAGE_MODE: 'local',
      MEDIA_DELIVERY_OBJECT_ROOT: '/srv/mosaic/objects',
    }),
    {storageMode: 'local', objectRoot: '/srv/mosaic/objects'},
  );
  assert.throws(
    () => loadMediaDeliveryStorageConfig({MEDIA_DELIVERY_STORAGE_MODE: 'local'}),
    /MEDIA_DELIVERY_OBJECT_ROOT is required/,
  );
});

test('S3 media delivery reuses validated private S3 identity without worker roots', () => {
  const config = loadMediaDeliveryStorageConfig(s3);
  assert.equal(config.storageMode, 's3');
  if (config.storageMode !== 's3') assert.fail('expected S3 config');
  assert.equal(config.storageTimeoutMs, 60_000);
  assert.equal(config.s3Endpoint, s3.MEDIA_S3_ENDPOINT);
  assert.equal(config.s3Bucket, s3.MEDIA_S3_BUCKET);
  assert.equal(config.s3Region, 'auto');
  assert.equal(config.s3AccessKeyId, 'ACCESS123');
  assert.equal(config.s3SecretAccessKey, 'secret/with+symbols=');
});

test('media delivery rejects unsafe modes, endpoints and timeout values', () => {
  assert.throws(
    () => loadMediaDeliveryStorageConfig({MEDIA_DELIVERY_STORAGE_MODE: 'magic'}),
    /disabled, local or s3/,
  );
  assert.throws(
    () => loadMediaDeliveryStorageConfig({...s3, MEDIA_S3_ENDPOINT: 'http://storage.test'}),
    /HTTPS origin/,
  );
  assert.throws(
    () => loadMediaDeliveryStorageConfig({...s3, MEDIA_DELIVERY_STORAGE_TIMEOUT_MS: '0'}),
    /positive safe integer/,
  );
});

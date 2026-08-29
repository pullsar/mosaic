import assert from 'node:assert/strict';
import {Readable} from 'node:stream';
import {test} from 'node:test';
import {buildApp} from '../src/app.js';
import {
  MediaDeliveryService,
  type MediaDeliveryObjectReader,
  type MediaPublicationResolver,
} from '../src/media_delivery.js';
import {registerMediaDeliveryRoutes} from '../src/media_delivery_routes.js';
import type {MediaDeliverySelection} from '../src/media_publication.js';
import type {MosaicRepository} from '../src/repository.js';

const origin = 'https://app.example.test';
const bytes = Buffer.from('0123456789');

const repository: MosaicRepository = {
  async ping() {},
  async createActor() {},
  async registerActorAccess() {
    return 'created';
  },
  async verifyActorAccess() {
    return false;
  },
  async bindActorToUser() {},
  async getPlayRevision() {
    return null;
  },
  async insertEvent() {
    return 'inserted';
  },
};

const selection: MediaDeliverySelection = {
  assetId: 'asset_cors',
  kind: 'audio',
  sourceSha256: 'a'.repeat(64),
  primary: {
    derivativeKey: 'mdv1_audio',
    purpose: 'audio',
    storageKey: 'media/asset_cors/derivatives/mdv1_audio/attempts/claim-a.m4a',
    mimeType: 'audio/mp4',
    sizeBytes: bytes.length,
    width: null,
    height: null,
    durationMs: 1_000,
    container: 'mp4',
    videoCodec: null,
    videoProfile: null,
    audioCodec: 'aac',
    colorSpace: null,
    dynamicRange: null,
  },
  poster: null,
  captions: null,
};

const publication: MediaPublicationResolver = {
  async resolveReady() {
    return selection;
  },
};

const reader: MediaDeliveryObjectReader = {
  async inspect() {
    return {sizeBytes: bytes.length, mimeType: 'audio/mp4'};
  },
  async openRange(_storageKey, range) {
    return Readable.from(bytes.subarray(range.start, range.endInclusive + 1));
  },
};

test('media delivery preflight permits HEAD/Range only for an allowlisted exact origin', async () => {
  const app = buildApp({repository, allowedWebOrigins: [origin], logLevel: 'silent'});
  registerMediaDeliveryRoutes(app, new MediaDeliveryService(publication, reader));

  const preflight = await app.inject({
    method: 'OPTIONS',
    url: '/v1/assets/asset_cors/content/primary',
    headers: {
      origin,
      'access-control-request-method': 'GET',
      'access-control-request-headers': 'range',
    },
  });
  assert.equal(preflight.statusCode, 204);
  assert.equal(preflight.headers['access-control-allow-origin'], origin);
  assert.equal(
    preflight.headers['access-control-allow-methods'],
    'GET,HEAD,POST,PUT,OPTIONS',
  );
  assert.equal(
    preflight.headers['access-control-allow-headers'],
    'content-type,authorization,range',
  );
  assert.equal(
    preflight.headers['access-control-expose-headers'],
    'accept-ranges,content-length,content-range',
  );
  assert.equal(preflight.headers['access-control-allow-credentials'], undefined);

  const denied = await app.inject({
    method: 'OPTIONS',
    url: '/v1/assets/asset_cors/content/primary',
    headers: {origin: 'https://evil.example.test'},
  });
  assert.equal(denied.statusCode, 403);
  assert.equal(denied.headers['access-control-allow-origin'], undefined);

  await app.close();
});

test('range responses expose only the metadata required by browser media clients', async () => {
  const app = buildApp({repository, allowedWebOrigins: [origin], logLevel: 'silent'});
  registerMediaDeliveryRoutes(app, new MediaDeliveryService(publication, reader));

  const response = await app.inject({
    method: 'GET',
    url: '/v1/assets/asset_cors/content/primary',
    headers: {origin, range: 'bytes=2-5'},
  });
  assert.equal(response.statusCode, 206);
  assert.equal(response.headers['access-control-allow-origin'], origin);
  assert.equal(
    response.headers['access-control-expose-headers'],
    'accept-ranges,content-length,content-range',
  );
  assert.equal(response.headers['content-range'], 'bytes 2-5/10');
  assert.equal(response.body, '2345');

  await app.close();
});

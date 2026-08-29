import assert from 'node:assert/strict';
import {Readable} from 'node:stream';
import {test} from 'node:test';
import Fastify from 'fastify';
import {
  MediaDeliveryService,
  type MediaByteRange,
  type MediaDeliveryObjectReader,
  type MediaPublicationResolver,
} from '../src/media_delivery.js';
import {registerMediaDeliveryRoutes} from '../src/media_delivery_routes.js';
import type {MediaDeliverySelection} from '../src/media_publication.js';

const bytes = Buffer.from('0123456789');
const selection: MediaDeliverySelection = {
  assetId: 'asset_route',
  kind: 'audio',
  sourceSha256: 'a'.repeat(64),
  primary: {
    derivativeKey: 'mdv1_audio',
    purpose: 'audio',
    storageKey: 'media/asset_route/derivatives/mdv1_audio/attempts/claim-a.m4a',
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
  async resolveReady(assetId) {
    assert.equal(assetId, 'asset_route');
    return selection;
  },
};

const reader: MediaDeliveryObjectReader = {
  async inspect() {
    return {sizeBytes: bytes.length, mimeType: 'audio/mp4'};
  },
  async openRange(_storageKey: string, range: MediaByteRange) {
    return Readable.from(bytes.subarray(range.start, range.endInclusive + 1));
  },
};

test('delivery routes expose descriptor, HEAD and single-range GET without storage keys', async () => {
  const app = Fastify({logger: false});
  registerMediaDeliveryRoutes(app, new MediaDeliveryService(publication, reader));

  const descriptor = await app.inject({method: 'GET', url: '/v1/assets/asset_route'});
  assert.equal(descriptor.statusCode, 200);
  assert.equal(descriptor.json().primary.url, '/v1/assets/asset_route/content/primary');
  assert.equal(descriptor.body.includes('storageKey'), false);

  const head = await app.inject({method: 'HEAD', url: '/v1/assets/asset_route/content/primary'});
  assert.equal(head.statusCode, 200);
  assert.equal(head.headers['accept-ranges'], 'bytes');
  assert.equal(head.headers['content-length'], String(bytes.length));
  assert.equal(head.body, '');

  const partial = await app.inject({
    method: 'GET',
    url: '/v1/assets/asset_route/content/primary',
    headers: {range: 'bytes=2-5'},
  });
  assert.equal(partial.statusCode, 206);
  assert.equal(partial.headers['content-range'], 'bytes 2-5/10');
  assert.equal(partial.headers['content-length'], '4');
  assert.equal(partial.headers['content-type'], 'audio/mp4');
  assert.equal(partial.body, '2345');

  const invalid = await app.inject({
    method: 'GET',
    url: '/v1/assets/asset_route/content/primary',
    headers: {range: 'bytes=99-'},
  });
  assert.equal(invalid.statusCode, 416);
  assert.equal(invalid.headers['content-range'], 'bytes */10');

  await app.close();
});

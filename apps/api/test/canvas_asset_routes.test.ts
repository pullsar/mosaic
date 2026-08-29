import assert from 'node:assert/strict';
import {test} from 'node:test';
import Fastify from 'fastify';
import {
  CanvasAssetIntegrityError,
  normalizeCanvasAssetDocument,
  type CanvasAssetResolver,
} from '../src/canvas_asset.js';
import {registerCanvasAssetRoutes} from '../src/canvas_asset_routes.js';

class FakeCanvasResolver implements CanvasAssetResolver {
  calls: string[] = [];
  value = normalizeCanvasAssetDocument({
    schemaVersion: 1,
    id: 'puzzle_match_01',
    semanticLabel: 'Matchstick puzzle',
    elements: [{type: 'label', x: 0.5, y: 0.5, text: '6 + 4 = 4'}],
  });
  error: Error | null = null;

  async resolveReady(assetId: string) {
    this.calls.push(assetId);
    if (this.error !== null) throw this.error;
    return assetId === this.value.id ? this.value : null;
  }
}

test('canvas route returns only bounded schema-v1 document with no database metadata', async () => {
  const resolver = new FakeCanvasResolver();
  const app = Fastify({logger: false});
  registerCanvasAssetRoutes(app, resolver);

  const response = await app.inject({
    method: 'GET',
    url: '/v1/canvas-assets/puzzle_match_01',
  });
  assert.equal(response.statusCode, 200);
  assert.equal(response.headers['cache-control'], 'no-store');
  assert.deepEqual(response.json(), JSON.parse(JSON.stringify(resolver.value)));
  assert.equal('contentSha256' in response.json(), false);
  assert.deepEqual(resolver.calls, ['puzzle_match_01']);

  await app.close();
});

test('canvas route fails closed for missing, malformed and integrity-failed assets', async () => {
  const resolver = new FakeCanvasResolver();
  const app = Fastify({logger: false});
  registerCanvasAssetRoutes(app, resolver);

  const missing = await app.inject({
    method: 'GET',
    url: '/v1/canvas-assets/unknown',
  });
  assert.equal(missing.statusCode, 404);

  const invalid = await app.inject({
    method: 'GET',
    url: `/v1/canvas-assets/${encodeURIComponent('\u0001')}`,
  });
  assert.equal(invalid.statusCode, 400);

  resolver.error = new CanvasAssetIntegrityError('tampered');
  const broken = await app.inject({
    method: 'GET',
    url: '/v1/canvas-assets/puzzle_match_01',
  });
  assert.equal(broken.statusCode, 503);
  assert.deepEqual(broken.json(), {error: 'canvas_asset_unavailable'});

  await app.close();
});

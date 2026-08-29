import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {test} from 'node:test';
import type {Pool} from 'pg';
import {normalizeCanvasAssetDocument} from '../src/canvas_asset.js';
import {
  extractFeedAssetRequirements,
  PostgresFeedAssetReadinessResolver,
} from '../src/feed_asset_readiness.js';
import {canonicalJson} from '../src/media.js';
import type {FeedCandidate} from '../src/consumer_ranking.js';

const sourceSha256 = 'a'.repeat(64);

function candidate(
  playId: string,
  type: string,
  assetId?: string,
): FeedCandidate {
  return {
    playId,
    revisionId: `rev_${playId}`,
    format: 'choose',
    topicIds: [],
    learningTopicIds: [],
    qualityPrior: 0.5,
    curatedOrder: 1,
    document: {
      schemaVersion: 1,
      id: playId,
      revisionId: `rev_${playId}`,
      format: 'choose',
      states: {
        start: {
          presentation: {
            layers: [
              type === 'text'
                ? {type: 'text', value: 'Prompt'}
                : {type, assetId},
            ],
          },
          input: {type: 'tap'},
          validation: {type: 'none'},
          transition: {default: '$end'},
        },
      },
    },
  };
}

test('feed asset extraction covers every external presentation kind and rejects ambiguous identity reuse', () => {
  const document = {
    states: {
      first: {
        presentation: {layers: [
          {type: 'image', assetId: ' image_b '},
          {type: 'canvas', assetId: 'canvas_a'},
        ]},
      },
      second: {
        presentation: {layers: [
          {type: 'video_clip', assetId: 'video_c'},
          {type: 'audio', assetId: 'audio_d'},
          {type: 'text', value: 'Done'},
        ]},
      },
    },
  };
  assert.deepEqual(extractFeedAssetRequirements(document), [
    {assetId: 'audio_d', kind: 'audio'},
    {assetId: 'canvas_a', kind: 'canvas'},
    {assetId: 'image_b', kind: 'image'},
    {assetId: 'video_c', kind: 'video'},
  ]);

  assert.equal(
    extractFeedAssetRequirements({
      states: {
        one: {presentation: {layers: [{type: 'image', assetId: 'same'}]}},
        two: {presentation: {layers: [{type: 'audio', assetId: 'same'}]}},
      },
    }),
    null,
  );
  assert.equal(
    extractFeedAssetRequirements({
      states: {one: {presentation: {layers: [{type: 'image'}]}}},
    }),
    null,
  );
});

test('PostgreSQL feed readiness batches media and canvas checks and filters unavailable or kind-mismatched supply', async () => {
  const canvasDocument = normalizeCanvasAssetDocument({
    schemaVersion: 1,
    id: 'canvas_ready',
    elements: [{type: 'label', x: 0.5, y: 0.5, text: 'Ready'}],
  });
  const canvasDigest = createHash('sha256')
    .update(canonicalJson(canvasDocument), 'utf8')
    .digest('hex');
  const queries: string[] = [];
  const pool = {
    async query(sql: string): Promise<{rows: unknown[]}> {
      queries.push(sql);
      if (sql.includes('from media_assets a')) {
        return {
          rows: [
            {
              asset_id: 'image_ready',
              asset_kind: 'image',
              asset_state: 'ready',
              asset_source_sha256: sourceSha256,
              derivative_key: 'mdv1_image',
              purpose: 'image',
              derivative_state: 'ready',
              derivative_source_sha256: sourceSha256,
              plan_version: 1,
              processor: 'ffmpeg-image-normalize-v1',
              storage_key: 'media/image_ready/derivatives/mdv1_image/attempts/claim.jpg',
              mime_type: 'image/jpeg',
              size_bytes: '1000',
              width: 1280,
              height: 720,
              duration_ms: null,
              container: null,
              video_codec: null,
              video_profile: null,
              audio_codec: null,
              color_space: null,
              dynamic_range: 'sdr',
            },
            {
              asset_id: 'video_wrong_kind',
              asset_kind: 'image',
              asset_state: 'ready',
              asset_source_sha256: sourceSha256,
              derivative_key: 'mdv1_wrong',
              purpose: 'image',
              derivative_state: 'ready',
              derivative_source_sha256: sourceSha256,
              plan_version: 1,
              processor: 'ffmpeg-image-normalize-v1',
              storage_key: 'media/video_wrong_kind/derivatives/mdv1_wrong/attempts/claim.jpg',
              mime_type: 'image/jpeg',
              size_bytes: '1000',
              width: 1280,
              height: 720,
              duration_ms: null,
              container: null,
              video_codec: null,
              video_profile: null,
              audio_codec: null,
              color_space: null,
              dynamic_range: 'sdr',
            },
          ],
        };
      }
      if (sql.includes('from canvas_assets')) {
        return {
          rows: [{
            id: 'canvas_ready',
            schema_version: 1,
            state: 'ready',
            content_sha256: canvasDigest,
            document: canvasDocument,
          }],
        };
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  } as unknown as Pool;

  const resolver = new PostgresFeedAssetReadinessResolver(pool, {
    binaryDeliveryEnabled: true,
  });
  const result = await resolver.filterDeliverable([
    candidate('text_only', 'text'),
    candidate('image_ok', 'image', 'image_ready'),
    candidate('image_missing', 'image', 'image_missing'),
    candidate('canvas_ok', 'canvas', 'canvas_ready'),
    candidate('video_kind_mismatch', 'video_clip', 'video_wrong_kind'),
  ]);

  assert.deepEqual(result.map((item) => item.playId), [
    'text_only',
    'image_ok',
    'canvas_ok',
  ]);
  assert.equal(queries.filter((sql) => sql.includes('from media_assets a')).length, 1);
  assert.equal(queries.filter((sql) => sql.includes('from canvas_assets')).length, 1);
});

test('binary readiness is fail-closed when the delivery transport is disabled', async () => {
  let mediaQueries = 0;
  const pool = {
    async query(sql: string): Promise<{rows: unknown[]}> {
      if (sql.includes('from media_assets a')) mediaQueries += 1;
      return {rows: []};
    },
  } as unknown as Pool;
  const resolver = new PostgresFeedAssetReadinessResolver(pool, {
    binaryDeliveryEnabled: false,
  });

  const result = await resolver.filterDeliverable([
    candidate('text_only', 'text'),
    candidate('image', 'image', 'image_ready'),
  ]);
  assert.deepEqual(result.map((item) => item.playId), ['text_only']);
  assert.equal(mediaQueries, 0);
});

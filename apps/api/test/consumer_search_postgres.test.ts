import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {buildApp} from '../src/app.js';
import {PostgresConsumerRepository} from '../src/consumer_repository.js';
import {PostgresConsumerSearchRepository} from '../src/consumer_search_repository.js';
import {PostgresRepository} from '../src/repository.js';

const databaseUrl = process.env.DATABASE_URL;
const actorToken = 'S'.repeat(43);
const authorization = {authorization: `Bearer ${actorToken}`};
const capabilities = {
  schemaVersions: [1],
  presentationTypes: ['text'],
  inputTypes: ['tap'],
  validatorTypes: ['none'],
  platformFlags: [],
};

async function runMigration(): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', 'src/db/migrate.ts', 'up'], {
      cwd: new URL('../', import.meta.url),
      env: process.env,
      stdio: 'inherit',
    });
    child.on('exit', (code) =>
      code === 0 ? resolve() : reject(new Error(`migration up exited ${code}`)),
    );
    child.on('error', reject);
  });
}

test(
  'consumer search is stable, private, prefix-indexed and distribution-safe',
  {skip: !databaseUrl},
  async () => {
    await runMigration();
    const pool = new Pool({connectionString: databaseUrl});
    const core = new PostgresRepository(pool);
    const consumer = new PostgresConsumerRepository(pool);
    const search = new PostgresConsumerSearchRepository(pool);
    const app = buildApp({
      repository: core,
      consumerRepository: consumer,
      consumerSearchRepository: search,
      logLevel: 'silent',
    });
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const actorId = `actor_search_${suffix}`;
    const travel = `travel_${suffix}`;
    const travelPlay = `travel_play_${suffix}`;
    const suspendedPlay = `travel_suspended_${suffix}`;
    const incompatiblePlay = `travel_map_${suffix}`;
    const revisionId = `rev_${suffix}`;

    try {
      const register = await app.inject({
        method: 'POST',
        url: '/v1/actors',
        headers: authorization,
        payload: {actorId},
      });
      assert.equal(register.statusCode, 201);

      await pool.query('insert into topics (id, label) values ($1, $2)', [travel, `Travel ${suffix}`]);
      for (const [playId, presentation, state] of [
        [travelPlay, 'text', 'eligible'],
        [suspendedPlay, 'text', 'suspended'],
        [incompatiblePlay, 'map', 'eligible'],
      ] as const) {
        await pool.query('insert into plays (id) values ($1)', [playId]);
        await pool.query(
          `insert into play_revisions (play_id, revision_id, schema_version, document)
           values ($1, $2, 1, $3::jsonb)`,
          [playId, revisionId, JSON.stringify(playDocument(playId, revisionId, presentation))],
        );
        await pool.query(
          `insert into play_revision_topics (play_id, revision_id, topic_id, role)
           values ($1, $2, $3, 'interest')`,
          [playId, revisionId, travel],
        );
        await pool.query(
          `insert into feed_catalog_entries (play_id, revision_id, state, quality_prior, curated_order)
           values ($1, $2, $3, 0.8, 10)`,
          [playId, revisionId, state],
        );
      }

      const unauthenticated = await app.inject({
        method: 'POST',
        url: '/v1/search',
        payload: {actorId, query: travel.slice(0, 6), intent: 'interest', capabilities},
      });
      assert.equal(unauthenticated.statusCode, 401);

      const first = await app.inject({
        method: 'POST',
        url: '/v1/search',
        headers: authorization,
        payload: {
          actorId,
          query: `  ${travel.slice(0, 8).toUpperCase()}  `,
          intent: 'interest',
          capabilities,
          limit: 1,
        },
      });
      assert.equal(first.statusCode, 200);
      const firstBody = first.json() as {
        requestId: string;
        intent: string;
        queryHash: string;
        resultCount: number;
        items: Array<Record<string, unknown>>;
        nextCursor: string | null;
      };
      assert.equal(firstBody.intent, 'interest');
      assert.equal(firstBody.queryHash.length, 64);
      assert.equal(firstBody.queryHash.includes(travel), false);
      assert.ok(firstBody.resultCount >= 2);
      assert.equal(firstBody.items.length, 1);
      assert.ok(firstBody.nextCursor);

      const stored = await pool.query<{
        query_sha256: string;
        result_count: number;
      }>(
        'select query_sha256, result_count from consumer_search_decisions where request_id = $1',
        [firstBody.requestId],
      );
      assert.equal(stored.rows[0]?.query_sha256, firstBody.queryHash);
      assert.equal(stored.rows[0]?.result_count, firstBody.resultCount);
      const columns = await pool.query<{column_name: string}>(
        `select column_name
           from information_schema.columns
          where table_schema = 'public' and table_name = 'consumer_search_decisions'`,
      );
      assert.equal(columns.rows.some((row) => row.column_name === 'query'), false);

      const latePlay = `travel_late_${suffix}`;
      await pool.query('insert into plays (id) values ($1)', [latePlay]);
      await pool.query(
        `insert into play_revisions (play_id, revision_id, schema_version, document)
         values ($1, $2, 1, $3::jsonb)`,
        [latePlay, revisionId, JSON.stringify(playDocument(latePlay, revisionId, 'text'))],
      );
      await pool.query(
        `insert into play_revision_topics (play_id, revision_id, topic_id, role)
         values ($1, $2, $3, 'interest')`,
        [latePlay, revisionId, travel],
      );
      await pool.query(
        `insert into feed_catalog_entries (play_id, revision_id, quality_prior, curated_order)
         values ($1, $2, 1, 1)`,
        [latePlay, revisionId],
      );

      const second = await app.inject({
        method: 'POST',
        url: '/v1/search',
        headers: authorization,
        payload: {
          actorId,
          cursor: firstBody.nextCursor,
          capabilities,
          limit: 20,
        },
      });
      assert.equal(second.statusCode, 200);
      const secondBody = second.json() as {
        resultCount: number;
        items: Array<{kind: string; playId?: string}>;
      };
      assert.equal(secondBody.resultCount, firstBody.resultCount);
      assert.equal(secondBody.items.some((item) => item.playId === latePlay), false);
      assert.equal(secondBody.items.some((item) => item.playId === suspendedPlay), false);
      assert.equal(secondBody.items.some((item) => item.playId === incompatiblePlay), false);

      const normalizedQuery = travel.slice(0, 8).toLowerCase();
      assert.equal(
        firstBody.queryHash,
        createHash('sha256').update(normalizedQuery, 'utf8').digest('hex'),
      );

      await pool.query('set enable_seqscan = off');
      const explain = await pool.query<{['QUERY PLAN']: string}>(
        `explain (costs off)
         select id from topics
          where lower(label) like $1
          order by label, id
          limit 10`,
        [`${travel.slice(0, 6).toLowerCase()}%`],
      );
      assert.equal(
        explain.rows.some((row) => row['QUERY PLAN'].includes('topics_search_label_prefix_idx')),
        true,
      );
    } finally {
      await app.close();
      await pool.end();
    }
  },
);

function playDocument(playId: string, revisionId: string, presentationType: string) {
  return {
    schemaVersion: 1,
    id: playId,
    revisionId,
    format: 'choose',
    states: {
      start: {
        presentation: {layers: [{type: presentationType}]},
        input: {type: 'tap'},
        validation: {type: 'none'},
        transition: {default: '$end'},
      },
    },
  };
}

import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {
  applyProductionCatalog,
  verifyProductionCatalog,
} from '../src/production_catalog.js';

const databaseUrl = process.env.DATABASE_URL;

async function runMigration(): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(
      process.execPath,
      ['--import', 'tsx', 'src/db/migrate.ts', 'up'],
      {
        cwd: new URL('../', import.meta.url),
        env: process.env,
        stdio: 'inherit',
      },
    );
    child.on('exit', (code) =>
      code === 0
        ? resolve()
        : reject(new Error(`migration up exited ${code}`)),
    );
    child.on('error', reject);
  });
}

test(
  'production catalog is idempotent, complete, and preserves unrelated content',
  {skip: !databaseUrl},
  async () => {
    await runMigration();
    const pool = new Pool({connectionString: databaseUrl});
    const suffix = `${Date.now().toString(36)}_${Math.random()
      .toString(36)
      .slice(2, 8)}`;
    const unrelated = `creator_owned_${suffix}`;

    try {
      await pool.query('insert into plays (id) values ($1)', [unrelated]);

      const first = await applyProductionCatalog(pool);
      const beforeRetry = await pool.query<{
        play_id: string;
        revision_id: string;
        state: string;
        document: unknown;
      }>(
        `select catalog.play_id, catalog.revision_id, catalog.state, revision.document
           from feed_catalog_entries catalog
           join play_revisions revision using (play_id, revision_id)
          where catalog.play_id like 'mixli_starter_%'
          order by catalog.play_id, catalog.revision_id`,
      );
      const second = await applyProductionCatalog(pool);
      const afterRetry = await pool.query<{
        play_id: string;
        revision_id: string;
        state: string;
        document: unknown;
      }>(
        `select catalog.play_id, catalog.revision_id, catalog.state, revision.document
           from feed_catalog_entries catalog
           join play_revisions revision using (play_id, revision_id)
          where catalog.play_id like 'mixli_starter_%'
          order by catalog.play_id, catalog.revision_id`,
      );

      assert.deepEqual(first, {eligiblePlays: 6, canvasAssets: 12});
      assert.deepEqual(second, first);
      assert.deepEqual(afterRetry.rows, beforeRetry.rows);
      assert.deepEqual(await verifyProductionCatalog(pool), first);

      const releaseStates = await pool.query<{
        revision_id: string;
        state: string;
      }>(
        `select revision_id, state
           from feed_catalog_entries
          where play_id like 'mixli_starter_%'`,
      );
      assert.equal(
        releaseStates.rows.filter(
          (row) => row.revision_id === 'rev_2' && row.state === 'eligible',
        ).length,
        6,
      );
      assert.equal(
        releaseStates.rows.filter(
          (row) => row.revision_id === 'rev_1' && row.state === 'suspended',
        ).length,
        6,
      );

      const eligible = await pool.query<{
        document: {
          assets?: string[];
          entryState?: string;
          states?: Record<
            string,
            {
              input?: {type?: string};
              presentation?: {
                layers?: Array<{type?: string; assetId?: string}>;
              };
            }
          >;
          topics?: string[];
        };
      }>(
        `select revision.document
           from feed_catalog_entries catalog
           join play_revisions revision using (play_id, revision_id)
          where catalog.play_id like 'mixli_starter_%'
            and catalog.state = 'eligible'
          order by catalog.curated_order`,
      );
      assert.equal(eligible.rows.length, 6);
      assert.equal(
        eligible.rows.filter((row) => {
          const primaryAsset = row.document.assets?.[0];
          return row.document.states?.reveal?.presentation?.layers?.some(
            (layer) =>
              layer.type === 'canvas' && layer.assetId === primaryAsset,
          );
        }).length,
        6,
      );
      const interactionTypes = new Set(
        eligible.rows.map((row) => {
          const entryState = row.document.entryState;
          return entryState === undefined
            ? undefined
            : row.document.states?.[entryState]?.input?.type;
        }),
      );
      assert.equal(interactionTypes.has('single_choice'), true);
      assert.equal(interactionTypes.has('drag'), true);
      for (let index = 1; index < eligible.rows.length; index += 1) {
        assert.notEqual(
          eligible.rows[index]?.document.topics?.[0],
          eligible.rows[index - 1]?.document.topics?.[0],
        );
      }

      const eligibleAssetIds = eligible.rows.flatMap(
        (row) => row.document.assets ?? [],
      );
      const eligibleCanvases = await pool.query<{
        document: {palette?: Record<string, string>};
      }>(
        'select document from canvas_assets where id = any($1::text[])',
        [eligibleAssetIds],
      );
      assert.equal(eligibleCanvases.rows.length, 6);
      assert.ok(
        new Set(
          eligibleCanvases.rows.map((row) => JSON.stringify(row.document.palette)),
        ).size >= 3,
      );

      const playSnapshot = await pool.query<{document: unknown}>(
        `select document from play_revisions
          where play_id = 'mixli_starter_quick_logic' and revision_id = 'rev_2'`,
      );
      try {
        await pool.query(
          `update play_revisions
              set document = document - 'states'
            where play_id = 'mixli_starter_quick_logic' and revision_id = 'rev_2'`,
        );
        await assert.rejects(
          verifyProductionCatalog(pool),
          /differs from release content/,
        );
      } finally {
        await pool.query(
          `update play_revisions set document = $1::jsonb
            where play_id = 'mixli_starter_quick_logic' and revision_id = 'rev_2'`,
          [JSON.stringify(playSnapshot.rows[0]?.document)],
        );
      }

      const canvasSnapshot = await pool.query<{content_sha256: string}>(
        `select content_sha256 from canvas_assets
          where id = 'mixli_canvas_quick_logic_v2'`,
      );
      try {
        await pool.query(
          `update canvas_assets
              set content_sha256 = repeat('0', 64)
            where id = 'mixli_canvas_quick_logic_v2'`,
        );
        await assert.rejects(verifyProductionCatalog(pool), /content hash changed/);
      } finally {
        await pool.query(
          `update canvas_assets set content_sha256 = $1
            where id = 'mixli_canvas_quick_logic_v2'`,
          [canvasSnapshot.rows[0]?.content_sha256],
        );
      }

      try {
        await pool.query(
          `delete from play_revision_topics
            where play_id = 'mixli_starter_city_instinct'
              and revision_id = 'rev_2'
              and topic_id = 'travel'`,
        );
        await assert.rejects(
          verifyProductionCatalog(pool),
          /topic links differ from release content/,
        );
      } finally {
        await applyProductionCatalog(pool);
      }

      try {
        await pool.query(
          `update play_revision_topics
              set role = 'learning'
            where play_id = 'mixli_starter_quick_logic'
              and revision_id = 'rev_2'
              and topic_id = 'logic'`,
        );
        await assert.rejects(
          verifyProductionCatalog(pool),
          /topic links differ from release content/,
        );
      } finally {
        await applyProductionCatalog(pool);
      }

      const unrelatedCount = await pool.query<{count: number}>(
        'select count(*)::int as count from plays where id = $1',
        [unrelated],
      );
      assert.equal(unrelatedCount.rows[0]?.count, 1);

      const documents = await pool.query<{
        document: {assets?: string[]};
      }>(
        `select revision.document
           from feed_catalog_entries catalog
           join play_revisions revision using (play_id, revision_id)
          where catalog.play_id like 'mixli_starter_%'
            and catalog.state = 'eligible'`,
      );
      const assetIds = new Set(
        documents.rows.flatMap((row) => row.document.assets ?? []),
      );
      const registered = await pool.query<{id: string}>(
        'select id from canvas_assets where id = any($1::text[])',
        [[...assetIds]],
      );
      assert.deepEqual(
        new Set(registered.rows.map((row) => row.id)),
        assetIds,
      );
    } finally {
      await pool.query('delete from plays where id = $1', [unrelated]);
      await pool.end();
    }
  },
);

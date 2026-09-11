import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {
  applyProductionCatalog,
  productionCatalogIntegrityFixture,
  productionStarterCount,
  verifyProductionCatalog,
} from '../src/production_catalog.js';
import {echoArchitectAudioAssets} from '../src/curated_audio.js';

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

      assert.deepEqual(first, {
        eligiblePlays: productionStarterCount,
        canvasAssets: productionCatalogIntegrityFixture.canvasAssets.length,
      });
      assert.deepEqual(second, first);
      assert.deepEqual(afterRetry.rows, beforeRetry.rows);
      assert.deepEqual(await verifyProductionCatalog(pool), first);

      const releaseStates = await pool.query<{
        play_id: string;
        revision_id: string;
        state: string;
      }>(
        `select play_id, revision_id, state
           from feed_catalog_entries
          where play_id like 'mixli_starter_%'`,
      );
      assert.deepEqual(
        releaseStates.rows.filter((row) => row.state === 'eligible')
          .map((row) => `${row.play_id}/${row.revision_id}`).sort(),
        productionCatalogIntegrityFixture.plays
          .map((play) => `${play.id}/${play.revisionId}`).sort(),
      );
      assert.equal(
        releaseStates.rows.filter(
          (row) =>
            (row.revision_id === 'rev_1' || row.revision_id === 'rev_2') &&
            row.state === 'suspended',
        ).length,
        18,
      );
      assert.equal(releaseStates.rows.filter(
        (row) => row.revision_id === 'rev_3' && row.state === 'suspended',
      ).length, 3);
      const preservedPattern = await pool.query<{document: {states: {choice: {presentation: {layers: Array<{value?: string}>}}}}}>(
        `select document from play_revisions where play_id = 'mixli_starter_finish_pattern' and revision_id = 'rev_3'`,
      );
      assert.ok(preservedPattern.rows[0]!.document.states.choice.presentation.layers
        .some((layer) => layer.value === 'Repeat the pattern.'));

      const eligible = await pool.query<{
        document: {
          assets?: string[];
          entryState?: string;
          states?: Record<
            string,
            {
              input?: {type?: string};
              presentation?: {
                layers?: Array<{type?: string; assetId?: string; scene?: unknown}>;
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
      assert.equal(eligible.rows.length, productionStarterCount);
      assert.equal(
        eligible.rows.filter((row) => {
          const playAssets = new Set(row.document.assets ?? []);
          return Object.values(row.document.states ?? {}).some(
            (state) => state.presentation?.layers?.some(
              (layer) =>
                (layer.type === 'canvas' &&
                  layer.assetId !== undefined &&
                  playAssets.has(layer.assetId)) ||
                (layer.type === 'audio' &&
                  layer.assetId !== undefined &&
                  playAssets.has(layer.assetId)) ||
                (layer.type === 'scene' && layer.scene !== undefined),
            ),
          );
        }).length,
        productionStarterCount,
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
      assert.equal(interactionTypes.has('piece_move'), true);
      assert.equal(interactionTypes.has('timed_cue'), true);
      for (const row of eligible.rows) {
        const topics = row.document.topics ?? [];
        assert.ok(topics.length > 0);
        assert.equal(new Set(topics).size, topics.length);
      }

      const eligibleCanvasAssetIds = eligible.rows.flatMap((row) => {
        const assets = new Set(row.document.assets ?? []);
        return Object.values(row.document.states ?? {}).flatMap((state) =>
          state.presentation?.layers?.flatMap((layer) =>
            layer.type === 'canvas' &&
                    layer.assetId !== undefined &&
                    assets.has(layer.assetId)
                ? [layer.assetId]
                : [],
          ) ?? [],
        );
      });
      const eligibleCanvases = await pool.query<{
        document: {palette?: Record<string, string>};
      }>(
        'select document from canvas_assets where id = any($1::text[])',
        [eligibleCanvasAssetIds],
      );
      assert.equal(
        eligibleCanvases.rows.length,
        new Set(eligibleCanvasAssetIds).size,
      );
      assert.ok(
        new Set(
          eligibleCanvases.rows.map((row) => JSON.stringify(row.document.palette)),
        ).size >= 3,
      );

      const playSnapshot = await pool.query<{document: unknown}>(
        `select document from play_revisions
          where play_id = 'mixli_starter_quick_logic' and revision_id = 'rev_3'`,
      );
      try {
        await pool.query(
          `update play_revisions
              set document = document - 'states'
            where play_id = 'mixli_starter_quick_logic' and revision_id = 'rev_3'`,
        );
        await assert.rejects(
          verifyProductionCatalog(pool),
          /differs from release content/,
        );
      } finally {
        await pool.query(
          `update play_revisions set document = $1::jsonb
            where play_id = 'mixli_starter_quick_logic' and revision_id = 'rev_3'`,
          [JSON.stringify(playSnapshot.rows[0]?.document)],
        );
      }

      const canvasSnapshot = await pool.query<{content_sha256: string}>(
        `select content_sha256 from canvas_assets
          where id = 'mixli_canvas_quick_logic_v3'`,
      );
      try {
        await pool.query(
          `update canvas_assets
              set content_sha256 = repeat('0', 64)
            where id = 'mixli_canvas_quick_logic_v3'`,
        );
        await assert.rejects(verifyProductionCatalog(pool), /content hash changed/);
      } finally {
        await pool.query(
          `update canvas_assets set content_sha256 = $1
            where id = 'mixli_canvas_quick_logic_v3'`,
          [canvasSnapshot.rows[0]?.content_sha256],
        );
      }

      try {
        await pool.query(
          `delete from play_revision_topics
            where play_id = 'mixli_starter_city_instinct'
              and revision_id = 'rev_3'
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
              and revision_id = 'rev_3'
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
      const audioAssetIds = new Set(
        echoArchitectAudioAssets.map((asset) => asset.assetId),
      );
      const canvasAssetIds = new Set(
        [...assetIds].filter((assetId) => !audioAssetIds.has(assetId)),
      );
      const registered = await pool.query<{id: string}>(
        'select id from canvas_assets where id = any($1::text[])',
        [[...canvasAssetIds]],
      );
      assert.deepEqual(
        new Set(registered.rows.map((row) => row.id)),
        canvasAssetIds,
      );
    } finally {
      await pool.query('delete from plays where id = $1', [unrelated]);
      await pool.end();
    }
  },
);

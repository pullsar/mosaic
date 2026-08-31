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
      const second = await applyProductionCatalog(pool);

      assert.deepEqual(first, {eligiblePlays: 6, canvasAssets: 6});
      assert.deepEqual(second, first);
      assert.deepEqual(await verifyProductionCatalog(pool), first);

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

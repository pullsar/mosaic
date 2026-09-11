import assert from 'node:assert/strict';
import {mkdtemp, rm, stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {echoArchitectAudioAssets} from '../src/curated_audio.js';
import {importCuratedAudio} from '../src/curated_audio_import.js';

const databaseUrl = process.env.DATABASE_URL;

async function migrateUp(): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', 'src/db/migrate.ts', 'up'], {
      cwd: new URL('../', import.meta.url), env: process.env, stdio: 'inherit',
    });
    child.on('exit', (code) => code === 0 ? resolve() : reject(new Error(`migration up exited ${String(code)}`)));
    child.on('error', reject);
  });
}

test('curated Echo audio is source-immutable and queued for the ordinary worker', {skip: !databaseUrl}, async () => {
  await migrateUp();
  const pool = new Pool({connectionString: databaseUrl});
  const sourceRoot = await mkdtemp(join(tmpdir(), 'mixli-curated-audio-'));
  try {
    assert.deepEqual(await importCuratedAudio(pool, {
      storageMode: 'local', sourceRoot, objectRoot: sourceRoot,
    }), {registeredAssets: 6});
    assert.deepEqual(await importCuratedAudio(pool, {
      storageMode: 'local', sourceRoot, objectRoot: sourceRoot,
    }), {registeredAssets: 6});
    const rows = await pool.query<{
      id: string; state: string; source_sha256: string; derivative_count: string;
    }>(
      `select asset.id, asset.state, asset.source_sha256,
              count(derivative.derivative_key)::text as derivative_count
         from media_assets asset
         left join media_derivatives derivative on derivative.asset_id = asset.id
        where asset.id = any($1::text[])
        group by asset.id, asset.state, asset.source_sha256`,
      [echoArchitectAudioAssets.map((asset) => asset.assetId)],
    );
    assert.equal(rows.rows.length, 6);
    for (const asset of echoArchitectAudioAssets) {
      const row = rows.rows.find((candidate) => candidate.id === asset.assetId);
      assert.deepEqual(row, {
        id: asset.assetId,
        state: 'uploaded',
        source_sha256: asset.sourceSha256,
        derivative_count: '1',
      });
      const published = await stat(join(sourceRoot, 'curated', 'echo_architect', `${asset.sourceSha256}.m4a`));
      assert.ok(published.size > 0);
    }
  } finally {
    await pool.query(
      'delete from media_assets where id = any($1::text[])',
      [echoArchitectAudioAssets.map((asset) => asset.assetId)],
    );
    await rm(sourceRoot, {recursive: true, force: true});
    await pool.end();
  }
});

import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {buildApp} from '../src/app.js';
import {PostgresRepository} from '../src/repository.js';

const databaseUrl = process.env.DATABASE_URL;
const actorToken = 'A'.repeat(43);
const actorAuthorization = {authorization: `Bearer ${actorToken}`};

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
  'media playback diagnostics survive exact retry and persist only bounded compatibility dimensions',
  {skip: !databaseUrl},
  async () => {
    await runMigration();
    const pool = new Pool({connectionString: databaseUrl});
    const repository = new PostgresRepository(pool);
    const app = buildApp({repository, logLevel: 'silent'});
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const actorId = `actor_diag_${suffix}`;
    const eventId = `evt_diag_${suffix}`;
    const sessionId = `session_diag_${suffix}`;
    const playRevisionId = `rev_diag_${suffix}`;
    const payload = {
      assetId: 'asset_playback',
      phase: 'playbackError',
      sourceType: 'network',
      runtime: 'web',
      operatingSystem: 'ios',
      browser: 'safari',
      container: 'mp4',
      videoCodec: 'h264',
      videoProfile: 'main',
      audioCodec: 'aac',
      errorType: 'PlatformException',
    };

    try {
      const actor = await app.inject({
        method: 'POST',
        url: '/v1/actors',
        headers: actorAuthorization,
        payload: {actorId},
      });
      assert.equal(actor.statusCode, 201);

      const event = {
        eventId,
        event: 'media_playback',
        version: 1,
        occurredAt: '2026-08-29T06:00:00Z',
        actorId,
        sessionId,
        playRevisionId,
        payload,
      };
      const first = await app.inject({
        method: 'POST',
        url: '/v1/events',
        headers: actorAuthorization,
        payload: event,
      });
      const duplicate = await app.inject({
        method: 'POST',
        url: '/v1/events',
        headers: actorAuthorization,
        payload: event,
      });
      assert.equal(first.statusCode, 202);
      assert.equal(duplicate.statusCode, 200);

      const stored = await pool.query<{
        event_name: string;
        event_version: number;
        actor_id: string;
        session_id: string;
        play_revision_id: string | null;
        payload: Record<string, unknown>;
      }>(
        `select event_name, event_version, actor_id, session_id, play_revision_id, payload
           from interaction_events
          where event_id = $1`,
        [eventId],
      );
      assert.equal(stored.rowCount, 1);
      assert.equal(stored.rows[0]?.event_name, 'media_playback');
      assert.equal(stored.rows[0]?.event_version, 1);
      assert.equal(stored.rows[0]?.actor_id, actorId);
      assert.equal(stored.rows[0]?.session_id, sessionId);
      assert.equal(stored.rows[0]?.play_revision_id, playRevisionId);
      assert.deepEqual(stored.rows[0]?.payload, payload);
      assert.equal('userAgent' in (stored.rows[0]?.payload ?? {}), false);
      assert.equal('errorMessage' in (stored.rows[0]?.payload ?? {}), false);
    } finally {
      await app.close();
      await pool.end();
    }
  },
);

import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {PostgresRepository} from '../src/repository.js';

const databaseUrl = process.env.DATABASE_URL;

async function runMigration(): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', 'src/db/migrate.ts', 'up'], {
      cwd: new URL('../', import.meta.url),
      env: process.env,
      stdio: 'inherit',
    });
    child.on('exit', (code) => code === 0 ? resolve() : reject(new Error(`migration exited ${code}`)));
    child.on('error', reject);
  });
}

test('PostgreSQL foundation preserves identity and event idempotency', {skip: !databaseUrl}, async () => {
  await runMigration();
  const pool = new Pool({connectionString: databaseUrl});
  const repo = new PostgresRepository(pool);
  const suffix = Date.now().toString(36);
  const actorId = `actor_${suffix}`;
  const userId = `user_${suffix}`;
  const eventId = `evt_${suffix}`;

  try {
    await repo.createActor(actorId);
    await repo.bindActorToUser(actorId, userId);
    const merge = await pool.query<{user_id: string}>(
      'select user_id from actor_user_merges where actor_id = $1',
      [actorId],
    );
    assert.equal(merge.rows[0]?.user_id, userId);

    const event = {
      eventId,
      event: 'play_started',
      version: 1,
      occurredAt: new Date().toISOString(),
      actorId,
      sessionId: `session_${suffix}`,
      payload: {},
    };
    assert.equal(await repo.insertEvent(event), 'inserted');
    assert.equal(await repo.insertEvent(event), 'duplicate');

    const received = await pool.query<{received_at: Date}>(
      'select received_at from interaction_events where event_id = $1',
      [eventId],
    );
    assert.ok(received.rows[0]?.received_at instanceof Date);
  } finally {
    await pool.end();
  }
});

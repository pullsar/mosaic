import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
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
    child.on('exit', (code) =>
      code === 0 ? resolve() : reject(new Error(`migration up exited ${code}`)),
    );
    child.on('error', reject);
  });
}

function digest(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

test('PostgreSQL actor access is exact-retry safe and rejects legacy/conflicting claims', {skip: !databaseUrl}, async () => {
  await runMigration();
  const pool = new Pool({connectionString: databaseUrl});
  const repository = new PostgresRepository(pool);
  const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
  const actorId = `actor_access_${suffix}`;
  const legacyActorId = `legacy_actor_${suffix}`;
  const rawToken = 'A'.repeat(43);
  const otherToken = 'B'.repeat(43);
  const tokenDigest = digest(rawToken);

  try {
    assert.equal(await repository.registerActorAccess(actorId, tokenDigest), 'created');
    assert.equal(await repository.registerActorAccess(actorId, tokenDigest), 'existing');
    assert.equal(
      await repository.registerActorAccess(actorId, digest(otherToken)),
      'credential_conflict',
    );
    assert.equal(await repository.verifyActorAccess(actorId, tokenDigest), true);
    assert.equal(await repository.verifyActorAccess(actorId, digest(otherToken)), false);

    const stored = await pool.query<{credential_digest: string}>(
      'select credential_digest from actor_access_credentials where actor_id = $1',
      [actorId],
    );
    assert.equal(stored.rows[0]?.credential_digest, tokenDigest);
    assert.notEqual(stored.rows[0]?.credential_digest, rawToken);

    await repository.createActor(legacyActorId);
    assert.equal(
      await repository.registerActorAccess(legacyActorId, tokenDigest),
      'legacy_actor_requires_rotation',
    );
    const legacyCredential = await pool.query<{count: string}>(
      `select count(*)::text as count
         from actor_access_credentials
        where actor_id = $1`,
      [legacyActorId],
    );
    assert.equal(legacyCredential.rows[0]?.count, '0');
  } finally {
    await pool.end();
  }
});

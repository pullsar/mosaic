import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {
  ChallengeAuthorizationError,
  ChallengeIdempotencyConflictError,
  ChallengeSubmissionConflictError,
  ChallengeUnavailableError,
  PostgresPlayChallengeRepository,
} from '../src/play_challenge.js';

const databaseUrl = process.env.DATABASE_URL;

async function migrateUp(): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', 'src/db/migrate.ts', 'up'], {
      cwd: new URL('../', import.meta.url),
      env: process.env,
      stdio: 'inherit',
    });
    child.on('exit', (code) => code === 0 ? resolve() : reject(new Error(`migration up exited ${String(code)}`)));
    child.on('error', reject);
  });
}

test('challenges are fixed-round, idempotent, and reveal a creator result only after submission', {skip: !databaseUrl}, async () => {
  await migrateUp();
  const pool = new Pool({connectionString: databaseUrl});
  const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
  const creator = `creator_${suffix}`;
  const participant = `participant_${suffix}`;
  const playId = `play_challenge_${suffix}`;
  const revisionId = 'rev_1';
  let now = new Date('2026-09-11T12:00:00.000Z');
  let serial = 0;
  const repository = new PostgresPlayChallengeRepository(
    pool,
    () => now,
    () => `pc_${String(serial++).padStart(22, 'A')}`,
  );
  const creatorResult = {outcome: 'correct' as const, score: 1, wrongAnswerCount: 0};
  const participantResult = {outcome: 'incorrect' as const, score: 0, wrongAnswerCount: 1};

  try {
    await pool.query('insert into actors (id) values ($1), ($2)', [creator, participant]);
    await pool.query('insert into plays (id) values ($1)', [playId]);
    await pool.query(
      `insert into play_revisions (play_id, revision_id, schema_version, document)
       values ($1, $2, 1, $3::jsonb)`,
      [playId, revisionId, JSON.stringify({schemaVersion: 1, id: playId, revisionId})],
    );
    await pool.query(
      `insert into feed_catalog_entries (play_id, revision_id, state)
       values ($1, $2, 'eligible')`,
      [playId, revisionId],
    );

    const creation = {
      creatorActorId: creator,
      idempotencyKey: `create_${suffix}`,
      playId,
      revisionId,
      presentation: {themeId: 'night', variantId: 'quiet'} as const,
      mode: 'async_same_round' as const,
      scoringVersion: 'v1',
      revealPolicy: 'after_participant_submission' as const,
      creatorResult,
    };
    const challenge = await repository.create(creation);
    assert.match(challenge.inviteId, /^pc_[A-Za-z0-9_-]{22}$/);
    assert.equal(challenge.expiresAt, '2026-10-11T12:00:00.000Z');
    assert.deepEqual(await repository.create(creation), challenge);
    await assert.rejects(
      repository.create({...creation, scoringVersion: 'v2'}),
      ChallengeIdempotencyConflictError,
    );

    // Invite retrieval never contains the creator's result.
    assert.deepEqual(await repository.readInvite(challenge.inviteId), challenge);
    await assert.rejects(
      repository.readComparison(challenge.inviteId, participant),
      /No ranked submission exists/,
    );

    const compared = await repository.submit({
      inviteId: challenge.inviteId,
      actorId: participant,
      result: participantResult,
    });
    assert.deepEqual(compared.self, participantResult);
    assert.deepEqual(compared.creator, creatorResult);
    assert.deepEqual(await repository.submit({
      inviteId: challenge.inviteId,
      actorId: participant,
      result: participantResult,
    }), compared);
    await assert.rejects(
      repository.submit({
        inviteId: challenge.inviteId,
        actorId: participant,
        result: creatorResult,
      }),
      ChallengeSubmissionConflictError,
    );
    await assert.rejects(
      repository.submit({
        inviteId: challenge.inviteId,
        actorId: creator,
        result: creatorResult,
      }),
      ChallengeAuthorizationError,
    );

    await repository.revoke(challenge.inviteId, creator);
    await assert.rejects(repository.readInvite(challenge.inviteId), ChallengeUnavailableError);
    await assert.rejects(repository.revoke(challenge.inviteId, participant), ChallengeAuthorizationError);

    const expiryChallenge = await repository.create({...creation, idempotencyKey: `expiry_${suffix}`});
    now = new Date('2026-10-12T12:00:00.000Z');
    await assert.rejects(
      repository.submit({inviteId: expiryChallenge.inviteId, actorId: participant, result: participantResult}),
      ChallengeUnavailableError,
    );
  } finally {
    await pool.query('delete from actors where id = any($1::text[])', [[creator, participant]]).catch(() => undefined);
    await pool.query('delete from plays where id = $1', [playId]).catch(() => undefined);
    await pool.end();
  }
});

import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {PostgresConsumerRepository} from '../src/consumer_repository.js';
import type {RankedFeedCandidate} from '../src/consumer_ranking.js';

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

test(
  'feed decision persistence supports anonymous first-use and actor-scoped expiry cleanup',
  {skip: !databaseUrl},
  async () => {
    await runMigration();
    const pool = new Pool({connectionString: databaseUrl});
    const repository = new PostgresConsumerRepository(pool);
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const actorId = `fresh_actor_${suffix}`;
    const otherActorId = `other_actor_${suffix}`;
    const playId = `play_first_use_${suffix}`;
    const revisionId = `rev_${suffix}`;
    const expiredRequestId = `feed_expired_${suffix}`;
    const nextRequestId = `feed_next_${suffix}`;
    const otherRequestId = `feed_other_${suffix}`;
    const capabilityFingerprint = `cap_${suffix}`;

    const document = {
      schemaVersion: 1,
      id: playId,
      revisionId,
      format: 'choose',
      states: {},
    };
    const ranked: RankedFeedCandidate[] = [
      {
        playId,
        revisionId,
        format: 'choose',
        topicIds: [],
        learningTopicIds: [],
        qualityPrior: 0.5,
        curatedOrder: 1,
        document,
        rank: 1,
        sourceBucket: 'curated_fallback',
        score: 0,
        featureContributions: {},
      },
    ];

    try {
      await pool.query('insert into plays (id) values ($1)', [playId]);
      await pool.query(
        `insert into play_revisions (play_id, revision_id, schema_version, document)
         values ($1, $2, 1, $3::jsonb)`,
        [playId, revisionId, JSON.stringify(document)],
      );

      await repository.persistFeedDecision({
        requestId: expiredRequestId,
        actorId,
        rankingConfigVersion: 'm2-rules-v1',
        capabilityFingerprint,
        fallback: true,
        ranked,
      });
      const actor = await pool.query<{id: string}>('select id from actors where id = $1', [actorId]);
      assert.equal(actor.rows[0]?.id, actorId);

      await repository.persistFeedDecision({
        requestId: otherRequestId,
        actorId: otherActorId,
        rankingConfigVersion: 'm2-rules-v1',
        capabilityFingerprint,
        fallback: true,
        ranked,
      });

      await pool.query(
        `update feed_decisions
            set expires_at = now() - interval '1 second'
          where request_id in ($1, $2)`,
        [expiredRequestId, otherRequestId],
      );
      assert.equal(
        await repository.readFeedDecisionPage(
          expiredRequestId,
          actorId,
          capabilityFingerprint,
          0,
          10,
        ),
        null,
      );

      await repository.persistFeedDecision({
        requestId: nextRequestId,
        actorId,
        rankingConfigVersion: 'm2-rules-v1',
        capabilityFingerprint,
        fallback: true,
        ranked,
      });

      const expiredForActor = await pool.query<{count: string}>(
        'select count(*)::text as count from feed_decisions where request_id = $1',
        [expiredRequestId],
      );
      const expiredForOther = await pool.query<{count: string}>(
        'select count(*)::text as count from feed_decisions where request_id = $1',
        [otherRequestId],
      );
      assert.equal(expiredForActor.rows[0]?.count, '0');
      assert.equal(expiredForOther.rows[0]?.count, '1');
    } finally {
      await pool.end();
    }
  },
);

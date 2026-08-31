import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {ConsumerActionEventError} from '../src/consumer_actions.js';
import {PostgresRepository, type EventInput} from '../src/repository.js';

const databaseUrl = process.env.DATABASE_URL;

async function migrateUp(): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', 'src/db/migrate.ts', 'up'], {
      cwd: new URL('../', import.meta.url),
      env: process.env,
      stdio: 'inherit',
    });
    child.on('exit', (code) =>
      code === 0 ? resolve() : reject(new Error(`migration up exited ${String(code)}`)),
    );
    child.on('error', reject);
  });
}

test(
  'consumer actions use server receipt order and invalidate hard-negative feed decisions',
  {skip: !databaseUrl},
  async () => {
    await migrateUp();
    const pool = new Pool({connectionString: databaseUrl});
    const repository = new PostgresRepository(pool);
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const actorId = `actor_actions_${suffix}`;
    const playId = `play_actions_${suffix}`;
    const revisionId = `revision_actions_${suffix}`;
    const topicId = `topic_actions_${suffix}`;

    const action = (
      eventId: string,
      event: string,
      occurredAt: string,
      payload: Record<string, unknown>,
      withPlay = true,
    ): EventInput => ({
      eventId: `${eventId}_${suffix}`,
      event,
      version: 1,
      occurredAt,
      actorId,
      sessionId: `session_${suffix}`,
      ...(withPlay ? {playRevisionId: revisionId} : {}),
      payload,
    });

    try {
      await pool.query('insert into actors (id) values ($1)', [actorId]);
      await pool.query('insert into topics (id, label) values ($1, $2)', [topicId, 'Action topic']);
      await pool.query('insert into plays (id) values ($1)', [playId]);
      await pool.query(
        `insert into play_revisions (play_id, revision_id, schema_version, document)
         values ($1, $2, 1, $3::jsonb)`,
        [playId, revisionId, JSON.stringify({schemaVersion: 1, id: playId, revisionId})],
      );

      // A deliberately future-skewed client clock must not make this Save
      // authoritative forever. The later server receipt wins even though its
      // observed client time is far in the past.
      const futureSave = action('save', 'play_saved', '2099-01-01T00:00:00.000Z', {playId});
      assert.equal(await repository.insertEvent(futureSave), 'inserted');
      assert.equal(await repository.insertEvent(futureSave), 'duplicate');
      const pastUnsave = action('unsave', 'play_unsaved', '2000-01-01T00:00:00.000Z', {playId});
      assert.equal(await repository.insertEvent(pastUnsave), 'inserted');

      const saved = await pool.query<{
        saved: boolean;
        event_id: string;
        event_received_at: Date;
      }>(
        `select saved, event_id, event_received_at
           from actor_saved_plays
          where actor_id = $1 and play_id = $2`,
        [actorId, playId],
      );
      assert.equal(saved.rows[0]?.saved, false);
      assert.equal(saved.rows[0]?.event_id, pastUnsave.eventId);

      assert.equal(
        await repository.insertEvent(
          action('more_1', 'more_like_this', '2099-02-01T00:00:00.000Z', {playId}),
        ),
        'inserted',
      );
      assert.equal(
        await repository.insertEvent(
          action('more_2', 'more_like_this', '2000-02-01T00:00:00.000Z', {playId}),
        ),
        'inserted',
      );
      const moreLike = await pool.query<{count: string}>(
        `select count(*)::text as count
           from actor_play_signals
          where actor_id = $1 and play_id = $2 and signal = 'more_like_this'`,
        [actorId, playId],
      );
      assert.equal(moreLike.rows[0]?.count, '1');

      const feedRequestId = `feed_before_negative_${suffix}`;
      await pool.query(
        `insert into feed_decisions (
           request_id, actor_id, ranking_config_version, capability_fingerprint,
           fallback, candidate_count
         ) values ($1, $2, 'test-v1', 'capability-test', false, 0)`,
        [feedRequestId, actorId],
      );
      assert.equal(
        await repository.insertEvent(
          action('dismiss', 'play_not_interested', '1999-03-01T00:00:00.000Z', {playId}),
        ),
        'inserted',
      );
      const decisionAfterDismiss = await pool.query<{count: string}>(
        `select count(*)::text as count from feed_decisions where request_id = $1`,
        [feedRequestId],
      );
      assert.equal(decisionAfterDismiss.rows[0]?.count, '0');

      const notInterested = await pool.query<{count: string}>(
        `select count(*)::text as count
           from actor_play_signals
          where actor_id = $1 and play_id = $2 and signal = 'not_interested'`,
        [actorId, playId],
      );
      assert.equal(notInterested.rows[0]?.count, '1');

      const futureMute = action(
        'mute',
        'topic_muted',
        '2099-04-01T00:00:00.000Z',
        {topicId},
        false,
      );
      const pastUnmute = action(
        'unmute',
        'topic_unmuted',
        '2000-04-01T00:00:00.000Z',
        {topicId},
        false,
      );
      await repository.insertEvent(futureMute);
      await repository.insertEvent(pastUnmute);
      const muted = await pool.query<{muted: boolean; event_id: string}>(
        `select muted, event_id
           from actor_topic_mutes
          where actor_id = $1 and topic_id = $2`,
        [actorId, topicId],
      );
      assert.deepEqual(muted.rows[0], {muted: false, event_id: pastUnmute.eventId});

      const report = action('report', 'play_reported', '2030-05-01T00:00:00.000Z', {
        playId,
        reason: 'misleading',
        dismiss: true,
      });
      assert.equal(await repository.insertEvent(report), 'inserted');
      const reportStored = await pool.query<{event_name: string}>(
        'select event_name from interaction_events where event_id = $1',
        [report.eventId],
      );
      assert.equal(reportStored.rows[0]?.event_name, 'play_reported');

      const badReport = action('bad_report', 'play_reported', '2030-06-01T00:00:00.000Z', {
        playId,
        reason: 'invented_reason',
      });
      await assert.rejects(repository.insertEvent(badReport), ConsumerActionEventError);
      const badReportStored = await pool.query<{count: string}>(
        'select count(*)::text as count from interaction_events where event_id = $1',
        [badReport.eventId],
      );
      assert.equal(badReportStored.rows[0]?.count, '0');
    } finally {
      await pool.query('delete from actors where id = $1', [actorId]).catch(() => undefined);
      await pool.query('delete from plays where id = $1', [playId]).catch(() => undefined);
      await pool.query('delete from topics where id = $1', [topicId]).catch(() => undefined);
      await pool.end();
    }
  },
);

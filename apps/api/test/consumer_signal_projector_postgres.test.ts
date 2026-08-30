import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {PostgresConsumerRepository} from '../src/consumer_repository.js';
import {PostgresConsumerSignalProjector} from '../src/consumer_signal_projector.js';
import {feedCandidateIdentity} from '../src/consumer_ranking.js';
import {PostgresRepository, type EventInput} from '../src/repository.js';

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
  'signal projection is bounded, idempotent, compound-identity safe and rebuildable',
  {skip: !databaseUrl},
  async () => {
    await runMigration();
    const pool = new Pool({connectionString: databaseUrl});
    const events = new PostgresRepository(pool);
    const consumer = new PostgresConsumerRepository(pool);
    const projector = new PostgresConsumerSignalProjector(pool, {maxEventsPerRun: 2});
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const actorId = `actor_signal_${suffix}`;
    const sessionId = `session_signal_${suffix}`;
    const sharedRevision = `revision_shared_${suffix}`;
    const travelTopic = `travel_${suffix}`;
    const artTopic = `art_${suffix}`;
    const travelPlay = `play_travel_${suffix}`;
    const artPlay = `play_art_${suffix}`;
    const otherArtPlay = `play_art_other_${suffix}`;

    try {
      await pool.query('insert into actors (id) values ($1)', [actorId]);
      await pool.query(
        `insert into topics (id, label) values ($1, 'Travel'), ($2, 'Art')`,
        [travelTopic, artTopic],
      );
      for (const [playId, format, topicId] of [
        [travelPlay, 'guess', travelTopic],
        [artPlay, 'choose', artTopic],
        [otherArtPlay, 'choose', artTopic],
      ] as const) {
        await pool.query('insert into plays (id) values ($1)', [playId]);
        await pool.query(
          `insert into play_revisions (play_id, revision_id, schema_version, document)
           values ($1, $2, 1, $3::jsonb)`,
          [
            playId,
            sharedRevision,
            JSON.stringify({schemaVersion: 1, id: playId, revisionId: sharedRevision, format}),
          ],
        );
        await pool.query(
          `insert into play_revision_topics (play_id, revision_id, topic_id, role)
           values ($1, $2, $3, 'interest')`,
          [playId, sharedRevision, topicId],
        );
      }

      const base = {actorId, sessionId, version: 1, occurredAt: '2026-08-30T12:00:00Z'};
      const visibleTravel = event(base, {
        eventId: `visible_travel_${suffix}`,
        event: 'play_visible',
        playId: travelPlay,
        revisionId: sharedRevision,
      });
      const resolvedTravel = event(base, {
        eventId: `resolved_travel_${suffix}`,
        event: 'play_resolved',
        playId: travelPlay,
        revisionId: sharedRevision,
        payload: {correct: true, outcome: 'correct', attempt: 1},
      });
      const moreTravel = event(base, {
        eventId: `more_travel_${suffix}`,
        event: 'more_like_this',
        playId: travelPlay,
        revisionId: sharedRevision,
      });
      const notArt = event(base, {
        eventId: `not_art_${suffix}`,
        event: 'play_not_interested',
        playId: artPlay,
        revisionId: sharedRevision,
      });

      assert.equal(await events.insertEvent(visibleTravel), 'inserted');
      assert.equal(await events.insertEvent(resolvedTravel), 'inserted');
      assert.equal(await events.insertEvent(moreTravel), 'inserted');
      assert.equal(await events.insertEvent(notArt), 'inserted');

      assert.equal(await projector.projectActor(actorId), 2);
      assert.equal(await projector.projectActor(actorId), 2);
      assert.equal(await projector.projectActor(actorId), 0);

      const first = await consumer.getDerivedRankingProfile(actorId);
      assert.ok(first);
      assert.ok((first.interactionAffinity.guess ?? 0) > 0);
      assert.deepEqual(first.recentPlayRevisionKeys, [
        feedCandidateIdentity(travelPlay, sharedRevision),
      ]);
      assert.deepEqual(first.moreLikeTopicIds, [travelTopic]);
      assert.equal(first.topicDismissalCounts[artTopic], 1);
      assert.equal(first.formatDismissalCounts.choose, 1);

      // Same revision ID on a different Play must not be marked recent.
      assert.equal(
        first.recentPlayRevisionKeys.includes(
          feedCandidateIdentity(artPlay, sharedRevision),
        ),
        false,
      );

      // Exact replay is rejected by canonical event identity and applies nothing.
      assert.equal(await events.insertEvent(notArt), 'duplicate');
      assert.equal(await projector.projectActor(actorId), 0);

      // A second related Play supplies genuine repeated negative evidence.
      const secondNotArt = event(base, {
        eventId: `not_art_second_${suffix}`,
        event: 'play_not_interested',
        playId: otherArtPlay,
        revisionId: sharedRevision,
      });
      assert.equal(await events.insertEvent(secondNotArt), 'inserted');
      const concurrent = await Promise.all([
        projector.projectActor(actorId),
        projector.projectActor(actorId),
      ]);
      assert.equal(concurrent.reduce((sum, value) => sum + value, 0), 1);
      const repeated = await consumer.getDerivedRankingProfile(actorId);
      assert.equal(repeated?.topicDismissalCounts[artTopic], 2);
      assert.equal(repeated?.formatDismissalCounts.choose, 2);

      // A second event ID for the same one-shot Play signal must not multiply evidence.
      const duplicateIntent = event(base, {
        eventId: `not_art_duplicate_intent_${suffix}`,
        event: 'play_not_interested',
        playId: artPlay,
        revisionId: sharedRevision,
      });
      assert.equal(await events.insertEvent(duplicateIntent), 'inserted');
      await projector.projectActor(actorId);
      const bounded = await consumer.getDerivedRankingProfile(actorId);
      assert.equal(bounded?.topicDismissalCounts[artTopic], 2);
      assert.equal(bounded?.formatDismissalCounts.choose, 2);

      const beforeRebuild = await rawProjection(pool, actorId);
      const rebuiltEvents = await projector.rebuildActor(actorId);
      assert.ok(rebuiltEvents >= 5);
      const afterRebuild = await rawProjection(pool, actorId);
      assert.deepEqual(afterRebuild, beforeRebuild);
    } finally {
      await pool.end();
    }
  },
);

function event(
  base: Pick<EventInput, 'actorId' | 'sessionId' | 'version' | 'occurredAt'>,
  input: {
    eventId: string;
    event: string;
    playId: string;
    revisionId: string;
    payload?: Record<string, unknown>;
  },
): EventInput {
  return {
    ...base,
    eventId: input.eventId,
    event: input.event,
    feedRequestId: 'feed_signal',
    playRevisionId: input.revisionId,
    payload: {playId: input.playId, ...input.payload},
  };
}

async function rawProjection(pool: Pool, actorId: string): Promise<unknown> {
  const result = await pool.query<{
    checkpoint_received_at: string | null;
    checkpoint_event_id: string | null;
    interaction_affinity: unknown;
    recent_revisions: unknown;
    topic_dismissal_counts: unknown;
    format_dismissal_counts: unknown;
    more_like_topic_expiries: unknown;
    format_last_dismissed_at: unknown;
  }>(
    `select checkpoint_received_at::text,
            checkpoint_event_id,
            interaction_affinity,
            recent_revisions,
            topic_dismissal_counts,
            format_dismissal_counts,
            more_like_topic_expiries,
            format_last_dismissed_at
       from consumer_signal_profiles
      where actor_id = $1`,
    [actorId],
  );
  return result.rows[0] ?? null;
}

import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {buildApp} from '../src/app.js';
import {PostgresConsumerRepository} from '../src/consumer_repository.js';
import {PostgresConsumerSignalProjector} from '../src/consumer_signal_projector.js';
import {PostgresRepository} from '../src/repository.js';

const databaseUrl = process.env.DATABASE_URL;
const actorToken = 'L'.repeat(43);
const authorization = {authorization: `Bearer ${actorToken}`};
const capabilities = {
  schemaVersions: [1],
  presentationTypes: ['text'],
  inputTypes: ['tap'],
  validatorTypes: ['none'],
  platformFlags: [],
};

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
  'anonymous feed interaction trace changes the next decision and rebuilds deterministically',
  {skip: !databaseUrl},
  async () => {
    await runMigration();
    const pool = new Pool({connectionString: databaseUrl});
    const repository = new PostgresRepository(pool);
    const consumerRepository = new PostgresConsumerRepository(pool);
    const projector = new PostgresConsumerSignalProjector(pool);
    const app = buildApp({
      repository,
      consumerRepository,
      consumerSignalProjector: projector,
      logLevel: 'silent',
    });
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const actorId = `actor_loop_${suffix}`;
    const sessionId = `session_loop_${suffix}`;
    const scienceTopic = `science_${suffix}`;
    const artTopic = `art_${suffix}`;
    const primaryPlay = `science_primary_${suffix}`;
    const siblingPlay = `science_sibling_${suffix}`;
    const artPlay = `art_${suffix}`;
    const revisionId = `revision_${suffix}`;

    try {
      const registration = await app.inject({
        method: 'POST',
        url: '/v1/actors',
        headers: authorization,
        payload: {actorId},
      });
      assert.equal(registration.statusCode, 201);

      await pool.query(
        `insert into topics (id, label) values ($1, 'Science'), ($2, 'Art')`,
        [scienceTopic, artTopic],
      );
      for (const [playId, format, topicId, qualityPrior, curatedOrder] of [
        [primaryPlay, 'guess', scienceTopic, 0.95, 1],
        [siblingPlay, 'guess', scienceTopic, 0.8, 2],
        [artPlay, 'choose', artTopic, 0.7, 3],
      ] as const) {
        await pool.query('insert into plays (id) values ($1)', [playId]);
        await pool.query(
          `insert into play_revisions (play_id, revision_id, schema_version, document)
           values ($1, $2, 1, $3::jsonb)`,
          [playId, revisionId, JSON.stringify(playDocument(playId, revisionId, format))],
        );
        await pool.query(
          `insert into play_revision_topics (play_id, revision_id, topic_id, role)
           values ($1, $2, $3, 'interest')`,
          [playId, revisionId, topicId],
        );
        await pool.query(
          `insert into feed_catalog_entries (
             play_id, revision_id, quality_prior, curated_order
           ) values ($1, $2, $3, $4)`,
          [playId, revisionId, qualityPrior, curatedOrder],
        );
      }

      const preferences = await app.inject({
        method: 'PUT',
        url: `/v1/actors/${actorId}/preferences`,
        headers: authorization,
        payload: {
          interestTopicIds: [scienceTopic, artTopic],
          learningTopicIds: [],
        },
      });
      assert.equal(preferences.statusCode, 204);

      const first = await app.inject({
        method: 'POST',
        url: '/v1/feed',
        headers: authorization,
        payload: {actorId, capabilities, limit: 3},
      });
      assert.equal(first.statusCode, 200);
      const firstBody = first.json() as FeedResponse;
      assert.equal(firstBody.rankingConfigVersion, 'm2-rules-v1');
      assert.deepEqual(firstBody.items.map((item) => item.playId), [
        primaryPlay,
        siblingPlay,
        artPlay,
      ]);

      const before = await decisionContributions(pool, firstBody.requestId, siblingPlay);
      assert.equal(before.interactionAffinity ?? 0, 0);
      assert.equal(before.moreLikeThisAffinity ?? 0, 0);

      const visibleEventId = `visible_${suffix}`;
      const resolvedEventId = `resolved_${suffix}`;
      const moreLikeEventId = `more_like_${suffix}`;
      assert.equal(
        await postEvent(app, {
          eventId: visibleEventId,
          event: 'play_visible',
          actorId,
          sessionId,
          feedRequestId: firstBody.requestId,
          playRevisionId: revisionId,
          payload: {playId: primaryPlay, position: 0},
        }),
        202,
      );
      assert.equal(
        await postEvent(app, {
          eventId: resolvedEventId,
          event: 'play_resolved',
          actorId,
          sessionId,
          feedRequestId: firstBody.requestId,
          playRevisionId: revisionId,
          payload: {
            playId: primaryPlay,
            correct: true,
            outcome: 'correct',
            attempt: 1,
          },
        }),
        202,
      );
      assert.equal(
        await postEvent(app, {
          eventId: moreLikeEventId,
          event: 'more_like_this',
          actorId,
          sessionId,
          feedRequestId: firstBody.requestId,
          playRevisionId: revisionId,
          payload: {playId: primaryPlay},
        }),
        202,
      );

      // Exact retry remains idempotent at the canonical event boundary.
      assert.equal(
        await postEvent(app, {
          eventId: resolvedEventId,
          event: 'play_resolved',
          actorId,
          sessionId,
          feedRequestId: firstBody.requestId,
          playRevisionId: revisionId,
          payload: {
            playId: primaryPlay,
            correct: true,
            outcome: 'correct',
            attempt: 1,
          },
        }),
        200,
      );
      const resolvedRows = await pool.query<{count: string}>(
        'select count(*)::text as count from interaction_events where event_id = $1',
        [resolvedEventId],
      );
      assert.equal(resolvedRows.rows[0]?.count, '1');

      const trace = await pool.query<{
        event_name: string;
        feed_request_id: string | null;
        play_revision_id: string | null;
      }>(
        `select event_name, feed_request_id, play_revision_id
           from interaction_events
          where event_id = any($1::text[])
          order by event_name`,
        [[visibleEventId, resolvedEventId, moreLikeEventId]],
      );
      assert.equal(trace.rows.length, 3);
      assert.equal(trace.rows.every((row) => row.feed_request_id === firstBody.requestId), true);
      assert.equal(trace.rows.every((row) => row.play_revision_id === revisionId), true);

      const second = await app.inject({
        method: 'POST',
        url: '/v1/feed',
        headers: authorization,
        payload: {actorId, capabilities, limit: 3},
      });
      assert.equal(second.statusCode, 200);
      const secondBody = second.json() as FeedResponse;
      assert.notEqual(secondBody.requestId, firstBody.requestId);
      assert.equal(secondBody.items[0]?.playId, siblingPlay);

      const after = await decisionContributions(pool, secondBody.requestId, siblingPlay);
      assert.ok((after.interactionAffinity ?? 0) > 0);
      assert.ok((after.moreLikeThisAffinity ?? 0) > 0);
      assert.equal(after.recentSeenPenalty ?? 0, 0);

      const primaryAfter = await decisionContributions(pool, secondBody.requestId, primaryPlay);
      assert.ok((primaryAfter.recentSeenPenalty ?? 0) < 0);
      assert.ok((primaryAfter.interactionAffinity ?? 0) > 0);
      assert.ok((primaryAfter.moreLikeThisAffinity ?? 0) > 0);

      const profileBeforeRebuild = await rawProfile(pool, actorId);
      assert.ok(profileBeforeRebuild);
      assert.equal(profileBeforeRebuild.checkpoint_event_id, resolvedEventId);
      assert.ok(
        Number(
          (profileBeforeRebuild.interaction_affinity as Record<string, {value?: number}>).guess
            ?.value ?? 0,
        ) > 0,
      );

      const rebuilt = await projector.rebuildActor(actorId);
      assert.equal(rebuilt, 2);
      const profileAfterRebuild = await rawProfile(pool, actorId);
      assert.deepEqual(profileAfterRebuild, profileBeforeRebuild);

      const actionSignal = await pool.query<{
        signal: string;
        play_id: string;
        revision_id: string;
      }>(
        `select signal, play_id, revision_id
           from actor_play_signals
          where actor_id = $1 and play_id = $2`,
        [actorId, primaryPlay],
      );
      assert.deepEqual(actionSignal.rows, [
        {signal: 'more_like_this', play_id: primaryPlay, revision_id: revisionId},
      ]);
    } finally {
      await app.close();
      await pool.end();
    }
  },
);

type FeedResponse = {
  requestId: string;
  rankingConfigVersion: string;
  items: Array<{playId: string; revisionId: string}>;
};

type EventRequest = {
  eventId: string;
  event: string;
  actorId: string;
  sessionId: string;
  feedRequestId: string;
  playRevisionId: string;
  payload: Record<string, unknown>;
};

async function postEvent(
  app: ReturnType<typeof buildApp>,
  event: EventRequest,
): Promise<number> {
  const response = await app.inject({
    method: 'POST',
    url: '/v1/events',
    headers: authorization,
    payload: {
      ...event,
      version: 1,
      occurredAt: '2026-08-31T04:00:00Z',
    },
  });
  return response.statusCode;
}

async function decisionContributions(
  pool: Pool,
  requestId: string,
  playId: string,
): Promise<Record<string, number>> {
  const result = await pool.query<{feature_contributions: Record<string, number>}>(
    `select feature_contributions
       from feed_decision_items
      where request_id = $1 and play_id = $2`,
    [requestId, playId],
  );
  const row = result.rows[0];
  assert.ok(row, `missing feed decision item for ${playId}`);
  return row.feature_contributions;
}

async function rawProfile(
  pool: Pool,
  actorId: string,
): Promise<{
  checkpoint_received_at: string | null;
  checkpoint_event_id: string | null;
  interaction_affinity: unknown;
  recent_revisions: unknown;
  format_dismissal_counts: unknown;
  format_last_dismissed_at: unknown;
} | null> {
  const result = await pool.query<{
    checkpoint_received_at: string | null;
    checkpoint_event_id: string | null;
    interaction_affinity: unknown;
    recent_revisions: unknown;
    format_dismissal_counts: unknown;
    format_last_dismissed_at: unknown;
  }>(
    `select checkpoint_received_at::text,
            checkpoint_event_id,
            interaction_affinity,
            recent_revisions,
            format_dismissal_counts,
            format_last_dismissed_at
       from consumer_signal_profiles
      where actor_id = $1`,
    [actorId],
  );
  return result.rows[0] ?? null;
}

function playDocument(playId: string, revisionId: string, format: string) {
  return {
    schemaVersion: 1,
    id: playId,
    revisionId,
    format,
    states: {
      start: {
        presentation: {layers: [{type: 'text'}]},
        input: {type: 'tap'},
        validation: {type: 'none'},
        transition: {default: '$end'},
      },
    },
  };
}

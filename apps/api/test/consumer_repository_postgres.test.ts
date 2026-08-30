import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {PostgresConsumerRepository, UnknownTopicError} from '../src/consumer_repository.js';
import {defaultConsumerRankingConfig, rankFeedCandidates} from '../src/consumer_ranking.js';
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

test(
  'PostgreSQL consumer repository replaces preferences, reads actions and persists decisions',
  {skip: !databaseUrl},
  async () => {
    await runMigration();
    const pool = new Pool({connectionString: databaseUrl});
    const repo = new PostgresConsumerRepository(pool);
    const eventRepo = new PostgresRepository(pool);
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const actorId = `actor_feed_${suffix}`;
    const travelTopic = `travel_${suffix}`;
    const pianoTopic = `piano_${suffix}`;
    const foodTopic = `food_${suffix}`;
    const travelPlay = `play_travel_${suffix}`;
    const pianoPlay = `play_piano_${suffix}`;
    const revisionId = `rev_${suffix}`;
    const requestId = `feed_${suffix}`;
    const capabilityFingerprint = `cap_${suffix}`;

    try {
      await pool.query(
        `insert into topics (id, label) values
           ($1, 'Travel'), ($2, 'Piano'), ($3, 'Food')`,
        [travelTopic, pianoTopic, foodTopic],
      );
      await pool.query('insert into actors (id) values ($1)', [actorId]);
      for (const [playId, format] of [
        [travelPlay, 'guess'],
        [pianoPlay, 'choose'],
      ] as const) {
        await pool.query('insert into plays (id) values ($1)', [playId]);
        await pool.query(
          `insert into play_revisions (play_id, revision_id, schema_version, document)
           values ($1, $2, 1, $3::jsonb)`,
          [
            playId,
            revisionId,
            JSON.stringify({schemaVersion: 1, id: playId, revisionId, format}),
          ],
        );
      }
      await pool.query(
        `insert into play_revision_topics (play_id, revision_id, topic_id, role)
         values ($1, $3, $4, 'interest'), ($2, $3, $5, 'learning')`,
        [travelPlay, pianoPlay, revisionId, travelTopic, pianoTopic],
      );
      await pool.query(
        `insert into feed_catalog_entries (
           play_id, revision_id, quality_prior, curated_order
         ) values ($1, $3, 0.8, 10), ($2, $3, 0.7, 20)`,
        [travelPlay, pianoPlay, revisionId],
      );

      await repo.replaceTopicPreferences(actorId, [travelTopic, travelTopic], [pianoTopic]);
      assert.deepEqual(await repo.getTopicPreferences(actorId), {
        interestTopicIds: [travelTopic],
        learningTopicIds: [pianoTopic],
      });

      const eventBase = {
        version: 1,
        actorId,
        sessionId: `session_${suffix}`,
        playRevisionId: revisionId,
      } as const;
      assert.equal(
        await eventRepo.insertEvent({
          ...eventBase,
          eventId: `save_${suffix}`,
          event: 'play_saved',
          occurredAt: '2026-08-29T20:00:00Z',
          payload: {playId: travelPlay},
        }),
        'inserted',
      );
      await eventRepo.insertEvent({
        ...eventBase,
        eventId: `more_${suffix}`,
        event: 'more_like_this',
        occurredAt: '2026-08-29T20:01:00Z',
        payload: {playId: travelPlay},
      });
      await eventRepo.insertEvent({
        ...eventBase,
        eventId: `not_${suffix}`,
        event: 'play_not_interested',
        occurredAt: '2026-08-29T20:02:00Z',
        payload: {playId: pianoPlay},
      });
      await eventRepo.insertEvent({
        eventId: `mute_${suffix}`,
        event: 'topic_muted',
        version: 1,
        occurredAt: '2026-08-29T20:03:00Z',
        actorId,
        sessionId: `session_${suffix}`,
        payload: {topicId: pianoTopic},
      });

      assert.deepEqual(await repo.getActionState(actorId, travelPlay), {
        play: {
          playId: travelPlay,
          saved: true,
          savedRevisionId: revisionId,
          moreLikeThis: true,
          notInterested: false,
        },
        mutedTopicIds: [pianoTopic],
      });
      assert.deepEqual(await repo.getFeedProfile(actorId), {
        interestTopicIds: [travelTopic],
        learningTopicIds: [pianoTopic],
        mutedTopicIds: [pianoTopic],
        notInterestedPlayIds: [pianoPlay],
      });

      const search = await repo.searchTopics('pIaNo', 10);
      assert.deepEqual(search, [{id: pianoTopic, label: 'Piano'}]);

      await assert.rejects(
        repo.replaceTopicPreferences(actorId, [foodTopic], [`missing_${suffix}`]),
        (error) =>
          error instanceof UnknownTopicError && error.topicIds[0] === `missing_${suffix}`,
      );
      assert.deepEqual(await repo.getTopicPreferences(actorId), {
        interestTopicIds: [travelTopic],
        learningTopicIds: [pianoTopic],
      });

      const candidates = await repo.listEligibleFeedCandidates(20);
      const selected = candidates.filter(
        (candidate) => candidate.playId === travelPlay || candidate.playId === pianoPlay,
      );
      assert.deepEqual(
        selected.map((candidate) => [
          candidate.playId,
          candidate.topicIds,
          candidate.learningTopicIds,
        ]),
        [
          [travelPlay, [travelTopic], []],
          [pianoPlay, [], [pianoTopic]],
        ],
      );

      const ranked = rankFeedCandidates(selected, {
        interestTopicIds: [travelTopic],
        learningTopicIds: [pianoTopic],
      });
      await repo.persistFeedDecision({
        requestId,
        actorId,
        rankingConfigVersion: defaultConsumerRankingConfig.version,
        capabilityFingerprint,
        fallback: false,
        ranked,
      });

      const page = await repo.readFeedDecisionPage(
        requestId,
        actorId,
        capabilityFingerprint,
        0,
        1,
      );
      assert.ok(page);
      assert.equal(page.candidateCount, 2);
      assert.equal(page.items.length, 1);
      assert.equal(page.items[0]?.playId, pianoPlay);
      assert.equal(page.items[0]?.sourceBucket, 'known');
      assert.equal(typeof page.items[0]?.featureContributions.learningAffinity, 'number');
      assert.equal(
        await repo.readFeedDecisionPage(requestId, actorId, `other_${suffix}`, 0, 1),
        null,
      );
      assert.equal(
        await repo.readFeedDecisionPage(
          requestId,
          `other_${suffix}`,
          capabilityFingerprint,
          0,
          1,
        ),
        null,
      );
    } finally {
      await pool.end();
    }
  },
);

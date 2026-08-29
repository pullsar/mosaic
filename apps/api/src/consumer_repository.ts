import {Pool, type PoolClient} from 'pg';
import type {FeedCandidate, FeedSourceBucket, RankedFeedCandidate} from './consumer_ranking.js';

const MAX_PREFERENCE_TOPICS = 64;
const MAX_CANDIDATES = 500;
const MAX_PAGE_SIZE = 50;

export interface TopicSummary {
  id: string;
  label: string;
}

export interface TopicPreferences {
  interestTopicIds: string[];
  learningTopicIds: string[];
}

export interface FeedDecisionInput {
  requestId: string;
  actorId: string;
  rankingConfigVersion: string;
  fallback: boolean;
  ranked: readonly RankedFeedCandidate[];
}

export interface StoredFeedDecisionItem {
  position: number;
  playId: string;
  revisionId: string;
  sourceBucket: FeedSourceBucket;
  score: number;
  featureContributions: Record<string, number>;
  document: unknown;
}

export interface StoredFeedDecisionPage {
  requestId: string;
  rankingConfigVersion: string;
  fallback: boolean;
  candidateCount: number;
  items: StoredFeedDecisionItem[];
}

export interface ConsumerRepository {
  searchTopics(query: string, limit?: number): Promise<TopicSummary[]>;
  replaceTopicPreferences(
    actorId: string,
    interestTopicIds: readonly string[],
    learningTopicIds: readonly string[],
  ): Promise<void>;
  getTopicPreferences(actorId: string): Promise<TopicPreferences>;
  listEligibleFeedCandidates(limit?: number): Promise<FeedCandidate[]>;
  persistFeedDecision(input: FeedDecisionInput): Promise<void>;
  readFeedDecisionPage(
    requestId: string,
    actorId: string,
    offset: number,
    limit: number,
  ): Promise<StoredFeedDecisionPage | null>;
}

export class UnknownTopicError extends Error {
  constructor(readonly topicIds: readonly string[]) {
    super(`Unknown topic IDs: ${topicIds.join(', ')}`);
    this.name = 'UnknownTopicError';
  }
}

export class PostgresConsumerRepository implements ConsumerRepository {
  constructor(private readonly pool: Pool) {}

  async searchTopics(query: string, limit = 30): Promise<TopicSummary[]> {
    const normalizedQuery = query.trim().toLowerCase();
    const boundedLimit = boundedInteger(limit, 1, 100, 'limit');
    const result = await this.pool.query<TopicSummary>(
      `select id, label
         from topics
        where $1 = ''
           or lower(id) like '%' || $1 || '%'
           or lower(label) like '%' || $1 || '%'
        order by
          case when lower(id) = $1 or lower(label) = $1 then 0 else 1 end,
          label asc,
          id asc
        limit $2`,
      [normalizedQuery, boundedLimit],
    );
    return result.rows;
  }

  async replaceTopicPreferences(
    actorId: string,
    interestTopicIds: readonly string[],
    learningTopicIds: readonly string[],
  ): Promise<void> {
    const normalizedActorId = requiredText(actorId, 'actorId');
    const interest = normalizeTopicIds(interestTopicIds, 'interestTopicIds');
    const learning = normalizeTopicIds(learningTopicIds, 'learningTopicIds');
    const requested = [...new Set([...interest, ...learning])];
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      await client.query(
        `insert into actors (id) values ($1)
         on conflict (id) do nothing`,
        [normalizedActorId],
      );
      await client.query('select id from actors where id = $1 for update', [normalizedActorId]);
      await this.assertKnownTopics(client, requested);
      await client.query('delete from actor_topic_preferences where actor_id = $1', [
        normalizedActorId,
      ]);
      await insertPreferences(client, normalizedActorId, 'interest', interest);
      await insertPreferences(client, normalizedActorId, 'learning', learning);
      await client.query('commit');
    } catch (error) {
      await client.query('rollback');
      throw error;
    } finally {
      client.release();
    }
  }

  async getTopicPreferences(actorId: string): Promise<TopicPreferences> {
    const normalizedActorId = requiredText(actorId, 'actorId');
    const result = await this.pool.query<{topic_id: string; kind: 'interest' | 'learning'}>(
      `select topic_id, kind
         from actor_topic_preferences
        where actor_id = $1
        order by kind, topic_id`,
      [normalizedActorId],
    );
    return {
      interestTopicIds: result.rows
        .filter((row) => row.kind === 'interest')
        .map((row) => row.topic_id),
      learningTopicIds: result.rows
        .filter((row) => row.kind === 'learning')
        .map((row) => row.topic_id),
    };
  }

  async listEligibleFeedCandidates(limit = 200): Promise<FeedCandidate[]> {
    const boundedLimit = boundedInteger(limit, 1, MAX_CANDIDATES, 'limit');
    const result = await this.pool.query<{
      play_id: string;
      revision_id: string;
      format: string | null;
      quality_prior: number;
      curated_order: number;
      topic_ids: string[];
      learning_topic_ids: string[];
      document: unknown;
    }>(
      `select catalog.play_id,
              catalog.revision_id,
              revision.document ->> 'format' as format,
              catalog.quality_prior,
              catalog.curated_order,
              coalesce(
                array_agg(link.topic_id order by link.topic_id)
                  filter (where link.role = 'interest'),
                array[]::text[]
              ) as topic_ids,
              coalesce(
                array_agg(link.topic_id order by link.topic_id)
                  filter (where link.role = 'learning'),
                array[]::text[]
              ) as learning_topic_ids,
              revision.document
         from feed_catalog_entries catalog
         join play_revisions revision
           on revision.play_id = catalog.play_id
          and revision.revision_id = catalog.revision_id
         left join play_revision_topics link
           on link.play_id = catalog.play_id
          and link.revision_id = catalog.revision_id
        where catalog.state = 'eligible'
        group by catalog.play_id,
                 catalog.revision_id,
                 revision.document,
                 catalog.quality_prior,
                 catalog.curated_order
        order by catalog.curated_order, catalog.play_id, catalog.revision_id
        limit $1`,
      [boundedLimit],
    );
    return result.rows.map((row) => ({
      playId: row.play_id,
      revisionId: row.revision_id,
      format: requiredText(row.format ?? '', 'candidate.format'),
      topicIds: row.topic_ids,
      learningTopicIds: row.learning_topic_ids,
      qualityPrior: row.quality_prior,
      curatedOrder: row.curated_order,
      document: row.document,
    }));
  }

  async persistFeedDecision(input: FeedDecisionInput): Promise<void> {
    const requestId = requiredText(input.requestId, 'requestId');
    const actorId = requiredText(input.actorId, 'actorId');
    const configVersion = requiredText(input.rankingConfigVersion, 'rankingConfigVersion');
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      await client.query(
        `insert into feed_decisions (
           request_id, actor_id, ranking_config_version, fallback, candidate_count
         ) values ($1, $2, $3, $4, $5)`,
        [requestId, actorId, configVersion, input.fallback, input.ranked.length],
      );
      for (const [position, candidate] of input.ranked.entries()) {
        await client.query(
          `insert into feed_decision_items (
             request_id, position, play_id, revision_id, source_bucket, score,
             feature_contributions
           ) values ($1, $2, $3, $4, $5, $6, $7::jsonb)`,
          [
            requestId,
            position,
            candidate.playId,
            candidate.revisionId,
            candidate.sourceBucket,
            candidate.score,
            JSON.stringify(candidate.featureContributions),
          ],
        );
      }
      await client.query('commit');
    } catch (error) {
      await client.query('rollback');
      throw error;
    } finally {
      client.release();
    }
  }

  async readFeedDecisionPage(
    requestId: string,
    actorId: string,
    offset: number,
    limit: number,
  ): Promise<StoredFeedDecisionPage | null> {
    const normalizedRequestId = requiredText(requestId, 'requestId');
    const normalizedActorId = requiredText(actorId, 'actorId');
    const boundedOffset = boundedInteger(offset, 0, Number.MAX_SAFE_INTEGER, 'offset');
    const boundedLimit = boundedInteger(limit, 1, MAX_PAGE_SIZE, 'limit');
    const decision = await this.pool.query<{
      ranking_config_version: string;
      fallback: boolean;
      candidate_count: number;
    }>(
      `select ranking_config_version, fallback, candidate_count
         from feed_decisions
        where request_id = $1 and actor_id = $2`,
      [normalizedRequestId, normalizedActorId],
    );
    const row = decision.rows[0];
    if (!row) return null;

    const items = await this.pool.query<{
      position: number;
      play_id: string;
      revision_id: string;
      source_bucket: FeedSourceBucket;
      score: number;
      feature_contributions: Record<string, number>;
      document: unknown;
    }>(
      `select item.position,
              item.play_id,
              item.revision_id,
              item.source_bucket,
              item.score,
              item.feature_contributions,
              revision.document
         from feed_decision_items item
         join play_revisions revision
           on revision.play_id = item.play_id
          and revision.revision_id = item.revision_id
        where item.request_id = $1
          and item.position >= $2
        order by item.position
        limit $3`,
      [normalizedRequestId, boundedOffset, boundedLimit],
    );

    return {
      requestId: normalizedRequestId,
      rankingConfigVersion: row.ranking_config_version,
      fallback: row.fallback,
      candidateCount: row.candidate_count,
      items: items.rows.map((item) => ({
        position: item.position,
        playId: item.play_id,
        revisionId: item.revision_id,
        sourceBucket: item.source_bucket,
        score: item.score,
        featureContributions: item.feature_contributions,
        document: item.document,
      })),
    };
  }

  private async assertKnownTopics(client: PoolClient, topicIds: readonly string[]): Promise<void> {
    if (topicIds.length === 0) return;
    const result = await client.query<{id: string}>(
      'select id from topics where id = any($1::text[])',
      [topicIds],
    );
    const known = new Set(result.rows.map((row) => row.id));
    const unknown = topicIds.filter((topicId) => !known.has(topicId));
    if (unknown.length > 0) throw new UnknownTopicError(unknown);
  }
}

async function insertPreferences(
  client: PoolClient,
  actorId: string,
  kind: 'interest' | 'learning',
  topicIds: readonly string[],
): Promise<void> {
  if (topicIds.length === 0) return;
  await client.query(
    `insert into actor_topic_preferences (actor_id, topic_id, kind)
     select $1, topic_id, $2
       from unnest($3::text[]) as selected(topic_id)`,
    [actorId, kind, topicIds],
  );
}

function normalizeTopicIds(values: readonly string[], name: string): string[] {
  if (!Array.isArray(values)) throw new TypeError(`${name} must be an array.`);
  const result = [...new Set(values.map((value) => requiredText(value, name).toLowerCase()))];
  if (result.length > MAX_PREFERENCE_TOPICS) {
    throw new RangeError(`${name} supports at most ${MAX_PREFERENCE_TOPICS} topics.`);
  }
  return result.sort();
}

function requiredText(value: string, name: string): string {
  if (typeof value !== 'string') throw new TypeError(`${name} must be a string.`);
  const normalized = value.trim();
  if (normalized.length === 0) throw new TypeError(`${name} must not be empty.`);
  if (normalized.length > 200) throw new RangeError(`${name} is too long.`);
  return normalized;
}

function boundedInteger(value: number, min: number, max: number, name: string): number {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new RangeError(`${name} must be an integer between ${min} and ${max}.`);
  }
  return value;
}

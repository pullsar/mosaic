import {Pool, type PoolClient} from 'pg';
import type {FeedCandidate} from './consumer_ranking.js';

const MAX_SEARCH_CANDIDATES = 120;
const MAX_DECISION_RESULTS = 60;
const MAX_PAGE_SIZE = 20;
const EXPIRED_SEARCH_CLEANUP_BATCH = 100;

export type ConsumerSearchIntent = 'interest' | 'learning';
export type ConsumerSearchMatchKind =
  | 'topic_exact'
  | 'topic_prefix'
  | 'play_exact'
  | 'play_prefix';

export interface ConsumerSearchTopicCandidate {
  kind: 'topic';
  topicId: string;
  label: string;
  matchKind: 'topic_exact' | 'topic_prefix';
}

export interface ConsumerSearchPlayCandidate {
  kind: 'play';
  candidate: FeedCandidate;
  matchKind: ConsumerSearchMatchKind;
  sortRank: number;
}

export type ConsumerSearchDecisionItemInput =
  | ConsumerSearchTopicCandidate
  | {
      kind: 'play';
      playId: string;
      revisionId: string;
      matchKind: ConsumerSearchMatchKind;
    };

export type ConsumerSearchDecisionItem =
  | {
      kind: 'topic';
      position: number;
      topicId: string;
      label: string;
      matchKind: 'topic_exact' | 'topic_prefix';
    }
  | {
      kind: 'play';
      position: number;
      playId: string;
      revisionId: string;
      document: unknown;
      matchKind: ConsumerSearchMatchKind;
    };

export interface ConsumerSearchDecisionInput {
  requestId: string;
  actorId: string;
  intent: ConsumerSearchIntent;
  queryHash: string;
  capabilityFingerprint: string;
  items: readonly ConsumerSearchDecisionItemInput[];
}

export interface StoredConsumerSearchDecisionPage {
  requestId: string;
  intent: ConsumerSearchIntent;
  queryHash: string;
  resultCount: number;
  items: ConsumerSearchDecisionItem[];
}

export interface ConsumerSearchRepository {
  searchTopics(query: string, limit?: number): Promise<ConsumerSearchTopicCandidate[]>;
  searchPlayCandidates(
    query: string,
    intent: ConsumerSearchIntent,
    limit?: number,
  ): Promise<ConsumerSearchPlayCandidate[]>;
  topicExists(topicId: string): Promise<boolean>;
  persistDecision(input: ConsumerSearchDecisionInput): Promise<void>;
  readDecisionPage(
    requestId: string,
    actorId: string,
    capabilityFingerprint: string,
    offset: number,
    limit: number,
  ): Promise<StoredConsumerSearchDecisionPage | null>;
}

export class PostgresConsumerSearchRepository implements ConsumerSearchRepository {
  constructor(private readonly pool: Pool) {}

  async searchTopics(query: string, limit = 20): Promise<ConsumerSearchTopicCandidate[]> {
    const normalized = requiredQuery(query);
    const boundedLimit = boundedInteger(limit, 1, MAX_DECISION_RESULTS, 'limit');
    const prefix = `${escapeLike(normalized)}%`;
    const result = await this.pool.query<{
      id: string;
      label: string;
      match_kind: 'topic_exact' | 'topic_prefix';
    }>(
      `select id,
              label,
              case
                when lower(id) = $1 or lower(label) = $1 then 'topic_exact'
                else 'topic_prefix'
              end as match_kind
         from topics
        where lower(id) = $1
           or lower(label) = $1
           or lower(id) like $2 escape '\\'
           or lower(label) like $2 escape '\\'
        order by
          case when lower(id) = $1 or lower(label) = $1 then 0 else 1 end,
          label,
          id
        limit $3`,
      [normalized, prefix, boundedLimit],
    );
    return result.rows.map((row) => ({
      kind: 'topic',
      topicId: row.id,
      label: row.label,
      matchKind: row.match_kind,
    }));
  }

  async searchPlayCandidates(
    query: string,
    intent: ConsumerSearchIntent,
    limit = 80,
  ): Promise<ConsumerSearchPlayCandidate[]> {
    const normalized = requiredQuery(query);
    const boundedLimit = boundedInteger(limit, 1, MAX_SEARCH_CANDIDATES, 'limit');
    const normalizedIntent = requiredIntent(intent);
    const prefix = `${escapeLike(normalized)}%`;
    const result = await this.pool.query<{
      play_id: string;
      revision_id: string;
      format: string | null;
      quality_prior: number;
      curated_order: number;
      topic_ids: string[];
      learning_topic_ids: string[];
      document: unknown;
      match_kind: ConsumerSearchMatchKind;
      sort_rank: number;
    }>(
      `with topic_match as (
         select link.play_id,
                link.revision_id,
                bool_or(
                  link.role = $3
                  and (lower(topic.id) = $1 or lower(topic.label) = $1)
                ) as intent_exact,
                bool_or(link.role = $3) as intent_prefix,
                bool_or(lower(topic.id) = $1 or lower(topic.label) = $1) as any_exact
           from play_revision_topics link
           join topics topic on topic.id = link.topic_id
          where lower(topic.id) = $1
             or lower(topic.label) = $1
             or lower(topic.id) like $2 escape '\\'
             or lower(topic.label) like $2 escape '\\'
          group by link.play_id, link.revision_id
       )
       select catalog.play_id,
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
              revision.document,
              case
                when lower(catalog.play_id) = $1 then 'play_exact'
                when lower(catalog.play_id) like $2 escape '\\' then 'play_prefix'
                when topic_match.any_exact then 'topic_exact'
                else 'topic_prefix'
              end as match_kind,
              case
                when lower(catalog.play_id) = $1 then 0
                when lower(catalog.play_id) like $2 escape '\\' then 1
                when topic_match.intent_exact then 2
                when topic_match.any_exact then 3
                when topic_match.intent_prefix then 4
                else 5
              end as sort_rank
         from feed_catalog_entries catalog
         join play_revisions revision
           on revision.play_id = catalog.play_id
          and revision.revision_id = catalog.revision_id
         left join topic_match
           on topic_match.play_id = catalog.play_id
          and topic_match.revision_id = catalog.revision_id
         left join play_revision_topics link
           on link.play_id = catalog.play_id
          and link.revision_id = catalog.revision_id
        where catalog.state = 'eligible'
          and (
            lower(catalog.play_id) = $1
            or lower(catalog.play_id) like $2 escape '\\'
            or topic_match.play_id is not null
          )
        group by catalog.play_id,
                 catalog.revision_id,
                 revision.document,
                 catalog.quality_prior,
                 catalog.curated_order,
                 topic_match.intent_exact,
                 topic_match.intent_prefix,
                 topic_match.any_exact
        order by sort_rank,
                 catalog.quality_prior desc,
                 catalog.curated_order,
                 catalog.play_id,
                 catalog.revision_id
        limit $4`,
      [normalized, prefix, normalizedIntent, boundedLimit],
    );
    return result.rows.map((row) => ({
      kind: 'play',
      matchKind: row.match_kind,
      sortRank: row.sort_rank,
      candidate: {
        playId: row.play_id,
        revisionId: row.revision_id,
        format: requiredText(row.format ?? '', 'candidate.format'),
        topicIds: row.topic_ids,
        learningTopicIds: row.learning_topic_ids,
        qualityPrior: row.quality_prior,
        curatedOrder: row.curated_order,
        document: row.document,
      },
    }));
  }

  async topicExists(topicId: string): Promise<boolean> {
    const normalized = requiredText(topicId, 'topicId');
    const result = await this.pool.query('select 1 from topics where id = $1', [normalized]);
    return result.rowCount === 1;
  }

  async persistDecision(input: ConsumerSearchDecisionInput): Promise<void> {
    const requestId = requiredText(input.requestId, 'requestId');
    const actorId = requiredText(input.actorId, 'actorId');
    const intent = requiredIntent(input.intent);
    const queryHash = requiredHash(input.queryHash);
    const capabilityFingerprint = requiredText(
      input.capabilityFingerprint,
      'capabilityFingerprint',
    );
    if (input.items.length > MAX_DECISION_RESULTS) {
      throw new RangeError(`search decision cannot exceed ${MAX_DECISION_RESULTS} items.`);
    }
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      await cleanupExpired(client);
      await client.query(
        `insert into consumer_search_decisions (
           request_id, actor_id, intent, query_sha256, capability_fingerprint, result_count
         ) values ($1, $2, $3, $4, $5, $6)`,
        [requestId, actorId, intent, queryHash, capabilityFingerprint, input.items.length],
      );
      for (const [position, item] of input.items.entries()) {
        await client.query(
          `insert into consumer_search_decision_items (
             request_id, position, kind, match_kind, topic_id, play_id, revision_id
           ) values ($1, $2, $3, $4, $5, $6, $7)`,
          item.kind === 'topic'
            ? [requestId, position, item.kind, item.matchKind, item.topicId, null, null]
            : [
                requestId,
                position,
                item.kind,
                item.matchKind,
                null,
                item.playId,
                item.revisionId,
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

  async readDecisionPage(
    requestId: string,
    actorId: string,
    capabilityFingerprint: string,
    offset: number,
    limit: number,
  ): Promise<StoredConsumerSearchDecisionPage | null> {
    const normalizedRequestId = requiredText(requestId, 'requestId');
    const normalizedActorId = requiredText(actorId, 'actorId');
    const normalizedFingerprint = requiredText(capabilityFingerprint, 'capabilityFingerprint');
    const boundedOffset = boundedInteger(offset, 0, MAX_DECISION_RESULTS, 'offset');
    const boundedLimit = boundedInteger(limit, 1, MAX_PAGE_SIZE, 'limit');
    const decision = await this.pool.query<{
      intent: ConsumerSearchIntent;
      query_sha256: string;
      result_count: number;
    }>(
      `select intent, query_sha256, result_count
         from consumer_search_decisions
        where request_id = $1
          and actor_id = $2
          and capability_fingerprint = $3
          and expires_at > now()`,
      [normalizedRequestId, normalizedActorId, normalizedFingerprint],
    );
    const metadata = decision.rows[0];
    if (!metadata) return null;
    const result = await this.pool.query<{
      position: number;
      kind: 'topic' | 'play';
      match_kind: ConsumerSearchMatchKind;
      topic_id: string | null;
      label: string | null;
      play_id: string | null;
      revision_id: string | null;
      document: unknown;
    }>(
      `select item.position,
              item.kind,
              item.match_kind,
              item.topic_id,
              topic.label,
              item.play_id,
              item.revision_id,
              revision.document
         from consumer_search_decision_items item
         left join topics topic on topic.id = item.topic_id
         left join play_revisions revision
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
      intent: metadata.intent,
      queryHash: metadata.query_sha256,
      resultCount: metadata.result_count,
      items: result.rows.map(decodeDecisionItem),
    };
  }
}

function decodeDecisionItem(row: {
  position: number;
  kind: 'topic' | 'play';
  match_kind: ConsumerSearchMatchKind;
  topic_id: string | null;
  label: string | null;
  play_id: string | null;
  revision_id: string | null;
  document: unknown;
}): ConsumerSearchDecisionItem {
  if (row.kind === 'topic') {
    if (row.topic_id === null || row.label === null || !row.match_kind.startsWith('topic_')) {
      throw new Error('Stored topic search result is corrupt.');
    }
    return {
      kind: 'topic',
      position: row.position,
      topicId: row.topic_id,
      label: row.label,
      matchKind: row.match_kind as 'topic_exact' | 'topic_prefix',
    };
  }
  if (row.play_id === null || row.revision_id === null || row.document === null) {
    throw new Error('Stored Play search result is corrupt.');
  }
  return {
    kind: 'play',
    position: row.position,
    playId: row.play_id,
    revisionId: row.revision_id,
    document: row.document,
    matchKind: row.match_kind,
  };
}

async function cleanupExpired(client: PoolClient): Promise<void> {
  await client.query(
    `delete from consumer_search_decisions
      where request_id in (
        select request_id
          from consumer_search_decisions
         where expires_at <= now()
         order by expires_at, request_id
         limit $1
         for update skip locked
      )`,
    [EXPIRED_SEARCH_CLEANUP_BATCH],
  );
}

function requiredQuery(value: string): string {
  if (typeof value !== 'string') throw new TypeError('query must be a string.');
  const normalized = value.normalize('NFKC').trim().replace(/\s+/gu, ' ').toLowerCase();
  if (normalized.length === 0 || normalized.length > 80 || /[\u0000-\u001f\u007f]/u.test(normalized)) {
    throw new TypeError('query must contain 1 to 80 printable characters.');
  }
  return normalized;
}

function requiredIntent(value: ConsumerSearchIntent): ConsumerSearchIntent {
  if (value !== 'interest' && value !== 'learning') {
    throw new TypeError('intent must be interest or learning.');
  }
  return value;
}

function requiredHash(value: string): string {
  if (!/^[0-9a-f]{64}$/.test(value)) throw new TypeError('queryHash must be SHA-256 hex.');
  return value;
}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (match) => `\\${match}`);
}

function requiredText(value: string, name: string, maxLength = 200): string {
  if (typeof value !== 'string') throw new TypeError(`${name} must be a string.`);
  const normalized = value.trim();
  if (normalized.length === 0 || normalized.length > maxLength) {
    throw new TypeError(`${name} must be between 1 and ${maxLength} characters.`);
  }
  return normalized;
}

function boundedInteger(value: number, min: number, max: number, name: string): number {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new RangeError(`${name} must be an integer between ${min} and ${max}.`);
  }
  return value;
}

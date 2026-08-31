import {createHash, randomUUID} from 'node:crypto';
import {checkPlayCompatibility, type ClientCapabilities} from './contracts/compatibility.js';
import {fingerprintCapabilities} from './consumer_feed.js';
import type {ConsumerRepository} from './consumer_repository.js';
import type {
  ConsumerSearchDecisionItemInput,
  ConsumerSearchIntent,
  ConsumerSearchMatchKind,
  ConsumerSearchRepository,
  StoredConsumerSearchDecisionPage,
} from './consumer_search_repository.js';
import type {FeedAssetReadinessResolver} from './feed_asset_readiness.js';
import type {FeedCandidate} from './consumer_ranking.js';

const DEFAULT_PAGE_SIZE = 12;
const MAX_PAGE_SIZE = 20;
const MAX_RESULTS = 60;
const PLAY_CANDIDATE_LIMIT = 100;
const TOPIC_CANDIDATE_LIMIT = 30;
const MAX_CURSOR_LENGTH = 512;

export interface ConsumerSearchRequest {
  actorId: string;
  capabilities: ClientCapabilities;
  query?: string;
  intent?: ConsumerSearchIntent;
  cursor?: string | null;
  limit?: number;
}

export type ConsumerSearchResultItem =
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

export interface ConsumerSearchPage {
  requestId: string;
  intent: ConsumerSearchIntent;
  queryHash: string;
  resultCount: number;
  items: ConsumerSearchResultItem[];
  nextCursor: string | null;
}

export interface ConsumerSearchServiceOptions {
  requestIdFactory?: () => string;
  assetReadiness?: FeedAssetReadinessResolver;
}

export class InvalidSearchCursorError extends Error {
  constructor(message = 'Invalid or expired search cursor.') {
    super(message);
    this.name = 'InvalidSearchCursorError';
  }
}

export class ConsumerSearchService {
  private readonly requestIdFactory: () => string;
  private readonly assetReadiness: FeedAssetReadinessResolver | undefined;

  constructor(
    private readonly searchRepository: ConsumerSearchRepository,
    private readonly consumerRepository: ConsumerRepository,
    options: ConsumerSearchServiceOptions = {},
  ) {
    this.requestIdFactory = options.requestIdFactory ?? randomUUID;
    this.assetReadiness = options.assetReadiness;
  }

  async search(input: ConsumerSearchRequest): Promise<ConsumerSearchPage> {
    const actorId = requiredText(input.actorId, 'actorId');
    const pageSize = boundedInteger(input.limit ?? DEFAULT_PAGE_SIZE, 1, MAX_PAGE_SIZE, 'limit');
    const fingerprint = fingerprintCapabilities(input.capabilities);
    const cursor = input.cursor?.trim();
    if (cursor) {
      const decoded = decodeCursor(cursor);
      const page = await this.searchRepository.readDecisionPage(
        decoded.requestId,
        actorId,
        fingerprint,
        decoded.offset,
        pageSize,
      );
      if (!page) throw new InvalidSearchCursorError();
      return pageFromStored(page, decoded.offset, pageSize);
    }

    const query = normalizeSearchQuery(input.query ?? '');
    const intent = normalizeIntent(input.intent);
    const queryHash = hashQuery(query);
    const profilePromise = this.consumerRepository.getFeedProfile(actorId);
    const topicPromise = this.searchRepository.searchTopics(query, TOPIC_CANDIDATE_LIMIT);
    const playPromise = this.searchRepository.searchPlayCandidates(
      query,
      intent,
      PLAY_CANDIDATE_LIMIT,
    );
    const [profile, topics, playMatches] = await Promise.all([
      profilePromise,
      topicPromise,
      playPromise,
    ]);

    const mutedTopics = normalizedSet(profile.mutedTopicIds);
    const notInterested = new Set(profile.notInterestedPlayIds);
    const compatible = playMatches.filter(({candidate}) =>
      checkPlayCompatibility(candidate.document, input.capabilities).compatible,
    );
    const deliverableCandidates = this.assetReadiness === undefined
      ? compatible.map((item) => item.candidate)
      : await this.assetReadiness.filterDeliverable(compatible.map((item) => item.candidate));
    const deliverableIds = new Set(
      deliverableCandidates.map((candidate) => candidateIdentity(candidate)),
    );
    const plays = compatible.filter(({candidate}) =>
      deliverableIds.has(candidateIdentity(candidate)) &&
      !notInterested.has(candidate.playId) &&
      !candidateTouchesMutedTopic(candidate, mutedTopics),
    );

    const selected = [
      ...topics.map((topic) => ({
        item: topic as ConsumerSearchDecisionItemInput,
        rank: topic.matchKind === 'topic_exact' ? 0 : 20,
        tie: `${topic.label.toLowerCase()}\u0000${topic.topicId}`,
      })),
      ...plays.map((play) => ({
        item: {
          kind: 'play' as const,
          playId: play.candidate.playId,
          revisionId: play.candidate.revisionId,
          matchKind: play.matchKind,
        },
        rank: 2 + play.sortRank * 4,
        tie: `${String(1 - play.candidate.qualityPrior).padStart(8, '0')}\u0000${String(
          play.candidate.curatedOrder,
        ).padStart(8, '0')}\u0000${play.candidate.playId}\u0000${play.candidate.revisionId}`,
      })),
    ]
      .sort((left, right) => left.rank - right.rank || left.tie.localeCompare(right.tie))
      .slice(0, MAX_RESULTS)
      .map(({item}) => item);

    const requestId = requiredText(this.requestIdFactory(), 'requestId');
    await this.searchRepository.persistDecision({
      requestId,
      actorId,
      intent,
      queryHash,
      capabilityFingerprint: fingerprint,
      items: selected,
    });
    const stored = await this.searchRepository.readDecisionPage(
      requestId,
      actorId,
      fingerprint,
      0,
      pageSize,
    );
    if (!stored) throw new Error('Persisted search decision could not be reloaded.');
    return pageFromStored(stored, 0, pageSize);
  }
}

export function normalizeSearchQuery(value: string): string {
  if (typeof value !== 'string') throw new TypeError('query must be a string.');
  const normalized = value.normalize('NFKC').trim().replace(/\s+/gu, ' ').toLowerCase();
  if (
    normalized.length === 0 ||
    normalized.length > 80 ||
    /[\u0000-\u001f\u007f]/u.test(normalized)
  ) {
    throw new TypeError('query must contain 1 to 80 printable characters.');
  }
  return normalized;
}

export function hashQuery(normalizedQuery: string): string {
  return createHash('sha256').update(normalizedQuery, 'utf8').digest('hex');
}

function normalizeIntent(value: ConsumerSearchIntent | undefined): ConsumerSearchIntent {
  if (value !== 'interest' && value !== 'learning') {
    throw new TypeError('intent must be interest or learning.');
  }
  return value;
}

function candidateTouchesMutedTopic(
  candidate: FeedCandidate,
  mutedTopics: ReadonlySet<string>,
): boolean {
  return [...candidate.topicIds, ...candidate.learningTopicIds].some((topicId) =>
    mutedTopics.has(topicId.trim().toLowerCase()),
  );
}

function normalizedSet(values: readonly string[]): ReadonlySet<string> {
  return new Set(values.map((value) => value.trim().toLowerCase()).filter(Boolean));
}

function candidateIdentity(candidate: Pick<FeedCandidate, 'playId' | 'revisionId'>): string {
  return JSON.stringify([candidate.playId, candidate.revisionId]);
}

function pageFromStored(
  page: StoredConsumerSearchDecisionPage,
  offset: number,
  limit: number,
): ConsumerSearchPage {
  const nextOffset = offset + page.items.length;
  return {
    requestId: page.requestId,
    intent: page.intent,
    queryHash: page.queryHash,
    resultCount: page.resultCount,
    items: page.items,
    nextCursor:
      nextOffset < page.resultCount && page.items.length === limit
        ? encodeCursor(page.requestId, nextOffset)
        : null,
  };
}

function encodeCursor(requestId: string, offset: number): string {
  return Buffer.from(JSON.stringify({v: 1, requestId, offset}), 'utf8').toString('base64url');
}

function decodeCursor(value: string): {requestId: string; offset: number} {
  if (value.length > MAX_CURSOR_LENGTH) throw new InvalidSearchCursorError();
  try {
    const decoded = JSON.parse(Buffer.from(value, 'base64url').toString('utf8')) as unknown;
    if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)) {
      throw new InvalidSearchCursorError();
    }
    const cursor = decoded as Record<string, unknown>;
    if (cursor.v !== 1 || typeof cursor.requestId !== 'string') {
      throw new InvalidSearchCursorError();
    }
    return {
      requestId: requiredText(cursor.requestId, 'cursor.requestId'),
      offset: boundedInteger(cursor.offset as number, 0, MAX_RESULTS, 'cursor.offset'),
    };
  } catch (error) {
    if (error instanceof InvalidSearchCursorError) throw error;
    throw new InvalidSearchCursorError();
  }
}

function requiredText(value: string, name: string): string {
  if (typeof value !== 'string') throw new TypeError(`${name} must be a string.`);
  const normalized = value.trim();
  if (normalized.length === 0 || normalized.length > 200) {
    throw new TypeError(`${name} must be between 1 and 200 characters.`);
  }
  return normalized;
}

function boundedInteger(value: number, min: number, max: number, name: string): number {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new RangeError(`${name} must be an integer between ${min} and ${max}.`);
  }
  return value;
}

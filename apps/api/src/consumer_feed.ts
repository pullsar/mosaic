import {createHash, randomUUID} from 'node:crypto';
import {checkPlayCompatibility, type ClientCapabilities} from './contracts/compatibility.js';
import type {ConsumerRepository, StoredFeedDecisionItem} from './consumer_repository.js';
import {
  defaultConsumerRankingConfig,
  rankFeedCandidates,
  type ConsumerRankingConfig,
  type FeedCandidate,
  type FeedSourceBucket,
  type RankedFeedCandidate,
} from './consumer_ranking.js';

const DEFAULT_PAGE_SIZE = 8;
const MAX_PAGE_SIZE = 20;
const DEFAULT_WINDOW_SIZE = 64;
const MAX_WINDOW_SIZE = 100;
const DEFAULT_CANDIDATE_LIMIT = 200;
const MAX_CURSOR_LENGTH = 512;

export interface FeedPageItem {
  playId: string;
  revisionId: string;
  sourceBucket: FeedSourceBucket;
  document: unknown;
}

export interface FeedPage {
  requestId: string;
  rankingConfigVersion: string;
  fallback: boolean;
  items: FeedPageItem[];
  nextCursor: string | null;
}

export interface FeedRequest {
  actorId: string;
  capabilities: ClientCapabilities;
  cursor?: string | null;
  limit?: number;
}

export interface ConsumerFeedServiceOptions {
  rankingConfig?: ConsumerRankingConfig;
  windowSize?: number;
  candidateLimit?: number;
  requestIdFactory?: () => string;
  onRankingError?: (error: unknown) => void;
}

export class InvalidFeedCursorError extends Error {
  constructor(message = 'Invalid or expired feed cursor.') {
    super(message);
    this.name = 'InvalidFeedCursorError';
  }
}

export class ConsumerFeedService {
  private readonly rankingConfig: ConsumerRankingConfig;
  private readonly windowSize: number;
  private readonly candidateLimit: number;
  private readonly requestIdFactory: () => string;
  private readonly onRankingError: ((error: unknown) => void) | undefined;

  constructor(
    private readonly repository: ConsumerRepository,
    options: ConsumerFeedServiceOptions = {},
  ) {
    this.rankingConfig = options.rankingConfig ?? defaultConsumerRankingConfig;
    this.windowSize = boundedInteger(
      options.windowSize ?? DEFAULT_WINDOW_SIZE,
      1,
      MAX_WINDOW_SIZE,
      'windowSize',
    );
    this.candidateLimit = boundedInteger(
      options.candidateLimit ?? DEFAULT_CANDIDATE_LIMIT,
      this.windowSize,
      500,
      'candidateLimit',
    );
    this.requestIdFactory = options.requestIdFactory ?? randomUUID;
    this.onRankingError = options.onRankingError;
  }

  async getFeed(input: FeedRequest): Promise<FeedPage> {
    const actorId = requiredText(input.actorId, 'actorId');
    const pageSize = boundedInteger(input.limit ?? DEFAULT_PAGE_SIZE, 1, MAX_PAGE_SIZE, 'limit');
    const fingerprint = fingerprintCapabilities(input.capabilities);
    const cursor = input.cursor?.trim();
    if (cursor) {
      const decoded = decodeCursor(cursor);
      const page = await this.repository.readFeedDecisionPage(
        decoded.requestId,
        actorId,
        fingerprint,
        decoded.offset,
        pageSize,
      );
      if (!page) throw new InvalidFeedCursorError();
      return pageFromStored(page, decoded.offset, pageSize);
    }

    const preferences = await this.repository.getTopicPreferences(actorId);
    const candidates = await this.repository.listEligibleFeedCandidates(this.candidateLimit);
    const compatible = candidates.filter(
      (candidate) => checkPlayCompatibility(candidate.document, input.capabilities).compatible,
    );

    let rankingFallback = false;
    let ranked: RankedFeedCandidate[];
    try {
      ranked = rankFeedCandidates(compatible, preferences, this.rankingConfig);
    } catch (error) {
      rankingFallback = true;
      this.reportRankingError(error);
      ranked = curatedFallbackCandidates(compatible);
    }

    const window = selectFeedWindow(ranked, this.windowSize);
    const fallback =
      rankingFallback ||
      window.length === 0 ||
      window.every((item) => item.sourceBucket !== 'known');
    const requestId = requiredText(this.requestIdFactory(), 'requestId');

    await this.repository.persistFeedDecision({
      requestId,
      actorId,
      rankingConfigVersion: this.rankingConfig.version,
      capabilityFingerprint: fingerprint,
      fallback,
      ranked: window,
    });
    const stored = await this.repository.readFeedDecisionPage(
      requestId,
      actorId,
      fingerprint,
      0,
      pageSize,
    );
    if (!stored) throw new Error('Persisted feed decision could not be reloaded.');
    return pageFromStored(stored, 0, pageSize);
  }

  private reportRankingError(error: unknown): void {
    try {
      this.onRankingError?.(error);
    } catch {
      // Observability must not become another feed failure mode.
    }
  }
}

export function fingerprintCapabilities(capabilities: ClientCapabilities): string {
  const normalized = {
    schemaVersions: uniqueSortedNumbers(capabilities.schemaVersions),
    presentationTypes: uniqueSortedStrings(capabilities.presentationTypes),
    inputTypes: uniqueSortedStrings(capabilities.inputTypes),
    validatorTypes: uniqueSortedStrings(capabilities.validatorTypes),
    platformFlags: uniqueSortedStrings(capabilities.platformFlags),
  };
  return createHash('sha256').update(JSON.stringify(normalized)).digest('hex');
}

export function selectFeedWindow(
  ranked: readonly RankedFeedCandidate[],
  windowSize: number,
): RankedFeedCandidate[] {
  const boundedWindow = boundedInteger(windowSize, 1, MAX_WINDOW_SIZE, 'windowSize');
  const selected = ranked.slice(0, boundedWindow);
  if (selected.length < 2 || selected.some((item) => item.sourceBucket === 'wildcard')) {
    return selected;
  }
  const wildcard = ranked.find((item) => item.sourceBucket === 'wildcard');
  if (!wildcard) return selected;
  return [...selected.slice(0, -1), wildcard];
}

function curatedFallbackCandidates(candidates: readonly FeedCandidate[]): RankedFeedCandidate[] {
  return [...candidates]
    .sort((left, right) => {
      const curated = left.curatedOrder - right.curatedOrder;
      if (curated !== 0) return curated;
      const play = left.playId.localeCompare(right.playId);
      return play !== 0 ? play : left.revisionId.localeCompare(right.revisionId);
    })
    .map(
      (candidate, index): RankedFeedCandidate => ({
        ...candidate,
        rank: index + 1,
        sourceBucket: 'curated_fallback',
        score: 0,
        featureContributions: Object.freeze({}),
      }),
    );
}

function pageFromStored(
  page: {
    requestId: string;
    rankingConfigVersion: string;
    fallback: boolean;
    candidateCount: number;
    items: StoredFeedDecisionItem[];
  },
  offset: number,
  limit: number,
): FeedPage {
  const nextOffset = offset + page.items.length;
  return {
    requestId: page.requestId,
    rankingConfigVersion: page.rankingConfigVersion,
    fallback: page.fallback,
    items: page.items.map((item) => ({
      playId: item.playId,
      revisionId: item.revisionId,
      sourceBucket: item.sourceBucket,
      document: item.document,
    })),
    nextCursor:
      nextOffset < page.candidateCount && page.items.length === limit
        ? encodeCursor(page.requestId, nextOffset)
        : null,
  };
}

function encodeCursor(requestId: string, offset: number): string {
  return Buffer.from(JSON.stringify({v: 1, requestId, offset}), 'utf8').toString('base64url');
}

function decodeCursor(value: string): {requestId: string; offset: number} {
  if (value.length > MAX_CURSOR_LENGTH) throw new InvalidFeedCursorError();
  try {
    const decoded = JSON.parse(Buffer.from(value, 'base64url').toString('utf8')) as unknown;
    if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)) {
      throw new InvalidFeedCursorError();
    }
    const cursor = decoded as Record<string, unknown>;
    if (cursor.v !== 1 || typeof cursor.requestId !== 'string') {
      throw new InvalidFeedCursorError();
    }
    return {
      requestId: requiredText(cursor.requestId, 'cursor.requestId'),
      offset: boundedInteger(cursor.offset as number, 0, MAX_WINDOW_SIZE, 'cursor.offset'),
    };
  } catch (error) {
    if (error instanceof InvalidFeedCursorError) throw error;
    throw new InvalidFeedCursorError();
  }
}

function uniqueSortedStrings(values: readonly string[]): string[] {
  if (!Array.isArray(values) || values.some((value) => typeof value !== 'string')) {
    throw new TypeError('Capability values must be string arrays.');
  }
  return [...new Set(values.map((value) => value.trim()).filter(Boolean))].sort();
}

function uniqueSortedNumbers(values: readonly number[]): number[] {
  if (!Array.isArray(values) || values.some((value) => !Number.isInteger(value))) {
    throw new TypeError('schemaVersions must contain integers.');
  }
  return [...new Set(values)].sort((left, right) => left - right);
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

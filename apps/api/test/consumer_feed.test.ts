import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  ConsumerFeedService,
  fingerprintCapabilities,
  InvalidFeedCursorError,
  selectFeedWindow,
} from '../src/consumer_feed.js';
import type {
  ConsumerRepository,
  FeedDecisionInput,
  StoredFeedDecisionPage,
  TopicPreferences,
  TopicSummary,
} from '../src/consumer_repository.js';
import type {FeedCandidate, RankedFeedCandidate} from '../src/consumer_ranking.js';

const capabilities = {
  schemaVersions: [1],
  presentationTypes: ['text'],
  inputTypes: ['tap'],
  validatorTypes: ['none'],
  platformFlags: [],
};

function playDocument(
  id: string,
  revisionId: string,
  presentationType = 'text',
): Record<string, unknown> {
  return {
    schemaVersion: 1,
    id,
    revisionId,
    format: 'choose',
    states: {
      start: {
        presentation: {layers: [{type: presentationType}]},
        input: {type: 'tap'},
        validation: {type: 'none'},
        transition: {default: '$end'},
      },
    },
  };
}

function candidate(
  playId: string,
  revisionId: string,
  options: {
    topicIds?: string[];
    learningTopicIds?: string[];
    curatedOrder?: number;
    presentationType?: string;
  } = {},
): FeedCandidate {
  return {
    playId,
    revisionId,
    format: 'choose',
    topicIds: options.topicIds ?? [],
    learningTopicIds: options.learningTopicIds ?? [],
    qualityPrior: 0.5,
    curatedOrder: options.curatedOrder ?? 100,
    document: playDocument(playId, revisionId, options.presentationType),
  };
}

class MemoryConsumerRepository implements ConsumerRepository {
  preferences: TopicPreferences = {interestTopicIds: [], learningTopicIds: []};
  candidates: FeedCandidate[] = [];
  decisions = new Map<
    string,
    FeedDecisionInput & {documents: Map<string, unknown>}
  >();

  async searchTopics(): Promise<TopicSummary[]> {
    return [];
  }

  async replaceTopicPreferences(
    _actorId: string,
    interestTopicIds: readonly string[],
    learningTopicIds: readonly string[],
  ): Promise<void> {
    this.preferences = {
      interestTopicIds: [...interestTopicIds],
      learningTopicIds: [...learningTopicIds],
    };
  }

  async getTopicPreferences(): Promise<TopicPreferences> {
    return this.preferences;
  }

  async listEligibleFeedCandidates(limit = 200): Promise<FeedCandidate[]> {
    return this.candidates.slice(0, limit);
  }

  async persistFeedDecision(input: FeedDecisionInput): Promise<void> {
    const documents = new Map(
      this.candidates.map((item) => [
        `${item.playId}\u0000${item.revisionId}`,
        item.document,
      ]),
    );
    this.decisions.set(input.requestId, {...input, documents});
  }

  async readFeedDecisionPage(
    requestId: string,
    actorId: string,
    capabilityFingerprint: string,
    offset: number,
    limit: number,
  ): Promise<StoredFeedDecisionPage | null> {
    const decision = this.decisions.get(requestId);
    if (
      !decision ||
      decision.actorId !== actorId ||
      decision.capabilityFingerprint !== capabilityFingerprint
    ) {
      return null;
    }
    return {
      requestId,
      rankingConfigVersion: decision.rankingConfigVersion,
      fallback: decision.fallback,
      candidateCount: decision.ranked.length,
      items: decision.ranked.slice(offset, offset + limit).map((item, index) => ({
        position: offset + index,
        playId: item.playId,
        revisionId: item.revisionId,
        sourceBucket: item.sourceBucket,
        score: item.score,
        featureContributions: {...item.featureContributions},
        document: decision.documents.get(`${item.playId}\u0000${item.revisionId}`),
      })),
    };
  }
}

test('capability fingerprint is canonical but changes with supported surface', () => {
  const first = fingerprintCapabilities({
    ...capabilities,
    presentationTypes: ['text', 'canvas', 'text'],
    schemaVersions: [1, 2, 1],
  });
  const reordered = fingerprintCapabilities({
    ...capabilities,
    presentationTypes: ['canvas', 'text'],
    schemaVersions: [2, 1],
  });
  const changed = fingerprintCapabilities({
    ...capabilities,
    presentationTypes: ['text'],
    schemaVersions: [2, 1],
  });
  assert.equal(first, reordered);
  assert.notEqual(first, changed);
});

test('feed filters incompatible revisions before persistence and paginates one decision', async () => {
  const repository = new MemoryConsumerRepository();
  repository.preferences = {interestTopicIds: ['travel'], learningTopicIds: []};
  repository.candidates = [
    candidate('known', 'r1', {topicIds: ['travel'], curatedOrder: 1}),
    candidate('unsupported', 'r2', {
      topicIds: ['travel'],
      curatedOrder: 2,
      presentationType: 'map',
    }),
    candidate('wildcard', 'r3', {topicIds: ['music'], curatedOrder: 3}),
  ];
  const service = new ConsumerFeedService(repository, {
    windowSize: 2,
    candidateLimit: 3,
    requestIdFactory: () => 'feed_request',
  });

  const first = await service.getFeed({actorId: 'actor_a', capabilities, limit: 1});
  assert.equal(first.requestId, 'feed_request');
  assert.deepEqual(first.items.map((item) => item.playId), ['known']);
  assert.ok(first.nextCursor);
  assert.deepEqual(
    repository.decisions.get('feed_request')?.ranked.map((item) => item.playId),
    ['known', 'wildcard'],
  );

  const second = await service.getFeed({
    actorId: 'actor_a',
    capabilities,
    cursor: first.nextCursor,
    limit: 1,
  });
  assert.deepEqual(second.items.map((item) => item.playId), ['wildcard']);
  assert.equal(second.nextCursor, null);

  await assert.rejects(
    service.getFeed({
      actorId: 'actor_a',
      capabilities: {...capabilities, presentationTypes: ['text', 'canvas']},
      cursor: first.nextCursor,
      limit: 1,
    }),
    InvalidFeedCursorError,
  );
});

test('ranking errors fall back to compatible curated order without blocking feed', async () => {
  const repository = new MemoryConsumerRepository();
  repository.candidates = [
    candidate('later', 'r2', {curatedOrder: 20}),
    candidate('first', 'r1', {curatedOrder: 10}),
  ];
  const errors: unknown[] = [];
  const service = new ConsumerFeedService(repository, {
    rankingConfig: {
      version: 'invalid-test-config',
      weights: {
        interestAffinity: -1,
        learningAffinity: 1,
        interactionAffinity: 1,
        qualityPrior: 1,
        explorationBonus: 1,
        moreLikeThisAffinity: 1,
        recentSeenPenalty: 1,
        repeatedTopicDismissalPenalty: 1,
        repeatedFormatDismissalPenalty: 1,
      },
    },
    windowSize: 2,
    candidateLimit: 2,
    requestIdFactory: () => 'fallback_request',
    onRankingError: (error) => errors.push(error),
  });

  const page = await service.getFeed({actorId: 'actor_b', capabilities, limit: 2});
  assert.equal(page.fallback, true);
  assert.deepEqual(page.items.map((item) => item.playId), ['first', 'later']);
  assert.deepEqual(page.items.map((item) => item.sourceBucket), [
    'curated_fallback',
    'curated_fallback',
  ]);
  assert.equal(errors.length, 1);
});

test('feed window introduces one wildcard only when top window lacks exploration', () => {
  const ranked = [
    rankedCandidate('known_a', 1, 'known'),
    rankedCandidate('known_b', 2, 'known'),
    rankedCandidate('wild', 3, 'wildcard'),
  ];
  assert.deepEqual(
    selectFeedWindow(ranked, 2).map((item) => item.playId),
    ['known_a', 'wild'],
  );
  assert.deepEqual(
    selectFeedWindow(ranked.slice(0, 2), 2).map((item) => item.playId),
    ['known_a', 'known_b'],
  );
});

function rankedCandidate(
  playId: string,
  rank: number,
  sourceBucket: RankedFeedCandidate['sourceBucket'],
): RankedFeedCandidate {
  return {
    ...candidate(playId, `r${rank}`, {curatedOrder: rank}),
    rank,
    sourceBucket,
    score: 10 - rank,
    featureContributions: {},
  };
}

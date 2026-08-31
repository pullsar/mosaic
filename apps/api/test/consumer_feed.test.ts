import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  ConsumerFeedService,
  fingerprintCapabilities,
  InvalidFeedCursorError,
  selectFeedWindow,
} from '../src/consumer_feed.js';
import type {
  ConsumerActionState,
  ConsumerRepository,
  FeedConsumerProfile,
  FeedDecisionInput,
  StoredFeedDecisionPage,
  TopicPreferences,
  TopicSummary,
} from '../src/consumer_repository.js';
import type {FeedAssetReadinessResolver} from '../src/feed_asset_readiness.js';
import {feedCandidateIdentity, type FeedCandidate, type RankedFeedCandidate} from '../src/consumer_ranking.js';

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
  mutedTopicIds: string[] = [];
  notInterestedPlayIds: string[] = [];
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

  async getFeedProfile(): Promise<FeedConsumerProfile> {
    return {
      ...this.preferences,
      mutedTopicIds: [...this.mutedTopicIds],
      notInterestedPlayIds: [...this.notInterestedPlayIds],
    };
  }

  async getActionState(_actorId: string, playId: string): Promise<ConsumerActionState> {
    return {
      play: {
        playId,
        saved: false,
        savedRevisionId: null,
        moreLikeThis: false,
        notInterested: this.notInterestedPlayIds.includes(playId),
      },
      mutedTopicIds: [...this.mutedTopicIds],
    };
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

class SelectiveAssetReadiness implements FeedAssetReadinessResolver {
  calls = 0;

  constructor(private readonly blockedPlayIds: ReadonlySet<string>) {}

  async filterDeliverable(
    candidates: readonly FeedCandidate[],
  ): Promise<FeedCandidate[]> {
    this.calls += 1;
    return candidates.filter((item) => !this.blockedPlayIds.has(item.playId));
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

test('compatible but known-undeliverable candidates are removed before ranking and persistence', async () => {
  const repository = new MemoryConsumerRepository();
  repository.preferences = {interestTopicIds: ['travel'], learningTopicIds: []};
  repository.candidates = [
    candidate('ready', 'r1', {topicIds: ['travel'], curatedOrder: 1}),
    candidate('not_ready', 'r2', {topicIds: ['travel'], curatedOrder: 2}),
  ];
  const readiness = new SelectiveAssetReadiness(new Set(['not_ready']));
  const service = new ConsumerFeedService(repository, {
    windowSize: 2,
    candidateLimit: 2,
    requestIdFactory: () => 'readiness_request',
    assetReadiness: readiness,
  });

  const page = await service.getFeed({
    actorId: 'actor_ready',
    capabilities,
    limit: 2,
  });
  assert.equal(readiness.calls, 1);
  assert.deepEqual(page.items.map((item) => item.playId), ['ready']);
  assert.deepEqual(
    repository.decisions.get('readiness_request')?.ranked.map((item) => item.playId),
    ['ready'],
  );
});

test('Not interested and muted topics are excluded before ranking and persistence', async () => {
  const repository = new MemoryConsumerRepository();
  repository.preferences = {interestTopicIds: ['travel'], learningTopicIds: []};
  repository.notInterestedPlayIds = ['dismissed'];
  repository.mutedTopicIds = ['music'];
  repository.candidates = [
    candidate('kept', 'r1', {topicIds: ['travel'], curatedOrder: 1}),
    candidate('dismissed', 'r2', {topicIds: ['travel'], curatedOrder: 2}),
    candidate('muted', 'r3', {topicIds: ['music'], curatedOrder: 3}),
  ];
  const service = new ConsumerFeedService(repository, {
    windowSize: 3,
    candidateLimit: 3,
    requestIdFactory: () => 'actions_request',
  });

  const page = await service.getFeed({actorId: 'actor_actions', capabilities, limit: 3});
  assert.deepEqual(page.items.map((item) => item.playId), ['kept']);
  assert.deepEqual(
    repository.decisions.get('actions_request')?.ranked.map((item) => item.playId),
    ['kept'],
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
        searchIntentAffinity: 1,
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

test('derived ranking profile changes a fresh decision without changing explicit preferences', async () => {
  const repository = new MemoryConsumerRepository();
  repository.candidates = [
    candidate('seen', 'r1', {curatedOrder: 1}),
    candidate('fresh', 'r2', {curatedOrder: 2}),
  ];
  const projector = {
    projectActor: async (_actorId: string) => 0,
    readActorProfile: async (_actorId: string) => ({
      interactionAffinity: {},
      recentPlayRevisionKeys: [feedCandidateIdentity('seen', 'r1')],
      topicDismissalCounts: {},
      formatDismissalCounts: {},
      moreLikeTopicIds: [],
    }),
    rebuildActor: async (_actorId: string) => 0,
  };
  const service = new ConsumerFeedService(repository, {
    windowSize: 2,
    candidateLimit: 2,
    requestIdFactory: () => 'derived_request',
    signalProjector: projector,
  });

  const page = await service.getFeed({actorId: 'actor_derived', capabilities, limit: 2});
  assert.deepEqual(page.items.map((item) => item.playId), ['fresh', 'seen']);
});

test('projection failure falls back to explicit profile without blocking feed', async () => {
  const repository = new MemoryConsumerRepository();
  repository.preferences = {interestTopicIds: ['travel'], learningTopicIds: []};
  repository.candidates = [
    candidate('travel', 'r1', {topicIds: ['travel'], curatedOrder: 2}),
    candidate('other', 'r2', {topicIds: ['music'], curatedOrder: 1}),
  ];
  const errors: unknown[] = [];
  const projector = {
    projectActor: async (_actorId: string) => {
      throw new Error('projection unavailable');
    },
    readActorProfile: async (_actorId: string) => {
      throw new Error('must not be reached');
    },
    rebuildActor: async (_actorId: string) => 0,
  };
  const service = new ConsumerFeedService(repository, {
    windowSize: 2,
    candidateLimit: 2,
    requestIdFactory: () => 'profile_fallback_request',
    signalProjector: projector,
    onProfileError: (error) => errors.push(error),
  });

  const page = await service.getFeed({actorId: 'actor_profile_fallback', capabilities, limit: 2});
  assert.equal(page.items[0]?.playId, 'travel');
  assert.equal(errors.length, 1);
});

test('scoped search intent boosts one fresh decision without mutating preferences', async () => {
  const repository = new MemoryConsumerRepository();
  repository.preferences = {interestTopicIds: ['music'], learningTopicIds: []};
  repository.candidates = [
    candidate('music', 'r1', {topicIds: ['music'], curatedOrder: 1}),
    candidate('travel', 'r2', {topicIds: ['travel'], curatedOrder: 2}),
  ];
  const service = new ConsumerFeedService(repository, {
    windowSize: 2,
    candidateLimit: 2,
    requestIdFactory: () => 'search_scoped_feed',
    searchTopicExists: async (topicId) => topicId === 'travel',
  });

  const page = await service.getFeed({
    actorId: 'actor_search_scope',
    capabilities,
    limit: 2,
    searchIntent: {kind: 'interest', topicId: 'travel'},
  });
  assert.equal(page.items[0]?.playId, 'travel');
  assert.deepEqual(repository.preferences, {
    interestTopicIds: ['music'],
    learningTopicIds: [],
  });
  const ranked = repository.decisions.get('search_scoped_feed')?.ranked;
  assert.ok(ranked);
  assert.ok((ranked[0]?.featureContributions.searchIntentAffinity ?? 0) > 0);
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

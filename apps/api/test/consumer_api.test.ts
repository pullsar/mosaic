import assert from 'node:assert/strict';
import {test} from 'node:test';
import {buildApp} from '../src/app.js';
import {
  type ConsumerRepository,
  type FeedDecisionInput,
  type StoredFeedDecisionPage,
  type TopicPreferences,
  type TopicSummary,
  UnknownTopicError,
} from '../src/consumer_repository.js';
import type {FeedCandidate} from '../src/consumer_ranking.js';
import type {
  ActorAccessRegistration,
  EventInput,
  MosaicRepository,
} from '../src/repository.js';

const actorToken = 'A'.repeat(43);
const otherToken = 'B'.repeat(43);
const actorAuthorization = {authorization: `Bearer ${actorToken}`};
const capabilities = {
  schemaVersions: [1],
  presentationTypes: ['text'],
  inputTypes: ['tap'],
  validatorTypes: ['none'],
  platformFlags: [],
};

class CoreRepository implements MosaicRepository {
  actors = new Set<string>();
  credentials = new Map<string, string>();

  async ping(): Promise<void> {}
  async createActor(actorId: string): Promise<void> {
    this.actors.add(actorId);
  }
  async registerActorAccess(
    actorId: string,
    credentialDigest: string,
  ): Promise<ActorAccessRegistration> {
    const existing = this.credentials.get(actorId);
    if (existing !== undefined) return existing === credentialDigest ? 'existing' : 'credential_conflict';
    if (this.actors.has(actorId)) return 'legacy_actor_requires_rotation';
    this.actors.add(actorId);
    this.credentials.set(actorId, credentialDigest);
    return 'created';
  }
  async verifyActorAccess(actorId: string, credentialDigest: string): Promise<boolean> {
    return this.credentials.get(actorId) === credentialDigest;
  }
  async bindActorToUser(): Promise<void> {}
  async getPlayRevision(): Promise<unknown | null> {
    return null;
  }
  async insertEvent(_event: EventInput): Promise<'inserted' | 'duplicate'> {
    return 'inserted';
  }
}

class ConsumerMemoryRepository implements ConsumerRepository {
  readonly topics = new Map<string, string>([
    ['travel', 'Travel'],
    ['piano', 'Piano'],
  ]);
  preferences = new Map<string, TopicPreferences>();
  decisions = new Map<string, FeedDecisionInput>();
  candidates: FeedCandidate[] = [
    {
      playId: 'play_travel',
      revisionId: 'rev_1',
      format: 'choose',
      topicIds: ['travel'],
      learningTopicIds: [],
      qualityPrior: 0.8,
      curatedOrder: 1,
      document: {
        schemaVersion: 1,
        id: 'play_travel',
        revisionId: 'rev_1',
        format: 'choose',
        states: {
          start: {
            presentation: {layers: [{type: 'text'}]},
            input: {type: 'tap'},
            validation: {type: 'none'},
            transition: {default: '$end'},
          },
        },
      },
    },
  ];

  async searchTopics(query: string, limit = 30): Promise<TopicSummary[]> {
    const normalized = query.toLowerCase();
    return [...this.topics.entries()]
      .filter(([id, label]) =>
        normalized.length === 0 ||
        id.includes(normalized) ||
        label.toLowerCase().includes(normalized),
      )
      .slice(0, limit)
      .map(([id, label]) => ({id, label}));
  }

  async replaceTopicPreferences(
    actorId: string,
    interestTopicIds: readonly string[],
    learningTopicIds: readonly string[],
  ): Promise<void> {
    const unknown = [...interestTopicIds, ...learningTopicIds].filter(
      (topicId) => !this.topics.has(topicId),
    );
    if (unknown.length > 0) throw new UnknownTopicError(unknown);
    this.preferences.set(actorId, {
      interestTopicIds: [...new Set(interestTopicIds)].sort(),
      learningTopicIds: [...new Set(learningTopicIds)].sort(),
    });
  }

  async getTopicPreferences(actorId: string): Promise<TopicPreferences> {
    return (
      this.preferences.get(actorId) ?? {
        interestTopicIds: [],
        learningTopicIds: [],
      }
    );
  }

  async listEligibleFeedCandidates(limit = 200): Promise<FeedCandidate[]> {
    return this.candidates.slice(0, limit);
  }

  async persistFeedDecision(input: FeedDecisionInput): Promise<void> {
    this.decisions.set(input.requestId, input);
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
    const items = decision.ranked.slice(offset, offset + limit).map((item, index) => ({
      position: offset + index,
      playId: item.playId,
      revisionId: item.revisionId,
      sourceBucket: item.sourceBucket,
      score: item.score,
      featureContributions: {...item.featureContributions},
      document: item.document,
    }));
    return {
      requestId,
      rankingConfigVersion: decision.rankingConfigVersion,
      fallback: decision.fallback,
      candidateCount: decision.ranked.length,
      items,
    };
  }
}

test('anonymous topic preferences and feed require the current actor credential', async () => {
  const coreRepository = new CoreRepository();
  const consumerRepository = new ConsumerMemoryRepository();
  const app = buildApp({
    repository: coreRepository,
    consumerRepository,
    logLevel: 'silent',
  });

  const register = await app.inject({
    method: 'POST',
    url: '/v1/actors',
    headers: actorAuthorization,
    payload: {actorId: 'actor_a'},
  });
  assert.equal(register.statusCode, 201);

  const topics = await app.inject({method: 'GET', url: '/v1/topics?q=trav&limit=10'});
  assert.equal(topics.statusCode, 200);
  assert.deepEqual(topics.json(), {topics: [{id: 'travel', label: 'Travel'}]});

  const unauthenticatedReplace = await app.inject({
    method: 'PUT',
    url: '/v1/actors/actor_a/preferences',
    payload: {interestTopicIds: ['travel'], learningTopicIds: ['piano']},
  });
  assert.equal(unauthenticatedReplace.statusCode, 401);

  const spoofedReplace = await app.inject({
    method: 'PUT',
    url: '/v1/actors/actor_a/preferences',
    headers: {authorization: `Bearer ${otherToken}`},
    payload: {interestTopicIds: ['travel'], learningTopicIds: ['piano']},
  });
  assert.equal(spoofedReplace.statusCode, 403);

  const replace = await app.inject({
    method: 'PUT',
    url: '/v1/actors/actor_a/preferences',
    headers: actorAuthorization,
    payload: {interestTopicIds: ['travel'], learningTopicIds: ['piano']},
  });
  assert.equal(replace.statusCode, 204);

  const preferences = await app.inject({
    method: 'GET',
    url: '/v1/actors/actor_a/preferences',
    headers: actorAuthorization,
  });
  assert.equal(preferences.statusCode, 200);
  assert.deepEqual(preferences.json(), {
    interestTopicIds: ['travel'],
    learningTopicIds: ['piano'],
  });

  const unknown = await app.inject({
    method: 'PUT',
    url: '/v1/actors/actor_a/preferences',
    headers: actorAuthorization,
    payload: {interestTopicIds: ['missing'], learningTopicIds: []},
  });
  assert.equal(unknown.statusCode, 400);
  assert.deepEqual(unknown.json(), {error: 'unknown_topic', topicIds: ['missing']});

  const feed = await app.inject({
    method: 'POST',
    url: '/v1/feed',
    headers: actorAuthorization,
    payload: {actorId: 'actor_a', capabilities, limit: 8},
  });
  assert.equal(feed.statusCode, 200);
  assert.equal(feed.json().rankingConfigVersion, 'm2-rules-v1');
  assert.deepEqual(feed.json().items.map((item: {playId: string}) => item.playId), [
    'play_travel',
  ]);

  const spoofedFeed = await app.inject({
    method: 'POST',
    url: '/v1/feed',
    headers: {authorization: `Bearer ${otherToken}`},
    payload: {actorId: 'actor_a', capabilities, limit: 8},
  });
  assert.equal(spoofedFeed.statusCode, 403);

  const invalidCapabilities = await app.inject({
    method: 'POST',
    url: '/v1/feed',
    headers: actorAuthorization,
    payload: {
      actorId: 'actor_a',
      capabilities: {...capabilities, schemaVersions: [0]},
    },
  });
  assert.equal(invalidCapabilities.statusCode, 400);
  assert.deepEqual(invalidCapabilities.json(), {error: 'invalid_feed_request'});

  const invalidCursor = await app.inject({
    method: 'POST',
    url: '/v1/feed',
    headers: actorAuthorization,
    payload: {actorId: 'actor_a', capabilities, cursor: 'not-a-cursor'},
  });
  assert.equal(invalidCursor.statusCode, 400);
  assert.deepEqual(invalidCursor.json(), {error: 'invalid_feed_cursor'});

  await app.close();
});

import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  defaultConsumerRankingConfig,
  feedCandidateIdentity,
  rankFeedCandidates,
  type FeedCandidate,
} from '../src/consumer_ranking.js';

function candidate(
  id: string,
  options: Partial<Omit<FeedCandidate, 'playId' | 'revisionId' | 'document'>> = {},
): FeedCandidate {
  return {
    playId: `play_${id}`,
    revisionId: `rev_${id}`,
    format: options.format ?? 'guess',
    topicIds: options.topicIds ?? [],
    learningTopicIds: options.learningTopicIds ?? [],
    qualityPrior: options.qualityPrior ?? 0.6,
    curatedOrder: options.curatedOrder ?? 100,
    document: {id: `play_${id}`, revisionId: `rev_${id}`},
  };
}

test('interest and learning intent remain separately inspectable ranking signals', () => {
  const candidates = [
    candidate('travel', {topicIds: ['travel']}),
    candidate('piano', {learningTopicIds: ['piano']}),
  ];

  const interest = rankFeedCandidates(candidates, {
    interestTopicIds: ['travel'],
    learningTopicIds: [],
  });
  assert.equal(interest[0]?.playId, 'play_travel');
  assert.equal(interest[0]?.featureContributions.interestAffinity, 1);
  assert.equal(interest[0]?.featureContributions.learningAffinity, 0);

  const learning = rankFeedCandidates(candidates, {
    interestTopicIds: [],
    learningTopicIds: ['piano'],
  });
  assert.equal(learning[0]?.playId, 'play_piano');
  assert.equal(learning[0]?.featureContributions.interestAffinity, 0);
  assert.equal(
    learning[0]?.featureContributions.learningAffinity,
    defaultConsumerRankingConfig.weights.learningAffinity,
  );
});

test('one dismissal is weak evidence while repeated dismissal suppresses the topic', () => {
  const candidates = [
    candidate('travel', {topicIds: ['travel'], qualityPrior: 0.8}),
    candidate('food', {topicIds: ['food'], qualityPrior: 0.7}),
  ];
  const once = rankFeedCandidates(candidates, {
    interestTopicIds: ['travel'],
    learningTopicIds: [],
    topicDismissalCounts: {travel: 1},
  });
  assert.equal(once[0]?.playId, 'play_travel');
  assert.equal(once[0]?.featureContributions.repeatedTopicDismissalPenalty, 0);

  const repeated = rankFeedCandidates(candidates, {
    interestTopicIds: ['travel'],
    learningTopicIds: [],
    topicDismissalCounts: {travel: 4},
  });
  assert.equal(repeated[0]?.playId, 'play_food');
  assert.ok(
    (repeated.find((item) => item.playId === 'play_travel')?.featureContributions
      .repeatedTopicDismissalPenalty ?? 0) < 0,
  );
});

test('More Like This is an explicit affinity independent of save state', () => {
  const candidates = [
    candidate('art', {topicIds: ['art'], qualityPrior: 0.55}),
    candidate('travel', {topicIds: ['travel'], qualityPrior: 0.65}),
  ];
  const ranked = rankFeedCandidates(candidates, {
    interestTopicIds: [],
    learningTopicIds: [],
    moreLikeTopicIds: ['art'],
  });

  assert.equal(ranked[0]?.playId, 'play_art');
  assert.equal(
    ranked[0]?.featureContributions.moreLikeThisAffinity,
    defaultConsumerRankingConfig.weights.moreLikeThisAffinity,
  );
});

test('recent fatigue keys include both Play and revision identity', () => {
  const first = candidate('first', {qualityPrior: 0.8, curatedOrder: 10});
  const second = candidate('second', {qualityPrior: 0.7, curatedOrder: 20});
  second.revisionId = first.revisionId;

  const ranked = rankFeedCandidates([first, second], {
    interestTopicIds: [],
    learningTopicIds: [],
    recentPlayRevisionKeys: [feedCandidateIdentity(first.playId, first.revisionId)],
  });

  assert.equal(
    ranked.find((item) => item.playId === first.playId)?.featureContributions.recentSeenPenalty,
    -defaultConsumerRankingConfig.weights.recentSeenPenalty,
  );
  assert.equal(
    ranked.find((item) => item.playId === second.playId)?.featureContributions.recentSeenPenalty,
    0,
  );
});

test('recent fatigue is scoped to the exact Play plus revision identity', () => {
  const sharedRevision = 'shared_revision';
  const seen = candidate('seen', {qualityPrior: 0.7, curatedOrder: 1});
  const other = candidate('other', {qualityPrior: 0.7, curatedOrder: 2});
  seen.revisionId = sharedRevision;
  other.revisionId = sharedRevision;

  const ranked = rankFeedCandidates([seen, other], {
    interestTopicIds: [],
    learningTopicIds: [],
    recentPlayRevisionKeys: [JSON.stringify([seen.playId, sharedRevision])],
  });

  assert.equal(ranked[0]?.playId, other.playId);
  assert.equal(
    ranked.find((item) => item.playId === other.playId)?.featureContributions.recentSeenPenalty,
    0,
  );
});

test('no explicit preference produces a deterministic curated fallback order', () => {
  const ranked = rankFeedCandidates(
    [
      candidate('b', {qualityPrior: 0.7, curatedOrder: 20}),
      candidate('a', {qualityPrior: 0.7, curatedOrder: 10}),
    ],
    {interestTopicIds: [], learningTopicIds: []},
  );

  assert.deepEqual(
    ranked.map((item) => [item.playId, item.sourceBucket, item.rank]),
    [
      ['play_a', 'curated_fallback', 1],
      ['play_b', 'curated_fallback', 2],
    ],
  );
});

test('muted topics are excluded before scoring', () => {
  const ranked = rankFeedCandidates(
    [
      candidate('travel', {topicIds: ['travel']}),
      candidate('food', {topicIds: ['food']}),
    ],
    {
      interestTopicIds: ['travel'],
      learningTopicIds: [],
      mutedTopicIds: ['travel'],
    },
  );

  assert.deepEqual(ranked.map((item) => item.playId), ['play_food']);
});

test('ranking rejects duplicate candidate identity instead of producing ambiguous decisions', () => {
  const duplicate = candidate('same');
  assert.throws(
    () =>
      rankFeedCandidates([duplicate, duplicate], {
        interestTopicIds: [],
        learningTopicIds: [],
      }),
    /Duplicate feed candidate/,
  );
});

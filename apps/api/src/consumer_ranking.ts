export type FeedSourceBucket = 'known' | 'wildcard' | 'curated_fallback';

export interface FeedCandidate {
  playId: string;
  revisionId: string;
  format: string;
  topicIds: readonly string[];
  learningTopicIds: readonly string[];
  qualityPrior: number;
  curatedOrder: number;
  document: unknown;
}

export interface ConsumerRankingProfile {
  interestTopicIds: readonly string[];
  learningTopicIds: readonly string[];
  interactionAffinity?: Readonly<Record<string, number>>;
  recentRevisionIds?: readonly string[];
  topicDismissalCounts?: Readonly<Record<string, number>>;
  formatDismissalCounts?: Readonly<Record<string, number>>;
  moreLikeTopicIds?: readonly string[];
  mutedTopicIds?: readonly string[];
}

export interface ConsumerRankingWeights {
  interestAffinity: number;
  learningAffinity: number;
  interactionAffinity: number;
  qualityPrior: number;
  explorationBonus: number;
  moreLikeThisAffinity: number;
  recentSeenPenalty: number;
  repeatedTopicDismissalPenalty: number;
  repeatedFormatDismissalPenalty: number;
}

export interface ConsumerRankingConfig {
  version: string;
  weights: ConsumerRankingWeights;
}

export interface RankedFeedCandidate extends FeedCandidate {
  rank: number;
  sourceBucket: FeedSourceBucket;
  score: number;
  featureContributions: Readonly<Record<string, number>>;
}

export const defaultConsumerRankingConfig: ConsumerRankingConfig = Object.freeze({
  version: 'm2-rules-v1',
  weights: Object.freeze({
    interestAffinity: 1,
    learningAffinity: 1.15,
    interactionAffinity: 0.55,
    qualityPrior: 0.5,
    explorationBonus: 0.2,
    moreLikeThisAffinity: 1.25,
    recentSeenPenalty: 1.1,
    repeatedTopicDismissalPenalty: 1.2,
    repeatedFormatDismissalPenalty: 0.8,
  }),
});

export function rankFeedCandidates(
  candidates: readonly FeedCandidate[],
  profile: ConsumerRankingProfile,
  config: ConsumerRankingConfig = defaultConsumerRankingConfig,
): RankedFeedCandidate[] {
  validateConfig(config);
  const normalized = normalizeProfile(profile);
  const seenKeys = new Set<string>();
  const hasExplicitPreference =
    normalized.interestTopicIds.size > 0 || normalized.learningTopicIds.size > 0;

  const ranked = candidates
    .map((candidate) => {
      validateCandidate(candidate);
      const key = candidateKey(candidate);
      if (!seenKeys.add(key)) throw new Error(`Duplicate feed candidate: ${key}`);
      if (hasOverlap(candidate.topicIds, normalized.mutedTopicIds) ||
          hasOverlap(candidate.learningTopicIds, normalized.mutedTopicIds)) {
        return null;
      }

      const interest = hasOverlap(candidate.topicIds, normalized.interestTopicIds) ? 1 : 0;
      const learning = hasOverlap(candidate.learningTopicIds, normalized.learningTopicIds) ? 1 : 0;
      const known = interest > 0 || learning > 0;
      const sourceBucket: FeedSourceBucket = known
        ? 'known'
        : hasExplicitPreference
          ? 'wildcard'
          : 'curated_fallback';
      const interaction = clampSigned(normalized.interactionAffinity[candidate.format] ?? 0);
      const moreLike =
        hasOverlap(candidate.topicIds, normalized.moreLikeTopicIds) ||
        hasOverlap(candidate.learningTopicIds, normalized.moreLikeTopicIds)
          ? 1
          : 0;
      const recentSeen = normalized.recentRevisionIds.has(candidate.revisionId) ? 1 : 0;
      const topicDismissal = dismissalStrength([
        ...candidate.topicIds.map((topic) => normalized.topicDismissalCounts[topic] ?? 0),
        ...candidate.learningTopicIds.map(
          (topic) => normalized.topicDismissalCounts[topic] ?? 0,
        ),
      ]);
      const formatDismissal = dismissalStrength([
        normalized.formatDismissalCounts[candidate.format] ?? 0,
      ]);
      const exploration = sourceBucket === 'wildcard' ? 1 : 0;

      const features = {
        interestAffinity: interest * config.weights.interestAffinity,
        learningAffinity: learning * config.weights.learningAffinity,
        interactionAffinity: interaction * config.weights.interactionAffinity,
        qualityPrior: candidate.qualityPrior * config.weights.qualityPrior,
        explorationBonus: exploration * config.weights.explorationBonus,
        moreLikeThisAffinity: moreLike * config.weights.moreLikeThisAffinity,
        recentSeenPenalty: -recentSeen * config.weights.recentSeenPenalty,
        repeatedTopicDismissalPenalty:
          -topicDismissal * config.weights.repeatedTopicDismissalPenalty,
        repeatedFormatDismissalPenalty:
          -formatDismissal * config.weights.repeatedFormatDismissalPenalty,
      } satisfies Record<string, number>;
      const score = Object.values(features).reduce((sum, value) => sum + value, 0);

      return {
        ...candidate,
        rank: 0,
        sourceBucket,
        score,
        featureContributions: Object.freeze(features),
      } satisfies RankedFeedCandidate;
    })
    .filter((candidate): candidate is RankedFeedCandidate => candidate !== null)
    .sort(compareRankedCandidates);

  return ranked.map((candidate, index) => ({...candidate, rank: index + 1}));
}

function compareRankedCandidates(
  left: RankedFeedCandidate,
  right: RankedFeedCandidate,
): number {
  const score = right.score - left.score;
  if (score !== 0) return score;
  const curated = left.curatedOrder - right.curatedOrder;
  if (curated !== 0) return curated;
  return candidateKey(left).localeCompare(candidateKey(right));
}

function dismissalStrength(values: readonly number[]): number {
  const count = Math.max(0, ...values.map(normalizeCount));
  if (count <= 1) return 0;
  return Math.min(1, (count - 1) / 3);
}

function normalizeCount(value: number): number {
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

function normalizeProfile(profile: ConsumerRankingProfile) {
  return {
    interestTopicIds: normalizedSet(profile.interestTopicIds),
    learningTopicIds: normalizedSet(profile.learningTopicIds),
    recentRevisionIds: normalizedSet(profile.recentRevisionIds ?? []),
    moreLikeTopicIds: normalizedSet(profile.moreLikeTopicIds ?? []),
    mutedTopicIds: normalizedSet(profile.mutedTopicIds ?? []),
    interactionAffinity: normalizeNumberMap(profile.interactionAffinity),
    topicDismissalCounts: normalizeNumberMap(profile.topicDismissalCounts),
    formatDismissalCounts: normalizeNumberMap(profile.formatDismissalCounts),
  };
}

function normalizedSet(values: readonly string[]): ReadonlySet<string> {
  return new Set(values.map(normalizeText).filter((value) => value.length > 0));
}

function normalizeNumberMap(
  value: Readonly<Record<string, number>> | undefined,
): Readonly<Record<string, number>> {
  if (!value) return Object.freeze({});
  const result: Record<string, number> = {};
  for (const [key, raw] of Object.entries(value)) {
    const normalized = normalizeText(key);
    if (normalized.length > 0 && Number.isFinite(raw)) result[normalized] = raw;
  }
  return Object.freeze(result);
}

function hasOverlap(values: readonly string[], selected: ReadonlySet<string>): boolean {
  return values.some((value) => selected.has(normalizeText(value)));
}

function normalizeText(value: string): string {
  return value.trim().toLowerCase();
}

function clampSigned(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(-1, Math.min(1, value));
}

function candidateKey(candidate: Pick<FeedCandidate, 'playId' | 'revisionId'>): string {
  return `${candidate.playId}\u0000${candidate.revisionId}`;
}

function validateCandidate(candidate: FeedCandidate): void {
  if (normalizeText(candidate.playId).length === 0 || normalizeText(candidate.revisionId).length === 0) {
    throw new Error('Feed candidates require playId and revisionId.');
  }
  if (normalizeText(candidate.format).length === 0) {
    throw new Error(`Feed candidate ${candidateKey(candidate)} requires a format.`);
  }
  if (!Number.isFinite(candidate.qualityPrior) || candidate.qualityPrior < 0 || candidate.qualityPrior > 1) {
    throw new Error(`Feed candidate ${candidateKey(candidate)} has an invalid quality prior.`);
  }
  if (!Number.isInteger(candidate.curatedOrder) || candidate.curatedOrder < 0) {
    throw new Error(`Feed candidate ${candidateKey(candidate)} has an invalid curated order.`);
  }
}

function validateConfig(config: ConsumerRankingConfig): void {
  if (config.version.trim().length === 0) throw new Error('Ranking config version is required.');
  for (const [name, value] of Object.entries(config.weights)) {
    if (!Number.isFinite(value) || value < 0) {
      throw new Error(`Ranking weight ${name} must be a finite non-negative number.`);
    }
  }
}

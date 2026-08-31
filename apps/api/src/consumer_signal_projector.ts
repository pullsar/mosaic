import {Pool, type PoolClient} from 'pg';
import {feedCandidateIdentity} from './consumer_ranking.js';

const PROFILE_VERSION = 1;
const DEFAULT_MAX_EVENTS_PER_RUN = 512;
const MAX_EVENTS_PER_RUN = 2000;
const RECENT_REVISION_LIMIT = 64;
const FORMAT_SIGNAL_LIMIT = 32;
const DISMISSAL_COUNT_CAP = 8;
const CORRECT_RESOLUTION_STEP = 0.16;
const INTENTIONAL_RESOLUTION_STEP = 0.1;
const INCORRECT_RESOLUTION_STEP = 0.04;
const RAPID_DISMISS_STEP = 0.08;
const RAPID_DISMISS_WINDOW_MS = 5 * 60 * 1000;
const RECENT_REVISION_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const DISMISSAL_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const MORE_LIKE_TTL_MS = 14 * 24 * 60 * 60 * 1000;
const AFFINITY_HALF_LIFE_MS = 30 * 24 * 60 * 60 * 1000;
const AFFINITY_MAX_AGE_MS = 90 * 24 * 60 * 60 * 1000;

export interface ConsumerDerivedRankingProfile {
  interactionAffinity: Record<string, number>;
  recentPlayRevisionKeys: string[];
  topicDismissalCounts: Record<string, number>;
  formatDismissalCounts: Record<string, number>;
  moreLikeTopicIds: string[];
}

export interface ConsumerSignalProjector {
  projectActor(actorId: string): Promise<number>;
  readActorProfile(actorId: string): Promise<ConsumerDerivedRankingProfile | null>;
  rebuildActor(actorId: string): Promise<number>;
}

export interface ConsumerSignalProjectorOptions {
  maxEventsPerRun?: number;
  clock?: () => Date;
}

type TimedAffinity = {value: number; updatedAt: string};
type TimedCount = {count: number; updatedAt: string};
type RecentRevision = {
  playId: string;
  revisionId: string;
  receivedAt: string;
};

type ProfileState = {
  checkpointReceivedAt: string | null;
  checkpointEventId: string | null;
  interactionAffinity: Record<string, TimedAffinity>;
  recentRevisions: RecentRevision[];
  formatDismissalCounts: Record<string, TimedCount>;
  formatLastDismissedAt: Record<string, string>;
};

type ProfileRow = {
  checkpoint_received_at: string | null;
  checkpoint_event_id: string | null;
  interaction_affinity: unknown;
  recent_revisions: unknown;
  format_dismissal_counts: unknown;
  format_last_dismissed_at: unknown;
};

type ProjectableEventRow = {
  event_id: string;
  event_name: string;
  received_at: string;
  play_revision_id: string | null;
  payload: unknown;
  play_format: string | null;
};

type ExplicitSignalRow = {
  signal: 'more_like_this' | 'not_interested';
  first_received_at: string;
  format: string | null;
  topic_ids: string[];
};

export class PostgresConsumerSignalProjector implements ConsumerSignalProjector {
  private readonly maxEventsPerRun: number;
  private readonly clock: () => Date;

  constructor(
    private readonly pool: Pool,
    options: ConsumerSignalProjectorOptions = {},
  ) {
    this.maxEventsPerRun = boundedInteger(
      options.maxEventsPerRun ?? DEFAULT_MAX_EVENTS_PER_RUN,
      1,
      MAX_EVENTS_PER_RUN,
      'maxEventsPerRun',
    );
    this.clock = options.clock ?? (() => new Date());
  }

  async projectActor(actorId: string): Promise<number> {
    const normalizedActorId = requiredText(actorId, 'actorId');
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      await lockActorProjection(client, normalizedActorId);
      const state = await loadLockedProfile(client, normalizedActorId);
      const events = await loadEvents(
        client,
        normalizedActorId,
        state.checkpointReceivedAt,
        state.checkpointEventId,
        this.maxEventsPerRun,
      );
      applyEvents(state, events);
      if (events.length > 0) await persistProfile(client, normalizedActorId, state);
      await client.query('commit');
      return events.length;
    } catch (error) {
      await client.query('rollback').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  }

  async readActorProfile(actorId: string): Promise<ConsumerDerivedRankingProfile | null> {
    const normalizedActorId = requiredText(actorId, 'actorId');
    const result = await this.pool.query<{
      interaction_affinity: unknown;
      recent_revisions: unknown;
      format_dismissal_counts: unknown;
    }>(
      `select interaction_affinity,
              recent_revisions,
              format_dismissal_counts
         from consumer_signal_profiles
        where actor_id = $1`,
      [normalizedActorId],
    );
    const row = result.rows[0];
    if (!row) return null;

    const now = this.clock().getTime();
    if (!Number.isFinite(now)) throw new Error('Consumer signal clock returned an invalid time.');
    const formatDismissalCounts = decodeCountsForRanking(row.format_dismissal_counts, now);
    const topicDismissalCounts: Record<string, number> = {};
    const moreLikeTopics = new Set<string>();
    const explicit = await this.pool.query<ExplicitSignalRow>(
      `select signal.signal,
              signal.first_received_at::text as first_received_at,
              revision.document ->> 'format' as format,
              coalesce((
                select array_agg(topic.topic_id order by topic.topic_id)
                  from (
                    select distinct link.topic_id
                      from play_revision_topics link
                     where link.play_id = signal.play_id
                       and link.revision_id = signal.revision_id
                  ) topic
              ), array[]::text[]) as topic_ids
         from actor_play_signals signal
         join play_revisions revision
           on revision.play_id = signal.play_id
          and revision.revision_id = signal.revision_id
        where signal.actor_id = $1
          and signal.signal in ('more_like_this', 'not_interested')
        order by signal.signal, signal.play_id`,
      [normalizedActorId],
    );

    for (const action of explicit.rows) {
      const receivedAt = timestampMs(action.first_received_at, 'action signal receipt');
      const age = Math.max(0, now - receivedAt);
      const topicIds = normalizedTopicIds(action.topic_ids);
      if (action.signal === 'more_like_this') {
        if (age <= MORE_LIKE_TTL_MS) {
          for (const topicId of topicIds) moreLikeTopics.add(topicId);
        }
        continue;
      }
      if (age > DISMISSAL_TTL_MS) continue;
      for (const topicId of topicIds) incrementCount(topicDismissalCounts, topicId);
      const format = optionalText(action.format);
      if (format !== null) incrementCount(formatDismissalCounts, format.toLowerCase());
    }

    return {
      interactionAffinity: decodeAffinityForRanking(row.interaction_affinity, now),
      recentPlayRevisionKeys: decodeRecentRevisionsForRanking(row.recent_revisions, now),
      topicDismissalCounts,
      formatDismissalCounts,
      moreLikeTopicIds: [...moreLikeTopics].sort(),
    };
  }

  async rebuildActor(actorId: string): Promise<number> {
    const normalizedActorId = requiredText(actorId, 'actorId');
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      await lockActorProjection(client, normalizedActorId);
      await client.query('delete from consumer_signal_profiles where actor_id = $1', [
        normalizedActorId,
      ]);
      const state = emptyProfile();
      let processed = 0;
      while (true) {
        const events = await loadEvents(
          client,
          normalizedActorId,
          state.checkpointReceivedAt,
          state.checkpointEventId,
          this.maxEventsPerRun,
        );
        if (events.length === 0) break;
        applyEvents(state, events);
        processed += events.length;
        if (events.length < this.maxEventsPerRun) break;
      }
      await ensureProfile(client, normalizedActorId);
      await persistProfile(client, normalizedActorId, state);
      await client.query('commit');
      return processed;
    } catch (error) {
      await client.query('rollback').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  }
}

async function lockActorProjection(client: PoolClient, actorId: string): Promise<void> {
  await client.query(
    `select pg_advisory_xact_lock(
       hashtext('consumer_signal_profile'),
       hashtext($1)
     )`,
    [actorId],
  );
}

async function ensureProfile(client: PoolClient, actorId: string): Promise<void> {
  await client.query(
    `insert into consumer_signal_profiles (actor_id, profile_version)
     values ($1, $2)
     on conflict (actor_id) do nothing`,
    [actorId, PROFILE_VERSION],
  );
}

async function loadLockedProfile(client: PoolClient, actorId: string): Promise<ProfileState> {
  await ensureProfile(client, actorId);
  const result = await client.query<ProfileRow>(
    `select checkpoint_received_at::text,
            checkpoint_event_id,
            interaction_affinity,
            recent_revisions,
            format_dismissal_counts,
            format_last_dismissed_at
       from consumer_signal_profiles
      where actor_id = $1
      for update`,
    [actorId],
  );
  const row = result.rows[0];
  if (!row) throw new Error('Consumer signal profile could not be locked.');
  return decodeProfile(row);
}

async function loadEvents(
  client: PoolClient,
  actorId: string,
  checkpointReceivedAt: string | null,
  checkpointEventId: string | null,
  limit: number,
): Promise<ProjectableEventRow[]> {
  const result = await client.query<ProjectableEventRow>(
    `select event.event_id,
            event.event_name,
            event.received_at::text as received_at,
            event.play_revision_id,
            event.payload,
            revision.document ->> 'format' as play_format
       from interaction_events event
       left join play_revisions revision
         on revision.play_id = event.payload ->> 'playId'
        and revision.revision_id = event.play_revision_id
      where event.actor_id = $1
        and event.event_name in ('play_visible', 'play_resolved', 'play_dismissed')
        and (
          $2::timestamptz is null
          or event.received_at > $2::timestamptz
          or (
            event.received_at = $2::timestamptz
            and event.event_id > $3
          )
        )
      order by event.received_at, event.event_id
      limit $4`,
    [actorId, checkpointReceivedAt, checkpointEventId, limit],
  );
  return result.rows;
}

function applyEvents(state: ProfileState, events: readonly ProjectableEventRow[]): void {
  for (const event of events) {
    applyEvent(state, event);
    state.checkpointReceivedAt = event.received_at;
    state.checkpointEventId = event.event_id;
  }
}

function applyEvent(state: ProfileState, event: ProjectableEventRow): void {
  const receivedAt = parseTimestamp(event.received_at, 'received_at');
  const payload = asRecord(event.payload);
  const playId = optionalText(payload?.playId);
  const revisionId = optionalText(event.play_revision_id);
  const format = optionalText(event.play_format)?.toLowerCase() ?? null;

  switch (event.event_name) {
    case 'play_visible':
      if (playId !== null && revisionId !== null && format !== null) {
        rememberRecentRevision(state, playId, revisionId, event.received_at);
      }
      return;
    case 'play_resolved':
      if (format !== null) {
        applyResolutionAffinity(state, format, payload, event.received_at);
      }
      return;
    case 'play_dismissed':
      if (format !== null && optionalText(payload?.reason) === 'swipe') {
        applySwipeDismissal(state, format, receivedAt, event.received_at);
      }
      return;
    case 'play_not_interested':
    case 'more_like_this':
      // These are canonical one-shot intents in actor_play_signals. Reading
      // that source table prevents a new event ID from multiplying one intent.
      return;
    default:
      return;
  }
}

function applyResolutionAffinity(
  state: ProfileState,
  format: string,
  payload: Record<string, unknown> | null,
  receivedAt: string,
): void {
  const correct = payload?.correct;
  const step = correct === true
    ? CORRECT_RESOLUTION_STEP
    : correct === false
      ? INCORRECT_RESOLUTION_STEP
      : INTENTIONAL_RESOLUTION_STEP;
  const current = state.interactionAffinity[format]?.value ?? 0;
  setTimedAffinity(state, format, current + step * (1 - current), receivedAt);
}

function applySwipeDismissal(
  state: ProfileState,
  format: string,
  receivedAt: Date,
  receivedAtText: string,
): void {
  incrementTimedCount(state.formatDismissalCounts, format, receivedAtText);
  const previousRaw = state.formatLastDismissedAt[format];
  const previous = previousRaw === undefined ? Number.NaN : Date.parse(previousRaw);
  if (
    Number.isFinite(previous) &&
    receivedAt.getTime() >= previous &&
    receivedAt.getTime() - previous <= RAPID_DISMISS_WINDOW_MS
  ) {
    const current = state.interactionAffinity[format]?.value ?? 0;
    setTimedAffinity(
      state,
      format,
      current - RAPID_DISMISS_STEP * (1 + current),
      receivedAtText,
    );
  }
  setBoundedTextEntry(state.formatLastDismissedAt, format, receivedAtText);
}

function setTimedAffinity(
  state: ProfileState,
  format: string,
  value: number,
  updatedAt: string,
): void {
  if (
    !(format in state.interactionAffinity) &&
    Object.keys(state.interactionAffinity).length >= FORMAT_SIGNAL_LIMIT
  ) {
    evictOldestTimedEntry(state.interactionAffinity);
  }
  state.interactionAffinity[format] = {value: clampSigned(value), updatedAt};
}

function rememberRecentRevision(
  state: ProfileState,
  playId: string,
  revisionId: string,
  receivedAt: string,
): void {
  const index = state.recentRevisions.findIndex(
    (entry) => entry.playId === playId && entry.revisionId === revisionId,
  );
  if (index >= 0) state.recentRevisions.splice(index, 1);
  state.recentRevisions.push({playId, revisionId, receivedAt});
  if (state.recentRevisions.length > RECENT_REVISION_LIMIT) {
    state.recentRevisions.splice(0, state.recentRevisions.length - RECENT_REVISION_LIMIT);
  }
}

function incrementTimedCount(
  target: Record<string, TimedCount>,
  key: string,
  updatedAt: string,
): void {
  if (!(key in target) && Object.keys(target).length >= FORMAT_SIGNAL_LIMIT) {
    evictOldestTimedEntry(target);
  }
  target[key] = {
    count: Math.min(DISMISSAL_COUNT_CAP, (target[key]?.count ?? 0) + 1),
    updatedAt,
  };
}

function incrementCount(target: Record<string, number>, key: string): void {
  target[key] = Math.min(DISMISSAL_COUNT_CAP, (target[key] ?? 0) + 1);
}

function evictOldestTimedEntry<T extends {updatedAt: string}>(target: Record<string, T>): void {
  const oldest = Object.entries(target).sort(([leftKey, left], [rightKey, right]) => {
    const time = timestampMs(left.updatedAt, 'signal update') - timestampMs(right.updatedAt, 'signal update');
    return time !== 0 ? time : leftKey.localeCompare(rightKey);
  })[0];
  if (oldest !== undefined) delete target[oldest[0]];
}

function setBoundedTextEntry(
  target: Record<string, string>,
  key: string,
  value: string,
): void {
  if (!(key in target) && Object.keys(target).length >= FORMAT_SIGNAL_LIMIT) {
    const oldest = Object.entries(target).sort(([leftKey, left], [rightKey, right]) => {
      const time = timestampMs(left, 'dismissal timestamp') - timestampMs(right, 'dismissal timestamp');
      return time !== 0 ? time : leftKey.localeCompare(rightKey);
    })[0];
    if (oldest !== undefined) delete target[oldest[0]];
  }
  target[key] = value;
}

async function persistProfile(
  client: PoolClient,
  actorId: string,
  state: ProfileState,
): Promise<void> {
  await client.query(
    `update consumer_signal_profiles
        set profile_version = $2,
            checkpoint_received_at = $3::timestamptz,
            checkpoint_event_id = $4,
            interaction_affinity = $5::jsonb,
            recent_revisions = $6::jsonb,
            format_dismissal_counts = $7::jsonb,
            format_last_dismissed_at = $8::jsonb,
            updated_at = now()
      where actor_id = $1`,
    [
      actorId,
      PROFILE_VERSION,
      state.checkpointReceivedAt,
      state.checkpointEventId,
      JSON.stringify(state.interactionAffinity),
      JSON.stringify(state.recentRevisions),
      JSON.stringify(state.formatDismissalCounts),
      JSON.stringify(state.formatLastDismissedAt),
    ],
  );
}

function emptyProfile(): ProfileState {
  return {
    checkpointReceivedAt: null,
    checkpointEventId: null,
    interactionAffinity: {},
    recentRevisions: [],
    formatDismissalCounts: {},
    formatLastDismissedAt: {},
  };
}

function decodeProfile(row: ProfileRow): ProfileState {
  return {
    checkpointReceivedAt: row.checkpoint_received_at,
    checkpointEventId: row.checkpoint_event_id,
    interactionAffinity: decodeTimedAffinityMap(row.interaction_affinity),
    recentRevisions: decodeRecentRevisions(row.recent_revisions),
    formatDismissalCounts: decodeTimedCountMap(row.format_dismissal_counts),
    formatLastDismissedAt: decodeTextMap(row.format_last_dismissed_at),
  };
}

function decodeTimedAffinityMap(value: unknown): Record<string, TimedAffinity> {
  const record = requireRecord(value, 'interaction_affinity');
  const result: Record<string, TimedAffinity> = {};
  for (const [key, raw] of Object.entries(record)) {
    const entry = requireRecord(raw, `interaction_affinity.${key}`);
    const affinity = entry.value;
    const updatedAt = optionalText(entry.updatedAt);
    if (typeof affinity !== 'number' || !Number.isFinite(affinity) || updatedAt === null) {
      throw new Error('Consumer signal affinity profile is corrupt.');
    }
    parseTimestamp(updatedAt, 'interaction affinity updatedAt');
    result[key] = {value: clampSigned(affinity), updatedAt};
  }
  return result;
}

function decodeTimedCountMap(value: unknown): Record<string, TimedCount> {
  const record = requireRecord(value, 'dismissal counts');
  const result: Record<string, TimedCount> = {};
  for (const [key, raw] of Object.entries(record)) {
    const entry = requireRecord(raw, `dismissal count.${key}`);
    const count = entry.count;
    const updatedAt = optionalText(entry.updatedAt);
    if (!Number.isInteger(count) || (count as number) < 0 || updatedAt === null) {
      throw new Error('Consumer signal dismissal profile is corrupt.');
    }
    parseTimestamp(updatedAt, 'dismissal count updatedAt');
    result[key] = {
      count: Math.min(DISMISSAL_COUNT_CAP, count as number),
      updatedAt,
    };
  }
  return result;
}

function decodeRecentRevisions(value: unknown): RecentRevision[] {
  if (!Array.isArray(value) || value.length > RECENT_REVISION_LIMIT) {
    throw new Error('Consumer recent-revision profile is corrupt.');
  }
  return value.map((raw) => {
    const entry = requireRecord(raw, 'recent revision');
    const playId = optionalText(entry.playId);
    const revisionId = optionalText(entry.revisionId);
    const receivedAt = optionalText(entry.receivedAt);
    if (playId === null || revisionId === null || receivedAt === null) {
      throw new Error('Consumer recent-revision profile is corrupt.');
    }
    parseTimestamp(receivedAt, 'recent revision receivedAt');
    return {playId, revisionId, receivedAt};
  });
}

function decodeTextMap(value: unknown): Record<string, string> {
  const record = requireRecord(value, 'text map');
  const result: Record<string, string> = {};
  for (const [key, raw] of Object.entries(record)) {
    if (typeof raw !== 'string') throw new Error('Consumer signal text map is corrupt.');
    parseTimestamp(raw, 'signal timestamp');
    result[key] = raw;
  }
  return result;
}

function decodeAffinityForRanking(value: unknown, now: number): Record<string, number> {
  const record = decodeTimedAffinityMap(value);
  const result: Record<string, number> = {};
  for (const [format, entry] of Object.entries(record)) {
    const age = Math.max(0, now - timestampMs(entry.updatedAt, 'affinity update'));
    if (age > AFFINITY_MAX_AGE_MS) continue;
    result[format] = entry.value * Math.pow(0.5, age / AFFINITY_HALF_LIFE_MS);
  }
  return result;
}

function decodeRecentRevisionsForRanking(value: unknown, now: number): string[] {
  return decodeRecentRevisions(value)
    .filter((entry) => Math.max(0, now - timestampMs(entry.receivedAt, 'recent revision')) <= RECENT_REVISION_TTL_MS)
    .map((entry) => feedCandidateIdentity(entry.playId, entry.revisionId));
}

function decodeCountsForRanking(value: unknown, now: number): Record<string, number> {
  const record = decodeTimedCountMap(value);
  const result: Record<string, number> = {};
  for (const [key, entry] of Object.entries(record)) {
    if (Math.max(0, now - timestampMs(entry.updatedAt, 'dismissal update')) <= DISMISSAL_TTL_MS) {
      result[key] = entry.count;
    }
  }
  return result;
}

function requireRecord(value: unknown, name: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${name} must be an object.`);
  }
  return value as Record<string, unknown>;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function normalizedTopicIds(values: readonly string[]): string[] {
  return [...new Set(values.map((value) => value.trim().toLowerCase()).filter(Boolean))].sort();
}

function optionalText(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const normalized = value.trim();
  return normalized.length > 0 && normalized.length <= 200 ? normalized : null;
}

function requiredText(value: string, name: string): string {
  const normalized = value.trim();
  if (normalized.length === 0 || normalized.length > 200) {
    throw new TypeError(`${name} must be between 1 and 200 characters.`);
  }
  return normalized;
}

function parseTimestamp(value: string, name: string): Date {
  const timestamp = new Date(value);
  if (!Number.isFinite(timestamp.getTime())) throw new Error(`${name} is invalid.`);
  return timestamp;
}

function timestampMs(value: string, name: string): number {
  return parseTimestamp(value, name).getTime();
}

function clampSigned(value: number): number {
  return Math.max(-1, Math.min(1, value));
}

function boundedInteger(value: number, min: number, max: number, name: string): number {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new RangeError(`${name} must be an integer between ${min} and ${max}.`);
  }
  return value;
}

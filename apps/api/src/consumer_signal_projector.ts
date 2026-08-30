import {Pool, type PoolClient} from 'pg';

const PROFILE_VERSION = 1;
const DEFAULT_MAX_EVENTS_PER_RUN = 512;
const MAX_EVENTS_PER_RUN = 2000;
const RECENT_REVISION_LIMIT = 64;
const TOPIC_SIGNAL_LIMIT = 128;
const FORMAT_SIGNAL_LIMIT = 32;
const MORE_LIKE_TOPIC_LIMIT = 128;
const DISMISSAL_COUNT_CAP = 8;
const CORRECT_RESOLUTION_STEP = 0.16;
const INTENTIONAL_RESOLUTION_STEP = 0.1;
const INCORRECT_RESOLUTION_STEP = 0.04;
const RAPID_DISMISS_STEP = 0.08;
const RAPID_DISMISS_WINDOW_MS = 5 * 60 * 1000;
const MORE_LIKE_TTL_MS = 14 * 24 * 60 * 60 * 1000;

export interface ConsumerSignalProjector {
  projectActor(actorId: string): Promise<number>;
  rebuildActor(actorId: string): Promise<number>;
}

export interface ConsumerSignalProjectorOptions {
  maxEventsPerRun?: number;
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
  topicDismissalCounts: Record<string, TimedCount>;
  formatDismissalCounts: Record<string, TimedCount>;
  moreLikeTopicExpiries: Record<string, string>;
  formatLastDismissedAt: Record<string, string>;
};

type ProfileRow = {
  checkpoint_received_at: string | null;
  checkpoint_event_id: string | null;
  interaction_affinity: unknown;
  recent_revisions: unknown;
  topic_dismissal_counts: unknown;
  format_dismissal_counts: unknown;
  more_like_topic_expiries: unknown;
  format_last_dismissed_at: unknown;
};

type ProjectableEventRow = {
  event_id: string;
  event_name: string;
  received_at: string;
  play_revision_id: string | null;
  payload: unknown;
  play_format: string | null;
  topic_ids: string[];
};

export class PostgresConsumerSignalProjector implements ConsumerSignalProjector {
  private readonly maxEventsPerRun: number;

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
            topic_dismissal_counts,
            format_dismissal_counts,
            more_like_topic_expiries,
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
            revision.document ->> 'format' as play_format,
            coalesce((
              select array_agg(topic.topic_id order by topic.topic_id)
                from (
                  select distinct link.topic_id
                    from play_revision_topics link
                   where link.play_id = event.payload ->> 'playId'
                     and link.revision_id = event.play_revision_id
                ) topic
            ), array[]::text[]) as topic_ids
       from interaction_events event
       left join play_revisions revision
         on revision.play_id = event.payload ->> 'playId'
        and revision.revision_id = event.play_revision_id
      where event.actor_id = $1
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
  const topicIds = normalizedTopicIds(event.topic_ids);
  const hasAuthoritativePlay = playId !== null && revisionId !== null && format !== null;

  switch (event.event_name) {
    case 'play_visible':
      if (hasAuthoritativePlay) {
        rememberRecentRevision(state, playId, revisionId, event.received_at);
      }
      return;
    case 'play_resolved':
      if (format === null) return;
      applyResolutionAffinity(state, format, payload, event.received_at);
      return;
    case 'play_dismissed':
      if (format === null || optionalText(payload?.reason) !== 'swipe') return;
      applySwipeDismissal(state, format, receivedAt, event.received_at);
      return;
    case 'play_not_interested':
      if (format === null) return;
      incrementTimedCount(
        state.formatDismissalCounts,
        format,
        event.received_at,
        FORMAT_SIGNAL_LIMIT,
      );
      for (const topicId of topicIds) {
        incrementTimedCount(
          state.topicDismissalCounts,
          topicId,
          event.received_at,
          TOPIC_SIGNAL_LIMIT,
        );
      }
      return;
    case 'more_like_this':
      for (const topicId of topicIds) {
        rememberMoreLikeTopic(state, topicId, receivedAt);
      }
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
  const next = current + step * (1 - current);
  setTimedAffinity(state, format, next, receivedAt);
}

function applySwipeDismissal(
  state: ProfileState,
  format: string,
  receivedAt: Date,
  receivedAtText: string,
): void {
  incrementTimedCount(
    state.formatDismissalCounts,
    format,
    receivedAtText,
    FORMAT_SIGNAL_LIMIT,
  );
  const previousRaw = state.formatLastDismissedAt[format];
  const previous = previousRaw === undefined ? null : Date.parse(previousRaw);
  if (
    previous !== null &&
    Number.isFinite(previous) &&
    receivedAt.getTime() >= previous &&
    receivedAt.getTime() - previous <= RAPID_DISMISS_WINDOW_MS
  ) {
    const current = state.interactionAffinity[format]?.value ?? 0;
    const next = current - RAPID_DISMISS_STEP * (1 + current);
    setTimedAffinity(state, format, next, receivedAtText);
  }
  setBoundedTextEntry(
    state.formatLastDismissedAt,
    format,
    receivedAtText,
    FORMAT_SIGNAL_LIMIT,
  );
}

function setTimedAffinity(
  state: ProfileState,
  format: string,
  value: number,
  updatedAt: string,
): void {
  if (!(format in state.interactionAffinity) &&
      Object.keys(state.interactionAffinity).length >= FORMAT_SIGNAL_LIMIT) {
    evictOldestTimedEntry(state.interactionAffinity);
  }
  state.interactionAffinity[format] = {
    value: clampSigned(value),
    updatedAt,
  };
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

function rememberMoreLikeTopic(
  state: ProfileState,
  topicId: string,
  receivedAt: Date,
): void {
  const expiry = new Date(receivedAt.getTime() + MORE_LIKE_TTL_MS).toISOString();
  const existing = state.moreLikeTopicExpiries[topicId];
  if (existing !== undefined && Date.parse(existing) >= expiryMs(expiry)) return;
  setBoundedTextEntry(
    state.moreLikeTopicExpiries,
    topicId,
    expiry,
    MORE_LIKE_TOPIC_LIMIT,
    true,
  );
}

function incrementTimedCount(
  target: Record<string, TimedCount>,
  key: string,
  updatedAt: string,
  limit: number,
): void {
  if (!(key in target) && Object.keys(target).length >= limit) {
    evictOldestTimedEntry(target);
  }
  target[key] = {
    count: Math.min(DISMISSAL_COUNT_CAP, (target[key]?.count ?? 0) + 1),
    updatedAt,
  };
}

function evictOldestTimedEntry<T extends {updatedAt: string}>(target: Record<string, T>): void {
  let oldestKey: string | null = null;
  let oldestTime = Number.POSITIVE_INFINITY;
  for (const [key, entry] of Object.entries(target)) {
    const timestamp = Date.parse(entry.updatedAt);
    const comparable = Number.isFinite(timestamp) ? timestamp : Number.NEGATIVE_INFINITY;
    if (
      comparable < oldestTime ||
      (comparable === oldestTime && (oldestKey === null || key < oldestKey))
    ) {
      oldestKey = key;
      oldestTime = comparable;
    }
  }
  if (oldestKey !== null) delete target[oldestKey];
}

function setBoundedTextEntry(
  target: Record<string, string>,
  key: string,
  value: string,
  limit: number,
  evictByValueTime = false,
): void {
  if (!(key in target) && Object.keys(target).length >= limit) {
    const keys = Object.keys(target);
    keys.sort((left, right) => {
      if (evictByValueTime) {
        const time = expiryMs(target[left] ?? '') - expiryMs(target[right] ?? '');
        if (time !== 0) return time;
      }
      return left.localeCompare(right);
    });
    const first = keys[0];
    if (first !== undefined) delete target[first];
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
            topic_dismissal_counts = $7::jsonb,
            format_dismissal_counts = $8::jsonb,
            more_like_topic_expiries = $9::jsonb,
            format_last_dismissed_at = $10::jsonb,
            updated_at = now()
      where actor_id = $1`,
    [
      actorId,
      PROFILE_VERSION,
      state.checkpointReceivedAt,
      state.checkpointEventId,
      JSON.stringify(state.interactionAffinity),
      JSON.stringify(state.recentRevisions),
      JSON.stringify(state.topicDismissalCounts),
      JSON.stringify(state.formatDismissalCounts),
      JSON.stringify(state.moreLikeTopicExpiries),
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
    topicDismissalCounts: {},
    formatDismissalCounts: {},
    moreLikeTopicExpiries: {},
    formatLastDismissedAt: {},
  };
}

function decodeProfile(row: ProfileRow): ProfileState {
  return {
    checkpointReceivedAt: row.checkpoint_received_at,
    checkpointEventId: row.checkpoint_event_id,
    interactionAffinity: decodeTimedAffinityMap(row.interaction_affinity),
    recentRevisions: decodeRecentRevisions(row.recent_revisions),
    topicDismissalCounts: decodeTimedCountMap(row.topic_dismissal_counts),
    formatDismissalCounts: decodeTimedCountMap(row.format_dismissal_counts),
    moreLikeTopicExpiries: decodeTextMap(row.more_like_topic_expiries),
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

function clampSigned(value: number): number {
  return Math.max(-1, Math.min(1, value));
}

function expiryMs(value: string): number {
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : Number.NEGATIVE_INFINITY;
}

function boundedInteger(value: number, min: number, max: number, name: string): number {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new RangeError(`${name} must be an integer between ${min} and ${max}.`);
  }
  return value;
}

import type {PoolClient} from 'pg';
import type {EventInput} from './repository.js';

export const CONSUMER_ACTION_EVENT = Object.freeze({
  playSaved: 'play_saved',
  playUnsaved: 'play_unsaved',
  moreLikeThis: 'more_like_this',
  playNotInterested: 'play_not_interested',
  topicMuted: 'topic_muted',
  topicUnmuted: 'topic_unmuted',
  playReported: 'play_reported',
} as const);

const CONSUMER_ACTION_EVENTS = new Set<string>(Object.values(CONSUMER_ACTION_EVENT));

export const PLAY_REPORT_REASONS = Object.freeze([
  'spam',
  'misleading',
  'harassment',
  'sexual_content',
  'violence_or_dangerous',
  'rights_or_ownership',
  'other',
] as const);

type PlayReportReason = (typeof PLAY_REPORT_REASONS)[number];

export class ConsumerActionEventError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConsumerActionEventError';
  }
}

export function isConsumerActionEvent(eventName: string): boolean {
  return CONSUMER_ACTION_EVENTS.has(eventName);
}

/**
 * Projects one canonical action event inside the caller-owned event transaction.
 *
 * Save/mute transitions are ordered by authoritative server receipt time plus
 * event ID. Client `occurredAt` remains observation telemetry and is never used
 * as the integrity ordering source. More Like This / Not interested are one-shot
 * logical-Play signals: repeated events never create count weight. Reports remain
 * immutable canonical events for #7 and do not masquerade as a preference.
 */
export async function projectConsumerActionEvent(
  client: PoolClient,
  event: EventInput,
  receivedAt: string,
): Promise<void> {
  if (!isConsumerActionEvent(event.event)) return;
  if (event.version !== 1) {
    throw new ConsumerActionEventError('Consumer action events require version 1.');
  }

  switch (event.event) {
    case CONSUMER_ACTION_EVENT.playSaved:
      await projectSaved(client, event, receivedAt, true);
      return;
    case CONSUMER_ACTION_EVENT.playUnsaved:
      await projectSaved(client, event, receivedAt, false);
      return;
    case CONSUMER_ACTION_EVENT.moreLikeThis:
      await projectPlaySignal(client, event, receivedAt, 'more_like_this');
      return;
    case CONSUMER_ACTION_EVENT.playNotInterested:
      await projectPlaySignal(client, event, receivedAt, 'not_interested');
      await invalidateFeedDecisions(client, event.actorId);
      return;
    case CONSUMER_ACTION_EVENT.topicMuted:
      await projectTopicMute(client, event, receivedAt, true);
      await invalidateFeedDecisions(client, event.actorId);
      return;
    case CONSUMER_ACTION_EVENT.topicUnmuted:
      await projectTopicMute(client, event, receivedAt, false);
      await invalidateFeedDecisions(client, event.actorId);
      return;
    case CONSUMER_ACTION_EVENT.playReported:
      await validateReport(client, event);
      return;
  }
}

async function projectSaved(
  client: PoolClient,
  event: EventInput,
  receivedAt: string,
  saved: boolean,
): Promise<void> {
  const identity = playIdentity(event);
  await assertPlayRevision(client, identity.playId, identity.revisionId);
  await client.query(
    `insert into actor_saved_plays (
       actor_id, play_id, revision_id, saved, event_received_at, event_id
     ) values ($1, $2, $3, $4, $5, $6)
     on conflict (actor_id, play_id) do update set
       revision_id = excluded.revision_id,
       saved = excluded.saved,
       event_received_at = excluded.event_received_at,
       event_id = excluded.event_id,
       updated_at = now()
     where (excluded.event_received_at, excluded.event_id)
           > (actor_saved_plays.event_received_at, actor_saved_plays.event_id)`,
    [event.actorId, identity.playId, identity.revisionId, saved, receivedAt, event.eventId],
  );
}

async function projectPlaySignal(
  client: PoolClient,
  event: EventInput,
  receivedAt: string,
  signal: 'more_like_this' | 'not_interested',
): Promise<void> {
  const identity = playIdentity(event);
  await assertPlayRevision(client, identity.playId, identity.revisionId);
  await client.query(
    `insert into actor_play_signals (
       actor_id, play_id, revision_id, signal, first_received_at, first_event_id
     ) values ($1, $2, $3, $4, $5, $6)
     on conflict (actor_id, play_id, signal) do nothing`,
    [event.actorId, identity.playId, identity.revisionId, signal, receivedAt, event.eventId],
  );
}

async function projectTopicMute(
  client: PoolClient,
  event: EventInput,
  receivedAt: string,
  muted: boolean,
): Promise<void> {
  const topicId = payloadText(event, 'topicId', 200);
  await assertTopic(client, topicId);
  await client.query(
    `insert into actor_topic_mutes (
       actor_id, topic_id, muted, event_received_at, event_id
     ) values ($1, $2, $3, $4, $5)
     on conflict (actor_id, topic_id) do update set
       muted = excluded.muted,
       event_received_at = excluded.event_received_at,
       event_id = excluded.event_id,
       updated_at = now()
     where (excluded.event_received_at, excluded.event_id)
           > (actor_topic_mutes.event_received_at, actor_topic_mutes.event_id)`,
    [event.actorId, topicId, muted, receivedAt, event.eventId],
  );
}

async function validateReport(client: PoolClient, event: EventInput): Promise<void> {
  const identity = playIdentity(event);
  const reason = payloadText(event, 'reason', 40) as PlayReportReason;
  if (!(PLAY_REPORT_REASONS as readonly string[]).includes(reason)) {
    throw new ConsumerActionEventError(
      `Unsupported report reason. Expected one of ${PLAY_REPORT_REASONS.join(', ')}.`,
    );
  }
  const dismiss = event.payload.dismiss;
  if (dismiss !== undefined && typeof dismiss !== 'boolean') {
    throw new ConsumerActionEventError('Report dismiss must be a boolean when present.');
  }
  await assertPlayRevision(client, identity.playId, identity.revisionId);
}

async function invalidateFeedDecisions(client: PoolClient, actorId: string): Promise<void> {
  await client.query('delete from feed_decisions where actor_id = $1', [actorId]);
}

function playIdentity(event: EventInput): {playId: string; revisionId: string} {
  const playId = payloadText(event, 'playId', 200);
  const revisionId = requiredText(event.playRevisionId, 'playRevisionId', 200);
  return {playId, revisionId};
}

async function assertPlayRevision(
  client: PoolClient,
  playId: string,
  revisionId: string,
): Promise<void> {
  const result = await client.query(
    `select 1 from play_revisions where play_id = $1 and revision_id = $2`,
    [playId, revisionId],
  );
  if (result.rowCount !== 1) {
    throw new ConsumerActionEventError('Consumer action references an unknown Play revision.');
  }
}

async function assertTopic(client: PoolClient, topicId: string): Promise<void> {
  const result = await client.query('select 1 from topics where id = $1', [topicId]);
  if (result.rowCount !== 1) {
    throw new ConsumerActionEventError('Consumer action references an unknown topic.');
  }
}

function payloadText(event: EventInput, key: string, maxLength: number): string {
  return requiredText(event.payload[key], `payload.${key}`, maxLength);
}

function requiredText(value: unknown, name: string, maxLength: number): string {
  if (typeof value !== 'string') {
    throw new ConsumerActionEventError(`${name} must be a string.`);
  }
  const normalized = value.trim();
  if (
    normalized.length === 0 ||
    normalized.length > maxLength ||
    /[\u0000-\u001F\u007F]/.test(normalized)
  ) {
    throw new ConsumerActionEventError(
      `${name} must be between 1 and ${maxLength} printable characters.`,
    );
  }
  return normalized;
}

import {timingSafeEqual} from 'node:crypto';
import {Pool} from 'pg';
import {
  isConsumerActionEvent,
  projectConsumerActionEvent,
} from './consumer_actions.js';

export interface EventInput {
  eventId: string;
  event: string;
  version: number;
  occurredAt: string;
  actorId: string;
  sessionId: string;
  feedRequestId?: string;
  playRevisionId?: string;
  payload: Record<string, unknown>;
}

export type ActorAccessRegistration =
  | 'created'
  | 'existing'
  | 'legacy_actor_requires_rotation'
  | 'credential_conflict';

export interface MosaicRepository {
  ping(): Promise<void>;
  createActor(actorId: string): Promise<void>;
  registerActorAccess(actorId: string, credentialDigest: string): Promise<ActorAccessRegistration>;
  verifyActorAccess(actorId: string, credentialDigest: string): Promise<boolean>;
  bindActorToUser(actorId: string, userId: string): Promise<void>;
  getPlayRevision(playId: string, revisionId: string): Promise<unknown | null>;
  insertEvent(event: EventInput): Promise<'inserted' | 'duplicate'>;
}

const INSERT_EVENT_SQL = `insert into interaction_events (
   event_id, event_name, event_version, occurred_at, actor_id, session_id,
   feed_request_id, play_revision_id, payload
 ) values ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb)
 on conflict (event_id) do nothing
 returning received_at::text as received_at`;

type InsertedEventRow = {received_at: string};

export class PostgresRepository implements MosaicRepository {
  constructor(private readonly pool: Pool) {}

  async ping(): Promise<void> {
    await this.pool.query('select 1');
  }

  async createActor(actorId: string): Promise<void> {
    await this.pool.query(
      `insert into actors (id) values ($1)
       on conflict (id) do nothing`,
      [actorId],
    );
  }

  async registerActorAccess(
    actorId: string,
    credentialDigest: string,
  ): Promise<ActorAccessRegistration> {
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      const insertedActor = await client.query<{id: string}>(
        `insert into actors (id) values ($1)
         on conflict (id) do nothing
         returning id`,
        [actorId],
      );
      await client.query('select id from actors where id = $1 for update', [actorId]);
      const credential = await client.query<{credential_digest: string}>(
        `select credential_digest
           from actor_access_credentials
          where actor_id = $1`,
        [actorId],
      );
      const existingDigest = credential.rows[0]?.credential_digest;
      if (existingDigest === undefined) {
        if (insertedActor.rowCount !== 1) {
          await client.query('rollback');
          return 'legacy_actor_requires_rotation';
        }
        await client.query(
          `insert into actor_access_credentials (actor_id, credential_digest)
           values ($1, $2)`,
          [actorId, credentialDigest],
        );
        await client.query('commit');
        return 'created';
      }

      const matches = constantTimeDigestEquals(existingDigest, credentialDigest);
      await client.query('commit');
      return matches ? 'existing' : 'credential_conflict';
    } catch (error) {
      await client.query('rollback');
      throw error;
    } finally {
      client.release();
    }
  }

  async verifyActorAccess(actorId: string, credentialDigest: string): Promise<boolean> {
    const result = await this.pool.query<{credential_digest: string}>(
      `select credential_digest
         from actor_access_credentials
        where actor_id = $1`,
      [actorId],
    );
    const existingDigest = result.rows[0]?.credential_digest;
    return existingDigest !== undefined && constantTimeDigestEquals(existingDigest, credentialDigest);
  }

  async bindActorToUser(actorId: string, userId: string): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      await client.query(
        `insert into users (id) values ($1)
         on conflict (id) do nothing`,
        [userId],
      );
      await client.query(
        `insert into actor_user_merges (actor_id, user_id)
         values ($1, $2)
         on conflict (actor_id) do update set user_id = excluded.user_id, merged_at = now()`,
        [actorId, userId],
      );
      await client.query('commit');
    } catch (error) {
      await client.query('rollback');
      throw error;
    } finally {
      client.release();
    }
  }

  async getPlayRevision(playId: string, revisionId: string): Promise<unknown | null> {
    const result = await this.pool.query<{document: unknown}>(
      `select document
         from play_revisions
        where play_id = $1 and revision_id = $2`,
      [playId, revisionId],
    );
    return result.rows[0]?.document ?? null;
  }

  async insertEvent(event: EventInput): Promise<'inserted' | 'duplicate'> {
    if (!isConsumerActionEvent(event.event)) {
      const result = await this.pool.query<InsertedEventRow>(
        INSERT_EVENT_SQL,
        eventValues(event),
      );
      return result.rowCount === 1 ? 'inserted' : 'duplicate';
    }

    const client = await this.pool.connect();
    try {
      await client.query('begin');
      const result = await client.query<InsertedEventRow>(
        INSERT_EVENT_SQL,
        eventValues(event),
      );
      if (result.rowCount !== 1) {
        await client.query('commit');
        return 'duplicate';
      }
      const receivedAt = result.rows[0]?.received_at;
      if (receivedAt === undefined) {
        throw new Error('Inserted event did not return server receipt time.');
      }
      await projectConsumerActionEvent(client, event, receivedAt);
      await client.query('commit');
      return 'inserted';
    } catch (error) {
      await client.query('rollback').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  }
}

function eventValues(event: EventInput): unknown[] {
  return [
    event.eventId,
    event.event,
    event.version,
    event.occurredAt,
    event.actorId,
    event.sessionId,
    event.feedRequestId ?? null,
    event.playRevisionId ?? null,
    JSON.stringify(event.payload),
  ];
}

function constantTimeDigestEquals(left: string, right: string): boolean {
  if (!/^[0-9a-f]{64}$/.test(left) || !/^[0-9a-f]{64}$/.test(right)) return false;
  return timingSafeEqual(Buffer.from(left, 'hex'), Buffer.from(right, 'hex'));
}

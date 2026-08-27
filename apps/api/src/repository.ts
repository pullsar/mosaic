import {Pool} from 'pg';

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

export interface MosaicRepository {
  ping(): Promise<void>;
  createActor(actorId: string): Promise<void>;
  bindActorToUser(actorId: string, userId: string): Promise<void>;
  getPlayRevision(playId: string, revisionId: string): Promise<unknown | null>;
  insertEvent(event: EventInput): Promise<'inserted' | 'duplicate'>;
}

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
    const result = await this.pool.query(
      `insert into interaction_events (
         event_id, event_name, event_version, occurred_at, actor_id, session_id,
         feed_request_id, play_revision_id, payload
       ) values ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb)
       on conflict (event_id) do nothing`,
      [
        event.eventId,
        event.event,
        event.version,
        event.occurredAt,
        event.actorId,
        event.sessionId,
        event.feedRequestId ?? null,
        event.playRevisionId ?? null,
        JSON.stringify(event.payload),
      ],
    );
    return result.rowCount === 1 ? 'inserted' : 'duplicate';
  }
}

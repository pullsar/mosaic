import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import {buildApp} from '../src/app.js';
import type {EventInput, MosaicRepository} from '../src/repository.js';

class MemoryRepository implements MosaicRepository {
  actors = new Set<string>();
  bindings = new Map<string, string>();
  events = new Map<string, EventInput>();
  plays = new Map<string, unknown>();

  async ping(): Promise<void> {}
  async createActor(actorId: string): Promise<void> { this.actors.add(actorId); }
  async bindActorToUser(actorId: string, userId: string): Promise<void> { this.bindings.set(actorId, userId); }
  async getPlayRevision(playId: string, revisionId: string): Promise<unknown | null> {
    return this.plays.get(`${playId}/${revisionId}`) ?? null;
  }
  async insertEvent(event: EventInput): Promise<'inserted' | 'duplicate'> {
    if (this.events.has(event.eventId)) return 'duplicate';
    this.events.set(event.eventId, event);
    return 'inserted';
  }
}

const capabilities = {
  schemaVersions: [1],
  presentationTypes: ['text', 'video_clip'],
  inputTypes: ['tap', 'single_choice'],
  validatorTypes: ['none', 'equals'],
  platformFlags: [],
};

test('actor creation, binding and event ingestion are idempotent', async () => {
  const repo = new MemoryRepository();
  const app = buildApp({repository: repo, logLevel: 'silent'});

  const actor = await app.inject({method: 'POST', url: '/v1/actors', payload: {actorId: 'actor_a'}});
  assert.equal(actor.statusCode, 201);

  const binding = await app.inject({
    method: 'POST',
    url: '/v1/actors/actor_a/bind-user',
    payload: {userId: 'user_a'},
  });
  assert.equal(binding.statusCode, 204);
  assert.equal(repo.bindings.get('actor_a'), 'user_a');

  const payload = {
    eventId: 'evt_1',
    event: 'play_started',
    version: 1,
    occurredAt: '2026-08-27T18:00:00Z',
    actorId: 'actor_a',
    sessionId: 'session_a',
    payload: {},
  };
  const first = await app.inject({method: 'POST', url: '/v1/events', payload});
  const duplicate = await app.inject({method: 'POST', url: '/v1/events', payload});
  assert.equal(first.statusCode, 202);
  assert.equal(duplicate.statusCode, 200);
  assert.equal(repo.events.size, 1);

  await app.close();
});

test('Play read route enforces requesting client capabilities', async () => {
  const repo = new MemoryRepository();
  const raw = JSON.parse(
    await readFile('../../packages/play_schema/fixtures/where_is_this.json', 'utf8'),
  ) as Record<string, unknown>;
  repo.plays.set(`${raw.id}/${raw.revisionId}`, raw);
  const app = buildApp({repository: repo, logLevel: 'silent'});

  const ok = await app.inject({
    method: 'POST',
    url: `/v1/plays/${raw.id}/revisions/${raw.revisionId}`,
    payload: capabilities,
  });
  assert.equal(ok.statusCode, 200);

  const unsupported = await app.inject({
    method: 'POST',
    url: `/v1/plays/${raw.id}/revisions/${raw.revisionId}`,
    payload: {...capabilities, presentationTypes: ['text']},
  });
  assert.equal(unsupported.statusCode, 409);
  assert.deepEqual(unsupported.json().missing, ['presentation:video_clip']);

  await app.close();
});

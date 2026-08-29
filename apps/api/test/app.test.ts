import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import {buildApp} from '../src/app.js';
import type {
  ActorAccessRegistration,
  EventInput,
  MosaicRepository,
} from '../src/repository.js';

class MemoryRepository implements MosaicRepository {
  actors = new Set<string>();
  credentials = new Map<string, string>();
  bindings = new Map<string, string>();
  events = new Map<string, EventInput>();
  plays = new Map<string, unknown>();

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
  async bindActorToUser(actorId: string, userId: string): Promise<void> {
    this.bindings.set(actorId, userId);
  }
  async getPlayRevision(playId: string, revisionId: string): Promise<unknown | null> {
    return this.plays.get(`${playId}/${revisionId}`) ?? null;
  }
  async insertEvent(event: EventInput): Promise<'inserted' | 'duplicate'> {
    if (this.events.has(event.eventId)) return 'duplicate';
    this.events.set(event.eventId, event);
    return 'inserted';
  }
}

const actorToken = 'A'.repeat(43);
const otherToken = 'B'.repeat(43);
const actorAuthorization = {authorization: `Bearer ${actorToken}`};
const capabilities = {
  schemaVersions: [1],
  presentationTypes: ['text', 'video_clip'],
  inputTypes: ['tap', 'single_choice'],
  validatorTypes: ['none', 'equals'],
  platformFlags: [],
};

test('actor ownership protects registration, binding and idempotent events', async () => {
  const repo = new MemoryRepository();
  const app = buildApp({repository: repo, logLevel: 'silent'});

  const actor = await app.inject({
    method: 'POST',
    url: '/v1/actors',
    headers: actorAuthorization,
    payload: {actorId: 'actor_a'},
  });
  assert.equal(actor.statusCode, 201);

  const exactRegistration = await app.inject({
    method: 'POST',
    url: '/v1/actors',
    headers: actorAuthorization,
    payload: {actorId: 'actor_a'},
  });
  assert.equal(exactRegistration.statusCode, 200);

  const conflictingRegistration = await app.inject({
    method: 'POST',
    url: '/v1/actors',
    headers: {authorization: `Bearer ${otherToken}`},
    payload: {actorId: 'actor_a'},
  });
  assert.equal(conflictingRegistration.statusCode, 403);

  const binding = await app.inject({
    method: 'POST',
    url: '/v1/actors/actor_a/bind-user',
    headers: actorAuthorization,
    payload: {userId: 'user_a'},
  });
  assert.equal(binding.statusCode, 501);
  assert.equal(repo.bindings.size, 0);

  const payload = {
    eventId: 'evt_1',
    event: 'play_started',
    version: 1,
    occurredAt: '2026-08-27T18:00:00Z',
    actorId: 'actor_a',
    sessionId: 'session_a',
    payload: {},
  };
  const unauthenticated = await app.inject({method: 'POST', url: '/v1/events', payload});
  assert.equal(unauthenticated.statusCode, 401);
  const spoofed = await app.inject({
    method: 'POST',
    url: '/v1/events',
    headers: {authorization: `Bearer ${otherToken}`},
    payload,
  });
  assert.equal(spoofed.statusCode, 403);

  const first = await app.inject({
    method: 'POST',
    url: '/v1/events',
    headers: actorAuthorization,
    payload,
  });
  const duplicate = await app.inject({
    method: 'POST',
    url: '/v1/events',
    headers: actorAuthorization,
    payload,
  });
  assert.equal(first.statusCode, 202);
  assert.equal(duplicate.statusCode, 200);
  assert.equal(repo.events.size, 1);

  await app.close();
});

test('legacy actors cannot be claimed by first supplied credential', async () => {
  const repo = new MemoryRepository();
  await repo.createActor('legacy_actor');
  const app = buildApp({repository: repo, logLevel: 'silent'});

  const registration = await app.inject({
    method: 'POST',
    url: '/v1/actors',
    headers: actorAuthorization,
    payload: {actorId: 'legacy_actor'},
  });
  assert.equal(registration.statusCode, 409);
  assert.equal(registration.json().error, 'actor_rotation_required');

  await app.close();
});

test('explicit CORS allowlist permits configured web origin only', async () => {
  const repo = new MemoryRepository();
  const app = buildApp({
    repository: repo,
    logLevel: 'silent',
    allowedWebOrigins: ['https://app.mosaic.example'],
  });

  const preflight = await app.inject({
    method: 'OPTIONS',
    url: '/v1/feed',
    headers: {
      origin: 'https://app.mosaic.example',
      'access-control-request-method': 'POST',
      'access-control-request-headers': 'content-type,authorization',
    },
  });
  assert.equal(preflight.statusCode, 204);
  assert.equal(preflight.headers['access-control-allow-origin'], 'https://app.mosaic.example');
  assert.equal(preflight.headers['access-control-allow-methods'], 'GET,POST,PUT,OPTIONS');
  assert.equal(preflight.headers['access-control-allow-headers'], 'content-type,authorization');
  assert.equal(preflight.headers.vary, 'Origin');
  assert.equal(preflight.headers['access-control-allow-credentials'], undefined);

  const rejected = await app.inject({
    method: 'OPTIONS',
    url: '/v1/feed',
    headers: {origin: 'https://evil.example'},
  });
  assert.equal(rejected.statusCode, 403);
  assert.equal(rejected.headers['access-control-allow-origin'], undefined);

  const native = await app.inject({method: 'GET', url: '/health'});
  assert.equal(native.statusCode, 200);

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

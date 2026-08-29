import assert from 'node:assert/strict';
import {test} from 'node:test';
import {buildApp} from '../src/app.js';
import type {EventInput, MosaicRepository} from '../src/repository.js';

class MetricsRepository implements MosaicRepository {
  async ping(): Promise<void> {}
  async createActor(_actorId: string): Promise<void> {}
  async bindActorToUser(_actorId: string, _userId: string): Promise<void> {}
  async getPlayRevision(_playId: string, _revisionId: string): Promise<unknown | null> { return null; }
  async insertEvent(_event: EventInput): Promise<'inserted' | 'duplicate'> { return 'inserted'; }
}

test('metrics expose bounded HTTP labels and active release information', async () => {
  const app = buildApp({
    repository: new MetricsRepository(),
    logLevel: 'silent',
    releaseSha: 'b5098ec72c804b6df97a7017681ea17b9843d73c',
  });

  const health = await app.inject({method: 'GET', url: '/health'});
  assert.equal(health.headers['x-mixli-release'], 'b5098ec72c804b6df97a7017681ea17b9843d73c');
  await app.inject({
    method: 'POST',
    url: '/v1/actors/actor-sensitive-id/bind-user',
    payload: {userId: 'user-sensitive-id'},
  });

  const response = await app.inject({method: 'GET', url: '/metrics'});
  assert.equal(response.statusCode, 200);
  assert.match(response.headers['content-type'] ?? '', /text\/plain/);
  assert.match(response.body, /mixli_http_requests_total\{method="GET",route="\/health",status_class="2xx"\} 1/);
  assert.match(response.body, /mixli_http_request_duration_seconds_count\{method="POST",route="\/v1\/actors\/:actorId\/bind-user",status_class="2xx"\} 1/);
  assert.match(response.body, /mixli_release_info\{sha="b5098ec72c804b6df97a7017681ea17b9843d73c"\} 1/);
  assert.doesNotMatch(response.body, /actor-sensitive-id|user-sensitive-id/);

  await app.close();
});

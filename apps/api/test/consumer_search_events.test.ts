import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  ConsumerSearchEventError,
  validateConsumerSearchEvent,
} from '../src/consumer_search_events.js';
import type {EventInput} from '../src/repository.js';

const base = {
  eventId: 'event_search',
  version: 1,
  occurredAt: '2026-08-31T04:00:00Z',
  actorId: 'actor_search',
  sessionId: 'session_search',
} as const;
const queryHash = 'a'.repeat(64);

function event(event: string, payload: Record<string, unknown>): EventInput {
  return {...base, event, payload};
}

test('search telemetry accepts bounded fingerprints and canonical result identity only', () => {
  assert.doesNotThrow(() =>
    validateConsumerSearchEvent(
      event('search_submitted', {
        requestId: 'search_request',
        intent: 'interest',
        queryHash,
        queryLength: 6,
        resultCount: 2,
        zeroResults: false,
      }),
    ),
  );
  assert.doesNotThrow(() =>
    validateConsumerSearchEvent(
      event('search_result_selected', {
        requestId: 'search_request',
        intent: 'learning',
        queryHash,
        resultKind: 'play',
        playId: 'play_travel',
        revisionId: 'revision_1',
      }),
    ),
  );
  assert.doesNotThrow(() =>
    validateConsumerSearchEvent(
      event('search_abandoned', {
        requestId: 'search_request',
        intent: 'interest',
        queryHash,
        resultCount: 0,
      }),
    ),
  );
});

test('search telemetry rejects raw query text, unknown fields and fake feed attribution', () => {
  assert.throws(
    () =>
      validateConsumerSearchEvent(
        event('search_submitted', {
          requestId: 'search_request',
          intent: 'interest',
          queryHash,
          queryLength: 6,
          resultCount: 0,
          zeroResults: true,
          query: 'travel',
        }),
      ),
    ConsumerSearchEventError,
  );
  assert.throws(
    () =>
      validateConsumerSearchEvent({
        ...event('search_abandoned', {
          requestId: 'search_request',
          intent: 'interest',
          queryHash,
          resultCount: 1,
        }),
        feedRequestId: 'not_a_feed_request',
      }),
    ConsumerSearchEventError,
  );
});

import type {EventInput} from './repository.js';

export const CONSUMER_SEARCH_EVENT = Object.freeze({
  submitted: 'search_submitted',
  resultSelected: 'search_result_selected',
  abandoned: 'search_abandoned',
} as const);

const SEARCH_EVENTS = new Set<string>(Object.values(CONSUMER_SEARCH_EVENT));
const QUERY_HASH = /^[0-9a-f]{64}$/;

export class ConsumerSearchEventError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConsumerSearchEventError';
  }
}

export function isConsumerSearchEvent(eventName: string): boolean {
  return SEARCH_EVENTS.has(eventName);
}

export function validateConsumerSearchEvent(event: EventInput): void {
  if (!isConsumerSearchEvent(event.event)) return;
  if (event.version !== 1) {
    throw new ConsumerSearchEventError('Search telemetry requires version 1.');
  }
  if (event.feedRequestId !== undefined || event.playRevisionId !== undefined) {
    throw new ConsumerSearchEventError('Search telemetry cannot reuse feed or Play attribution.');
  }
  if ('query' in event.payload || 'rawQuery' in event.payload || 'text' in event.payload) {
    throw new ConsumerSearchEventError('Raw search text is not accepted in telemetry.');
  }

  switch (event.event) {
    case CONSUMER_SEARCH_EVENT.submitted:
      assertExactKeys(event.payload, [
        'requestId',
        'intent',
        'queryHash',
        'queryLength',
        'resultCount',
        'zeroResults',
      ]);
      requiredText(event.payload.requestId, 'requestId', 200);
      requiredIntent(event.payload.intent);
      requiredQueryHash(event.payload.queryHash);
      requiredInteger(event.payload.queryLength, 'queryLength', 1, 80);
      requiredInteger(event.payload.resultCount, 'resultCount', 0, 60);
      if (typeof event.payload.zeroResults !== 'boolean') {
        throw new ConsumerSearchEventError('zeroResults must be a boolean.');
      }
      return;
    case CONSUMER_SEARCH_EVENT.resultSelected: {
      const kind = event.payload.resultKind;
      if (kind === 'topic') {
        assertExactKeys(event.payload, [
          'requestId',
          'intent',
          'queryHash',
          'resultKind',
          'topicId',
        ]);
        requiredText(event.payload.topicId, 'topicId', 200);
      } else if (kind === 'play') {
        assertExactKeys(event.payload, [
          'requestId',
          'intent',
          'queryHash',
          'resultKind',
          'playId',
          'revisionId',
        ]);
        requiredText(event.payload.playId, 'playId', 200);
        requiredText(event.payload.revisionId, 'revisionId', 200);
      } else {
        throw new ConsumerSearchEventError('resultKind must be topic or play.');
      }
      requiredText(event.payload.requestId, 'requestId', 200);
      requiredIntent(event.payload.intent);
      requiredQueryHash(event.payload.queryHash);
      return;
    }
    case CONSUMER_SEARCH_EVENT.abandoned:
      assertExactKeys(event.payload, ['requestId', 'intent', 'queryHash', 'resultCount']);
      requiredText(event.payload.requestId, 'requestId', 200);
      requiredIntent(event.payload.intent);
      requiredQueryHash(event.payload.queryHash);
      requiredInteger(event.payload.resultCount, 'resultCount', 0, 60);
      return;
  }
}

function assertExactKeys(payload: Record<string, unknown>, keys: readonly string[]): void {
  const expected = [...keys].sort();
  const actual = Object.keys(payload).sort();
  if (expected.length !== actual.length || expected.some((key, index) => key !== actual[index])) {
    throw new ConsumerSearchEventError('Search telemetry payload contains unexpected fields.');
  }
}

function requiredIntent(value: unknown): void {
  if (value !== 'interest' && value !== 'learning') {
    throw new ConsumerSearchEventError('intent must be interest or learning.');
  }
}

function requiredQueryHash(value: unknown): void {
  if (typeof value !== 'string' || !QUERY_HASH.test(value)) {
    throw new ConsumerSearchEventError('queryHash must be SHA-256 hex.');
  }
}

function requiredText(value: unknown, name: string, maxLength: number): string {
  if (typeof value !== 'string') {
    throw new ConsumerSearchEventError(`${name} must be a string.`);
  }
  const normalized = value.trim();
  if (
    normalized.length === 0 ||
    normalized.length > maxLength ||
    /[\u0000-\u001f\u007f]/u.test(normalized)
  ) {
    throw new ConsumerSearchEventError(`${name} must be bounded printable text.`);
  }
  return normalized;
}

function requiredInteger(
  value: unknown,
  name: string,
  min: number,
  max: number,
): number {
  if (!Number.isSafeInteger(value) || (value as number) < min || (value as number) > max) {
    throw new ConsumerSearchEventError(`${name} must be an integer between ${min} and ${max}.`);
  }
  return value as number;
}

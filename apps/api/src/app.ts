import Fastify, {type FastifyInstance} from 'fastify';
import {randomUUID} from 'node:crypto';
import {
  checkPlayCompatibility,
  parseClientCapabilities,
} from './contracts/compatibility.js';
import {ConsumerFeedService, InvalidFeedCursorError} from './consumer_feed.js';
import {
  type ConsumerRepository,
  UnknownTopicError,
} from './consumer_repository.js';
import type {EventInput, MosaicRepository} from './repository.js';

export interface BuildAppOptions {
  repository: MosaicRepository;
  consumerRepository?: ConsumerRepository;
  logLevel?: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function parseEvent(value: unknown): EventInput | null {
  if (!isRecord(value)) return null;
  const requiredStrings = ['eventId', 'event', 'occurredAt', 'actorId', 'sessionId'] as const;
  for (const key of requiredStrings) {
    if (typeof value[key] !== 'string' || (value[key] as string).length === 0) return null;
  }
  if (!Number.isInteger(value.version)) return null;
  if (!isRecord(value.payload)) return null;
  return {
    eventId: value.eventId as string,
    event: value.event as string,
    version: value.version as number,
    occurredAt: value.occurredAt as string,
    actorId: value.actorId as string,
    sessionId: value.sessionId as string,
    ...(typeof value.feedRequestId === 'string' ? {feedRequestId: value.feedRequestId} : {}),
    ...(typeof value.playRevisionId === 'string' ? {playRevisionId: value.playRevisionId} : {}),
    payload: value.payload,
  };
}

export function buildApp(options: BuildAppOptions): FastifyInstance {
  const app = Fastify({
    logger: {level: options.logLevel ?? 'info'},
    genReqId: () => randomUUID(),
    disableRequestLogging: false,
  });
  const feedService = options.consumerRepository
    ? new ConsumerFeedService(options.consumerRepository, {
        onRankingError: (error) =>
          app.log.error({err: error}, 'consumer ranking failed; using curated fallback'),
      })
    : null;

  app.get('/health', async () => ({status: 'ok'}));
  app.get('/ready', async (_request, reply) => {
    try {
      await options.repository.ping();
      return {status: 'ready'};
    } catch {
      return reply.code(503).send({status: 'not_ready'});
    }
  });

  app.post('/v1/actors', async (request, reply) => {
    if (
      !isRecord(request.body) ||
      typeof request.body.actorId !== 'string' ||
      request.body.actorId.length === 0
    ) {
      return reply.code(400).send({error: 'invalid_actor'});
    }
    await options.repository.createActor(request.body.actorId);
    return reply.code(201).send({actorId: request.body.actorId});
  });

  app.post('/v1/actors/:actorId/bind-user', async (request, reply) => {
    const params = request.params as {actorId?: string};
    if (!params.actorId || !isRecord(request.body) || typeof request.body.userId !== 'string') {
      return reply.code(400).send({error: 'invalid_binding'});
    }
    await options.repository.bindActorToUser(params.actorId, request.body.userId);
    return reply.code(204).send();
  });

  app.post('/v1/events', async (request, reply) => {
    const event = parseEvent(request.body);
    if (!event) return reply.code(400).send({error: 'invalid_event'});
    const status = await options.repository.insertEvent(event);
    return reply.code(status === 'inserted' ? 202 : 200).send({status});
  });

  app.post('/v1/plays/:playId/revisions/:revisionId', async (request, reply) => {
    const params = request.params as {playId?: string; revisionId?: string};
    const capabilities = parseClientCapabilities(request.body);
    if (!params.playId || !params.revisionId || !capabilities) {
      return reply.code(400).send({error: 'invalid_request'});
    }
    const document = await options.repository.getPlayRevision(params.playId, params.revisionId);
    if (document === null) return reply.code(404).send({error: 'play_revision_not_found'});

    const compatibility = checkPlayCompatibility(document, capabilities);
    if (!compatibility.compatible) {
      return reply.code(409).send({
        error: 'play_not_supported',
        reason: compatibility.reason,
        missing: compatibility.missing,
      });
    }
    return reply.send(document);
  });

  if (options.consumerRepository && feedService) {
    const consumerRepository = options.consumerRepository;

    app.get('/v1/topics', async (request, reply) => {
      const query = isRecord(request.query) ? request.query : {};
      const search = optionalText(query.q, 100);
      const limit = optionalInteger(query.limit, 30, 1, 100);
      if (search === null || limit === null) {
        return reply.code(400).send({error: 'invalid_topic_search'});
      }
      const topics = await consumerRepository.searchTopics(search, limit);
      return {topics};
    });

    app.get('/v1/actors/:actorId/preferences', async (request, reply) => {
      const params = request.params as {actorId?: string};
      const actorId = boundedText(params.actorId, 200);
      if (actorId === null) return reply.code(400).send({error: 'invalid_actor'});
      return consumerRepository.getTopicPreferences(actorId);
    });

    app.put('/v1/actors/:actorId/preferences', async (request, reply) => {
      const params = request.params as {actorId?: string};
      const actorId = boundedText(params.actorId, 200);
      if (actorId === null || !isRecord(request.body)) {
        return reply.code(400).send({error: 'invalid_preferences'});
      }
      const interestTopicIds = textArray(request.body.interestTopicIds, 64, 200);
      const learningTopicIds = textArray(request.body.learningTopicIds, 64, 200);
      if (interestTopicIds === null || learningTopicIds === null) {
        return reply.code(400).send({error: 'invalid_preferences'});
      }
      try {
        await consumerRepository.replaceTopicPreferences(
          actorId,
          interestTopicIds,
          learningTopicIds,
        );
      } catch (error) {
        if (error instanceof UnknownTopicError) {
          return reply.code(400).send({error: 'unknown_topic', topicIds: error.topicIds});
        }
        if (isInputError(error)) {
          return reply.code(400).send({error: 'invalid_preferences'});
        }
        throw error;
      }
      return reply.code(204).send();
    });

    app.post('/v1/feed', async (request, reply) => {
      if (!isRecord(request.body)) return reply.code(400).send({error: 'invalid_feed_request'});
      const actorId = boundedText(request.body.actorId, 200);
      const capabilities = parseClientCapabilities(request.body.capabilities);
      const cursor = nullableText(request.body.cursor, 512);
      const limit = optionalInteger(request.body.limit, 8, 1, 20);
      if (actorId === null || !capabilities || cursor === undefined || limit === null) {
        return reply.code(400).send({error: 'invalid_feed_request'});
      }
      try {
        return await feedService.getFeed({actorId, capabilities, cursor, limit});
      } catch (error) {
        if (error instanceof InvalidFeedCursorError) {
          return reply.code(400).send({error: 'invalid_feed_cursor'});
        }
        if (isInputError(error)) {
          return reply.code(400).send({error: 'invalid_feed_request'});
        }
        throw error;
      }
    });
  }

  return app;
}

function boundedText(value: unknown, maxLength: number): string | null {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  return text.length > 0 && text.length <= maxLength ? text : null;
}

function optionalText(value: unknown, maxLength: number): string | null {
  if (value === undefined) return '';
  if (typeof value !== 'string') return null;
  const text = value.trim();
  return text.length <= maxLength ? text : null;
}

function nullableText(value: unknown, maxLength: number): string | null | undefined {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string') return undefined;
  const text = value.trim();
  return text.length > 0 && text.length <= maxLength ? text : undefined;
}

function textArray(value: unknown, maxCount: number, maxLength: number): string[] | null {
  if (!Array.isArray(value) || value.length > maxCount) return null;
  const result: string[] = [];
  for (const item of value) {
    const text = boundedText(item, maxLength);
    if (text === null) return null;
    result.push(text);
  }
  return result;
}

function optionalInteger(
  value: unknown,
  fallback: number,
  min: number,
  max: number,
): number | null {
  if (value === undefined) return fallback;
  const parsed =
    typeof value === 'number'
      ? value
      : typeof value === 'string' && /^\d+$/.test(value)
        ? Number(value)
        : Number.NaN;
  return Number.isSafeInteger(parsed) && parsed >= min && parsed <= max ? parsed : null;
}

function isInputError(error: unknown): error is TypeError | RangeError {
  return error instanceof TypeError || error instanceof RangeError;
}

import {createHash, randomUUID} from 'node:crypto';
import Fastify, {
  type FastifyInstance,
  type FastifyReply,
  type FastifyRequest,
} from 'fastify';
import {
  checkPlayCompatibility,
  parseClientCapabilities,
} from './contracts/compatibility.js';
import {ConsumerFeedService, InvalidFeedCursorError} from './consumer_feed.js';
import {
  type ConsumerRepository,
  UnknownTopicError,
} from './consumer_repository.js';
import type {FeedAssetReadinessResolver} from './feed_asset_readiness.js';
import type {EventInput, MosaicRepository} from './repository.js';

const ACTOR_ACCESS_TOKEN = /^[A-Za-z0-9_-]{43}$/;
const CORS_METHODS = 'GET,HEAD,POST,PUT,OPTIONS';
const CORS_HEADERS = 'content-type,authorization,range';
const CORS_EXPOSE_HEADERS = 'accept-ranges,content-length,content-range';

export interface BuildAppOptions {
  repository: MosaicRepository;
  consumerRepository?: ConsumerRepository;
  feedAssetReadiness?: FeedAssetReadinessResolver;
  logLevel?: string;
  allowedWebOrigins?: readonly string[];
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
  const allowedWebOrigins = new Set(options.allowedWebOrigins ?? []);
  const feedService = options.consumerRepository
    ? new ConsumerFeedService(options.consumerRepository, {
        onRankingError: (error) =>
          app.log.error({err: error}, 'consumer ranking failed; using curated fallback'),
        ...(options.feedAssetReadiness === undefined
          ? {}
          : {assetReadiness: options.feedAssetReadiness}),
      })
    : null;

  app.addHook('onRequest', async (request, reply) => {
    const origin = request.headers.origin;
    if (origin === undefined) return;
    if (!allowedWebOrigins.has(origin)) {
      return reply.code(403).send({error: 'origin_not_allowed'});
    }
    reply.header('access-control-allow-origin', origin);
    reply.header('vary', 'Origin');
    reply.header('access-control-allow-methods', CORS_METHODS);
    reply.header('access-control-allow-headers', CORS_HEADERS);
    reply.header('access-control-expose-headers', CORS_EXPOSE_HEADERS);
    reply.header('access-control-max-age', '600');
    if (request.method === 'OPTIONS') {
      return reply.code(204).send();
    }
  });

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
    if (!isRecord(request.body)) return reply.code(400).send({error: 'invalid_actor'});
    const actorId = boundedText(request.body.actorId, 200);
    const digest = actorCredentialDigest(request);
    if (actorId === null || digest === null) {
      return reply.code(400).send({error: 'invalid_actor'});
    }
    const registration = await options.repository.registerActorAccess(actorId, digest);
    switch (registration) {
      case 'created':
        return reply.code(201).send({actorId});
      case 'existing':
        return reply.code(200).send({actorId});
      case 'legacy_actor_requires_rotation':
        return reply.code(409).send({error: 'actor_rotation_required'});
      case 'credential_conflict':
        return reply.code(403).send({error: 'actor_credential_rejected'});
    }
  });

  app.post('/v1/actors/:actorId/bind-user', async (request, reply) => {
    const params = request.params as {actorId?: string};
    const actorId = boundedText(params.actorId, 200);
    if (actorId === null) {
      return reply.code(400).send({error: 'invalid_binding'});
    }
    if (!(await requireActorAccess(options.repository, request, reply, actorId))) return;
    return reply.code(501).send({error: 'account_auth_not_configured'});
  });

  app.post('/v1/events', async (request, reply) => {
    const event = parseEvent(request.body);
    if (!event) return reply.code(400).send({error: 'invalid_event'});
    if (!(await requireActorAccess(options.repository, request, reply, event.actorId))) return;
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
      if (!(await requireActorAccess(options.repository, request, reply, actorId))) return;
      return consumerRepository.getTopicPreferences(actorId);
    });

    app.put('/v1/actors/:actorId/preferences', async (request, reply) => {
      const params = request.params as {actorId?: string};
      const actorId = boundedText(params.actorId, 200);
      if (actorId === null || !isRecord(request.body)) {
        return reply.code(400).send({error: 'invalid_preferences'});
      }
      if (!(await requireActorAccess(options.repository, request, reply, actorId))) return;
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
      if (!(await requireActorAccess(options.repository, request, reply, actorId))) return;
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

async function requireActorAccess(
  repository: MosaicRepository,
  request: FastifyRequest,
  reply: FastifyReply,
  actorId: string,
): Promise<boolean> {
  const digest = actorCredentialDigest(request);
  if (digest === null) {
    await reply.code(401).send({error: 'actor_credential_required'});
    return false;
  }
  if (!(await repository.verifyActorAccess(actorId, digest))) {
    await reply.code(403).send({error: 'actor_credential_rejected'});
    return false;
  }
  return true;
}

function actorCredentialDigest(request: FastifyRequest): string | null {
  const authorization = request.headers.authorization;
  if (typeof authorization !== 'string') return null;
  const match = /^Bearer ([A-Za-z0-9_-]+)$/.exec(authorization);
  const token = match?.[1];
  if (token === undefined || !ACTOR_ACCESS_TOKEN.test(token)) return null;
  return createHash('sha256').update(token, 'utf8').digest('hex');
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

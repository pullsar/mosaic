import Fastify, {type FastifyInstance} from 'fastify';
import {randomUUID} from 'node:crypto';
import type {ClientCapabilities} from './contracts/compatibility.js';
import {checkPlayCompatibility} from './contracts/compatibility.js';
import {createApiMetrics} from './metrics.js';
import type {EventInput, MosaicRepository} from './repository.js';

export interface BuildAppOptions {
  repository: MosaicRepository;
  logLevel?: string;
  releaseSha?: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function parseCapabilities(value: unknown): ClientCapabilities | null {
  if (!isRecord(value)) return null;
  const keys = ['presentationTypes', 'inputTypes', 'validatorTypes', 'platformFlags'] as const;
  const arrays: Partial<Record<(typeof keys)[number], string[]>> = {};
  for (const key of keys) {
    const raw = value[key];
    if (!Array.isArray(raw) || raw.some((item) => typeof item !== 'string')) return null;
    arrays[key] = raw as string[];
  }
  const versions = value.schemaVersions;
  if (!Array.isArray(versions) || versions.some((item) => !Number.isInteger(item))) return null;
  return {
    schemaVersions: versions as number[],
    presentationTypes: arrays.presentationTypes ?? [],
    inputTypes: arrays.inputTypes ?? [],
    validatorTypes: arrays.validatorTypes ?? [],
    platformFlags: arrays.platformFlags ?? [],
  };
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
  const releaseSha = options.releaseSha ?? 'unknown';
  const metrics = createApiMetrics(releaseSha);
  const requestStarts = new WeakMap<object, bigint>();
  const app = Fastify({
    logger: {level: options.logLevel ?? 'info'},
    genReqId: () => randomUUID(),
    disableRequestLogging: false,
  });

  app.addHook('onRequest', (request, reply, done) => {
    requestStarts.set(request, process.hrtime.bigint());
    reply.header('x-mixli-release', releaseSha);
    done();
  });

  app.addHook('onResponse', (request, reply, done) => {
    const started = requestStarts.get(request);
    const durationSeconds = started === undefined
      ? 0
      : Number(process.hrtime.bigint() - started) / 1_000_000_000;
    metrics.observeRequest({
      method: request.method,
      route: request.routeOptions.url ?? 'unmatched',
      status_class: `${Math.floor(reply.statusCode / 100)}xx`,
    }, durationSeconds);
    done();
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
  app.get('/metrics', async (_request, reply) => {
    return reply.type(metrics.registry.contentType).send(await metrics.registry.metrics());
  });

  app.post('/v1/actors', async (request, reply) => {
    if (!isRecord(request.body) || typeof request.body.actorId !== 'string' || request.body.actorId.length === 0) {
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
    const capabilities = parseCapabilities(request.body);
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

  return app;
}

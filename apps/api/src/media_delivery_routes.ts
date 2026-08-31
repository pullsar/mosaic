import type {FastifyInstance, FastifyReply, FastifyRequest} from 'fastify';
import {
  MediaDeliveryIntegrityError,
  MediaDeliveryRangeError,
  MediaDeliveryService,
  type MediaDeliveryVariant,
} from './media_delivery.js';
import {MediaPublicationBlockedError} from './media_publication.js';

const VARIANTS = new Set<MediaDeliveryVariant>(['primary', 'poster', 'captions']);
const CONTENT_CACHE_CONTROL = 'no-store';

export function registerMediaDeliveryRoutes(
  app: FastifyInstance,
  service: MediaDeliveryService,
): void {
  app.get('/v1/assets/:assetId', async (request, reply) => {
    const assetId = routeText((request.params as {assetId?: string}).assetId);
    if (assetId === null) return reply.code(400).send({error: 'invalid_asset'});
    try {
      reply.header('cache-control', 'no-store');
      return await service.describe(assetId);
    } catch (error) {
      return deliveryError(reply, error);
    }
  });

  app.route({
    method: ['GET', 'HEAD'],
    url: '/v1/assets/:assetId/content/:variant',
    handler: async (request, reply) => {
      const params = request.params as {assetId?: string; variant?: string};
      const assetId = routeText(params.assetId);
      const variant = routeVariant(params.variant);
      if (assetId === null || variant === null) {
        return reply.code(400).send({error: 'invalid_asset_delivery'});
      }
      const rangeHeader = singleHeader(request, 'range');
      if (rangeHeader === null) {
        return reply.code(400).send({error: 'invalid_range'});
      }
      try {
        const content = await service.prepareContent(
          assetId,
          variant,
          rangeHeader,
          request.method !== 'HEAD',
        );
        const length = content.range.endInclusive - content.range.start + 1;
        reply.header('accept-ranges', 'bytes');
        reply.header('cache-control', CONTENT_CACHE_CONTROL);
        reply.header('content-type', content.mimeType);
        reply.header('content-length', String(length));
        if (content.partial) {
          reply.header(
            'content-range',
            `bytes ${content.range.start}-${content.range.endInclusive}/${content.sizeBytes}`,
          );
          reply.code(206);
        }
        if (request.method === 'HEAD') return reply.send();
        return reply.send(content.body);
      } catch (error) {
        return deliveryError(reply, error);
      }
    },
  });
}

function deliveryError(reply: FastifyReply, error: unknown): FastifyReply {
  if (error instanceof MediaDeliveryRangeError) {
    reply.header('content-range', `bytes */${error.sizeBytes}`);
    reply.header('accept-ranges', 'bytes');
    return reply.code(416).send({error: 'range_not_satisfiable'});
  }
  if (error instanceof MediaPublicationBlockedError) {
    return reply.code(404).send({error: 'asset_not_deliverable'});
  }
  if (error instanceof MediaDeliveryIntegrityError) {
    return reply.code(503).send({error: 'asset_delivery_unavailable'});
  }
  if (error instanceof TypeError || error instanceof RangeError) {
    return reply.code(400).send({error: 'invalid_asset_delivery'});
  }
  throw error;
}

function routeText(value: string | undefined): string | null {
  if (typeof value !== 'string') return null;
  const normalized = value.trim();
  return normalized.length > 0 && normalized.length <= 200 ? normalized : null;
}

function routeVariant(value: string | undefined): MediaDeliveryVariant | null {
  return typeof value === 'string' && VARIANTS.has(value as MediaDeliveryVariant)
    ? value as MediaDeliveryVariant
    : null;
}

function singleHeader(request: FastifyRequest, name: 'range'): string | undefined | null {
  const value = request.headers[name];
  if (value === undefined) return undefined;
  return typeof value === 'string' ? value : null;
}

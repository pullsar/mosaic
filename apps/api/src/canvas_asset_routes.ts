import type {FastifyInstance, FastifyReply} from 'fastify';
import {
  CanvasAssetIntegrityError,
  type CanvasAssetResolver,
} from './canvas_asset.js';

export function registerCanvasAssetRoutes(
  app: FastifyInstance,
  resolver: CanvasAssetResolver,
): void {
  app.get('/v1/canvas-assets/:assetId', async (request, reply) => {
    const assetId = routeText((request.params as {assetId?: string}).assetId);
    if (assetId === null) return reply.code(400).send({error: 'invalid_canvas_asset'});
    try {
      const document = await resolver.resolveReady(assetId);
      if (document === null) {
        return reply.code(404).send({error: 'canvas_asset_not_found'});
      }
      reply.header('cache-control', 'no-store');
      return document;
    } catch (error) {
      return canvasError(reply, error);
    }
  });
}

function canvasError(reply: FastifyReply, error: unknown): FastifyReply {
  if (error instanceof CanvasAssetIntegrityError) {
    return reply.code(503).send({error: 'canvas_asset_unavailable'});
  }
  if (error instanceof TypeError || error instanceof RangeError) {
    return reply.code(400).send({error: 'invalid_canvas_asset'});
  }
  throw error;
}

function routeText(value: string | undefined): string | null {
  if (typeof value !== 'string') return null;
  const normalized = value.trim();
  if (
    normalized.length === 0 ||
    normalized.length > 200 ||
    /[\u0000-\u001F\u007F]/.test(normalized)
  ) {
    return null;
  }
  return normalized;
}

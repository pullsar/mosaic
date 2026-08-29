import {Pool} from 'pg';
import {buildApp} from './app.js';
import {loadConfig} from './config.js';
import {PostgresConsumerRepository} from './consumer_repository.js';
import {MediaDeliveryService} from './media_delivery.js';
import {loadMediaDeliveryStorageConfig} from './media_delivery_config.js';
import {LocalMediaDeliveryObjectReader} from './media_delivery_local_storage.js';
import {registerMediaDeliveryRoutes} from './media_delivery_routes.js';
import {S3MediaDeliveryObjectReader} from './media_delivery_s3_storage.js';
import {PostgresMediaPublicationGate} from './media_publication.js';
import {PostgresRepository} from './repository.js';

const config = loadConfig();
const pool = new Pool({connectionString: config.databaseUrl});
const repository = new PostgresRepository(pool);
const consumerRepository = new PostgresConsumerRepository(pool);
const app = buildApp({
  repository,
  consumerRepository,
  logLevel: config.logLevel,
  allowedWebOrigins: config.allowedWebOrigins,
});

const mediaDeliveryConfig = loadMediaDeliveryStorageConfig();
if (mediaDeliveryConfig.storageMode !== 'disabled') {
  const reader = mediaDeliveryConfig.storageMode === 'local'
    ? new LocalMediaDeliveryObjectReader(mediaDeliveryConfig.objectRoot)
    : new S3MediaDeliveryObjectReader({
        endpoint: mediaDeliveryConfig.s3Endpoint,
        bucket: mediaDeliveryConfig.s3Bucket,
        region: mediaDeliveryConfig.s3Region,
        accessKeyId: mediaDeliveryConfig.s3AccessKeyId,
        secretAccessKey: mediaDeliveryConfig.s3SecretAccessKey,
        ...(mediaDeliveryConfig.s3SessionToken === undefined
          ? {}
          : {sessionToken: mediaDeliveryConfig.s3SessionToken}),
        requestTimeoutMs: mediaDeliveryConfig.storageTimeoutMs,
      });
  registerMediaDeliveryRoutes(
    app,
    new MediaDeliveryService(new PostgresMediaPublicationGate(pool), reader),
  );
}

const shutdown = async (signal: string) => {
  app.log.info({signal}, 'shutting down');
  await app.close();
  await pool.end();
  process.exit(0);
};

process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));

await app.listen({host: config.host, port: config.port});

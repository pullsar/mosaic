import {Pool} from 'pg';
import {buildApp} from './app.js';
import {loadConfig} from './config.js';
import {PostgresRepository} from './repository.js';

const config = loadConfig();
const pool = new Pool({connectionString: config.databaseUrl});
const repository = new PostgresRepository(pool);
const app = buildApp({repository, logLevel: config.logLevel, releaseSha: config.releaseSha});

const shutdown = async (signal: string) => {
  app.log.info({signal}, 'shutting down');
  await app.close();
  await pool.end();
  process.exit(0);
};

process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));

await app.listen({host: config.host, port: config.port});

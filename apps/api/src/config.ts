export interface ApiConfig {
  host: string;
  port: number;
  databaseUrl: string;
  logLevel: string;
  releaseSha: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ApiConfig {
  const databaseUrl = env.DATABASE_URL;
  if (!databaseUrl) throw new Error('DATABASE_URL is required');

  const port = Number(env.PORT ?? 8080);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error('PORT must be a valid TCP port');
  }

  return {
    host: env.HOST ?? '0.0.0.0',
    port,
    databaseUrl,
    logLevel: env.LOG_LEVEL ?? 'info',
    releaseSha: env.MIXLI_RELEASE_SHA ?? 'unknown',
  };
}

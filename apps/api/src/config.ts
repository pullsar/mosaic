export interface ApiConfig {
  host: string;
  port: number;
  databaseUrl: string;
  logLevel: string;
  allowedWebOrigins: string[];
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
    allowedWebOrigins: parseAllowedWebOrigins(env.MOSAIC_WEB_ORIGINS ?? ''),
  };
}

function parseAllowedWebOrigins(value: string): string[] {
  const origins = [...new Set(value.split(',').map((origin) => origin.trim()).filter(Boolean))];
  if (origins.length > 20) throw new Error('MOSAIC_WEB_ORIGINS supports at most 20 origins');
  return origins.map((origin) => {
    let uri: URL;
    try {
      uri = new URL(origin);
    } catch {
      throw new Error(`Invalid MOSAIC_WEB_ORIGINS entry: ${origin}`);
    }
    const localHttp =
      uri.protocol === 'http:' &&
      (uri.hostname === 'localhost' || uri.hostname === '127.0.0.1' || uri.hostname === '::1');
    if (uri.protocol !== 'https:' && !localHttp) {
      throw new Error(`MOSAIC_WEB_ORIGINS must use HTTPS outside localhost: ${origin}`);
    }
    if (uri.username || uri.password || uri.search || uri.hash || uri.pathname !== '/') {
      throw new Error(`MOSAIC_WEB_ORIGINS must contain origins only: ${origin}`);
    }
    return uri.origin;
  });
}

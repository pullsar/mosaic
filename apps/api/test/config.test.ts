import assert from 'node:assert/strict';
import {test} from 'node:test';
import {loadConfig} from '../src/config.js';

const databaseUrl = 'postgres://mosaic:mosaic@localhost:5432/mosaic';

test('web origin config accepts HTTPS and explicit localhost development only', () => {
  const config = loadConfig({
    DATABASE_URL: databaseUrl,
    MOSAIC_WEB_ORIGINS:
      'https://app.example.com, http://localhost:3000, https://app.example.com',
  });

  assert.deepEqual(config.allowedWebOrigins, [
    'https://app.example.com',
    'http://localhost:3000',
  ]);
});

test('web origin config rejects insecure production and non-origin values', () => {
  assert.throws(
    () =>
      loadConfig({
        DATABASE_URL: databaseUrl,
        MOSAIC_WEB_ORIGINS: 'http://app.example.com',
      }),
    /must use HTTPS outside localhost/,
  );
  assert.throws(
    () =>
      loadConfig({
        DATABASE_URL: databaseUrl,
        MOSAIC_WEB_ORIGINS: 'https://app.example.com/path',
      }),
    /must contain origins only/,
  );
});

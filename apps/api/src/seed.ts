import {readFile, readdir} from 'node:fs/promises';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {Pool} from 'pg';
import {loadConfig} from './config.js';

const here = dirname(fileURLToPath(import.meta.url));
const fixturesDir = join(here, '../../../packages/play_schema/fixtures');
const pool = new Pool({connectionString: loadConfig().databaseUrl});

try {
  const files = (await readdir(fixturesDir)).filter((name) => name.endsWith('.json')).sort();
  for (const file of files) {
    const raw = JSON.parse(await readFile(join(fixturesDir, file), 'utf8')) as Record<string, unknown>;
    const id = raw.id;
    const revisionId = raw.revisionId;
    const schemaVersion = raw.schemaVersion;
    if (typeof id !== 'string' || typeof revisionId !== 'string' || !Number.isInteger(schemaVersion)) {
      throw new Error(`Invalid fixture ${file}`);
    }

    await pool.query('insert into plays (id) values ($1) on conflict (id) do nothing', [id]);
    await pool.query(
      `insert into play_revisions (play_id, revision_id, schema_version, document)
       values ($1, $2, $3, $4::jsonb)
       on conflict (play_id, revision_id) do nothing`,
      [id, revisionId, schemaVersion, JSON.stringify(raw)],
    );

    const topics = new Set<string>([
      ...((Array.isArray(raw.topics) ? raw.topics : []).filter((value): value is string => typeof value === 'string')),
      ...((Array.isArray(raw.learningTopics) ? raw.learningTopics : []).filter((value): value is string => typeof value === 'string')),
    ]);
    for (const topic of topics) {
      await pool.query(
        `insert into topics (id, label) values ($1, $2)
         on conflict (id) do nothing`,
        [topic, topic.replaceAll('-', ' ')],
      );
    }
    console.log(`seeded ${id}/${revisionId}`);
  }
} finally {
  await pool.end();
}

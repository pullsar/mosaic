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
  for (const [curatedOrder, file] of files.entries()) {
    const raw = JSON.parse(await readFile(join(fixturesDir, file), 'utf8')) as Record<
      string,
      unknown
    >;
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
       on conflict (play_id, revision_id) do update set
         schema_version = excluded.schema_version,
         document = excluded.document`,
      [id, revisionId, schemaVersion, JSON.stringify(raw)],
    );

    const interestTopics = normalizedTopics(raw.topics);
    const learningTopics = normalizedTopics(raw.learningTopics);
    const topics = new Set<string>([...interestTopics, ...learningTopics]);
    for (const topic of topics) {
      await pool.query(
        `insert into topics (id, label) values ($1, $2)
         on conflict (id) do update set label = excluded.label`,
        [topic, topic.replaceAll('-', ' ')],
      );
    }

    await pool.query(
      'delete from play_revision_topics where play_id = $1 and revision_id = $2',
      [id, revisionId],
    );
    for (const topic of interestTopics) {
      await pool.query(
        `insert into play_revision_topics (play_id, revision_id, topic_id, role)
         values ($1, $2, $3, 'interest')`,
        [id, revisionId, topic],
      );
    }
    for (const topic of learningTopics) {
      await pool.query(
        `insert into play_revision_topics (play_id, revision_id, topic_id, role)
         values ($1, $2, $3, 'learning')`,
        [id, revisionId, topic],
      );
    }

    await pool.query(
      `insert into feed_catalog_entries (
         play_id, revision_id, state, quality_prior, curated_order
       ) values ($1, $2, 'eligible', 0.7, $3)
       on conflict (play_id, revision_id) do update set
         state = excluded.state,
         quality_prior = excluded.quality_prior,
         curated_order = excluded.curated_order,
         updated_at = now()`,
      [id, revisionId, curatedOrder],
    );
    console.log(`seeded ${id}/${revisionId}`);
  }
} finally {
  await pool.end();
}

function normalizedTopics(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return [
    ...new Set(
      value
        .filter((topic): topic is string => typeof topic === 'string')
        .map((topic) => topic.trim().toLowerCase())
        .filter((topic) => topic.length > 0),
    ),
  ].sort();
}

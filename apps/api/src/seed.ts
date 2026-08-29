import {readFile, readdir} from 'node:fs/promises';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {Pool} from 'pg';
import {PostgresCanvasAssetRepository} from './canvas_asset.js';
import {loadConfig} from './config.js';

const here = dirname(fileURLToPath(import.meta.url));
const fixturesDir = join(here, '../../../packages/play_schema/fixtures');
const pool = new Pool({connectionString: loadConfig().databaseUrl});

const seedCanvasAssets = [
  {
    schemaVersion: 1,
    id: 'puzzle_match_01',
    semanticLabel: 'Matchstick equation: six plus four equals four',
    elements: [
      {type: 'label', x: 0.18, y: 0.42, text: '6', scale: 0.22},
      {type: 'line', x1: 0.29, y1: 0.42, x2: 0.38, y2: 0.42, width: 0.016},
      {type: 'line', x1: 0.335, y1: 0.35, x2: 0.335, y2: 0.49, width: 0.016, tone: 'accent'},
      {type: 'label', x: 0.50, y: 0.42, text: '4', scale: 0.22},
      {type: 'line', x1: 0.62, y1: 0.39, x2: 0.71, y2: 0.39, width: 0.012},
      {type: 'line', x1: 0.62, y1: 0.45, x2: 0.71, y2: 0.45, width: 0.012},
      {type: 'label', x: 0.82, y: 0.42, text: '4', scale: 0.22},
    ],
  },
  {
    schemaVersion: 1,
    id: 'puzzle_match_01_solved',
    semanticLabel: 'Solved matchstick equation: eight minus four equals four',
    elements: [
      {type: 'label', x: 0.18, y: 0.42, text: '8', scale: 0.22},
      {type: 'line', x1: 0.29, y1: 0.42, x2: 0.38, y2: 0.42, width: 0.016, tone: 'accent'},
      {type: 'label', x: 0.50, y: 0.42, text: '4', scale: 0.22},
      {type: 'line', x1: 0.62, y1: 0.39, x2: 0.71, y2: 0.39, width: 0.012},
      {type: 'line', x1: 0.62, y1: 0.45, x2: 0.71, y2: 0.45, width: 0.012},
      {type: 'label', x: 0.82, y: 0.42, text: '4', scale: 0.22},
    ],
  },
  {
    schemaVersion: 1,
    id: 'getaway_mood_01',
    semanticLabel: 'Warm walkable city-break mood with evening sun and winding streets',
    elements: [
      {type: 'circle', x: 0.78, y: 0.20, radius: 0.075, fill: true, tone: 'accent'},
      {type: 'rect', x: 0.12, y: 0.34, width: 0.22, height: 0.28, radius: 0.03, fill: true, tone: 'surface'},
      {type: 'rect', x: 0.39, y: 0.28, width: 0.18, height: 0.34, radius: 0.03, fill: true, tone: 'muted'},
      {type: 'rect', x: 0.62, y: 0.39, width: 0.18, height: 0.23, radius: 0.03, fill: true, tone: 'surface'},
      {type: 'line', x1: 0.08, y1: 0.76, x2: 0.34, y2: 0.68, width: 0.018, tone: 'foreground'},
      {type: 'line', x1: 0.34, y1: 0.68, x2: 0.60, y2: 0.78, width: 0.018, tone: 'foreground'},
      {type: 'line', x1: 0.60, y1: 0.78, x2: 0.90, y2: 0.67, width: 0.018, tone: 'foreground'},
    ],
  },
] as const;

try {
  const canvasRepository = new PostgresCanvasAssetRepository(pool);
  for (const asset of seedCanvasAssets) {
    const registered = await canvasRepository.register(asset);
    console.log(`${registered.status === 'inserted' ? 'seeded' : 'verified'} canvas ${asset.id}`);
  }

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

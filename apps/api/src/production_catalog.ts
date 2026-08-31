import type {Pool, PoolClient} from 'pg';
import {PostgresCanvasAssetRepository} from './canvas_asset.js';

export const productionStarterPrefix = 'mixli_starter_';
export const productionStarterCount = 6;

export interface ProductionCatalogStatus {
  eligiblePlays: number;
  canvasAssets: number;
}

interface StarterPlay {
  id: string;
  revisionId: string;
  topics: readonly string[];
  document: Record<string, unknown>;
}

interface ChoiceSpec {
  id: string;
  format: 'choose' | 'guess';
  classification: 'preference' | 'challenge';
  topics: readonly string[];
  assetId: string;
  prompt: string;
  options: readonly {id: string; label: string}[];
  answer?: string;
  reveal: string;
}

const canvasAssets = [
  {
    schemaVersion: 1,
    id: 'mixli_canvas_matchsticks',
    semanticLabel: 'A matchstick equation showing six plus four equals four',
    elements: [
      {type: 'label', x: 0.18, y: 0.42, text: '6', scale: 0.22},
      {type: 'line', x1: 0.29, y1: 0.42, x2: 0.38, y2: 0.42, width: 0.016},
      {
        type: 'line',
        x1: 0.335,
        y1: 0.35,
        x2: 0.335,
        y2: 0.49,
        width: 0.016,
        tone: 'accent',
      },
      {type: 'label', x: 0.5, y: 0.42, text: '4', scale: 0.22},
      {type: 'line', x1: 0.62, y1: 0.39, x2: 0.71, y2: 0.39, width: 0.012},
      {type: 'line', x1: 0.62, y1: 0.45, x2: 0.71, y2: 0.45, width: 0.012},
      {type: 'label', x: 0.82, y: 0.42, text: '4', scale: 0.22},
    ],
  },
  {
    schemaVersion: 1,
    id: 'mixli_canvas_city_night',
    semanticLabel: 'A warm city skyline at night with a winding path',
    elements: [
      {type: 'circle', x: 0.78, y: 0.2, radius: 0.075, fill: true, tone: 'accent'},
      {
        type: 'rect',
        x: 0.12,
        y: 0.34,
        width: 0.22,
        height: 0.28,
        radius: 0.03,
        fill: true,
        tone: 'surface',
      },
      {
        type: 'rect',
        x: 0.39,
        y: 0.28,
        width: 0.18,
        height: 0.34,
        radius: 0.03,
        fill: true,
        tone: 'muted',
      },
      {
        type: 'rect',
        x: 0.62,
        y: 0.39,
        width: 0.18,
        height: 0.23,
        radius: 0.03,
        fill: true,
        tone: 'surface',
      },
      {type: 'line', x1: 0.08, y1: 0.76, x2: 0.34, y2: 0.68, width: 0.018},
      {type: 'line', x1: 0.34, y1: 0.68, x2: 0.6, y2: 0.78, width: 0.018},
      {type: 'line', x1: 0.6, y1: 0.78, x2: 0.9, y2: 0.67, width: 0.018},
    ],
  },
  {
    schemaVersion: 1,
    id: 'mixli_canvas_pattern',
    semanticLabel: 'Alternating circles and squares increasing in size',
    elements: [
      {type: 'circle', x: 0.16, y: 0.5, radius: 0.06, fill: true, tone: 'accent'},
      {
        type: 'rect',
        x: 0.32,
        y: 0.42,
        width: 0.16,
        height: 0.16,
        radius: 0.02,
        fill: true,
        tone: 'surface',
      },
      {type: 'circle', x: 0.62, y: 0.5, radius: 0.12, fill: true, tone: 'accent'},
      {
        type: 'rect',
        x: 0.75,
        y: 0.36,
        width: 0.24,
        height: 0.24,
        radius: 0.02,
        fill: false,
        tone: 'muted',
      },
    ],
  },
  {
    schemaVersion: 1,
    id: 'mixli_canvas_orbit',
    semanticLabel: 'A bright planet with three possible orbital paths',
    elements: [
      {type: 'circle', x: 0.5, y: 0.5, radius: 0.11, fill: true, tone: 'accent'},
      {type: 'circle', x: 0.22, y: 0.28, radius: 0.025, fill: true, tone: 'surface'},
      {type: 'circle', x: 0.78, y: 0.3, radius: 0.025, fill: true, tone: 'surface'},
      {type: 'circle', x: 0.68, y: 0.76, radius: 0.025, fill: true, tone: 'surface'},
      {
        type: 'circle',
        x: 0.5,
        y: 0.5,
        radius: 0.31,
        strokeWidth: 0.008,
        fill: false,
        tone: 'muted',
      },
      {type: 'line', x1: 0.32, y1: 0.2, x2: 0.68, y2: 0.8, width: 0.008},
    ],
  },
  {
    schemaVersion: 1,
    id: 'mixli_canvas_color_energy',
    semanticLabel: 'Three overlapping shapes suggesting an electric color palette',
    elements: [
      {type: 'circle', x: 0.28, y: 0.46, radius: 0.19, fill: true, tone: 'accent'},
      {type: 'circle', x: 0.5, y: 0.38, radius: 0.15, fill: true, tone: 'surface'},
      {type: 'circle', x: 0.68, y: 0.56, radius: 0.21, fill: true, tone: 'muted'},
      {
        type: 'rect',
        x: 0.16,
        y: 0.72,
        width: 0.68,
        height: 0.035,
        radius: 0.018,
        fill: true,
        tone: 'surface',
      },
    ],
  },
  {
    schemaVersion: 1,
    id: 'mixli_canvas_quick_logic',
    semanticLabel: 'The sequence two, six, twelve, twenty, then a mystery value',
    elements: [
      {type: 'label', x: 0.14, y: 0.46, text: '2', scale: 0.13},
      {type: 'label', x: 0.3, y: 0.46, text: '6', scale: 0.13},
      {type: 'label', x: 0.48, y: 0.46, text: '12', scale: 0.13},
      {type: 'label', x: 0.68, y: 0.46, text: '20', scale: 0.13},
      {type: 'circle', x: 0.87, y: 0.46, radius: 0.07, fill: true, tone: 'accent'},
    ],
  },
] as const;

const choiceSpecs: readonly ChoiceSpec[] = [
  {
    id: 'mixli_starter_city_instinct',
    format: 'choose',
    classification: 'preference',
    topics: ['travel', 'city-breaks'],
    assetId: 'mixli_canvas_city_night',
    prompt: 'Four days. Warm nights. Where are you going?',
    options: [
      {id: 'lisbon', label: 'Lisbon'},
      {id: 'marrakech', label: 'Marrakech'},
    ],
    reveal: 'Good instinct.',
  },
  {
    id: 'mixli_starter_finish_pattern',
    format: 'guess',
    classification: 'challenge',
    topics: ['patterns', 'design'],
    assetId: 'mixli_canvas_pattern',
    prompt: 'What completes the rhythm?',
    options: [
      {id: 'circle', label: 'Circle'},
      {id: 'diamond', label: 'Diamond'},
      {id: 'square', label: 'Square'},
    ],
    answer: 'diamond',
    reveal: 'Diamond. The shape alternates as the scale rises.',
  },
  {
    id: 'mixli_starter_find_orbit',
    format: 'guess',
    classification: 'challenge',
    topics: ['space', 'science'],
    assetId: 'mixli_canvas_orbit',
    prompt: 'Which path stays in orbit?',
    options: [
      {id: 'a', label: 'A'},
      {id: 'b', label: 'B'},
      {id: 'c', label: 'C'},
    ],
    answer: 'b',
    reveal: 'B. Sideways speed keeps the fall curving.',
  },
  {
    id: 'mixli_starter_color_energy',
    format: 'choose',
    classification: 'preference',
    topics: ['design', 'culture'],
    assetId: 'mixli_canvas_color_energy',
    prompt: 'Pick tonight’s energy.',
    options: [
      {id: 'electric', label: 'Electric'},
      {id: 'soft', label: 'Soft'},
      {id: 'afterglow', label: 'Afterglow'},
    ],
    reveal: 'That is your color story.',
  },
  {
    id: 'mixli_starter_quick_logic',
    format: 'guess',
    classification: 'challenge',
    topics: ['logic', 'numbers'],
    assetId: 'mixli_canvas_quick_logic',
    prompt: '2 · 6 · 12 · 20 · ?',
    options: [
      {id: '26', label: '26'},
      {id: '28', label: '28'},
      {id: '30', label: '30'},
    ],
    answer: '30',
    reveal: '30. Add 4, 6, 8, then 10.',
  },
];

const moveOneMatch: StarterPlay = {
  id: 'mixli_starter_move_one_match',
  revisionId: 'rev_1',
  topics: ['puzzles', 'logic'],
  document: {
    schemaVersion: 1,
    id: 'mixli_starter_move_one_match',
    revisionId: 'rev_1',
    format: 'solve',
    classification: 'challenge',
    topics: ['puzzles', 'logic'],
    learningTopics: [],
    estimatedDurationSec: 25,
    assets: ['mixli_canvas_matchsticks'],
    sources: [],
    entryState: 'solve',
    states: {
      solve: {
        presentation: {
          layers: [
            {type: 'canvas', role: 'media', assetId: 'mixli_canvas_matchsticks'},
            {type: 'text', role: 'prompt', value: 'Move one match.'},
          ],
        },
        input: {
          type: 'drag',
          dragOrigin: {x: 0.335, y: 0.35},
          dragSize: {width: 0.03, height: 0.14},
          targets: [
            {id: 'solution_a', x: 0.185, y: 0.29, width: 0.05, height: 0.14},
          ],
          handleLabel: 'Move match',
        },
        validation: {type: 'target_region', value: 'solution_a'},
        transition: {correct: 'reveal', incorrect: 'solve'},
      },
      reveal: {
        presentation: {
          layers: [{type: 'text', role: 'reveal_title', value: '8 − 4 = 4'}],
        },
        input: {type: 'tap', label: 'Done'},
        validation: {type: 'none'},
        transition: {default: '$end'},
      },
    },
  },
};

const starterPlays: readonly StarterPlay[] = [
  moveOneMatch,
  ...choiceSpecs.map((spec) => ({
    id: spec.id,
    revisionId: 'rev_1',
    topics: spec.topics,
    document: choiceDocument(spec),
  })),
];

export async function applyProductionCatalog(
  pool: Pool,
): Promise<ProductionCatalogStatus> {
  const canvasRepository = new PostgresCanvasAssetRepository(pool);
  for (const asset of canvasAssets) await canvasRepository.register(asset);

  const client = await pool.connect();
  try {
    await client.query('begin');
    for (const [curatedOrder, play] of starterPlays.entries()) {
      await applyStarterPlay(client, play, curatedOrder + 1);
    }
    await client.query('commit');
  } catch (error) {
    await client.query('rollback');
    throw error;
  } finally {
    client.release();
  }
  return verifyProductionCatalog(pool);
}

export async function verifyProductionCatalog(
  pool: Pool,
): Promise<ProductionCatalogStatus> {
  const eligible = await pool.query<{count: number}>(
    `select count(*)::int as count
       from feed_catalog_entries
      where play_id like $1 and state = 'eligible'`,
    [`${productionStarterPrefix}%`],
  );
  const assets = await pool.query<{count: number}>(
    `select count(*)::int as count
       from canvas_assets
      where id = any($1::text[]) and state = 'ready'`,
    [canvasAssets.map((asset) => asset.id)],
  );
  const eligiblePlays = eligible.rows[0]?.count ?? 0;
  const canvasAssetCount = assets.rows[0]?.count ?? 0;
  if (eligiblePlays !== productionStarterCount) {
    throw new Error(
      `Expected ${productionStarterCount} eligible starter Plays, found ${eligiblePlays}`,
    );
  }
  if (canvasAssetCount !== canvasAssets.length) {
    throw new Error(
      `Expected ${canvasAssets.length} ready starter canvases, found ${canvasAssetCount}`,
    );
  }

  const documents = await pool.query<{play_id: string; assets: unknown}>(
    `select revision.play_id, revision.document -> 'assets' as assets
       from play_revisions revision
       join feed_catalog_entries catalog using (play_id, revision_id)
      where catalog.play_id like $1 and catalog.state = 'eligible'`,
    [`${productionStarterPrefix}%`],
  );
  const knownAssets = new Set<string>(canvasAssets.map((asset) => asset.id));
  for (const row of documents.rows) {
    if (!Array.isArray(row.assets) || row.assets.length !== 1) {
      throw new Error(`Starter Play ${row.play_id} must reference one canvas`);
    }
    const [assetId] = row.assets;
    if (typeof assetId !== 'string' || !knownAssets.has(assetId)) {
      throw new Error(`Starter Play ${row.play_id} references an unknown asset`);
    }
  }
  return {eligiblePlays, canvasAssets: canvasAssetCount};
}

function choiceDocument(spec: ChoiceSpec): Record<string, unknown> {
  const transition =
    spec.answer === undefined
      ? Object.fromEntries(spec.options.map((option) => [option.id, 'reveal']))
      : {correct: 'reveal', incorrect: 'reveal'};
  return {
    schemaVersion: 1,
    id: spec.id,
    revisionId: 'rev_1',
    format: spec.format,
    classification: spec.classification,
    topics: [...spec.topics],
    learningTopics: [],
    estimatedDurationSec: 15,
    assets: [spec.assetId],
    sources: [],
    entryState: 'choice',
    states: {
      choice: {
        presentation: {
          layers: [
            {type: 'canvas', role: 'media', assetId: spec.assetId},
            {type: 'text', role: 'prompt', value: spec.prompt},
          ],
        },
        input: {type: 'single_choice', options: spec.options},
        validation:
          spec.answer === undefined
            ? {type: 'none'}
            : {type: 'equals', value: spec.answer},
        transition,
      },
      reveal: {
        presentation: {
          layers: [{type: 'text', role: 'reveal_title', value: spec.reveal}],
        },
        input: {type: 'tap', label: 'Done'},
        validation: {type: 'none'},
        transition: {default: '$end'},
      },
    },
  };
}

async function applyStarterPlay(
  client: PoolClient,
  play: StarterPlay,
  curatedOrder: number,
): Promise<void> {
  await client.query('insert into plays (id) values ($1) on conflict (id) do nothing', [
    play.id,
  ]);
  const serialized = JSON.stringify(play.document);
  await client.query(
    `insert into play_revisions (play_id, revision_id, schema_version, document)
     values ($1, $2, 1, $3::jsonb)
     on conflict (play_id, revision_id) do nothing`,
    [play.id, play.revisionId, serialized],
  );
  const stored = await client.query<{matches: boolean}>(
    `select document = $3::jsonb as matches
       from play_revisions
      where play_id = $1 and revision_id = $2`,
    [play.id, play.revisionId, serialized],
  );
  if (stored.rows[0]?.matches !== true) {
    throw new Error(`Starter revision conflict: ${play.id}/${play.revisionId}`);
  }

  for (const topic of play.topics) {
    await client.query(
      `insert into topics (id, label) values ($1, $2)
       on conflict (id) do update set label = excluded.label`,
      [topic, topicLabel(topic)],
    );
  }
  await client.query(
    'delete from play_revision_topics where play_id = $1 and revision_id = $2',
    [play.id, play.revisionId],
  );
  for (const topic of play.topics) {
    await client.query(
      `insert into play_revision_topics (play_id, revision_id, topic_id, role)
       values ($1, $2, $3, 'interest')`,
      [play.id, play.revisionId, topic],
    );
  }
  await client.query(
    `insert into feed_catalog_entries (
       play_id, revision_id, state, quality_prior, curated_order
     ) values ($1, $2, 'eligible', 0.85, $3)
     on conflict (play_id, revision_id) do update set
       state = 'eligible',
       quality_prior = 0.85,
       curated_order = excluded.curated_order,
       updated_at = now()`,
    [play.id, play.revisionId, curatedOrder],
  );
}

function topicLabel(topic: string): string {
  return topic
    .split('-')
    .map((part) => `${part.slice(0, 1).toUpperCase()}${part.slice(1)}`)
    .join(' ');
}

import type {Pool, PoolClient} from 'pg';
import {
  normalizeCanvasAssetDocument,
  PostgresCanvasAssetRepository,
} from './canvas_asset.js';
import {canonicalJson} from './media.js';

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

const legacyCanvasAssets = [
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

const releaseCanvasAssets = [
  {
    ...legacyCanvasAssets[0],
    id: 'mixli_canvas_matchsticks_v2',
    palette: {
      background: '#F6E8D5',
      foreground: '#2A1C16',
      accent: '#8A2F1B',
      muted: '#715A4E',
      surface: '#D7B58C',
    },
  },
  {
    ...legacyCanvasAssets[1],
    id: 'mixli_canvas_city_night_v2',
    palette: {
      background: '#101827',
      foreground: '#F7F2E8',
      accent: '#F4B942',
      muted: '#748199',
      surface: '#25334A',
    },
  },
  {
    ...legacyCanvasAssets[2],
    id: 'mixli_canvas_pattern_v2',
    palette: {
      background: '#EFF2EC',
      foreground: '#17261F',
      accent: '#166A55',
      muted: '#6C7C73',
      surface: '#C9D8CF',
    },
  },
  {
    ...legacyCanvasAssets[3],
    id: 'mixli_canvas_orbit_v2',
    palette: {
      background: '#14152E',
      foreground: '#F4F5FF',
      accent: '#44D6E8',
      muted: '#7779A0',
      surface: '#292B58',
    },
  },
  {
    ...legacyCanvasAssets[4],
    id: 'mixli_canvas_color_energy_v2',
    palette: {
      background: '#FFF3E8',
      foreground: '#241923',
      accent: '#B32655',
      muted: '#806A75',
      surface: '#F2C4A5',
    },
  },
  {
    ...legacyCanvasAssets[5],
    id: 'mixli_canvas_quick_logic_v2',
    palette: {
      background: '#F3F1EC',
      foreground: '#20211F',
      accent: '#315C55',
      muted: '#77766F',
      surface: '#D9D5CB',
    },
  },
] as const;

const canvasAssets = [...legacyCanvasAssets, ...releaseCanvasAssets] as const;

const legacyChoiceSpecs: readonly ChoiceSpec[] = [
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

const releaseChoiceSpecs: readonly ChoiceSpec[] = [
  {
    id: 'mixli_starter_city_instinct',
    format: 'choose',
    classification: 'preference',
    topics: ['travel', 'city-breaks'],
    assetId: 'mixli_canvas_city_night_v2',
    prompt: 'Which warm night?',
    options: [
      {id: 'lisbon', label: 'Lisbon'},
      {id: 'marrakech', label: 'Marrakech'},
    ],
    reveal: 'That’s your kind of night.',
  },
  {
    id: 'mixli_starter_finish_pattern',
    format: 'guess',
    classification: 'challenge',
    topics: ['patterns', 'design'],
    assetId: 'mixli_canvas_pattern_v2',
    prompt: 'What comes next?',
    options: [
      {id: 'circle', label: 'Circle'},
      {id: 'diamond', label: 'Diamond'},
      {id: 'square', label: 'Square'},
    ],
    answer: 'diamond',
    reveal: 'Diamond. Shape and scale alternate.',
  },
  {
    id: 'mixli_starter_find_orbit',
    format: 'guess',
    classification: 'challenge',
    topics: ['space', 'science'],
    assetId: 'mixli_canvas_orbit_v2',
    prompt: 'Which path holds?',
    options: [
      {id: 'a', label: 'A'},
      {id: 'b', label: 'B'},
      {id: 'c', label: 'C'},
    ],
    answer: 'b',
    reveal: 'B. Sideways speed bends the fall.',
  },
  {
    id: 'mixli_starter_color_energy',
    format: 'choose',
    classification: 'preference',
    topics: ['design', 'culture'],
    assetId: 'mixli_canvas_color_energy_v2',
    prompt: 'Pick tonight’s energy.',
    options: [
      {id: 'electric', label: 'Electric'},
      {id: 'soft', label: 'Soft'},
      {id: 'afterglow', label: 'Afterglow'},
    ],
    reveal: 'That palette fits your pulse.',
  },
  {
    id: 'mixli_starter_quick_logic',
    format: 'guess',
    classification: 'challenge',
    topics: ['logic', 'numbers'],
    assetId: 'mixli_canvas_quick_logic_v2',
    prompt: 'Complete the sequence.',
    options: [
      {id: '26', label: '26'},
      {id: '28', label: '28'},
      {id: '30', label: '30'},
    ],
    answer: '30',
    reveal: '30. The gaps rise by two.',
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

const legacyStarterPlays: readonly StarterPlay[] = [
  moveOneMatch,
  ...legacyChoiceSpecs.map((spec) => ({
    id: spec.id,
    revisionId: 'rev_1',
    topics: spec.topics,
    document: choiceDocument(spec, 'rev_1'),
  })),
];

const moveOneMatchV2: StarterPlay = {
  id: 'mixli_starter_move_one_match',
  revisionId: 'rev_2',
  topics: ['puzzles', 'logic'],
  document: {
    schemaVersion: 1,
    id: 'mixli_starter_move_one_match',
    revisionId: 'rev_2',
    format: 'solve',
    classification: 'challenge',
    topics: ['puzzles', 'logic'],
    learningTopics: [],
    estimatedDurationSec: 20,
    assets: ['mixli_canvas_matchsticks_v2'],
    sources: [],
    entryState: 'solve',
    states: {
      solve: {
        presentation: {
          layers: [
            {type: 'canvas', role: 'media', assetId: 'mixli_canvas_matchsticks_v2'},
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
          layers: [
            {type: 'canvas', role: 'media', assetId: 'mixli_canvas_matchsticks_v2'},
            {type: 'text', role: 'reveal_title', value: '8 − 4 = 4. One stroke changes sides.'},
          ],
        },
        input: {type: 'tap', label: 'Done'},
        validation: {type: 'none'},
        transition: {default: '$end'},
      },
    },
  },
};

const starterPlays: readonly StarterPlay[] = [
  moveOneMatchV2,
  ...releaseChoiceSpecs.map((spec) => ({
    id: spec.id,
    revisionId: 'rev_2',
    topics: spec.topics,
    document: choiceDocument(spec, 'rev_2'),
  })),
];

const allStarterPlays = [...legacyStarterPlays, ...starterPlays] as const;

export async function applyProductionCatalog(
  pool: Pool,
): Promise<ProductionCatalogStatus> {
  const canvasRepository = new PostgresCanvasAssetRepository(pool);
  for (const asset of canvasAssets) await canvasRepository.register(asset);

  const client = await pool.connect();
  try {
    await client.query('begin');
    for (const [curatedOrder, play] of legacyStarterPlays.entries()) {
      await applyStarterPlay(client, play, curatedOrder + 1, 'suspended');
    }
    await client.query(
      `update feed_catalog_entries
          set state = 'suspended', updated_at = now()
        where play_id like $1`,
      [`${productionStarterPrefix}%`],
    );
    for (const [curatedOrder, play] of starterPlays.entries()) {
      await applyStarterPlay(client, play, curatedOrder + 1, 'eligible');
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
  const catalog = await pool.query<{
    play_id: string;
    revision_id: string;
    state: string;
  }>(
    `select play_id, revision_id, state
       from feed_catalog_entries
      where play_id like $1`,
    [`${productionStarterPrefix}%`],
  );
  const expectedCatalog = new Map(
    allStarterPlays.map((play) => [
      `${play.id}\u0000${play.revisionId}`,
      play.revisionId === 'rev_2' ? 'eligible' : 'suspended',
    ]),
  );
  const actualCatalog = new Set(
    catalog.rows
      .filter((row) => row.state === 'eligible')
      .map((row) => `${row.play_id}\u0000${row.revision_id}`),
  );
  if (
    catalog.rows.length !== expectedCatalog.size ||
    actualCatalog.size !== starterPlays.length ||
    catalog.rows.some(
      (row) =>
        expectedCatalog.get(`${row.play_id}\u0000${row.revision_id}`) !== row.state,
    )
  ) {
    throw new Error('Starter Play catalog does not match the exact release set');
  }
  const eligiblePlays = actualCatalog.size;
  const canvasRepository = new PostgresCanvasAssetRepository(pool);
  let canvasAssetCount = 0;
  for (const authoredAsset of canvasAssets) {
    const expected = normalizeCanvasAssetDocument(authoredAsset);
    const stored = await canvasRepository.get(expected.id);
    if (
      stored?.state !== 'ready' ||
      canonicalJson(stored.document) !== canonicalJson(expected)
    ) {
      throw new Error(`Starter canvas ${expected.id} differs from release content`);
    }
    canvasAssetCount += 1;
  }
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

  const documents = await pool.query<{
    play_id: string;
    revision_id: string;
    document: unknown;
  }>(
    `select revision.play_id, revision.revision_id, revision.document
       from play_revisions revision
       join feed_catalog_entries catalog using (play_id, revision_id)
      where catalog.play_id = any($1::text[])`,
    [allStarterPlays.map((play) => play.id)],
  );
  const expectedDocuments = new Map(
    allStarterPlays.map((play) => [
      `${play.id}\u0000${play.revisionId}`,
      canonicalJson(play.document),
    ]),
  );
  for (const row of documents.rows) {
    const identity = `${row.play_id}\u0000${row.revision_id}`;
    if (canonicalJson(row.document) !== expectedDocuments.get(identity)) {
      throw new Error(`Starter Play ${row.play_id} differs from release content`);
    }
  }
  if (documents.rows.length !== allStarterPlays.length) {
    throw new Error('Starter Play revisions are incomplete');
  }

  const topicLinks = await pool.query<{
    play_id: string;
    revision_id: string;
    topic_id: string;
    role: string;
  }>(
    `select play_id, revision_id, topic_id, role
       from play_revision_topics
      where play_id = any($1::text[])`,
    [allStarterPlays.map((play) => play.id)],
  );
  const expectedTopicLinks = new Set(
    allStarterPlays.flatMap((play) =>
      play.topics.map(
        (topic) => `${play.id}\u0000${play.revisionId}\u0000${topic}\u0000interest`,
      ),
    ),
  );
  const actualTopicLinks = new Set(
    topicLinks.rows.map(
      (link) =>
        `${link.play_id}\u0000${link.revision_id}\u0000${link.topic_id}\u0000${link.role}`,
    ),
  );
  if (
    actualTopicLinks.size !== expectedTopicLinks.size ||
    [...expectedTopicLinks].some((identity) => !actualTopicLinks.has(identity))
  ) {
    throw new Error('Starter Play topic links differ from release content');
  }
  return {eligiblePlays, canvasAssets: canvasAssetCount};
}

function choiceDocument(
  spec: ChoiceSpec,
  revisionId: 'rev_1' | 'rev_2',
): Record<string, unknown> {
  const transition =
    spec.answer === undefined
      ? Object.fromEntries(spec.options.map((option) => [option.id, 'reveal']))
      : {correct: 'reveal', incorrect: 'reveal'};
  return {
    schemaVersion: 1,
    id: spec.id,
    revisionId,
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
          layers: [
            ...(revisionId === 'rev_2'
              ? [{type: 'canvas', role: 'media', assetId: spec.assetId}]
              : []),
            {type: 'text', role: 'reveal_title', value: spec.reveal},
          ],
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
  state: 'eligible' | 'suspended',
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
     ) values ($1, $2, $3, 0.85, $4)
      on conflict (play_id, revision_id) do update set
       state = excluded.state,
       quality_prior = 0.85,
       curated_order = excluded.curated_order,
       updated_at = now()`,
    [play.id, play.revisionId, state, curatedOrder],
  );
}

function topicLabel(topic: string): string {
  return topic
    .split('-')
    .map((part) => `${part.slice(0, 1).toUpperCase()}${part.slice(1)}`)
    .join(' ');
}

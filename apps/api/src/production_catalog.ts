import type {Pool, PoolClient} from 'pg';
import {
  normalizeCanvasAssetDocument,
  PostgresCanvasAssetRepository,
} from './canvas_asset.js';
import {
  assertProductionCatalogIntegrity,
  buildMatchstickCanvasAsset,
  moveSegment,
  type CatalogIntegrityReview,
  type ProductionCatalogIntegrityFixture,
} from './catalog_integrity.js';
import {canonicalJson} from './media.js';
import type {SleightTrajectory, SleightTrajectoryEvent} from './sleight_solver.js';
import type {
  ConstellationRect,
  ConstellationTrajectory,
} from './constellation_solver.js';
import {
  solveSecondThought,
  type SecondThoughtRound,
} from './second_thought_solver.js';
import {
  solveRuleFlip,
  type RuleFlipObject,
} from './rule_flip_solver.js';
import {
  solveEvidenceLens,
  type EvidenceLensClaim,
  type EvidenceLensPoint,
} from './evidence_lens_solver.js';
import {
  solveCounterexample,
  type CounterexampleClaim,
  type CounterexampleTile,
} from './counterexample_solver.js';

export const productionStarterPrefix = 'mixli_starter_';
export const productionStarterCount = 53;

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

interface MatchstickRoundSpec {
  readonly id: string;
  readonly sourceAssetId: string;
  readonly solvedAssetId: string;
  readonly sourceSegments: readonly string[];
  readonly sourceEquation: string;
  readonly movingSegment: string;
  readonly destinations: readonly {readonly id: string; readonly to: string}[];
  readonly answerDestinationId: string;
  readonly solvedEquation: string;
}

interface SecondThoughtRoundSpec {
  readonly id: string;
  readonly topics: readonly [string, string];
  readonly round: SecondThoughtRound;
}
interface RuleFlipRoundSpec {
  readonly id: string;
  readonly topics: readonly [string, string];
  readonly object: RuleFlipObject;
}
interface EvidenceLensRoundSpec {
  readonly id: string;
  readonly topics: readonly [string, string];
  readonly source: string;
  readonly points: readonly EvidenceLensPoint[];
}
interface ChoiceSpec {
  id: string;
  format: 'choose' | 'guess';
  classification: 'preference' | 'challenge';
  topics: readonly string[];
  assetId: string;
  revealAssetId?: string;
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

const matchstickPalette = {
  background: '#F6E8D5',
  foreground: '#2A1C16',
  accent: '#8A2F1B',
  muted: '#715A4E',
  surface: '#D7B58C',
} as const;

const matchstickSourceSegments = new Set([
  'left.a',
  'left.c',
  'left.d',
  'left.e',
  'left.f',
  'left.g',
  'operator.horizontal',
  'operator.vertical',
  'right.b',
  'right.c',
  'right.f',
  'right.g',
  'result.b',
  'result.c',
  'result.f',
  'result.g',
]);

const matchstickSolvedSegments = moveSegment(
  matchstickSourceSegments,
  'operator.vertical',
  'left.b',
);

const matchstickDigitSegments: Readonly<Record<string, readonly string[]>> = {
  '0': ['a', 'b', 'c', 'd', 'e', 'f'],
  '1': ['b', 'c'],
  '2': ['a', 'b', 'd', 'e', 'g'],
  '3': ['a', 'b', 'c', 'd', 'g'],
  '4': ['b', 'c', 'f', 'g'],
  '5': ['a', 'c', 'd', 'f', 'g'],
  '6': ['a', 'c', 'd', 'e', 'f', 'g'],
  '7': ['a', 'b', 'c'],
  '8': ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
  '9': ['a', 'b', 'c', 'd', 'f', 'g'],
};

function matchstickEquationSegments(
  left: keyof typeof matchstickDigitSegments,
  operator: '+' | '-',
  right: keyof typeof matchstickDigitSegments,
  result: keyof typeof matchstickDigitSegments,
): Set<string> {
  const segments = new Set<string>();
  for (const [slot, digit] of [
    ['left', left],
    ['right', right],
    ['result', result],
  ] as const) {
    for (const segment of matchstickDigitSegments[digit]!) {
      segments.add(`${slot}.${segment}`);
    }
  }
  segments.add('operator.horizontal');
  if (operator === '+') segments.add('operator.vertical');
  return segments;
}

interface SleightRoundSpec {
  readonly id: string;
  readonly trajectory: SleightTrajectory;
  readonly durationMs: number;
  readonly answerPositionId: 'left' | 'center' | 'right';
}

interface ConstellationRoundSpec {
  readonly id: string;
  readonly durationMs: number;
  readonly targetObjectIds: readonly string[];
  readonly delta: Readonly<{x: number; y: number}>;
}

interface CounterexampleTileSpec extends CounterexampleTile {
  readonly x: number;
}

interface CounterexampleRoundSpec {
  readonly id: string;
  readonly topics: readonly [string, string];
  readonly claim: CounterexampleClaim;
  readonly tiles: readonly CounterexampleTileSpec[];
}

const additionalMatchstickRoundSpecs: readonly MatchstickRoundSpec[] = [
  {
    id: 'mixli_starter_move_zero_one',
    sourceAssetId: 'mixli_canvas_matchsticks_zero_one_base_v1',
    solvedAssetId: 'mixli_canvas_matchsticks_zero_one_solved_v1',
    sourceSegments: [...matchstickEquationSegments('0', '+', '1', '8')],
    sourceEquation: '0 + 1 = 8',
    movingSegment: 'result.e',
    destinations: [
      {id: 'solution_a', to: 'left.g'},
      {id: 'invalid_left', to: 'right.f'},
      {id: 'invalid_right', to: 'right.a'},
    ],
    answerDestinationId: 'solution_a',
    solvedEquation: '8 + 1 = 9',
  },
  {
    id: 'mixli_starter_move_zero_two',
    sourceAssetId: 'mixli_canvas_matchsticks_zero_two_base_v1',
    solvedAssetId: 'mixli_canvas_matchsticks_zero_two_solved_v1',
    sourceSegments: [...matchstickEquationSegments('0', '-', '6', '3')],
    sourceEquation: '0 - 6 = 3',
    movingSegment: 'right.e',
    destinations: [
      {id: 'solution_a', to: 'left.g'},
      {id: 'invalid_left', to: 'right.b'},
      {id: 'invalid_right', to: 'result.e'},
    ],
    answerDestinationId: 'solution_a',
    solvedEquation: '8 - 5 = 3',
  },
  {
    id: 'mixli_starter_move_one_two',
    sourceAssetId: 'mixli_canvas_matchsticks_one_two_base_v1',
    solvedAssetId: 'mixli_canvas_matchsticks_one_two_solved_v1',
    sourceSegments: [...matchstickEquationSegments('1', '+', '0', '8')],
    sourceEquation: '1 + 0 = 8',
    movingSegment: 'result.e',
    destinations: [
      {id: 'solution_a', to: 'right.g'},
      {id: 'invalid_left', to: 'left.a'},
      {id: 'invalid_right', to: 'left.f'},
    ],
    answerDestinationId: 'solution_a',
    solvedEquation: '1 + 8 = 9',
  },
  {
    id: 'mixli_starter_move_one_three',
    sourceAssetId: 'mixli_canvas_matchsticks_one_three_base_v1',
    solvedAssetId: 'mixli_canvas_matchsticks_one_three_solved_v1',
    sourceSegments: [...matchstickEquationSegments('2', '-', '1', '9')],
    sourceEquation: '2 - 1 = 9',
    movingSegment: 'result.f',
    destinations: [
      {id: 'solution_a', to: 'operator.vertical'},
      {id: 'invalid_left', to: 'right.a'},
      {id: 'invalid_right', to: 'left.c'},
    ],
    answerDestinationId: 'solution_a',
    solvedEquation: '2 + 1 = 3',
  },
  {
    id: 'mixli_starter_move_one_five',
    sourceAssetId: 'mixli_canvas_matchsticks_one_five_base_v1',
    solvedAssetId: 'mixli_canvas_matchsticks_one_five_solved_v1',
    sourceSegments: [...matchstickEquationSegments('3', '+', '0', '8')],
    sourceEquation: '3 + 0 = 8',
    movingSegment: 'result.e',
    destinations: [
      {id: 'solution_a', to: 'left.f'},
      {id: 'invalid_left', to: 'right.g'},
      {id: 'invalid_right', to: 'left.e'},
    ],
    answerDestinationId: 'solution_a',
    solvedEquation: '9 + 0 = 9',
  },
];

function movedMatchstickSegments(spec: MatchstickRoundSpec): ReadonlySet<string> {
  const destination = spec.destinations.find(
    (entry) => entry.id === spec.answerDestinationId,
  );
  if (destination === undefined) {
    throw new Error(`missing_matchstick_answer:${spec.id}`);
  }
  return moveSegment(
    new Set(spec.sourceSegments),
    spec.movingSegment,
    destination.to,
  );
}

const verifiedCanvasAssets = [
  buildMatchstickCanvasAsset(
    'mixli_canvas_matchsticks_base_v4',
    new Set(
      [...matchstickSourceSegments].filter(
        (segment) => segment !== 'operator.vertical',
      ),
    ),
    matchstickPalette,
  ),
  buildMatchstickCanvasAsset(
    'mixli_canvas_matchsticks_v3',
    matchstickSourceSegments,
    matchstickPalette,
  ),
  buildMatchstickCanvasAsset(
    'mixli_canvas_matchsticks_solved_v3',
    matchstickSolvedSegments,
    matchstickPalette,
  ),
  ...additionalMatchstickRoundSpecs.flatMap((spec) => [
    buildMatchstickCanvasAsset(
      spec.sourceAssetId,
      new Set(
        spec.sourceSegments.filter(
          (segment) => segment !== spec.movingSegment,
        ),
      ),
      matchstickPalette,
    ),
    buildMatchstickCanvasAsset(
      spec.solvedAssetId,
      movedMatchstickSegments(spec),
      matchstickPalette,
    ),
  ]),
  {
    schemaVersion: 1,
    id: 'mixli_canvas_city_night_v3',
    semanticLabel:
      'Two warm night choices: Lisbon with hill lights and Marrakech with courtyard lamps',
    elements: [
      {type: 'label', x: 0.25, y: 0.18, text: 'Lisbon', scale: 0.075},
      {type: 'circle', x: 0.24, y: 0.32, radius: 0.07, fill: true, tone: 'accent'},
      {type: 'line', x1: 0.12, y1: 0.58, x2: 0.38, y2: 0.46, width: 0.014},
      {type: 'rect', x: 0.12, y: 0.62, width: 0.1, height: 0.18, fill: true, tone: 'surface'},
      {type: 'rect', x: 0.28, y: 0.54, width: 0.1, height: 0.26, fill: true, tone: 'muted'},
      {type: 'label', x: 0.72, y: 0.18, text: 'Marrakech', scale: 0.07},
      {type: 'circle', x: 0.72, y: 0.32, radius: 0.065, fill: true, tone: 'accent'},
      {type: 'rect', x: 0.6, y: 0.52, width: 0.24, height: 0.26, fill: false, tone: 'surface'},
      {type: 'line', x1: 0.62, y1: 0.62, x2: 0.82, y2: 0.62, width: 0.014},
    ],
    palette: {
      background: '#101827',
      foreground: '#F7F2E8',
      accent: '#F4B942',
      muted: '#748199',
      surface: '#25334A',
    },
  },
  {
    schemaVersion: 1,
    id: 'mixli_canvas_pattern_v3',
    semanticLabel: 'Pattern sequence circle, square, circle, square',
    elements: [
      {type: 'circle', x: 0.16, y: 0.5, radius: 0.065, fill: true, tone: 'accent'},
      {type: 'rect', x: 0.32, y: 0.43, width: 0.14, height: 0.14, radius: 0.02, fill: true, tone: 'surface'},
      {type: 'circle', x: 0.58, y: 0.5, radius: 0.105, fill: true, tone: 'accent'},
      {type: 'rect', x: 0.76, y: 0.39, width: 0.22, height: 0.22, radius: 0.02, fill: false, tone: 'surface'},
    ],
    palette: {
      background: '#EFF2EC',
      foreground: '#17261F',
      accent: '#166A55',
      muted: '#6C7C73',
      surface: '#C9D8CF',
    },
  },
  {
    schemaVersion: 1,
    id: 'mixli_canvas_orbit_v3',
    semanticLabel: 'Route puzzle with paths A, B, and C. Path B connects the marked endpoints',
    elements: [
      {type: 'circle', x: 0.18, y: 0.5, radius: 0.035, fill: true, tone: 'accent'},
      {type: 'circle', x: 0.82, y: 0.5, radius: 0.035, fill: true, tone: 'accent'},
      {type: 'label', x: 0.18, y: 0.4, text: 'Start', scale: 0.055},
      {type: 'label', x: 0.82, y: 0.4, text: 'End', scale: 0.055},
      {type: 'line', x1: 0.22, y1: 0.45, x2: 0.55, y2: 0.25, width: 0.01, tone: 'muted'},
      {type: 'line', x1: 0.55, y1: 0.25, x2: 0.78, y2: 0.38, width: 0.01, tone: 'muted'},
      {type: 'label', x: 0.52, y: 0.2, text: 'A', scale: 0.075},
      {type: 'line', x1: 0.22, y1: 0.5, x2: 0.78, y2: 0.5, width: 0.014, tone: 'surface'},
      {type: 'label', x: 0.5, y: 0.44, text: 'B', scale: 0.075},
      {type: 'line', x1: 0.22, y1: 0.56, x2: 0.48, y2: 0.76, width: 0.01, tone: 'muted'},
      {type: 'line', x1: 0.48, y1: 0.76, x2: 0.68, y2: 0.6, width: 0.01, tone: 'muted'},
      {type: 'label', x: 0.49, y: 0.82, text: 'C', scale: 0.075},
    ],
    palette: {
      background: '#14152E',
      foreground: '#F4F5FF',
      accent: '#44D6E8',
      muted: '#7779A0',
      surface: '#292B58',
    },
  },
  {
    schemaVersion: 1,
    id: 'mixli_canvas_color_energy_v3',
    semanticLabel: 'Three distinct palettes: electric, soft, and afterglow',
    elements: [
      {type: 'circle', x: 0.2, y: 0.45, radius: 0.14, fill: true, tone: 'accent'},
      {type: 'label', x: 0.2, y: 0.67, text: 'Electric', scale: 0.06},
      {type: 'circle', x: 0.5, y: 0.45, radius: 0.14, fill: true, tone: 'surface'},
      {type: 'label', x: 0.5, y: 0.67, text: 'Soft', scale: 0.06},
      {type: 'circle', x: 0.8, y: 0.45, radius: 0.14, fill: true, tone: 'muted'},
      {type: 'label', x: 0.8, y: 0.67, text: 'Afterglow', scale: 0.055},
    ],
    palette: {
      background: '#FFF3E8',
      foreground: '#241923',
      accent: '#B32655',
      muted: '#806A75',
      surface: '#F2C4A5',
    },
  },
  {
    schemaVersion: 1,
    id: 'mixli_canvas_quick_logic_v3',
    semanticLabel: 'The sequence 2, 6, 12, 20 with gaps 4, 6, and 8',
    elements: [
      {type: 'label', x: 0.14, y: 0.46, text: '2', scale: 0.13},
      {type: 'label', x: 0.3, y: 0.46, text: '6', scale: 0.13},
      {type: 'label', x: 0.48, y: 0.46, text: '12', scale: 0.13},
      {type: 'label', x: 0.68, y: 0.46, text: '20', scale: 0.13},
      {type: 'circle', x: 0.87, y: 0.46, radius: 0.07, fill: true, tone: 'accent'},
      {type: 'label', x: 0.22, y: 0.68, text: '+4', scale: 0.055, tone: 'muted'},
      {type: 'label', x: 0.39, y: 0.68, text: '+6', scale: 0.055, tone: 'muted'},
      {type: 'label', x: 0.58, y: 0.68, text: '+8', scale: 0.055, tone: 'muted'},
    ],
    palette: {
      background: '#F3F1EC',
      foreground: '#20211F',
      accent: '#315C55',
      muted: '#77766F',
      surface: '#D9D5CB',
    },
  },
] as const;

const patternV4Prefix = [
  {type: 'circle', x: 0.17, y: 0.5, radius: 0.07, fill: true, tone: 'accent'},
  {type: 'rect', x: 0.32, y: 0.444, width: 0.14, height: 0.112, radius: 0.015, fill: true, tone: 'accent'},
  {type: 'circle', x: 0.61, y: 0.5, radius: 0.07, fill: true, tone: 'accent'},
] as const;
const patternV4Palette = {
  background: '#EFF2EC', foreground: '#17261F', accent: '#166A55',
  muted: '#6C7C73', surface: '#C9D8CF',
} as const;
const quietSwitchPalette = {
  background: '#18282E', foreground: '#F6EBDD', accent: '#D7A15D',
  muted: '#86A7A6', surface: '#365159',
} as const;
const quietSwitchRoom = [
  {type: 'rect', x: 0.12, y: 0.24, width: 0.76, height: 0.09, radius: 0.018, fill: true, tone: 'surface'},
  {type: 'rect', x: 0.22, y: 0.47, width: 0.2, height: 0.07, radius: 0.012, fill: true, tone: 'foreground'},
  {type: 'circle', x: 0.36, y: 0.2, radius: 0.052, fill: true, tone: 'accent'},
  {type: 'line', x1: 0.72, y1: 0.62, x2: 0.72, y2: 0.38, width: 0.018, tone: 'muted'},
  {type: 'circle', x: 0.72, y: 0.32, radius: 0.075, fill: true, tone: 'foreground'},
] as const;
type QuietSwitchSpec = {
  readonly id: string;
  readonly topics: readonly string[];
  readonly assetStem: string;
  readonly semanticLabel: string;
  readonly elements: readonly Record<string, unknown>[];
  readonly palette: Record<string, string>;
  readonly changedElementIndex: number;
  readonly changedX: number;
  readonly answer: string;
  readonly answerLabel: string;
  readonly distractors: readonly {readonly id: string; readonly label: string}[];
  readonly reveal: string;
};

const additionalQuietSwitchSpecs: readonly QuietSwitchSpec[] = [
  {
    id: 'mixli_starter_gallery_shift',
    topics: ['art', 'observation'],
    assetStem: 'gallery_shift',
    semanticLabel: 'A gallery wall with three frames, a bench, and a red dot.',
    elements: [
      {type: 'rect', x: 0.1, y: 0.16, width: 0.8, height: 0.62, radius: 0.025, fill: true, tone: 'surface'},
      {type: 'rect', x: 0.18, y: 0.27, width: 0.16, height: 0.2, radius: 0.012, fill: false, tone: 'foreground'},
      {type: 'rect', x: 0.42, y: 0.23, width: 0.16, height: 0.24, radius: 0.012, fill: false, tone: 'foreground'},
      {type: 'rect', x: 0.67, y: 0.28, width: 0.14, height: 0.19, radius: 0.012, fill: false, tone: 'foreground'},
      {type: 'circle', x: 0.28, y: 0.62, radius: 0.035, fill: true, tone: 'accent'},
      {type: 'rect', x: 0.33, y: 0.66, width: 0.34, height: 0.07, radius: 0.02, fill: true, tone: 'muted'},
    ],
    palette: {background: '#14151B', foreground: '#F4F0E9', accent: '#E35D58', muted: '#6B7180', surface: '#2B2F3B'},
    changedElementIndex: 4,
    changedX: 0.72,
    answer: 'dot',
    answerLabel: 'The red dot moved',
    distractors: [{id: 'frame', label: 'A frame changed'}, {id: 'bench', label: 'The bench changed'}],
    reveal: 'The red dot moved below the right frame.',
  },
  {
    id: 'mixli_starter_garden_glance',
    topics: ['nature', 'observation'],
    assetStem: 'garden_glance',
    semanticLabel: 'A night garden with planters, flowers, and one firefly.',
    elements: [
      {type: 'rect', x: 0.1, y: 0.61, width: 0.3, height: 0.16, radius: 0.03, fill: true, tone: 'surface'},
      {type: 'rect', x: 0.6, y: 0.61, width: 0.3, height: 0.16, radius: 0.03, fill: true, tone: 'surface'},
      {type: 'circle', x: 0.21, y: 0.54, radius: 0.05, fill: true, tone: 'muted'},
      {type: 'circle', x: 0.31, y: 0.5, radius: 0.04, fill: true, tone: 'muted'},
      {type: 'circle', x: 0.69, y: 0.52, radius: 0.05, fill: true, tone: 'muted'},
      {type: 'circle', x: 0.27, y: 0.3, radius: 0.022, fill: true, tone: 'accent'},
    ],
    palette: {background: '#111F28', foreground: '#F1F5E9', accent: '#F6D365', muted: '#77A38C', surface: '#29483F'},
    changedElementIndex: 5,
    changedX: 0.76,
    answer: 'firefly',
    answerLabel: 'The firefly moved',
    distractors: [{id: 'flower', label: 'A flower changed'}, {id: 'planter', label: 'A planter changed'}],
    reveal: 'The firefly crossed to the right planter.',
  },
  {
    id: 'mixli_starter_studio_shuffle',
    topics: ['design', 'observation'],
    assetStem: 'studio_shuffle',
    semanticLabel: 'A design studio with a desk, paper, lamp, and paint pot.',
    elements: [
      {type: 'rect', x: 0.12, y: 0.62, width: 0.76, height: 0.12, radius: 0.025, fill: true, tone: 'surface'},
      {type: 'rect', x: 0.3, y: 0.38, width: 0.26, height: 0.17, radius: 0.015, fill: true, tone: 'foreground'},
      {type: 'line', x1: 0.72, y1: 0.59, x2: 0.72, y2: 0.28, width: 0.018, tone: 'muted'},
      {type: 'circle', x: 0.72, y: 0.24, radius: 0.07, fill: true, tone: 'muted'},
      {type: 'circle', x: 0.2, y: 0.53, radius: 0.045, fill: true, tone: 'accent'},
    ],
    palette: {background: '#2D2038', foreground: '#FFF2DE', accent: '#FC8A70', muted: '#B39AC7', surface: '#5A4067'},
    changedElementIndex: 4,
    changedX: 0.62,
    answer: 'paint',
    answerLabel: 'The paint pot moved',
    distractors: [{id: 'paper', label: 'The paper changed'}, {id: 'lamp', label: 'The lamp changed'}],
    reveal: 'The paint pot moved beside the paper.',
  },
  {
    id: 'mixli_starter_bakery_blink',
    topics: ['food', 'observation'],
    assetStem: 'bakery_blink',
    semanticLabel: 'A bakery counter with pastries, a cake, and one cherry.',
    elements: [
      {type: 'rect', x: 0.1, y: 0.61, width: 0.8, height: 0.16, radius: 0.025, fill: true, tone: 'surface'},
      {type: 'circle', x: 0.26, y: 0.53, radius: 0.08, fill: true, tone: 'muted'},
      {type: 'circle', x: 0.48, y: 0.51, radius: 0.1, fill: true, tone: 'foreground'},
      {type: 'circle', x: 0.72, y: 0.53, radius: 0.08, fill: true, tone: 'muted'},
      {type: 'circle', x: 0.48, y: 0.39, radius: 0.022, fill: true, tone: 'accent'},
    ],
    palette: {background: '#FFF0DE', foreground: '#513628', accent: '#D54C55', muted: '#D59B72', surface: '#EBC6A3'},
    changedElementIndex: 4,
    changedX: 0.72,
    answer: 'cherry',
    answerLabel: 'The cherry moved',
    distractors: [{id: 'cake', label: 'The cake changed'}, {id: 'pastry', label: 'A pastry changed'}],
    reveal: 'The cherry moved to the right pastry.',
  },
  {
    id: 'mixli_starter_platform_glance',
    topics: ['travel', 'observation'],
    assetStem: 'platform_glance',
    semanticLabel: 'A train platform with a bench, sign, suitcase, and clock.',
    elements: [
      {type: 'rect', x: 0.1, y: 0.68, width: 0.8, height: 0.08, radius: 0.02, fill: true, tone: 'surface'},
      {type: 'rect', x: 0.24, y: 0.54, width: 0.25, height: 0.07, radius: 0.02, fill: true, tone: 'foreground'},
      {type: 'rect', x: 0.73, y: 0.26, width: 0.08, height: 0.18, radius: 0.01, fill: true, tone: 'muted'},
      {type: 'circle', x: 0.22, y: 0.59, radius: 0.045, fill: true, tone: 'accent'},
      {type: 'circle', x: 0.52, y: 0.28, radius: 0.065, fill: false, tone: 'foreground'},
    ],
    palette: {background: '#17212D', foreground: '#F4F1E8', accent: '#E5B35A', muted: '#71869A', surface: '#34485B'},
    changedElementIndex: 3,
    changedX: 0.68,
    answer: 'suitcase',
    answerLabel: 'The suitcase moved',
    distractors: [{id: 'bench', label: 'The bench changed'}, {id: 'clock', label: 'The clock changed'}],
    reveal: 'The suitcase moved beside the sign.',
  },
];
const routeV3Asset = verifiedCanvasAssets.find((asset) => asset.id === 'mixli_canvas_orbit_v3')!;
const clarifiedCanvasAssets = [
  {
    schemaVersion: 1, id: 'mixli_canvas_pattern_v4',
    semanticLabel: 'Circle, square, circle, then a missing shape.',
    elements: [...patternV4Prefix,
      {type: 'label', x: 0.83, y: 0.5, text: '?', scale: 0.12}],
    palette: patternV4Palette,
  },
  {
    schemaVersion: 1, id: 'mixli_canvas_pattern_solved_v4',
    semanticLabel: 'Circle, square, circle, square.',
    elements: [...patternV4Prefix,
      {type: 'rect', x: 0.76, y: 0.444, width: 0.14, height: 0.112, radius: 0.015, fill: true, tone: 'accent'}],
    palette: patternV4Palette,
  },
  {
    ...routeV3Asset,
    id: 'mixli_canvas_orbit_v4',
    semanticLabel: 'Three route candidates: A rises, B stays level, C falls. Start and End are marked.',
    elements: routeV3Asset.elements.map((element) => {
      if (element.type === 'line') {
        return {...element, tone: 'foreground', width: 0.012,
          ...(element.y1 === 0.5 && element.y2 === 0.5 ? {x1: 0.18, x2: 0.82} : {})};
      }
      if (element.type === 'label' && (element.text === 'Start' || element.text === 'End')) {
        return {...element, x: element.text === 'Start' ? 0.08 : 0.92, y: 0.5, scale: 0.045};
      }
      return element;
    }),
  },
] as const;

const quietSwitchCanvasAssets = [
  {
    schemaVersion: 1,
    id: 'mixli_canvas_quiet_switch_before_v1',
    semanticLabel: 'A reading room with a shelf, book, lamp, and vase.',
    elements: quietSwitchRoom,
    palette: quietSwitchPalette,
  },
  {
    schemaVersion: 1,
    id: 'mixli_canvas_quiet_switch_after_v1',
    semanticLabel: 'A reading room with a shelf, book, lamp, and vase.',
    elements: quietSwitchRoom.map((element, index) =>
      index === 2 ? {...element, x: 0.58} : element,
    ),
    palette: quietSwitchPalette,
  },
  ...additionalQuietSwitchSpecs.flatMap((spec) => [
    {
      schemaVersion: 1,
      id: `mixli_canvas_${spec.assetStem}_before_v1`,
      semanticLabel: spec.semanticLabel,
      elements: spec.elements,
      palette: spec.palette,
    },
    {
      schemaVersion: 1,
      id: `mixli_canvas_${spec.assetStem}_after_v1`,
      semanticLabel: spec.semanticLabel,
      elements: spec.elements.map((element, index) =>
        index === spec.changedElementIndex ? {...element, x: spec.changedX} : element,
      ),
      palette: spec.palette,
    },
  ]),
] as const;

const counterexamplePalette = {
  background: '#161A26',
  foreground: '#F9F4EA',
  accent: '#F15B68',
  muted: '#6FA8E6',
  surface: '#F2C84B',
} as const;

const counterexampleRoundSpecs: readonly CounterexampleRoundSpec[] = [
  {
    id: 'mixli_starter_counterexample_one',
    topics: ['reasoning', 'observation'],
    claim: {color: 'red', shape: 'round'},
    tiles: [
      {id: 'a', color: 'red', shape: 'round', x: .22},
      {id: 'b', color: 'red', shape: 'square', x: .5},
      {id: 'c', color: 'blue', shape: 'square', x: .78},
    ],
  },
  {
    id: 'mixli_starter_counterexample_two',
    topics: ['logic', 'observation'],
    claim: {color: 'blue', shape: 'square'},
    tiles: [
      {id: 'a', color: 'blue', shape: 'square', x: .22},
      {id: 'b', color: 'blue', shape: 'round', x: .5},
      {id: 'c', color: 'gold', shape: 'square', x: .78},
    ],
  },
  {
    id: 'mixli_starter_counterexample_three',
    topics: ['attention', 'reasoning'],
    claim: {color: 'gold', shape: 'round'},
    tiles: [
      {id: 'a', color: 'gold', shape: 'round', x: .22},
      {id: 'b', color: 'red', shape: 'square', x: .5},
      {id: 'c', color: 'gold', shape: 'square', x: .78},
    ],
  },
  {
    id: 'mixli_starter_counterexample_four',
    topics: ['patterns', 'reasoning'],
    claim: {color: 'red', shape: 'square'},
    tiles: [
      {id: 'a', color: 'red', shape: 'square', x: .22},
      {id: 'b', color: 'red', shape: 'round', x: .5},
      {id: 'c', color: 'blue', shape: 'round', x: .78},
    ],
  },
  {
    id: 'mixli_starter_counterexample_five',
    topics: ['focus', 'reasoning'],
    claim: {color: 'blue', shape: 'round'},
    tiles: [
      {id: 'a', color: 'blue', shape: 'round', x: .22},
      {id: 'b', color: 'gold', shape: 'square', x: .5},
      {id: 'c', color: 'red', shape: 'round', x: .78},
    ],
  },
  {
    id: 'mixli_starter_counterexample_six',
    topics: ['puzzles', 'reasoning'],
    claim: {color: 'gold', shape: 'square'},
    tiles: [
      {id: 'a', color: 'gold', shape: 'square', x: .22},
      {id: 'b', color: 'gold', shape: 'round', x: .5},
      {id: 'c', color: 'blue', shape: 'square', x: .78},
    ],
  },
];

function counterexampleTone(tile: CounterexampleTile): 'accent' | 'muted' | 'surface' {
  return tile.color === 'red' ? 'accent' : tile.color === 'blue' ? 'muted' : 'surface';
}

function counterexampleAsset(
  spec: CounterexampleRoundSpec,
  solved: boolean,
): Record<string, unknown> {
  const solution = solveCounterexample(spec.claim, spec.tiles);
  const answerText = solution.answerId === 'insufficient'
    ? 'No tile breaks it.'
    : `Tile ${solution.answerId.toUpperCase()} breaks it.`;
  return {
    schemaVersion: 1,
    id: `${spec.id}_${solved ? 'solved' : 'source'}_canvas`,
    semanticLabel: 'Three colored shape tiles labelled A, B, and C.',
    elements: [
      ...spec.tiles.flatMap((tile) => [
        {
          type: 'rect', x: tile.x - .12, y: .28, width: .24, height: .32,
          radius: .045, fill: false, tone: 'foreground',
        },
        tile.shape === 'round'
          ? {type: 'circle', x: tile.x, y: .42, radius: .075, fill: true, tone: counterexampleTone(tile)}
          : {type: 'rect', x: tile.x - .07, y: .35, width: .14, height: .14, radius: .028, fill: true, tone: counterexampleTone(tile)},
        {type: 'label', x: tile.x, y: .55, text: tile.id.toUpperCase(), scale: .055, tone: 'foreground'},
      ]),
      ...(solved ? [
        {type: 'label', x: .5, y: .76, text: answerText, scale: .055, tone: 'foreground'},
      ] : []),
    ],
    palette: counterexamplePalette,
  };
}

const counterexampleCanvasAssets = counterexampleRoundSpecs.flatMap((spec) => [
  counterexampleAsset(spec, false),
  counterexampleAsset(spec, true),
]);

const secondThoughtPalette = {
  background: '#16252A', foreground: '#F9F4EA', accent: '#F09A5A', muted: '#8AC5C1', surface: '#E8C35F',
} as const;

const secondThoughtRoundSpecs: readonly SecondThoughtRoundSpec[] = [
  {id: 'mixli_starter_second_thought_one', topics: ['reasoning', 'reflection'], round: {initial: 'north', advice: 'south', evidence: 'north'}},
  {id: 'mixli_starter_second_thought_two', topics: ['attention', 'reflection'], round: {initial: 'south', advice: 'north', evidence: 'north'}},
  {id: 'mixli_starter_second_thought_three', topics: ['logic', 'reflection'], round: {initial: 'north', advice: 'north', evidence: 'south'}},
  {id: 'mixli_starter_second_thought_four', topics: ['focus', 'reflection'], round: {initial: 'south', advice: 'south', evidence: 'south'}},
  {id: 'mixli_starter_second_thought_five', topics: ['observation', 'reflection'], round: {initial: 'north', advice: 'unsure', evidence: 'south'}},
  {id: 'mixli_starter_second_thought_six', topics: ['patterns', 'reflection'], round: {initial: 'south', advice: 'unsure', evidence: 'south'}},
];

function secondThoughtAsset(spec: SecondThoughtRoundSpec): Record<string, unknown> {
  const evidenceY = spec.round.evidence === 'north' ? .28 : .56;
  return {schemaVersion: 1, id: `${spec.id}_canvas`, semanticLabel: `A compass with a blue flag pointing ${spec.round.evidence}.`, palette: secondThoughtPalette, elements: [
    {type: 'circle', x: .5, y: .43, radius: .23, fill: false, tone: 'foreground'},
    {type: 'label', x: .5, y: .19, text: 'NORTH', scale: .05, tone: 'foreground'},
    {type: 'label', x: .5, y: .68, text: 'SOUTH', scale: .05, tone: 'foreground'},
    {type: 'line', x1: .5, y1: .43, x2: .5, y2: evidenceY, width: .024, tone: 'accent'},
    {type: 'rect', x: .5, y: evidenceY - .02, width: .12, height: .07, radius: .012, fill: true, tone: 'muted'},
  ]};
}

const secondThoughtCanvasAssets = secondThoughtRoundSpecs.map(secondThoughtAsset);
const ruleFlipPalette = {
  background: '#1E1728', foreground: '#FBF4E9', accent: '#C983E6', muted: '#8CB8E8', surface: '#E7BD63',
} as const;

const ruleFlipRoundSpecs: readonly RuleFlipRoundSpec[] = [
  {id: 'mixli_starter_rule_flip_one', topics: ['reasoning', 'focus'], object: {shape: 'triangle', fill: 'striped'}},
  {id: 'mixli_starter_rule_flip_two', topics: ['attention', 'reasoning'], object: {shape: 'round', fill: 'solid'}},
  {id: 'mixli_starter_rule_flip_three', topics: ['patterns', 'reasoning'], object: {shape: 'triangle', fill: 'solid'}},
  {id: 'mixli_starter_rule_flip_four', topics: ['logic', 'focus'], object: {shape: 'round', fill: 'striped'}},
  {id: 'mixli_starter_rule_flip_five', topics: ['observation', 'reasoning'], object: {shape: 'triangle', fill: 'striped'}},
  {id: 'mixli_starter_rule_flip_six', topics: ['focus', 'patterns'], object: {shape: 'round', fill: 'solid'}},
];

function ruleFlipAsset(spec: RuleFlipRoundSpec): Record<string, unknown> {
  const object = spec.object;
  const objectElements = object.shape === 'round'
    ? [{type: 'circle', x: .5, y: .43, radius: .14, fill: object.fill === 'solid', tone: 'accent'}]
    : [
      {type: 'line', x1: .5, y1: .25, x2: .34, y2: .56, width: .022, tone: 'accent'},
      {type: 'line', x1: .34, y1: .56, x2: .66, y2: .56, width: .022, tone: 'accent'},
      {type: 'line', x1: .66, y1: .56, x2: .5, y2: .25, width: .022, tone: 'accent'},
    ];
  const stripeElements = object.fill === 'striped' ? [
    {type: 'line', x1: .4, y1: .36, x2: .6, y2: .36, width: .018, tone: 'surface'},
    {type: 'line', x1: .38, y1: .43, x2: .62, y2: .43, width: .018, tone: 'surface'},
    {type: 'line', x1: .4, y1: .5, x2: .6, y2: .5, width: .018, tone: 'surface'},
  ] : [];
  return {schemaVersion: 1, id: `${spec.id}_canvas`, semanticLabel: `A ${object.fill} ${object.shape}.`, palette: ruleFlipPalette, elements: [
    ...objectElements, ...stripeElements,
    {type: 'label', x: .27, y: .76, text: 'LEFT', scale: .05, tone: 'foreground'},
    {type: 'label', x: .73, y: .76, text: 'RIGHT', scale: .05, tone: 'foreground'},
  ]};
}

const ruleFlipCanvasAssets = ruleFlipRoundSpecs.map(ruleFlipAsset);
const evidenceLensPalette = {
  background: '#132330', foreground: '#F8F4E8', accent: '#F2B84B', muted: '#86C7D6', surface: '#D67563',
} as const;

const evidenceLensRoundSpecs: readonly EvidenceLensRoundSpec[] = [
  {id: 'mixli_starter_evidence_lens_one', topics: ['reasoning', 'data'], source: 'Museum visits', points: [{id: 'a', label: '2023', value: 10}, {id: 'b', label: '2024', value: 15}, {id: 'c', label: '2025', value: 12}]},
  {id: 'mixli_starter_evidence_lens_two', topics: ['observation', 'data'], source: 'Garden blooms', points: [{id: 'a', label: 'Spring', value: 8}, {id: 'b', label: 'Summer', value: 14}, {id: 'c', label: 'Autumn', value: 11}]},
  {id: 'mixli_starter_evidence_lens_three', topics: ['attention', 'data'], source: 'Night trains', points: [{id: 'a', label: 'Mon', value: 17}, {id: 'b', label: 'Tue', value: 13}, {id: 'c', label: 'Wed', value: 16}]},
  {id: 'mixli_starter_evidence_lens_four', topics: ['patterns', 'data'], source: 'Tide markers', points: [{id: 'a', label: 'Dawn', value: 9}, {id: 'b', label: 'Noon', value: 12}, {id: 'c', label: 'Dusk', value: 18}]},
  {id: 'mixli_starter_evidence_lens_five', topics: ['focus', 'data'], source: 'Studio light', points: [{id: 'a', label: 'East', value: 14}, {id: 'b', label: 'South', value: 18}, {id: 'c', label: 'West', value: 10}]},
  {id: 'mixli_starter_evidence_lens_six', topics: ['logic', 'data'], source: 'Harbor signals', points: [{id: 'a', label: 'One', value: 11}, {id: 'b', label: 'Two', value: 7}, {id: 'c', label: 'Three', value: 15}]},
];

function evidenceLensClaims(points: readonly EvidenceLensPoint[]): readonly EvidenceLensClaim[] {
  const final = points.at(-1)!;
  const peak = points.reduce((best, point) => point.value > best.value ? point : best);
  const lowest = points.reduce((best, point) => point.value < best.value ? point : best);
  return [
    {id: 'final', kind: 'final', label: `Final value: ${final.value}.`},
    {id: 'peak', kind: 'peak', label: `Peak value: ${peak.value}.`},
    {id: 'lowest', kind: 'lowest', label: `Lowest value: ${lowest.value}.`},
  ];
}

function evidenceLensAsset(spec: EvidenceLensRoundSpec): Record<string, unknown> {
  const minimum = Math.min(...spec.points.map((point) => point.value));
  const maximum = Math.max(...spec.points.map((point) => point.value));
  const yFor = (value: number) => .65 - ((value - minimum) / (maximum - minimum || 1)) * .34;
  const xFor = (index: number) => .2 + index * .3;
  return {schemaVersion: 1, id: `${spec.id}_canvas`, semanticLabel: `${spec.source}: ${spec.points.map((point) => `${point.label} ${point.value}`).join(', ')}.`, palette: evidenceLensPalette, elements: [
    {type: 'line', x1: .14, y1: .72, x2: .88, y2: .72, width: .012, tone: 'foreground'},
    {type: 'line', x1: .14, y1: .18, x2: .14, y2: .72, width: .012, tone: 'foreground'},
    ...spec.points.slice(0, -1).map((point, index) => ({type: 'line', x1: xFor(index), y1: yFor(point.value), x2: xFor(index + 1), y2: yFor(spec.points[index + 1]!.value), width: .018, tone: 'muted'})),
    ...spec.points.flatMap((point, index) => [{type: 'circle', x: xFor(index), y: yFor(point.value), radius: .042, fill: true, tone: 'accent'}, {type: 'label', x: xFor(index), y: .8, text: point.id.toUpperCase(), scale: .05, tone: 'foreground'}, {type: 'label', x: xFor(index), y: yFor(point.value) - .08, text: String(point.value), scale: .045, tone: 'foreground'}]),
    {type: 'label', x: .5, y: .09, text: spec.source, scale: .052, tone: 'foreground'},
  ]};
}

const evidenceLensCanvasAssets = evidenceLensRoundSpecs.map(evidenceLensAsset);
const canvasAssets = [
  ...legacyCanvasAssets,
  ...releaseCanvasAssets,
  ...verifiedCanvasAssets,
  ...clarifiedCanvasAssets,
  ...quietSwitchCanvasAssets,
  ...counterexampleCanvasAssets,
  ...evidenceLensCanvasAssets,
  ...ruleFlipCanvasAssets,
  ...secondThoughtCanvasAssets,
] as const;

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
          handleStyle: 'matchstick',
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

const releaseV2StarterPlays: readonly StarterPlay[] = [
  moveOneMatchV2,
  ...releaseChoiceSpecs.map((spec) => ({
    id: spec.id,
    revisionId: 'rev_2',
    topics: spec.topics,
    document: choiceDocument(spec, 'rev_2'),
  })),
];

const releaseV3ChoiceSpecs: readonly ChoiceSpec[] = [
  {
    id: 'mixli_starter_city_instinct',
    format: 'choose',
    classification: 'preference',
    topics: ['travel', 'city-breaks'],
    assetId: 'mixli_canvas_city_night_v3',
    prompt: 'Four days. Warm nights.',
    options: [
      {id: 'lisbon', label: 'Lisbon'},
      {id: 'marrakech', label: 'Marrakech'},
    ],
    reveal: 'Lisbon brings late hills. Marrakech brings warm courtyards.',
  },
  {
    id: 'mixli_starter_finish_pattern',
    format: 'guess',
    classification: 'challenge',
    topics: ['patterns', 'design'],
    assetId: 'mixli_canvas_pattern_v3',
    prompt: 'Repeat the pattern.',
    options: [
      {id: 'circle', label: 'Circle'},
      {id: 'triangle', label: 'Triangle'},
      {id: 'square', label: 'Square'},
    ],
    answer: 'square',
    reveal: 'Square. The rhythm repeats circle, square.',
  },
  {
    id: 'mixli_starter_find_orbit',
    format: 'guess',
    classification: 'challenge',
    topics: ['space', 'science'],
    assetId: 'mixli_canvas_orbit_v3',
    prompt: 'Which path connects?',
    options: [
      {id: 'a', label: 'A'},
      {id: 'b', label: 'B'},
      {id: 'c', label: 'C'},
    ],
    answer: 'b',
    reveal: 'B. It joins the marked endpoints.',
  },
  {
    id: 'mixli_starter_color_energy',
    format: 'choose',
    classification: 'preference',
    topics: ['design', 'culture'],
    assetId: 'mixli_canvas_color_energy_v3',
    prompt: 'Pick tonight’s energy.',
    options: [
      {id: 'electric', label: 'Electric'},
      {id: 'soft', label: 'Soft'},
      {id: 'afterglow', label: 'Afterglow'},
    ],
    reveal: 'Electric is sharp. Soft is quiet. Afterglow is warm.',
  },
  {
    id: 'mixli_starter_quick_logic',
    format: 'guess',
    classification: 'challenge',
    topics: ['logic', 'numbers'],
    assetId: 'mixli_canvas_quick_logic_v3',
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

function matchstickSceneLocation(segment: string): Record<string, number> {
  const [slot, part] = segment.split('.');
  if (slot === 'operator') {
    if (part === 'horizontal') {
      return {x: 0.29, y: 0.485, width: 0.1, height: 0.03};
    }
    if (part === 'vertical') {
      return {x: 0.325, y: 0.43, width: 0.03, height: 0.14};
    }
    throw new Error(`unknown_matchstick_segment:${segment}`);
  }
  const center = ({left: 0.16, right: 0.5, result: 0.82} as const)[slot ?? ''];
  if (center === undefined) throw new Error(`unknown_matchstick_slot:${segment}`);
  if (part === 'a') return {x: center - 0.07, y: 0.345, width: 0.14, height: 0.03};
  if (part === 'b') return {x: center + 0.04, y: 0.36, width: 0.03, height: 0.14};
  if (part === 'c') return {x: center + 0.04, y: 0.5, width: 0.03, height: 0.14};
  if (part === 'd') return {x: center - 0.07, y: 0.625, width: 0.14, height: 0.03};
  if (part === 'e') return {x: center - 0.07, y: 0.5, width: 0.03, height: 0.14};
  if (part === 'f') return {x: center - 0.07, y: 0.36, width: 0.03, height: 0.14};
  if (part === 'g') return {x: center - 0.07, y: 0.485, width: 0.14, height: 0.03};
  throw new Error(`unknown_matchstick_segment:${segment}`);
}

function additionalMatchstickRound(spec: MatchstickRoundSpec): StarterPlay {
  const pieceId = `match_${spec.movingSegment.replace('.', '_')}`;
  const source = matchstickSceneLocation(spec.movingSegment);
  return {
    id: spec.id,
    revisionId: 'rev_1',
    topics: ['puzzles', 'logic'],
    document: {
      schemaVersion: 1,
      id: spec.id,
      revisionId: 'rev_1',
      format: 'solve',
      classification: 'challenge',
      topics: ['puzzles', 'logic'],
      learningTopics: [],
      estimatedDurationSec: 20,
      assets: [spec.sourceAssetId, spec.solvedAssetId],
      sources: [],
      entryState: 'solve',
      states: {
        solve: {
          presentation: {
            layers: [
              {type: 'canvas', role: 'media', assetId: spec.sourceAssetId},
              {
                type: 'scene',
                role: 'media',
                scene: {
                  version: 1,
                  objects: [
                    {
                      id: pieceId,
                      semanticLabel: 'Match',
                      shape: 'matchstick',
                      ...source,
                      tone: 'accent',
                      movable: true,
                    },
                  ],
                  targets: spec.destinations.map((destination) => ({
                    id: destination.id,
                    semanticLabel: 'Open space',
                    ...matchstickSceneLocation(destination.to),
                  })),
                },
              },
              {type: 'text', role: 'prompt', value: 'Move one match.'},
            ],
          },
          input: {type: 'piece_move'},
          validation: {
            type: 'legal_piece_move',
            value: spec.destinations.map((destination) => ({
              pieceId,
              targetId: destination.id,
              correct: destination.id === spec.answerDestinationId,
            })),
          },
          transition: {correct: 'reveal', incorrect: 'solve'},
        },
        reveal: {
          presentation: {
            layers: [
              {type: 'canvas', role: 'media', assetId: spec.solvedAssetId},
              {
                type: 'text',
                role: 'reveal_title',
                value: `${spec.solvedEquation}. One stroke changes sides.`,
              },
            ],
          },
          input: {type: 'tap', label: 'Done'},
          validation: {type: 'none'},
          transition: {default: '$end'},
        },
      },
    },
  };
}

const additionalMatchstickRounds = additionalMatchstickRoundSpecs.map(
  additionalMatchstickRound,
);

const moveOneMatchV4: StarterPlay = {
  id: 'mixli_starter_move_one_match',
  revisionId: 'rev_4',
  topics: ['puzzles', 'logic'],
  document: {
    schemaVersion: 1,
    id: 'mixli_starter_move_one_match',
    revisionId: 'rev_4',
    format: 'solve',
    classification: 'challenge',
    topics: ['puzzles', 'logic'],
    learningTopics: [],
    estimatedDurationSec: 20,
    assets: [
      'mixli_canvas_matchsticks_base_v4',
      'mixli_canvas_matchsticks_solved_v3',
    ],
    sources: [],
    entryState: 'solve',
    states: {
      solve: {
        presentation: {
          layers: [
            {
              type: 'canvas',
              role: 'media',
              assetId: 'mixli_canvas_matchsticks_base_v4',
            },
            {
              type: 'scene',
              role: 'media',
              scene: {
                version: 1,
                objects: [
                  {
                    id: 'operator_vertical',
                    semanticLabel: 'Vertical match',
                    shape: 'matchstick',
                    x: 0.325,
                    y: 0.43,
                    width: 0.03,
                    height: 0.14,
                    tone: 'accent',
                    movable: true,
                  },
                ],
                targets: [
                  {
                    id: 'solution_a',
                    semanticLabel: 'Upper right opening',
                    x: 0.195,
                    y: 0.36,
                    width: 0.04,
                    height: 0.14,
                  },
                  {
                    id: 'invalid_left',
                    semanticLabel: 'Lower left opening',
                    x: 0.425,
                    y: 0.5,
                    width: 0.04,
                    height: 0.14,
                  },
                  {
                    id: 'invalid_right',
                    semanticLabel: 'Right opening',
                    x: 0.745,
                    y: 0.5,
                    width: 0.04,
                    height: 0.14,
                  },
                ],
              },
            },
            {type: 'text', role: 'prompt', value: 'Move one match.'},
          ],
        },
        input: {
          type: 'piece_move',
        },
        validation: {
          type: 'legal_piece_move',
          value: [
            {
              pieceId: 'operator_vertical',
              targetId: 'solution_a',
              correct: true,
            },
            {
              pieceId: 'operator_vertical',
              targetId: 'invalid_left',
              correct: false,
            },
            {
              pieceId: 'operator_vertical',
              targetId: 'invalid_right',
              correct: false,
            },
          ],
        },
        transition: {correct: 'reveal', incorrect: 'solve'},
      },
      reveal: {
        presentation: {
          layers: [
            {type: 'canvas', role: 'media', assetId: 'mixli_canvas_matchsticks_solved_v3'},
            {type: 'text', role: 'reveal_title', value: '8 - 4 = 4. One stroke changes sides.'},
          ],
        },
        input: {type: 'tap', label: 'Done'},
        validation: {type: 'none'},
        transition: {default: '$end'},
      },
    },
  },
};

const moveOneMatchV3: StarterPlay = {
  id: 'mixli_starter_move_one_match',
  revisionId: 'rev_3',
  topics: ['puzzles', 'logic'],
  document: {
    schemaVersion: 1,
    id: 'mixli_starter_move_one_match',
    revisionId: 'rev_3',
    format: 'solve',
    classification: 'challenge',
    topics: ['puzzles', 'logic'],
    learningTopics: [],
    estimatedDurationSec: 20,
    assets: ['mixli_canvas_matchsticks_v3', 'mixli_canvas_matchsticks_solved_v3'],
    sources: [],
    entryState: 'solve',
    states: {
      solve: {
        presentation: {
          layers: [
            {type: 'canvas', role: 'media', assetId: 'mixli_canvas_matchsticks_v3'},
            {type: 'text', role: 'prompt', value: 'Move one match.'},
          ],
        },
        input: {
          type: 'drag',
          dragOrigin: {x: 0.325, y: 0.43},
          dragSize: {width: 0.03, height: 0.14},
          targets: [
            {id: 'solution_a', x: 0.195, y: 0.36, width: 0.04, height: 0.14},
            {id: 'invalid_left', x: 0.425, y: 0.5, width: 0.04, height: 0.14},
            {id: 'invalid_right', x: 0.745, y: 0.5, width: 0.04, height: 0.14},
          ],
          handleLabel: 'Move match',
        },
        validation: {type: 'target_region', value: 'solution_a'},
        transition: {correct: 'reveal', incorrect: 'solve'},
      },
      reveal: {
        presentation: {
          layers: [
            {
              type: 'canvas',
              role: 'media',
              assetId: 'mixli_canvas_matchsticks_solved_v3',
            },
            {
              type: 'text',
              role: 'reveal_title',
              value: '8 - 4 = 4. One stroke changes sides.',
            },
          ],
        },
        input: {type: 'tap', label: 'Done'},
        validation: {type: 'none'},
        transition: {default: '$end'},
      },
    },
  },
};

const quietSwitchCueDurationMs = 2200;

const quietSwitchV1: StarterPlay = {
  id: 'mixli_starter_quiet_switch',
  revisionId: 'rev_1',
  topics: ['observation', 'design'],
  document: {
    schemaVersion: 1,
    id: 'mixli_starter_quiet_switch',
    revisionId: 'rev_1',
    format: 'guess',
    classification: 'challenge',
    topics: ['observation', 'design'],
    learningTopics: [],
    estimatedDurationSec: 15,
    assets: [
      'mixli_canvas_quiet_switch_before_v1',
      'mixli_canvas_quiet_switch_after_v1',
    ],
    sources: [],
    entryState: 'observe',
    states: {
      observe: {
        presentation: {
          layers: [
            {type: 'canvas', role: 'media', assetId: 'mixli_canvas_quiet_switch_before_v1'},
            {type: 'text', role: 'prompt', value: 'Remember the room.'},
          ],
        },
        input: {type: 'tap', label: 'Ready'},
        validation: {type: 'none'},
        transition: {default: 'choose'},
      },
      choose: {
        presentation: {
          layers: [
            {type: 'canvas', role: 'media', assetId: 'mixli_canvas_quiet_switch_after_v1'},
            {type: 'text', role: 'prompt', value: 'What changed?'},
          ],
        },
        input: {
          type: 'single_choice',
          options: [
            {id: 'vase', label: 'The vase moved'},
            {id: 'book', label: 'The book changed'},
            {id: 'lamp', label: 'The lamp changed'},
          ],
        },
        validation: {type: 'equals', value: 'vase'},
        transition: {correct: 'reveal', incorrect: 'choose'},
      },
      reveal: {
        presentation: {
          layers: [
            {type: 'canvas', role: 'media', assetId: 'mixli_canvas_quiet_switch_after_v1'},
            {type: 'text', role: 'reveal_title', value: 'The vase moved to the right.'},
          ],
        },
        input: {type: 'tap', label: 'Done'},
        validation: {type: 'none'},
        transition: {default: '$end'},
      },
    },
  },
};

const quietSwitchV1States = quietSwitchV1.document.states as Record<string, unknown>;

const quietSwitchV2: StarterPlay = {
  id: 'mixli_starter_quiet_switch',
  revisionId: 'rev_2',
  topics: ['observation', 'design'],
  document: {
    schemaVersion: 1,
    id: 'mixli_starter_quiet_switch',
    revisionId: 'rev_2',
    format: 'guess',
    classification: 'challenge',
    topics: ['observation', 'design'],
    learningTopics: [],
    estimatedDurationSec: 15,
    assets: [
      'mixli_canvas_quiet_switch_before_v1',
      'mixli_canvas_quiet_switch_after_v1',
    ],
    sources: [],
    entryState: 'observe',
    states: {
      observe: {
        presentation: {
          layers: [
            {type: 'canvas', role: 'media', assetId: 'mixli_canvas_quiet_switch_before_v1'},
            {type: 'text', role: 'prompt', value: 'Look closer.'},
          ],
        },
        input: {
          type: 'timed_cue',
          cueId: 'observe_1',
          cueOrdinal: 1,
          durationMs: quietSwitchCueDurationMs,
        },
        validation: {type: 'none'},
        transition: {default: 'choose'},
      },
      choose: quietSwitchV1States['choose'],
      reveal: quietSwitchV1States['reveal'],
    },
  },
};

function additionalQuietSwitchPlay(
  spec: QuietSwitchSpec,
  revisionId: 'rev_1' | 'rev_2',
): StarterPlay {
  const sourceAssetId = `mixli_canvas_${spec.assetStem}_before_v1`;
  const choiceAssetId = `mixli_canvas_${spec.assetStem}_after_v1`;
  return {
    id: spec.id,
    revisionId,
    topics: spec.topics,
    document: {
      schemaVersion: 1,
      id: spec.id,
      revisionId,
      format: 'guess',
      classification: 'challenge',
      topics: [...spec.topics],
      learningTopics: [],
      estimatedDurationSec: 15,
      assets: [sourceAssetId, choiceAssetId],
      sources: [],
      entryState: 'observe',
      states: {
        observe: {
          presentation: {
            layers: [
              {type: 'canvas', role: 'media', assetId: sourceAssetId},
              {type: 'text', role: 'prompt', value: revisionId === 'rev_2' ? 'Look closer.' : 'Remember the scene.'},
            ],
          },
          input: revisionId === 'rev_2'
            ? {
                type: 'timed_cue',
                cueId: 'observe_1',
                cueOrdinal: 1,
                durationMs: quietSwitchCueDurationMs,
              }
            : {type: 'tap', label: 'Ready'},
          validation: {type: 'none'},
          transition: {default: 'choose'},
        },
        choose: {
          presentation: {
            layers: [
              {type: 'canvas', role: 'media', assetId: choiceAssetId},
              {type: 'text', role: 'prompt', value: 'What changed?'},
            ],
          },
          input: {
            type: 'single_choice',
            options: [
              {id: spec.answer, label: spec.answerLabel},
              ...spec.distractors,
            ],
          },
          validation: {type: 'equals', value: spec.answer},
          transition: {correct: 'reveal', incorrect: 'choose'},
        },
        reveal: {
          presentation: {
            layers: [
              {type: 'canvas', role: 'media', assetId: choiceAssetId},
              {type: 'text', role: 'reveal_title', value: spec.reveal},
            ],
          },
          input: {type: 'tap', label: 'Done'},
          validation: {type: 'none'},
          transition: {default: '$end'},
        },
      },
    },
  };
}

const additionalQuietSwitchV1 = additionalQuietSwitchSpecs.map((spec) =>
  additionalQuietSwitchPlay(spec, 'rev_1'),
);
const additionalQuietSwitchV2 = additionalQuietSwitchSpecs.map((spec) =>
  additionalQuietSwitchPlay(spec, 'rev_2'),
);

const sleightRoundSpecs: readonly SleightRoundSpec[] = [
  {id: 'mixli_starter_sleight_one', durationMs: 2400, answerPositionId: 'right', trajectory: {cupIds: ['left', 'center', 'right'], coinStartCupId: 'left', events: [{atMs: 500, type: 'occlude', cupId: 'left'}, {atMs: 1400, type: 'swap', firstCupId: 'left', secondCupId: 'right'}]}},
  {id: 'mixli_starter_sleight_two', durationMs: 2600, answerPositionId: 'left', trajectory: {cupIds: ['left', 'center', 'right'], coinStartCupId: 'center', events: [{atMs: 600, type: 'swap', firstCupId: 'center', secondCupId: 'left'}, {atMs: 1700, type: 'swap', firstCupId: 'left', secondCupId: 'right'}]}},
  {id: 'mixli_starter_sleight_three', durationMs: 2800, answerPositionId: 'center', trajectory: {cupIds: ['left', 'center', 'right'], coinStartCupId: 'right', events: [{atMs: 550, type: 'occlude', cupId: 'right'}, {atMs: 1200, type: 'swap', firstCupId: 'right', secondCupId: 'center'}, {atMs: 2100, type: 'swap', firstCupId: 'center', secondCupId: 'left'}]}},
  {id: 'mixli_starter_sleight_four', durationMs: 2700, answerPositionId: 'left', trajectory: {cupIds: ['left', 'center', 'right'], coinStartCupId: 'left', events: [{atMs: 650, type: 'swap', firstCupId: 'left', secondCupId: 'center'}, {atMs: 1400, type: 'transfer', fromCupId: 'left', toCupId: 'right'}, {atMs: 2100, type: 'swap', firstCupId: 'right', secondCupId: 'center'}]}},
  {id: 'mixli_starter_sleight_five', durationMs: 2500, answerPositionId: 'right', trajectory: {cupIds: ['left', 'center', 'right'], coinStartCupId: 'center', events: [{atMs: 700, type: 'transfer', fromCupId: 'center', toCupId: 'left'}, {atMs: 1700, type: 'swap', firstCupId: 'left', secondCupId: 'right'}]}},
  {id: 'mixli_starter_sleight_six', durationMs: 2900, answerPositionId: 'right', trajectory: {cupIds: ['left', 'center', 'right'], coinStartCupId: 'right', events: [{atMs: 600, type: 'swap', firstCupId: 'right', secondCupId: 'left'}, {atMs: 1400, type: 'transfer', fromCupId: 'right', toCupId: 'center'}, {atMs: 2200, type: 'swap', firstCupId: 'center', secondCupId: 'left'}]}},
];

function sleightRound(spec: SleightRoundSpec): StarterPlay {
  const cueId = 'shuffle_1';
  const initialScene = sleightScene(spec, cueId, false);
  const finalScene = sleightScene(spec, cueId, true);
  const answerLabel = `${spec.answerPositionId[0]!.toUpperCase()}${spec.answerPositionId.slice(1)} cup`;
  return {
    id: spec.id,
    revisionId: 'rev_1',
    topics: ['observation', 'focus'],
    document: {
      schemaVersion: 1,
      id: spec.id,
      revisionId: 'rev_1',
      format: 'guess',
      classification: 'challenge',
      topics: ['observation', 'focus'],
      learningTopics: [],
      estimatedDurationSec: 12,
      assets: [],
      sources: [],
      requiredPlatformFlags: ['timed_scene_v1'],
      entryState: 'observe',
      states: {
        observe: {
          presentation: {layers: [{type: 'scene', role: 'media', scene: initialScene}, {type: 'text', role: 'prompt', value: 'Track the coin.'}]},
          input: {type: 'timed_cue', cueId, cueOrdinal: 1, durationMs: spec.durationMs},
          validation: {type: 'none'},
          transition: {default: 'choose'},
        },
        choose: {
          presentation: {layers: [{type: 'scene', role: 'media', scene: finalScene}, {type: 'text', role: 'prompt', value: 'Where is it?'}]},
          input: {type: 'single_choice', options: [{id: 'left', label: 'Left cup'}, {id: 'center', label: 'Center cup'}, {id: 'right', label: 'Right cup'}]},
          validation: {type: 'equals', value: spec.answerPositionId},
          transition: {correct: 'replay', incorrect: 'choose'},
        },
        replay: {
          presentation: {layers: [{type: 'scene', role: 'media', scene: initialScene}, {type: 'text', role: 'prompt', value: 'Track it again.'}]},
          input: {type: 'timed_cue', cueId, cueOrdinal: 1, durationMs: spec.durationMs},
          validation: {type: 'none'},
          transition: {default: 'reveal'},
        },
        reveal: {
          presentation: {layers: [{type: 'scene', role: 'media', scene: finalScene}, {type: 'text', role: 'reveal_title', value: `The coin finishes under the ${answerLabel.toLowerCase()}.`}]},
          input: {type: 'tap', label: 'Done'}, validation: {type: 'none'}, transition: {default: '$end'},
        },
      },
    },
  };
}

function sleightScene(spec: SleightRoundSpec, cueId: string, final: boolean): Record<string, unknown> {
  const positions = new Map<string, string>(spec.trajectory.cupIds.map((cupId) => [cupId, cupId]));
  let coinCupId = spec.trajectory.coinStartCupId;
  const cupFrames = new Map<string, Array<Record<string, number>>>();
  const coinFrames: Array<Record<string, number>> = [];
  const addFrame = (timeMs: number, verticalOffsets = new Map<string, number>()) => {
    for (const cupId of spec.trajectory.cupIds) {
      cupFrames.get(cupId)!.push({
        timeMs,
        ...sleightRect(positions.get(cupId)!, verticalOffsets.get(cupId) ?? 0),
      });
    }
    coinFrames.push({
      timeMs,
      ...sleightCoinRect(
        positions.get(coinCupId)!,
        verticalOffsets.get(coinCupId) ?? 0,
      ),
    });
  };
  for (const cupId of spec.trajectory.cupIds) cupFrames.set(cupId, []);
  addFrame(0);
  let previousEventAtMs = 0;
  for (const event of spec.trajectory.events) {
    if (event.type === 'swap') {
      const midpoint = Math.floor((previousEventAtMs + event.atMs) / 2);
      if (midpoint > previousEventAtMs) {
        addFrame(midpoint, new Map([
          [event.firstCupId, -.07],
          [event.secondCupId, .07],
        ]));
      }
    }
    applySleightVisualEvent(event, positions, (cupId) => { if (event.type === 'transfer' && event.fromCupId === coinCupId) coinCupId = event.toCupId; });
    addFrame(event.atMs);
    previousEventAtMs = event.atMs;
  }
  addFrame(spec.durationMs);
  const object = (id: string, label: string, rect: Record<string, number>, shape: 'circle' | 'rounded_rect' | 'cup' | 'coin', tone: string) => ({id, semanticLabel: label, shape, ...rect, tone});
  const objects = [
    object('coin', 'Coin', coinFrames[final ? coinFrames.length - 1 : 0]!, 'coin', 'accent'),
    ...spec.trajectory.cupIds.map((cupId) => object(cupId, 'Cup', cupFrames.get(cupId)![final ? cupFrames.get(cupId)!.length - 1 : 0]!, 'cup', 'surface')),
  ];
  return {version: 1, objects, targets: [], ...(final ? {} : {cues: [
    {id: cueId, objectId: 'coin', durationMs: spec.durationMs, keyframes: coinFrames},
    ...spec.trajectory.cupIds.map((cupId) => ({id: cueId, objectId: cupId, durationMs: spec.durationMs, keyframes: cupFrames.get(cupId)!})),
  ]})};
}

function applySleightVisualEvent(event: SleightTrajectoryEvent, positions: Map<string, string>, transfer: (cupId: string) => void): void {
  if (event.type === 'swap') {
    const first = positions.get(event.firstCupId)!;
    positions.set(event.firstCupId, positions.get(event.secondCupId)!);
    positions.set(event.secondCupId, first);
  } else if (event.type === 'transfer') {
    transfer(event.fromCupId);
  }
}

function sleightRect(position: string, verticalOffset = 0): Record<string, number> {
  const x = {left: .1, center: .42, right: .74}[position];
  if (x === undefined) throw new Error(`unknown_sleight_position:${position}`);
  return {x, y: .36 + verticalOffset, width: .16, height: .28};
}

function sleightCoinRect(position: string, verticalOffset = 0): Record<string, number> {
  const cup = sleightRect(position, verticalOffset);
  return {x: cup.x! + .06, y: cup.y! + .2, width: .04, height: .04};
}

const constellationObjects = [
  {id: 'a', label: 'Small dark dot', tone: 'foreground', rect: {x: .08, y: .24, width: .06, height: .06}},
  {id: 'b', label: 'Medium pale dot', tone: 'surface', rect: {x: .31, y: .2, width: .08, height: .08}},
  {id: 'c', label: 'Tiny soft dot', tone: 'muted', rect: {x: .66, y: .26, width: .05, height: .05}},
  {id: 'd', label: 'Large dark dot', tone: 'foreground', rect: {x: .12, y: .64, width: .1, height: .1}},
  {id: 'e', label: 'Small pale dot', tone: 'surface', rect: {x: .43, y: .66, width: .065, height: .065}},
  {id: 'f', label: 'Wide soft dot', tone: 'muted', rect: {x: .72, y: .63, width: .085, height: .085}},
] as const;

const constellationRoundSpecs: readonly ConstellationRoundSpec[] = [
  {id: 'mixli_starter_constellation_one', durationMs: 2200, targetObjectIds: ['b', 'e'], delta: {x: .08, y: .04}},
  {id: 'mixli_starter_constellation_two', durationMs: 2400, targetObjectIds: ['a', 'f'], delta: {x: .06, y: .08}},
  {id: 'mixli_starter_constellation_three', durationMs: 2600, targetObjectIds: ['c', 'd'], delta: {x: .1, y: -.05}},
  {id: 'mixli_starter_constellation_four', durationMs: 2300, targetObjectIds: ['a', 'e'], delta: {x: -.04, y: .06}},
  {id: 'mixli_starter_constellation_five', durationMs: 2500, targetObjectIds: ['b', 'd'], delta: {x: .05, y: -.08}},
  {id: 'mixli_starter_constellation_six', durationMs: 2700, targetObjectIds: ['c', 'f'], delta: {x: -.06, y: -.04}},
];

function constellationRound(spec: ConstellationRoundSpec): StarterPlay {
  const cueId = 'constellation_1';
  const trajectory = constellationTrajectory(spec);
  const initialScene = constellationScene(spec, trajectory, cueId, false);
  const finalScene = constellationScene(spec, trajectory, cueId, true);
  const targetLabels = constellationObjects
    .filter((object) => spec.targetObjectIds.includes(object.id))
    .map((object) => object.label.toLowerCase())
    .join(' and ');
  return {
    id: spec.id,
    revisionId: 'rev_1',
    topics: ['observation', 'attention'],
    document: {
      schemaVersion: 1,
      id: spec.id,
      revisionId: 'rev_1',
      format: 'guess',
      classification: 'challenge',
      topics: ['observation', 'attention'],
      learningTopics: [],
      estimatedDurationSec: 12,
      assets: [],
      sources: [],
      requiredPlatformFlags: ['timed_scene_v1', 'multiple_choice', 'set_equality'],
      entryState: 'observe',
      states: {
        observe: {
          presentation: {layers: [{type: 'scene', role: 'media', scene: initialScene}, {type: 'text', role: 'prompt', value: 'Track the marked dots.'}]},
          input: {type: 'timed_cue', cueId, cueOrdinal: 1, durationMs: spec.durationMs},
          validation: {type: 'none'},
          transition: {default: 'choose'},
        },
        choose: {
          presentation: {layers: [{type: 'scene', role: 'media', scene: finalScene}, {type: 'text', role: 'prompt', value: 'Mark both.'}]},
          input: {type: 'multiple_choice', options: constellationObjects.map((object) => ({id: object.id, label: object.label}))},
          validation: {type: 'set_equality', value: spec.targetObjectIds},
          transition: {correct: 'replay', incorrect: 'choose'},
        },
        replay: {
          presentation: {layers: [{type: 'scene', role: 'media', scene: initialScene}, {type: 'text', role: 'prompt', value: 'Watch the marked dots.'}]},
          input: {type: 'timed_cue', cueId, cueOrdinal: 1, durationMs: spec.durationMs},
          validation: {type: 'none'},
          transition: {default: 'reveal'},
        },
        reveal: {
          presentation: {layers: [{type: 'scene', role: 'media', scene: finalScene}, {type: 'text', role: 'reveal_title', value: `Marked: ${targetLabels}.`}]},
          input: {type: 'tap', label: 'Done'},
          validation: {type: 'none'},
          transition: {default: '$end'},
        },
      },
    },
  };
}

function constellationTrajectory(spec: ConstellationRoundSpec): ConstellationTrajectory {
  return {
    objectIds: constellationObjects.map((object) => object.id),
    durationMs: spec.durationMs,
    tracks: constellationObjects.map((object, index) => {
      const midpoint = shiftConstellationRect(
        object.rect,
        spec.delta.x * .48,
        spec.delta.y * .48 + (index % 2 === 0 ? -.018 : .018),
      );
      const finalRect = shiftConstellationRect(object.rect, spec.delta.x, spec.delta.y);
      return {
        objectId: object.id,
        keyframes: [
          {timeMs: 0, ...object.rect},
          {timeMs: Math.floor(spec.durationMs / 2), ...midpoint},
          {timeMs: spec.durationMs, ...finalRect},
        ],
      };
    }),
  };
}

function shiftConstellationRect(
  rect: ConstellationRect,
  x: number,
  y: number,
): ConstellationRect {
  return {x: rect.x + x, y: rect.y + y, width: rect.width, height: rect.height};
}

function constellationScene(
  spec: ConstellationRoundSpec,
  trajectory: ConstellationTrajectory,
  cueId: string,
  final: boolean,
): Record<string, unknown> {
  const finalRects = new Map(
    trajectory.tracks.map((track) => [
      track.objectId,
      track.keyframes.at(-1)!,
    ]),
  );
  const objects = constellationObjects.map((object) => ({
    id: object.id,
    semanticLabel: final || !spec.targetObjectIds.includes(object.id)
      ? object.label
      : `Marked ${object.label.toLowerCase()}`,
    shape: 'orb',
    ...(final ? finalRects.get(object.id)! : object.rect),
    tone: !final && spec.targetObjectIds.includes(object.id) ? 'accent' : object.tone,
  }));
  return {
    version: 1,
    objects,
    targets: [],
    ...(final ? {} : {
      cues: trajectory.tracks.map((track) => ({
        id: cueId,
        objectId: track.objectId,
        durationMs: trajectory.durationMs,
        keyframes: track.keyframes,
      })),
    }),
  };
}

function counterexampleRound(spec: CounterexampleRoundSpec): StarterPlay {
  const solution = solveCounterexample(spec.claim, spec.tiles);
  const sourceAssetId = `${spec.id}_source_canvas`;
  const solvedAssetId = `${spec.id}_solved_canvas`;
  const claim = `Every ${spec.claim.color} tile is ${spec.claim.shape}.`;
  const reveal = solution.answerId === 'insufficient'
    ? 'No shown tile breaks the claim.'
    : `Tile ${solution.answerId.toUpperCase()} breaks the claim.`;
  return {
    id: spec.id,
    revisionId: 'rev_1',
    topics: spec.topics,
    document: {
      schemaVersion: 1,
      id: spec.id,
      revisionId: 'rev_1',
      format: 'solve',
      classification: 'challenge',
      topics: spec.topics,
      learningTopics: [],
      estimatedDurationSec: 15,
      assets: [sourceAssetId, solvedAssetId],
      sources: [],
      entryState: 'choose',
      states: {
        choose: {
          presentation: {layers: [
            {type: 'canvas', role: 'media', assetId: sourceAssetId},
            {type: 'text', role: 'prompt', value: claim},
          ]},
          input: {type: 'single_choice', options: [
            ...spec.tiles.map((tile) => ({id: tile.id, label: `Tile ${tile.id.toUpperCase()}`})),
            {id: 'insufficient', label: 'No counterexample'},
          ]},
          validation: {type: 'equals', value: solution.answerId},
          transition: {correct: 'reveal', incorrect: 'choose'},
        },
        reveal: {
          presentation: {layers: [
            {type: 'canvas', role: 'media', assetId: solvedAssetId},
            {type: 'text', role: 'reveal_title', value: reveal},
          ]},
          input: {type: 'tap', label: 'Done'},
          validation: {type: 'none'},
          transition: {default: '$end'},
        },
      },
    },
  };
}

function secondThoughtRound(spec: SecondThoughtRoundSpec): StarterPlay {
  const assetId = `${spec.id}_canvas`;
  const adviceText = spec.round.advice === 'unsure' ? 'Guide: unsure.' : `Guide: ${spec.round.advice}.`;
  const states: Record<string, unknown> = {};
  for (const initial of ['north', 'south'] as const) {
    const solution = solveSecondThought({...spec.round, initial});
    states[`advice_${initial}`] = {
      presentation: {layers: [
        {type: 'canvas', role: 'media', assetId},
        {type: 'text', role: 'prompt', value: adviceText},
        {type: 'text', role: 'detail', value: `Flag: ${spec.round.evidence}.`},
      ]},
      input: {type: 'single_choice', options: [{id: 'keep', label: 'Keep'}, {id: 'change', label: 'Change'}]},
      validation: {type: 'equals', value: solution.decision}, transition: {correct: `reveal_${initial}`, incorrect: `advice_${initial}`},
    };
    states[`reveal_${initial}`] = {
      presentation: {layers: [{type: 'canvas', role: 'media', assetId}, {type: 'text', role: 'reveal_title', value: `${solution.finalChoice}. Evidence decides.`}]},
      input: {type: 'tap', label: 'Done'}, validation: {type: 'none'}, transition: {default: '$end'},
    };
  }
  return {
    id: spec.id, revisionId: 'rev_1', topics: spec.topics,
    document: {
      schemaVersion: 1, id: spec.id, revisionId: 'rev_1', format: 'solve', classification: 'challenge',
      topics: spec.topics, learningTopics: [], estimatedDurationSec: 18, assets: [assetId], sources: [], entryState: 'initial',
      states: {
        initial: {
          presentation: {layers: [{type: 'canvas', role: 'media', assetId}, {type: 'text', role: 'prompt', value: 'Choose a direction.'}]},
          input: {type: 'single_choice', options: [{id: 'north', label: 'North'}, {id: 'south', label: 'South'}]},
          validation: {type: 'none'}, transition: {north: 'advice_north', south: 'advice_south'},
        },
        ...states,
      },
    },
  };
}
function ruleFlipRound(spec: RuleFlipRoundSpec): StarterPlay {
  const shape = solveRuleFlip('shape', spec.object).side;
  const fill = solveRuleFlip('fill', spec.object).side;
  const assetId = `${spec.id}_canvas`;
  const option = (trial: 'shape' | 'fill', side: 'left' | 'right') => `${trial}_${side}`;
  return {
    id: spec.id, revisionId: 'rev_1', topics: spec.topics,
    document: {
      schemaVersion: 1, id: spec.id, revisionId: 'rev_1', format: 'solve', classification: 'challenge',
      topics: spec.topics, learningTopics: [], estimatedDurationSec: 16, assets: [assetId], sources: [], entryState: 'shape',
      states: {
        shape: {
          presentation: {layers: [{type: 'canvas', role: 'media', assetId}, {type: 'text', role: 'prompt', value: 'Shape: triangle left.'}]},
          input: {type: 'single_choice', options: [{id: option('shape', 'left'), label: 'Left'}, {id: option('shape', 'right'), label: 'Right'}]},
          validation: {type: 'equals', value: option('shape', shape)}, transition: {correct: 'fill', incorrect: 'shape'},
        },
        fill: {
          presentation: {layers: [{type: 'canvas', role: 'media', assetId}, {type: 'text', role: 'prompt', value: 'Fill: solid left.'}]},
          input: {type: 'single_choice', options: [{id: option('fill', 'left'), label: 'Left'}, {id: option('fill', 'right'), label: 'Right'}]},
          validation: {type: 'equals', value: option('fill', fill)}, transition: {correct: 'reveal', incorrect: 'fill'},
        },
        reveal: {
          presentation: {layers: [{type: 'canvas', role: 'media', assetId}, {type: 'text', role: 'reveal_title', value: `Shape: ${shape}. Fill: ${fill}.`}]},
          input: {type: 'tap', label: 'Done'}, validation: {type: 'none'}, transition: {default: '$end'},
        },
      },
    },
  };
}
function evidenceLensRound(spec: EvidenceLensRoundSpec): StarterPlay {
  const claims = evidenceLensClaims(spec.points);
  const assetId = `${spec.id}_canvas`;
  return {
    id: spec.id, revisionId: 'rev_1', topics: spec.topics,
    document: {
      schemaVersion: 1, id: spec.id, revisionId: 'rev_1', format: 'solve', classification: 'challenge',
      topics: spec.topics, learningTopics: [], estimatedDurationSec: 20, assets: [assetId], sources: [], entryState: 'claim',
      states: {
        claim: {
          presentation: {layers: [{type: 'canvas', role: 'media', assetId}, {type: 'text', role: 'prompt', value: 'Pick a claim.'}]},
          input: {type: 'single_choice', options: claims.map((claim) => ({id: claim.id, label: claim.label}))},
          validation: {type: 'none'}, transition: Object.fromEntries(claims.map((claim) => [claim.id, `evidence_${claim.id}`])),
        },
        ...Object.fromEntries(claims.map((claim) => {
          const solution = solveEvidenceLens(claim, spec.points);
          return [`evidence_${claim.id}`, {
            presentation: {layers: [{type: 'canvas', role: 'media', assetId}, {type: 'text', role: 'prompt', value: `Which point proves: ${claim.label}`}]},
            input: {type: 'single_choice', options: spec.points.map((point) => ({id: point.id, label: `Point ${point.id.toUpperCase()}`}))},
            validation: {type: 'equals', value: solution.answerId}, transition: {correct: `reveal_${claim.id}`, incorrect: `evidence_${claim.id}`},
          }];
        })),
        ...Object.fromEntries(claims.map((claim) => {
          const solution = solveEvidenceLens(claim, spec.points);
          return [`reveal_${claim.id}`, {
            presentation: {layers: [{type: 'canvas', role: 'media', assetId}, {type: 'text', role: 'reveal_title', value: `${solution.answerId.toUpperCase()}. ${claim.label}`}]},
            input: {type: 'tap', label: 'Done'}, validation: {type: 'none'}, transition: {default: '$end'},
          }];
        })),
      },
    },
  };
}
const sleightRounds = sleightRoundSpecs.map(sleightRound);
const constellationRounds = constellationRoundSpecs.map(constellationRound);
const counterexampleRounds = counterexampleRoundSpecs.map(counterexampleRound);
const evidenceLensRounds = evidenceLensRoundSpecs.map(evidenceLensRound);
const ruleFlipRounds = ruleFlipRoundSpecs.map(ruleFlipRound);
const secondThoughtRounds = secondThoughtRoundSpecs.map(secondThoughtRound);

const releaseV3StarterPlays: readonly StarterPlay[] = [
  moveOneMatchV3,
  ...releaseV3ChoiceSpecs.map((spec) => ({
    id: spec.id,
    revisionId: 'rev_3',
    topics: spec.topics,
    document: choiceDocument(spec, 'rev_3'),
  })),
];

const clarifiedChoiceSpecs: readonly ChoiceSpec[] = releaseV3ChoiceSpecs
  .filter((spec) => spec.id === 'mixli_starter_finish_pattern' || spec.id === 'mixli_starter_find_orbit')
  .map((spec) => spec.id === 'mixli_starter_finish_pattern'
    ? {...spec, assetId: 'mixli_canvas_pattern_v4', revealAssetId: 'mixli_canvas_pattern_solved_v4', prompt: 'Which shape is next?', reveal: 'Square. Same pair.'}
    : {...spec, assetId: 'mixli_canvas_orbit_v4', reveal: 'B. No gaps.'});
const clarifiedStarterPlays: readonly StarterPlay[] = clarifiedChoiceSpecs.map((spec) => ({
  id: spec.id, revisionId: 'rev_4', topics: spec.topics,
  document: choiceDocument(spec, 'rev_4'),
}));
const clarifiedPlayIds = new Set(clarifiedStarterPlays.map((play) => play.id));
const starterPlays = [
  moveOneMatchV4,
  ...additionalMatchstickRounds,
  ...releaseV3StarterPlays
      .filter((play) => play.id !== moveOneMatchV3.id)
      .map(
        (play) =>
            clarifiedStarterPlays.find(
              (replacement) => replacement.id === play.id,
            ) ??
            play,
      ),
  quietSwitchV2,
  ...additionalQuietSwitchV2,
  ...sleightRounds,
  ...constellationRounds,
  ...counterexampleRounds,
  ...evidenceLensRounds,
  ...ruleFlipRounds,
  ...secondThoughtRounds,
] as const;

const historicalStarterPlays = [
  ...legacyStarterPlays,
  ...releaseV2StarterPlays,
  ...releaseV3StarterPlays.filter(
    (play) => clarifiedPlayIds.has(play.id) || play.id === moveOneMatchV3.id,
  ),
  quietSwitchV1,
  ...additionalQuietSwitchV1,
] as const;

const allStarterPlays = [...historicalStarterPlays, ...starterPlays] as const;

const starterIntegrityReviews: readonly CatalogIntegrityReview[] = [
  {
    kind: 'matchstick',
    playId: 'mixli_starter_move_one_match',
    revisionId: 'rev_4',
    prompt: 'Move one match.',
    sourceAssetId: 'mixli_canvas_matchsticks_base_v4',
    solvedAssetId: 'mixli_canvas_matchsticks_solved_v3',
    sourceSegments: [...matchstickSourceSegments],
    sourceEquation: '6 + 4 = 4',
    movingPieceId: 'operator_vertical',
    destinations: [
      {
        id: 'solution_a',
        from: 'operator.vertical',
        to: 'left.b',
      },
      {
        id: 'invalid_left',
        from: 'operator.vertical',
        to: 'right.e',
      },
      {
        id: 'invalid_right',
        from: 'operator.vertical',
        to: 'result.e',
      },
    ],
    answerDestinationId: 'solution_a',
    solvedEquation: '8 - 4 = 4',
  },
  ...additionalMatchstickRoundSpecs.map((spec) => ({
    kind: 'matchstick' as const,
    playId: spec.id,
    revisionId: 'rev_1',
    prompt: 'Move one match.',
    sourceAssetId: spec.sourceAssetId,
    solvedAssetId: spec.solvedAssetId,
    sourceSegments: spec.sourceSegments,
    sourceEquation: spec.sourceEquation,
    movingPieceId: `match_${spec.movingSegment.replace('.', '_')}`,
    destinations: spec.destinations.map((destination) => ({
      id: destination.id,
      from: spec.movingSegment,
      to: destination.to,
    })),
    answerDestinationId: spec.answerDestinationId,
    solvedEquation: spec.solvedEquation,
  })),
  {
    kind: 'preference',
    playId: 'mixli_starter_city_instinct',
    revisionId: 'rev_3',
    prompt: 'Four days. Warm nights.',
    optionIds: ['lisbon', 'marrakech'],
    revealEvidence: ['Lisbon', 'Marrakech'],
    semanticEvidence: ['Lisbon', 'Marrakech'],
  },
  {
    kind: 'single_choice',
    playId: 'mixli_starter_finish_pattern',
    revisionId: 'rev_4',
    prompt: 'Which shape is next?',
    answer: 'square',
    revealStartsWith: 'Square.',
    semanticEvidence: ['circle, square, circle', 'missing shape'],
  },
  {
    kind: 'single_choice',
    playId: 'mixli_starter_find_orbit',
    revisionId: 'rev_4',
    prompt: 'Which path connects?',
    answer: 'b',
    revealStartsWith: 'B.',
    semanticEvidence: ['A', 'B', 'C', 'Start', 'End'],
  },
  {
    kind: 'preference',
    playId: 'mixli_starter_color_energy',
    revisionId: 'rev_3',
    prompt: 'Pick tonight’s energy.',
    optionIds: ['electric', 'soft', 'afterglow'],
    revealEvidence: ['electric', 'soft', 'afterglow'],
    semanticEvidence: ['electric', 'soft', 'afterglow'],
  },
  {
    kind: 'single_choice',
    playId: 'mixli_starter_quick_logic',
    revisionId: 'rev_3',
    prompt: 'Complete the sequence.',
    answer: '30',
    revealStartsWith: '30.',
    semanticEvidence: ['2', '6', '12', '20'],
  },
  {
    kind: 'quiet_switch',
    playId: 'mixli_starter_quiet_switch',
    revisionId: 'rev_2',
    prompt: 'Look closer.',
    sourceAssetId: 'mixli_canvas_quiet_switch_before_v1',
    choiceAssetId: 'mixli_canvas_quiet_switch_after_v1',
    choicePrompt: 'What changed?',
    answer: 'vase',
    changedElementIndex: 2,
    revealStartsWith: 'The vase moved',
  },
  ...additionalQuietSwitchSpecs.map((spec) => ({
    kind: 'quiet_switch' as const,
    playId: spec.id,
    revisionId: 'rev_2',
    prompt: 'Look closer.',
    sourceAssetId: `mixli_canvas_${spec.assetStem}_before_v1`,
    choiceAssetId: `mixli_canvas_${spec.assetStem}_after_v1`,
    choicePrompt: 'What changed?',
    answer: spec.answer,
    changedElementIndex: spec.changedElementIndex,
    revealStartsWith: spec.reveal,
  })),
  ...sleightRoundSpecs.map((spec) => ({
    kind: 'sleight' as const,
    playId: spec.id,
    revisionId: 'rev_1',
    prompt: 'Track the coin.',
    cueId: 'shuffle_1',
    durationMs: spec.durationMs,
    trajectory: spec.trajectory,
    answerPositionId: spec.answerPositionId,
    revealStartsWith: 'The coin finishes',
  })),
  ...constellationRoundSpecs.map((spec) => ({
    kind: 'constellation' as const,
    playId: spec.id,
    revisionId: 'rev_1',
    prompt: 'Track the marked dots.',
    cueId: 'constellation_1',
    durationMs: spec.durationMs,
    trajectory: constellationTrajectory(spec),
    targetObjectIds: spec.targetObjectIds,
    revealStartsWith: 'Marked:',
  })),
  ...counterexampleRoundSpecs.map((spec) => ({
    kind: 'counterexample' as const,
    playId: spec.id,
    revisionId: 'rev_1',
    prompt: `Every ${spec.claim.color} tile is ${spec.claim.shape}.`,
    claim: spec.claim,
    tiles: spec.tiles,
    sourceAssetId: `${spec.id}_source_canvas`,
    solvedAssetId: `${spec.id}_solved_canvas`,
    revealStartsWith: solveCounterexample(spec.claim, spec.tiles).answerId === 'insufficient'
      ? 'No shown tile'
      : 'Tile ',
  })),
  ...evidenceLensRoundSpecs.map((spec) => ({
    kind: 'evidence_lens' as const,
    playId: spec.id,
    revisionId: 'rev_1',
    sourceAssetId: `${spec.id}_canvas`,
    points: spec.points,
    claims: evidenceLensClaims(spec.points),
  })),  ...ruleFlipRoundSpecs.map((spec) => ({
    kind: 'rule_flip' as const,
    playId: spec.id,
    revisionId: 'rev_1',
    sourceAssetId: `${spec.id}_canvas`,
    object: spec.object,
  })),  ...secondThoughtRoundSpecs.map((spec) => ({
    kind: 'second_thought' as const,
    playId: spec.id,
    revisionId: 'rev_1',
    sourceAssetId: `${spec.id}_canvas`,
    round: spec.round,
  })),] as const;

export const productionCatalogIntegrityFixture: ProductionCatalogIntegrityFixture = {
  plays: starterPlays,
  canvasAssets: canvasAssets.map((asset) => normalizeCanvasAssetDocument(asset)),
  reviews: starterIntegrityReviews,
};

assertProductionCatalogIntegrity(productionCatalogIntegrityFixture);

export async function applyProductionCatalog(
  pool: Pool,
): Promise<ProductionCatalogStatus> {
  const canvasRepository = new PostgresCanvasAssetRepository(pool);
  for (const asset of canvasAssets) await canvasRepository.register(asset);

  const client = await pool.connect();
  try {
    await client.query('begin');
    for (const [curatedOrder, play] of historicalStarterPlays.entries()) {
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
  const eligibleIdentities = new Set(starterPlays.map((play) => `${play.id}\u0000${play.revisionId}`));
  const expectedCatalog = new Map(
    allStarterPlays.map((play) => [
      `${play.id}\u0000${play.revisionId}`,
      eligibleIdentities.has(`${play.id}\u0000${play.revisionId}`) ? 'eligible' : 'suspended',
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
  revisionId: 'rev_1' | 'rev_2' | 'rev_3' | 'rev_4',
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
    assets: [spec.assetId, ...(spec.revealAssetId === undefined ? [] : [spec.revealAssetId])],
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
            ...(revisionId !== 'rev_1'
              ? [{type: 'canvas', role: 'media', assetId: spec.revealAssetId ?? spec.assetId}]
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

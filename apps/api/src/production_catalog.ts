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

export const productionStarterPrefix = 'mixli_starter_';
export const productionStarterCount = 12;

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

const verifiedCanvasAssets = [
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

const canvasAssets = [
  ...legacyCanvasAssets,
  ...releaseCanvasAssets,
  ...verifiedCanvasAssets,
  ...clarifiedCanvasAssets,
  ...quietSwitchCanvasAssets,
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

function additionalQuietSwitchPlay(spec: QuietSwitchSpec): StarterPlay {
  const sourceAssetId = `mixli_canvas_${spec.assetStem}_before_v1`;
  const choiceAssetId = `mixli_canvas_${spec.assetStem}_after_v1`;
  return {
    id: spec.id,
    revisionId: 'rev_1',
    topics: spec.topics,
    document: {
      schemaVersion: 1,
      id: spec.id,
      revisionId: 'rev_1',
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
              {type: 'text', role: 'prompt', value: 'Remember the scene.'},
            ],
          },
          input: {type: 'tap', label: 'Ready'},
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

const additionalQuietSwitchPlays = additionalQuietSwitchSpecs.map(
  additionalQuietSwitchPlay,
);

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
  ...releaseV3StarterPlays.map((play) =>
    clarifiedStarterPlays.find((replacement) => replacement.id === play.id) ?? play,
  ),
  quietSwitchV1,
  ...additionalQuietSwitchPlays,
] as const;

const historicalStarterPlays = [
  ...legacyStarterPlays,
  ...releaseV2StarterPlays,
  ...releaseV3StarterPlays.filter((play) => clarifiedPlayIds.has(play.id)),
] as const;

const allStarterPlays = [...historicalStarterPlays, ...starterPlays] as const;

const starterIntegrityReviews: readonly CatalogIntegrityReview[] = [
  {
    kind: 'matchstick',
    playId: 'mixli_starter_move_one_match',
    revisionId: 'rev_3',
    prompt: 'Move one match.',
    sourceAssetId: 'mixli_canvas_matchsticks_v3',
    solvedAssetId: 'mixli_canvas_matchsticks_solved_v3',
    sourceSegments: [...matchstickSourceSegments],
    sourceEquation: '6 + 4 = 4',
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
    revisionId: 'rev_1',
    prompt: 'Remember the room.',
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
    revisionId: 'rev_1',
    prompt: 'Remember the scene.',
    sourceAssetId: `mixli_canvas_${spec.assetStem}_before_v1`,
    choiceAssetId: `mixli_canvas_${spec.assetStem}_after_v1`,
    choicePrompt: 'What changed?',
    answer: spec.answer,
    changedElementIndex: spec.changedElementIndex,
    revealStartsWith: spec.reveal,
  })),
] as const;

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

export const counterexampleColors = ['red', 'blue', 'gold'] as const;
export const counterexampleShapes = ['round', 'square'] as const;

export type CounterexampleColor = (typeof counterexampleColors)[number];
export type CounterexampleShape = (typeof counterexampleShapes)[number];

export interface CounterexampleClaim {
  readonly color: CounterexampleColor;
  readonly shape: CounterexampleShape;
}

export interface CounterexampleTile {
  readonly id: string;
  readonly color: CounterexampleColor;
  readonly shape: CounterexampleShape;
}

export interface CounterexampleSolution {
  readonly answerId: string;
  readonly counterexampleIds: readonly string[];
}

/**
 * Evaluates the finite predicate independently from Play validation. A round
 * may offer one decisive counterexample or an explicit insufficient-evidence
 * response; ambiguous authored data is not eligible for single-choice play.
 */
export function solveCounterexample(
  claim: CounterexampleClaim,
  tiles: readonly CounterexampleTile[],
): CounterexampleSolution {
  if (!isColor(claim.color) || !isShape(claim.shape)) {
    throw new Error('counterexample_claim');
  }
  if (
    tiles.length < 2 ||
    tiles.length > 12 ||
    new Set(tiles.map((tile) => tile.id)).size !== tiles.length ||
    tiles.some((tile) =>
      !isIdentifier(tile.id) || !isColor(tile.color) || !isShape(tile.shape),
    )
  ) {
    throw new Error('counterexample_tile');
  }
  const counterexampleIds = tiles
    .filter((tile) => tile.color === claim.color && tile.shape !== claim.shape)
    .map((tile) => tile.id);
  if (counterexampleIds.length > 1) {
    throw new Error('counterexample_ambiguous');
  }
  return {
    answerId: counterexampleIds[0] ?? 'insufficient',
    counterexampleIds,
  };
}

function isColor(value: unknown): value is CounterexampleColor {
  return typeof value === 'string' && counterexampleColors.includes(
    value as CounterexampleColor,
  );
}

function isShape(value: unknown): value is CounterexampleShape {
  return typeof value === 'string' && counterexampleShapes.includes(
    value as CounterexampleShape,
  );
}

function isIdentifier(value: string): boolean {
  return /^[a-z][a-z0-9_-]{0,39}$/.test(value);
}

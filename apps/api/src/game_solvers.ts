export interface MatchstickMoveSolution {
  readonly from: string;
  readonly to: string;
  readonly equation: string;
}

/** Changes whenever the independent proof algorithm's semantics change. */
export const oneMoveMatchstickSolverVersion = 'one-move-matchstick-solver-v1';

const digitSegments: Readonly<Record<string, readonly string[]>> = {
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

const digitBySignature = new Map<string, string>(
  Object.entries(digitSegments).map(([digit, segments]) => [
    segments.join(','),
    digit,
  ]),
);

const digitSlots = ['left', 'right', 'result'] as const;
const digitSegmentNames = ['a', 'b', 'c', 'd', 'e', 'f', 'g'] as const;

export const knownMatchstickSegments: readonly string[] = Object.freeze([
  ...digitSlots.flatMap((slot) =>
    digitSegmentNames.map((segment) => `${slot}.${segment}`),
  ),
  'operator.horizontal',
  'operator.vertical',
].sort());

/**
 * Decodes a complete seven-segment equation independently from gameplay
 * validation. Null means the segments do not form three digits and +/-.
 */
export function matchstickEquationFromSegments(
  occupied: ReadonlySet<string>,
): string | null {
  if ([...occupied].some((segment) => !knownMatchstickSegments.includes(segment))) {
    return null;
  }
  const digits = digitSlots.map((slot) => {
    const signature = digitSegmentNames
      .filter((segment) => occupied.has(`${slot}.${segment}`))
      .join(',');
    return digitBySignature.get(signature);
  });
  if (digits.some((digit) => digit === undefined)) return null;

  const horizontal = occupied.has('operator.horizontal');
  const vertical = occupied.has('operator.vertical');
  const operator = horizontal && vertical ? '+' : horizontal ? '-' : null;
  if (operator === null) return null;
  return `${digits[0]!} ${operator} ${digits[1]!} = ${digits[2]!}`;
}

/** Enumerates every one-stick move that turns a false, renderable equation true. */
export function enumerateOneMoveMatchstickSolutions(
  occupied: ReadonlySet<string>,
): readonly MatchstickMoveSolution[] {
  const source = matchstickEquationFromSegments(occupied);
  if (source === null || equationIsTrue(source)) return [];

  const solutions: MatchstickMoveSolution[] = [];
  for (const from of [...occupied].sort()) {
    for (const to of knownMatchstickSegments) {
      if (occupied.has(to)) continue;
      const moved = new Set(occupied);
      moved.delete(from);
      moved.add(to);
      const equation = matchstickEquationFromSegments(moved);
      if (equation !== null && equationIsTrue(equation)) {
        solutions.push({from, to, equation});
      }
    }
  }
  return Object.freeze(solutions);
}

export function matchstickSegmentsForEquation(
  left: string,
  operator: '+' | '-',
  right: string,
  result: string,
): ReadonlySet<string> {
  const digits = [left, right, result];
  if (digits.some((digit) => digitSegments[digit] === undefined)) {
    throw new RangeError('matchstick digits must be decimal numerals');
  }
  const segments = new Set<string>();
  for (const [index, slot] of digitSlots.entries()) {
    for (const segment of digitSegments[digits[index]!]!) {
      segments.add(`${slot}.${segment}`);
    }
  }
  segments.add('operator.horizontal');
  if (operator === '+') segments.add('operator.vertical');
  return segments;
}

function equationIsTrue(equation: string): boolean {
  const match = /^(\d) ([+-]) (\d) = (\d)$/.exec(equation);
  if (match === null) return false;
  const left = Number(match[1]);
  const right = Number(match[3]);
  const result = Number(match[4]);
  return (match[2] === '+' ? left + right : left - right) === result;
}

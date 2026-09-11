export interface SleightTrajectory {
  readonly cupIds: readonly string[];
  readonly coinStartCupId: string;
  readonly events: readonly SleightTrajectoryEvent[];
}

export type SleightTrajectoryEvent =
  | {
      readonly atMs: number;
      readonly type: 'occlude';
      readonly cupId: string;
    }
  | {
      readonly atMs: number;
      readonly type: 'swap';
      readonly firstCupId: string;
      readonly secondCupId: string;
    }
  | {
      readonly atMs: number;
      readonly type: 'transfer';
      readonly fromCupId: string;
      readonly toCupId: string;
    };

export interface SleightSimulation {
  readonly finalCupId: string;
  readonly finalPositionId: string;
  readonly positionsByCupId: Readonly<Record<string, string>>;
}

/**
 * A deliberately separate oracle for authored cup trajectories. It has no
 * rendering or gameplay dependencies, so catalog review can reject a final
 * answer that does not follow the declared swaps and transfers.
 */
export function simulateSleightTrajectory(
  trajectory: SleightTrajectory,
): SleightSimulation {
  if (trajectory.cupIds.length !== 3) throw new Error('sleight_cup_count');
  const cupIds = new Set<string>();
  for (const cupId of trajectory.cupIds) {
    if (!validId(cupId) || cupIds.has(cupId)) {
      throw new Error('sleight_cup_identity');
    }
    cupIds.add(cupId);
  }
  if (!cupIds.has(trajectory.coinStartCupId)) {
    throw new Error('sleight_coin_start');
  }

  const positions = new Map<string, string>(
    trajectory.cupIds.map((cupId) => [cupId, cupId]),
  );
  let coinCupId = trajectory.coinStartCupId;
  let previousTime = -1;
  for (const event of trajectory.events) {
    if (!Number.isInteger(event.atMs) || event.atMs < 0 || event.atMs <= previousTime) {
      throw new Error('sleight_event_time');
    }
    previousTime = event.atMs;
    switch (event.type) {
      case 'occlude':
        assertCup(cupIds, event.cupId);
        break;
      case 'swap': {
        assertCup(cupIds, event.firstCupId);
        assertCup(cupIds, event.secondCupId);
        if (event.firstCupId === event.secondCupId) throw new Error('sleight_swap_identity');
        const firstPosition = positions.get(event.firstCupId)!;
        positions.set(event.firstCupId, positions.get(event.secondCupId)!);
        positions.set(event.secondCupId, firstPosition);
        break;
      }
      case 'transfer':
        assertCup(cupIds, event.fromCupId);
        assertCup(cupIds, event.toCupId);
        if (event.fromCupId !== coinCupId || event.fromCupId === event.toCupId) {
          throw new Error('sleight_transfer_impossible');
        }
        coinCupId = event.toCupId;
        break;
    }
  }

  const positionsByCupId = Object.fromEntries(positions) as Record<string, string>;
  return Object.freeze({
    finalCupId: coinCupId,
    finalPositionId: positions.get(coinCupId)!,
    positionsByCupId: Object.freeze(positionsByCupId),
  });
}

function assertCup(cupIds: ReadonlySet<string>, cupId: string): void {
  if (!cupIds.has(cupId)) throw new Error('sleight_unknown_cup');
}

function validId(value: string): boolean {
  return /^[A-Za-z0-9_-]{1,80}$/.test(value);
}

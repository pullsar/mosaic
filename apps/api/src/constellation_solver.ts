export interface ConstellationRect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

export interface ConstellationKeyframe extends ConstellationRect {
  readonly timeMs: number;
}

export interface ConstellationTrack {
  readonly objectId: string;
  readonly keyframes: readonly ConstellationKeyframe[];
}

export interface ConstellationTrajectory {
  readonly objectIds: readonly string[];
  readonly durationMs: number;
  readonly tracks: readonly ConstellationTrack[];
}

export interface ConstellationEvaluation {
  readonly acceptedObjectIds: readonly string[];
  readonly finalRects: ReadonlyMap<string, ConstellationRect>;
}

/**
 * Independently validates the authored observation path. This solver does not
 * reuse client selection validation: it proves that every dot remains
 * identifiable along the supplied piecewise-linear trajectories.
 */
export function evaluateConstellationRound(
  trajectory: ConstellationTrajectory,
  targetObjectIds: readonly string[],
): ConstellationEvaluation {
  if (
    trajectory.objectIds.length !== 6 ||
    new Set(trajectory.objectIds).size !== trajectory.objectIds.length
  ) {
    throw new Error('constellation_object_ids');
  }
  if (
    targetObjectIds.length !== 2 ||
    new Set(targetObjectIds).size !== targetObjectIds.length
  ) {
    throw new Error('constellation_duplicate_target');
  }
  if (!targetObjectIds.every((id) => trajectory.objectIds.includes(id))) {
    throw new Error('constellation_unknown_target');
  }
  if (!Number.isInteger(trajectory.durationMs) || trajectory.durationMs < 300 || trajectory.durationMs > 12000) {
    throw new Error('constellation_duration');
  }
  if (
    trajectory.tracks.length !== trajectory.objectIds.length ||
    new Set(trajectory.tracks.map((track) => track.objectId)).size !== trajectory.tracks.length ||
    !trajectory.objectIds.every((id) => trajectory.tracks.some((track) => track.objectId === id))
  ) {
    throw new Error('constellation_tracks');
  }

  const tracks = new Map(
    trajectory.tracks.map((track) => [
      track.objectId,
      validateTrack(track, trajectory.durationMs),
    ]),
  );
  assertNoConstellationPathCollisions(trajectory.objectIds, tracks);

  return {
    acceptedObjectIds: [...targetObjectIds].sort(),
    finalRects: new Map(
      trajectory.objectIds.map((id) => [
        id,
        sampleTrack(tracks.get(id)!, trajectory.durationMs),
      ]),
    ),
  };
}

function validateTrack(
  track: ConstellationTrack,
  durationMs: number,
): readonly ConstellationKeyframe[] {
  if (
    track.keyframes.length < 2 ||
    track.keyframes[0]?.timeMs !== 0 ||
    track.keyframes.at(-1)?.timeMs !== durationMs
  ) {
    throw new Error('constellation_keyframes');
  }
  for (let index = 0; index < track.keyframes.length; index += 1) {
    const frame = track.keyframes[index]!;
    if (
      !Number.isInteger(frame.timeMs) ||
      frame.timeMs < 0 ||
      frame.timeMs > durationMs ||
      !isUnitRect(frame) ||
      (index > 0 && frame.timeMs <= track.keyframes[index - 1]!.timeMs)
    ) {
      throw new Error('constellation_keyframes');
    }
  }
  return track.keyframes;
}

function sampleTrack(
  keyframes: readonly ConstellationKeyframe[],
  timeMs: number,
): ConstellationRect {
  const afterIndex = keyframes.findIndex((frame) => frame.timeMs >= timeMs);
  if (afterIndex <= 0) return stripTime(keyframes[0]!);
  if (afterIndex === -1) return stripTime(keyframes.at(-1)!);
  const start = keyframes[afterIndex - 1]!;
  const end = keyframes[afterIndex]!;
  const fraction = (timeMs - start.timeMs) / (end.timeMs - start.timeMs);
  return {
    x: start.x + (end.x - start.x) * fraction,
    y: start.y + (end.y - start.y) * fraction,
    width: start.width + (end.width - start.width) * fraction,
    height: start.height + (end.height - start.height) * fraction,
  };
}

function stripTime({timeMs: _timeMs, ...rect}: ConstellationKeyframe): ConstellationRect {
  return rect;
}

function isUnitRect(rect: ConstellationRect): boolean {
  return [rect.x, rect.y, rect.width, rect.height].every(Number.isFinite) &&
    rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0 &&
    rect.x + rect.width <= 1 && rect.y + rect.height <= 1;
}

function overlaps(first: ConstellationRect, second: ConstellationRect): boolean {
  return first.x < second.x + second.width &&
    second.x < first.x + first.width &&
    first.y < second.y + second.height &&
    second.y < first.y + first.height;
}

function assertNoConstellationPathCollisions(
  objectIds: readonly string[],
  tracks: ReadonlyMap<string, readonly ConstellationKeyframe[]>,
): void {
  const times = [...new Set(
    [...tracks.values()].flatMap((track) => track.map((frame) => frame.timeMs)),
  )].sort((first, second) => first - second);
  for (let interval = 0; interval < times.length - 1; interval += 1) {
    const startMs = times[interval]!;
    const endMs = times[interval + 1]!;
    for (let index = 0; index < objectIds.length; index += 1) {
      for (let other = index + 1; other < objectIds.length; other += 1) {
        const firstTrack = tracks.get(objectIds[index]!)!;
        const secondTrack = tracks.get(objectIds[other]!)!;
        const firstStart = sampleTrack(firstTrack, startMs);
        const secondStart = sampleTrack(secondTrack, startMs);
        const firstEnd = sampleTrack(firstTrack, endMs);
        const secondEnd = sampleTrack(secondTrack, endMs);
        if (
          overlaps(firstStart, secondStart) ||
          overlaps(firstEnd, secondEnd) ||
          overlapsDuringInterval(firstStart, firstEnd, secondStart, secondEnd)
        ) {
          throw new Error('constellation_path_collision');
        }
      }
    }
  }
}

function overlapsDuringInterval(
  firstStart: ConstellationRect,
  firstEnd: ConstellationRect,
  secondStart: ConstellationRect,
  secondEnd: ConstellationRect,
): boolean {
  return allPositiveDuringInterior([
    secondStart.x + secondStart.width - firstStart.x,
    firstStart.x + firstStart.width - secondStart.x,
    secondStart.y + secondStart.height - firstStart.y,
    firstStart.y + firstStart.height - secondStart.y,
  ], [
    secondEnd.x + secondEnd.width - firstEnd.x,
    firstEnd.x + firstEnd.width - secondEnd.x,
    secondEnd.y + secondEnd.height - firstEnd.y,
    firstEnd.y + firstEnd.height - secondEnd.y,
  ]);
}

function allPositiveDuringInterior(
  starts: readonly number[],
  ends: readonly number[],
): boolean {
  let lower = 0;
  let upper = 1;
  for (let index = 0; index < starts.length; index += 1) {
    const start = starts[index]!;
    const slope = ends[index]! - start;
    if (slope === 0) {
      if (start <= 0) return false;
      continue;
    }
    const zero = -start / slope;
    if (slope > 0) {
      lower = Math.max(lower, zero);
    } else {
      upper = Math.min(upper, zero);
    }
  }
  return Math.max(lower, 0) < Math.min(upper, 1);
}

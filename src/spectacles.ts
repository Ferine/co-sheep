/**
 * Spectacle scheduling — pure logic. Rare, high-impact desktop events.
 * Random spectacles roll on a timer; showdown/feast are drama-triggered
 * and never come from this table.
 */

export type SpectacleType =
  | "wolf"
  | "ufo"
  | "merchant"
  | "balloon"
  | "shearing"
  | "showdown"
  | "feast";

export interface SpectacleSchedulerState {
  lastFiredMs: number;
  lastByType: Partial<Record<SpectacleType, number>>;
}

export interface SchedulerInput {
  state: SpectacleSchedulerState;
  nowMs: number;
  isNight: boolean;
  /** Random [0,1) injected by the caller for testability. */
  rand: number;
}

export const SPECTACLE = {
  /** Global floor between spectacles (~at most one per day). */
  MIN_GAP_MS: 20 * 3600 * 1000,
  /** Guaranteed something within this window of app uptime. */
  PITY_MS: 72 * 3600 * 1000,
  /** Per 5-min check: expected ~one spectacle every 2 days of uptime. */
  TICK_CHANCE: 0.0017,
  /** Same spectacle won't repeat within a week. */
  TYPE_COOLDOWN_MS: 7 * 24 * 3600 * 1000,
  CHECK_INTERVAL_MS: 5 * 60 * 1000,
} as const;

const RANDOM_TABLE: Array<{ type: SpectacleType; weight: number }> = [
  { type: "wolf", weight: 3 },
  { type: "ufo", weight: 2 },
  { type: "merchant", weight: 2 },
  { type: "balloon", weight: 2 },
  { type: "shearing", weight: 1 },
];

export function pickRandomSpectacle(input: SchedulerInput): SpectacleType | null {
  const { state, nowMs, isNight, rand } = input;
  if (isNight) return null;
  if (nowMs - state.lastFiredMs < SPECTACLE.MIN_GAP_MS) return null;

  const pityDue = nowMs - state.lastFiredMs >= SPECTACLE.PITY_MS;
  if (!pityDue && rand >= SPECTACLE.TICK_CHANCE) return null;

  // The gate consumed rand's magnitude: on the non-pity path only
  // rand < TICK_CHANCE survives, so rescale it back to [0,1) or the
  // weighted walk below would always land on the first entry.
  const pickRand = pityDue ? rand : rand / SPECTACLE.TICK_CHANCE;

  const eligible = RANDOM_TABLE.filter(({ type }) => {
    const last = state.lastByType[type];
    return last === undefined || nowMs - last >= SPECTACLE.TYPE_COOLDOWN_MS;
  });
  if (eligible.length === 0) return null;

  const totalWeight = eligible.reduce((s, e) => s + e.weight, 0);
  let roll = pickRand * totalWeight;
  for (const e of eligible) {
    roll -= e.weight;
    if (roll < 0) return e.type;
  }
  return eligible[eligible.length - 1].type;
}

export function markFired(
  state: SpectacleSchedulerState,
  type: SpectacleType,
  nowMs: number,
): SpectacleSchedulerState {
  return {
    lastFiredMs: nowMs,
    lastByType: { ...state.lastByType, [type]: nowMs },
  };
}

/**
 * Simulation-driven relationship drama. Pure logic: state in, transitions out.
 * The AI never owns this state — it only narrates what these rules decide.
 *
 * State graph:  neutral <-> warm -> inseparable
 *               neutral <-> tension -> feud -> reconciling -> warm
 */

export type RelationshipState =
  | "neutral"
  | "warm"
  | "inseparable"
  | "tension"
  | "feud"
  | "reconciling";

export interface PairInput {
  idA: string;
  idB: string;
  /** Symmetric affinity: average of both directions' scores. */
  affinity: number;
  moodA: string;
  moodB: string;
  state: RelationshipState;
  msInState: number;
  /** |petsA - petsB| today — fuel for jealousy. */
  pettingGap: number;
  /** Random [0,1) injected by the caller so tests are deterministic. */
  spark: number;
}

export interface DramaTransition {
  idA: string;
  idB: string;
  from: RelationshipState;
  to: RelationshipState;
  cause: string;
}

/** Tuning constants — thresholds are hysteresis pairs (enter > exit). */
export const DRAMA = {
  WARM_ENTER: 8,
  WARM_EXIT: 5,
  INSEP_ENTER: 15,
  INSEP_EXIT: 10,
  INSEP_DWELL_MS: 24 * 3600 * 1000,
  TENSION_ENTER: -3,
  TENSION_EXIT: 1,
  JEALOUSY_GAP: 5,
  FEUD_DWELL_MS: 12 * 3600 * 1000,
  FEUD_SPARK: 0.005,
  FEUD_TIREOUT_MS: 48 * 3600 * 1000,
  RECONCILE_MS: 10 * 60 * 1000,
  /** No pair may transition twice within this window (anti-flap). */
  MIN_DWELL_MS: 30 * 60 * 1000,
} as const;

export function pairKey(a: string, b: string): string {
  return a < b ? `${a}|${b}` : `${b}|${a}`;
}

/** Drop every pair record involving a departed character. Ids never come
 * back (they're timestamped), so their pairs would otherwise live in
 * drama.json forever. */
export function pruneCharacterFromPairs<T>(
  pairs: Record<string, T>,
  id: string,
): Record<string, T> {
  const out: Record<string, T> = {};
  for (const [key, rec] of Object.entries(pairs)) {
    const [a, b] = key.split("|");
    if (a !== id && b !== id) out[key] = rec;
  }
  return out;
}

export function blocksGroupActivity(state: RelationshipState): boolean {
  return state === "feud";
}

export function evaluatePair(p: PairInput): DramaTransition | null {
  const t = (to: RelationshipState, cause: string): DramaTransition => ({
    idA: p.idA,
    idB: p.idB,
    from: p.state,
    to,
    cause,
  });

  switch (p.state) {
    case "neutral":
      if (p.msInState < DRAMA.MIN_DWELL_MS) return null;
      if (p.pettingGap >= DRAMA.JEALOUSY_GAP) return t("tension", "jealousy");
      if (p.affinity >= DRAMA.WARM_ENTER) return t("warm", "growing affinity");
      if (p.affinity <= DRAMA.TENSION_ENTER) return t("tension", "low affinity");
      return null;

    case "warm":
      if (p.msInState < DRAMA.MIN_DWELL_MS) return null;
      if (p.affinity < DRAMA.WARM_EXIT) return t("neutral", "drifted apart");
      if (p.affinity >= DRAMA.INSEP_ENTER && p.msInState >= DRAMA.INSEP_DWELL_MS)
        return t("inseparable", "best friends now");
      return null;

    case "inseparable":
      if (p.msInState < DRAMA.MIN_DWELL_MS) return null;
      if (p.affinity < DRAMA.INSEP_EXIT) return t("warm", "cooled slightly");
      return null;

    case "tension":
      if (p.msInState < DRAMA.MIN_DWELL_MS) return null;
      if (p.affinity >= DRAMA.TENSION_EXIT && p.pettingGap < DRAMA.JEALOUSY_GAP)
        return t("neutral", "cooled off");
      if (p.spark < DRAMA.FEUD_SPARK) return t("feud", "spark");
      if (
        p.msInState >= DRAMA.FEUD_DWELL_MS &&
        (p.moodA === "grumpy" || p.moodB === "grumpy")
      )
        return t("feud", "grudge");
      return null;

    case "feud":
      if (p.msInState >= DRAMA.FEUD_TIREOUT_MS) return t("reconciling", "tired of fighting");
      return null;

    case "reconciling":
      if (p.msInState >= DRAMA.RECONCILE_MS) return t("warm", "made up");
      return null;
  }
}

export function evaluateDrama(pairs: PairInput[]): DramaTransition[] {
  const out: DramaTransition[] = [];
  for (const p of pairs) {
    const t = evaluatePair(p);
    if (t) out.push(t);
  }
  return out;
}

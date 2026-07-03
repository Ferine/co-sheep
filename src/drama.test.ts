import { describe, it, expect } from "vitest";
import {
  DRAMA,
  PairInput,
  evaluatePair,
  evaluateDrama,
  pairKey,
  blocksGroupActivity,
  pruneCharacterFromPairs,
} from "./drama";

function pair(overrides: Partial<PairInput>): PairInput {
  return {
    idA: "friend_a",
    idB: "friend_b",
    affinity: 0,
    moodA: "happy",
    moodB: "happy",
    state: "neutral",
    msInState: DRAMA.MIN_DWELL_MS + 1,
    pettingGap: 0,
    spark: 0.99, // never fires random spark unless a test lowers it
    ...overrides,
  };
}

describe("pairKey", () => {
  it("is order-independent", () => {
    expect(pairKey("b", "a")).toBe("a|b");
    expect(pairKey("a", "b")).toBe("a|b");
  });
});

describe("evaluatePair transitions", () => {
  it("neutral -> warm on high affinity", () => {
    const t = evaluatePair(pair({ affinity: DRAMA.WARM_ENTER }));
    expect(t).toMatchObject({ from: "neutral", to: "warm" });
  });

  it("neutral -> tension on low affinity", () => {
    const t = evaluatePair(pair({ affinity: DRAMA.TENSION_ENTER }));
    expect(t).toMatchObject({ from: "neutral", to: "tension" });
  });

  it("neutral -> tension on jealousy (petting gap)", () => {
    const t = evaluatePair(pair({ affinity: 2, pettingGap: DRAMA.JEALOUSY_GAP }));
    expect(t).toMatchObject({ from: "neutral", to: "tension", cause: "jealousy" });
  });

  it("respects minimum dwell time (no flapping)", () => {
    const t = evaluatePair(pair({ affinity: DRAMA.WARM_ENTER, msInState: 1000 }));
    expect(t).toBeNull();
  });

  it("warm -> inseparable needs affinity AND long dwell", () => {
    const notYet = evaluatePair(
      pair({ state: "warm", affinity: DRAMA.INSEP_ENTER, msInState: DRAMA.MIN_DWELL_MS + 1 }),
    );
    expect(notYet).toBeNull();
    const now = evaluatePair(
      pair({ state: "warm", affinity: DRAMA.INSEP_ENTER, msInState: DRAMA.INSEP_DWELL_MS + 1 }),
    );
    expect(now).toMatchObject({ from: "warm", to: "inseparable" });
  });

  it("warm -> neutral below exit threshold (hysteresis)", () => {
    const stays = evaluatePair(pair({ state: "warm", affinity: DRAMA.WARM_EXIT }));
    expect(stays).toBeNull();
    const cools = evaluatePair(pair({ state: "warm", affinity: DRAMA.WARM_EXIT - 1 }));
    expect(cools).toMatchObject({ from: "warm", to: "neutral" });
  });

  it("tension -> feud when a grump holds a grudge long enough", () => {
    const t = evaluatePair(
      pair({ state: "tension", affinity: -4, moodA: "grumpy", msInState: DRAMA.FEUD_DWELL_MS + 1 }),
    );
    expect(t).toMatchObject({ from: "tension", to: "feud" });
  });

  it("tension -> feud on random spark", () => {
    const t = evaluatePair(pair({ state: "tension", affinity: -4, spark: 0 }));
    expect(t).toMatchObject({ from: "tension", to: "feud", cause: "spark" });
  });

  it("tension -> neutral when cooled off", () => {
    const t = evaluatePair(pair({ state: "tension", affinity: DRAMA.TENSION_EXIT }));
    expect(t).toMatchObject({ from: "tension", to: "neutral" });
  });

  it("feud -> reconciling after tiring out", () => {
    const t = evaluatePair(
      pair({ state: "feud", affinity: -5, msInState: DRAMA.FEUD_TIREOUT_MS + 1 }),
    );
    expect(t).toMatchObject({ from: "feud", to: "reconciling" });
  });

  it("reconciling -> warm quickly", () => {
    const t = evaluatePair(
      pair({ state: "reconciling", affinity: 0, msInState: DRAMA.RECONCILE_MS + 1 }),
    );
    expect(t).toMatchObject({ from: "reconciling", to: "warm" });
  });
});

describe("evaluateDrama", () => {
  it("returns only pairs that transition", () => {
    const out = evaluateDrama([
      pair({ affinity: DRAMA.WARM_ENTER }),
      pair({ idA: "x", idB: "y", affinity: 0 }),
    ]);
    expect(out).toHaveLength(1);
    expect(out[0].to).toBe("warm");
  });
});

describe("blocksGroupActivity", () => {
  it("only feud blocks", () => {
    expect(blocksGroupActivity("feud")).toBe(true);
    expect(blocksGroupActivity("tension")).toBe(false);
    expect(blocksGroupActivity("warm")).toBe(false);
  });
});

describe("pruneCharacterFromPairs", () => {
  const pairs = {
    [pairKey("main", "friend_1")]: { state: "feud", since: 100 },
    [pairKey("friend_1", "friend_2")]: { state: "warm", since: 200 },
    [pairKey("main", "friend_2")]: { state: "neutral", since: 300 },
  };

  it("removes every pair involving the departed character", () => {
    const out = pruneCharacterFromPairs(pairs, "friend_1");
    expect(Object.keys(out)).toEqual([pairKey("main", "friend_2")]);
    expect(out[pairKey("main", "friend_2")]).toEqual({ state: "neutral", since: 300 });
  });

  it("returns pairs unchanged for an unknown id", () => {
    expect(pruneCharacterFromPairs(pairs, "friend_99")).toEqual(pairs);
  });

  it("does not prune on partial id matches", () => {
    const p = { [pairKey("friend_1", "friend_12")]: { state: "warm", since: 1 } };
    expect(pruneCharacterFromPairs(p, "friend_1")).toEqual({});
    expect(pruneCharacterFromPairs(p, "friend_12")).toEqual({});
    expect(Object.keys(pruneCharacterFromPairs(p, "friend_"))).toHaveLength(1);
  });
});

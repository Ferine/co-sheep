import { describe, it, expect } from "vitest";
import {
  SPECTACLE,
  SpectacleSchedulerState,
  markFired,
  pickRandomSpectacle,
} from "./spectacles";

const DAY = 24 * 3600 * 1000;

function fresh(): SpectacleSchedulerState {
  return { lastFiredMs: 0, lastByType: {} };
}

describe("pickRandomSpectacle", () => {
  it("never fires within MIN_GAP of the last spectacle", () => {
    const state = { ...fresh(), lastFiredMs: 100 * DAY };
    const picked = pickRandomSpectacle({
      state,
      nowMs: 100 * DAY + SPECTACLE.MIN_GAP_MS - 1,
      isNight: false,
      rand: 0, // would otherwise always fire
    });
    expect(picked).toBeNull();
  });

  it("never fires at night", () => {
    const picked = pickRandomSpectacle({
      state: fresh(),
      nowMs: 100 * DAY,
      isNight: true,
      rand: 0,
    });
    expect(picked).toBeNull();
  });

  it("fires on a lucky roll after the gap", () => {
    const picked = pickRandomSpectacle({
      state: { ...fresh(), lastFiredMs: 100 * DAY },
      nowMs: 100 * DAY + SPECTACLE.MIN_GAP_MS + 1,
      isNight: false,
      rand: 0,
    });
    expect(picked).not.toBeNull();
  });

  it("does not fire on an unlucky roll before the pity timer", () => {
    const picked = pickRandomSpectacle({
      state: { ...fresh(), lastFiredMs: 100 * DAY },
      nowMs: 100 * DAY + SPECTACLE.MIN_GAP_MS + 1,
      isNight: false,
      rand: 0.99,
    });
    expect(picked).toBeNull();
  });

  it("pity timer forces a spectacle even on an unlucky roll", () => {
    const picked = pickRandomSpectacle({
      state: { ...fresh(), lastFiredMs: 100 * DAY },
      nowMs: 100 * DAY + SPECTACLE.PITY_MS + 1,
      isNight: false,
      rand: 0.99,
    });
    expect(picked).not.toBeNull();
  });

  it("respects the per-type cooldown", () => {
    // Exhaust every type's cooldown except one; the pick must be that one.
    const nowMs = 100 * DAY;
    let state = fresh();
    state = markFired(state, "wolf", nowMs - 1);
    state = markFired(state, "ufo", nowMs - 1);
    state = markFired(state, "merchant", nowMs - 1);
    state = markFired(state, "shearing", nowMs - 1);
    state = { ...state, lastFiredMs: nowMs - SPECTACLE.MIN_GAP_MS - 1 };
    const picked = pickRandomSpectacle({ state, nowMs, isNight: false, rand: 0 });
    expect(picked).toBe("balloon");
  });

  it("returns null when every type is cooling down", () => {
    const nowMs = 100 * DAY;
    let state = fresh();
    for (const t of ["wolf", "ufo", "merchant", "balloon", "shearing"] as const) {
      state = markFired(state, t, nowMs - 1);
    }
    state = { ...state, lastFiredMs: nowMs - SPECTACLE.PITY_MS - 1 };
    expect(pickRandomSpectacle({ state, nowMs, isNight: false, rand: 0 })).toBeNull();
  });
});

describe("markFired", () => {
  it("stamps both the global and per-type clocks", () => {
    const s = markFired(fresh(), "wolf", 123);
    expect(s.lastFiredMs).toBe(123);
    expect(s.lastByType.wolf).toBe(123);
  });
});

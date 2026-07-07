import { describe, it, expect } from "vitest";
import { pickReaction } from "./mcp-companion";
import { SessionEvent } from "./types";

const ev = (o: Partial<SessionEvent>): SessionEvent => ({
  kind: "milestone", task: null, progress: null,
  milestone: null, detail: null, health: "good", ...o,
});

const first = () => 0; // deterministic: always the first pool entry

describe("pickReaction", () => {
  it("failed milestone -> headshake + a snarky failure line", () => {
    const r = pickReaction(ev({ milestone: "failed", health: "failing" }), first);
    expect(r.animation).toBe("headshake");
    expect(r.text.length).toBeGreaterThan(0);
  });

  it("done milestone -> bounce", () => {
    const r = pickReaction(ev({ milestone: "done", health: "good" }), first);
    expect(r.animation).toBe("bounce");
  });

  it("blocked milestone -> vibrate", () => {
    const r = pickReaction(ev({ milestone: "blocked", health: "degraded" }), first);
    expect(r.animation).toBe("vibrate");
  });

  it("begin -> a greeting line, no crash", () => {
    const r = pickReaction(ev({ kind: "begin", milestone: null }), first);
    expect(r.text.length).toBeGreaterThan(0);
  });

  it("high progress announces near-done", () => {
    const r = pickReaction(ev({ kind: "progress", progress: 0.95, milestone: null }), first);
    expect(r.text.length).toBeGreaterThan(0);
  });

  it("rng selects within the pool deterministically", () => {
    const a = pickReaction(ev({ milestone: "failed" }), () => 0);
    const b = pickReaction(ev({ milestone: "failed" }), () => 0.999);
    expect(a.text).not.toBe(b.text); // different indices → different lines
  });
});

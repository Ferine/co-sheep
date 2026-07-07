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

  it("milestone with detail appends it to the line", () => {
    const r = pickReaction(
      ev({ milestone: "failed", detail: "3 tests failed" }),
      first,
    );
    expect(r.text).toContain("3 tests failed");
  });

  it("milestone with null detail behaves exactly as before (no parenthetical)", () => {
    const r = pickReaction(ev({ milestone: "done", detail: null }), first);
    expect(r.text).not.toContain("(");
  });

  it("milestone with empty-string detail behaves exactly as before (no parenthetical)", () => {
    const r = pickReaction(ev({ milestone: "blocked", detail: "" }), first);
    expect(r.text).not.toContain("(");
  });

  it("set_task with a task label includes the label", () => {
    const r = pickReaction(
      ev({ kind: "task", milestone: null, task: "wire LDP" }),
      first,
    );
    expect(r.text).toContain("wire LDP");
    expect(r.animation).toBeNull();
  });

  it("set_task with null task falls back to a generic non-empty line", () => {
    const r = pickReaction(ev({ kind: "task", milestone: null, task: null }), first);
    expect(r.text.length).toBeGreaterThan(0);
    expect(r.animation).toBeNull();
  });

  it("set_task label selection is deterministic via rng and varies across values", () => {
    const a = pickReaction(
      ev({ kind: "task", milestone: null, task: "wire LDP" }),
      () => 0,
    );
    const b = pickReaction(
      ev({ kind: "task", milestone: null, task: "wire LDP" }),
      () => 0.999,
    );
    expect(a.text).toContain("wire LDP");
    expect(b.text).toContain("wire LDP");
    expect(a.text).not.toBe(b.text);
  });

  it("waiting_on_you milestone -> vibrate", () => {
    const r = pickReaction(ev({ milestone: "waiting_on_you" }), first);
    expect(r.animation).toBe("vibrate");
  });

  it("end -> animation null", () => {
    const r = pickReaction(ev({ kind: "end", milestone: null }), first);
    expect(r.animation).toBeNull();
    expect(r.text.length).toBeGreaterThan(0);
  });

  it("low/mid progress -> non-empty text, animation null", () => {
    const r = pickReaction(
      ev({ kind: "progress", progress: 0.3, milestone: null }),
      first,
    );
    expect(r.text.length).toBeGreaterThan(0);
    expect(r.animation).toBeNull();
  });

  it("unknown milestone value falls through without throwing", () => {
    expect(() =>
      pickReaction(ev({ milestone: "weird" as SessionEvent["milestone"] }), first),
    ).not.toThrow();
    const r = pickReaction(ev({ milestone: "weird" as SessionEvent["milestone"] }), first);
    expect(r.text.length).toBeGreaterThan(0);
  });
});

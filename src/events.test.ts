import { describe, it, expect, vi } from "vitest";
import { bus } from "./events";

describe("flock event bus", () => {
  it("delivers payload to subscriber", () => {
    const seen: string[] = [];
    const off = bus.on("sheep-petted", (p) => seen.push(p.id));
    bus.emit("sheep-petted", { id: "good_colleague" });
    off();
    expect(seen).toEqual(["good_colleague"]);
  });

  it("unsubscribe stops delivery", () => {
    const handler = vi.fn();
    const off = bus.on("sheep-petted", handler);
    off();
    bus.emit("sheep-petted", { id: "main" });
    expect(handler).not.toHaveBeenCalled();
  });

  it("a throwing handler does not break other handlers", () => {
    const seen: string[] = [];
    const offA = bus.on("app-switched", () => {
      throw new Error("boom");
    });
    const offB = bus.on("app-switched", (p) => seen.push(p.app));
    bus.emit("app-switched", { app: "Xcode", previousApp: null, previousDurationMs: 0 });
    offA();
    offB();
    expect(seen).toEqual(["Xcode"]);
  });
});

import { describe, it, expect } from "vitest";
import { categorizeApp } from "./gossip";

describe("categorizeApp", () => {
  it("exact matches win across categories", () => {
    expect(categorizeApp("Webex")).toBe("meetings");
    expect(categorizeApp("X")).toBe("social");
    expect(categorizeApp("Music")).toBe("music");
  });
  it("substring matching requires length >= 4 names", () => {
    expect(categorizeApp("Final Cut Pro X")).toBe("other");
    expect(categorizeApp("Microsoft Excel")).toBe("other");
    expect(categorizeApp("Google Chrome Beta")).toBe("browser");
    expect(categorizeApp("Gmail")).toBe("mail");
  });
  it("unknown apps fall to other", () => {
    expect(categorizeApp("Blender")).toBe("other");
  });
});

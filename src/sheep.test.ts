import { describe, it, expect, vi } from "vitest";

// SpriteSheet needs a DOM Image; stub it for the node test environment
vi.stubGlobal(
  "Image",
  class {
    onload: (() => void) | null = null;
    onerror: (() => void) | null = null;
    src = "";
    complete = false;
    naturalWidth = 0;
    addEventListener() {}
  },
);

import { Sheep } from "./sheep";

/** Run the update loop until the parachute descent settles */
function settle(sheep: Sheep) {
  for (let i = 0; i < 5000 && sheep.state === "parachute"; i++) {
    sheep.update(16);
  }
}

describe("parachute landing on window platforms", () => {
  it("skips platforms that would place the sheep above the screen top", () => {
    const sheep = new Sheep(1512, 982);
    // Maximized window: top edge just below the macOS menu bar
    sheep.platforms = [{ x: 0, y: 25, w: 1512, h: 957 }];

    settle(sheep);

    expect(sheep.state).toBe("idle");
    expect(sheep.y).toBeGreaterThanOrEqual(0);
    expect(sheep.currentPlatform).toBeNull();
  });

  it("still lands on platforms low enough to stand on", () => {
    const sheep = new Sheep(1512, 982);
    sheep.platforms = [{ x: 400, y: 400, w: 700, h: 500 }];

    settle(sheep);

    expect(sheep.state).toBe("idle");
    expect(sheep.y).toBe(400 - sheep.displaySize);
    expect(sheep.currentPlatform).not.toBeNull();
  });
});

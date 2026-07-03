import { describe, expect, it } from "vitest";
import { capTranscript, ChatTurn } from "./chat-transcript";

function turn(role: "human" | "sheep", text: string): ChatTurn {
  return { role, text };
}

describe("capTranscript", () => {
  it("returns empty for empty history", () => {
    expect(capTranscript([])).toEqual([]);
  });

  it("keeps short histories unchanged", () => {
    const turns = [turn("human", "hei"), turn("sheep", "bæ")];
    expect(capTranscript(turns)).toEqual(turns);
  });

  it("caps to the last 8 turns", () => {
    const turns = Array.from({ length: 12 }, (_, i) =>
      turn(i % 2 === 0 ? "human" : "sheep", `msg ${i}`),
    );
    const capped = capTranscript(turns);
    expect(capped).toHaveLength(8);
    expect(capped[0].text).toBe("msg 4");
    expect(capped[7].text).toBe("msg 11");
  });

  it("drops oldest turns to stay under the char budget", () => {
    const big = "x".repeat(700);
    const turns = [
      turn("human", big),
      turn("sheep", big),
      turn("human", big),
    ];
    const capped = capTranscript(turns);
    expect(capped).toHaveLength(2);
    expect(capped[0].role).toBe("sheep");
  });

  it("always keeps the newest turn even if it alone busts the budget", () => {
    const turns = [turn("human", "x".repeat(9000))];
    expect(capTranscript(turns)).toHaveLength(1);
  });
});

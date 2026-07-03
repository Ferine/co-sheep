/** One exchange line in a chat session with the main sheep. */
export interface ChatTurn {
  role: "human" | "sheep";
  text: string;
}

const MAX_TURNS = 8;
const CHAR_BUDGET = 1500;

/**
 * Cap a chat transcript for the on-device model's small context window:
 * last MAX_TURNS turns, dropping the oldest until the total text fits
 * CHAR_BUDGET. The newest turn is always kept.
 */
export function capTranscript(turns: ChatTurn[]): ChatTurn[] {
  const recent = turns.slice(-MAX_TURNS);
  const kept: ChatTurn[] = [];
  let total = 0;
  for (let i = recent.length - 1; i >= 0; i--) {
    total += recent[i].text.length;
    if (total > CHAR_BUDGET && kept.length > 0) break;
    kept.unshift(recent[i]);
  }
  return kept;
}

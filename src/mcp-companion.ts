import { listen } from "@tauri-apps/api/event";
import { Flock } from "./flock";
import { SessionEvent, SheepAnimation } from "./types";

// Static tsundere pools — deterministic, testable. One consistent voice.
const POOLS = {
  clock_in: [
    "Oh. We're working now, are we?",
    "Tch. Fine. I was watching anyway.",
    "Back at it. Don't expect applause.",
  ],
  new_task: [
    "This again? Predictable.",
    "Hm. Watching you wrestle with this.",
    "Go on then. I'm observing.",
  ],
  new_task_labeled: [
    (label: string) => `Watching you wrestle with "${label}" again, hm?`,
    (label: string) => `"${label}". Predictable choice.`,
    (label: string) => `So it's "${label}" today. Riveting.`,
  ],
  progress_mid: [
    "Halfway. Don't get comfortable.",
    "Still going. Barely.",
    "Adequate pace. For you.",
  ],
  progress_high: [
    "Almost there. I counted.",
    "Nearly done. Try not to break it now.",
    "So close. Don't fumble it.",
  ],
  done: [
    "...Fine. That worked. Don't read into it.",
    "Hmph. Not terrible. For a human.",
    "It's done. I'm as surprised as you.",
  ],
  failed: [
    "Tch. Predictable.",
    "Saw that coming three commits ago.",
    "That's the third time. I'm keeping count.",
  ],
  blocked: [
    "Your move, sorcerer.",
    "Stuck? Obviously.",
    "I'll wait. Not that I mind.",
  ],
  waiting: [
    "*taps foot* Any day now.",
    "Waiting on you. As usual.",
    "Well? I'm right here.",
  ],
  clock_out: [
    "Done already? Hmph.",
    "Off you go. I'll be here.",
    "That's a wrap. Don't miss me.",
  ],
} as const;

function pick<T>(pool: readonly T[], rng: () => number): T {
  return pool[Math.min(pool.length - 1, Math.floor(rng() * pool.length))];
}

function withDetail(text: string, detail: string | null): string {
  return detail ? `${text} (${detail})` : text;
}

export function pickReaction(
  ev: SessionEvent,
  rng: () => number = Math.random,
): { text: string; animation: SheepAnimation | null } {
  if (ev.kind === "milestone") {
    switch (ev.milestone) {
      case "failed":
        return { text: withDetail(pick(POOLS.failed, rng), ev.detail), animation: "headshake" };
      case "done":
        return { text: withDetail(pick(POOLS.done, rng), ev.detail), animation: "bounce" };
      case "blocked":
        return { text: withDetail(pick(POOLS.blocked, rng), ev.detail), animation: "vibrate" };
      case "waiting_on_you":
        return { text: withDetail(pick(POOLS.waiting, rng), ev.detail), animation: "vibrate" };
    }
  }
  if (ev.kind === "begin") return { text: pick(POOLS.clock_in, rng), animation: "bounce" };
  if (ev.kind === "end") return { text: pick(POOLS.clock_out, rng), animation: null };
  if (ev.kind === "task") {
    if (ev.task) {
      return { text: pick(POOLS.new_task_labeled, rng)(ev.task), animation: null };
    }
    return { text: pick(POOLS.new_task, rng), animation: null };
  }
  if (ev.kind === "progress") {
    const p = ev.progress ?? 0;
    return { text: pick(p >= 0.9 ? POOLS.progress_high : POOLS.progress_mid, rng), animation: null };
  }
  return { text: pick(POOLS.new_task, rng), animation: null };
}

/** Listens for backend `sheep-session` facts and renders them through the flock. */
export class McpCompanion {
  private unlisten: (() => void) | null = null;

  constructor(private flock: Flock) {}

  start() {
    listen<SessionEvent>("sheep-session", (event) => {
      try {
        const { text, animation } = pickReaction(event.payload);
        this.flock.mainBubble.show(text, 6000);
        this.flock.onChatReply(animation); // animates main sheep + friend reactions
      } catch (e) {
        console.error("[co-sheep] mcp-companion render failed:", e);
      }
    }).then((fn) => {
      this.unlisten = fn;
    });
  }

  stop() {
    if (this.unlisten) {
      this.unlisten();
      this.unlisten = null;
    }
  }
}

import { invoke } from "@tauri-apps/api/core";
import { Flock } from "./flock";
import { bus } from "./events";
import { ConversationScript } from "./types";

export type AppCategory =
  | "dev" | "terminal" | "social" | "browser" | "meetings"
  | "music" | "mail" | "notes" | "other";

const CATEGORY_APPS: Record<Exclude<AppCategory, "other">, string[]> = {
  dev: ["Code", "Visual Studio Code", "Xcode", "IntelliJ IDEA", "WebStorm", "Zed", "Cursor", "Sublime Text"],
  terminal: ["Terminal", "iTerm2", "Warp", "Ghostty", "kitty", "Alacritty"],
  social: ["Twitter", "X", "Discord", "Slack", "Telegram", "Messages", "WhatsApp", "Signal"],
  browser: ["Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser", "Microsoft Edge"],
  meetings: ["zoom.us", "Microsoft Teams", "FaceTime", "Google Meet", "Webex"],
  music: ["Music", "Spotify", "Tidal"],
  mail: ["Mail", "Microsoft Outlook", "Superhuman", "Mimestream"],
  notes: ["Notes", "Obsidian", "Notion", "Bear"],
};

export function categorizeApp(appName: string): AppCategory {
  const lower = appName.toLowerCase();

  // Pass 1: exact match (case-insensitive) across ALL categories first.
  for (const [category, names] of Object.entries(CATEGORY_APPS)) {
    if (names.some((n) => lower === n.toLowerCase())) {
      return category as AppCategory;
    }
  }

  // Pass 2: substring match, but only for names with length >= 4 to avoid
  // short names (like "X") false-positive matching unrelated apps.
  for (const [category, names] of Object.entries(CATEGORY_APPS)) {
    if (names.some((n) => n.length >= 4 && lower.includes(n.toLowerCase()))) {
      return category as AppCategory;
    }
  }

  return "other";
}

/** Instant one-liners on switching INTO a category. Personality-neutral. */
const INSTANT_BITS: Record<AppCategory, string[]> = {
  dev: ["Ah, the code mines.", "Xcode again? Bold.", "*peers at the syntax*", "May the compiler be gentle."],
  terminal: ["Back to the green glow.", "*watches the cursor blink*", "Type faster. It's judging you. I'm judging you."],
  social: ["Ooh, are we procrastinating?", "Say hi from me.", "*leans in to read the drama*"],
  browser: ["Down the rabbit hole we go.", "How many tabs is that now?", "*pretends not to count the tabs*"],
  meetings: ["Say baa if you need rescuing.", "*sits very quietly*", "You're muted. Probably."],
  music: ["*bobs head*", "DJ human, volume up.", "Finally, some culture."],
  mail: ["Inbox zero is a myth.", "*watches you type 'per my last email'*"],
  notes: ["Writing things down. Growth.", "*peeks at the notes*"],
  other: ["What IS that app?", "*squints at the unfamiliar window*"],
};

/** Gossip templates about measured habits. $A/$B placeholders; {hours}/{app} filled. */
const GOSSIP_TEMPLATES: ConversationScript[] = [
  [
    { speakerId: "$A", text: "Hour {hours} in {app}.", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "Blink twice if you need help, human.", duration: 4000, delay: 700, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "{app}. Again. That's hour {hours}.", duration: 4000, delay: 0 },
    { speakerId: "$B", text: "We should stage an intervention.", duration: 3500, delay: 700 },
    { speakerId: "$A", text: "We ARE the intervention.", duration: 3000, delay: 600, animation: "bounce" },
  ],
  [
    { speakerId: "$A", text: "Psst. {hours} hours of {app} today.", duration: 4000, delay: 0 },
    { speakerId: "$B", text: "I heard. The whole flock heard.", duration: 3500, delay: 700, animation: "headshake" },
  ],
];

const CATEGORY_LABELS: Record<AppCategory, string> = {
  dev: "the editor", terminal: "the terminal", social: "the group chats",
  browser: "the browser", meetings: "meetings", music: "the music app",
  mail: "the inbox", notes: "the notes app", other: "that app",
};

const INSTANT_BIT_COOLDOWN_MS = 10 * 60 * 1000;
const GOSSIP_HOUR_MS = 3600 * 1000;

export class GossipManager {
  private categoryMsToday: Partial<Record<AppCategory, number>> = {};
  private gossipedHours: Partial<Record<AppCategory, number>> = {};
  private day = new Date().toISOString().slice(0, 10);
  private lastInstantBit = 0;
  private currentCategory: AppCategory | null = null;
  private lastCreditAt = Date.now();

  constructor(private flock: Flock) {}

  start(): void {
    bus.on("app-switched", ({ app }) => {
      this.rollDay();
      this.creditElapsed();

      const cat = categorizeApp(app);
      const isNewCategory = cat !== this.currentCategory;
      this.currentCategory = cat;

      if (isNewCategory) {
        // Daily tally (lands in opinions.json → feeds AI "Today's tallies").
        invoke("record_app_usage", { category: cat }).catch(() => {});
        this.maybeInstantBit(cat);
      }
      this.maybeGossip(cat);
    });

    setInterval(() => {
      this.rollDay();
      this.creditElapsed();
      if (this.currentCategory) this.maybeGossip(this.currentCategory);
    }, 5 * 60 * 1000);
  }

  /** Credit elapsed time since the last credit to the current category. */
  private creditElapsed(): void {
    const now = Date.now();
    if (this.currentCategory) {
      this.categoryMsToday[this.currentCategory] =
        (this.categoryMsToday[this.currentCategory] ?? 0) + (now - this.lastCreditAt);
    }
    this.lastCreditAt = now;
  }

  private rollDay(): void {
    const today = new Date().toISOString().slice(0, 10);
    if (today !== this.day) {
      this.day = today;
      this.categoryMsToday = {};
      this.gossipedHours = {};
    }
  }

  private maybeInstantBit(cat: AppCategory): void {
    const now = Date.now();
    if (now - this.lastInstantBit < INSTANT_BIT_COOLDOWN_MS) return;

    // A random calm friend delivers the bit.
    const candidates = this.flock
      .getCharacterIds()
      .filter((id) => id !== "main" && this.flock.isCharacterCalm(id));
    if (candidates.length === 0) return;
    const speaker = this.flock.getCharacter(candidates[Math.floor(Math.random() * candidates.length)]);
    if (!speaker || speaker.bubble.visible) return;

    const pool = INSTANT_BITS[cat];
    speaker.bubble.show(pool[Math.floor(Math.random() * pool.length)], 4000);
    this.lastInstantBit = now;
  }

  private maybeGossip(cat: AppCategory): void {
    const ms = this.categoryMsToday[cat] ?? 0;
    const hours = Math.floor(ms / GOSSIP_HOUR_MS);
    if (hours < 1) return;
    if ((this.gossipedHours[cat] ?? 0) >= hours) return; // one gossip per hour milestone

    const friends = this.flock
      .getCharacterIds()
      .filter((id) => id !== "main" && this.flock.isCharacterCalm(id));
    if (friends.length < 2) return;
    const i = Math.floor(Math.random() * friends.length);
    let j = Math.floor(Math.random() * (friends.length - 1));
    if (j >= i) j++;
    const a = friends[i];
    const b = friends[j];

    const appLabel = CATEGORY_LABELS[cat];
    const template = GOSSIP_TEMPLATES[Math.floor(Math.random() * GOSSIP_TEMPLATES.length)];
    const script: ConversationScript = template.map((line) => ({
      ...line,
      speakerId: line.speakerId === "$A" ? a : line.speakerId === "$B" ? b : line.speakerId,
      text: line.text.replace("{hours}", String(hours)).replace("{app}", appLabel),
    }));

    if (this.flock.startScriptedConversation(script, [a, b])) {
      this.gossipedHours[cat] = hours;
      // Gossip becomes a shared memory + affinity bump via the existing command.
      invoke("record_friend_conversation", {
        idA: a, idB: b,
        topic: `the human's ${hours}h of ${cat}`,
      }).catch(() => {});
    }
  }
}

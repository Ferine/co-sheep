// The in-page replacement for co-sheep's Rust backend (ex-src-tauri): settings,
// friends, friend brains (mood, affinity, memories), the diary, opinions and
// the living-state files. Everything persists in this browser's localStorage
// (per device), so it survives reloads but never leaves the machine.

import type { FriendConfig, FriendPersonality } from "legacy/types";

const NS = "co-sheep:";

export function load<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(NS + key);
    if (raw == null) return fallback;
    const parsed = JSON.parse(raw);
    return parsed ?? fallback;
  } catch {
    return fallback;
  }
}

export function save(key: string, value: unknown): void {
  try {
    localStorage.setItem(NS + key, JSON.stringify(value));
  } catch {
    // Storage blocked (private window, preview capture): run without it.
  }
}

// ─── Settings ───────────────────────────────────────────────────────────────

export type SeasonMode = "auto" | "on" | "off";

export interface Settings {
  name: string;
  personality: FriendPersonality;
  language: string;
  break_reminders: boolean;
  easter_mode: SeasonMode;
  summer_mode: SeasonMode;
  accessories: string[];
  /** Seconds between the main sheep's own remarks. */
  comment_interval_s: number;
  paused: boolean;
}

const DEFAULT_SETTINGS: Settings = {
  name: "Sheep",
  personality: "snarky",
  language: "English",
  break_reminders: true,
  easter_mode: "auto",
  summer_mode: "auto",
  accessories: [],
  comment_interval_s: 150,
  paused: false,
};

export const LANGUAGES = [
  "English", "Nynorsk", "Bokmål", "Swedish", "Danish",
  "German", "French", "Spanish", "Japanese", "Korean",
];

let settings: Settings = { ...DEFAULT_SETTINGS, ...load<Partial<Settings>>("settings", {}) };

export function getSettings(): Settings {
  return { ...settings, accessories: [...settings.accessories] };
}

export function updateSettings(patch: Partial<Settings>): Settings {
  settings = { ...settings, ...patch };
  save("settings", settings);
  return getSettings();
}

// ─── Friends ────────────────────────────────────────────────────────────────

let friends: FriendConfig[] = load<FriendConfig[]>("friends", []);

export function getFriends(): FriendConfig[] {
  return friends.map((f) => ({ ...f, accessories: [...(f.accessories ?? [])] }));
}

export function saveFriend(config: FriendConfig): void {
  const i = friends.findIndex((f) => f.id === config.id);
  if (i >= 0) friends[i] = config;
  else friends.push(config);
  save("friends", friends);
  ensureBrain(config.id, config.name);
}

export function deleteFriend(id: string): void {
  friends = friends.filter((f) => f.id !== id);
  save("friends", friends);
  delete brains[id];
  for (const brain of Object.values(brains)) delete brain.relationships[id];
  saveBrains();
}

// ─── Friend brains (ex-friend_memory.rs) ────────────────────────────────────

export interface Memory {
  at: string;
  text: string;
}

export interface Brain {
  name: string;
  mood: string;
  mood_since: number;
  relationships: Record<string, number>;
  memories: Memory[];
  stats: {
    conversations_today: number;
    conversations_total: number;
    times_petted: number;
    group_activities: number;
    days_alive: number;
  };
  last_decay_date: string;
}

const brains: Record<string, Brain> = load<Record<string, Brain>>("brains", {});

/** Resolves an id to the name on screen; installed by the shell. */
export let nameOf: (id: string) => string = (id) => id;
export function setNameResolver(fn: (id: string) => string): void {
  nameOf = fn;
}

function localDay(d = new Date()): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function saveBrains(): void {
  save("brains", brains);
}

function ensureBrain(id: string, name?: string): Brain | null {
  if (id === "main") return null; // the main sheep keeps opinions, not a friend brain
  let brain = brains[id];
  if (!brain) {
    brain = {
      name: name ?? nameOf(id),
      mood: id === "good_colleague" ? "grumpy" : "happy",
      mood_since: Date.now(),
      relationships: {},
      memories: [],
      stats: {
        conversations_today: 0,
        conversations_total: 0,
        times_petted: 0,
        group_activities: 0,
        days_alive: 1,
      },
      last_decay_date: localDay(),
    };
    brains[id] = brain;
  }
  if (name) brain.name = name;
  return brain;
}

function remember(brain: Brain, text: string): void {
  brain.memories.push({ at: new Date().toISOString(), text });
  if (brain.memories.length > 20) brain.memories.splice(0, brain.memories.length - 20);
}

function setMood(brain: Brain, mood: string): void {
  if (brain.mood !== mood) {
    brain.mood = mood;
    brain.mood_since = Date.now();
  }
}

function bumpAffinity(a: string, b: string, by: number): void {
  const brain = ensureBrain(a);
  if (!brain) return;
  brain.relationships[b] = Math.min(20, (brain.relationships[b] ?? 0) + by);
}

/** Once a day: affinities fade by one, daily counts reset, everyone ages. */
function decayIfNewDay(): void {
  const today = localDay();
  let changed = false;
  for (const brain of Object.values(brains)) {
    if (brain.last_decay_date === today) continue;
    brain.last_decay_date = today;
    brain.stats.conversations_today = 0;
    brain.stats.days_alive += 1;
    for (const [other, v] of Object.entries(brain.relationships)) {
      brain.relationships[other] = v > 0 ? v - 1 : Math.max(-5, v);
    }
    changed = true;
  }
  if (changed) saveBrains();
}

/** Moods drift: everyone gets sleepy at night, Good Colleague drifts back to
 * grumpy, and a long-ignored friend may sour. */
function currentMood(id: string, brain: Brain): string {
  const h = new Date().getHours();
  if (h >= 23 || h < 6) return "sleepy";
  const age = Date.now() - brain.mood_since;
  if (id === "good_colleague" && brain.mood !== "grumpy" && age > 30 * 60_000) {
    setMood(brain, "grumpy");
    saveBrains();
  } else if (brain.mood === "excited" && age > 15 * 60_000) {
    setMood(brain, "happy");
    saveBrains();
  } else if (brain.mood === "happy" && age > 60 * 60_000 && Math.random() < 0.25) {
    setMood(brain, "grumpy");
    saveBrains();
  }
  return brain.mood;
}

export function getBrains(): Record<string, Brain> {
  decayIfNewDay();
  return JSON.parse(JSON.stringify(brains));
}

export function moodOf(id: string): string | null {
  const brain = brains[id];
  return brain ? currentMood(id, brain) : null;
}

// ─── Diary, tallies and opinions (ex-memory.rs) ─────────────────────────────

let journal: Memory[] = load<Memory[]>("journal", []);
let tallies: { day: string; counts: Record<string, number> } = load("tallies", { day: localDay(), counts: {} });

export interface Opinion {
  text: string;
  category: string;
  times_seen: number;
  updated: string;
}
let opinions: Record<string, Opinion> = load("opinions", {});

export function writeDiary(text: string): void {
  text = text.charAt(0).toUpperCase() + text.slice(1);
  journal.push({ at: new Date().toISOString(), text });
  if (journal.length > 80) journal.splice(0, journal.length - 80);
  save("journal", journal);
}

export function getDiary(): Memory[] {
  return [...journal];
}

export function countToday(key: string): number {
  if (tallies.day !== localDay()) tallies = { day: localDay(), counts: {} };
  tallies.counts[key] = (tallies.counts[key] ?? 0) + 1;
  save("tallies", tallies);
  return tallies.counts[key];
}

export function getTallies(): Record<string, number> {
  return tallies.day === localDay() ? { ...tallies.counts } : {};
}

export function saveOpinion(topic: string, text: string, category: string): void {
  const key = topic.toLowerCase().replace(/[^a-z0-9_]+/g, "_").slice(0, 40);
  if (!key) return;
  const prev = opinions[key];
  opinions[key] = {
    text: text.slice(0, 200),
    category: category || "opinion",
    times_seen: (prev?.times_seen ?? 0) + 1,
    updated: new Date().toISOString(),
  };
  save("opinions", opinions);
}

export function getOpinions(): Record<string, Opinion> {
  return JSON.parse(JSON.stringify(opinions));
}

export function forgetEverything(): void {
  journal = [];
  opinions = {};
  tallies = { day: localDay(), counts: {} };
  for (const id of Object.keys(brains)) delete brains[id];
  save("journal", journal);
  save("opinions", opinions);
  save("tallies", tallies);
  saveBrains();
}

// ─── Easter stats (ex-easter_memory.rs, simplified) ─────────────────────────

interface EasterStats {
  last_reset_date: string;
  last_hunt_date: string;
  eggs_found_total: number;
  eggs_found_today: number;
  golden_eggs_total: number;
  golden_eggs_today: number;
  hunts_completed: number;
  hunts_today: number;
  current_streak: number;
  best_streak: number;
  painted_eggs_used_total: number;
  flock_score: number;
  top_hunter_name?: string;
  last_winner_name?: string;
  hunter_totals: Record<string, number>;
}

function easterStats(): EasterStats {
  const s = load<EasterStats>("easter", {
    last_reset_date: localDay(), last_hunt_date: "",
    eggs_found_total: 0, eggs_found_today: 0, golden_eggs_total: 0, golden_eggs_today: 0,
    hunts_completed: 0, hunts_today: 0, current_streak: 0, best_streak: 0,
    painted_eggs_used_total: 0, flock_score: 0, hunter_totals: {},
  });
  if (s.last_reset_date !== localDay()) {
    s.last_reset_date = localDay();
    s.eggs_found_today = 0;
    s.golden_eggs_today = 0;
    s.hunts_today = 0;
  }
  return s;
}

interface HuntResult {
  totalEggs: number;
  allCollected: boolean;
  paintedEggsUsed: number;
  hunters: Array<{ id: string; name: string; eggsFound: number; goldenEggsFound: number }>;
}

function recordHunt(result: HuntResult): EasterStats {
  const s = easterStats();
  const today = localDay();
  const yesterday = localDay(new Date(Date.now() - 86_400_000));
  if (s.last_hunt_date !== today) {
    s.current_streak = s.last_hunt_date === yesterday ? s.current_streak + 1 : 1;
    s.best_streak = Math.max(s.best_streak, s.current_streak);
  }
  s.last_hunt_date = today;
  s.hunts_completed += 1;
  s.hunts_today += 1;
  s.painted_eggs_used_total += result.paintedEggsUsed ?? 0;
  let winner: { name: string; eggs: number } | null = null;
  for (const h of result.hunters ?? []) {
    s.eggs_found_total += h.eggsFound;
    s.eggs_found_today += h.eggsFound;
    s.golden_eggs_total += h.goldenEggsFound;
    s.golden_eggs_today += h.goldenEggsFound;
    s.flock_score += h.eggsFound + h.goldenEggsFound * 4;
    s.hunter_totals[h.name] = (s.hunter_totals[h.name] ?? 0) + h.eggsFound;
    const eggs = h.eggsFound + h.goldenEggsFound;
    if (!winner || eggs > winner.eggs) winner = { name: h.name, eggs };
  }
  if (result.allCollected) s.flock_score += 5;
  if (winner) s.last_winner_name = winner.name;
  const top = Object.entries(s.hunter_totals).sort((a, b) => b[1] - a[1])[0];
  if (top) s.top_hunter_name = top[0];
  save("easter", s);
  return s;
}

// ─── Command router (what `invoke` reaches) ─────────────────────────────────

export interface ShellHooks {
  onCursorEvents?: (ignore: boolean) => void;
  onAccessoriesChanged?: (ids: string[]) => void;
}
export const hooks: ShellHooks = {};

type Args = Record<string, unknown>;

const commands: Record<string, (args: Args) => unknown> = {
  get_living_state: (a) => load(`living:${a.name}`, null),
  save_living_state: (a) => save(`living:${a.name}`, a.value),

  record_interaction: (a) => {
    const what = String(a.interaction ?? "");
    const verb = what.split(" ")[0] || "interaction";
    const n = countToday(verb);
    const pretty = what.split(" ").map((w) => (w === "main" ? "me" : nameOf(w))).join(" ");
    writeDiary(verb === "trampoline" ? `${pretty} (${n} today)` : `Human ${pretty} (${n} today)`);
  },
  record_app_usage: () => {},
  record_spectacle: (a) => {
    const who = (a.participants as string[] | undefined)?.map((id) => nameOf(id)).join(", ");
    writeDiary(`Spectacle: ${a.kind}${who ? ` (${who})` : ""}`);
    for (const id of (a.participants as string[] | undefined) ?? []) {
      const brain = ensureBrain(id);
      if (brain) remember(brain, `Lived through ${a.kind}`);
    }
    saveBrains();
  },

  record_group_activity: (a) => {
    const ids = ((a.participants as string[]) ?? []).filter(Boolean);
    const type = String(a.activityType ?? "something").replace(/_/g, " ");
    for (const id of ids) {
      const brain = ensureBrain(id);
      if (!brain) continue;
      brain.stats.group_activities += 1;
      const others = ids.filter((o) => o !== id).map((o) => nameOf(o));
      remember(brain, `Joined a ${type} with ${others.join(", ") || "nobody"}`);
      for (const other of ids) if (other !== id) bumpAffinity(id, other, 2);
    }
    saveBrains();
    writeDiary(`The flock did a ${type}`);
  },

  record_friend_conversation: (a) => {
    const idA = String(a.idA);
    const idB = String(a.idB);
    const topic = String(a.topic ?? "nothing much");
    for (const [me, other] of [[idA, idB], [idB, idA]]) {
      const brain = ensureBrain(me);
      if (!brain) continue;
      brain.stats.conversations_today += 1;
      brain.stats.conversations_total += 1;
      bumpAffinity(me, other, 1);
      remember(brain, `Talked with ${nameOf(other)} about ${topic}`);
      // Chatty friends cheer up.
      if ((brain.mood === "grumpy" || brain.mood === "sleepy") && Math.random() < 0.4) setMood(brain, "happy");
      else if (brain.stats.conversations_today > 5 && brain.mood === "happy") setMood(brain, "excited");
    }
    saveBrains();
  },

  record_friend_pet: (a) => {
    const brain = ensureBrain(String(a.id));
    if (!brain) return;
    brain.stats.times_petted += 1;
    remember(brain, "Got petted by human!");
    setMood(brain, brain.mood === "happy" ? "excited" : "happy");
    saveBrains();
  },

  get_all_relationships: () => {
    decayIfNewDay();
    const out: Record<string, unknown> = {};
    for (const [id, b] of Object.entries(brains)) {
      out[id] = {
        name: b.name,
        mood: currentMood(id, b),
        relationships: { ...b.relationships },
        stats: {
          conversations_total: b.stats.conversations_total,
          times_petted: b.stats.times_petted,
          group_activities: b.stats.group_activities,
        },
      };
    }
    return out;
  },
  get_friend_moods: () => {
    const out: Record<string, string> = {};
    for (const [id, b] of Object.entries(brains)) out[id] = currentMood(id, b);
    return out;
  },

  get_easter_stats: () => easterStats(),
  record_easter_hunt: (a) => recordHunt(a.result as HuntResult),

  get_accessories: () => [...settings.accessories],
  save_accessories: (a) => {
    const ids = (a.accessories as string[]) ?? [];
    updateSettings({ accessories: ids });
    hooks.onAccessoriesChanged?.(ids);
  },

  set_cursor_events: (a) => hooks.onCursorEvents?.(Boolean(a.ignore)),

  // Timer-driven model calls stay off in an artifact (see patch.py).
  friend_ai_chat: () => {
    throw new Error("friend AI chat is scripted in the artifact");
  },
};

export async function handleCommand(cmd: string, args: Args): Promise<unknown> {
  const handler = commands[cmd];
  if (!handler) return undefined;
  return handler(args);
}

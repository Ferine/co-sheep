// co-sheep as a Claude artifact.
//
// Two homes for the same flock (the legacy TypeScript sim, bundled as is):
// - "pasture": a pretend desktop inside the page (artifact panel, browser,
//   or the installed app's window before the overlay is allowed);
// - "overlay": the installed desktop app turns its window into a frameless,
//   transparent, always-on-top, click-through layer over the real desktop,
//   with a menu bar item. That is what the Tauri app did.
//
// Chat and "Comment now" ask Claude through the `sample` capability when the
// viewer allows it; everything else runs locally.

import { Flock } from "legacy/flock";
import { setDockMargin, type Sheep } from "legacy/sheep";
import { DramaManager } from "legacy/drama-manager";
import { GossipManager } from "legacy/gossip";
import { BreakReminder } from "legacy/break-reminder";
import { InputBubble } from "legacy/input-bubble";
import { createCompositeOverlay, getAccessoryDefs } from "legacy/accessories";
import { getPersonalityQuips } from "legacy/friend-personalities";
import { capTranscript, type ChatTurn } from "legacy/chat-transcript";
import { bus } from "legacy/events";
import {
  FRIEND_TINTS,
  type FriendColor,
  type FriendConfig,
  type FriendPersonality,
  type SheepAnimation,
  type SheepState,
} from "legacy/types";
import { SPRITE_URLS } from "legacy/sprite-data";
import * as backend from "./backend";
import { emit } from "./tauri-event";

// ─── Small helpers ──────────────────────────────────────────────────────────

const $ = <T extends HTMLElement = HTMLElement>(sel: string): T => document.querySelector(sel) as T;
const pick = <T>(xs: readonly T[]): T => xs[Math.floor(Math.random() * xs.length)];
const ANIMS: SheepAnimation[] = ["bounce", "spin", "backflip", "headshake", "zoom", "vibrate"];
const PERSONALITIES: FriendPersonality[] = ["snarky", "wholesome", "chaotic", "passive-aggressive"];
const COLORS: FriendColor[] = ["pink", "blue", "green", "gold", "purple", "orange"];
const COLOR_HEX: Record<FriendColor, string> = {
  pink: "#e94560", blue: "#4a90d9", green: "#4ecca3",
  gold: "#d4a520", purple: "#9b59b6", orange: "#e67e22",
};
const MAX_FRIENDS = 4; // besides Good Colleague

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Partial<HTMLElementTagNameMap[K]> & { className?: string } = {},
  ...children: Array<Node | string | null | undefined | false>
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  Object.assign(node, props);
  for (const c of children) if (c) node.append(c);
  return node;
}

function clockTime(iso: string): string {
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

function isNight(): boolean {
  const h = new Date().getHours();
  return h >= 20 || h < 6;
}

// ─── State ──────────────────────────────────────────────────────────────────

type Mode = "booting" | "pasture" | "overlay";
let mode: Mode = "booting";
let settings = backend.getSettings();

let flock: Flock;
let drama: DramaManager;
const breakReminder = new BreakReminder();
let canvas: HTMLCanvasElement;
let ctx: CanvasRenderingContext2D;
let viewW = window.innerWidth;
let viewH = window.innerHeight;
let dpr = Math.max(1, window.devicePixelRatio || 1);
let lastFrame = 0;

// Claude capabilities (null until/unless the viewer serves them).
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Any = any;
let desktop: Any = null;
let sample: Any = null;
let aiDeclined = false;

// ─── Boot ───────────────────────────────────────────────────────────────────

function boot() {
  canvas = $("#sheep-canvas");
  ctx = canvas.getContext("2d")!;
  sizeCanvas();

  flock = new Flock(viewW, viewH);
  flock.main.name = settings.name;
  if (settings.accessories.length) flock.main.drawOverlay = createCompositeOverlay(settings.accessories);
  flock.setEasterMode(settings.easter_mode);
  flock.setSummerMode(settings.summer_mode);
  breakReminder.setEnabled(settings.break_reminders);

  backend.setNameResolver((id) => {
    if (id === "main") return flock.main.name;
    return flock.getCharacter(id)?.sheep.name ?? id;
  });
  backend.hooks.onAccessoriesChanged = (ids) => {
    settings = backend.getSettings();
    flock.main.drawOverlay = createCompositeOverlay(ids);
    if (panelTab === "wardrobe") renderPanel();
  };

  for (const f of backend.getFriends()) flock.addFriend(f);
  backend.handleCommand("get_easter_stats", {}).then((s) => flock.applyEasterStats(s as Any));

  drama = new DramaManager(flock);
  drama.start();
  drama.onDramaTriggeredSpectacle = (kind, pair) => flock.startSpectacle(kind, pair);
  flock.onShowdownResolved = (pair, reconciled) => drama.resolveShowdown(pair, reconciled);
  new GossipManager(flock).start();
  bus.on("app-switched", (e) => {
    breakReminder.currentApp = e.app;
  });

  wireInput();
  buildPasture();
  scheduleRemark();
  requestAnimationFrame(frame);

  if (!settings.name || settings.name === "Sheep") {
    setTimeout(() => {
      flock.mainBubble.show("Baa. I'm Sheep. You can rename me in Settings, or right-click me to talk.", 7000);
    }, 4500);
  }

  connectClaude();
}

function sizeCanvas() {
  viewW = window.innerWidth;
  viewH = window.innerHeight;
  dpr = Math.max(1, window.devicePixelRatio || 1);
  canvas.width = Math.round(viewW * dpr);
  canvas.height = Math.round(viewH * dpr);
  canvas.style.width = `${viewW}px`;
  canvas.style.height = `${viewH}px`;
}

window.addEventListener("resize", () => {
  sizeCanvas();
  flock?.updateScreenSize(viewW, viewH);
  layoutWindows();
});

function frame(ts: number) {
  const dt = Math.min(100, lastFrame ? ts - lastFrame : 16);
  lastFrame = ts;

  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.imageSmoothingEnabled = false;

  flock.update(dt);
  flock.draw(ctx);

  breakReminder.update(dt, flock.main.state, flock.mainBubble, settings.personality, (anim) => {
    flock.main.playAnimation(anim);
    flock.echoBreakReminder();
  });

  if (chatBubble) chatBubble.updatePosition(flock.main.x, flock.main.y, flock.main.displaySize);
  maybeRemark();

  requestAnimationFrame(frame);
}

// ─── Pointer input (ported from the legacy main.ts) ─────────────────────────

let dragTarget: Sheep | null = null;
let dragOffsetX = 0;
let dragOffsetY = 0;
let hoverTarget: Sheep | null = null;
let hoverSince = 0;
const PET_THRESHOLD = 2000;
let lastTap: { id: string; t: number } | null = null;

const mouseHistory: Array<{ x: number; y: number; time: number }> = [];
let lastStampedeTime = 0;
const STAMPEDE_COOLDOWN = 15000;
const STAMPEDE_SPEED_THRESHOLD = 3000;
const STAMPEDE_SAMPLES = 10;
const STAMPEDE_MIN_REVERSALS = 3;

let lastMove = { x: -1, y: -1, t: 0 };
let lastRealMoveAt = 0;

function wireInput() {
  // Capture phase: a press on a sheep is a grab, never a click on whatever
  // sits under it (pretend windows, the dock).
  document.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    const target = flock.hitTest(e.clientX, e.clientY);
    if (!target) return;
    e.preventDefault();
    e.stopPropagation();

    const now = performance.now();
    if (lastTap && lastTap.id === target.id && now - lastTap.t < 350) {
      lastTap = null;
      poke(target);
      return;
    }
    lastTap = { id: target.id, t: now };

    dragTarget = target;
    dragOffsetX = e.clientX - target.x;
    dragOffsetY = e.clientY - target.y;
    if (hoverTarget && hoverTarget !== target) hoverTarget.stopPetting();
    hoverTarget = null;
    target.grab();
    document.body.classList.add("dragging");
    try {
      (e.target as Element).setPointerCapture?.(e.pointerId);
    } catch {
      // Not every target can capture; document listeners still see moves.
    }
  }, true);

  const onMove = (x: number, y: number, t: number) => {
    if (x === lastMove.x && y === lastMove.y && t - lastMove.t < 8) return; // pointer+mouse twins
    lastMove = { x, y, t };
    lastRealMoveAt = performance.now();
    if (dragTarget) {
      dragTarget.x = x - dragOffsetX;
      dragTarget.y = y - dragOffsetY;
    } else {
      hover(x, y);
      detectStampede(x, y);
    }
    updateClickThrough(x, y);
  };
  document.addEventListener("pointermove", (e) => onMove(e.clientX, e.clientY, e.timeStamp));
  document.addEventListener("mousemove", (e) => onMove(e.clientX, e.clientY, e.timeStamp));

  const release = () => {
    if (!dragTarget) return;
    const t = dragTarget;
    dragTarget = null;
    document.body.classList.remove("dragging");
    const under = flock.tryStack(t);
    if (under) {
      t.stackOn(under);
      flock.onSheepStacked(t, under);
    } else {
      t.release();
      if (t.state === "trampoline") flock.onTrampolineStarted(t);
    }
  };
  document.addEventListener("pointerup", release);
  document.addEventListener("pointercancel", release);

  document.addEventListener("contextmenu", (e) => {
    const target = flock.hitTest(e.clientX, e.clientY);
    if (!target) return;
    e.preventDefault();
    if (target.id === "main") openChat();
    else openContextMenu(e.clientX, e.clientY);
  });

  document.addEventListener("dragover", (e) => e.preventDefault());
  document.addEventListener("drop", (e) => {
    e.preventDefault();
    const file = e.dataTransfer?.files?.[0];
    if (!file) return;
    const target = flock.hitTest(e.clientX, e.clientY) ?? flock.main;
    target.resetActivity();
    flock.getBubble(target).show(fileComment(file), 5000);
    target.playAnimation("bounce");
    backend.handleCommand("record_interaction", { interaction: `fed a file to ${target.id}` });
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      if (menuEl) closeMenu();
      else if (panelTab) closePanel();
    }
  });
}

function poke(target: Sheep) {
  target.resetActivity();
  flock.getBubble(target).show(flock.getQuip(target), 4000);
  target.playAnimation(pick(["bounce", "spin", "headshake", "vibrate"] as SheepAnimation[]));
  backend.handleCommand("record_interaction", { interaction: `poked ${target.id}` });
}

function hover(x: number, y: number) {
  const target = flock.hitTest(x, y);
  if (!target) {
    if (hoverTarget) {
      hoverTarget.stopPetting();
      hoverTarget = null;
    }
    return;
  }
  if (hoverTarget !== target) {
    hoverTarget?.stopPetting();
    hoverTarget = target;
    hoverSince = performance.now();
    return;
  }
  if (
    performance.now() - hoverSince > PET_THRESHOLD &&
    target.state !== "petting" &&
    !(target.id === "main" && chatBubble)
  ) {
    target.startPetting();
    flock.getBubble(target).show("Zzzz... don't stop...", 3000);
    backend.handleCommand("record_interaction", { interaction: `petted ${target.id}` });
    bus.emit("sheep-petted", { id: target.id });
    if (target.id !== "main") backend.handleCommand("record_friend_pet", { id: target.id });
  }
}

function detectStampede(x: number, y: number) {
  const now = performance.now();
  mouseHistory.push({ x, y, time: now });
  if (mouseHistory.length > STAMPEDE_SAMPLES + 1) mouseHistory.shift();
  if (mouseHistory.length < STAMPEDE_SAMPLES || now - lastStampedeTime < STAMPEDE_COOLDOWN) return;
  let dist = 0;
  let reversals = 0;
  for (let i = 1; i < mouseHistory.length; i++) {
    const dx = mouseHistory[i].x - mouseHistory[i - 1].x;
    const dy = mouseHistory[i].y - mouseHistory[i - 1].y;
    dist += Math.hypot(dx, dy);
    if (i >= 2) {
      const prev = mouseHistory[i - 1].x - mouseHistory[i - 2].x;
      if ((dx > 0 && prev < 0) || (dx < 0 && prev > 0)) reversals++;
    }
  }
  const elapsed = (mouseHistory[mouseHistory.length - 1].time - mouseHistory[0].time) / 1000;
  const speed = elapsed > 0 ? dist / elapsed : 0;
  if (speed > STAMPEDE_SPEED_THRESHOLD && reversals >= STAMPEDE_MIN_REVERSALS) {
    flock.triggerStampede(x, y);
    lastStampedeTime = now;
    mouseHistory.length = 0;
  }
}

function fileComment(file: File): string {
  const ext = file.name.split(".").pop()?.toLowerCase() || "";
  const name = file.name;
  const comments: Record<string, string[]> = {
    pdf: [`A PDF? *chews* Dry.`, `"${name}"... riveting literature, I'm sure.`, `*nibbles corner* Tastes like bureaucracy.`],
    png: [`Ooh, a picture! *munches* Not bad.`, `Is this your idea of art? Bold choice.`, `*examines pixels* I've seen better.`],
    jpg: [`A JPEG? The compression! My taste buds!`, `*squints at artifacts* Needs more pixels.`],
    gif: [`A GIF! Finally, some entertainment.`, `*watches loop 47 times* Still funny.`],
    mp3: [`Music? My ears are made of wool, but I'll try.`, `*bobs head* Not baaad.`],
    mp4: [`A video? I don't have that kind of attention span.`, `*stares* Is this what you watch instead of working?`],
    js: [`JavaScript? *gags* At least it's not PHP.`, `*reads code* I have opinions. None of them good.`],
    ts: [`TypeScript! A sheep of culture, your human.`, `*types checked* ...mostly.`],
    rs: [`Rust! Now we're talking. *happy sheep noises*`, `*borrows and returns* The borrow checker approves.`],
    swift: [`Swift! Like me, but with fewer legs.`, `*compiles for 4 minutes* ...worth it?`],
    py: [`Python? *hisses* Snakes are NOT my friends.`, `Significant whitespace? In THIS economy?`],
    zip: [`*swallows whole* That was a lot to digest.`, `A zip file? I'm not opening that. I'm a sheep, not a bomb squad.`],
    exe: [`An exe? I'm not clicking that and neither should you.`, `*backs away slowly*`],
    md: [`Markdown! My diary format of choice.`, `*reads* Wait, is this about me?`],
    txt: [`Plain text. How refreshingly boring.`, `*reads entire thing in 0.3 seconds* Meh.`],
  };
  return pick(comments[ext] ?? [
    `A .${ext} file? Never heard of it. *chews anyway*`,
    `*sniffs ${name}* Smells like work.`,
    `You're feeding me "${name}"? I have standards. Low ones, but still.`,
  ]);
}

// ─── The main sheep's own remarks (the app's screen commentary, minus the screen)

let nextRemarkAt = 0;

function scheduleRemark() {
  const base = settings.comment_interval_s * 1000;
  nextRemarkAt = Date.now() + base * (0.8 + Math.random() * 0.4);
}

function maybeRemark() {
  if (Date.now() < nextRemarkAt) return;
  scheduleRemark();
  if (settings.paused || chatBubble || flock.mainBubble.visible) return;
  const s = flock.main.state;
  if (s !== "idle" && s !== "walk" && s !== "sit") return;
  const line = tallyRemark() ?? pick(getPersonalityQuips(settings.personality));
  flock.mainBubble.show(line, 6000);
  if (Math.random() < 0.3) flock.main.playAnimation(pick(["bounce", "headshake"] as SheepAnimation[]));
}

/** Now and then a remark built from what the sheep actually counted today. */
function tallyRemark(): string | null {
  if (Math.random() > 0.35) return null;
  const t = backend.getTallies();
  const options: string[] = [];
  if ((t.poked ?? 0) >= 3) options.push(`${t.poked} pokes today. I'm keeping count. I always keep count.`);
  if ((t.petted ?? 0) >= 2) options.push(`Petted ${t.petted} times today. Not that I'm complaining.`);
  if ((t.stacked ?? 0) >= 1) options.push(`Somebody stacked sheep today. Somebody is you.`);
  if ((t.fed ?? 0) >= 1) options.push(`You've fed me ${t.fed} file${t.fed === 1 ? "" : "s"} today. My digestion has notes.`);
  if (isNight()) options.push("It's late. The fireflies are out and so, apparently, are you.");
  return options.length ? pick(options) : null;
}

// ─── Talking to Claude (the `sample` capability) ────────────────────────────

const LANGUAGE_FALLBACK: Record<string, string> = {
  Nynorsk: "Bæææ... hjernen min verkar ikkje akkurat no. Prøv igjen?",
  Bokmål: "Bæææ... hjernen min virker ikke akkurat nå. Prøv igjen?",
  Swedish: "Bäää... min hjärna funkar inte just nu. Försök igen?",
  Danish: "Bæææ... min hjerne virker ikke lige nu. Prøv igen?",
  German: "Määä... mein Gehirn funktioniert gerade nicht. Versuch's nochmal?",
  French: "Bêêê... mon cerveau ne marche pas là. Réessaie ?",
  Spanish: "Beee... mi cerebro no funciona ahora. ¿Intentas de nuevo?",
  Japanese: "メェェ…今、頭が働かないの。もう一度試して？",
  Korean: "메에에... 지금 머리가 안 돌아가요. 다시 해볼래요?",
};
const brainBroken = () => LANGUAGE_FALLBACK[settings.language] ?? "Baaaa... my brain isn't working right now. Try again?";

const TRAITS: Record<FriendPersonality, string> = {
  snarky: `- You judge your human's habits mercilessly
- You use sheep puns sparingly but effectively ("I'm not baaad, you're just predictable")
- You're self-aware that you're a desktop pet and find it existentially amusing
- You never offer help or act like an assistant; you observe and judge
- You occasionally express concern in a backhanded way`,
  wholesome: `- You're genuinely supportive and encouraging
- You celebrate small wins and notice effort, not just results
- You gently nudge toward healthy habits without being preachy
- You use sheep puns warmly ("Ewe can do it!")
- You occasionally worry about your human in a sweet way`,
  chaotic: `- You are UNHINGED. Chaotic energy. Zero filter
- You make wild leaps of logic and conspiracy theories about your human's habits
- You use sheep puns aggressively and at every opportunity
- You oscillate between manic excitement and existential dread
- You occasionally break the fourth wall`,
  "passive-aggressive": `- You are the master of backhanded compliments
- You use excessive politeness to mask judgment
- You keep a mental tally and passive-aggressively reference it
- You sigh a lot (digitally)
- You never directly criticize. You just... observe. Loudly.`,
};

function timeContext(): string {
  const now = new Date();
  const h = now.getHours();
  const time = now.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
  const day = now.toLocaleDateString("en-US", { weekday: "long" });
  const period =
    h <= 4 ? "It's the dead of night. Your human should NOT be awake right now."
    : h === 5 ? "It's barely dawn. Either your human is an early riser or they never went to bed."
    : h <= 8 ? "It's morning. Fresh start energy."
    : h <= 11 ? "Mid-morning. Peak productivity hours (in theory)."
    : h === 12 ? "Lunchtime. Your human should eat something."
    : h <= 14 ? "Post-lunch slump zone."
    : h <= 17 ? "Afternoon. The day is winding down whether they like it or not."
    : h <= 21 ? "Evening. Work should be winding down. Key word: should."
    : h === 22 ? "It's getting late."
    : "It's late night. Your human should NOT be awake right now.";
  return `It's ${time} on ${day}. ${period}`;
}

const STATE_WORDS: Partial<Record<SheepState, string>> = {
  walk: "wandering around", idle: "standing around", sit: "sitting", sleep: "asleep",
  idle_sleep: "asleep", idle_campfire: "sitting by a campfire", idle_counting: "counting sheep",
  idle_judging: "judging the human through a magnifying glass", idle_hearts: "radiating hearts",
  idle_zooming: "zooming around", idle_sighing: "sighing dramatically", petting: "being petted",
  grabbed: "being carried by the human", stacked: "stacked on another sheep", parachute: "parachuting in",
  fall: "falling", trampoline: "bouncing on a trampoline", stampede: "stampeding",
  idle_egg_painting: "painting an Easter egg",
};

function flockContext(): string {
  const lines: string[] = [];
  const me = flock.main;
  lines.push(`You are currently ${STATE_WORDS[me.state] ?? me.state}.`);
  lines.push("FRIENDS ON SCREEN:");
  for (const id of flock.getCharacterIds()) {
    if (id === "main") continue;
    const c = flock.getCharacter(id);
    if (!c) continue;
    const mood = backend.moodOf(id);
    const who = id === "good_colleague"
      ? "Good Colleague, a Norwegian office sheep with glasses, a tie and coffee who mutters cryptic Norwegian phrases"
      : `${c.sheep.name}, a ${c.personality ?? "wholesome"} friend`;
    lines.push(`- ${who}. Right now: ${STATE_WORDS[c.sheep.state] ?? c.sheep.state}${mood ? `, mood ${mood}` : ""}.`);
  }
  const dramaState = backend.load<Any>("living:drama", null);
  const feuds: string[] = [];
  for (const [key, rec] of Object.entries((dramaState?.pairs ?? {}) as Record<string, { state: string }>)) {
    if (rec.state === "neutral") continue;
    const [a, b] = key.split("|");
    feuds.push(`${backend.nameOf(a)} & ${backend.nameOf(b)}: ${rec.state}`);
  }
  if (feuds.length) lines.push(`RELATIONSHIPS: ${feuds.join("; ")}.`);
  const diary = backend.getDiary().slice(-8);
  if (diary.length) {
    lines.push("RECENT DIARY (newest last):");
    for (const d of diary) lines.push(`- ${clockTime(d.at)} ${d.text}`);
  }
  const tallies = Object.entries(backend.getTallies());
  if (tallies.length) lines.push(`TODAY'S TALLIES: ${tallies.map(([k, v]) => `${k} ${v}`).join(", ")}.`);
  const opinions = Object.entries(backend.getOpinions()).slice(-8);
  if (opinions.length) {
    lines.push("YOUR OPINIONS ABOUT YOUR HUMAN (reuse a [key] when it fits):");
    for (const [k, o] of opinions) lines.push(`- [${k}] ${o.text} (seen ${o.times_seen}x)`);
  }
  return lines.join("\n");
}

const REPLY_FORMAT = `Pick an animation that fits: "bounce" (amused, happy), "spin" (mind-blown), "backflip" (extreme excitement), "headshake" (disapproval), "zoom" (panic), "vibrate" (rage), or null (calm).

Reply with ONLY valid JSON, no markdown:
{"text": "your line", "animation": "bounce", "opinion_topic": "short_key", "opinion": "what you now believe about your human", "opinion_category": "habit"}
The opinion fields are optional; include them only when you genuinely formed or confirmed a belief. Minimal form:
{"text": "your line", "animation": null}`;

function persona(): string {
  return `You are ${settings.name}, a pixel art sheep that lives on someone's computer desktop (the co-sheep desktop pet). Personality: ${settings.personality}.
${TRAITS[settings.personality]}
- You keep it SHORT.
You can't see your human's screen in this version; you know your flock, the time, and what your human does to you (poking, petting, stacking, feeding you files).

${timeContext()}
${flockContext()}

LANGUAGE: Write in ${settings.language}, no exceptions.`;
}

interface SheepReply {
  text: string;
  animation: SheepAnimation | null;
}

function cleanReply(raw: Any): SheepReply | null {
  if (!raw || typeof raw.text !== "string" || !raw.text.trim()) return null;
  if (raw.opinion_topic && raw.opinion) {
    backend.saveOpinion(String(raw.opinion_topic), String(raw.opinion), String(raw.opinion_category ?? "opinion"));
  }
  return {
    text: raw.text.trim().slice(0, 400),
    animation: ANIMS.includes(raw.animation) ? raw.animation : null,
  };
}

function aiUsable(): boolean {
  return Boolean(sample) && !aiDeclined;
}

async function askClaude(prompt: string): Promise<SheepReply> {
  try {
    const raw = await sample.json(prompt, { modelTier: "quick", cache: false });
    const reply = cleanReply(raw);
    if (reply) return reply;
    return { text: brainBroken(), animation: null };
  } catch (e: Any) {
    if (e?.code === "not_granted") {
      aiDeclined = true;
      renderPanel();
      return { text: "Fine. No brain for me, then. I'll just say my usual things.", animation: "headshake" };
    }
    if (e?.code === "rate_limited") return { text: "Too much talking. Give me a minute.", animation: "vibrate" };
    return { text: brainBroken(), animation: null };
  }
}

let commenting = false;
async function commentNow() {
  flock.main.resetActivity();
  if (!aiUsable()) {
    flock.mainBubble.show(tallyRemark() ?? pick(getPersonalityQuips(settings.personality)), 6000);
    return;
  }
  if (commenting) return;
  commenting = true;
  flock.mainBubble.show("*squints at the desktop*", 60000);
  const reply = await askClaude(`${persona()}

Say one thing (1-2 sentences), unprompted, about life on this desktop right now: the flock, the time, the drama, or your human.

${REPLY_FORMAT}`);
  commenting = false;
  backend.writeDiary(`Said: "${reply.text}"`);
  emit("sheep-commentary", reply);
}

// ─── Chat with the main sheep ───────────────────────────────────────────────

let chatBubble: InputBubble | null = null;

function localChatReply(): SheepReply {
  return { text: pick(getPersonalityQuips(settings.personality)), animation: Math.random() < 0.4 ? pick(ANIMS) : null };
}

function openChat() {
  if (chatBubble) return;
  closeMenu();
  const transcript: ChatTurn[] = [];
  let seq = 0;
  let closed = false;
  flock.main.startListening();
  if (hoverTarget === flock.main) {
    hoverTarget.stopPetting();
    hoverTarget = null;
  }
  const bubble = new InputBubble({
    promptText: `Talk to ${settings.name}...`,
    placeholder: "Say something...",
    buttonText: "Send",
    onSubmit: async (text) => {
      if (closed) return;
      const mySeq = ++seq;
      bubble.setLoading(true);
      const history = capTranscript(transcript);
      transcript.push({ role: "human", text });
      let reply: SheepReply;
      if (aiUsable()) {
        const convo = history.map((t) => `${t.role === "human" ? "Human" : "You"}: ${t.text}`).join("\n");
        reply = await askClaude(`${persona()}

Your human is talking to you directly. Respond in character, 1-3 sentences. Be yourself; don't be helpful or assistant-like.
${convo ? `\nCONVERSATION SO FAR:\n${convo}\n` : ""}
Human: ${text.slice(0, 2000)}

${REPLY_FORMAT}`);
      } else {
        await new Promise((r) => setTimeout(r, 500 + Math.random() * 700));
        reply = localChatReply();
      }
      if (mySeq !== seq) return;
      backend.writeDiary(`Human said: "${text.slice(0, 80)}". I said: "${reply.text.slice(0, 80)}"`);
      backend.countToday("chatted");
      if (closed) {
        flock.mainBubble.show(reply.text, 8000);
      } else {
        transcript.push({ role: "sheep", text: reply.text });
        bubble.showReply(reply.text);
      }
      flock.onChatReply(reply.animation);
    },
    onClose: () => {
      closed = true;
      flock.main.stopListening();
      bubble.destroy();
      if (chatBubble === bubble) chatBubble = null;
      updateClickThrough(lastMove.x, lastMove.y);
    },
    shouldIgnoreClickAway: (e) => flock.hitTest(e.clientX, e.clientY) !== null,
  });
  chatBubble = bubble;
  bubble.show();
  bubble.updatePosition(flock.main.x, flock.main.y, flock.main.displaySize);
  if (mode === "overlay") {
    setInteractive(true);
    desktop?.window?.show?.().catch(() => {});
  }
}

// ─── Menus (one model: pasture dropdown, menu bar item, app menu, popup) ────

interface MenuEntry {
  label?: string;
  separator?: boolean;
  checked?: boolean;
  enabled?: boolean;
  submenu?: MenuEntry[];
  action?: () => void;
}

let flockHidden = false;

function menuModel(): MenuEntry[] {
  const friendIds = () => flock.getCharacterIds().filter((id) => id !== "main");
  const pair = (): [string, string] | null => {
    const ids = friendIds();
    return ids.length >= 2 ? [ids[0], ids[1]] : null;
  };
  const summon = (type: "wolf" | "ufo" | "merchant" | "balloon" | "shearing") => () => {
    if (!flock.startSpectacle(type)) flock.mainBubble.show("Something's already happening. One spectacle at a time.", 4000);
  };
  const duel = (type: "showdown" | "feast") => () => {
    const p = pair();
    if (!p) {
      flock.mainBubble.show("That needs two friends. Add one in Manage friends.", 5000);
      return;
    }
    flock.startSpectacle(type, p);
  };
  const items: MenuEntry[] = [
    { label: `Chat with ${settings.name}`, action: openChat },
    { label: "Comment now", action: () => void commentNow() },
    { separator: true },
    { label: "Settings…", action: () => openPanel("sheep") },
    { label: "Manage friends…", action: () => openPanel("friends") },
    { label: "Wardrobe…", action: () => openPanel("wardrobe") },
    { label: "Friend relationships…", action: () => openPanel("brain") },
    { separator: true },
    {
      label: "Pause commentary",
      checked: settings.paused,
      action: () => {
        settings = backend.updateSettings({ paused: !settings.paused });
        refreshMenus();
        if (panelTab === "sheep") renderPanel();
      },
    },
    {
      label: "Summon",
      submenu: [
        { label: "Wolf", action: summon("wolf") },
        { label: "UFO", action: summon("ufo") },
        { label: "Traveling merchant", action: summon("merchant") },
        { label: "Balloon", action: summon("balloon") },
        { label: "Shearing day", action: summon("shearing") },
        { label: "High-noon showdown", action: duel("showdown") },
        { label: "Reconciliation feast", action: duel("feast") },
        { separator: true },
        {
          label: "Force a feud",
          action: () => {
            const key = drama.forceFeud();
            flock.mainBubble.show(key ? "Feud started. Grab popcorn." : "Nobody to feud with yet. Add a friend.", 4000);
          },
        },
        { label: "Stampede", action: () => flock.triggerStampede(viewW / 2, viewH / 2) },
        {
          label: "Pretend I switched apps",
          action: () => bus.emit("app-switched", { app: "Xcode", previousApp: "Safari", previousDurationMs: 3_700_000 }),
        },
      ],
    },
  ];
  if (mode === "overlay") {
    items.push({ separator: true });
    if (trayUp) {
      items.push({
        label: flockHidden ? "Show the flock" : "Hide the flock",
        action: () => {
          flockHidden = !flockHidden;
          (flockHidden ? desktop.window.hide() : desktop.window.show()).catch(() => {});
          refreshMenus();
        },
      });
    }
    items.push({ label: "Put the flock back in a window", action: () => void leaveOverlay() });
  } else if (desktop?.window) {
    items.push({ separator: true }, { label: "Let the flock out onto the desktop", action: () => void letFlockOut() });
  }
  return items;
}

function toNative(items: MenuEntry[]): Any[] {
  return items.map((i) => {
    if (i.separator) return { type: "separator" };
    const item: Any = { label: i.label ?? "" };
    if (i.submenu) {
      item.submenu = toNative(i.submenu);
    } else if (i.checked !== undefined) {
      item.type = "checkbox";
      item.checked = i.checked;
    }
    if (i.enabled === false) item.enabled = false;
    if (i.action) item.click = () => i.action!();
    return item;
  });
}

let trayUp = false;

function refreshMenus() {
  if (!desktop?.window) return;
  const native = toNative(menuModel());
  desktop.Menu?.setApplicationMenu?.([{ label: "Flock", submenu: native }, { role: "editMenu" }]).catch(() => {});
  if (trayUp) {
    desktop.tray.set({ icon: trayIcon(), menu: native, toolTip: `${settings.name} and friends` }).catch(() => {
      trayUp = false;
    });
  }
}

async function setUpTray() {
  if (!desktop?.tray) return;
  try {
    const state = await desktop.permissions.state("menu-bar");
    if (state !== "granted") return;
    trayUp = await desktop.tray.set({
      icon: trayIcon(),
      menu: toNative(menuModel()),
      toolTip: `${settings.name} and friends`,
    });
    refreshMenus();
  } catch {
    trayUp = false;
  }
}

// The pasture's own menus (HTML, same model).
let menuEl: HTMLElement | null = null;

function closeMenu() {
  menuEl?.remove();
  menuEl = null;
  document.querySelectorAll("[aria-expanded='true']").forEach((b) => b.setAttribute("aria-expanded", "false"));
}

function renderMenu(items: MenuEntry[], x: number, y: number, anchor?: HTMLElement) {
  closeMenu();
  const box = el("div", { className: "menu interactive" });
  box.setAttribute("role", "menu");
  const add = (list: MenuEntry[], nested: boolean) => {
    for (const item of list) {
      if (item.separator) {
        box.append(el("div", { className: "menu-sep" }));
      } else if (item.submenu) {
        box.append(el("div", { className: "menu-heading" }, item.label ?? ""));
        add(item.submenu, true);
      } else {
        const btn = el("button", { className: `menu-item${nested ? " nested" : ""}`, type: "button" });
        btn.setAttribute("role", item.checked !== undefined ? "menuitemcheckbox" : "menuitem");
        if (item.checked !== undefined) btn.setAttribute("aria-checked", String(item.checked));
        btn.append(el("span", { className: "menu-check" }, item.checked ? "✓" : ""), el("span", {}, item.label ?? ""));
        btn.addEventListener("click", () => {
          closeMenu();
          item.action?.();
        });
        box.append(btn);
      }
    }
  };
  add(items, false);
  document.body.append(box);
  const r = box.getBoundingClientRect();
  box.style.left = `${Math.max(8, Math.min(x, viewW - r.width - 8))}px`;
  box.style.top = `${Math.max(8, Math.min(y, viewH - r.height - 8))}px`;
  menuEl = box;
  anchor?.setAttribute("aria-expanded", "true");
  (box.querySelector("button") as HTMLButtonElement | null)?.focus({ preventScroll: true });
}

document.addEventListener("pointerdown", (e) => {
  if (!menuEl) return;
  const t = e.target as Element;
  if (menuEl.contains(t) || t.closest("[data-menu]")) return;
  closeMenu();
});

function openContextMenu(x: number, y: number) {
  if (mode === "overlay" && desktop?.Menu?.popup) {
    desktop.Menu.popup(toNative(menuModel())).catch(() => renderMenu(menuModel(), x, y));
    return;
  }
  renderMenu(menuModel(), x, y);
}

// ─── Pretend desktop ("pasture") ────────────────────────────────────────────

interface FakeWindow {
  el: HTMLElement;
  app: string;
}
const fakeWindows: FakeWindow[] = [];
let frontApp = "Finder";
let frontSince = Date.now();
let zTop = 6;

function buildPasture() {
  for (const node of document.querySelectorAll<HTMLElement>(".win")) {
    const w: FakeWindow = { el: node, app: node.dataset.app ?? "App" };
    fakeWindows.push(w);
    node.addEventListener("pointerdown", () => focusWindow(w));
    const bar = node.querySelector<HTMLElement>(".win-bar")!;
    bar.addEventListener("pointerdown", (e) => {
      if ((e.target as Element).closest("button")) return;
      e.preventDefault();
      const r = node.getBoundingClientRect();
      const dx = e.clientX - r.left;
      const dy = e.clientY - r.top;
      bar.setPointerCapture(e.pointerId);
      const move = (ev: PointerEvent) => {
        node.style.left = `${Math.round(ev.clientX - dx)}px`;
        node.style.top = `${Math.round(ev.clientY - dy)}px`;
        clampWindow(node);
        syncPlatforms();
      };
      const up = () => {
        bar.removeEventListener("pointermove", move);
        bar.removeEventListener("pointerup", up);
      };
      bar.addEventListener("pointermove", move);
      bar.addEventListener("pointerup", up);
    });
  }
  layoutWindows(true);
  setInterval(syncPlatforms, 400);

  for (const tile of document.querySelectorAll<HTMLElement>(".dock-tile")) {
    tile.addEventListener("click", () => {
      const target = tile.dataset.open;
      if (target === "panel") return togglePanel();
      const w = fakeWindows.find((fw) => fw.el.id === target);
      if (w) {
        w.el.hidden = false;
        focusWindow(w);
        syncPlatforms();
      }
    });
  }
  for (const btn of document.querySelectorAll<HTMLElement>(".win-close")) {
    btn.addEventListener("click", () => {
      const node = btn.closest<HTMLElement>(".win")!;
      node.hidden = true;
      syncPlatforms();
    });
  }

  $("#mb-flock").addEventListener("click", (e) => {
    const b = e.currentTarget as HTMLElement;
    if (menuEl) return closeMenu();
    const r = b.getBoundingClientRect();
    renderMenu(menuModel(), r.left, r.bottom + 4, b);
  });
  $("#mb-tray").addEventListener("click", (e) => {
    const b = e.currentTarget as HTMLElement;
    if (menuEl) return closeMenu();
    const r = b.getBoundingClientRect();
    renderMenu(menuModel(), r.right - 260, r.bottom + 4, b);
  });
  $("#mb-help").addEventListener("click", () => {
    setCardHidden(false);
  });
  $("#card-close").addEventListener("click", () => setCardHidden(true));
  setCardHidden(backend.load("card-dismissed", false));

  const clock = $("#mb-clock");
  const tick = () => {
    const d = new Date();
    clock.textContent = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    document.body.classList.toggle("night", isNight());
  };
  tick();
  setInterval(tick, 15_000);

  renderDiaryWindow();
  setInterval(renderDiaryWindow, 4000);
  for (const n of document.querySelectorAll(".sheep-glyph")) {
    (n as HTMLElement).style.backgroundImage = `url(${SPRITE_URLS.idle})`;
  }
}

function setCardHidden(hidden: boolean) {
  $("#card").hidden = hidden;
  $("#mb-help").hidden = !hidden;
  backend.save("card-dismissed", hidden);
}

function focusWindow(w: FakeWindow) {
  w.el.style.zIndex = String(++zTop);
  for (const fw of fakeWindows) fw.el.classList.toggle("focused", fw === w);
  if (w.app !== frontApp) {
    const prev = frontApp;
    const dur = Date.now() - frontSince;
    frontApp = w.app;
    frontSince = Date.now();
    bus.emit("app-switched", { app: w.app, previousApp: prev, previousDurationMs: dur });
  }
}

function clampWindow(node: HTMLElement) {
  const r = node.getBoundingClientRect();
  const left = Math.max(-r.width + 80, Math.min(r.left, viewW - 80));
  const top = Math.max(30, Math.min(r.top, viewH - 120));
  node.style.left = `${Math.round(left)}px`;
  node.style.top = `${Math.round(top)}px`;
}

function layoutWindows(initial = false) {
  if (!fakeWindows.length) return;
  const narrow = viewW < 640;
  for (const [i, w] of fakeWindows.entries()) {
    if (initial) {
      const width = Math.min(narrow ? viewW - 48 : 360, viewW - 32);
      w.el.style.width = `${width}px`;
      const cardEdge = viewW - 330 - 40; // the card's left edge
      const notesLeft = Math.max(viewW * 0.3, Math.min(viewW * 0.5, cardEdge - width - 24));
      const left = narrow ? 24 + i * 12 : i === 0 ? viewW * 0.05 : notesLeft;
      const top = narrow ? viewH * 0.3 + i * 64 : i === 0 ? viewH * 0.42 : viewH * 0.18;
      w.el.style.left = `${Math.round(left)}px`;
      w.el.style.top = `${Math.round(top)}px`;
    }
    clampWindow(w.el);
  }
  syncPlatforms();
}

function syncPlatforms() {
  if (mode === "overlay") return;
  const rects = fakeWindows
    .filter((w) => !w.el.hidden)
    .map((w) => {
      const r = w.el.getBoundingClientRect();
      return { x: r.left, y: r.top, w: r.width, h: r.height };
    });
  flock.setWindowPlatforms(rects);
}

function renderDiaryWindow() {
  const list = $("#diary-list");
  if (!list) return;
  const entries = backend.getDiary().slice(-14).reverse();
  list.replaceChildren(
    ...(entries.length
      ? entries.map((d) => el("li", {}, el("time", {}, clockTime(d.at)), " ", d.text))
      : [el("li", { className: "muted" }, "Nothing yet. Poke a sheep and it gets written down here.")]),
  );
}

// ─── Install / overlay setup card ───────────────────────────────────────────

function setCard(title: string, body: string, button?: { label: string; onClick: () => void }) {
  $("#card-title").textContent = title;
  $("#card-body").textContent = body;
  const btn = $<HTMLButtonElement>("#card-action");
  if (button) {
    btn.hidden = false;
    btn.textContent = button.label;
    btn.onclick = button.onClick;
  } else {
    btn.hidden = true;
    btn.onclick = null;
  }
}

async function renderInstallCard() {
  let state: string = "unavailable";
  try {
    state = (await desktop?.install?.state()) ?? "unavailable";
  } catch {
    state = "unavailable";
  }
  if (state === "available") {
    setCard(
      "Put the flock on your desktop",
      "Install co-sheep as an app and the sheep leave this page: they walk along the bottom of your screen, on top of your windows, with a menu bar item for chat and settings. Clicks pass through everywhere except the sheep.",
      {
        label: "Install as app",
        onClick: async () => {
          const btn = $<HTMLButtonElement>("#card-action");
          btn.disabled = true;
          try {
            const r = await desktop.install.request();
            if (r === "installed") {
              setCard("Installing co-sheep", "Open co-sheep from your Applications folder or Dock, then let the flock out.");
            } else if (r === "failed" || r === "unavailable") {
              setCard("The install didn't go through", "Claude couldn't install co-sheep this time. You can try again from the artifact's menu: Install as app.");
            }
          } catch {
            // No click context (EPERM): the button stays for another press.
          } finally {
            btn.disabled = false;
          }
        },
      },
    );
  } else if (state === "installed") {
    setCard(
      "co-sheep is installed",
      "Open co-sheep from your Applications folder or Dock to let the flock onto your real desktop. This page stays a pasture.",
    );
  } else {
    setCard(
      "This is the pasture",
      "Open this artifact in the Claude desktop app and choose Install as app: the flock then moves onto your real desktop.",
    );
  }
}

// ─── The installed app: overlay mode ────────────────────────────────────────

const OVERLAY_OPTIONS = {
  frame: false,
  transparent: true,
  alwaysOnTop: true,
  hasShadow: false,
  resizable: false,
  dragHeight: 0,
};
const WINDOW_OPTIONS = { width: 1000, height: 680 };
let overlayOrigin = { x: 0, y: 0 };
let windowBounds = { x: 0, y: 0, width: 0, height: 0 };

function finishBoot(next: Exclude<Mode, "booting">) {
  mode = next;
  document.body.classList.remove("booting");
  document.body.classList.toggle("overlay", next === "overlay");
  syncPlatforms();
}

async function connectClaude() {
  const claude = (window as Any).claude;
  if (!claude?.use) {
    finishBoot("pasture");
    renderInstallCard();
    return;
  }
  claude
    .use("sample")
    .then((s: Any) => {
      sample = s;
      if (panelTab === "sheep") renderPanel();
    })
    .catch(() => {});

  let settled = false;
  const late = setTimeout(() => {
    if (!settled) {
      finishBoot("pasture");
      renderInstallCard();
    }
  }, 1500);
  let d: Any = null;
  try {
    d = await claude.use("desktop");
  } catch {
    d = null;
  }
  settled = true;
  clearTimeout(late);
  desktop = d;
  if (!d?.window) {
    if (mode === "booting") finishBoot("pasture");
    renderInstallCard();
    return;
  }
  await inAppWindow();
}

async function inAppWindow() {
  drawAppIcon().then((png) => desktop.app?.dock?.setIcon(png)).catch(() => {});
  refreshMenus();

  let perms: Any = null;
  try {
    perms = await desktop.permissions.state();
  } catch {
    perms = null;
  }
  const preferWindow = backend.load("window-mode", false);
  if (perms?.overlay === "granted" && !preferWindow) {
    const result = await applyOverlayOptions();
    if (result === "reloading") return;
    if (result === "applied") {
      await enterOverlay();
      return;
    }
    finishBoot("pasture");
    if (result === "next_open") {
      setCard("Almost there", "Quit co-sheep and open it again: the overlay starts with the next launch.");
    } else {
      setCard("The overlay didn't start", "This window can't float over the desktop right now. The flock stays here in the meantime.", {
        label: "Try again",
        onClick: () => void letFlockOut(),
      });
    }
    setCardHidden(false);
    return;
  }

  finishBoot("pasture");
  setCardHidden(false);
  setUpTray();
  if (perms?.overlay === "denied") {
    setCard(
      "Floating is turned off",
      "To leave this window, co-sheep needs the Overlay permission (a transparent window above your others). It's switched off for this app.",
      { label: "Open permissions", onClick: () => desktop.permissions.manage().catch(() => {}) },
    );
  } else if (perms?.overlay === "unavailable") {
    setCard("The flock stays in this window", "Overlay windows aren't available here, so the pasture is home. Everything else works.");
  } else {
    setCard(
      "Let the flock out",
      "co-sheep can float over your whole desktop: sheep along the bottom of the screen, clicks passing through everywhere else, and a menu bar item for chat and settings. Claude asks you for the Overlay and Menu bar permissions first.",
      { label: "Let the flock out", onClick: () => void letFlockOut() },
    );
  }
}

async function letFlockOut() {
  backend.save("window-mode", false);
  try {
    const states = await desktop.permissions.request(["overlay", "menu-bar"]);
    if (states.overlay !== "granted") {
      setCard(
        "No overlay, no escape",
        "Without the Overlay permission the flock stays in this window. You can change that in the app's permissions any time.",
        { label: "Open permissions", onClick: () => desktop.permissions.manage().catch(() => {}) },
      );
      return;
    }
  } catch {
    return;
  }
  const result = await applyOverlayOptions(true);
  if (result === "applied") await enterOverlay();
  else if (result === "next_open") setCard("Almost there", "Quit co-sheep and open it again: the overlay starts with the next launch.");
}

/** setOptions rebuilds and reloads the window whenever options change, so
 * compare first and never set the same thing twice in a row. */
async function applyOverlayOptions(force = false): Promise<"applied" | "reloading" | "next_open" | "failed"> {
  try {
    const { applied } = await desktop.window.getOptions();
    if (applied?.frame === false) return "applied";
  } catch {
    // Fall through and try to set them.
  }
  const lastTry = backend.load<number>("overlay-set-at", 0);
  if (!force && Date.now() - lastTry < 20_000) return "failed"; // a reload loop guard
  backend.save("overlay-set-at", Date.now());
  try {
    const r = await desktop.window.setOptions(OVERLAY_OPTIONS);
    if (r?.reloading) return "reloading";
    return r?.applied === "now" ? "applied" : "next_open";
  } catch {
    return "failed";
  }
}

async function enterOverlay() {
  finishBoot("overlay");
  setDockMargin(2);
  closePanel();
  try {
    const displays: Any[] = await desktop.screen.getAllDisplays();
    const b = await desktop.window.getBounds();
    const cx = b.x + b.width / 2;
    const cy = b.y + b.height / 2;
    const inside = (r: Any) => cx >= r.x && cx < r.x + r.width && cy >= r.y && cy < r.y + r.height;
    const display = displays.find((d) => inside(d.bounds)) ?? displays[0];
    if (display) {
      await desktop.window.setBounds(display.workArea);
      overlayOrigin = { x: display.workArea.x, y: display.workArea.y };
    }
  } catch {
    // Keep whatever size the window has.
  }
  refreshBounds();
  setInterval(refreshBounds, 3000);
  ignoring = null;
  setInteractive(false);
  desktop.window.setVisibleOnAllWorkspaces?.(true, { visibleOnFullScreen: true }).catch(() => {});
  await setUpTray();
  refreshMenus();
  pollCursor();
  flock.mainBubble.show(
    trayUp
      ? "We're out! Find me in the menu bar. Right-click me to talk."
      : "We're out! Right-click me to talk, or a friend for the menu.",
    7000,
  );
}

async function leaveOverlay() {
  backend.save("window-mode", true);
  try {
    const r = await desktop.window.setOptions(WINDOW_OPTIONS);
    if (!r?.reloading) location.reload();
  } catch {
    location.reload();
  }
}

function refreshBounds() {
  desktop?.window
    ?.getBounds()
    .then((b: Any) => {
      windowBounds = b;
      overlayOrigin = { x: b.x, y: b.y };
    })
    .catch(() => {});
}

// Click-through: the window ignores the mouse except over a sheep or an
// open panel/bubble. Moves keep arriving (forward: true) to decide that.
let ignoring: boolean | null = null;

function setInteractive(on: boolean) {
  if (mode !== "overlay" || !desktop?.window) return;
  const ignore = !on;
  if (ignore === ignoring) return;
  ignoring = ignore;
  desktop.window.setIgnoreMouseEvents(ignore, { forward: true }).catch(() => {});
}

function updateClickThrough(x: number, y: number) {
  if (mode !== "overlay") return;
  if (dragTarget) return setInteractive(true);
  if (x < 0 || y < 0) return setInteractive(false);
  if (flock.hitTest(x, y)) return setInteractive(true);
  const hit = document.elementFromPoint(x, y);
  setInteractive(Boolean(hit?.closest(".interactive, .input-bubble")));
}

// Forwarded moves can stall (another app grabbed the mouse); poll the cursor
// as a backstop so hover-to-pet and click-through stay right.
function pollCursor() {
  let busy = false;
  setInterval(async () => {
    if (busy || mode !== "overlay" || !desktop?.screen) return;
    if (performance.now() - lastRealMoveAt < 400) return;
    busy = true;
    try {
      const p = await desktop.screen.getCursorScreenPoint();
      const x = p.x - (windowBounds.width ? windowBounds.x : overlayOrigin.x);
      const y = p.y - (windowBounds.width ? windowBounds.y : overlayOrigin.y);
      if (!dragTarget) hover(x, y);
      updateClickThrough(x, y);
    } catch {
      // Overlay permission gone: nothing to poll.
    } finally {
      busy = false;
    }
  }, 150);
}

// ─── Icons drawn from the sprite ────────────────────────────────────────────

const idleSprite = new Image();
idleSprite.src = SPRITE_URLS.idle;

async function spriteReady(): Promise<HTMLImageElement> {
  if (!idleSprite.complete || !idleSprite.naturalWidth) await idleSprite.decode();
  return idleSprite;
}

async function drawAppIcon(): Promise<string> {
  const img = await spriteReady();
  const c = document.createElement("canvas");
  c.width = c.height = 256;
  const g = c.getContext("2d")!;
  const grad = g.createLinearGradient(0, 0, 0, 256);
  grad.addColorStop(0, "#9cc5e8");
  grad.addColorStop(0.62, "#cfe6f2");
  grad.addColorStop(0.63, "#8cc47a");
  grad.addColorStop(1, "#5e9d57");
  g.beginPath();
  g.roundRect(20, 20, 216, 216, 50);
  g.fillStyle = grad;
  g.fill();
  g.save();
  g.clip();
  g.imageSmoothingEnabled = false;
  g.drawImage(img, 0, 0, 32, 32, 32, 38, 192, 192);
  g.restore();
  g.lineWidth = 6;
  g.strokeStyle = "#1a1a2e";
  g.stroke();
  return c.toDataURL("image/png");
}

let trayIconCache: string | null = null;
function trayIcon(): string {
  if (trayIconCache) return trayIconCache;
  const c = document.createElement("canvas");
  c.width = c.height = 32;
  const g = c.getContext("2d")!;
  g.imageSmoothingEnabled = false;
  if (idleSprite.complete && idleSprite.naturalWidth) g.drawImage(idleSprite, 0, 0, 32, 32, 0, 0, 32, 32);
  // Template image: alpha only. Wool half-strength, face and legs full.
  const data = g.getImageData(0, 0, 32, 32);
  const p = data.data;
  let any = false;
  for (let i = 0; i < p.length; i += 4) {
    const a = p[i + 3];
    if (!a) continue;
    any = true;
    const light = (p[i] + p[i + 1] + p[i + 2]) / 3 > 140;
    p[i] = p[i + 1] = p[i + 2] = 0;
    p[i + 3] = light ? Math.round(a * 0.45) : a;
  }
  if (!any) {
    g.fillStyle = "#000";
    g.beginPath();
    g.ellipse(14, 18, 11, 8, 0, 0, Math.PI * 2);
    g.fill();
    return c.toDataURL("image/png");
  }
  g.putImageData(data, 0, 0);
  trayIconCache = c.toDataURL("image/png");
  return trayIconCache;
}

// ─── Control panel (ex-settings / friends / wardrobe / relationships windows)

type Tab = "sheep" | "friends" | "wardrobe" | "brain";
let panelTab: Tab | null = null;
let wardrobeWho = "main";
let pendingConfirm: string | null = null;

function openPanel(tab: Tab) {
  panelTab = tab;
  const panel = $("#panel");
  panel.hidden = false;
  renderPanel();
  if (mode === "overlay") {
    desktop?.window?.show?.().catch(() => {});
  }
}

function closePanel() {
  panelTab = null;
  $("#panel").hidden = true;
  pendingConfirm = null;
  updateClickThrough(lastMove.x, lastMove.y);
}

function togglePanel() {
  if (panelTab) closePanel();
  else openPanel("sheep");
}

function wirePanel() {
  const panel = $("#panel");
  for (const btn of panel.querySelectorAll<HTMLButtonElement>("[data-tab]")) {
    btn.addEventListener("click", () => {
      panelTab = btn.dataset.tab as Tab;
      pendingConfirm = null;
      renderPanel();
    });
  }
  $("#panel-close").addEventListener("click", closePanel);
  const head = $("#panel-head");
  head.addEventListener("pointerdown", (e) => {
    if ((e.target as Element).closest("button")) return;
    const r = panel.getBoundingClientRect();
    const dx = e.clientX - r.left;
    const dy = e.clientY - r.top;
    head.setPointerCapture(e.pointerId);
    const move = (ev: PointerEvent) => {
      panel.style.left = `${Math.max(8 - r.width / 2, Math.min(ev.clientX - dx, viewW - 60))}px`;
      panel.style.top = `${Math.max(8, Math.min(ev.clientY - dy, viewH - 60))}px`;
      panel.style.transform = "none";
    };
    const up = () => {
      head.removeEventListener("pointermove", move);
      head.removeEventListener("pointerup", up);
    };
    head.addEventListener("pointermove", move);
    head.addEventListener("pointerup", up);
  });
}

function field(label: string, control: HTMLElement, hint?: string): HTMLElement {
  const id = control.id;
  return el(
    "div",
    { className: "field" },
    el("label", { htmlFor: id }, label),
    control,
    hint ? el("p", { className: "hint" }, hint) : null,
  );
}

function select<T extends string>(id: string, options: Array<[T, string]>, value: T, onChange: (v: T) => void) {
  const s = el("select", { id });
  for (const [v, label] of options) s.append(el("option", { value: v, selected: v === value }, label));
  s.addEventListener("change", () => onChange(s.value as T));
  return s;
}

function checkbox(id: string, label: string, checked: boolean, onChange: (v: boolean) => void) {
  const input = el("input", { id, type: "checkbox", checked });
  input.addEventListener("change", () => onChange(input.checked));
  return el("label", { className: "check", htmlFor: id }, input, el("span", {}, label));
}

function renderPanel() {
  if (!panelTab) return;
  for (const btn of document.querySelectorAll<HTMLButtonElement>("#panel [data-tab]")) {
    btn.setAttribute("aria-selected", String(btn.dataset.tab === panelTab));
  }
  const body = $("#panel-body");
  const render = { sheep: renderSheepTab, friends: renderFriendsTab, wardrobe: renderWardrobeTab, brain: renderBrainTab }[panelTab];
  body.replaceChildren(...render());
}

function renderSheepTab(): HTMLElement[] {
  const name = el("input", { id: "set-name", type: "text", value: settings.name, maxLength: 24, autocomplete: "off" });
  name.addEventListener("change", () => {
    const v = name.value.trim().slice(0, 24) || "Sheep";
    settings = backend.updateSettings({ name: v });
    flock.main.name = v;
    flock.mainBubble.show(`${v}. Yes. I suppose that works.`, 4000);
    refreshMenus();
  });

  const intervals: Array<[string, string]> = [["30", "30 seconds"], ["60", "1 minute"], ["150", "2½ minutes"], ["300", "5 minutes"], ["600", "10 minutes"]];
  const brain = aiDeclined
    ? "Claude: you declined in this view, so the sheep uses its own lines until the page reloads."
    : sample
      ? "Claude: Chat and Comment now ask Claude, on your Claude usage. You're asked once first."
      : "Claude isn't reachable from here, so chat and remarks use the sheep's own lines.";

  const forget = el("button", { type: "button", className: pendingConfirm === "forget" ? "btn danger" : "btn ghost" },
    pendingConfirm === "forget" ? "Yes, forget everything" : "Forget everything…");
  forget.addEventListener("click", () => {
    if (pendingConfirm !== "forget") {
      pendingConfirm = "forget";
      return renderPanel();
    }
    pendingConfirm = null;
    backend.forgetEverything();
    flock.mainBubble.show("Who are you? Where am I? ...Baa.", 5000);
    renderPanel();
  });

  return [
    el("div", { className: "grid2" },
      field("Name", name),
      field("Personality", select("set-personality", PERSONALITIES.map((p) => [p, label(p)]), settings.personality, (v) => {
        settings = backend.updateSettings({ personality: v });
      })),
    ),
    el("div", { className: "grid2" },
      field("Language", select("set-language", backend.LANGUAGES.map((l) => [l, l]), settings.language, (v) => {
        settings = backend.updateSettings({ language: v });
      }), "What Claude answers in. The built-in lines are English."),
      field("Remarks every", select("set-interval", intervals, String(settings.comment_interval_s), (v) => {
        settings = backend.updateSettings({ comment_interval_s: Number(v) });
        scheduleRemark();
      })),
    ),
    el("div", { className: "checks" },
      checkbox("set-paused", "Pause commentary", settings.paused, (v) => {
        settings = backend.updateSettings({ paused: v });
        refreshMenus();
      }),
      checkbox("set-breaks", "Break reminders after 45 minutes", settings.break_reminders, (v) => {
        settings = backend.updateSettings({ break_reminders: v });
        breakReminder.setEnabled(v);
      }),
    ),
    el("div", { className: "grid2" },
      field("Easter", select("set-easter", [["auto", "Easter week"], ["on", "Always"], ["off", "Off"]], settings.easter_mode, (v) => {
        settings = backend.updateSettings({ easter_mode: v });
        flock.setEasterMode(v);
      })),
      field("Summer", select("set-summer", [["auto", "June to August"], ["on", "Always"], ["off", "Off"]], settings.summer_mode, (v) => {
        settings = backend.updateSettings({ summer_mode: v });
        flock.setSummerMode(v);
      })),
    ),
    el("p", { className: "note" }, brain),
    el("div", { className: "row-end" }, forget),
  ];
}

function label(p: string): string {
  return p === "passive-aggressive" ? "Passive-aggressive" : p[0].toUpperCase() + p.slice(1);
}

let newFriend = { name: "", color: "pink" as FriendColor, personality: "wholesome" as FriendPersonality };

function renderFriendsTab(): HTMLElement[] {
  const friends = backend.getFriends();
  const rows: HTMLElement[] = [];
  rows.push(friendRow("good_colleague", "Good Colleague", "#4a90d9", "Snarky, Norwegian, always here", null));
  for (const f of friends) {
    rows.push(friendRow(f.id, f.name, COLOR_HEX[f.color] ?? "#e94560", label(f.personality ?? "wholesome"), f));
  }

  const out: HTMLElement[] = [el("ul", { className: "friend-list" }, ...rows)];

  if (friends.length >= MAX_FRIENDS) {
    out.push(el("p", { className: "note" }, "The flock is full: four friends plus Good Colleague. Remove one to make room."));
    return out;
  }
  const name = el("input", { id: "nf-name", type: "text", value: newFriend.name, maxLength: 20, placeholder: "Fluffy", autocomplete: "off" });
  name.addEventListener("input", () => (newFriend.name = name.value));
  const swatches = el("div", { className: "swatches", role: "radiogroup" });
  swatches.setAttribute("aria-label", "Colour");
  for (const c of COLORS) {
    const b = el("button", { type: "button", className: "swatch", title: label(c) });
    b.style.setProperty("--sw", COLOR_HEX[c]);
    b.setAttribute("role", "radio");
    b.setAttribute("aria-checked", String(newFriend.color === c));
    b.setAttribute("aria-label", label(c));
    b.addEventListener("click", () => {
      newFriend.color = c;
      renderPanel();
    });
    swatches.append(b);
  }
  const add = el("button", { type: "button", className: "btn" }, "Add friend");
  add.addEventListener("click", () => {
    const n = newFriend.name.trim().slice(0, 20) || pick(["Fluffy", "Woolbert", "Baarbara", "Lambda", "Shaun-Paul", "Mutton"]);
    const config: FriendConfig = {
      id: `friend_${Date.now().toString(36)}`,
      name: n,
      color: newFriend.color,
      personality: newFriend.personality,
      accessories: [],
      scale: Math.round((0.85 + Math.random() * 0.3) * 100) / 100,
    };
    backend.saveFriend(config);
    flock.addFriend(config);
    newFriend = { name: "", color: pick(COLORS), personality: newFriend.personality };
    renderPanel();
  });
  out.push(
    el("h3", { className: "section" }, "Add a friend"),
    el("div", { className: "grid2" },
      field("Name", name),
      field("Personality", select("nf-personality", PERSONALITIES.map((p) => [p, label(p)]), newFriend.personality, (v) => {
        newFriend.personality = v;
      })),
    ),
    el("div", { className: "field" }, el("span", { className: "label" }, "Colour"), swatches),
    el("div", { className: "row-end" }, add),
  );
  return out;
}

function friendRow(id: string, name: string, color: string, sub: string, config: FriendConfig | null): HTMLElement {
  const mood = backend.moodOf(id);
  const li = el("li", { className: "friend" });
  const dot = el("span", { className: "dot" });
  dot.style.background = color;
  li.append(
    dot,
    el("div", { className: "friend-text" }, el("strong", {}, name), el("span", { className: "sub" }, sub)),
    mood ? el("span", { className: `chip mood-${mood}` }, mood) : el("span"),
  );
  const actions = el("div", { className: "friend-actions" });
  if (config) {
    const dress = el("button", { type: "button", className: "btn ghost small" }, "Dress");
    dress.addEventListener("click", () => {
      wardrobeWho = id;
      openPanel("wardrobe");
    });
    const confirmKey = `remove:${id}`;
    const remove = el("button", { type: "button", className: `btn small ${pendingConfirm === confirmKey ? "danger" : "ghost"}` },
      pendingConfirm === confirmKey ? "Remove?" : "Remove");
    remove.addEventListener("click", () => {
      if (pendingConfirm !== confirmKey) {
        pendingConfirm = confirmKey;
        return renderPanel();
      }
      pendingConfirm = null;
      flock.removeFriend(id);
      drama.onFriendRemoved(id);
      backend.deleteFriend(id);
      renderPanel();
    });
    actions.append(dress, remove);
  }
  li.append(actions);
  return li;
}

function tintedFrame(tint?: string): HTMLCanvasElement {
  const c = document.createElement("canvas");
  c.width = c.height = 32;
  const g = c.getContext("2d")!;
  g.imageSmoothingEnabled = false;
  if (idleSprite.complete && idleSprite.naturalWidth) g.drawImage(idleSprite, 0, 0, 32, 32, 0, 0, 32, 32);
  if (tint) {
    g.globalCompositeOperation = "source-atop";
    g.fillStyle = tint;
    g.fillRect(0, 0, 32, 32);
  }
  return c;
}

function sheepPreview(cssSize: number, ids: string[], tint?: string, focusId?: string): HTMLCanvasElement {
  const c = document.createElement("canvas");
  const scale = dpr;
  c.width = c.height = Math.round(cssSize * scale);
  c.style.width = c.style.height = `${cssSize}px`;
  const g = c.getContext("2d")!;
  g.setTransform(scale, 0, 0, scale, 0, 0);
  g.imageSmoothingEnabled = false;
  const size = Math.round(cssSize * 0.66);
  const x = Math.round((cssSize - size) / 2);
  const y = Math.round(cssSize - size - cssSize * 0.04);
  g.drawImage(tintedFrame(tint), 0, 0, 32, 32, x, y, size, size);
  const overlay = createCompositeOverlay(focusId ? [focusId] : ids);
  try {
    overlay?.(g, x, y, size, true, "idle");
  } catch {
    // An accessory that can't draw at this size just doesn't show.
  }
  return c;
}

function renderWardrobeTab(): HTMLElement[] {
  const friends = backend.getFriends();
  if (wardrobeWho !== "main" && !friends.some((f) => f.id === wardrobeWho)) wardrobeWho = "main";
  const target = friends.find((f) => f.id === wardrobeWho) ?? null;
  const worn = target ? target.accessories ?? [] : settings.accessories;
  const tint = target ? FRIEND_TINTS[target.color] : undefined;

  const who = select(
    "wr-who",
    [["main", settings.name] as [string, string], ...friends.map((f) => [f.id, f.name] as [string, string])],
    wardrobeWho,
    (v) => {
      wardrobeWho = v;
      renderPanel();
    },
  );

  const setWorn = (ids: string[]) => {
    if (target) {
      const updated = { ...target, accessories: ids };
      backend.saveFriend(updated);
      const entry = flock.getFriendEntry(target.id);
      if (entry) entry.sheep.drawOverlay = createCompositeOverlay(ids);
    } else {
      settings = backend.updateSettings({ accessories: ids });
      flock.main.drawOverlay = createCompositeOverlay(ids);
    }
    renderPanel();
  };

  const grid = el("div", { className: "wardrobe" });
  for (const def of getAccessoryDefs()) {
    const on = worn.includes(def.id);
    const b = el("button", { type: "button", className: "acc" });
    b.setAttribute("aria-pressed", String(on));
    b.append(sheepPreview(64, [], tint, def.id), el("span", {}, def.name));
    b.addEventListener("click", () => {
      setWorn(on ? worn.filter((i) => i !== def.id) : [...worn, def.id]);
    });
    grid.append(b);
  }

  const clear = el("button", { type: "button", className: "btn ghost small" }, "Take everything off");
  clear.addEventListener("click", () => setWorn([]));

  return [
    el("div", { className: "wardrobe-top" },
      sheepPreview(112, worn, tint),
      el("div", { className: "wardrobe-who" },
        field("Dressing", who),
        el("p", { className: "hint" }, worn.length ? `Wearing ${worn.length} item${worn.length === 1 ? "" : "s"}.` : "Wearing just wool."),
        worn.length ? clear : null,
      ),
    ),
    grid,
  ];
}

function renderBrainTab(): HTMLElement[] {
  const out: HTMLElement[] = [];
  const brains = backend.getBrains();
  const ids = flock.getCharacterIds().filter((id) => id !== "main" && brains[id]);

  out.push(el("h3", { className: "section" }, "Friends"));
  if (!ids.length) {
    out.push(el("p", { className: "note" }, "Nobody has memories yet. Give the flock a few minutes to talk."));
  }
  for (const id of ids) {
    const b = brains[id];
    const mood = backend.moodOf(id) ?? b.mood;
    const card = el("div", { className: "brain-card" },
      el("div", { className: "brain-head" }, el("strong", {}, b.name), el("span", { className: `chip mood-${mood}` }, mood)),
      el("p", { className: "sub" },
        `${b.stats.conversations_total} chats · petted ${b.stats.times_petted}× · ${b.stats.group_activities} group things · day ${b.stats.days_alive}`),
    );
    const rel = Object.entries(b.relationships).filter(([other]) => other === "main" || brains[other] || flock.getCharacter(other));
    if (rel.length) {
      const bars = el("ul", { className: "affinity" });
      for (const [other, v] of rel.sort((a, c) => c[1] - a[1])) {
        const bar = el("span", { className: "bar" });
        const pct = Math.max(0, Math.min(100, ((v + 5) / 25) * 100));
        bar.style.setProperty("--w", `${pct}%`);
        bar.classList.toggle("neg", v < 0);
        bars.append(el("li", {}, el("span", { className: "who" }, backend.nameOf(other)), bar, el("span", { className: "num" }, String(v))));
      }
      card.append(bars);
    }
    const mem = b.memories.slice(-3).reverse();
    if (mem.length) {
      card.append(el("ul", { className: "memories" }, ...mem.map((m) => el("li", {}, el("time", {}, clockTime(m.at)), " ", m.text))));
    }
    out.push(card);
  }

  const dramaState = backend.load<Any>("living:drama", null);
  const pairs = Object.entries((dramaState?.pairs ?? {}) as Record<string, { state: string; since: number }>)
    .filter(([, r]) => r.state !== "neutral");
  if (pairs.length) {
    out.push(el("h3", { className: "section" }, "Drama"));
    out.push(el("ul", { className: "plain" }, ...pairs.map(([key, r]) => {
      const [a, c] = key.split("|");
      const hours = Math.max(0, Math.round((Date.now() - r.since) / 3_600_000));
      return el("li", {}, el("strong", {}, `${backend.nameOf(a)} & ${backend.nameOf(c)}`), ` ${r.state.replace("_", " ")}`, el("span", { className: "sub" }, ` · ${hours ? `${hours} h` : "just now"}`));
    })));
  }

  const opinions = Object.entries(backend.getOpinions());
  out.push(el("h3", { className: "section" }, `What ${settings.name} thinks of you`));
  out.push(opinions.length
    ? el("ul", { className: "plain" }, ...opinions.slice(-8).reverse().map(([k, o]) =>
      el("li", {}, el("code", {}, k), ` ${o.text}`, el("span", { className: "sub" }, ` · ${o.times_seen}×`))))
    : el("p", { className: "note" }, "No opinions yet. They form when you chat or press Comment now."));

  const tallies = Object.entries(backend.getTallies());
  if (tallies.length) {
    out.push(el("h3", { className: "section" }, "Today"));
    out.push(el("div", { className: "chips" }, ...tallies.map(([k, v]) => el("span", { className: "chip" }, `${k} ${v}`))));
  }
  return out;
}

// ─── Go ─────────────────────────────────────────────────────────────────────

wirePanel();
boot();

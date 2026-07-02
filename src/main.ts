import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Sheep } from "./sheep";
import { Flock } from "./flock";
import { InputBubble } from "./input-bubble";
import { BreakReminder } from "./break-reminder";
import { createCompositeOverlay } from "./accessories";
import { FriendConfig } from "./types";
import { EasterStatsSnapshot } from "./easter-theme";
import "./styles.css";

let flock: Flock;
let canvas: HTMLCanvasElement;
let ctx: CanvasRenderingContext2D;
let lastTime = 0;

// Drag state
let isDragging = false;
let dragTarget: Sheep | null = null;
let dragOffsetX = 0;
let dragOffsetY = 0;

// Petting state
let hoverTarget: Sheep | null = null;
let hoverTimer = 0;
const PET_THRESHOLD = 2000; // ms of hovering before petting starts

// Chat input bubble
let chatBubble: InputBubble | null = null;

// Stampede detection
const mouseHistory: Array<{ x: number; y: number; time: number }> = [];
let lastStampedeTime = 0;
const STAMPEDE_COOLDOWN = 15000;
const STAMPEDE_SPEED_THRESHOLD = 3000; // px/s average speed
const STAMPEDE_SAMPLES = 10;
const STAMPEDE_MIN_REVERSALS = 3;

// Throttle bounds updates to Rust (~20fps)
let lastBoundsUpdate = 0;
const BOUNDS_UPDATE_INTERVAL = 50;

// Break reminders
const breakReminder = new BreakReminder();
let personality = "snarky";

async function init() {
  canvas = document.getElementById("sheep-canvas") as HTMLCanvasElement;
  ctx = canvas.getContext("2d")!;

  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight;
  ctx.imageSmoothingEnabled = false;

  console.log("[co-sheep] Canvas initialized:", canvas.width, "x", canvas.height);

  flock = new Flock(canvas.width, canvas.height);
  console.log("[co-sheep] Flock created with main sheep + Good Colleague");

  // Load settings (personality, break reminders, accessories)
  try {
    const settings = await invoke<{
      personality: string;
      break_reminders: boolean;
      accessories: string[];
      easter_mode: "auto" | "on" | "off";
      summer_mode: "auto" | "on" | "off";
    }>("get_settings");
    personality = settings.personality || "snarky";
    breakReminder.setEnabled(settings.break_reminders);
    flock.setEasterMode(settings.easter_mode || "auto");
    flock.setSummerMode(settings.summer_mode || "auto");
    if (settings.accessories && settings.accessories.length > 0) {
      flock.main.drawOverlay = createCompositeOverlay(settings.accessories);
    }
  } catch (e) {
    console.log("[co-sheep] Failed to load settings:", e);
  }

  try {
    const easterStats = await invoke<EasterStatsSnapshot>("get_easter_stats");
    flock.applyEasterStats(easterStats);
  } catch (e) {
    console.log("[co-sheep] Failed to load Easter stats:", e);
  }

  // Load additional saved friends
  try {
    const friends = await invoke<FriendConfig[]>("get_friends");
    for (const f of friends) {
      flock.addFriend(f);
    }
  } catch (e) {
    console.log("[co-sheep] No saved friends to load:", e);
  }

  // --- Weather polling ---
  pollWeather();
  setInterval(pollWeather, 5 * 60 * 1000); // every 5 min

  // --- Window position polling ---
  pollWindows();
  setInterval(pollWindows, 2000); // every 2s

  // --- Drag, toss, double-click, and petting handlers ---

  document.addEventListener("mousedown", (e) => {
    const target = flock.hitTest(e.clientX, e.clientY);
    if (target) {
      console.log(`[co-sheep] Grab ${target.id} at`, e.clientX, e.clientY);
      isDragging = true;
      dragTarget = target;
      dragOffsetX = e.clientX - target.x;
      dragOffsetY = e.clientY - target.y;
      // Clear petting state so hearts don't resume after release
      if (hoverTarget && hoverTarget !== target) hoverTarget.stopPetting();
      hoverTarget = null;
      hoverTimer = 0;
      target.grab();
      document.body.classList.add("dragging");
      invoke("set_dragging", { dragging: true });
    }
  });

  document.addEventListener("mousemove", (e) => {
    if (isDragging && dragTarget) {
      dragTarget.x = e.clientX - dragOffsetX;
      dragTarget.y = e.clientY - dragOffsetY;
    }
  });

  document.addEventListener("mouseup", () => {
    if (isDragging && dragTarget) {
      console.log(`[co-sheep] Release ${dragTarget.id}!`);
      isDragging = false;

      // Check for stacking first
      const stackTarget = flock.tryStack(dragTarget);
      if (stackTarget) {
        dragTarget.stackOn(stackTarget);
        flock.onSheepStacked(dragTarget, stackTarget);
      } else {
        dragTarget.release();
        // Check if trampoline was triggered
        if (dragTarget.state === "trampoline") {
          flock.onTrampolineStarted(dragTarget);
        }
      }

      dragTarget = null;
      document.body.classList.remove("dragging");
      invoke("set_dragging", { dragging: false });
    }
  });

  // Double-click: random quip + animation
  document.addEventListener("dblclick", (e) => {
    const target = flock.hitTest(e.clientX, e.clientY);
    if (target && !isDragging) {
      console.log(`[co-sheep] Double-click ${target.id}!`);
      target.resetActivity();
      const quip = flock.getQuip(target);
      const bubble = flock.getBubble(target);
      bubble.show(quip, 4000);
      const anims: Array<"bounce" | "spin" | "headshake" | "vibrate"> = [
        "bounce", "spin", "headshake", "vibrate",
      ];
      target.playAnimation(anims[Math.floor(Math.random() * anims.length)]);
      invoke("record_interaction", { interaction: `poked ${target.id}` });
    }
  });

  // Petting: track hover time over any sheep
  document.addEventListener("mousemove", (e) => {
    if (isDragging) return;
    const target = flock.hitTest(e.clientX, e.clientY);
    if (target) {
      if (hoverTarget !== target) {
        // Started hovering a new target — release the old one, or it
        // stays in "petting" forever (that state has no timeout)
        if (hoverTarget) hoverTarget.stopPetting();
        hoverTarget = target;
        hoverTimer = performance.now();
      } else if (
        performance.now() - hoverTimer > PET_THRESHOLD &&
        target.state !== "petting"
      ) {
        target.startPetting();
        const bubble = flock.getBubble(target);
        bubble.show("Zzzz... don't stop...", 3000);
        invoke("record_interaction", { interaction: `petted ${target.id}` });
        if (target.id !== "main") {
          invoke("record_friend_pet", { id: target.id }).catch(() => {});
        }
      }
    } else {
      if (hoverTarget) {
        hoverTarget.stopPetting();
        hoverTarget = null;
      }
    }
  });

  // Stampede detection: track rapid mouse shaking
  document.addEventListener("mousemove", (e) => {
    if (isDragging) return;

    const now = performance.now();
    mouseHistory.push({ x: e.clientX, y: e.clientY, time: now });
    if (mouseHistory.length > STAMPEDE_SAMPLES + 1) {
      mouseHistory.shift();
    }

    if (mouseHistory.length >= STAMPEDE_SAMPLES && now - lastStampedeTime > STAMPEDE_COOLDOWN) {
      let totalDist = 0;
      let reversals = 0;
      for (let i = 1; i < mouseHistory.length; i++) {
        const dx = mouseHistory[i].x - mouseHistory[i - 1].x;
        const dy = mouseHistory[i].y - mouseHistory[i - 1].y;
        totalDist += Math.sqrt(dx * dx + dy * dy);
        if (i >= 2) {
          const prevDx = mouseHistory[i - 1].x - mouseHistory[i - 2].x;
          if ((dx > 0 && prevDx < 0) || (dx < 0 && prevDx > 0)) reversals++;
        }
      }
      const elapsed = (mouseHistory[mouseHistory.length - 1].time - mouseHistory[0].time) / 1000;
      const speed = elapsed > 0 ? totalDist / elapsed : 0;

      if (speed > STAMPEDE_SPEED_THRESHOLD && reversals >= STAMPEDE_MIN_REVERSALS) {
        const centerX = mouseHistory[mouseHistory.length - 1].x;
        const centerY = mouseHistory[mouseHistory.length - 1].y;
        flock.triggerStampede(centerX, centerY);
        lastStampedeTime = now;
        mouseHistory.length = 0;
      }
    }
  });

  // File drop: any character can "eat" the file
  document.addEventListener("dragover", (e) => {
    e.preventDefault();
  });

  document.addEventListener("drop", (e) => {
    e.preventDefault();
    if (!e.dataTransfer?.files.length) return;
    const file = e.dataTransfer.files[0];
    // Check if dropped on a specific character, default to main sheep
    const target = flock.hitTest(e.clientX, e.clientY) ?? flock.main;
    const bubble = flock.getBubble(target);
    console.log(`[co-sheep] File dropped on ${target.id}:`, file.name, file.type);
    target.resetActivity();
    const comment = getFileComment(file);
    bubble.show(comment, 5000);
    target.playAnimation("bounce");
    invoke("record_interaction", { interaction: `fed a file to ${target.id}` });
  });

  // --- Right-click: open chat with main sheep ---
  document.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    const target = flock.hitTest(e.clientX, e.clientY);
    if (target && target.id === "main") {
      openChat();
    }
  });

  // --- Events ---
  listen("open-chat", () => {
    openChat();
  });

  listen<string>("naming-complete", async (event) => {
    const name = event.payload;
    console.log("[co-sheep] Naming complete:", name);
    const aiReady = await invoke<boolean>("check_ai_ready");
    if (aiReady) {
      flock.mainBubble.show(
        `Nice! I'm ${name} now. I can see everything. This is going to be fun. For me.`,
        6000,
      );
    } else {
      flock.mainBubble.show(
        `I'm ${name}! But my brain isn't working yet — enable Apple Intelligence in System Settings so I can think.`,
        8000,
      );
    }
  });

  // Friend management events
  listen<FriendConfig>("add-friend", (event) => {
    flock.addFriend(event.payload);
  });

  listen<string>("remove-friend", (event) => {
    flock.removeFriend(event.payload);
  });

  listen<{
    personality: string;
    break_reminders: boolean;
    easter_mode: "auto" | "on" | "off";
    summer_mode: "auto" | "on" | "off";
  }>("settings-changed", (event) => {
    personality = event.payload.personality || "snarky";
    breakReminder.setEnabled(event.payload.break_reminders);
    flock.setEasterMode(event.payload.easter_mode || "auto");
    flock.setSummerMode(event.payload.summer_mode || "auto");
  });

  // Capture moment event
  listen("capture-moment", () => {
    captureMoment();
  });

  // Accessories changed event (main sheep)
  listen("accessories-changed", async () => {
    try {
      const ids = await invoke<string[]>("get_accessories");
      flock.main.drawOverlay = createCompositeOverlay(ids);
    } catch (e) {
      console.error("[co-sheep] Failed to reload accessories:", e);
    }
  });

  // Friend accessories changed event
  listen<{ id: string; accessories: string[] }>("friend-accessories-changed", (event) => {
    const { id, accessories } = event.payload;
    const entry = flock.getFriendEntry(id);
    if (entry) {
      entry.sheep.drawOverlay = createCompositeOverlay(accessories);
    }
  });

  // --- Onboarding ---
  try {
    const needsOnboarding = await invoke<boolean>("check_onboarding");
    console.log("[co-sheep] Needs onboarding:", needsOnboarding);
    if (needsOnboarding) {
      console.log("[co-sheep] Will open naming window in 4s...");
      setTimeout(() => {
        console.log("[co-sheep] Opening naming window");
        invoke("open_naming_window");
      }, 4000);
    }
  } catch (e) {
    console.error("[co-sheep] Onboarding check failed:", e);
  }

  console.log("[co-sheep] Starting animation loop");
  requestAnimationFrame(gameLoop);
}

async function pollWeather() {
  try {
    const snapshot = await invoke<{ condition: string; temp_c: number | null } | null>(
      "get_weather_snapshot",
    );
    flock.setWeatherCondition(snapshot?.condition ?? null, snapshot?.temp_c ?? null);
  } catch (e) {
    console.log("[co-sheep] Weather poll failed:", e);
  }
}

async function pollWindows() {
  try {
    const platforms = await invoke<Array<{ x: number; y: number; w: number; h: number }>>("get_window_positions");
    flock.setWindowPlatforms(platforms);
  } catch (e) {
    // Window positions not available (command may not exist yet)
  }
}

async function captureMoment() {
  const sheep = flock.main;
  const size = sheep.displaySize;
  const padding = 20;
  const bubbleText = flock.mainBubble.currentText;
  const bubbleHeight = bubbleText ? 60 : 0;
  const totalW = size + padding * 2;
  const totalH = size + padding * 2 + bubbleHeight;

  const offscreen = document.createElement("canvas");
  offscreen.width = totalW;
  offscreen.height = totalH;
  const offCtx = offscreen.getContext("2d")!;
  offCtx.imageSmoothingEnabled = false;

  // Draw sheep centered on offscreen canvas
  const origX = sheep.x;
  const origY = sheep.y;
  sheep.x = padding;
  sheep.y = padding + bubbleHeight;
  sheep.draw(offCtx);
  sheep.x = origX;
  sheep.y = origY;

  // Draw speech bubble if text is visible
  if (bubbleText) {
    drawBubbleShape(offCtx, totalW / 2, padding + bubbleHeight - 5, bubbleText);
  }

  const imageData = offscreen.toDataURL("image/png");
  try {
    await invoke("save_moment", { imageData });
    flock.mainBubble.show("Moment captured! Saved to your Desktop.", 5000);
  } catch (e) {
    console.error("[co-sheep] Capture failed:", e);
    flock.mainBubble.show("Capture failed... baaad luck.", 4000);
  }
}

function drawBubbleShape(
  ctx: CanvasRenderingContext2D,
  cx: number,
  bottomY: number,
  text: string,
) {
  ctx.save();
  ctx.font = "12px 'Courier New', monospace";

  // Wrap text
  const maxLineW = 180;
  const words = text.split(" ");
  const lines: string[] = [];
  let currentLine = "";
  for (const word of words) {
    const test = currentLine ? currentLine + " " + word : word;
    if (ctx.measureText(test).width > maxLineW) {
      if (currentLine) lines.push(currentLine);
      currentLine = word;
    } else {
      currentLine = test;
    }
  }
  if (currentLine) lines.push(currentLine);

  const lineH = 16;
  const padX = 10;
  const padY = 8;
  const bubbleW = Math.min(maxLineW + padX * 2, 200);
  const bubbleH = lines.length * lineH + padY * 2;
  const bubbleX = cx - bubbleW / 2;
  const bubbleY = bottomY - bubbleH - 8;

  // Background
  ctx.fillStyle = "#1a1a2e";
  ctx.strokeStyle = "#e94560";
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.roundRect(bubbleX, bubbleY, bubbleW, bubbleH, 6);
  ctx.fill();
  ctx.stroke();

  // Tail
  ctx.fillStyle = "#1a1a2e";
  ctx.beginPath();
  ctx.moveTo(cx - 6, bubbleY + bubbleH);
  ctx.lineTo(cx, bubbleY + bubbleH + 8);
  ctx.lineTo(cx + 6, bubbleY + bubbleH);
  ctx.closePath();
  ctx.fill();
  ctx.strokeStyle = "#e94560";
  ctx.beginPath();
  ctx.moveTo(cx - 6, bubbleY + bubbleH);
  ctx.lineTo(cx, bubbleY + bubbleH + 8);
  ctx.lineTo(cx + 6, bubbleY + bubbleH);
  ctx.stroke();

  // Text
  ctx.fillStyle = "#eee";
  for (let i = 0; i < lines.length; i++) {
    ctx.fillText(lines[i], bubbleX + padX, bubbleY + padY + (i + 1) * lineH - 3);
  }
  ctx.restore();
}

function openChat() {
  if (chatBubble) return; // already open

  chatBubble = new InputBubble({
    promptText: "Talk to me...",
    placeholder: "Say something...",
    buttonText: "Send",
    onSubmit: async (text) => {
      chatBubble?.setLoading(true);
      try {
        await invoke("chat_with_sheep", { message: text });
        // Response arrives via sheep-commentary event on mainBubble
      } catch (e) {
        console.error("[co-sheep] Chat error:", e);
      }
      chatBubble?.destroy();
      chatBubble = null;
    },
    onClose: () => {
      chatBubble?.destroy();
      chatBubble = null;
    },
  });
  chatBubble.show();
  chatBubble.updatePosition(flock.main.x, flock.main.y, flock.main.displaySize);
}

function gameLoop(timestamp: number) {
  const dt = lastTime ? timestamp - lastTime : 16;
  lastTime = timestamp;

  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.imageSmoothingEnabled = false;

  flock.update(dt);
  flock.draw(ctx);

  // Break reminder check
  breakReminder.update(
    dt,
    flock.main.state,
    flock.mainBubble,
    personality,
    (anim) => {
      flock.main.playAnimation(anim);
      flock.echoBreakReminder();
    },
  );

  // Update chat bubble position if active
  if (chatBubble) {
    chatBubble.updatePosition(flock.main.x, flock.main.y, flock.main.displaySize);
  }

  // Report ALL bounds to Rust for cursor hit detection (throttled)
  if (timestamp - lastBoundsUpdate > BOUNDS_UPDATE_INTERVAL) {
    lastBoundsUpdate = timestamp;
    const bounds = flock.getAllBounds();
    invoke("update_sheep_bounds_multi", { bounds });
  }

  requestAnimationFrame(gameLoop);
}

function getFileComment(file: File): string {
  const ext = file.name.split(".").pop()?.toLowerCase() || "";
  const name = file.name;

  const comments: Record<string, string[]> = {
    pdf: [
      `A PDF? *chews* Dry.`,
      `"${name}"... riveting literature, I'm sure.`,
      `*nibbles corner* Tastes like bureaucracy.`,
    ],
    png: [
      `Ooh, a picture! *munches* Not bad.`,
      `Is this your idea of art? Bold choice.`,
      `*examines pixels* I've seen better.`,
    ],
    jpg: [
      `A JPEG? The compression! My taste buds!`,
      `*squints at artifacts* Needs more pixels.`,
    ],
    gif: [
      `A GIF! Finally, some entertainment.`,
      `*watches loop 47 times* Still funny.`,
    ],
    mp3: [
      `Music? My ears are made of wool, but I'll try.`,
      `*bobs head* Not baaad.`,
    ],
    mp4: [
      `A video? I don't have that kind of attention span.`,
      `*stares* Is this what you watch instead of working?`,
    ],
    js: [
      `JavaScript? *gags* At least it's not PHP.`,
      `*reads code* I have opinions. None of them good.`,
    ],
    ts: [
      `TypeScript! A sheep of culture, your human.`,
      `*types checked* ...mostly.`,
    ],
    rs: [
      `Rust! Now we're talking. *happy sheep noises*`,
      `*borrows and returns* The borrow checker approves.`,
    ],
    py: [
      `Python? *hisses* Snakes are NOT my friends.`,
      `Significant whitespace? In THIS economy?`,
    ],
    zip: [
      `*swallows whole* That was a lot to digest.`,
      `A zip file? I'm not opening that. I'm a sheep, not a bomb squad.`,
    ],
    exe: [
      `An exe? I'm not clicking that and neither should you.`,
      `*backs away slowly*`,
    ],
    md: [
      `Markdown! My diary format of choice.`,
      `*reads* Wait, is this about me?`,
    ],
    txt: [
      `Plain text. How refreshingly boring.`,
      `*reads entire thing in 0.3 seconds* Meh.`,
    ],
  };

  const pool = comments[ext] || [
    `A .${ext} file? Never heard of it. *chews anyway*`,
    `*sniffs ${name}* Smells like work.`,
    `You're feeding me "${name}"? I have standards. Low ones, but still.`,
  ];

  return pool[Math.floor(Math.random() * pool.length)];
}

window.addEventListener("resize", () => {
  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight;
  ctx.imageSmoothingEnabled = false;
  flock.updateScreenSize(canvas.width, canvas.height);
});

init();

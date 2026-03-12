import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Sheep } from "./sheep";
import { SpeechBubble } from "./speech-bubble";
import "./styles.css";

let sheep: Sheep;
let speechBubble: SpeechBubble;
let canvas: HTMLCanvasElement;
let ctx: CanvasRenderingContext2D;
let lastTime = 0;

// Drag state
let isDragging = false;
let dragOffsetX = 0;
let dragOffsetY = 0;

// Throttle bounds updates to Rust (~20fps)
let lastBoundsUpdate = 0;
const BOUNDS_UPDATE_INTERVAL = 50;

async function init() {
  canvas = document.getElementById("sheep-canvas") as HTMLCanvasElement;
  ctx = canvas.getContext("2d")!;

  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight;
  ctx.imageSmoothingEnabled = false;

  console.log("[co-sheep] Canvas initialized:", canvas.width, "x", canvas.height);

  sheep = new Sheep(canvas.width, canvas.height);
  speechBubble = new SpeechBubble();
  speechBubble.onAnimation = (anim) => {
    console.log("[co-sheep] Triggering animation from AI:", anim);
    sheep.playAnimation(anim);
  };
  console.log("[co-sheep] Sheep and speech bubble created");

  // --- Drag-and-drop handlers ---
  // These only fire when the Rust cursor tracker disables click-through
  // (i.e. when the cursor is hovering over the sheep).
  document.addEventListener("mousedown", (e) => {
    if (sheep.hitTest(e.clientX, e.clientY)) {
      console.log("[co-sheep] Grab! at", e.clientX, e.clientY);
      isDragging = true;
      dragOffsetX = e.clientX - sheep.x;
      dragOffsetY = e.clientY - sheep.y;
      sheep.grab();
      document.body.classList.add("dragging");
      invoke("set_dragging", { dragging: true });
    }
  });

  document.addEventListener("mousemove", (e) => {
    if (isDragging) {
      sheep.x = e.clientX - dragOffsetX;
      sheep.y = e.clientY - dragOffsetY;
    }
  });

  document.addEventListener("mouseup", () => {
    if (isDragging) {
      const aboveGround = sheep.y < sheep.groundY - 10;
      console.log(
        "[co-sheep] Release! aboveGround:", aboveGround,
        "y:", Math.round(sheep.y), "groundY:", Math.round(sheep.groundY),
      );
      isDragging = false;
      sheep.release();
      document.body.classList.remove("dragging");
      invoke("set_dragging", { dragging: false });
    }
  });

  // --- Events ---
  listen<string>("naming-complete", async (event) => {
    const name = event.payload;
    console.log("[co-sheep] Naming complete:", name);
    const hasKey = await invoke<boolean>("check_api_key");
    if (hasKey) {
      speechBubble.show(
        `Nice! I'm ${name} now. I can see everything. This is going to be fun. For me.`,
        6000,
      );
    } else {
      speechBubble.show(
        `I'm ${name}! But I can't see your screen yet. Set ANTHROPIC_API_KEY in your environment and restart me!`,
        8000,
      );
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

function gameLoop(timestamp: number) {
  const dt = lastTime ? timestamp - lastTime : 16;
  lastTime = timestamp;

  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.imageSmoothingEnabled = false;

  sheep.update(dt);
  sheep.draw(ctx);

  speechBubble.updatePosition(sheep.x, sheep.y, sheep.displaySize);

  // Report sheep bounds to Rust for cursor hit detection (throttled)
  if (timestamp - lastBoundsUpdate > BOUNDS_UPDATE_INTERVAL) {
    lastBoundsUpdate = timestamp;
    const pad = 12;
    invoke("update_sheep_bounds", {
      x: sheep.x - pad,
      y: sheep.y - pad,
      w: sheep.displaySize + pad * 2,
      h: sheep.displaySize + pad * 2,
    });
  }

  requestAnimationFrame(gameLoop);
}

window.addEventListener("resize", () => {
  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight;
});

init();

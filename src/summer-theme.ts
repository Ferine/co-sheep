import { SheepState } from "./types";

type SummerMode = "auto" | "on" | "off";

interface Sunflower {
  x: number; // fraction of screen width
  y: number; // fraction of screen height
  size: number;
  swaySpeed: number;
  swayOffset: number;
}

interface Butterfly {
  x: number;
  y: number;
  targetX: number;
  targetY: number;
  wingPhase: number;
  color: string;
  retargetTimer: number;
}

interface Seed {
  x: number;
  y: number;
  vx: number;
  vy: number;
  size: number;
  swayOffset: number;
}

const BUTTERFLY_COLORS = ["#FF8C42", "#FFD23F", "#F26CA7", "#7FB5FF", "#B8E986"];

const SUNFLOWER_SPOTS = [
  { x: 0.04, y: 0.965 },
  { x: 0.115, y: 0.975 },
  { x: 0.24, y: 0.96 },
  { x: 0.41, y: 0.975 },
  { x: 0.58, y: 0.962 },
  { x: 0.72, y: 0.975 },
  { x: 0.86, y: 0.958 },
  { x: 0.955, y: 0.972 },
];

const BUTTERFLY_COUNT = 4;
const SEED_COUNT = 10;

/// Temperatures at/above this (°C) count as summer weather
const SUMMER_TEMP_THRESHOLD = 18;
const ACTIVE_REFRESH_INTERVAL_MS = 60000;

/** June through August (northern hemisphere) */
export function isSummerSeason(): boolean {
  const month = new Date().getMonth(); // 0-based
  return month >= 5 && month <= 7;
}

/**
 * Summer event: a sun with slowly turning rays, sunflowers along the
 * bottom, butterflies that drift toward calm sheep, and floating seeds.
 * Activates automatically during summer months when the weather is
 * actually summery (clear and warm), or via the settings override.
 */
export class SummerTheme {
  private sunflowers: Sunflower[] = [];
  private butterflies: Butterfly[] = [];
  private seeds: Seed[] = [];
  private sheepPositions: Array<{ x: number; y: number; state: SheepState }> = [];
  private screenWidth: number;
  private screenHeight: number;
  private time = 0;
  private activeRefreshTimer = 0;
  private modeOverride: SummerMode = "auto";
  private weatherCondition: string | null = null;
  private weatherTempC: number | null = null;
  active = false;

  constructor(screenWidth: number, screenHeight: number) {
    this.screenWidth = screenWidth;
    this.screenHeight = screenHeight;
    this.refreshActiveState();
  }

  setModeOverride(mode: SummerMode = "auto") {
    this.modeOverride = mode;
    this.refreshActiveState();
  }

  /** Feed the latest weather poll — this is what triggers the event */
  setWeather(condition: string | null, tempC: number | null) {
    this.weatherCondition = condition;
    this.weatherTempC = tempC;
    this.refreshActiveState();
  }

  updateScreenSize(w: number, h: number) {
    this.screenWidth = w;
    this.screenHeight = h;
    if (this.active) this.spawnDecorations();
  }

  /** Clear skies and warm enough — or no weather configured, season decides */
  private weatherLooksSummery(): boolean {
    if (this.weatherCondition === null) return true;
    if (this.weatherCondition !== "clear") return false;
    return this.weatherTempC === null || this.weatherTempC >= SUMMER_TEMP_THRESHOLD;
  }

  private refreshActiveState() {
    const wasActive = this.active;
    if (this.modeOverride === "on") {
      this.active = true;
    } else if (this.modeOverride === "off") {
      this.active = false;
    } else {
      this.active = isSummerSeason() && this.weatherLooksSummery();
    }

    if (this.active && !wasActive) {
      this.spawnDecorations();
      console.log("[co-sheep] Summer event activated ☀");
    } else if (!this.active && wasActive) {
      this.sunflowers = [];
      this.butterflies = [];
      this.seeds = [];
      console.log("[co-sheep] Summer event deactivated");
    }
  }

  private spawnDecorations() {
    this.sunflowers = SUNFLOWER_SPOTS.map((spot) => ({
      x: spot.x,
      y: spot.y,
      size: 26 + Math.random() * 14,
      swaySpeed: 0.4 + Math.random() * 0.5,
      swayOffset: Math.random() * Math.PI * 2,
    }));

    this.butterflies = [];
    for (let i = 0; i < BUTTERFLY_COUNT; i++) {
      this.butterflies.push(this.spawnButterfly());
    }

    this.seeds = [];
    for (let i = 0; i < SEED_COUNT; i++) {
      this.seeds.push(this.spawnSeed(true));
    }
  }

  private spawnButterfly(): Butterfly {
    return {
      x: Math.random() * this.screenWidth,
      y: this.screenHeight * (0.4 + Math.random() * 0.45),
      targetX: Math.random() * this.screenWidth,
      targetY: this.screenHeight * (0.4 + Math.random() * 0.45),
      wingPhase: Math.random() * Math.PI * 2,
      color: BUTTERFLY_COLORS[Math.floor(Math.random() * BUTTERFLY_COLORS.length)],
      retargetTimer: 1000 + Math.random() * 4000,
    };
  }

  private spawnSeed(anywhere: boolean): Seed {
    return {
      x: anywhere ? Math.random() * this.screenWidth : -10,
      y: anywhere
        ? Math.random() * this.screenHeight * 0.8
        : this.screenHeight * (0.3 + Math.random() * 0.5),
      vx: 8 + Math.random() * 14,
      vy: -(2 + Math.random() * 6),
      size: 2 + Math.random() * 2,
      swayOffset: Math.random() * Math.PI * 2,
    };
  }

  update(dt: number, sheepPositions: Array<{ x: number; y: number; state: SheepState }>) {
    this.time += dt;
    this.sheepPositions = sheepPositions;

    // Season/weather can flip mid-session (sunset poll, month rollover)
    this.activeRefreshTimer += dt;
    if (this.activeRefreshTimer >= ACTIVE_REFRESH_INTERVAL_MS) {
      this.activeRefreshTimer = 0;
      this.refreshActiveState();
    }

    if (!this.active) return;

    this.updateButterflies(dt);
    this.updateSeeds(dt);
  }

  private updateButterflies(dt: number) {
    const dtSec = dt / 1000;
    for (const b of this.butterflies) {
      b.wingPhase += dtSec * 14;
      b.retargetTimer -= dt;

      if (b.retargetTimer <= 0) {
        b.retargetTimer = 2000 + Math.random() * 5000;
        // Sometimes visit a resting sheep, otherwise wander
        const calm = this.sheepPositions.filter(
          (s) => s.state === "sit" || s.state === "idle" || s.state === "idle_sleep" || s.state === "sleep",
        );
        if (calm.length > 0 && Math.random() < 0.45) {
          const sheep = calm[Math.floor(Math.random() * calm.length)];
          b.targetX = sheep.x + 30 + Math.random() * 40;
          b.targetY = sheep.y - 20 - Math.random() * 30;
        } else {
          b.targetX = Math.random() * this.screenWidth;
          b.targetY = this.screenHeight * (0.35 + Math.random() * 0.5);
        }
      }

      // Ease toward target with a flutter wobble
      const dx = b.targetX - b.x;
      const dy = b.targetY - b.y;
      b.x += dx * dtSec * 0.9 + Math.sin(b.wingPhase * 0.7) * 22 * dtSec;
      b.y += dy * dtSec * 0.9 + Math.cos(b.wingPhase * 0.5) * 16 * dtSec;
    }
  }

  private updateSeeds(dt: number) {
    const dtSec = dt / 1000;
    for (let i = 0; i < this.seeds.length; i++) {
      const s = this.seeds[i];
      s.x += (s.vx + Math.sin(this.time / 900 + s.swayOffset) * 6) * dtSec;
      s.y += s.vy * dtSec;
      if (s.x > this.screenWidth + 15 || s.y < -15) {
        this.seeds[i] = this.spawnSeed(false);
      }
    }
  }

  /** Sun and warm glow — drawn behind everything */
  drawBackground(ctx: CanvasRenderingContext2D, w: number, _h: number) {
    if (!this.active) return;

    const sunX = w * 0.88;
    const sunY = 90;
    const sunR = 34;

    ctx.save();

    // Soft warm halo
    const glow = ctx.createRadialGradient(sunX, sunY, sunR * 0.5, sunX, sunY, sunR * 4);
    glow.addColorStop(0, "rgba(255, 214, 90, 0.30)");
    glow.addColorStop(1, "rgba(255, 214, 90, 0)");
    ctx.fillStyle = glow;
    ctx.fillRect(sunX - sunR * 4, sunY - sunR * 4, sunR * 8, sunR * 8);

    // Slowly turning rays
    const rotation = this.time / 14000;
    ctx.strokeStyle = "rgba(255, 205, 66, 0.55)";
    ctx.lineWidth = 4;
    ctx.lineCap = "round";
    for (let i = 0; i < 12; i++) {
      const angle = rotation + (i / 12) * Math.PI * 2;
      const inner = sunR + 8 + Math.sin(this.time / 600 + i) * 2;
      const outer = inner + 14;
      ctx.beginPath();
      ctx.moveTo(sunX + Math.cos(angle) * inner, sunY + Math.sin(angle) * inner);
      ctx.lineTo(sunX + Math.cos(angle) * outer, sunY + Math.sin(angle) * outer);
      ctx.stroke();
    }

    // Sun core
    const core = ctx.createRadialGradient(sunX - 8, sunY - 8, 4, sunX, sunY, sunR);
    core.addColorStop(0, "#FFF3B0");
    core.addColorStop(1, "#FFC53D");
    ctx.fillStyle = core;
    ctx.beginPath();
    ctx.arc(sunX, sunY, sunR, 0, Math.PI * 2);
    ctx.fill();

    ctx.restore();
  }

  /** Sunflowers along the bottom — drawn behind the sheep */
  drawMidground(ctx: CanvasRenderingContext2D, w: number, h: number) {
    if (!this.active) return;

    ctx.save();
    for (const f of this.sunflowers) {
      const x = f.x * w;
      const baseY = f.y * h;
      const sway = Math.sin((this.time / 1000) * f.swaySpeed + f.swayOffset) * 3;
      const headX = x + sway;
      const headY = baseY - f.size;

      // Stem
      ctx.strokeStyle = "#4E7C31";
      ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.moveTo(x, baseY);
      ctx.quadraticCurveTo(x + sway * 0.5, baseY - f.size * 0.6, headX, headY);
      ctx.stroke();

      // Leaf
      ctx.fillStyle = "#5C9440";
      ctx.beginPath();
      ctx.ellipse(x + 6, baseY - f.size * 0.45, 7, 3.5, 0.6, 0, Math.PI * 2);
      ctx.fill();

      // Petals
      ctx.fillStyle = "#FFC53D";
      const petalR = f.size * 0.34;
      for (let i = 0; i < 10; i++) {
        const angle = (i / 10) * Math.PI * 2;
        ctx.beginPath();
        ctx.ellipse(
          headX + Math.cos(angle) * petalR,
          headY + Math.sin(angle) * petalR,
          petalR * 0.6,
          petalR * 0.3,
          angle,
          0,
          Math.PI * 2,
        );
        ctx.fill();
      }

      // Center
      ctx.fillStyle = "#6B4423";
      ctx.beginPath();
      ctx.arc(headX, headY, petalR * 0.55, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  }

  /** Butterflies and drifting seeds — drawn on top of the sheep */
  drawForeground(ctx: CanvasRenderingContext2D, _w: number, _h: number) {
    if (!this.active) return;

    ctx.save();

    // Seeds: tiny white tufts drifting on the breeze
    ctx.fillStyle = "rgba(255, 255, 255, 0.85)";
    ctx.strokeStyle = "rgba(255, 255, 255, 0.5)";
    ctx.lineWidth = 1;
    for (const s of this.seeds) {
      ctx.beginPath();
      ctx.arc(s.x, s.y, s.size * 0.6, 0, Math.PI * 2);
      ctx.fill();
      for (let i = 0; i < 4; i++) {
        const angle = (i / 4) * Math.PI * 2 + s.swayOffset;
        ctx.beginPath();
        ctx.moveTo(s.x, s.y);
        ctx.lineTo(s.x + Math.cos(angle) * s.size * 2, s.y + Math.sin(angle) * s.size * 2);
        ctx.stroke();
      }
    }

    // Butterflies: two flapping wings and a body
    for (const b of this.butterflies) {
      const flap = Math.abs(Math.sin(b.wingPhase));
      const wingW = 6 * (0.35 + flap * 0.65);
      ctx.fillStyle = b.color;
      ctx.beginPath();
      ctx.ellipse(b.x - wingW * 0.7, b.y, wingW, 5, -0.4, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.ellipse(b.x + wingW * 0.7, b.y, wingW, 5, 0.4, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "#3A2E20";
      ctx.beginPath();
      ctx.ellipse(b.x, b.y, 1.4, 4.5, 0, 0, Math.PI * 2);
      ctx.fill();
    }

    ctx.restore();
  }
}

export const SUMMER_IDLE_QUIPS = [
  "Sun's out, wool's out.",
  "This is prime grazing weather.",
  "I could nap in this sun forever.",
  "Anyone else smell sunscreen?",
  "A butterfly landed on me. I'm chosen.",
  "Too hot for a wool coat. Can't take it off though.",
];

export const SUNBATHE_QUIPS = [
  "Ahhh... sol.",
  "Someone flip me in ten minutes.",
  "I'm working on my wool tan.",
  "This is the life.",
  "Wake me when it's autumn.",
  "SPF? Never heard of her.",
];

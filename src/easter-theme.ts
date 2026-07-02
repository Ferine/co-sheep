import { SheepState } from "./types";

type EasterMode = "auto" | "on" | "off";
type EggPattern = "stripe" | "zigzag" | "dots" | "bands" | "cross";

interface Flower {
  x: number;
  y: number;
  color: string;
  petalColor: string;
  swaySpeed: number;
  swayOffset: number;
  size: number;
}

interface Petal {
  x: number;
  y: number;
  vx: number;
  vy: number;
  color: string;
  rotation: number;
  rotationSpeed: number;
  size: number;
}

interface PaintedEggDesign {
  painterId: string;
  painterName: string;
  baseColor: string;
  stripeColor: string;
  accentColor: string;
  pattern: EggPattern;
}

interface EasterEgg {
  x: number;
  y: number;
  baseColor: string;
  stripeColor: string;
  accentColor: string;
  found: boolean;
  sparkleTimer: number;
  hiddenness: number;
  isGolden: boolean;
  pattern: EggPattern;
  shadowScale: number;
  paintedBy?: PaintedEggDesign;
}

export interface EasterEggPosition {
  x: number;
  y: number;
  found: boolean;
  golden: boolean;
  hiddenness: number;
  painted: boolean;
  painterName?: string;
}

export interface EasterStatsSnapshot {
  eggs_found_total?: number;
  eggs_found_today?: number;
  golden_eggs_total?: number;
  golden_eggs_today?: number;
  hunts_completed?: number;
  hunts_today?: number;
  current_streak?: number;
  best_streak?: number;
  painted_eggs_used_total?: number;
  flock_score?: number;
  top_hunter_name?: string;
  last_winner_name?: string;
}

const PASTEL_COLORS = [
  "rgba(255, 182, 193, 0.72)",
  "rgba(176, 226, 172, 0.72)",
  "rgba(200, 180, 230, 0.72)",
  "rgba(255, 239, 170, 0.72)",
  "rgba(180, 220, 255, 0.72)",
];

const FLOWER_PALETTES = [
  { petal: "#FFB6C1", center: "#FFD700" },
  { petal: "#DDA0DD", center: "#FFF8DC" },
  { petal: "#FFFACD", center: "#FFA07A" },
  { petal: "#E6E6FA", center: "#FFD700" },
  { petal: "#98FB98", center: "#FF69B4" },
];

const EGG_PALETTES = [
  { base: "#FFB6C1", stripe: "#FF69B4", accent: "#FFF4FA" },
  { base: "#B0E2AC", stripe: "#4CAF50", accent: "#ECFFF0" },
  { base: "#C8B4E6", stripe: "#7B68EE", accent: "#F2ECFF" },
  { base: "#FFEFAA", stripe: "#E8B400", accent: "#FFFBE0" },
  { base: "#B4DCFF", stripe: "#6495ED", accent: "#ECF6FF" },
  { base: "#FFDAB9", stripe: "#FF8C00", accent: "#FFF0E2" },
];

const PATTERNS: EggPattern[] = ["stripe", "zigzag", "dots", "bands", "cross"];
const ACTIVE_REFRESH_INTERVAL_MS = 60000;
const HUD_DISPLAY_TIME_MS = 18000;
const MAX_PAINTED_DESIGNS = 6;

const EGG_SPAWN_POINTS = [
  { x: 0.06, y: 0.91 },
  { x: 0.13, y: 0.875 },
  { x: 0.21, y: 0.94 },
  { x: 0.28, y: 0.895 },
  { x: 0.36, y: 0.955 },
  { x: 0.43, y: 0.905 },
  { x: 0.52, y: 0.94 },
  { x: 0.6, y: 0.965 },
  { x: 0.68, y: 0.915 },
  { x: 0.76, y: 0.945 },
  { x: 0.84, y: 0.89 },
  { x: 0.92, y: 0.93 },
];

/** Compute Easter Sunday for a given year using the Anonymous Gregorian algorithm */
export function computeEasterSunday(year: number): Date {
  const a = year % 19;
  const b = Math.floor(year / 100);
  const c = year % 100;
  const d = Math.floor(b / 4);
  const e = b % 4;
  const f = Math.floor((b + 8) / 25);
  const g = Math.floor((b - f + 1) / 3);
  const h = (19 * a + b - d - g + 15) % 30;
  const i = Math.floor(c / 4);
  const k = c % 4;
  const l = (32 + 2 * e + 2 * i - h - k) % 7;
  const m = Math.floor((a + 11 * h + 22 * l) / 451);
  const month = Math.floor((h + l - 7 * m + 114) / 31);
  const day = ((h + l - 7 * m + 114) % 31) + 1;
  return new Date(year, month - 1, day);
}

/** Check if today falls within the Easter season window (5 days before to 2 days after) */
export function isEasterSeason(): boolean {
  const now = new Date();
  const easter = computeEasterSunday(now.getFullYear());
  const start = new Date(easter);
  start.setDate(start.getDate() - 5);
  const end = new Date(easter);
  end.setDate(end.getDate() + 2);
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  return today >= start && today <= end;
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function chooseRandom<T>(items: T[]): T {
  return items[Math.floor(Math.random() * items.length)];
}

function pickDistinctSpawnPoints(count: number) {
  const pool = [...EGG_SPAWN_POINTS];
  const chosen: Array<{ x: number; y: number }> = [];

  while (pool.length > 0 && chosen.length < count) {
    const index = Math.floor(Math.random() * pool.length);
    const point = pool.splice(index, 1)[0];
    chosen.push(point);
    for (let i = pool.length - 1; i >= 0; i--) {
      if (Math.abs(pool[i].x - point.x) < 0.07) {
        pool.splice(i, 1);
      }
    }
  }

  return chosen.sort((a, b) => a.x - b.x);
}

export class EasterTheme {
  private flowers: Flower[] = [];
  private petals: Petal[] = [];
  private eggs: EasterEgg[] = [];
  private paintedEggDesigns: PaintedEggDesign[] = [];
  private basketLoads: Map<string, number> = new Map();
  private huntParticipants: Set<string> = new Set();
  private sheepPositions: Array<{ x: number; y: number; state: SheepState }> = [];
  private stats: EasterStatsSnapshot = {};
  private screenWidth: number;
  private screenHeight: number;
  private time = 0;
  private activeRefreshTimer = 0;
  private hudTimer = 0;
  private recentHuntTimer = 0;
  private modeOverride: EasterMode = "auto";
  private huntActive = false;
  private currentPaintedEggsUsed = 0;
  active = false;

  constructor(screenWidth: number, screenHeight: number) {
    this.screenWidth = screenWidth;
    this.screenHeight = screenHeight;
    this.refreshActiveState(true);
  }

  setModeOverride(mode: EasterMode = "auto") {
    this.modeOverride = mode;
    this.refreshActiveState(true);
  }

  getModeOverride(): EasterMode {
    return this.modeOverride;
  }

  applyStats(stats: EasterStatsSnapshot | null) {
    this.stats = stats ?? {};
  }

  hasRecentHuntBuzz(): boolean {
    return this.recentHuntTimer > 0;
  }

  shouldShowBasket(id: string): boolean {
    if (!this.active) return false;
    return (this.huntActive && this.huntParticipants.has(id)) || (this.basketLoads.get(id) ?? 0) > 0;
  }

  getBasketFillRatio(id: string): number {
    return clamp((this.basketLoads.get(id) ?? 0) / 3, 0, 1);
  }

  getBasketEggCount(id: string): number {
    return this.basketLoads.get(id) ?? 0;
  }

  getPaintedEggsUsedCount(): number {
    return this.currentPaintedEggsUsed;
  }

  registerPaintedEgg(painterId: string, painterName: string) {
    if (!this.active) return;
    const palette = chooseRandom(EGG_PALETTES);
    const design: PaintedEggDesign = {
      painterId,
      painterName,
      baseColor: palette.base,
      stripeColor: palette.stripe,
      accentColor: palette.accent,
      pattern: chooseRandom(PATTERNS),
    };
    this.paintedEggDesigns.unshift(design);
    if (this.paintedEggDesigns.length > MAX_PAINTED_DESIGNS) {
      this.paintedEggDesigns.length = MAX_PAINTED_DESIGNS;
    }
    this.hudTimer = HUD_DISPLAY_TIME_MS;
  }

  refreshActiveState(force: boolean = false): boolean {
    const seasonActive = isEasterSeason();
    const nextActive = this.modeOverride === "on"
      ? true
      : this.modeOverride === "off"
        ? false
        : seasonActive;

    if (!force && nextActive === this.active) {
      return false;
    }

    this.active = nextActive;
    this.petals = [];
    this.time = 0;
    this.huntActive = false;
    this.huntParticipants.clear();
    this.basketLoads.clear();
    this.currentPaintedEggsUsed = 0;

    if (this.active) {
      this.seedFlowers();
      this.seedEggs();
      this.hudTimer = HUD_DISPLAY_TIME_MS;
    } else {
      this.flowers = [];
      this.eggs = [];
    }

    return true;
  }

  private seedFlowers() {
    this.flowers = [];
    for (let i = 0; i < 16; i++) {
      const palette = FLOWER_PALETTES[i % FLOWER_PALETTES.length];
      this.flowers.push({
        x: 0.04 + (i / 15) * 0.92 + Math.sin(i * 4.7) * 0.02,
        y: 0.84 + Math.sin(i * 3.1) * 0.06,
        color: palette.center,
        petalColor: palette.petal,
        swaySpeed: 0.45 + Math.sin(i * 2.1) * 0.2,
        swayOffset: i * 1.17,
        size: 0.9 + Math.sin(i * 2.9) * 0.3,
      });
    }
  }

  private createEgg(point: { x: number; y: number }, design?: PaintedEggDesign, isGolden: boolean = false): EasterEgg {
    const fallbackPalette = chooseRandom(EGG_PALETTES);
    const palette = design
      ? { base: design.baseColor, stripe: design.stripeColor, accent: design.accentColor }
      : fallbackPalette;
    return {
      x: point.x + (Math.random() - 0.5) * 0.01,
      y: point.y + (Math.random() - 0.5) * 0.01,
      baseColor: isGolden ? "#FFE07B" : palette.base,
      stripeColor: isGolden ? "#F2B705" : palette.stripe,
      accentColor: isGolden ? "#FFF7CC" : palette.accent,
      found: false,
      sparkleTimer: 0,
      hiddenness: isGolden ? 0.12 : 0.18 + Math.random() * 0.38,
      isGolden,
      pattern: design?.pattern ?? chooseRandom(PATTERNS),
      shadowScale: 0.8 + Math.random() * 0.4,
      paintedBy: design,
    };
  }

  private seedEggs() {
    this.eggs = [];
    const eggCount = 6 + (Math.random() < 0.35 ? 1 : 0);
    const points = pickDistinctSpawnPoints(eggCount);
    const goldenIndex = Math.random() < 0.2 ? Math.floor(Math.random() * points.length) : -1;
    const paintedPool = [...this.paintedEggDesigns];
    this.currentPaintedEggsUsed = 0;

    for (let i = 0; i < points.length; i++) {
      const shouldUsePainted = paintedPool.length > 0 && Math.random() < 0.45;
      const design = shouldUsePainted ? paintedPool.splice(Math.floor(Math.random() * paintedPool.length), 1)[0] : undefined;
      if (design) {
        this.currentPaintedEggsUsed += 1;
      }
      this.eggs.push(this.createEgg(points[i], design, i === goldenIndex));
    }
  }

  getEggPositions(): EasterEggPosition[] {
    return this.eggs.map((egg) => ({
      x: egg.x * this.screenWidth,
      y: egg.y * this.screenHeight,
      found: egg.found,
      golden: egg.isGolden,
      hiddenness: egg.hiddenness,
      painted: Boolean(egg.paintedBy),
      painterName: egg.paintedBy?.painterName,
    }));
  }

  prepareHunt(participants: string[]) {
    if (!this.active) return;
    this.huntActive = true;
    this.huntParticipants = new Set(participants);
    this.basketLoads.clear();
    this.seedEggs();
    this.hudTimer = HUD_DISPLAY_TIME_MS;
  }

  collectEgg(index: number, finderId?: string) {
    if (index < 0 || index >= this.eggs.length) return;
    const egg = this.eggs[index];
    if (egg.found) return;

    egg.found = true;
    egg.sparkleTimer = egg.isGolden ? 3.4 : 2.2;
    if (finderId) {
      this.basketLoads.set(finderId, (this.basketLoads.get(finderId) ?? 0) + (egg.isGolden ? 2 : 1));
    }
    this.hudTimer = HUD_DISPLAY_TIME_MS;
    this.recentHuntTimer = Math.max(this.recentHuntTimer, 10000);
  }

  finishHunt() {
    this.huntActive = false;
    this.recentHuntTimer = Math.max(this.recentHuntTimer, 15000);
    this.huntParticipants.clear();
  }

  /** Reset eggs for a new egg hunt round */
  resetEggs() {
    if (!this.active) return;
    this.huntActive = false;
    this.huntParticipants.clear();
    this.basketLoads.clear();
    this.seedEggs();
  }

  updateScreenSize(w: number, h: number) {
    this.screenWidth = w;
    this.screenHeight = h;
  }

  update(dt: number, sheepPositions: Array<{ x: number; y: number; state: SheepState }>) {
    this.sheepPositions = sheepPositions;
    this.activeRefreshTimer += dt;
    if (this.activeRefreshTimer >= ACTIVE_REFRESH_INTERVAL_MS) {
      this.activeRefreshTimer %= ACTIVE_REFRESH_INTERVAL_MS;
      this.refreshActiveState();
    }

    if (!this.active) return;
    this.time += dt / 1000;
    this.hudTimer = Math.max(0, this.hudTimer - dt);
    this.recentHuntTimer = Math.max(0, this.recentHuntTimer - dt);

    this.updatePetals(dt / 1000);

    for (const egg of this.eggs) {
      if (egg.sparkleTimer > 0) {
        egg.sparkleTimer -= dt / 1000;
      }
    }
  }

  private updatePetals(dt: number) {
    while (this.petals.length < 18) {
      this.petals.push(this.spawnPetal());
    }

    for (const petal of this.petals) {
      petal.x += petal.vx * dt;
      petal.y += petal.vy * dt;
      petal.rotation += petal.rotationSpeed * dt;
      petal.x += Math.sin(petal.y * 0.035 + petal.rotation) * 10 * dt;

      for (const sheep of this.sheepPositions) {
        const dx = petal.x - (sheep.x + 48);
        const dy = petal.y - (sheep.y + 56);
        const distance = Math.sqrt(dx * dx + dy * dy);
        if (distance < 130) {
          const push = (130 - distance) / 130;
          petal.x += (dx >= 0 ? 1 : -1) * push * 16 * dt;
          petal.rotation += push * 1.8 * dt;
        }
      }
    }

    // Respawn petals that drifted off-screen (pushing into the array
    // being filtered would be discarded by the filter's return value)
    this.petals = this.petals.map((petal) =>
      petal.y < -20 || petal.x < -20 || petal.x > this.screenWidth + 20
        ? this.spawnPetal()
        : petal,
    );
  }

  private spawnPetal(): Petal {
    return {
      x: Math.random() * this.screenWidth,
      y: this.screenHeight + Math.random() * 40,
      vx: (Math.random() - 0.5) * 10,
      vy: -(15 + Math.random() * 25),
      color: chooseRandom(PASTEL_COLORS),
      rotation: Math.random() * Math.PI * 2,
      rotationSpeed: (Math.random() - 0.5) * 2.2,
      size: 3 + Math.random() * 4,
    };
  }

  drawBackground(ctx: CanvasRenderingContext2D, w: number, h: number) {
    if (!this.active) return;
    this.drawGroundWash(ctx, w, h);
    this.drawFlowers(ctx, w, h);
  }

  drawMidground(ctx: CanvasRenderingContext2D, w: number, h: number) {
    if (!this.active) return;
    this.drawEggs(ctx, w, h);
  }

  drawForeground(ctx: CanvasRenderingContext2D, w: number, h: number) {
    if (!this.active) return;
    this.drawSparkles(ctx, w, h);
    this.drawPetals(ctx);
    this.drawHud(ctx, w, h);
  }

  private drawGroundWash(ctx: CanvasRenderingContext2D, w: number, h: number) {
    ctx.save();
    const gradient = ctx.createLinearGradient(0, h * 0.7, 0, h);
    gradient.addColorStop(0, "rgba(255, 240, 204, 0)");
    gradient.addColorStop(1, "rgba(200, 236, 170, 0.08)");
    ctx.fillStyle = gradient;
    ctx.fillRect(0, h * 0.7, w, h * 0.3);
    ctx.restore();
  }

  private drawFlowers(ctx: CanvasRenderingContext2D, w: number, h: number) {
    ctx.save();
    for (const flower of this.flowers) {
      const fx = flower.x * w;
      const fy = flower.y * h;
      const sway = Math.sin(this.time * flower.swaySpeed + flower.swayOffset) * 3;
      const scale = flower.size * 3;

      ctx.strokeStyle = "rgba(80, 160, 80, 0.6)";
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(fx + sway, fy);
      ctx.lineTo(fx, fy + (12 * scale) / 3);
      ctx.stroke();

      ctx.fillStyle = flower.petalColor;
      for (let i = 0; i < 5; i++) {
        const angle = (i / 5) * Math.PI * 2 + this.time * 0.1;
        const px = fx + sway + (Math.cos(angle) * 3 * scale) / 3;
        const py = fy + (Math.sin(angle) * 3 * scale) / 3;
        ctx.beginPath();
        ctx.arc(px, py, (2.5 * scale) / 3, 0, Math.PI * 2);
        ctx.fill();
      }

      ctx.fillStyle = flower.color;
      ctx.beginPath();
      ctx.arc(fx + sway, fy, (2 * scale) / 3, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  }

  private drawEggs(ctx: CanvasRenderingContext2D, w: number, h: number) {
    ctx.save();
    for (const egg of this.eggs) {
      if (egg.found) continue;

      const ex = egg.x * w;
      const ey = egg.y * h;
      const eggW = egg.isGolden ? 7 : 6;
      const eggH = egg.isGolden ? 9 : 8;

      ctx.fillStyle = "rgba(40, 50, 35, 0.14)";
      ctx.beginPath();
      ctx.ellipse(ex, ey + 8, eggW * 1.3 * egg.shadowScale, 2.4, 0, 0, Math.PI * 2);
      ctx.fill();

      ctx.fillStyle = egg.baseColor;
      ctx.beginPath();
      ctx.ellipse(ex, ey, eggW, eggH, 0, 0, Math.PI * 2);
      ctx.fill();

      this.drawEggPattern(ctx, ex, ey, eggW, eggH, egg);

      ctx.fillStyle = egg.accentColor;
      ctx.beginPath();
      ctx.ellipse(ex - 2, ey - 3, 1.5, 2, -0.3, 0, Math.PI * 2);
      ctx.fill();

      this.drawGrassTufts(ctx, ex, ey, egg.hiddenness);
    }
    ctx.restore();
  }

  private drawEggPattern(
    ctx: CanvasRenderingContext2D,
    ex: number,
    ey: number,
    eggW: number,
    eggH: number,
    egg: EasterEgg,
  ) {
    ctx.save();
    ctx.strokeStyle = egg.stripeColor;
    ctx.fillStyle = egg.stripeColor;
    ctx.lineWidth = egg.isGolden ? 1.2 : 1;

    switch (egg.pattern) {
      case "stripe":
        ctx.fillRect(ex - eggW, ey - 1.5, eggW * 2, 3);
        break;
      case "bands":
        ctx.fillRect(ex - eggW + 0.5, ey - 5, eggW * 2 - 1, 2);
        ctx.fillRect(ex - eggW + 0.5, ey + 2, eggW * 2 - 1, 2);
        break;
      case "dots":
        for (let i = -1; i <= 1; i++) {
          ctx.beginPath();
          ctx.arc(ex + i * 3, ey + (i % 2 === 0 ? -1 : 2), 1.2, 0, Math.PI * 2);
          ctx.fill();
        }
        break;
      case "cross":
        ctx.fillRect(ex - 1, ey - eggH + 2, 2, eggH * 2 - 4);
        ctx.fillRect(ex - eggW + 1, ey - 1, eggW * 2 - 2, 2);
        break;
      case "zigzag":
      default:
        ctx.beginPath();
        for (let i = 0; i < 5; i++) {
          const zx = ex - eggW + 1 + (i * (eggW * 2 - 2)) / 4;
          const zy = ey + 1 + (i % 2 === 0 ? -2 : 2);
          if (i === 0) ctx.moveTo(zx, zy);
          else ctx.lineTo(zx, zy);
        }
        ctx.stroke();
        break;
    }

    if (egg.paintedBy) {
      ctx.fillStyle = "rgba(255, 255, 255, 0.65)";
      ctx.beginPath();
      ctx.arc(ex, ey - 5, 1.1, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  }

  private drawGrassTufts(ctx: CanvasRenderingContext2D, ex: number, ey: number, hiddenness: number) {
    const tuftCount = 2 + Math.round(hiddenness * 4);
    const height = 3 + hiddenness * 4;
    ctx.save();
    ctx.strokeStyle = "rgba(109, 168, 93, 0.9)";
    ctx.lineWidth = 1;
    for (let i = 0; i < tuftCount; i++) {
      const gx = ex - 6 + i * 3;
      const sway = Math.sin(this.time * 1.4 + gx) * 0.8;
      ctx.beginPath();
      ctx.moveTo(gx, ey + 7);
      ctx.lineTo(gx - 1 + sway, ey + 7 - height);
      ctx.moveTo(gx, ey + 7);
      ctx.lineTo(gx + 1 + sway, ey + 7 - height * 0.85);
      ctx.stroke();
    }
    ctx.restore();
  }

  private drawSparkles(ctx: CanvasRenderingContext2D, w: number, h: number) {
    for (const egg of this.eggs) {
      if (!egg.found || egg.sparkleTimer <= 0) continue;
      this.drawSparkle(ctx, egg.x * w, egg.y * h, egg.sparkleTimer, egg.isGolden);
    }
  }

  private drawSparkle(ctx: CanvasRenderingContext2D, x: number, y: number, timer: number, golden: boolean) {
    const alpha = Math.min(1, timer);
    const spread = (golden ? 20 : 15) * (golden ? 1.4 : 1) * (3 - timer * 0.8);
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.fillStyle = golden ? "#FFE07B" : "#FFD700";
    for (let i = 0; i < (golden ? 8 : 6); i++) {
      const angle = (i / (golden ? 8 : 6)) * Math.PI * 2 + this.time * (golden ? 4 : 3);
      const sx = x + Math.cos(angle) * spread * 0.35;
      const sy = y + Math.sin(angle) * spread * 0.25;
      ctx.beginPath();
      ctx.arc(sx, sy, golden ? 2.4 : 2, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  }

  private drawPetals(ctx: CanvasRenderingContext2D) {
    ctx.save();
    for (const petal of this.petals) {
      ctx.fillStyle = petal.color;
      ctx.save();
      ctx.translate(petal.x, petal.y);
      ctx.rotate(petal.rotation);
      ctx.beginPath();
      ctx.ellipse(0, 0, petal.size * 0.5, petal.size, 0, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }
    ctx.restore();
  }

  private drawHud(ctx: CanvasRenderingContext2D, w: number, _h: number) {
    const shouldShow = this.hudTimer > 0 || this.recentHuntTimer > 0 || this.huntActive || this.modeOverride !== "auto";
    if (!shouldShow) return;

    const eggsToday = this.stats.eggs_found_today ?? 0;
    const streak = this.stats.current_streak ?? 0;
    const score = this.stats.flock_score ?? 0;
    const hunts = this.stats.hunts_completed ?? 0;
    const topHunter = this.stats.top_hunter_name || this.stats.last_winner_name || "Nobody yet";
    const goldenToday = this.stats.golden_eggs_today ?? 0;

    const boxW = 188;
    const boxH = 82;
    const x = w - boxW - 18;
    const y = 18;

    ctx.save();
    ctx.fillStyle = "rgba(26, 26, 46, 0.72)";
    ctx.strokeStyle = "rgba(255, 233, 163, 0.35)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.roundRect(x, y, boxW, boxH, 12);
    ctx.fill();
    ctx.stroke();

    ctx.fillStyle = "#FFF5CE";
    ctx.font = "bold 11px monospace";
    ctx.fillText("SPRING LEDGER", x + 14, y + 18);

    ctx.fillStyle = "#F7DA7D";
    ctx.font = "10px monospace";
    ctx.fillText(`Eggs today ${eggsToday}`, x + 14, y + 36);
    ctx.fillText(`Golden ${goldenToday}`, x + 14, y + 50);
    ctx.fillText(`Streak ${streak}  Hunts ${hunts}`, x + 14, y + 64);
    ctx.fillText(`Score ${score}`, x + 14, y + 78);

    ctx.fillStyle = "#BFE4A8";
    ctx.textAlign = "right";
    ctx.fillText(topHunter, x + boxW - 14, y + 36);
    ctx.fillStyle = "#A6BEDA";
    ctx.fillText(this.modeOverride === "auto" ? "Seasonal" : `Forced ${this.modeOverride}`, x + boxW - 14, y + 78);
    ctx.textAlign = "start";
    ctx.restore();
  }
}

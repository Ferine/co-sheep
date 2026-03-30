import { SheepState } from "./types";

interface Flower {
  x: number; // normalized 0..1
  y: number;
  color: string;
  petalColor: string;
  swaySpeed: number;
  swayOffset: number;
  size: number; // 1..1.5
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

interface EasterEgg {
  x: number;
  y: number;
  baseColor: string;
  stripeColor: string;
  found: boolean;
  sparkleTimer: number; // >0 means sparkling after collection
}

const PASTEL_COLORS = [
  "rgba(255, 182, 193, 0.7)", // pink
  "rgba(176, 226, 172, 0.7)", // mint
  "rgba(200, 180, 230, 0.7)", // lavender
  "rgba(255, 239, 170, 0.7)", // soft yellow
  "rgba(180, 220, 255, 0.7)", // baby blue
];

const FLOWER_PALETTES = [
  { petal: "#FFB6C1", center: "#FFD700" }, // pink + gold
  { petal: "#DDA0DD", center: "#FFF8DC" }, // plum + cream
  { petal: "#FFFACD", center: "#FFA07A" }, // lemon + salmon
  { petal: "#E6E6FA", center: "#FFD700" }, // lavender + gold
  { petal: "#98FB98", center: "#FF69B4" }, // pale green + hot pink
];

const EGG_PALETTES = [
  { base: "#FFB6C1", stripe: "#FF69B4" },
  { base: "#B0E2AC", stripe: "#4CAF50" },
  { base: "#C8B4E6", stripe: "#7B68EE" },
  { base: "#FFEFAA", stripe: "#FFD700" },
  { base: "#B4DCFF", stripe: "#6495ED" },
  { base: "#FFDAB9", stripe: "#FF8C00" },
];

const ACTIVE_REFRESH_INTERVAL_MS = 60000;

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
  const month = Math.floor((h + l - 7 * m + 114) / 31); // 3=March, 4=April
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
  // Strip time for date comparison
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  return today >= start && today <= end;
}

export class EasterTheme {
  private flowers: Flower[] = [];
  private petals: Petal[] = [];
  private eggs: EasterEgg[] = [];
  private screenWidth: number;
  private screenHeight: number;
  private time = 0;
  private activeRefreshTimer = 0;
  active = false;

  constructor(screenWidth: number, screenHeight: number) {
    this.screenWidth = screenWidth;
    this.screenHeight = screenHeight;
    this.refreshActiveState(true);
  }

  refreshActiveState(force: boolean = false): boolean {
    const nextActive = isEasterSeason();
    if (!force && nextActive === this.active) {
      return false;
    }

    this.active = nextActive;
    this.petals = [];
    this.time = 0;

    if (this.active) {
      this.seedFlowers();
      this.seedEggs();
    } else {
      this.flowers = [];
      this.eggs = [];
    }

    return true;
  }

  private seedFlowers() {
    this.flowers = [];
    for (let i = 0; i < 12; i++) {
      const palette = FLOWER_PALETTES[i % FLOWER_PALETTES.length];
      this.flowers.push({
        x: 0.05 + (i / 12) * 0.9 + (Math.sin(i * 7.3) * 0.03),
        y: 0.85 + Math.sin(i * 4.1) * 0.08,
        color: palette.center,
        petalColor: palette.petal,
        swaySpeed: 0.5 + Math.sin(i * 2.7) * 0.3,
        swayOffset: i * 1.3,
        size: 1.0 + Math.sin(i * 3.9) * 0.4,
      });
    }
  }

  private seedEggs() {
    this.eggs = [];
    const positions = [
      { x: 0.05, y: 0.92 },
      { x: 0.92, y: 0.88 },
      { x: 0.35, y: 0.95 },
      { x: 0.75, y: 0.93 },
      { x: 0.15, y: 0.88 },
      { x: 0.60, y: 0.96 },
    ];
    for (let i = 0; i < positions.length; i++) {
      const palette = EGG_PALETTES[i % EGG_PALETTES.length];
      this.eggs.push({
        x: positions[i].x,
        y: positions[i].y,
        baseColor: palette.base,
        stripeColor: palette.stripe,
        found: false,
        sparkleTimer: 0,
      });
    }
  }

  getEggPositions(): Array<{ x: number; y: number; found: boolean }> {
    return this.eggs.map((e) => ({
      x: e.x * this.screenWidth,
      y: e.y * this.screenHeight,
      found: e.found,
    }));
  }

  collectEgg(index: number) {
    if (index >= 0 && index < this.eggs.length && !this.eggs[index].found) {
      this.eggs[index].found = true;
      this.eggs[index].sparkleTimer = 2.0; // 2s sparkle
    }
  }

  /** Reset eggs for a new egg hunt round */
  resetEggs() {
    for (const egg of this.eggs) {
      egg.found = false;
      egg.sparkleTimer = 0;
    }
  }

  updateScreenSize(w: number, h: number) {
    this.screenWidth = w;
    this.screenHeight = h;
  }

  update(dt: number, _sheepPositions: Array<{ x: number; y: number; state: SheepState }>) {
    this.activeRefreshTimer += dt;
    if (this.activeRefreshTimer >= ACTIVE_REFRESH_INTERVAL_MS) {
      this.activeRefreshTimer %= ACTIVE_REFRESH_INTERVAL_MS;
      this.refreshActiveState();
    }

    if (!this.active) return;
    this.time += dt / 1000;

    // Update petals
    this.updatePetals(dt / 1000);

    // Update egg sparkle timers
    for (const egg of this.eggs) {
      if (egg.sparkleTimer > 0) egg.sparkleTimer -= dt / 1000;
    }
  }

  private updatePetals(dt: number) {
    // Spawn petals up to max
    while (this.petals.length < 15) {
      this.petals.push(this.spawnPetal());
    }

    for (const p of this.petals) {
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.rotation += p.rotationSpeed * dt;
      // Gentle horizontal wobble
      p.x += Math.sin(p.y * 3 + p.rotation) * 8 * dt;
    }

    // Recycle off-screen petals
    this.petals = this.petals.filter((p) => {
      if (p.y < -20 || p.x < -20 || p.x > this.screenWidth + 20) {
        this.petals.push(this.spawnPetal());
        return false;
      }
      return true;
    });
  }

  private spawnPetal(): Petal {
    return {
      x: Math.random() * this.screenWidth,
      y: this.screenHeight + Math.random() * 40,
      vx: (Math.random() - 0.5) * 10,
      vy: -(15 + Math.random() * 25), // drift upward
      color: PASTEL_COLORS[Math.floor(Math.random() * PASTEL_COLORS.length)],
      rotation: Math.random() * Math.PI * 2,
      rotationSpeed: (Math.random() - 0.5) * 2,
      size: 3 + Math.random() * 4,
    };
  }

  drawBackground(ctx: CanvasRenderingContext2D, w: number, h: number) {
    if (!this.active) return;
    this.drawFlowers(ctx, w, h);
  }

  drawForeground(ctx: CanvasRenderingContext2D, w: number, h: number) {
    if (!this.active) return;
    this.drawEggs(ctx, w, h);
    this.drawPetals(ctx);
  }

  private drawFlowers(ctx: CanvasRenderingContext2D, w: number, h: number) {
    ctx.save();
    for (const f of this.flowers) {
      const fx = f.x * w;
      const fy = f.y * h;
      const sway = Math.sin(this.time * f.swaySpeed + f.swayOffset) * 3;
      const s = f.size * 3;

      // Stem
      ctx.strokeStyle = "rgba(80, 160, 80, 0.6)";
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(fx + sway, fy);
      ctx.lineTo(fx, fy + 12 * s / 3);
      ctx.stroke();

      // Petals (5 around center)
      ctx.fillStyle = f.petalColor;
      for (let i = 0; i < 5; i++) {
        const angle = (i / 5) * Math.PI * 2 + this.time * 0.1;
        const px = fx + sway + Math.cos(angle) * 3 * s / 3;
        const py = fy + Math.sin(angle) * 3 * s / 3;
        ctx.beginPath();
        ctx.arc(px, py, 2.5 * s / 3, 0, Math.PI * 2);
        ctx.fill();
      }

      // Center
      ctx.fillStyle = f.color;
      ctx.beginPath();
      ctx.arc(fx + sway, fy, 2 * s / 3, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  }

  private drawEggs(ctx: CanvasRenderingContext2D, w: number, h: number) {
    ctx.save();
    for (let i = 0; i < this.eggs.length; i++) {
      const egg = this.eggs[i];
      if (egg.found && egg.sparkleTimer <= 0) continue; // fully collected, gone

      const ex = egg.x * w;
      const ey = egg.y * h;

      if (egg.found && egg.sparkleTimer > 0) {
        // Sparkle effect for collected egg
        this.drawSparkle(ctx, ex, ey, egg.sparkleTimer);
        continue;
      }

      // Draw egg shape (oval)
      const eggW = 6;
      const eggH = 8;
      ctx.fillStyle = egg.baseColor;
      ctx.beginPath();
      ctx.ellipse(ex, ey, eggW, eggH, 0, 0, Math.PI * 2);
      ctx.fill();

      // Stripe across middle
      ctx.fillStyle = egg.stripeColor;
      ctx.fillRect(ex - eggW, ey - 1.5, eggW * 2, 3);

      // Zigzag decoration
      ctx.strokeStyle = egg.stripeColor;
      ctx.lineWidth = 1;
      ctx.beginPath();
      for (let j = 0; j < 4; j++) {
        const zx = ex - eggW + 1 + j * (eggW * 2 - 2) / 4;
        const zy = ey + 3 + (j % 2 === 0 ? -1.5 : 1.5);
        if (j === 0) ctx.moveTo(zx, zy);
        else ctx.lineTo(zx, zy);
      }
      ctx.stroke();

      // Shine
      ctx.fillStyle = "rgba(255, 255, 255, 0.4)";
      ctx.beginPath();
      ctx.ellipse(ex - 2, ey - 3, 1.5, 2, -0.3, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  }

  private drawSparkle(ctx: CanvasRenderingContext2D, x: number, y: number, timer: number) {
    const alpha = Math.min(1, timer);
    const spread = (2 - timer) * 15; // expands as timer decreases
    ctx.save();
    ctx.globalAlpha = alpha;
    for (let i = 0; i < 6; i++) {
      const angle = (i / 6) * Math.PI * 2 + this.time * 3;
      const sx = x + Math.cos(angle) * spread;
      const sy = y + Math.sin(angle) * spread;
      ctx.fillStyle = "#FFD700";
      ctx.beginPath();
      ctx.arc(sx, sy, 2, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
    ctx.restore();
  }

  private drawPetals(ctx: CanvasRenderingContext2D) {
    ctx.save();
    for (const p of this.petals) {
      ctx.fillStyle = p.color;
      ctx.save();
      ctx.translate(p.x, p.y);
      ctx.rotate(p.rotation);
      // Petal shape: small ellipse
      ctx.beginPath();
      ctx.ellipse(0, 0, p.size * 0.5, p.size, 0, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }
    ctx.restore();
  }
}

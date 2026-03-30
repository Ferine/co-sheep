import { SpriteSheet } from "./sprite";
import { FriendPersonality, SheepAnimation, SheepState, WindowPlatform } from "./types";
import type { EasterTheme } from "./easter-theme";

const SPRITE_SIZE = 32;
const SCALE = 3;
const DISPLAY_SIZE = SPRITE_SIZE * SCALE;
const WALK_SPEED = 60; // px/sec
const DOCK_MARGIN = 80; // stay above macOS Dock
const ZOOM_SPEED = 600; // px/sec
const BORED_THRESHOLD = 120000; // 2 minutes until bored idle behaviors

export type DrawOverlay = (
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  size: number,
  facingRight: boolean,
  state: SheepState,
) => void;

export class Sheep {
  readonly id: string;
  readonly tint: string | null;
  readonly scaleMultiplier: number;
  name: string;
  personality: FriendPersonality | null = null;
  x: number;
  y: number;
  vx: number = 0;
  vy: number = 0;
  state: SheepState = "parachute";
  facingRight: boolean = true;
  walkTarget: number | null = null;
  drawOverlay: DrawOverlay | null = null;

  // Stacking
  stackedOn: Sheep | null = null;
  stackedBy: Sheep | null = null;

  // Trampoline
  trampolineBounces: number = 0;
  private trampolineFlipProgress: number = 0;

  // Window platforms
  platforms: WindowPlatform[] = [];
  currentPlatform: WindowPlatform | null = null;

  screenWidth: number;
  screenHeight: number;
  private stateTimer: number = 0;
  private stateDuration: number = 0;
  private lastActivityTime: number = Date.now();
  private campfireSparks: Array<{ x: number; y: number; life: number }> = [];
  private nameTagAlpha: number = 0;
  private easterTheme: EasterTheme | null = null;

  private sprites: Record<string, SpriteSheet>;

  constructor(
    screenWidth: number,
    screenHeight: number,
    id: string = "main",
    tint: string | null = null,
    startX?: number,
    scaleMultiplier?: number,
  ) {
    this.id = id;
    this.tint = tint;
    this.scaleMultiplier = scaleMultiplier ?? 1.0;
    this.name = "Sheep";
    this.screenWidth = screenWidth;
    this.screenHeight = screenHeight;

    // Start from top for parachute entrance
    const ds = this.displaySize;
    this.x = startX ?? screenWidth / 2 - ds / 2;
    this.y = -ds;

    this.sprites = {
      idle: new SpriteSheet("/assets/sprites/sheep-idle.png", 32, 32, 2, 2),
      walk: new SpriteSheet("/assets/sprites/sheep-walk.png", 32, 32, 4, 6),
      parachute: new SpriteSheet(
        "/assets/sprites/sheep-parachute.png",
        32,
        32,
        2,
        3,
      ),
      sit: new SpriteSheet("/assets/sprites/sheep-sit.png", 32, 32, 1, 1),
      sleep: new SpriteSheet("/assets/sprites/sheep-sleep.png", 32, 32, 2, 2),
      fall: new SpriteSheet("/assets/sprites/sheep-fall.png", 32, 32, 1, 1),
    };
  }

  setEasterTheme(easterTheme: EasterTheme | null) {
    this.easterTheme = easterTheme;
  }

  get groundY(): number {
    return this.screenHeight - this.displaySize - DOCK_MARGIN;
  }

  get displaySize(): number {
    return Math.round(DISPLAY_SIZE * this.scaleMultiplier);
  }

  private get drawScale(): number {
    return SCALE * this.scaleMultiplier;
  }

  private get walkSpeed(): number {
    return WALK_SPEED * this.scaleMultiplier;
  }

  /** Reset boredom timer — call on any user interaction or AI commentary. */
  resetActivity() {
    this.lastActivityTime = Date.now();
    // Break out of bored states
    if (
      this.state === "idle_sleep" ||
      this.state === "idle_campfire" ||
      this.state === "idle_counting" ||
      this.state === "idle_judging" ||
      this.state === "idle_hearts" ||
      this.state === "idle_zooming" ||
      this.state === "idle_sighing"
    ) {
      this.setState("idle", 1000 + Math.random() * 2000);
    }
  }

  private isBored(): boolean {
    return Date.now() - this.lastActivityTime > BORED_THRESHOLD;
  }

  /** Trigger a named animation. Interrupts idle/walk/sit but not grabbed. */
  playAnimation(anim: SheepAnimation) {
    if (this.state === "grabbed" || this.state === "parachute") return;
    this.resetActivity();
    console.log(`[co-sheep:${this.id}] Playing animation:`, anim);

    switch (anim) {
      case "bounce":
        this.setState("bounce", 1200);
        this.vy = -300;
        break;
      case "spin":
        this.setState("spin", 800);
        break;
      case "backflip":
        this.setState("backflip", 600);
        this.vy = -200;
        break;
      case "headshake":
        this.setState("headshake", 800);
        break;
      case "zoom":
        this.setState("zoom", 1500);
        this.facingRight = Math.random() > 0.5;
        break;
      case "vibrate":
        this.setState("vibrate", 1000);
        break;
    }
  }

  /** Called when the user clicks on the sheep to start dragging. */
  grab() {
    this.resetActivity();
    // If something is stacked on us, make it fall
    if (this.stackedBy) {
      this.stackedBy.stackedOn = null;
      this.stackedBy.vy = -150;
      this.stackedBy.setState("fall", 0);
      this.stackedBy = null;
    }
    // If we're stacked on something, unstack
    if (this.stackedOn) {
      this.stackedOn.stackedBy = null;
      this.stackedOn = null;
    }
    this.currentPlatform = null;
    this.state = "grabbed";
    this.stateTimer = 0;
    this.vx = 0;
    this.vy = 0;
  }

  /** Called when the user releases the sheep. Parachutes if airborne, trampolines if very high. */
  release() {
    const trampolineThreshold = this.screenHeight * 0.35;
    if (this.y < trampolineThreshold) {
      // Very high up — trampoline mode!
      this.startTrampoline();
    } else if (this.y < this.groundY - 10) {
      // Airborne — deploy parachute
      this.state = "parachute";
      this.stateTimer = 0;
      this.vy = 0;
      this.vx = 0;
      const sprite = this.sprites["parachute"];
      if (sprite) sprite.reset();
    } else {
      // On or near ground
      this.y = this.groundY;
      this.state = "idle";
      this.stateTimer = 0;
      this.stateDuration = 1000 + Math.random() * 2000;
    }
  }

  /** Start petting — called when cursor hovers over sheep for a while. */
  startPetting() {
    if (this.state === "grabbed" || this.state === "parachute") return;
    if (this.state === "petting") return;
    this.resetActivity();
    console.log(`[co-sheep:${this.id}] Being petted!`);
    this.setState("petting", 0);
  }

  /** Stop petting — called when cursor leaves. */
  stopPetting() {
    if (this.state !== "petting") return;
    console.log(`[co-sheep:${this.id}] Petting stopped`);
    this.setState("idle", 2000 + Math.random() * 3000);
  }

  /** Returns a random quip for double-click interaction. */
  getRandomQuip(): string {
    const quips = [
      "Hey! Hooves are sensitive!",
      "Do I come to YOUR desktop and poke you?",
      "Baaaa! That tickles!",
      "*startled sheep noises*",
      "I was THINKING. Very deep thoughts.",
      "You know I can see your tabs, right?",
      "Stop poking me and get back to work.",
      "Is this what passes for entertainment?",
      "I'm not a button. I'm a sheep.",
      "If you pet me one more time I'm filing an HR complaint.",
      "Wow, procrastinating by clicking on a sheep. New low.",
      "I'm judging you. Always judging.",
      "That's my personal space!",
      "Ow! Just kidding, I'm made of pixels.",
    ];
    return quips[Math.floor(Math.random() * quips.length)];
  }

  /** Start stampede — scatter away from the given X coordinate */
  startStampede(mouseX: number) {
    if (this.state === "parachute" || this.state === "stacked") return;
    // Unstack if involved in a stack
    if (this.stackedBy) {
      this.stackedBy.stackedOn = null;
      this.stackedBy.setState("stampede", 1500);
      this.stackedBy.facingRight = Math.random() > 0.5;
      this.stackedBy = null;
    }
    if (this.stackedOn) {
      this.stackedOn.stackedBy = null;
      this.stackedOn = null;
    }
    this.currentPlatform = null;
    this.resetActivity();
    this.setState("stampede", 1200 + Math.random() * 800);
    // Run AWAY from mouse
    this.facingRight = this.x > mouseX;
    // If too close to edge, run the other way
    if (!this.facingRight && this.x < 100) this.facingRight = true;
    if (this.facingRight && this.x > this.screenWidth - 100) this.facingRight = false;
  }

  /** Start trampoline bouncing — called when dropped from very high */
  startTrampoline() {
    this.setState("trampoline", 12000); // max 12s
    this.trampolineBounces = 0;
    this.trampolineFlipProgress = 0;
    this.vy = 0; // gravity will do the work
  }

  /** Stack this sheep on top of another */
  stackOn(other: Sheep) {
    this.stackedOn = other;
    other.stackedBy = this;
    this.setState("stacked", 0);
    // Position on top
    this.x = other.x + (other.displaySize - this.displaySize) / 2;
    this.y = other.y - this.displaySize * 0.7;
    this.facingRight = other.facingRight;
  }

  /** Unstack this sheep from whatever it's stacked on */
  unstack() {
    if (this.stackedOn) {
      this.stackedOn.stackedBy = null;
      this.stackedOn = null;
    }
  }

  /** Called when the platform this sheep is standing on disappears */
  loseGround() {
    if (this.state === "grabbed" || this.state === "parachute" || this.state === "fall" || this.state === "trampoline") return;
    this.currentPlatform = null;
    this.state = "parachute";
    this.stateTimer = 0;
    this.vy = 0;
    const sprite = this.sprites["parachute"];
    if (sprite) sprite.reset();
  }

  /** Hit-test: is point (px, py) over the sheep? Uses a generous hitbox. */
  hitTest(px: number, py: number): boolean {
    const pad = 12;
    const ds = this.displaySize;
    return (
      px >= this.x - pad &&
      px <= this.x + ds + pad &&
      py >= this.y - pad &&
      py <= this.y + ds + pad
    );
  }

  update(dt: number) {
    this.stateTimer += dt;

    // Animate sprite — pick the right sheet for the current state
    const spriteKey = this.getSpriteKey();
    const currentSprite = this.sprites[spriteKey];
    if (currentSprite) currentSprite.update(dt);

    switch (this.state) {
      case "parachute":
        this.updateParachute(dt);
        break;
      case "idle":
        this.updateIdle();
        break;
      case "walk":
        this.updateWalk(dt);
        break;
      case "sit":
        this.updateSit();
        break;
      case "sleep":
        this.updateSleep();
        break;
      case "fall":
        this.updateFall(dt);
        break;
      case "grabbed":
        this.x = Math.max(0, Math.min(this.x, this.screenWidth - this.displaySize));
        this.y = Math.max(0, Math.min(this.y, this.screenHeight - this.displaySize));
        break;
      case "petting":
        // Just chill — sprite animation handles the rest
        break;
      case "bounce":
        this.updateBounce(dt);
        break;
      case "spin":
      case "backflip":
      case "headshake":
      case "vibrate":
        this.updateTimedAnimation();
        break;
      case "zoom":
        this.updateZoom(dt);
        break;
      case "idle_sleep":
        this.updateIdleSleep();
        break;
      case "idle_campfire":
        this.updateIdleCampfire(dt);
        break;
      case "idle_counting":
        this.updateIdleCounting();
        break;
      case "idle_judging":
        this.updateIdleJudging();
        break;
      case "idle_hearts":
        this.updateIdleHearts();
        break;
      case "idle_zooming":
        this.updateIdleZooming(dt);
        break;
      case "idle_sighing":
        this.updateIdleSighing();
        break;
      case "idle_egg_painting":
        this.updateIdleEggPainting();
        break;
      case "stampede":
        this.updateStampede(dt);
        break;
      case "trampoline":
        this.updateTrampoline(dt);
        break;
      case "stacked":
        this.updateStacked();
        break;
    }

    // Check platform validity (if standing on a window that moved/closed)
    if (this.currentPlatform && this.state !== "grabbed" && this.state !== "parachute"
        && this.state !== "fall" && this.state !== "trampoline" && this.state !== "stampede") {
      const p = this.currentPlatform;
      const found = this.platforms.some(wp =>
        Math.abs(wp.x - p.x) < 30 && Math.abs(wp.y - p.y) < 30 && Math.abs(wp.w - p.w) < 30
      );
      if (!found) {
        this.loseGround();
      }
    }
  }

  private setState(newState: SheepState, duration: number = 0) {
    this.state = newState;
    this.stateTimer = 0;
    this.stateDuration = duration;
    const sprite = this.sprites[newState];
    if (sprite) sprite.reset();
  }

  private updateParachute(dt: number) {
    this.vy = 80; // slow fall px/sec
    this.y += this.vy * (dt / 1000);

    // Gentle side-to-side sway
    this.x += Math.sin(this.stateTimer / 500) * 0.5;

    // Check platform landing first
    if (this.checkPlatformLanding()) {
      this.vy = 0;
      this.setState("idle", 2000 + Math.random() * 3000);
      return;
    }

    if (this.y >= this.groundY) {
      this.y = this.groundY;
      this.vy = 0;
      this.currentPlatform = null;
      this.setState("idle", 2000 + Math.random() * 3000);
    }
  }

  private updateIdle() {
    if (this.stateTimer >= this.stateDuration) {
      this.transitionFromIdle();
    }
  }

  private updateWalk(dt: number) {
    const dir = this.facingRight ? 1 : -1;
    this.x += dir * this.walkSpeed * (dt / 1000);

    // If on a window platform, check boundaries
    if (this.currentPlatform) {
      const p = this.currentPlatform;
      if (this.x < p.x - this.displaySize * 0.3 || this.x + this.displaySize > p.x + p.w + this.displaySize * 0.3) {
        // Walked off the edge! Fall with parachute
        this.currentPlatform = null;
        this.state = "parachute";
        this.stateTimer = 0;
        this.vy = 0;
        const sprite = this.sprites["parachute"];
        if (sprite) sprite.reset();
        return;
      }
    }

    if (this.x <= 0) {
      this.x = 0;
      this.facingRight = true;
    } else if (this.x >= this.screenWidth - this.displaySize) {
      this.x = this.screenWidth - this.displaySize;
      this.facingRight = false;
    }

    // Check if we've reached our walk target
    if (this.walkTarget !== null) {
      const dist = Math.abs(this.x - this.walkTarget);
      if (dist < this.displaySize * 1.5) {
        this.walkTarget = null;
        // Arrived near target — sit down together or idle
        if (Math.random() < 0.5) {
          this.setState("sit", 5000 + Math.random() * 8000);
        } else {
          this.setState("idle", 2000 + Math.random() * 4000);
        }
        return;
      }
    }

    if (this.stateTimer >= this.stateDuration) {
      this.walkTarget = null;
      this.setState("idle", 2000 + Math.random() * 6000);
    }
  }

  private updateSit() {
    if (this.stateTimer >= this.stateDuration) {
      this.setState("idle", 1000 + Math.random() * 2000);
    }
  }

  private updateSleep() {
    if (this.stateTimer >= this.stateDuration) {
      this.setState("idle", 1000 + Math.random() * 2000);
    }
  }

  private updateFall(dt: number) {
    this.vy += 800 * (dt / 1000);
    this.y += this.vy * (dt / 1000);

    if (this.checkPlatformLanding()) {
      this.vy = 0;
      this.setState("idle", 1000 + Math.random() * 2000);
      return;
    }

    if (this.y >= this.groundY) {
      this.y = this.groundY;
      this.vy = 0;
      this.currentPlatform = null;
      this.setState("idle", 1000 + Math.random() * 2000);
    }
  }

  private transitionFromIdle() {
    if (this.isBored()) {
      this.transitionToBored();
      return;
    }

    // If we have a walk target, walk toward it with enough time to arrive
    if (this.walkTarget !== null) {
      this.facingRight = this.walkTarget > this.x;
      const dist = Math.abs(this.walkTarget - this.x);
      const duration = Math.max(3000, (dist / WALK_SPEED) * 1000 + 2000);
      this.setState("walk", duration);
      return;
    }

    const w = this.getIdleWeights();
    const roll = Math.random();
    if (roll < w.walk) {
      this.facingRight = Math.random() > 0.5;
      this.setState("walk", 3000 + Math.random() * 7000);
    } else if (roll < w.walk + w.sit) {
      this.setState("sit", 5000 + Math.random() * 10000);
    } else if (roll < w.walk + w.sit + w.sleep) {
      this.setState("sleep", 8000 + Math.random() * 12000);
    } else {
      this.setState("idle", 2000 + Math.random() * 6000);
    }
  }

  private getIdleWeights(): { walk: number; sit: number; sleep: number } {
    const hour = new Date().getHours();
    if (hour >= 23 || hour <= 4) return { walk: 0.2, sit: 0.3, sleep: 0.3 };
    if (hour >= 6 && hour <= 8) return { walk: 0.8, sit: 0.1, sleep: 0.0 };
    if (hour >= 13 && hour <= 14) return { walk: 0.4, sit: 0.35, sleep: 0.1 };
    if (hour >= 18 && hour <= 21) return { walk: 0.45, sit: 0.3, sleep: 0.05 };
    return { walk: 0.7, sit: 0.2, sleep: 0.0 };
  }

  private transitionToBored() {
    // Ensure campfire has room — face away from nearest edge
    if (this.x < this.displaySize * 2) {
      this.facingRight = true;
    } else if (this.x > this.screenWidth - this.displaySize * 3) {
      this.facingRight = false;
    }

    // Personality-specific bored behaviors for friends
    if (this.personality) {
      this.transitionToPersonalityBored();
      return;
    }

    // Easter egg painting chance during Easter season
    if (this.easterTheme?.active && Math.random() < 0.15) {
      this.setState("idle_egg_painting", 12000 + Math.random() * 8000);
      return;
    }

    const bw = this.getBoredWeights();
    const roll = Math.random();
    if (roll < bw.sleep) {
      this.setState("idle_sleep", 15000 + Math.random() * 15000);
    } else if (roll < bw.sleep + bw.campfire) {
      this.campfireSparks = [];
      this.setState("idle_campfire", 15000 + Math.random() * 10000);
    } else {
      this.setState("idle_counting", 10000 + Math.random() * 5000);
    }
  }

  private transitionToPersonalityBored() {
    // Easter egg painting chance during Easter season
    if (this.easterTheme?.active && Math.random() < 0.15) {
      this.setState("idle_egg_painting", 12000 + Math.random() * 8000);
      return;
    }

    const roll = Math.random();
    switch (this.personality) {
      case "chaotic":
        if (roll < 0.4) this.setState("idle_zooming", 8000 + Math.random() * 6000);
        else if (roll < 0.7) { this.campfireSparks = []; this.setState("idle_campfire", 12000 + Math.random() * 8000); }
        else if (roll < 0.9) this.setState("idle_counting", 8000 + Math.random() * 5000);
        else this.setState("idle_sleep", 10000 + Math.random() * 10000);
        break;
      case "wholesome":
        if (roll < 0.4) this.setState("idle_hearts", 10000 + Math.random() * 8000);
        else if (roll < 0.7) this.setState("idle_sleep", 12000 + Math.random() * 12000);
        else if (roll < 0.9) { this.campfireSparks = []; this.setState("idle_campfire", 12000 + Math.random() * 8000); }
        else this.setState("idle_counting", 8000 + Math.random() * 5000);
        break;
      case "snarky":
        if (roll < 0.4) this.setState("idle_judging", 10000 + Math.random() * 8000);
        else if (roll < 0.7) this.setState("idle_counting", 8000 + Math.random() * 5000);
        else if (roll < 0.9) { this.campfireSparks = []; this.setState("idle_campfire", 12000 + Math.random() * 8000); }
        else this.setState("idle_sleep", 10000 + Math.random() * 10000);
        break;
      case "passive-aggressive":
        if (roll < 0.4) this.setState("idle_sighing", 10000 + Math.random() * 8000);
        else if (roll < 0.7) this.setState("idle_sleep", 12000 + Math.random() * 12000);
        else if (roll < 0.9) { this.campfireSparks = []; this.setState("idle_campfire", 12000 + Math.random() * 8000); }
        else this.setState("idle_counting", 8000 + Math.random() * 5000);
        break;
      default: {
        this.campfireSparks = [];
        this.setState("idle_campfire", 12000 + Math.random() * 8000);
      }
    }
  }

  private getBoredWeights(): { sleep: number; campfire: number; counting: number } {
    const hour = new Date().getHours();
    if (hour >= 23 || hour <= 4) return { sleep: 0.7, campfire: 0.1, counting: 0.2 };
    if (hour >= 18 && hour <= 21) return { sleep: 0.2, campfire: 0.55, counting: 0.25 };
    return { sleep: 0.4, campfire: 0.35, counting: 0.25 };
  }

  private updateIdleSleep() {
    if (this.stateTimer >= this.stateDuration) {
      this.setState("idle", 2000 + Math.random() * 3000);
    }
  }

  private updateIdleCampfire(dt: number) {
    // Spawn sparks occasionally
    if (Math.random() < 0.03) {
      const fireX = this.facingRight
        ? this.x + this.displaySize + 10
        : this.x - 25;
      this.campfireSparks.push({
        x: fireX + 5 + Math.random() * 10,
        y: this.groundY + this.displaySize * 0.7,
        life: 1.0,
      });
    }
    // Update sparks
    this.campfireSparks = this.campfireSparks.filter((s) => {
      s.y -= 30 * (dt / 1000);
      s.x += (Math.random() - 0.5) * 20 * (dt / 1000);
      s.life -= 1.5 * (dt / 1000);
      return s.life > 0;
    });

    if (this.stateTimer >= this.stateDuration) {
      this.setState("idle", 2000 + Math.random() * 3000);
    }
  }

  private updateIdleCounting() {
    if (this.stateTimer >= this.stateDuration) {
      this.setState("idle", 2000 + Math.random() * 3000);
    }
  }

  private updateIdleJudging() {
    if (this.stateTimer >= this.stateDuration) {
      this.setState("idle", 2000 + Math.random() * 3000);
    }
  }

  private updateIdleHearts() {
    if (this.stateTimer >= this.stateDuration) {
      this.setState("idle", 2000 + Math.random() * 3000);
    }
  }

  private idleZoomBurst = false;

  private updateIdleZooming(dt: number) {
    // Every ~3s, do a brief zoom burst
    const cycle = this.stateTimer % 3000;
    if (cycle < 300) {
      if (!this.idleZoomBurst) {
        this.idleZoomBurst = true;
        this.facingRight = Math.random() > 0.5;
      }
      const dir = this.facingRight ? 1 : -1;
      this.x += dir * 400 * (dt / 1000);
      // Clamp to screen
      if (this.x <= 0) { this.x = 0; this.facingRight = true; }
      else if (this.x >= this.screenWidth - this.displaySize) {
        this.x = this.screenWidth - this.displaySize;
        this.facingRight = false;
      }
    } else if (this.idleZoomBurst) {
      this.idleZoomBurst = false;
    }

    if (this.stateTimer >= this.stateDuration) {
      this.setState("idle", 2000 + Math.random() * 3000);
    }
  }

  private updateIdleSighing() {
    if (this.stateTimer >= this.stateDuration) {
      this.setState("idle", 2000 + Math.random() * 3000);
    }
  }

  private updateIdleEggPainting() {
    if (this.stateTimer >= this.stateDuration) {
      this.setState("idle", 2000 + Math.random() * 3000);
    }
  }

  private updateStampede(dt: number) {
    const dir = this.facingRight ? 1 : -1;
    const speed = ZOOM_SPEED * 1.5;
    this.x += dir * speed * (dt / 1000);

    if (this.x <= 0) {
      this.x = 0;
      this.setState("idle", 2000 + Math.random() * 3000);
      return;
    }
    if (this.x >= this.screenWidth - this.displaySize) {
      this.x = this.screenWidth - this.displaySize;
      this.setState("idle", 2000 + Math.random() * 3000);
      return;
    }

    if (this.stateTimer >= this.stateDuration) {
      this.setState("idle", 2000 + Math.random() * 3000);
    }
  }

  private updateTrampoline(dt: number) {
    const GRAVITY = 1200;
    const BOUNCE_DAMPING = 0.68;
    const MAX_BOUNCES = 5;
    const MIN_BOUNCE_VEL = 120;

    this.vy += GRAVITY * (dt / 1000);
    this.y += this.vy * (dt / 1000);

    // Flip while airborne
    if (this.y < this.groundY) {
      this.trampolineFlipProgress += dt / 350;
    }

    if (this.y >= this.groundY) {
      this.y = this.groundY;
      this.trampolineBounces++;
      this.trampolineFlipProgress = 0;

      if (this.trampolineBounces >= MAX_BOUNCES || Math.abs(this.vy) * BOUNCE_DAMPING < MIN_BOUNCE_VEL) {
        this.vy = 0;
        this.setState("idle", 1000 + Math.random() * 2000);
        return;
      }

      // Bounce!
      this.vy = -Math.abs(this.vy) * BOUNCE_DAMPING;
    }

    if (this.stateTimer >= this.stateDuration) {
      this.y = this.groundY;
      this.vy = 0;
      this.setState("idle", 1000 + Math.random() * 2000);
    }
  }

  private updateStacked() {
    if (!this.stackedOn) {
      this.vy = -100;
      this.setState("fall", 0);
      return;
    }

    const target = this.stackedOn;
    this.x = target.x + (target.displaySize - this.displaySize) / 2;
    this.y = target.y - this.displaySize * 0.7;
    this.facingRight = target.facingRight;

    // Unstack if bottom sheep enters a wild state
    if (target.state === "stampede" || target.state === "zoom" || target.state === "grabbed"
        || target.state === "trampoline" || target.state === "backflip") {
      this.unstack();
      this.vy = -200;
      this.setState("fall", 0);
    }
  }

  /** Check if the sheep should land on a window platform during fall/parachute */
  private checkPlatformLanding(): boolean {
    for (const p of this.platforms) {
      const landY = p.y - this.displaySize;
      // Only land on platforms that are above the ground
      if (landY >= this.groundY) continue;
      if (this.y >= landY && this.y - 10 < landY + 20) {
        if (this.x + this.displaySize > p.x && this.x < p.x + p.w) {
          this.y = landY;
          this.currentPlatform = p;
          return true;
        }
      }
    }
    return false;
  }

  /** Map states to sprite sheet keys */
  private getSpriteKey(): string {
    switch (this.state) {
      case "grabbed": return "fall";
      case "petting": return "sleep";
      case "bounce": return "idle";
      case "spin": return "walk";
      case "backflip": return "fall";
      case "headshake": return "idle";
      case "zoom": return "walk";
      case "vibrate": return "idle";
      case "idle_sleep": return "sleep";
      case "idle_campfire": return "sit";
      case "idle_counting": return "idle";
      case "idle_judging": return "idle";
      case "idle_hearts": return "sit";
      case "idle_zooming": return "walk";
      case "idle_sighing": return "sit";
      case "idle_egg_painting": return "sit";
      case "stampede": return "walk";
      case "trampoline": return "fall";
      case "stacked": return "sit";
      default: return this.state;
    }
  }

  private updateBounce(dt: number) {
    this.vy += 800 * (dt / 1000); // gravity
    this.y += this.vy * (dt / 1000);

    if (this.y >= this.groundY) {
      this.y = this.groundY;
      if (this.stateTimer >= this.stateDuration) {
        this.setState("idle", 1000 + Math.random() * 2000);
      } else {
        this.vy = -200; // smaller re-bounce
      }
    }
  }

  private updateTimedAnimation() {
    if (this.stateTimer >= this.stateDuration) {
      this.y = this.groundY;
      this.setState("idle", 1000 + Math.random() * 2000);
    }
  }

  private updateZoom(dt: number) {
    const dir = this.facingRight ? 1 : -1;
    this.x += dir * ZOOM_SPEED * (dt / 1000);

    // Bounce off edges
    if (this.x <= 0) {
      this.x = 0;
      this.facingRight = true;
    } else if (this.x >= this.screenWidth - this.displaySize) {
      this.x = this.screenWidth - this.displaySize;
      this.facingRight = false;
    }

    if (this.stateTimer >= this.stateDuration) {
      this.setState("idle", 1000 + Math.random() * 2000);
    }
  }

  draw(ctx: CanvasRenderingContext2D) {
    const spriteKey = this.getSpriteKey();
    const sprite = this.sprites[spriteKey];
    if (!sprite) return;

    const cx = this.x + this.displaySize / 2;
    const cy = this.y + this.displaySize / 2;
    const t = this.tint ?? undefined;

    switch (this.state) {
      case "grabbed": {
        const wiggle = Math.sin(this.stateTimer / 60) * 0.18;
        ctx.save();
        ctx.translate(cx, cy);
        ctx.rotate(wiggle);
        ctx.translate(-cx, -cy);
        sprite.draw(ctx, this.x, this.y, this.drawScale, !this.facingRight, t);
        ctx.restore();
        break;
      }

      case "petting": {
        // Gentle happy sway
        const sway = Math.sin(this.stateTimer / 300) * 0.05;
        ctx.save();
        ctx.translate(cx, cy);
        ctx.rotate(sway);
        ctx.translate(-cx, -cy);
        sprite.draw(ctx, this.x, this.y, this.drawScale, !this.facingRight, t);
        ctx.restore();
        break;
      }

      case "bounce": {
        // Squash and stretch based on vertical velocity
        const squash = 1 + Math.abs(this.vy) * 0.001;
        const scaleX = 1 / squash;
        const scaleY = squash;
        ctx.save();
        ctx.translate(cx, this.y + this.displaySize);
        ctx.scale(scaleX, scaleY);
        ctx.translate(-cx, -(this.y + this.displaySize));
        sprite.draw(ctx, this.x, this.y, this.drawScale, !this.facingRight, t);
        ctx.restore();
        break;
      }

      case "spin": {
        const angle = (this.stateTimer / this.stateDuration) * Math.PI * 2;
        ctx.save();
        ctx.translate(cx, cy);
        ctx.rotate(angle);
        ctx.translate(-cx, -cy);
        sprite.draw(ctx, this.x, this.y, this.drawScale, !this.facingRight, t);
        ctx.restore();
        break;
      }

      case "backflip": {
        const progress = this.stateTimer / this.stateDuration;
        const angle = progress * Math.PI * 2;
        // Arc up then down
        const arcY = this.y - Math.sin(progress * Math.PI) * 80;
        const arcCy = arcY + this.displaySize / 2;
        ctx.save();
        ctx.translate(cx, arcCy);
        ctx.rotate(-angle);
        ctx.translate(-cx, -arcCy);
        sprite.draw(ctx, this.x, arcY, this.drawScale, !this.facingRight, t);
        ctx.restore();
        break;
      }

      case "headshake": {
        const shake = Math.sin(this.stateTimer / 30) * 8;
        ctx.save();
        ctx.translate(shake, 0);
        sprite.draw(ctx, this.x, this.y, this.drawScale, !this.facingRight, t);
        ctx.restore();
        break;
      }

      case "zoom": {
        // Lean forward + motion blur via slight horizontal stretch
        const lean = this.facingRight ? -0.2 : 0.2;
        ctx.save();
        ctx.translate(cx, cy);
        ctx.rotate(lean);
        ctx.scale(1.15, 0.9);
        ctx.translate(-cx, -cy);
        sprite.draw(ctx, this.x, this.y, this.drawScale, !this.facingRight, t);

        // Speed lines (afterimages)
        ctx.globalAlpha = 0.15;
        const trailDir = this.facingRight ? -1 : 1;
        sprite.draw(ctx, this.x + trailDir * 30, this.y, this.drawScale, !this.facingRight, t);
        ctx.globalAlpha = 0.07;
        sprite.draw(ctx, this.x + trailDir * 60, this.y, this.drawScale, !this.facingRight, t);
        ctx.restore();
        break;
      }

      case "vibrate": {
        const ox = (Math.random() - 0.5) * 6;
        const oy = (Math.random() - 0.5) * 6;
        sprite.draw(ctx, this.x + ox, this.y + oy, this.drawScale, !this.facingRight, t);
        break;
      }

      case "stampede": {
        // Heavy lean forward + aggressive speed lines
        const stampLean = this.facingRight ? -0.25 : 0.25;
        ctx.save();
        ctx.translate(cx, cy);
        ctx.rotate(stampLean);
        ctx.scale(1.2, 0.85);
        ctx.translate(-cx, -cy);
        sprite.draw(ctx, this.x, this.y, this.drawScale, !this.facingRight, t);
        const stampTrail = this.facingRight ? -1 : 1;
        ctx.globalAlpha = 0.2;
        sprite.draw(ctx, this.x + stampTrail * 25, this.y, this.drawScale, !this.facingRight, t);
        ctx.globalAlpha = 0.1;
        sprite.draw(ctx, this.x + stampTrail * 50, this.y, this.drawScale, !this.facingRight, t);
        ctx.globalAlpha = 0.05;
        sprite.draw(ctx, this.x + stampTrail * 75, this.y, this.drawScale, !this.facingRight, t);
        ctx.restore();
        break;
      }

      case "trampoline": {
        // Squash/stretch + flip rotation
        const tSquash = 1 + Math.abs(this.vy) * 0.0006;
        const tScaleX = 1 / tSquash;
        const tScaleY = tSquash;
        const flipAngle = this.trampolineFlipProgress * Math.PI * 2;
        ctx.save();
        ctx.translate(cx, cy);
        ctx.rotate(flipAngle);
        ctx.scale(tScaleX, tScaleY);
        ctx.translate(-cx, -cy);
        sprite.draw(ctx, this.x, this.y, this.drawScale, !this.facingRight, t);
        ctx.restore();
        break;
      }

      case "stacked": {
        // Gentle wobble
        const wobble = Math.sin(this.stateTimer / 300) * 0.08;
        ctx.save();
        ctx.translate(cx, cy);
        ctx.rotate(wobble);
        ctx.translate(-cx, -cy);
        sprite.draw(ctx, this.x, this.y, this.drawScale, !this.facingRight, t);
        ctx.restore();
        break;
      }

      default:
        sprite.draw(ctx, this.x, this.y, this.drawScale, !this.facingRight, t);
        break;
    }

    // Draw emote particles for certain animations
    this.drawEmoteParticles(ctx);

    // Draw character-specific overlay (accessories etc.)
    if (this.drawOverlay) {
      this.drawOverlay(ctx, this.x, this.y, this.displaySize, this.facingRight, this.state);
    }

    // Name tag for non-main sheep during calm states
    if (this.id !== "main" && this.name !== "Sheep") {
      const calm = this.state === "idle" || this.state === "sit" || this.state === "walk"
        || this.state === "sleep" || this.state === "petting";
      if (calm && this.nameTagAlpha < 1) {
        this.nameTagAlpha = Math.min(1, this.nameTagAlpha + 0.05);
      } else if (!calm && this.nameTagAlpha > 0) {
        this.nameTagAlpha = Math.max(0, this.nameTagAlpha - 0.05);
      }
      if (this.nameTagAlpha > 0) {
        const ds = this.displaySize;
        const tagCx = this.x + ds / 2;
        const tagY = this.y + ds + 14;
        ctx.save();
        ctx.globalAlpha = this.nameTagAlpha * 0.7;
        ctx.font = "10px monospace";
        const tw = ctx.measureText(this.name).width;
        ctx.fillStyle = "rgba(26, 26, 46, 0.6)";
        ctx.beginPath();
        ctx.roundRect(tagCx - tw / 2 - 4, tagY - 9, tw + 8, 14, 3);
        ctx.fill();
        ctx.fillStyle = "#ccc";
        ctx.globalAlpha = this.nameTagAlpha * 0.9;
        ctx.textAlign = "center";
        ctx.fillText(this.name, tagCx, tagY);
        ctx.restore();
      }
    }
  }

  private drawEmoteParticles(ctx: CanvasRenderingContext2D) {
    const cx = this.x + this.displaySize / 2;
    const top = this.y - 10;

    if (this.state === "petting") {
      // Floating hearts
      ctx.save();
      ctx.font = "14px serif";
      const t = this.stateTimer / 600;
      const heartCount = 3;
      for (let i = 0; i < heartCount; i++) {
        const phase = t + i * 2.1;
        const hx = cx + Math.sin(phase * 1.5) * 25 - 8;
        const hy = top - (phase % 3) * 20;
        ctx.globalAlpha = 1 - (phase % 3) / 3;
        ctx.fillText("\u{2764}\u{FE0F}", hx, hy);
      }
      ctx.restore();
    }

    if (this.state === "bounce" && this.vy < -50) {
      // Sparkles on upward bounce
      ctx.save();
      ctx.fillStyle = "#FFD700";
      ctx.font = "16px serif";
      const sparkleY = top - Math.sin(this.stateTimer / 100) * 15;
      ctx.fillText("\u2728", cx - 20, sparkleY);
      ctx.fillText("\u2728", cx + 10, sparkleY - 8);
      ctx.restore();
    }

    if (this.state === "vibrate") {
      // Angry marks
      ctx.save();
      ctx.fillStyle = "#e94560";
      ctx.font = "18px serif";
      const pulse = 0.8 + Math.sin(this.stateTimer / 50) * 0.2;
      ctx.globalAlpha = pulse;
      ctx.fillText("\u{1F4A2}", cx - 8, top - 5);
      ctx.restore();
    }

    if (this.state === "idle_sleep") {
      this.drawSleepZzz(ctx, cx, top);
    }

    if (this.state === "idle_campfire") {
      this.drawCampfire(ctx);
    }

    if (this.state === "idle_counting") {
      this.drawCountingSheep(ctx, cx, top);
    }

    if (this.state === "idle_judging") {
      this.drawJudging(ctx, cx, top);
    }

    if (this.state === "idle_hearts") {
      this.drawIdleHearts(ctx, cx, top);
    }

    if (this.state === "idle_zooming" && this.idleZoomBurst) {
      // Speed lines during zoom bursts
      ctx.save();
      ctx.strokeStyle = "rgba(233, 69, 96, 0.3)";
      ctx.lineWidth = 1;
      const dir = this.facingRight ? -1 : 1;
      for (let i = 0; i < 3; i++) {
        const ly = this.y + 20 + i * 25;
        ctx.beginPath();
        ctx.moveTo(cx + dir * 20, ly);
        ctx.lineTo(cx + dir * 50, ly + (Math.random() - 0.5) * 4);
        ctx.stroke();
      }
      ctx.restore();
    }

    if (this.state === "idle_sighing") {
      this.drawSighing(ctx, cx, top);
    }

    if (this.state === "idle_egg_painting") {
      this.drawEggPainting(ctx);
    }

    if (this.state === "stampede") {
      // Panic exclamation marks
      ctx.save();
      ctx.font = "bold 16px monospace";
      ctx.fillStyle = "#e94560";
      const panic = Math.sin(this.stateTimer / 80) * 4;
      ctx.globalAlpha = 0.8;
      ctx.fillText("!", cx - 4 + panic, top - 8);
      ctx.fillText("!", cx + 8 - panic, top - 14);
      ctx.restore();
    }

    if (this.state === "trampoline") {
      // "BOING" on bounce (when near ground and going up)
      if (this.vy < -100 && this.y > this.groundY - 60) {
        ctx.save();
        ctx.font = "bold 12px monospace";
        ctx.fillStyle = "#FFD700";
        ctx.globalAlpha = 0.9;
        ctx.fillText("BOING!", cx - 20, top - 10);
        ctx.restore();
      }
      // Sparkles while airborne
      if (this.y < this.groundY - 30) {
        ctx.save();
        ctx.fillStyle = "#FFD700";
        ctx.font = "14px serif";
        const sparkT = this.stateTimer / 150;
        ctx.globalAlpha = 0.6;
        ctx.fillText("\u2728", cx - 25 + Math.sin(sparkT) * 10, top - 5);
        ctx.fillText("\u2728", cx + 15 + Math.cos(sparkT) * 8, top + 10);
        ctx.restore();
      }
    }

    if (this.state === "stacked") {
      // Balancing wobble indicator
      const wobbleT = this.stateTimer / 500;
      if (Math.sin(wobbleT * 2) > 0.7) {
        ctx.save();
        ctx.font = "10px monospace";
        ctx.fillStyle = "rgba(233, 69, 96, 0.5)";
        ctx.fillText("~", cx + this.displaySize * 0.3, top + 5);
        ctx.restore();
      }
    }
  }

  private drawSleepZzz(ctx: CanvasRenderingContext2D, cx: number, top: number) {
    ctx.save();
    const t = this.stateTimer / 1000;
    for (let i = 0; i < 3; i++) {
      const phase = (t * 0.6 + i * 1.4) % 4;
      const zx = cx + 12 + i * 10 + Math.sin(phase * 1.8) * 8;
      const zy = top - phase * 16;
      const size = 11 + i * 4;
      ctx.globalAlpha = Math.max(0, 1 - phase / 4);
      ctx.font = `bold ${size}px monospace`;
      ctx.fillStyle = "#8a9bb5";
      ctx.fillText("Z", zx, zy);
    }
    ctx.restore();
  }

  private drawCampfire(ctx: CanvasRenderingContext2D) {
    const fireX = this.facingRight
      ? this.x + this.displaySize + 8
      : this.x - 28;
    const baseY = this.groundY + this.displaySize - 8;

    // Logs
    ctx.fillStyle = "#6B3A2A";
    ctx.fillRect(fireX, baseY + 2, 20, 5);
    ctx.fillStyle = "#8B4513";
    ctx.fillRect(fireX + 3, baseY - 2, 14, 5);

    // Fire — flickering pixel flames
    const t = this.stateTimer / 120;
    const flicker1 = Math.sin(t) * 2;
    const flicker2 = Math.cos(t * 1.3) * 2;

    // Outer flame (orange-red)
    ctx.fillStyle = "#E8530E";
    ctx.fillRect(fireX + 4, baseY - 10 + flicker1, 12, 12);
    // Mid flame (orange)
    ctx.fillStyle = "#FF8C00";
    ctx.fillRect(fireX + 6, baseY - 14 + flicker2, 8, 10);
    // Inner flame (yellow)
    ctx.fillStyle = "#FFD700";
    ctx.fillRect(fireX + 8, baseY - 16 + flicker1 * 0.7, 5, 7);
    // Hot core (white-yellow)
    ctx.fillStyle = "#FFF4C0";
    ctx.fillRect(fireX + 9, baseY - 12 + flicker2 * 0.5, 3, 4);

    // Sparks
    ctx.fillStyle = "#FFD700";
    for (const spark of this.campfireSparks) {
      ctx.globalAlpha = spark.life;
      ctx.fillRect(spark.x, spark.y, 2, 2);
    }
    ctx.globalAlpha = 1;

    // Warm glow
    ctx.save();
    const gradient = ctx.createRadialGradient(
      fireX + 10, baseY - 6, 3,
      fireX + 10, baseY - 6, 50,
    );
    gradient.addColorStop(0, "rgba(255, 150, 50, 0.12)");
    gradient.addColorStop(1, "rgba(255, 150, 50, 0)");
    ctx.fillStyle = gradient;
    ctx.beginPath();
    ctx.arc(fireX + 10, baseY - 6, 50, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }

  private drawCountingSheep(
    ctx: CanvasRenderingContext2D,
    cx: number,
    top: number,
  ) {
    const elapsed = this.stateTimer / 1000;
    const sheepCount = Math.floor(elapsed / 2.5); // One every 2.5s

    for (let i = 0; i <= Math.min(sheepCount, 6); i++) {
      const t = elapsed - i * 2.5;
      if (t < 0) continue;
      const loopT = t % 3;
      if (loopT > 2.8) continue; // brief gap between loops

      const progress = loopT / 2.8;
      const miniX = cx - 35 + progress * 70;
      const arcHeight = Math.sin(progress * Math.PI) * 45;
      const miniY = top - 15 - arcHeight;

      ctx.save();
      ctx.globalAlpha = 0.8;
      // Mini sheep body (white fluffy blob)
      ctx.fillStyle = "#F0F0F0";
      ctx.fillRect(miniX, miniY, 9, 6);
      // Head
      ctx.fillStyle = "#444";
      ctx.fillRect(miniX + 7, miniY - 2, 3, 4);
      // Legs (animate based on progress)
      const legBob = Math.sin(progress * Math.PI * 4) > 0 ? 0 : 1;
      ctx.fillRect(miniX + 1, miniY + 6, 2, 2 + legBob);
      ctx.fillRect(miniX + 5, miniY + 6, 2, 2 + (1 - legBob));
      ctx.restore();
    }

    // Counter bubble
    if (sheepCount > 0) {
      ctx.save();
      ctx.font = "bold 11px monospace";
      ctx.fillStyle = "rgba(180, 190, 210, 0.7)";
      ctx.fillText(`${Math.min(sheepCount, 99)}`, cx + 30, top - 50);
      ctx.restore();
    }
  }

  private drawJudging(ctx: CanvasRenderingContext2D, cx: number, top: number) {
    ctx.save();
    const t = this.stateTimer / 1000;
    // Floating magnifying glass that slowly sways
    const mx = cx + Math.sin(t * 0.8) * 12;
    const my = top - 15 + Math.sin(t * 1.2) * 4;
    ctx.globalAlpha = 0.7;
    // Glass circle
    ctx.strokeStyle = "#DAA520";
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(mx, my, 7, 0, Math.PI * 2);
    ctx.stroke();
    // Lens shine
    ctx.fillStyle = "rgba(180, 220, 255, 0.15)";
    ctx.beginPath();
    ctx.arc(mx, my, 6, 0, Math.PI * 2);
    ctx.fill();
    // Handle
    ctx.strokeStyle = "#8B4513";
    ctx.lineWidth = 2.5;
    ctx.beginPath();
    ctx.moveTo(mx + 5, my + 5);
    ctx.lineTo(mx + 12, my + 12);
    ctx.stroke();
    // Occasional subtle headshake offset
    if (Math.sin(t * 2) > 0.8) {
      ctx.font = "bold 10px monospace";
      ctx.fillStyle = "rgba(233, 69, 96, 0.5)";
      ctx.fillText("hmm", cx + 20, top - 25);
    }
    ctx.restore();
  }

  private drawIdleHearts(ctx: CanvasRenderingContext2D, cx: number, top: number) {
    ctx.save();
    ctx.font = "12px serif";
    const t = this.stateTimer / 1000;
    for (let i = 0; i < 2; i++) {
      const phase = (t * 0.4 + i * 1.8) % 3.5;
      const hx = cx + Math.sin(phase * 1.2 + i) * 20 - 6;
      const hy = top - phase * 15;
      ctx.globalAlpha = Math.max(0, 0.6 - phase / 3.5);
      ctx.fillText("\u{2764}\u{FE0F}", hx, hy);
    }
    ctx.restore();
  }

  private drawSighing(ctx: CanvasRenderingContext2D, cx: number, top: number) {
    ctx.save();
    const t = this.stateTimer / 1000;
    // "..." text bubble
    const dotPhase = Math.floor(t * 1.5) % 4;
    const dots = ".".repeat(Math.min(dotPhase + 1, 3));
    ctx.font = "bold 14px monospace";
    ctx.fillStyle = "rgba(150, 150, 170, 0.6)";
    ctx.globalAlpha = 0.7 + Math.sin(t) * 0.2;
    ctx.fillText(dots, cx - 10, top - 10);
    // Small cloud puffs drifting up
    for (let i = 0; i < 2; i++) {
      const pPhase = (t * 0.5 + i * 1.5) % 3;
      const px = cx + 15 + i * 8 + Math.sin(pPhase + i) * 5;
      const py = top - 20 - pPhase * 12;
      ctx.globalAlpha = Math.max(0, 0.3 - pPhase / 3);
      ctx.fillStyle = "#888";
      ctx.beginPath();
      ctx.arc(px, py, 3, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  }

  private drawEggPainting(ctx: CanvasRenderingContext2D) {
    const eggX = this.facingRight
      ? this.x + this.displaySize + 8
      : this.x - 22;
    const baseY = this.groundY + this.displaySize - 4;
    const progress = Math.min(1, this.stateTimer / (this.stateDuration - 2000)); // 0..1

    ctx.save();

    // Egg (white oval)
    ctx.fillStyle = "#FFFFF0";
    ctx.beginPath();
    ctx.ellipse(eggX + 7, baseY - 4, 6, 9, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = "#DDD";
    ctx.lineWidth = 0.5;
    ctx.stroke();

    // Progressive paint stripes (appear as progress increases)
    const stripeColors = ["#FFB6C1", "#B0E2AC", "#C8B4E6", "#FFFACD"];
    for (let i = 0; i < 4; i++) {
      if (progress > (i + 1) / 5) {
        ctx.fillStyle = stripeColors[i];
        const sy = baseY - 10 + i * 4;
        ctx.fillRect(eggX + 2, sy, 10, 2);
      }
    }

    // Tiny dots decoration (appear later)
    if (progress > 0.7) {
      ctx.fillStyle = "#FFD700";
      ctx.beginPath();
      ctx.arc(eggX + 5, baseY - 6, 1.5, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(eggX + 9, baseY - 2, 1.5, 0, Math.PI * 2);
      ctx.fill();
    }

    // Brush (brown line near egg)
    const brushBob = Math.sin(this.stateTimer / 200) * 2;
    ctx.strokeStyle = "#8B4513";
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(eggX + 14, baseY - 8 + brushBob);
    ctx.lineTo(eggX + 20, baseY - 16 + brushBob);
    ctx.stroke();
    // Brush tip
    ctx.fillStyle = stripeColors[Math.floor(this.stateTimer / 800) % stripeColors.length];
    ctx.beginPath();
    ctx.arc(eggX + 14, baseY - 8 + brushBob, 2, 0, Math.PI * 2);
    ctx.fill();

    // Sparkle when done (last 2s)
    if (this.stateTimer > this.stateDuration - 2000) {
      const sparkAlpha = Math.sin(this.stateTimer / 100) * 0.5 + 0.5;
      ctx.globalAlpha = sparkAlpha;
      ctx.fillStyle = "#FFD700";
      ctx.font = "12px serif";
      ctx.fillText("\u2728", eggX - 2, baseY - 16);
      ctx.fillText("\u2728", eggX + 12, baseY - 14);
    }

    ctx.restore();
  }
}

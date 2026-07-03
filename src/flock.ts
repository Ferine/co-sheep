import { Sheep, DrawOverlay } from "./sheep";
import { SpeechBubble } from "./speech-bubble";
import { ConversationScript, FriendConfig, FriendPersonality, FRIEND_TINTS, SheepAnimation, SheepState, WindowPlatform } from "./types";
import { pickConversation, ConversationContext } from "./conversations";
import { NightAmbience } from "./night-ambience";
import { WeatherEffects } from "./weather-effects";
import { getPersonalityQuips, getPersonalityAnimBias } from "./friend-personalities";
import { createCompositeOverlay, drawEasterBasket } from "./accessories";
import { EasterHuntSummary, GroupActivity, canStartGroupActivity, createGroupActivity, pickActivityType, updateGroupActivity } from "./group-activities";
import { EasterStatsSnapshot, EasterTheme } from "./easter-theme";
import { SummerTheme, SUMMER_IDLE_QUIPS } from "./summer-theme";
import { invoke } from "@tauri-apps/api/core";
import { bus } from "./events";
import { SPECTACLE, SpectacleSchedulerState, SpectacleType, markFired, pickRandomSpectacle } from "./spectacles";
import { SpectacleScene, SpectacleWorld, createSpectacleScene, drawSpectacleScene, updateSpectacleScene } from "./spectacle-render";

const GOOD_COLLEAGUE_QUIPS = [
  "No blir det liv rai rai",
  "Fakyou",
  "Langt oppi b\u00F8ttebaletten",
  "N\u00E5 blir det godt med medda",
  "N\u00E5 er det tomt alts\u00E5",
  "Tai tai tai tai",
  "N\u00E5 er det bare pausemusikk",
  "N\u00E5 er hodet tygd og spytta p\u00E5",
  "Hjernen alene hjemme",
  "Kan du sette opp en kjapp apostel",
  "Tidenes forundringspakke er ikke forbi",
  "De setter opp artium hus p\u00E5 skorpa",
  "Alle kluter til",
  "Hvis vi kan kalle inn ham og hans undersl\u00E5tte, s\u00E5 ville det v\u00E6rt fint",
  "Viktig \u00E5 tenke gjennom dette s\u00E5 vi ikke lager slike dirty fries",
  "Da er det bare \u00E5 stride til verket",
  "Da greip \u00E6 mitt snitt \u00E6",
  "Kontrolert brud",
];

const DISPLAY_SIZE = 96; // 32 * 3
const EASTER_IDLE_QUIPS = [
  "I can smell fresh paint.",
  "Spring logistics are underway.",
  "This meadow is suspiciously egg-shaped.",
];
const EASTER_POST_HUNT_QUIPS = [
  "I should've hidden them better.",
  "We absolutely crushed that hunt.",
  "I am still thinking about the golden egg.",
];

interface PendingReaction {
  text: string;
  animation?: SheepAnimation;
  delay: number;
}

interface FriendEntry {
  sheep: Sheep;
  bubble: SpeechBubble;
  quips: string[];
  nextQuipTime: number;
  personality: FriendPersonality;
  pendingReaction?: PendingReaction;
}

/** Draw Good Colleague's accessories: glasses, tie, and coffee mug */
const drawGoodColleagueOverlay: DrawOverlay = (
  ctx, x, y, size, facingRight, state,
) => {
  const s = size / 32; // scale factor (3)

  // Head position varies with facing direction
  const headX = facingRight ? x + size * 0.65 : x + size * 0.15;
  const headY = y + size * 0.3;

  // --- Tiny round glasses ---
  ctx.save();
  ctx.strokeStyle = "#2a2a3a";
  ctx.lineWidth = 1.5;
  const glassR = 3 * s;
  const glassGap = 2.5 * s;
  const glassY = headY + 2 * s;
  const gl = headX - glassGap / 2 - glassR;
  const gr = headX + glassGap / 2 + glassR;
  // Left lens
  ctx.beginPath();
  ctx.arc(gl, glassY, glassR, 0, Math.PI * 2);
  ctx.stroke();
  // Right lens
  ctx.beginPath();
  ctx.arc(gr, glassY, glassR, 0, Math.PI * 2);
  ctx.stroke();
  // Bridge
  ctx.beginPath();
  ctx.moveTo(gl + glassR, glassY);
  ctx.lineTo(gr - glassR, glassY);
  ctx.stroke();
  // Lens shine
  ctx.fillStyle = "rgba(180, 220, 255, 0.25)";
  ctx.beginPath();
  ctx.arc(gl, glassY, glassR - 1, 0, Math.PI * 2);
  ctx.fill();
  ctx.beginPath();
  ctx.arc(gr, glassY, glassR - 1, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();

  // --- Tiny tie ---
  const tieX = facingRight ? x + size * 0.48 : x + size * 0.42;
  const tieY = y + size * 0.55;
  ctx.save();
  ctx.fillStyle = "#c0392b";
  // Knot
  ctx.fillRect(tieX - 1.5 * s, tieY, 3 * s, 2 * s);
  // Triangle body
  ctx.beginPath();
  ctx.moveTo(tieX - 1.5 * s, tieY + 2 * s);
  ctx.lineTo(tieX + 1.5 * s, tieY + 2 * s);
  ctx.lineTo(tieX, tieY + 7 * s);
  ctx.closePath();
  ctx.fill();
  ctx.restore();

  // --- Coffee mug (only when idle/sitting) ---
  const restingStates: SheepState[] = ["idle", "sit", "idle_sleep", "idle_campfire", "idle_counting", "idle_egg_painting"];
  if (restingStates.includes(state)) {
    const mugX = facingRight ? x + size * 0.82 : x + size * 0.02;
    const mugY = y + size * 0.6;
    ctx.save();
    // Mug body
    ctx.fillStyle = "#f5f5f0";
    ctx.fillRect(mugX, mugY, 5 * s, 6 * s);
    // Coffee
    ctx.fillStyle = "#6F4E37";
    ctx.fillRect(mugX + 0.5 * s, mugY + 1 * s, 4 * s, 3 * s);
    // Handle
    ctx.strokeStyle = "#f5f5f0";
    ctx.lineWidth = 1.5;
    const handleX = facingRight ? mugX + 5 * s : mugX;
    const handleDir = facingRight ? 1 : -1;
    ctx.beginPath();
    ctx.arc(handleX, mugY + 3 * s, 2 * s, -Math.PI / 2 * handleDir, Math.PI / 2 * handleDir);
    ctx.stroke();
    // Steam wisps
    const st = Date.now() / 800;
    ctx.strokeStyle = "rgba(200, 200, 200, 0.4)";
    ctx.lineWidth = 1;
    for (let i = 0; i < 2; i++) {
      const sx = mugX + (1.5 + i * 2) * s;
      const sy = mugY - 1 * s;
      ctx.beginPath();
      ctx.moveTo(sx, sy);
      ctx.quadraticCurveTo(
        sx + Math.sin(st + i) * 2 * s,
        sy - 3 * s,
        sx + Math.sin(st + i + 1) * 1.5 * s,
        sy - 5 * s,
      );
      ctx.stroke();
    }
    ctx.restore();
  }
};

export class Flock {
  readonly main: Sheep;
  readonly mainBubble: SpeechBubble;
  private friends: Map<string, FriendEntry> = new Map();
  private screenWidth: number;
  private screenHeight: number;
  private socialTimer: number = 0;
  private activeConversation: {
    lines: ConversationScript;
    currentIndex: number;
    timer: number;
    participants: Set<string>;
  } | null = null;
  private conversationCooldown: number = 0;
  private nightAmbience: NightAmbience;
  private weatherEffects: WeatherEffects;
  private easterTheme: EasterTheme;
  private summerTheme: SummerTheme;
  private reactiveCooldown: number = 0;
  private currentWeatherCondition: string | null = null;
  private lastNotificationHour: number = -1;
  private notificationCooldown: number = 0;
  private hasGreetedOnLaunch: boolean = false;
  private launchTimer: number = 0;
  private groupActivity: GroupActivity | null = null;
  private groupActivityCooldown: number = 0;
  private aiChatPending: boolean = false;
  private aiChatCooldown: number = 0;
  private spectacle: SpectacleScene | null = null;
  private spectacleSchedulerState: SpectacleSchedulerState = { lastFiredMs: 0, lastByType: {} };
  private spectacleCheckTimer = 0;
  private spectacleStateLoaded = false;
  /** main.ts points this at dramaManager.resolveShowdown. */
  onShowdownResolved: ((pair: [string, string], reconciled: boolean) => void) | null = null;

  // Stampede
  private stampedeCooldown: number = 0;
  private stampedeActive: boolean = false;
  private stampedeDialogueTimer: number = 0;


  /** Callback set by main.ts when break reminder fires */
  onBreakReminderFired: (() => void) | null = null;

  /** Installed by DramaManager: filters group-activity participant lists (drops feuders). */
  participantFilter: ((ids: string[]) => string[]) | null = null;

  constructor(screenWidth: number, screenHeight: number) {
    this.screenWidth = screenWidth;
    this.screenHeight = screenHeight;

    this.nightAmbience = new NightAmbience(screenWidth, screenHeight);
    this.weatherEffects = new WeatherEffects();
    this.easterTheme = new EasterTheme(screenWidth, screenHeight);
    this.summerTheme = new SummerTheme(screenWidth, screenHeight);

    // Create main sheep
    this.main = new Sheep(screenWidth, screenHeight, "main");
    this.main.setEasterTheme(this.easterTheme);
    this.attachSeasonalOverlay(this.main);
    this.mainBubble = new SpeechBubble(true);

    // Wire AI commentary animations to main sheep
    this.mainBubble.onAnimation = (anim) => {
      console.log("[co-sheep] Triggering animation from AI:", anim);
      this.cancelConversation(); // AI commentary takes priority
      this.main.resetActivity();
      this.main.playAnimation(anim);
      // Friends react to AI commentary
      this.triggerFriendReactions("commentary");
      bus.emit("ai-commentary", { animation: anim });
    };

    // Spawn Good Colleague after a short delay
    setTimeout(() => {
      this.spawnGoodColleague();
    }, 3000);

    invoke<SpectacleSchedulerState | null>("get_living_state", { name: "spectacles" })
      .then((s) => {
        if (s && typeof s.lastFiredMs === "number") this.spectacleSchedulerState = s;
        this.spectacleStateLoaded = true;
      })
      .catch(() => { this.spectacleStateLoaded = true; });
  }

  private spawnGoodColleague() {
    const tint = FRIEND_TINTS["blue"];
    const startX = Math.random() * (this.screenWidth - DISPLAY_SIZE * 2) + DISPLAY_SIZE / 2;
    const sheep = new Sheep(this.screenWidth, this.screenHeight, "good_colleague", tint, startX);
    sheep.setEasterTheme(this.easterTheme);
    this.attachSeasonalOverlay(sheep);
    sheep.name = "Good Colleague";
    sheep.drawOverlay = drawGoodColleagueOverlay;

    const bubble = new SpeechBubble(false, "#4a90d9");

    const entry: FriendEntry = {
      sheep,
      bubble,
      quips: GOOD_COLLEAGUE_QUIPS,
      nextQuipTime: Date.now() + 15000 + Math.random() * 30000,
      personality: "snarky",
    };
    this.friends.set("good_colleague", entry);
  }

  addFriend(config: FriendConfig) {
    if (this.friends.has(config.id)) return;
    if (this.friends.size >= 5) return;

    const tint = FRIEND_TINTS[config.color] ?? FRIEND_TINTS["pink"];
    const scale = config.scale ?? (0.85 + Math.random() * 0.3); // 0.85–1.15
    const startX = Math.random() * (this.screenWidth - DISPLAY_SIZE * 2) + DISPLAY_SIZE / 2;
    const sheep = new Sheep(this.screenWidth, this.screenHeight, config.id, tint, startX, scale);
    sheep.setEasterTheme(this.easterTheme);
    this.attachSeasonalOverlay(sheep);
    sheep.name = config.name;

    const personality: FriendPersonality = config.personality ?? "wholesome";
    sheep.personality = personality;

    // Apply accessories if provided
    if (config.accessories && config.accessories.length > 0) {
      sheep.drawOverlay = createCompositeOverlay(config.accessories);
    }

    const colorHex: Record<string, string> = {
      pink: "#e94560", blue: "#4a90d9", green: "#4ecca3",
      gold: "#d4a520", purple: "#9b59b6", orange: "#e67e22",
    };
    const bubble = new SpeechBubble(false, colorHex[config.color] ?? "#e94560");

    const quips = getPersonalityQuips(personality);

    this.friends.set(config.id, {
      sheep,
      bubble,
      quips,
      nextQuipTime: Date.now() + 30000 + Math.random() * 60000,
      personality,
    });
  }

  getFriendEntry(id: string): FriendEntry | undefined {
    return this.friends.get(id);
  }

  removeFriend(id: string) {
    if (id === "good_colleague") return; // can't remove the colleague
    const entry = this.friends.get(id);
    if (entry) {
      // Detach from any stack, or a sheep riding the removed friend keeps
      // tracking its ghost forever (and vice versa)
      entry.sheep.detachFromStack();
      entry.bubble.destroy();
      this.friends.delete(id);
    }
  }

  /** Hit test all characters, friends first (drawn on top). Returns null if none hit. */
  hitTest(px: number, py: number): Sheep | null {
    // Check friends in reverse order (last drawn = on top)
    const entries = Array.from(this.friends.values()).reverse();
    for (const entry of entries) {
      if (entry.sheep.hitTest(px, py)) return entry.sheep;
    }
    if (this.main.hitTest(px, py)) return this.main;
    return null;
  }

  /** Get the speech bubble for a specific sheep */
  getBubble(sheep: Sheep): SpeechBubble {
    if (sheep.id === "main") return this.mainBubble;
    return this.friends.get(sheep.id)?.bubble ?? this.mainBubble;
  }

  /** Get the quip pool for a specific sheep */
  getQuip(sheep: Sheep): string {
    if (sheep.id === "main") return sheep.getRandomQuip();
    const entry = this.friends.get(sheep.id);
    if (entry) {
      return entry.quips[Math.floor(Math.random() * entry.quips.length)];
    }
    return sheep.getRandomQuip();
  }

  /** All character ids: "main" + every friend (incl. good_colleague). */
  getCharacterIds(): string[] {
    return ["main", ...this.friends.keys()];
  }

  /** Public lookup for other systems (drama, spectacles, gossip). */
  getCharacter(id: string): { sheep: Sheep; bubble: SpeechBubble; personality?: string } | null {
    return this.getSheepById(id);
  }

  isCharacterCalm(id: string): boolean {
    const c = this.getSheepById(id);
    return c ? this.isCalm(c.sheep.state) : false;
  }

  /**
   * Play a prepared script through the normal conversation machinery.
   * Refuses (returns false) if the stage is already busy.
   */
  startScriptedConversation(script: ConversationScript, participants: string[]): boolean {
    if (this.activeConversation || this.groupActivity || script.length === 0) return false;
    for (const id of participants) {
      const c = this.getSheepById(id);
      if (!c || !this.isCalm(c.sheep.state) || c.bubble.visible) return false;
    }
    this.activeConversation = {
      lines: script,
      currentIndex: 0,
      timer: 0,
      participants: new Set(participants),
    };
    return true;
  }

  /** Begin a spectacle. Refuses while another scene is running. */
  startSpectacle(type: SpectacleType, pair?: [string, string]): boolean {
    if (this.spectacle) return false;
    this.cancelConversation();
    const calmIds = this.getCharacterIds().filter((id) => this.isCharacterCalm(id));
    if (type !== "balloon" && calmIds.length === 0) return false;
    this.spectacle = createSpectacleScene(type, this.screenWidth, this.screenHeight, calmIds, pair);
    this.spectacleSchedulerState = markFired(this.spectacleSchedulerState, type, Date.now());
    invoke("save_living_state", { name: "spectacles", value: this.spectacleSchedulerState }).catch(() => {});
    bus.emit("spectacle-started", { type });
    console.log(`[co-sheep] SPECTACLE: ${type}`);
    return true;
  }

  /** Trigger stampede — all sheep scatter in panic */
  triggerStampede(mouseX: number, _mouseY: number) {
    if (this.stampedeCooldown > 0 || this.stampedeActive) return;

    this.stampedeCooldown = 15000;
    this.cancelConversation();

    this.main.startStampede(mouseX);
    for (const entry of this.friends.values()) {
      entry.sheep.startStampede(mouseX);
    }

    // Only queue post-stampede dialogue if someone actually stampeded
    // (everyone could be parachuting/stacked and thus exempt)
    const anyStampeding = this.main.state === "stampede" ||
      Array.from(this.friends.values()).some(e => e.sheep.state === "stampede");
    if (anyStampeding) {
      this.stampedeActive = true;
      this.stampedeDialogueTimer = 2500; // dialogue 2.5s after stampede starts
      console.log("[co-sheep] STAMPEDE triggered!");
    }
  }

  /** Check if a dropped sheep should stack on another */
  tryStack(droppedSheep: Sheep): Sheep | null {
    const dropBottom = droppedSheep.y + droppedSheep.displaySize;
    const dropCenterX = droppedSheep.x + droppedSheep.displaySize / 2;

    const check = (target: Sheep): boolean => {
      if (target === droppedSheep) return false;
      if (target.stackedBy) return false; // already has something on top
      const badStates: SheepState[] = ["grabbed", "parachute", "fall", "stampede", "trampoline", "stacked"];
      if (badStates.includes(target.state)) return false;

      const targetCenterX = target.x + target.displaySize / 2;
      const xDist = Math.abs(dropCenterX - targetCenterX);
      const yDist = dropBottom - target.y;

      return xDist < target.displaySize * 0.7 && yDist > -target.displaySize * 0.3 && yDist < target.displaySize * 0.6;
    };

    for (const entry of Array.from(this.friends.values()).reverse()) {
      if (check(entry.sheep)) return entry.sheep;
    }
    if (check(this.main)) return this.main;

    return null;
  }

  /** Called when a sheep is stacked on another — triggers dialogue */
  onSheepStacked(top: Sheep, bottom: Sheep) {
    const topBubble = this.getBubble(top);
    const bottomBubble = this.getBubble(bottom);

    const topQuips = [
      "I can see everything from up here!",
      "The view is amazing!",
      "Don't move!",
      "I'm the king of the sheep!",
      "Higher! HIGHER!",
    ];
    const bottomQuips = [
      "HEY! Get off me!",
      "I'm NOT a chair!",
      "This is NOT okay.",
      "My back... my poor back...",
      "I didn't sign up for this.",
    ];

    bottomBubble.show(bottomQuips[Math.floor(Math.random() * bottomQuips.length)], 4000);
    setTimeout(() => {
      if (top.state === "stacked") {
        topBubble.show(topQuips[Math.floor(Math.random() * topQuips.length)], 4000);
      }
    }, 1500);

    bottom.playAnimation("headshake");
    invoke("record_interaction", { interaction: `stacked ${top.id} on ${bottom.id}` });
  }

  /** Called when a sheep starts trampolining — triggers reactions */
  onTrampolineStarted(sheep: Sheep) {
    const TRAMPOLINE_REACTIONS: Record<FriendPersonality, string[]> = {
      wholesome: ["WOAH! Are you okay?!", "Impressive!", "Do it again!"],
      chaotic: ["YESSS! HIGHER! HIGHER!", "10/10! DO A FLIP!", "I WANT A TURN!"],
      snarky: ["Show off.", "Physics isn't your strong suit.", "Gravity always wins."],
      "passive-aggressive": ["Must be nice to fly...", "Oh, so YOU get to have fun.", "I'm fine down here."],
    };

    let count = 0;
    for (const entry of this.friends.values()) {
      if (count >= 2) break;
      if (!this.isCalm(entry.sheep.state) || entry.bubble.visible) continue;
      if (entry.sheep === sheep) continue;

      const pool = TRAMPOLINE_REACTIONS[entry.personality] ?? TRAMPOLINE_REACTIONS.wholesome;
      entry.pendingReaction = {
        text: pool[Math.floor(Math.random() * pool.length)],
        animation: "bounce",
        delay: 800 + Math.random() * 1500,
      };
      count++;
    }

    invoke("record_interaction", { interaction: `trampoline by ${sheep.id}` });
  }

  /** Update window platforms and check validity */
  setWindowPlatforms(platforms: WindowPlatform[]) {
    this.main.platforms = platforms;
    for (const entry of this.friends.values()) {
      entry.sheep.platforms = platforms;
    }
  }

  /** Get all bounding boxes for cursor detection */
  getAllBounds(): Array<{ x: number; y: number; w: number; h: number }> {
    const pad = 12;
    const bounds: Array<{ x: number; y: number; w: number; h: number }> = [];
    bounds.push({
      x: this.main.x - pad,
      y: this.main.y - pad,
      w: this.main.displaySize + pad * 2,
      h: this.main.displaySize + pad * 2,
    });
    for (const entry of this.friends.values()) {
      bounds.push({
        x: entry.sheep.x - pad,
        y: entry.sheep.y - pad,
        w: entry.sheep.displaySize + pad * 2,
        h: entry.sheep.displaySize + pad * 2,
      });
    }
    return bounds;
  }

  updateScreenSize(w: number, h: number) {
    this.screenWidth = w;
    this.screenHeight = h;
    this.main.screenWidth = w;
    this.main.screenHeight = h;
    this.main.reground();
    for (const entry of this.friends.values()) {
      entry.sheep.screenWidth = w;
      entry.sheep.screenHeight = h;
      entry.sheep.reground();
    }
    this.nightAmbience.updateScreenSize(w, h);
    this.easterTheme.updateScreenSize(w, h);
    this.summerTheme.updateScreenSize(w, h);
  }

  setSummerMode(mode: "auto" | "on" | "off") {
    this.summerTheme.setModeOverride(mode);
  }

  setEasterMode(mode: "auto" | "on" | "off") {
    this.easterTheme.setModeOverride(mode);
    if (mode === "off" && this.groupActivity?.type === "easter_egg_hunt") {
      this.clearGroupActivity(true);
    }
  }

  applyEasterStats(stats: EasterStatsSnapshot | null) {
    this.easterTheme.applyStats(stats);
  }

  setWeatherCondition(c: string | null, tempC: number | null = null) {
    const prev = this.weatherEffects.condition;
    this.currentWeatherCondition = c;
    this.weatherEffects.setCondition(c);
    this.summerTheme.setWeather(c, tempC);
    if (c && c !== prev) {
      this.triggerFriendReactions("weather");
      bus.emit("weather-changed", { condition: c });
    }
  }

  update(dt: number) {
    this.main.update(dt);
    for (const entry of this.friends.values()) {
      entry.sheep.update(dt);
    }

    // Build sheep positions for night ambience
    const sheepPositions: Array<{ x: number; y: number; state: SheepState }> = [
      { x: this.main.x, y: this.main.y, state: this.main.state },
    ];
    for (const entry of this.friends.values()) {
      sheepPositions.push({ x: entry.sheep.x, y: entry.sheep.y, state: entry.sheep.state });
    }
    this.nightAmbience.update(dt, sheepPositions);
    this.weatherEffects.update(dt, this.screenWidth, this.screenHeight);
    this.easterTheme.update(dt, sheepPositions);
    this.summerTheme.update(dt, sheepPositions);

    // Update speech bubble positions
    this.mainBubble.updatePosition(this.main.x, this.main.y, this.main.displaySize);
    for (const entry of this.friends.values()) {
      entry.bubble.updatePosition(entry.sheep.x, entry.sheep.y, entry.sheep.displaySize);
    }

    // Process pending friend reactions
    this.updatePendingReactions(dt);

    // Social tick — probability rolls that assume a 500ms cadence run
    // only on these ticks, not every frame
    this.socialTimer += dt;
    const socialTick = this.socialTimer > 500;
    if (socialTick) this.socialTimer = 0;

    // Conversations
    this.updateConversations(dt, socialTick);

    // Reactive emote cooldown
    if (this.reactiveCooldown > 0) this.reactiveCooldown -= dt;
    if (this.aiChatCooldown > 0) this.aiChatCooldown -= dt;
    if (this.stampedeCooldown > 0) this.stampedeCooldown -= dt;

    // Stampede post-dialogue
    if (this.stampedeActive) {
      this.stampedeDialogueTimer -= dt;
      // Check if all sheep have stopped stampeding
      const anyStampeding = this.main.state === "stampede" ||
        Array.from(this.friends.values()).some(e => e.sheep.state === "stampede");
      if (!anyStampeding && this.stampedeDialogueTimer <= 0) {
        this.stampedeActive = false;
        this.triggerStampedeDialogue();
      }
    }

    // Friend notifications
    this.checkFriendNotifications(dt);

    // Group activities
    this.updateGroupActivityLoop(dt, socialTick);

    // Spectacles: run the active scene, else roll the scheduler every 5 min.
    if (this.spectacle) {
      const world = this.spectacleWorld();
      const alive = updateSpectacleScene(this.spectacle, dt, world);
      if (!alive) {
        const finished = this.spectacle;
        this.spectacle = null;
        bus.emit("spectacle-ended", { type: finished.type });
        if (finished.type === "showdown" && finished.pairIds && this.onShowdownResolved) {
          this.onShowdownResolved(finished.pairIds, finished.data.reconciled === 1);
        }
        const kindLabels: Record<SpectacleType, string> = {
          wolf: "wolf scare", ufo: "UFO encounter", merchant: "merchant visit",
          balloon: "balloon flyover", shearing: "shearing day",
          showdown: "high-noon showdown", feast: "reconciliation feast",
        };
        // "main" has no friend brain — never pass it to record_spectacle
        // or friend_memory would mint a brain file for it.
        const who = (finished.type === "showdown" && finished.pairIds
          ? [...finished.pairIds]
          : finished.type === "ufo" && finished.targetId
            ? [finished.targetId]
            : finished.participants
        ).filter((id) => id !== "main");
        if (who.length > 0) {
          invoke("record_spectacle", { kind: kindLabels[finished.type], participants: who }).catch(() => {});
        }
      }
    } else if (this.spectacleStateLoaded) {
      this.spectacleCheckTimer += dt;
      if (this.spectacleCheckTimer >= SPECTACLE.CHECK_INTERVAL_MS) {
        this.spectacleCheckTimer = 0;
        const hour = new Date().getHours();
        const type = pickRandomSpectacle({
          state: this.spectacleSchedulerState,
          nowMs: Date.now(),
          isNight: hour >= 20 || hour < 6,
          rand: Math.random(),
        });
        if (type) this.startSpectacle(type);
      }
    }

    // Social behaviors + periodic quips
    if (socialTick) {
      if (!this.groupActivity) {
        this.updateSocialBehaviors();
      }
      this.updatePeriodicQuips();
    }
  }

  /** Cancel any active conversation — called when AI commentary fires */
  cancelConversation() {
    if (this.activeConversation) {
      this.activeConversation = null;
    }
    this.clearGroupActivity(true);
  }

  draw(ctx: CanvasRenderingContext2D) {
    // Night ambience background (stars, moonlight) — behind everything
    this.nightAmbience.drawBackground(ctx, this.screenWidth, this.screenHeight);

    // Easter theme background (flowers) — behind sheep
    this.easterTheme.drawBackground(ctx, this.screenWidth, this.screenHeight);

    // Summer sun and glow — behind sheep
    this.summerTheme.drawBackground(ctx, this.screenWidth, this.screenHeight);

    // Easter eggs and grass detail — beneath the flock
    this.easterTheme.drawMidground(ctx, this.screenWidth, this.screenHeight);

    // Sunflowers — beneath the flock
    this.summerTheme.drawMidground(ctx, this.screenWidth, this.screenHeight);

    // Main sheep first (behind friends)
    this.main.draw(ctx);
    // Friends on top
    for (const entry of this.friends.values()) {
      entry.sheep.draw(ctx);
    }

    if (this.spectacle) {
      drawSpectacleScene(this.spectacle, ctx, this.spectacleWorld());
    }

    // Build positions for night foreground effects
    const positions: Array<{ x: number; y: number; state: SheepState }> = [
      { x: this.main.x, y: this.main.y, state: this.main.state },
    ];
    for (const entry of this.friends.values()) {
      positions.push({ x: entry.sheep.x, y: entry.sheep.y, state: entry.sheep.state });
    }

    // Easter theme foreground (petals, eggs) — on top of sheep
    this.easterTheme.drawForeground(ctx, this.screenWidth, this.screenHeight);

    // Summer butterflies and drifting seeds — on top of sheep
    this.summerTheme.drawForeground(ctx, this.screenWidth, this.screenHeight);

    // Weather particles (rain/snow) — on top of sheep
    this.weatherEffects.draw(ctx);

    // Night ambience foreground (fireflies, campfire glow) — on top
    this.nightAmbience.drawForeground(ctx, this.screenWidth, this.screenHeight, positions);
  }

  private updateGroupActivityLoop(dt: number, socialTick: boolean) {
    if (this.groupActivityCooldown > 0) {
      this.groupActivityCooldown -= dt;
    }

    if (this.groupActivity) {
      const getSheep = (id: string) => this.getSheepById(id);
      const alive = updateGroupActivity(this.groupActivity, dt, getSheep, this.easterTheme);
      if (!alive) {
        this.clearGroupActivity();
      }
      return;
    }

    // Try to start a group activity (only on 500ms social ticks, very rare)
    if (!socialTick) return;
    if (this.groupActivityCooldown > 0) return;
    if (this.activeConversation) return;
    if (this.spectacle) return;
    if (this.friends.size < 2) return; // need at least 3 total (main + 2 friends)
    if (Math.random() > 0.001) return; // 0.1% per tick

    const sheepList: Array<{ id: string; x: number; calm: boolean }> = [
      { id: "main", x: this.main.x, calm: this.isCalm(this.main.state) },
    ];
    for (const [id, entry] of this.friends) {
      sheepList.push({ id, x: entry.sheep.x, calm: this.isCalm(entry.sheep.state) });
    }

    let participants = canStartGroupActivity(sheepList);
    if (!participants) return;
    if (this.participantFilter) {
      participants = this.participantFilter(participants);
      if (participants.length < 3) return; // feud thinned the group below viability
    }

    // Calculate center of participants
    let sumX = 0;
    for (const id of participants) {
      const s = id === "main" ? this.main : this.friends.get(id)?.sheep;
      if (s) sumX += s.x;
    }
    const centerX = sumX / participants.length;

    const type = pickActivityType(this.easterTheme, this.summerTheme);
    this.groupActivity = createGroupActivity(type, participants, centerX);
    console.log(`[co-sheep] Group activity started: ${type} with ${participants.length} participants`);
  }

  /** Called by main.ts when break reminder fires on main sheep */
  echoBreakReminder() {
    if (this.notificationCooldown > 0) return;
    // Find a calm friend to echo after 5s
    for (const entry of this.friends.values()) {
      if (!this.isCalm(entry.sheep.state) || entry.bubble.visible) continue;
      const ECHO_MESSAGES: Record<FriendPersonality, string[]> = {
        wholesome: ["They're right! Take care of yourself!", "Please stretch! For me?"],
        chaotic: ["YEAH! STAND UP! DO A FLIP!", "BREAK TIME BREAK TIME!"],
        snarky: ["They have a point, for once.", "Even I agree. Take a break."],
        "passive-aggressive": ["I mean, if you WANT to ruin your health...", "Sure, keep sitting. See what happens."],
      };
      const pool = ECHO_MESSAGES[entry.personality] ?? ECHO_MESSAGES.wholesome;
      const text = pool[Math.floor(Math.random() * pool.length)];
      entry.pendingReaction = { text, delay: 5000 };
      this.notificationCooldown = 120000;
      break;
    }
  }

  private checkFriendNotifications(dt: number) {
    if (this.notificationCooldown > 0) this.notificationCooldown -= dt;
    this.launchTimer += dt;

    // Launch greeting — 8s after start, once someone has actually landed
    // (don't burn the one-shot flag while everyone is still parachuting)
    if (!this.hasGreetedOnLaunch && this.launchTimer > 8000 && this.friends.size > 0) {
      const GREETINGS: Record<FriendPersonality, string[]> = {
        wholesome: ["Good to be here! Ready for a great day!", "Hello everyone!"],
        chaotic: ["I'M ALIVE AGAIN! WHAT DID I MISS?!", "LET'S GOOOOO"],
        snarky: ["Oh. We're doing this again.", "Back to the grind."],
        "passive-aggressive": ["Oh, you remembered I exist. How nice.", "I guess I'm here now."],
      };
      for (const entry of this.friends.values()) {
        if (entry.sheep.state === "parachute") continue; // still landing
        if (entry.bubble.visible) continue;
        const pool = GREETINGS[entry.personality] ?? GREETINGS.wholesome;
        entry.pendingReaction = {
          text: pool[Math.floor(Math.random() * pool.length)],
          delay: 1000 + Math.random() * 3000,
        };
        this.hasGreetedOnLaunch = true;
        this.notificationCooldown = 120000;
        break; // only one friend greets
      }
    }

    // Nightfall notifications — when hour crosses 20 or 22
    const hour = new Date().getHours();
    if (hour !== this.lastNotificationHour && (hour === 20 || hour === 22 || hour === 0)) {
      this.lastNotificationHour = hour;
      if (this.notificationCooldown <= 0) {
        const NIGHT_MESSAGES: Record<FriendPersonality, string[]> = {
          wholesome: ["Getting dark! Cozy time!", "Stars are coming out!"],
          chaotic: ["THE SUN DIED! WE'RE NEXT!", "DARKNESS FALLS!"],
          snarky: ["Still working? Bold.", "Another late night, huh."],
          "passive-aggressive": ["I'm sure working late is FINE.", "Don't mind the time. I won't."],
        };
        for (const entry of this.friends.values()) {
          if (!this.isCalm(entry.sheep.state) || entry.bubble.visible) continue;
          const pool = NIGHT_MESSAGES[entry.personality] ?? NIGHT_MESSAGES.wholesome;
          entry.bubble.show(pool[Math.floor(Math.random() * pool.length)], 5000);
          this.notificationCooldown = 120000;
          break;
        }
      }
    }
    if (hour !== this.lastNotificationHour && this.lastNotificationHour !== -1) {
      this.lastNotificationHour = hour;
    }
  }

  private triggerFriendReactions(_cause: string) {
    if (this.reactiveCooldown > 0) return;

    const REACTION_MESSAGES: Record<FriendPersonality, string[]> = {
      wholesome: ["Oh!", "Yay!", "*looks over excitedly*", "How nice!"],
      chaotic: ["WHAT", "DID YOU SEE THAT", "!!!", "WHOA"],
      snarky: ["...", "*glances over*", "Hmm.", "Interesting."],
      "passive-aggressive": ["*pretends not to notice*", "That's... something.", "Cool, I guess."],
    };

    const REACTION_ANIMS: Record<FriendPersonality, SheepAnimation | undefined> = {
      wholesome: "bounce",
      chaotic: "spin",
      snarky: "headshake",
      "passive-aggressive": undefined,
    };

    // Pick 1-2 calm friends near main sheep
    let count = 0;
    for (const entry of this.friends.values()) {
      if (count >= 2) break;
      if (!this.isCalm(entry.sheep.state)) continue;
      if (entry.bubble.visible) continue;
      const dist = Math.abs(entry.sheep.x - this.main.x);
      if (dist > DISPLAY_SIZE * 3) continue;

      const pool = REACTION_MESSAGES[entry.personality] ?? REACTION_MESSAGES.wholesome;
      const text = pool[Math.floor(Math.random() * pool.length)];
      const anim = REACTION_ANIMS[entry.personality];
      entry.pendingReaction = {
        text,
        animation: anim,
        delay: 1000 + Math.random() * 2000, // 1-3s delay
      };
      count++;
    }
    // Only burn the cooldown if someone actually reacted
    if (count > 0) this.reactiveCooldown = 30000;
  }

  private updatePendingReactions(dt: number) {
    for (const entry of this.friends.values()) {
      if (!entry.pendingReaction) continue;
      entry.pendingReaction.delay -= dt;
      if (entry.pendingReaction.delay <= 0) {
        const r = entry.pendingReaction;
        entry.pendingReaction = undefined;
        if (!entry.bubble.visible && this.isCalm(entry.sheep.state)) {
          entry.bubble.show(r.text, 3000);
          if (r.animation) {
            entry.sheep.playAnimation(r.animation);
          }
        }
      }
    }
  }

  private spectacleWorld(): SpectacleWorld {
    return {
      getCharacter: (id) => this.getSheepById(id),
      characterIds: () => this.getCharacterIds(),
      screenW: this.screenWidth,
      screenH: this.screenHeight,
    };
  }

  private getSheepById(id: string): { sheep: Sheep; bubble: SpeechBubble; personality?: string } | null {
    if (id === "main") return { sheep: this.main, bubble: this.mainBubble };
    const entry = this.friends.get(id);
    if (entry) return { sheep: entry.sheep, bubble: entry.bubble, personality: entry.personality || (id === "good_colleague" ? "good_colleague" : undefined) };
    return null;
  }

  private isCalm(state: SheepState): boolean {
    return state === "idle" || state === "sit" || state === "walk";
  }

  private clearGroupActivity(cancelledEarly: boolean = false) {
    if (!this.groupActivity) return;

    if (this.groupActivity.type === "easter_egg_hunt") {
      const huntSummary = this.groupActivity.huntSummary;
      if (huntSummary && huntSummary.finders.some((finder) => finder.eggsFound > 0)) {
        this.recordEasterHunt(huntSummary);
      }
      this.easterTheme.resetEggs();
    }

    if (!cancelledEarly) {
      invoke("record_group_activity", {
        participants: this.groupActivity.participants,
        activityType: this.groupActivity.type,
      }).catch(() => {});
      bus.emit("group-activity", {
        type: this.groupActivity.type,
        participants: this.groupActivity.participants,
      });
    }

    // Release participants from activity-driven states so they don't keep walking toward stale targets
    if (cancelledEarly) {
      for (const id of this.groupActivity.participants) {
        const entry = this.getSheepById(id);
        if (entry) {
          entry.sheep.walkTarget = null;
          (entry.sheep as any).state = "idle";
          (entry.sheep as any).stateTimer = 0;
          (entry.sheep as any).stateDuration = 1000 + Math.random() * 2000;
        }
      }
    }

    this.groupActivity = null;
    this.groupActivityCooldown = 300000 + Math.random() * 300000;
  }

  private updateConversations(dt: number, socialTick: boolean) {
    if (this.activeConversation) {
      const conv = this.activeConversation;
      conv.timer -= dt;
      if (conv.timer <= 0) {
        if (conv.currentIndex >= conv.lines.length) {
          // Conversation finished — record in friend memory
          const pIds = Array.from(conv.participants);
          const topic = conv.lines[0]?.text.slice(0, 30) ?? "something";
          if (pIds.length === 2) {
            invoke("record_friend_conversation", { idA: pIds[0], idB: pIds[1], topic }).catch(() => {});
            bus.emit("conversation-happened", { idA: pIds[0], idB: pIds[1], topic });
          }
          this.activeConversation = null;
          this.conversationCooldown = 180000 + Math.random() * 120000;
          return;
        }
        const line = conv.lines[conv.currentIndex];
        const target = this.getSheepById(line.speakerId);
        if (target) {
          target.bubble.show(line.text, line.duration);
          if (line.animation) {
            target.sheep.playAnimation(line.animation);
          }
        }
        conv.currentIndex++;
        // Timer = this line's duration + next line's delay (or 0 if last)
        const nextDelay = conv.currentIndex < conv.lines.length
          ? conv.lines[conv.currentIndex].delay
          : 0;
        conv.timer = line.duration + nextDelay;
      }
      return;
    }

    // Cooldown
    if (this.conversationCooldown > 0) {
      this.conversationCooldown -= dt;
      return;
    }

    // Try to start a conversation on social ticks (every 500ms)
    // ~2% chance per pair per social tick
    if (!socialTick) return;
    const allSheep: Array<{ id: string; sheep: Sheep; bubble: SpeechBubble }> = [
      { id: "main", sheep: this.main, bubble: this.mainBubble },
    ];
    for (const [id, entry] of this.friends) {
      allSheep.push({ id, sheep: entry.sheep, bubble: entry.bubble });
    }

    for (let i = 0; i < allSheep.length; i++) {
      for (let j = i + 1; j < allSheep.length; j++) {
        const a = allSheep[i];
        const b = allSheep[j];
        if (!this.isCalm(a.sheep.state) || !this.isCalm(b.sheep.state)) continue;
        const dist = Math.abs(a.sheep.x - b.sheep.x);
        if (dist > DISPLAY_SIZE * 2) continue;
        if (a.bubble.visible || b.bubble.visible) continue;
        if (Math.random() > 0.02) continue;

        const aEntry = this.friends.get(a.id);
        const bEntry = this.friends.get(b.id);

        // 30% chance to use AI chat when both friends have personalities and cooldown allows
        if (aEntry?.personality && bEntry?.personality
            && !this.aiChatPending && this.aiChatCooldown <= 0
            && a.id !== "main" && b.id !== "main"
            && Math.random() < 0.3) {
          this.startAIConversation(a.id, aEntry, b.id, bEntry);
          return;
        }

        const ctx: ConversationContext = {
          personalityA: aEntry?.personality,
          personalityB: bEntry?.personality,
          weather: this.currentWeatherCondition,
          hour: new Date().getHours(),
          easterTheme: this.easterTheme,
          recentEasterHunt: this.easterTheme.hasRecentHuntBuzz(),
          summerActive: this.summerTheme.active,
          eggPaintingActive: a.sheep.state === "idle_egg_painting" || b.sheep.state === "idle_egg_painting",
        };
        const script = pickConversation(a.id, b.id, ctx);
        if (!script) continue;

        this.activeConversation = {
          lines: script,
          currentIndex: 0,
          timer: 0, // start immediately
          participants: new Set([a.id, b.id]),
        };
        return;
      }
    }
  }

  private startAIConversation(idA: string, entryA: FriendEntry, idB: string, entryB: FriendEntry) {
    this.aiChatPending = true;
    this.conversationCooldown = 60000; // prevent template convos while waiting

    invoke<string>("friend_ai_chat", {
      friendAName: entryA.sheep.name,
      friendAPersonality: entryA.personality,
      friendBName: entryB.sheep.name,
      friendBPersonality: entryB.personality,
    }).then((raw) => {
      this.aiChatPending = false;
      this.aiChatCooldown = 600000; // 10 min cooldown for AI chat

      try {
        const cleaned = raw
          .trim()
          .replace(/^```json\s*/i, "")
          .replace(/```\s*$/, "")
          .trim();
        const lines = JSON.parse(cleaned) as Array<{
          speaker: string;
          text: string;
          animation?: string | null;
        }>;

        if (!Array.isArray(lines) || lines.length === 0) return;

        const validAnims = ["bounce", "spin", "backflip", "headshake", "zoom", "vibrate"];
        const script: ConversationScript = lines.map((line, i) => {
          // Map speaker name to ID
          let speakerId = idA;
          if (line.speaker === entryB.sheep.name) speakerId = idB;
          const animation = line.animation && validAnims.includes(line.animation)
            ? line.animation as SheepAnimation
            : undefined;
          return {
            speakerId,
            text: line.text,
            duration: 3500,
            delay: i === 0 ? 0 : 800,
            animation,
          };
        });

        this.activeConversation = {
          lines: script,
          currentIndex: 0,
          timer: 0,
          participants: new Set([idA, idB]),
        };
        console.log("[co-sheep] AI friend conversation started");
      } catch (e) {
        console.error("[co-sheep] Failed to parse AI friend chat:", e);
      }
    }).catch((e) => {
      this.aiChatPending = false;
      // Back off on failure too, or a broken backend (offline, no API
      // key) gets re-invoked every time the conversation cooldown lapses
      this.aiChatCooldown = 600000;
      console.error("[co-sheep] AI friend chat failed:", e);
    });
  }

  private updateSocialBehaviors() {
    for (const entry of this.friends.values()) {
      const friend = entry.sheep;
      if (friend.state !== "idle" || friend.walkTarget !== null) continue;

      // Small chance to walk toward another character
      if (Math.random() < 0.005) {
        // Pick nearest other character
        let nearestX = this.main.x;
        let nearestDist = Math.abs(friend.x - this.main.x);

        for (const other of this.friends.values()) {
          if (other.sheep.id === friend.id) continue;
          const dist = Math.abs(friend.x - other.sheep.x);
          if (dist < nearestDist) {
            nearestDist = dist;
            nearestX = other.sheep.x;
          }
        }

        // Only walk toward if far enough away
        if (nearestDist > DISPLAY_SIZE * 3) {
          friend.walkTarget = nearestX;
        }
      }
    }
  }

  private updatePeriodicQuips() {
    const now = Date.now();
    for (const entry of this.friends.values()) {
      if (now < entry.nextQuipTime) continue;

      const s = entry.sheep.state;
      // Only blurt quips during calm states
      if (s === "idle" || s === "walk" || s === "sit") {
        let pool = entry.quips;
        if (this.easterTheme.active && this.easterTheme.hasRecentHuntBuzz()) {
          pool = EASTER_POST_HUNT_QUIPS;
        } else if (this.easterTheme.active && Math.random() < 0.35) {
          pool = EASTER_IDLE_QUIPS;
        } else if (this.summerTheme.active && Math.random() < 0.35) {
          pool = SUMMER_IDLE_QUIPS;
        }
        const quip = pool[Math.floor(Math.random() * pool.length)];
        entry.bubble.show(quip, 5000);
        // Personality-biased animation to accompany the quip
        const anims = getPersonalityAnimBias(entry.personality);
        if (Math.random() < 0.3) {
          entry.sheep.playAnimation(anims[Math.floor(Math.random() * anims.length)]);
        }
      }

      // Schedule next quip 45-90s from now
      entry.nextQuipTime = now + 45000 + Math.random() * 45000;
    }
  }

  private attachSeasonalOverlay(sheep: Sheep) {
    sheep.seasonalOverlay = (ctx, x, y, size, facingRight, state) => {
      if (!this.easterTheme.shouldShowBasket(sheep.id)) return;
      const eggCount = Math.max(1, this.easterTheme.getBasketEggCount(sheep.id));
      drawEasterBasket(ctx, x, y, size, facingRight, state, {
        eggCount,
        allowMoving: true,
      });
    };
  }

  private recordEasterHunt(summary: EasterHuntSummary) {
    const hunters = summary.finders.map((finder) => {
      const sheep = this.getSheepById(finder.id)?.sheep;
      return {
        id: finder.id,
        name: sheep?.name || finder.id,
        eggsFound: finder.eggsFound,
        goldenEggsFound: finder.goldenEggsFound,
      };
    });

    invoke<EasterStatsSnapshot>("record_easter_hunt", {
      result: {
        totalEggs: summary.totalEggs,
        durationMs: summary.durationMs,
        allCollected: summary.allCollected,
        paintedEggsUsed: summary.paintedEggsUsed,
        hunters,
      },
    }).then((stats) => {
      this.easterTheme.applyStats(stats);
    }).catch((error) => {
      console.error("[co-sheep] Failed to record Easter hunt:", error);
    });
  }

  private triggerStampedeDialogue() {
    // Find two calm sheep for a post-stampede conversation
    const calmSheep: Array<{ id: string; sheep: Sheep; bubble: SpeechBubble }> = [];
    if (this.isCalm(this.main.state) && !this.mainBubble.visible) {
      calmSheep.push({ id: "main", sheep: this.main, bubble: this.mainBubble });
    }
    for (const [id, entry] of this.friends) {
      if (this.isCalm(entry.sheep.state) && !entry.bubble.visible) {
        calmSheep.push({ id, sheep: entry.sheep, bubble: entry.bubble });
      }
    }

    if (calmSheep.length < 1) return;

    const STAMPEDE_QUIPS_A = [
      "What was THAT?!",
      "I thought I was going to die!",
      "MY HEART IS STILL RACING!",
      "EARTHQUAKE?! PREDATOR?! WHAT?!",
      "I saw my life flash before my eyes!",
    ];
    const STAMPEDE_QUIPS_B = [
      "...I think it was the cursor.",
      "We really need to stop panicking.",
      "That was the cursor. Again.",
      "I'm going to need therapy.",
      "Same time tomorrow, probably.",
    ];

    const first = calmSheep[0];
    first.bubble.show(STAMPEDE_QUIPS_A[Math.floor(Math.random() * STAMPEDE_QUIPS_A.length)], 4000);
    first.sheep.playAnimation("vibrate");

    if (calmSheep.length >= 2) {
      const second = calmSheep[1];
      second.sheep.resetActivity();
      setTimeout(() => {
        if (this.isCalm(second.sheep.state)) {
          second.bubble.show(STAMPEDE_QUIPS_B[Math.floor(Math.random() * STAMPEDE_QUIPS_B.length)], 4000);
          second.sheep.playAnimation("headshake");
        }
      }, 2000);
    }

    this.conversationCooldown = 30000;
  }
}

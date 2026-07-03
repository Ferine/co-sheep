import { invoke } from "@tauri-apps/api/core";
import { Flock } from "./flock";
import { bus } from "./events";
import {
  DramaTransition,
  PairInput,
  RelationshipState,
  blocksGroupActivity,
  evaluateDrama,
  pairKey,
  pruneCharacterFromPairs,
} from "./drama";
import { DramaScriptKind, pickDramaScript } from "./drama-scripts";
import { ConversationScript, SheepAnimation } from "./types";

const TICK_MS = 60_000;
const DISPLAY_SIZE = 96;
const SNIPE_CHANCE = 0.10;        // per tick, per feuding pair
const MEDIATION_CHANCE = 0.05;    // per tick, per feuding pair
const MEDIATION_SUCCESS = 0.6;
const SHOWDOWN_MS = 24 * 3600 * 1000;
const SHOWDOWN_CHANCE = 0.10;
const AI_NARRATION_CHANCE = 0.3;
const AI_NARRATION_COOLDOWN_MS = 10 * 60 * 1000;
const LOG_CAP = 50;

interface PairRecord {
  state: RelationshipState;
  since: number; // epoch ms of last transition
}

interface DramaFile {
  pairs: Record<string, PairRecord>;
  pettingToday: Record<string, number>;
  pettingDate: string;
  log: Array<{ at: string; text: string }>;
}

type RelationshipsSnapshot = Record<
  string,
  { name: string; relationships: Record<string, number> }
>;

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

export class DramaManager {
  private state: DramaFile = { pairs: {}, pettingToday: {}, pettingDate: today(), log: [] };
  private aiNarrationCooldownUntil = 0;
  onDramaTriggeredSpectacle:
    | ((kind: "showdown" | "feast", pair: [string, string]) => void)
    | null = null;

  constructor(private flock: Flock) {}

  async start(): Promise<void> {
    try {
      const saved = await invoke<DramaFile | null>("get_living_state", { name: "drama" });
      if (saved && saved.pairs) this.state = saved;
    } catch (e) {
      console.log("[co-sheep] No saved drama state:", e);
    }
    this.resetPettingIfNewDay();

    bus.on("sheep-petted", ({ id }) => {
      this.resetPettingIfNewDay();
      this.state.pettingToday[id] = (this.state.pettingToday[id] ?? 0) + 1;
    });

    // Feuders refuse shared group activities.
    this.flock.participantFilter = (ids) => this.filterFeuders(ids);

    setInterval(() => {
      this.tick().catch((e) => console.error("[co-sheep] drama tick failed:", e));
    }, TICK_MS);
  }

  /** A friend was removed — its id never returns, so drop its drama state.
   * Called from the remove-friend event, NOT the tick: friends spawn
   * staggered at startup, so pruning against live ids would eat real feuds. */
  onFriendRemoved(id: string): void {
    this.state.pairs = pruneCharacterFromPairs(this.state.pairs, id);
    delete this.state.pettingToday[id];
    this.persist();
  }

  getPairStates(): Record<string, { state: RelationshipState; sinceMs: number }> {
    const out: Record<string, { state: RelationshipState; sinceMs: number }> = {};
    const now = Date.now();
    for (const [key, rec] of Object.entries(this.state.pairs)) {
      out[key] = { state: rec.state, sinceMs: now - rec.since };
    }
    return out;
  }

  /** Debug hook: force the first non-feud friend pair into a feud. */
  forceFeud(): string | null {
    const ids = this.flock.getCharacterIds().filter((id) => id !== "main");
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) {
        const key = pairKey(ids[i], ids[j]);
        const rec = this.state.pairs[key];
        if (!rec || rec.state !== "feud") {
          this.applyTransition({
            idA: ids[i] < ids[j] ? ids[i] : ids[j],
            idB: ids[i] < ids[j] ? ids[j] : ids[i],
            from: rec?.state ?? "neutral",
            to: "feud",
            cause: "debug",
          });
          return key;
        }
      }
    }
    return null;
  }

  /** Called by the showdown scene (Task 9) with its outcome. */
  resolveShowdown(pair: [string, string], reconciled: boolean): void {
    const key = pairKey(pair[0], pair[1]);
    const rec = this.state.pairs[key];
    if (!rec || rec.state !== "feud") return;
    if (reconciled) {
      this.applyTransition({
        idA: pair[0], idB: pair[1],
        from: "feud", to: "reconciling", cause: "showdown",
      });
    } else {
      this.state.log.push({
        at: new Date().toISOString(),
        text: `${pair[0]} & ${pair[1]}: showdown ended in a stalemate`,
      });
      this.persist();
    }
  }

  private resetPettingIfNewDay(): void {
    if (this.state.pettingDate !== today()) {
      this.state.pettingToday = {};
      this.state.pettingDate = today();
    }
  }

  private filterFeuders(ids: string[]): string[] {
    const result = [...ids];
    for (let i = 0; i < result.length; i++) {
      for (let j = result.length - 1; j > i; j--) {
        const rec = this.state.pairs[pairKey(result[i], result[j])];
        if (rec && blocksGroupActivity(rec.state)) result.splice(j, 1);
      }
    }
    return result;
  }

  private async tick(): Promise<void> {
    const ids = this.flock.getCharacterIds();
    if (ids.length < 2) return;
    this.resetPettingIfNewDay();

    let rels: RelationshipsSnapshot;
    let moods: Record<string, string>;
    try {
      rels = await invoke<RelationshipsSnapshot>("get_all_relationships");
      moods = await invoke<Record<string, string>>("get_friend_moods");
    } catch (e) {
      console.error("[co-sheep] drama: failed to fetch relationship data:", e);
      return;
    }

    const now = Date.now();
    const inputs: PairInput[] = [];
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) {
        const [a, b] = ids[i] < ids[j] ? [ids[i], ids[j]] : [ids[j], ids[i]];
        const key = pairKey(a, b);
        let rec = this.state.pairs[key];
        if (!rec) {
          rec = { state: "neutral", since: now };
          this.state.pairs[key] = rec;
        }
        // Symmetric affinity: average whichever directions exist
        // ("main" has no brain, so main-pairs use the friend's view only).
        const ab = rels[a]?.relationships?.[b];
        const ba = rels[b]?.relationships?.[a];
        const vals = [ab, ba].filter((v): v is number => typeof v === "number");
        const affinity = vals.length ? vals.reduce((s, v) => s + v, 0) / vals.length : 0;
        const gap = Math.abs(
          (this.state.pettingToday[a] ?? 0) - (this.state.pettingToday[b] ?? 0),
        );
        inputs.push({
          idA: a, idB: b,
          affinity,
          moodA: moods[a] ?? "happy",
          moodB: moods[b] ?? "happy",
          state: rec.state,
          msInState: now - rec.since,
          pettingGap: gap,
          spark: Math.random(),
        });
      }
    }

    for (const t of evaluateDrama(inputs)) {
      this.applyTransition(t);
    }
    this.runOngoingBehaviors(now, rels);
    this.persist();
  }

  private applyTransition(t: DramaTransition): void {
    const key = pairKey(t.idA, t.idB);
    this.state.pairs[key] = { state: t.to, since: Date.now() };
    this.state.log.push({
      at: new Date().toISOString(),
      text: `${t.idA} & ${t.idB}: ${t.from} -> ${t.to} (${t.cause})`,
    });
    if (this.state.log.length > LOG_CAP) {
      this.state.log.splice(0, this.state.log.length - LOG_CAP);
    }
    bus.emit("drama-state-changed", {
      idA: t.idA, idB: t.idB, from: t.from, to: t.to, cause: t.cause,
    });
    console.log(`[co-sheep] DRAMA: ${t.idA} & ${t.idB} ${t.from} -> ${t.to} (${t.cause})`);

    // Visible beat for the transition.
    if (t.to === "feud") {
      this.playScript(t.cause === "jealousy" ? "jealousy" : "feud_start", t.idA, t.idB);
    } else if (t.to === "warm" && t.from === "reconciling") {
      this.playScript("reconciliation", t.idA, t.idB);
    } else if (t.to === "inseparable") {
      this.playScript("inseparable", t.idA, t.idB);
    } else if (t.to === "reconciling" && this.onDramaTriggeredSpectacle) {
      this.onDramaTriggeredSpectacle("feast", [t.idA, t.idB]);
    }

    this.maybeNarrate(t);
    this.persist();
  }

  /** 30% chance of an on-device AI beat about the transition (fire-and-forget). */
  private maybeNarrate(t: DramaTransition): void {
    if (Math.random() >= AI_NARRATION_CHANCE) return;
    if (Date.now() < this.aiNarrationCooldownUntil) return;
    if (t.idA === "main" || t.idB === "main") return; // needs two friend personalities
    const a = this.flock.getCharacter(t.idA);
    const b = this.flock.getCharacter(t.idB);
    if (!a?.personality || !b?.personality) return;
    this.aiNarrationCooldownUntil = Date.now() + AI_NARRATION_COOLDOWN_MS;

    invoke<string>("friend_ai_chat", {
      friendAName: a.sheep.name,
      friendAPersonality: a.personality,
      friendBName: b.sheep.name,
      friendBPersonality: b.personality,
      topic: `their relationship just changed from ${t.from} to ${t.to} because of ${t.cause}`,
    }).then((raw) => {
      try {
        const cleaned = raw.trim().replace(/^```json\s*/i, "").replace(/```\s*$/, "").trim();
        const lines = JSON.parse(cleaned) as Array<{
          speaker: string;
          text: string;
          animation?: string | null;
        }>;
        if (!Array.isArray(lines) || lines.length === 0) return;
        const validAnims = ["bounce", "spin", "backflip", "headshake", "zoom", "vibrate"];
        const script: ConversationScript = lines.map((line, i) => ({
          speakerId: line.speaker === b.sheep.name ? t.idB : t.idA,
          text: line.text,
          duration: 3500,
          delay: i === 0 ? 0 : 800,
          animation:
            line.animation && validAnims.includes(line.animation)
              ? (line.animation as SheepAnimation)
              : undefined,
        }));
        this.flock.startScriptedConversation(script, [t.idA, t.idB]);
      } catch (e) {
        console.error("[co-sheep] drama narration parse failed:", e);
      }
    }).catch((e) => console.error("[co-sheep] drama narration failed:", e));
  }

  /** Per-tick continuous behaviors for pairs in dramatic states. */
  private runOngoingBehaviors(now: number, rels: RelationshipsSnapshot): void {
    for (const [key, rec] of Object.entries(this.state.pairs)) {
      const [idA, idB] = key.split("|");
      const a = this.flock.getCharacter(idA);
      const b = this.flock.getCharacter(idB);
      if (!a || !b) continue;

      if (rec.state === "feud") {
        const dist = Math.abs(a.sheep.x - b.sheep.x);
        if (
          dist < DISPLAY_SIZE * 2 &&
          this.flock.isCharacterCalm(idA) &&
          this.flock.isCharacterCalm(idB)
        ) {
          // Storm apart when too close.
          const dir = a.sheep.x < b.sheep.x ? -1 : 1;
          a.sheep.walkTarget = Math.max(
            0,
            Math.min(a.sheep.screenWidth - DISPLAY_SIZE, a.sheep.x + dir * DISPLAY_SIZE * 3),
          );
          a.sheep.playAnimation("headshake");
        } else if (Math.random() < SNIPE_CHANCE) {
          this.playScript("feud_snipe", idA, idB);
        }

        // Mediation: the best-connected calm third sheep intervenes.
        if (Math.random() < MEDIATION_CHANCE) {
          const mediator = this.pickMediator(idA, idB, rels);
          if (mediator && this.playScript("mediation", idA, idB, mediator)) {
            if (Math.random() < MEDIATION_SUCCESS) {
              this.applyTransition({
                idA, idB, from: "feud", to: "reconciling", cause: "mediation",
              });
              // applyTransition invalidates rec for this iteration; move to next pair
              continue;
            }
          }
        }

        // Long feuds may erupt into a high-noon showdown (Task 9 sets the callback).
        if (
          now - rec.since >= SHOWDOWN_MS &&
          Math.random() < SHOWDOWN_CHANCE &&
          this.onDramaTriggeredSpectacle
        ) {
          this.onDramaTriggeredSpectacle("showdown", [idA, idB]);
        }
      }

      if (rec.state === "inseparable") {
        // Trail each other when separated.
        const dist = Math.abs(a.sheep.x - b.sheep.x);
        if (dist > DISPLAY_SIZE * 4 && this.flock.isCharacterCalm(idB) && b.sheep.walkTarget === null) {
          b.sheep.walkTarget = a.sheep.x;
        }
      }
    }
  }

  /** Calm third sheep with the highest combined affinity to both feuders. */
  private pickMediator(idA: string, idB: string, rels: RelationshipsSnapshot): string | null {
    let best: string | null = null;
    let bestScore = -Infinity;
    for (const id of this.flock.getCharacterIds()) {
      if (id === idA || id === idB || id === "main") continue;
      if (!this.flock.isCharacterCalm(id)) continue;
      const score =
        (rels[id]?.relationships?.[idA] ?? 0) + (rels[id]?.relationships?.[idB] ?? 0);
      if (score > bestScore) {
        bestScore = score;
        best = id;
      }
    }
    return best;
  }

  private playScript(kind: DramaScriptKind, idA: string, idB: string, mediatorId?: string): boolean {
    const script = pickDramaScript(kind, idA, idB, mediatorId);
    const participants = mediatorId ? [idA, idB, mediatorId] : [idA, idB];
    return this.flock.startScriptedConversation(script, participants);
  }

  private persist(): void {
    invoke("save_living_state", { name: "drama", value: this.state }).catch(() => {});
  }
}

import { invoke } from "@tauri-apps/api/core";
import { Sheep } from "./sheep";
import { SpeechBubble } from "./speech-bubble";
import { SpectacleType } from "./spectacles";

export interface SpectacleWorld {
  getCharacter(id: string): { sheep: Sheep; bubble: SpeechBubble; personality?: string } | null;
  characterIds(): string[];
  screenW: number;
  screenH: number;
}

export interface SpectacleScene {
  type: SpectacleType;
  phase: "enter" | "perform" | "exit";
  timer: number;
  actorX: number;
  actorY: number;
  facingRight: boolean;
  targetId?: string;
  pairIds?: [string, string];
  participants: string[];
  /** Per-scene scratch values (flags, one-shot markers, outcome). */
  data: Record<string, number>;
}

const SIZE = 96;
const GROUND_OFFSET = SIZE + 10;

export function createSpectacleScene(
  type: SpectacleType,
  screenW: number,
  screenH: number,
  calmIds: string[],
  pair?: [string, string],
): SpectacleScene {
  const scene: SpectacleScene = {
    type,
    phase: type === "shearing" ? "perform" : "enter",
    timer: 0,
    actorX: type === "merchant" ? screenW + SIZE : -SIZE,
    actorY:
      type === "ufo" ? -SIZE :
      type === "balloon" ? screenH * 0.15 :
      screenH - GROUND_OFFSET,
    facingRight: type !== "merchant",
    participants: [...calmIds],
    pairIds: pair,
    data: {},
  };
  if (type === "ufo") {
    scene.targetId = calmIds[Math.floor(Math.random() * calmIds.length)] ?? "main";
  }
  return scene;
}

/** Returns true while running; false once the scene is finished. */
export function updateSpectacleScene(
  scene: SpectacleScene,
  dt: number,
  world: SpectacleWorld,
): boolean {
  scene.timer += dt;
  switch (scene.type) {
    case "wolf": return updateWolf(scene, dt, world);
    case "ufo": return updateUfo(scene, dt, world);
    case "merchant": return updateMerchant(scene, dt, world);
    case "balloon": return updateBalloon(scene, dt, world);
    case "shearing": return updateShearing(scene, dt, world);
    case "showdown": return updateShowdown(scene, dt, world);
    case "feast": return updateFeast(scene, dt, world);
  }
}

function setState(sheep: Sheep, state: string, durationMs: number): void {
  (sheep as any).state = state;
  (sheep as any).stateTimer = 0;
  (sheep as any).stateDuration = durationMs;
}

function updateWolf(scene: SpectacleScene, dt: number, world: SpectacleWorld): boolean {
  const speed = 0.35; // px per ms
  if (scene.phase === "enter") {
    scene.actorX += speed * dt;
    if (scene.actorX >= world.screenW * 0.3 || scene.timer > 2000) {
      scene.phase = "perform";
      scene.timer = 0;
      // Flock flees.
      for (const id of world.characterIds()) {
        const c = world.getCharacter(id);
        if (!c) continue;
        const away = c.sheep.x < scene.actorX ? 0 : world.screenW - SIZE;
        c.sheep.walkTarget = away;
        c.sheep.playAnimation("zoom");
      }
    }
  } else if (scene.phase === "perform") {
    if (scene.timer > 3000 && !scene.data.gcQuip) {
      scene.data.gcQuip = 1;
      const gc = world.getCharacter("good_colleague");
      if (gc && !gc.bubble.visible) gc.bubble.show("Jeg var IKKE redd.", 4000);
    }
    if (scene.timer > 6000) {
      scene.phase = "exit";
      scene.timer = 0;
      scene.facingRight = false;
    }
  } else {
    scene.actorX -= speed * 1.4 * dt;
    if (scene.actorX < -SIZE) {
      // Survivors catch their breath once the wolf is gone.
      const RELIEF = ["That was TOO close.", "Wolves. WHY wolves.", "Never speak of this."];
      let shown = 0;
      for (const id of scene.participants) {
        if (shown >= 2) break;
        const c = world.getCharacter(id);
        if (!c || c.bubble.visible) continue;
        c.bubble.show(RELIEF[Math.floor(Math.random() * RELIEF.length)], 3500);
        shown++;
      }
      return false;
    }
  }
  return true;
}

function updateUfo(scene: SpectacleScene, dt: number, world: SpectacleWorld): boolean {
  const target = world.getCharacter(scene.targetId ?? "main");
  if (!target) return false;
  const hoverY = world.screenH * 0.25;
  if (scene.phase === "enter") {
    scene.actorX = target.sheep.x + SIZE / 2 - 40;
    scene.actorY = Math.min(hoverY, scene.actorY + 0.3 * dt);
    if (scene.actorY >= hoverY || scene.timer > 2500) {
      scene.phase = "perform";
      scene.timer = 0;
      setState(target.sheep, "grabbed", 8000);
    }
  } else if (scene.phase === "perform") {
    // Beam the target upward.
    const liftTo = scene.actorY + 90;
    if (target.sheep.y > liftTo) target.sheep.y -= 0.15 * dt;
    if (scene.timer > 8000) {
      scene.phase = "exit";
      scene.timer = 0;
      setState(target.sheep, "fall", 4000);
    }
  } else {
    scene.actorY -= 0.4 * dt;
    if (scene.actorY < -120 || scene.timer > 2000) {
      if (!target.bubble.visible) target.bubble.show("I have SEEN things.", 5000);
      target.sheep.playAnimation("spin");
      return false;
    }
  }
  return true;
}

const GIFT_POOL = [
  "party_hat", "crown", "sunglasses", "bow_tie", "flower", "scarf", "top_hat",
  "monocle", "wizard_hat", "bandana", "mustache", "cape", "chef_hat", "necklace",
];

function updateMerchant(scene: SpectacleScene, dt: number, world: SpectacleWorld): boolean {
  const speed = 0.2;
  if (scene.phase === "enter") {
    scene.actorX -= speed * dt;
    if (scene.actorX <= world.screenW * 0.6 || scene.timer > 4000) {
      scene.phase = "perform";
      scene.timer = 0;
      const main = world.getCharacter("main");
      if (main) {
        main.sheep.walkTarget = scene.actorX - SIZE;
        if (!main.bubble.visible) main.bubble.show("A traveling merchant!", 3500);
      }
    }
  } else if (scene.phase === "perform") {
    if (scene.timer > 6000) {
      scene.phase = "exit";
      scene.timer = 0;
      scene.facingRight = true;
      giftAccessory(world);
    }
  } else {
    scene.actorX += speed * 1.5 * dt;
    if (scene.actorX > world.screenW + SIZE) return false;
  }
  return true;
}

/** Fire-and-forget: gift the main sheep one accessory it doesn't own yet. */
function giftAccessory(world: SpectacleWorld): void {
  invoke<string[]>("get_accessories")
    .then((owned) => {
      const options = GIFT_POOL.filter((id) => !owned.includes(id));
      if (options.length === 0) return;
      const gift = options[Math.floor(Math.random() * options.length)];
      return invoke("save_accessories", { accessories: [...owned, gift] }).then(() => {
        const main = world.getCharacter("main");
        if (main) {
          if (!main.bubble.visible) main.bubble.show("Ooh, a gift!", 4000);
          main.sheep.playAnimation("bounce");
        }
      });
    })
    .catch((e) => console.error("[co-sheep] merchant gift failed:", e));
}

function updateBalloon(scene: SpectacleScene, dt: number, world: SpectacleWorld): boolean {
  if (scene.phase === "enter") {
    scene.phase = "perform";
    scene.timer = 0;
    scene.actorX = -60;
    for (const id of scene.participants) {
      const c = world.getCharacter(id);
      if (c) setState(c.sheep, "sit", 20000);
    }
  } else {
    scene.actorX += ((world.screenW + 120) / 20000) * dt;
    if (scene.timer > 5000 && !scene.data.ooh) {
      scene.data.ooh = 1;
      const c = scene.participants[0] ? world.getCharacter(scene.participants[0]) : null;
      if (c && !c.bubble.visible) c.bubble.show("Ooooh.", 3000);
    }
    for (const id of scene.participants) {
      const c = world.getCharacter(id);
      if (c) c.sheep.facingRight = scene.actorX > c.sheep.x; // track the balloon
    }
    if (scene.actorX > world.screenW + 60) return false;
  }
  return true;
}

const SHEARING_BUBBLES = ["MY WOOL!", "Don't look at me.", "This is a violation.", "Cold. So cold."];
const SHEARING_TOTAL_MS = 60_000;

function updateShearing(scene: SpectacleScene, _dt: number, world: SpectacleWorld): boolean {
  // Scene is created directly in "perform"; the shorn overlay is drawn
  // by drawShornOverlays and fades back in over the final 10 s.
  if (!scene.data.started) {
    scene.data.started = 1;
    for (const id of scene.participants) {
      world.getCharacter(id)?.sheep.playAnimation("vibrate");
    }
  }
  for (let i = 0; i < SHEARING_BUBBLES.length; i++) {
    const flag = `bubble${i}`;
    if (scene.timer > i * 2000 && !scene.data[flag]) {
      scene.data[flag] = 1;
      const id = scene.participants[i % Math.max(1, scene.participants.length)];
      const c = id ? world.getCharacter(id) : null;
      if (c && !c.bubble.visible) c.bubble.show(SHEARING_BUBBLES[i], 3000);
    }
  }
  return scene.timer < SHEARING_TOTAL_MS;
}

function updateShowdown(scene: SpectacleScene, _dt: number, world: SpectacleWorld): boolean {
  if (!scene.pairIds) return false;
  const a = world.getCharacter(scene.pairIds[0]);
  const b = world.getCharacter(scene.pairIds[1]);
  if (!a || !b) return false;
  const center = world.screenW / 2;
  const aSpot = center - 60 - SIZE / 2;
  const bSpot = center + 60 - SIZE / 2;

  if (scene.phase === "enter") {
    if (!scene.data.summoned) {
      scene.data.summoned = 1;
      a.sheep.walkTarget = aSpot;
      b.sheep.walkTarget = bSpot;
      for (const id of scene.participants) {
        if (id === scene.pairIds[0] || id === scene.pairIds[1]) continue;
        const c = world.getCharacter(id);
        if (c) setState(c.sheep, "sit", 15000); // spectators settle in
      }
    }
    const gathered =
      Math.abs(a.sheep.x - aSpot) < SIZE && Math.abs(b.sheep.x - bSpot) < SIZE;
    if (gathered || scene.timer > 5000) {
      scene.phase = "perform";
      scene.timer = 0;
    }
  } else if (scene.phase === "perform") {
    a.sheep.facingRight = b.sheep.x > a.sheep.x;
    b.sheep.facingRight = a.sheep.x > b.sheep.x;
    if (!scene.data.vibe0) {
      scene.data.vibe0 = 1;
      a.sheep.playAnimation("vibrate");
      b.sheep.playAnimation("vibrate");
    }
    if (scene.timer > 4000 && !scene.data.vibe4) {
      scene.data.vibe4 = 1;
      a.sheep.playAnimation("vibrate");
      b.sheep.playAnimation("vibrate");
    }
    if (scene.timer > 8000) {
      scene.phase = "exit";
      scene.timer = 0;
      scene.data.reconciled = Math.random() < 0.5 ? 1 : 0;
      const rec = scene.data.reconciled === 1;
      if (!a.bubble.visible) a.bubble.show(rec ? "...truce?" : "This isn't over.", 4000);
      if (!b.bubble.visible) b.bubble.show(rec ? "...fine. Truce." : "Not even CLOSE to over.", 4000);
    }
  } else if (scene.timer > 2000) {
    return false;
  }
  return true;
}

function updateFeast(scene: SpectacleScene, _dt: number, world: SpectacleWorld): boolean {
  const center = world.screenW / 2;
  if (scene.phase === "enter") {
    if (!scene.data.gathered) {
      scene.data.gathered = 1;
      let slot = 0;
      for (const id of scene.participants) {
        const c = world.getCharacter(id);
        if (!c) continue;
        c.sheep.walkTarget = center + (slot - scene.participants.length / 2) * SIZE * 0.9;
        slot++;
      }
    }
    if (scene.timer > 6000) {
      scene.phase = "perform";
      scene.timer = 0;
      const host = scene.pairIds?.[0] ?? scene.participants[0];
      const hostChar = host ? world.getCharacter(host) : null;
      if (hostChar) {
        setState(hostChar.sheep, "idle_campfire", 15000);
        (hostChar.sheep as any).campfireSparks = [];
      }
      for (const id of scene.participants) {
        if (id === host) continue;
        const c = world.getCharacter(id);
        if (c) setState(c.sheep, "sit", 15000);
      }
    }
  } else if (scene.phase === "perform") {
    if (scene.timer > 2000 && !scene.data.toasted && scene.pairIds) {
      scene.data.toasted = 1;
      const a = world.getCharacter(scene.pairIds[0]);
      const b = world.getCharacter(scene.pairIds[1]);
      if (a && !a.bubble.visible) a.bubble.show("To making up!", 3500);
      if (b) {
        setTimeout(() => {
          if (!b.bubble.visible) b.bubble.show("To wool and friendship!", 3500);
        }, 1200);
      }
    }
    if (scene.timer > 15000) {
      scene.phase = "exit";
      scene.timer = 0;
      for (const id of scene.participants) {
        const c = world.getCharacter(id);
        if (c) {
          const dir = Math.random() > 0.5 ? 1 : -1;
          c.sheep.walkTarget = c.sheep.x + dir * (SIZE * 2 + Math.random() * SIZE * 3);
        }
      }
    }
  } else if (scene.timer > 3000) {
    return false;
  }
  return true;
}

export function drawSpectacleScene(
  scene: SpectacleScene,
  ctx: CanvasRenderingContext2D,
  world: SpectacleWorld,
): void {
  switch (scene.type) {
    case "wolf": drawWolf(ctx, scene.actorX, scene.actorY, scene.facingRight); break;
    case "ufo": drawUfo(ctx, scene.actorX, scene.actorY, scene.phase === "perform"); break;
    case "merchant": drawMerchant(ctx, scene.actorX, scene.actorY, scene.facingRight); break;
    case "balloon": drawBalloon(ctx, scene.actorX, scene.actorY); break;
    case "shearing": drawShornOverlays(ctx, scene, world); break;
    case "showdown": drawTumbleweed(ctx, scene, world); break;
    case "feast": break; // campfire visuals come from the existing idle_campfire state
  }
}

function drawWolf(ctx: CanvasRenderingContext2D, x: number, y: number, facingRight: boolean) {
  ctx.save();
  ctx.translate(x + 48, y + 48);
  if (!facingRight) ctx.scale(-1, 1);
  ctx.translate(-48, -48);
  const s = 3;
  ctx.fillStyle = "#4a4a55";                       // body
  ctx.fillRect(8 * s, 14 * s, 18 * s, 8 * s);
  ctx.fillRect(22 * s, 9 * s, 8 * s, 7 * s);       // head
  ctx.fillStyle = "#3a3a44";
  ctx.fillRect(27 * s, 6 * s, 3 * s, 4 * s);       // ear
  ctx.fillRect(4 * s, 13 * s, 5 * s, 3 * s);       // tail
  ctx.fillRect(9 * s, 22 * s, 3 * s, 5 * s);       // legs
  ctx.fillRect(14 * s, 22 * s, 3 * s, 5 * s);
  ctx.fillRect(19 * s, 22 * s, 3 * s, 5 * s);
  ctx.fillRect(23 * s, 22 * s, 3 * s, 5 * s);
  ctx.fillStyle = "#e94560";                       // eye
  ctx.fillRect(26 * s, 10 * s, 2 * s, 2 * s);
  ctx.fillStyle = "#ffffff";                       // fang
  ctx.fillRect(29 * s, 14 * s, 1 * s, 2 * s);
  ctx.restore();
}

function drawUfo(ctx: CanvasRenderingContext2D, x: number, y: number, beamOn: boolean) {
  ctx.save();
  if (beamOn) {
    const grad = ctx.createLinearGradient(x + 40, y + 20, x + 40, y + 400);
    grad.addColorStop(0, "rgba(120, 255, 160, 0.35)");
    grad.addColorStop(1, "rgba(120, 255, 160, 0)");
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.moveTo(x + 25, y + 20);
    ctx.lineTo(x + 55, y + 20);
    ctx.lineTo(x + 95, y + 400);
    ctx.lineTo(x - 15, y + 400);
    ctx.closePath();
    ctx.fill();
  }
  ctx.fillStyle = "#8899aa";                        // saucer
  ctx.beginPath();
  ctx.ellipse(x + 40, y + 14, 40, 12, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = "#bfe8ff";                        // dome
  ctx.beginPath();
  ctx.arc(x + 40, y + 6, 14, Math.PI, 0);
  ctx.fill();
  ctx.fillStyle = "#ffe066";                        // lights
  const t = Math.floor(Date.now() / 300) % 3;
  for (let i = 0; i < 3; i++) {
    ctx.globalAlpha = i === t ? 1 : 0.35;
    ctx.fillRect(x + 18 + i * 20, y + 16, 6, 4);
  }
  ctx.restore();
}

function drawMerchant(ctx: CanvasRenderingContext2D, x: number, y: number, facingRight: boolean) {
  const s = 3;
  ctx.save();
  ctx.translate(x + 48, y + 48);
  if (!facingRight) ctx.scale(-1, 1);
  ctx.translate(-48, -48);
  ctx.fillStyle = "#9a9aa5";                        // grey wool body
  ctx.fillRect(8 * s, 12 * s, 16 * s, 10 * s);
  ctx.fillRect(21 * s, 8 * s, 7 * s, 8 * s);        // head
  ctx.fillStyle = "#6f6f7a";
  ctx.fillRect(10 * s, 22 * s, 3 * s, 5 * s);       // legs
  ctx.fillRect(19 * s, 22 * s, 3 * s, 5 * s);
  ctx.fillStyle = "#1a1a2e";                        // top hat
  ctx.fillRect(21 * s, 3 * s, 7 * s, 2 * s);
  ctx.fillRect(22.5 * s, 0 * s, 4 * s, 3 * s);
  ctx.fillStyle = "#7a5230";                        // wares bundle
  ctx.fillRect(6 * s, 8 * s, 7 * s, 6 * s);
  ctx.strokeStyle = "#4d3319";
  ctx.lineWidth = 2;
  ctx.strokeRect(6 * s, 8 * s, 7 * s, 6 * s);
  ctx.fillStyle = "#1a1a2e";                        // eye
  ctx.fillRect(25 * s, 10 * s, 2 * s, 2 * s);
  ctx.restore();
}

function drawBalloon(ctx: CanvasRenderingContext2D, x: number, y: number) {
  ctx.save();
  const bob = Math.sin(Date.now() / 900) * 6;
  const by = y + bob;
  ctx.fillStyle = "#e94560";                        // envelope
  ctx.beginPath();
  ctx.arc(x, by, 34, Math.PI * 0.95, Math.PI * 2.05);
  ctx.fill();
  ctx.fillStyle = "#d4a520";
  ctx.beginPath();
  ctx.arc(x, by, 34, Math.PI * 1.25, Math.PI * 1.75);
  ctx.fill();
  ctx.strokeStyle = "#6f4e37";                      // ropes
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(x - 20, by + 24); ctx.lineTo(x - 9, by + 48);
  ctx.moveTo(x + 20, by + 24); ctx.lineTo(x + 9, by + 48);
  ctx.stroke();
  ctx.fillStyle = "#7a5230";                        // basket
  ctx.fillRect(x - 11, by + 48, 22, 14);
  ctx.restore();
}

function drawShornOverlays(ctx: CanvasRenderingContext2D, scene: SpectacleScene, world: SpectacleWorld) {
  // Pink "naked" ellipse over each sheep's wool; fades back in the last 10s.
  const total = 60_000;
  const fadeStart = total - 10_000;
  const alpha = scene.timer < fadeStart ? 0.65 : 0.65 * (1 - (scene.timer - fadeStart) / 10_000);
  if (alpha <= 0) return;
  ctx.save();
  ctx.globalAlpha = Math.max(0, alpha);
  ctx.fillStyle = "#f2b9c4";
  for (const id of scene.participants) {
    const c = world.getCharacter(id);
    if (!c) continue;
    const sz = c.sheep.displaySize;
    ctx.beginPath();
    ctx.ellipse(c.sheep.x + sz * 0.45, c.sheep.y + sz * 0.55, sz * 0.32, sz * 0.24, 0, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.restore();
}

function drawTumbleweed(ctx: CanvasRenderingContext2D, scene: SpectacleScene, world: SpectacleWorld) {
  if (scene.phase !== "perform") return;
  const x = (scene.data.tumbleX = (scene.data.tumbleX ?? -20) + 4);
  const y = world.screenH - 130 + Math.abs(Math.sin(x / 40)) * -18;
  ctx.save();
  ctx.strokeStyle = "#b0925a";
  ctx.lineWidth = 2;
  ctx.translate(x, y);
  ctx.rotate(x / 30);
  ctx.beginPath();
  ctx.arc(0, 0, 12, 0, Math.PI * 2);
  for (let i = 0; i < 4; i++) {
    ctx.moveTo(-12, 0);
    ctx.quadraticCurveTo(0, (i - 1.5) * 8, 12, 0);
  }
  ctx.stroke();
  ctx.restore();
}

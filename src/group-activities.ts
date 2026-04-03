import { Sheep } from "./sheep";
import { SpeechBubble } from "./speech-bubble";
import type { EasterTheme } from "./easter-theme";

export type GroupActivityType = "campfire_circle" | "follow_leader" | "sync_bounce" | "huddle" | "easter_egg_hunt";

export interface EasterHuntFinder {
  eggsFound: number;
  goldenEggsFound: number;
}

export interface EasterHuntSummary {
  totalEggs: number;
  durationMs: number;
  allCollected: boolean;
  paintedEggsUsed: number;
  winnerId?: string;
  finders: Array<{
    id: string;
    eggsFound: number;
    goldenEggsFound: number;
  }>;
}

export interface GroupActivity {
  type: GroupActivityType;
  participants: string[];
  phase: "gathering" | "performing" | "celebrating" | "dispersing";
  timer: number;
  duration: number;
  centerX: number;
  leaderId?: string;
  bounceCount?: number;
  // Easter egg hunt state
  eggAssignments?: Map<string, number>; // participant id → egg index
  collectedEggs?: Set<number>;
  eggReactionTimer?: number;
  eggFinders?: Map<string, EasterHuntFinder>;
  huntSummary?: EasterHuntSummary;
}

const DISPLAY_SIZE = 96;
const EGG_COLLECTION_RADIUS = DISPLAY_SIZE * 0.35;

const EGG_HUNT_QUIPS = [
  "Found one!",
  "Egg-cellent!",
  "This one's mine!",
  "Over here!",
  "Got it!",
];

const EGG_HUNT_PERSONALITY_QUIPS: Record<string, string[]> = {
  snarky: ["These eggs are poorly hidden.", "Amateur hour.", "I found it first, obviously."],
  wholesome: ["Best. Easter. Ever!", "What a pretty egg!", "This is so fun!"],
  chaotic: ["EGG EGG EGG EGG", "THE EGG CHOSE ME", "I AM THE EGG LORD"],
  "passive-aggressive": ["Oh, I found one. How... delightful.", "I suppose someone had to find it.", "How nice for me."],
  good_colleague: ["Fint egg, ja", "Påskeegg!", "Nå snakker vi"],
};

const EGG_HUNT_VICTORY_LINES = [
  "All eggs found!",
  "Spring sweep complete!",
  "The meadow has been cleared!",
];

const EGG_HUNT_WINNER_LINES = [
  "I carried this hunt.",
  "You're welcome, everyone.",
  "I deserve the golden grass.",
];

/** Check if enough sheep are calm and near each other to start a group activity */
export function canStartGroupActivity(
  sheepList: Array<{ id: string; x: number; calm: boolean }>,
): string[] | null {
  // Need at least 3 calm sheep within 5 display widths of each other
  const calm = sheepList.filter((s) => s.calm);
  if (calm.length < 3) return null;

  // Find a cluster — check if any 3+ are within range
  for (let i = 0; i < calm.length; i++) {
    const cluster = [calm[i]];
    for (let j = 0; j < calm.length; j++) {
      if (i === j) continue;
      if (Math.abs(calm[i].x - calm[j].x) < DISPLAY_SIZE * 5) {
        cluster.push(calm[j]);
      }
    }
    if (cluster.length >= 3) {
      return cluster.map((s) => s.id);
    }
  }
  return null;
}

export function createGroupActivity(
  type: GroupActivityType,
  participants: string[],
  centerX: number,
): GroupActivity {
  const durations: Record<GroupActivityType, number> = {
    campfire_circle: 15000 + Math.random() * 10000,
    follow_leader: 10000 + Math.random() * 5000,
    sync_bounce: 6000,
    huddle: 10000 + Math.random() * 5000,
    easter_egg_hunt: 20000 + Math.random() * 10000,
  };

  return {
    type,
    participants,
    phase: "gathering",
    timer: 0,
    duration: durations[type],
    centerX,
    leaderId: type === "follow_leader" ? participants[Math.floor(Math.random() * participants.length)] : undefined,
    bounceCount: type === "sync_bounce" ? 0 : undefined,
    eggAssignments: type === "easter_egg_hunt" ? new Map() : undefined,
    collectedEggs: type === "easter_egg_hunt" ? new Set() : undefined,
    eggReactionTimer: type === "easter_egg_hunt" ? 0 : undefined,
    eggFinders: type === "easter_egg_hunt" ? new Map() : undefined,
  };
}

export function pickActivityType(easterTheme?: EasterTheme | null): GroupActivityType {
  if (easterTheme?.active && Math.random() < 0.4) {
    return "easter_egg_hunt";
  }
  const types: GroupActivityType[] = ["campfire_circle", "follow_leader", "sync_bounce", "huddle"];
  return types[Math.floor(Math.random() * types.length)];
}

/** Returns true while activity is still running, false when done */
export function updateGroupActivity(
  activity: GroupActivity,
  dt: number,
  getSheep: (id: string) => { sheep: Sheep; bubble: SpeechBubble; personality?: string } | null,
  easterTheme?: EasterTheme | null,
): boolean {
  activity.timer += dt;

  switch (activity.phase) {
    case "gathering":
      return updateGathering(activity, dt, getSheep, easterTheme);
    case "performing":
      return updatePerforming(activity, dt, getSheep, easterTheme);
    case "celebrating":
      return updateCelebrating(activity, dt, getSheep, easterTheme);
    case "dispersing":
      return updateDispersing(activity);
  }
}

function updateGathering(
  activity: GroupActivity,
  _dt: number,
  getSheep: (id: string) => { sheep: Sheep; bubble: SpeechBubble } | null,
  easterTheme?: EasterTheme | null,
): boolean {
  let allGathered = true;

  for (const id of activity.participants) {
    const entry = getSheep(id);
    if (!entry) continue;
    const sheep = entry.sheep;

    // Set walk target toward center
    if (sheep.walkTarget === null && Math.abs(sheep.x - activity.centerX) > DISPLAY_SIZE * 1.5) {
      sheep.walkTarget = activity.centerX + (activity.participants.indexOf(id) - 1) * DISPLAY_SIZE * 0.8;
    }

    if (Math.abs(sheep.x - activity.centerX) > DISPLAY_SIZE * 2) {
      allGathered = false;
    }
  }

  // Timeout gathering after 8s — just start performing
  if (allGathered || activity.timer > 8000) {
    activity.phase = "performing";
    activity.timer = 0;

    if (activity.type === "easter_egg_hunt" && easterTheme) {
      easterTheme.prepareHunt(activity.participants);
      activity.huntSummary = {
        totalEggs: easterTheme.getEggPositions().length,
        durationMs: 0,
        allCollected: false,
        paintedEggsUsed: easterTheme.getPaintedEggsUsedCount(),
        finders: [],
      };
    }

    // Announce the activity
    if (activity.type === "huddle") {
      const first = getSheep(activity.participants[0]);
      if (first) first.bubble.show("Group meeting!", 3000);
    } else if (activity.type === "campfire_circle") {
      const first = getSheep(activity.participants[0]);
      if (first) first.bubble.show("Campfire time!", 3000);
    } else if (activity.type === "easter_egg_hunt") {
      const first = getSheep(activity.participants[0]);
      if (first) first.bubble.show("Easter egg hunt!", 3000);
    }
  }

  return true;
}

function updatePerforming(
  activity: GroupActivity,
  dt: number,
  getSheep: (id: string) => { sheep: Sheep; bubble: SpeechBubble; personality?: string } | null,
  easterTheme?: EasterTheme | null,
): boolean {
  switch (activity.type) {
    case "campfire_circle": {
      // First participant does campfire, others sit nearby
      for (let i = 0; i < activity.participants.length; i++) {
        const entry = getSheep(activity.participants[i]);
        if (!entry) continue;
        const sheep = entry.sheep;
        if (i === 0 && sheep.state !== "idle_campfire") {
          sheep.playAnimation("bounce"); // will transition to campfire via bored state
          // Directly set state for leader
          (sheep as any).state = "idle_campfire";
          (sheep as any).stateTimer = 0;
          (sheep as any).stateDuration = activity.duration;
          (sheep as any).campfireSparks = [];
        } else if (i > 0 && sheep.state !== "sit") {
          (sheep as any).state = "sit";
          (sheep as any).stateTimer = 0;
          (sheep as any).stateDuration = activity.duration;
        }
      }
      break;
    }

    case "follow_leader": {
      // Leader walks, others follow
      const leader = getSheep(activity.leaderId!);
      if (leader) {
        if (leader.sheep.state !== "walk") {
          leader.sheep.facingRight = Math.random() > 0.5;
          (leader.sheep as any).state = "walk";
          (leader.sheep as any).stateTimer = 0;
          (leader.sheep as any).stateDuration = activity.duration;
        }
        // Others follow leader
        for (const id of activity.participants) {
          if (id === activity.leaderId) continue;
          const follower = getSheep(id);
          if (follower) {
            follower.sheep.walkTarget = leader.sheep.x;
          }
        }
      }
      break;
    }

    case "sync_bounce": {
      // Synchronized bouncing every 1.5s
      const interval = 1500;
      const expectedBounces = Math.floor(activity.timer / interval);
      if (activity.bounceCount !== undefined && expectedBounces > activity.bounceCount && activity.bounceCount < 4) {
        activity.bounceCount = expectedBounces;
        for (let i = 0; i < activity.participants.length; i++) {
          const entry = getSheep(activity.participants[i]);
          if (entry) {
            // Stagger slightly for cascade effect
            setTimeout(() => entry.sheep.playAnimation("bounce"), i * 150);
          }
        }
      }
      break;
    }

    case "huddle": {
      // Everyone sits close together
      for (const id of activity.participants) {
        const entry = getSheep(id);
        if (!entry) continue;
        if (entry.sheep.state !== "sit" && entry.sheep.state !== "idle") {
          (entry.sheep as any).state = "sit";
          (entry.sheep as any).stateTimer = 0;
          (entry.sheep as any).stateDuration = activity.duration;
        }
      }
      break;
    }

    case "easter_egg_hunt": {
      const finished = updateEasterEggHunt(activity, dt, getSheep, easterTheme);
      if (finished) {
        startHuntCelebration(activity, getSheep, easterTheme);
        return true;
      }
      break;
    }
  }

  if (activity.timer >= activity.duration) {
    if (activity.type === "easter_egg_hunt") {
      finalizeHuntSummary(activity, easterTheme, false);
      easterTheme?.finishHunt();
    }
    startDispersing(activity, getSheep);
  }

  // Call campfire update for the leader during campfire_circle
  if (activity.type === "campfire_circle") {
    const leader = getSheep(activity.participants[0]);
    if (leader) {
      leader.sheep.update(dt);
    }
  }

  return true;
}

function updateCelebrating(
  activity: GroupActivity,
  dt: number,
  getSheep: (id: string) => { sheep: Sheep; bubble: SpeechBubble; personality?: string } | null,
  easterTheme?: EasterTheme | null,
): boolean {
  if (activity.type !== "easter_egg_hunt") {
    startDispersing(activity, getSheep);
    return true;
  }

  if (activity.eggReactionTimer !== undefined && activity.eggReactionTimer > 0) {
    activity.eggReactionTimer -= dt;
    if (activity.eggReactionTimer <= 0) {
      const summary = finalizeHuntSummary(activity, easterTheme, true);
      if (summary?.winnerId) {
        const winner = getSheep(summary.winnerId);
        if (winner && !winner.bubble.visible) {
          winner.bubble.show(EGG_HUNT_WINNER_LINES[Math.floor(Math.random() * EGG_HUNT_WINNER_LINES.length)], 2400);
        }
      }
      activity.eggReactionTimer = 0;
    }
  }

  if (activity.timer >= 2200) {
    easterTheme?.finishHunt();
    startDispersing(activity, getSheep);
  }
  return true;
}

function updateEasterEggHunt(
  activity: GroupActivity,
  _dt: number,
  getSheep: (id: string) => { sheep: Sheep; bubble: SpeechBubble; personality?: string } | null,
  easterTheme?: EasterTheme | null,
) : boolean {
  if (!easterTheme || !activity.eggAssignments || !activity.collectedEggs) return false;

  const eggs = easterTheme.getEggPositions();
  const uncollected = eggs.map((e, i) => ({ ...e, index: i })).filter((e) => !e.found && !activity.collectedEggs!.has(e.index));

  // Assign unassigned participants to eggs
  for (const id of activity.participants) {
    if (activity.eggAssignments.has(id)) {
      // Check if their target egg was already collected
      const targetIdx = activity.eggAssignments.get(id)!;
      if (activity.collectedEggs.has(targetIdx)) {
        activity.eggAssignments.delete(id);
      }
    }

    if (!activity.eggAssignments.has(id) && uncollected.length > 0) {
      // Assign nearest uncollected egg
      const entry = getSheep(id);
      if (!entry) continue;
      let nearest = uncollected[0];
      let nearestDist = Math.abs(entry.sheep.x - nearest.x);
      for (const egg of uncollected) {
        const dist = Math.abs(entry.sheep.x - egg.x);
        if (dist < nearestDist) {
          nearest = egg;
          nearestDist = dist;
        }
      }
      activity.eggAssignments.set(id, nearest.index);
      // Remove from uncollected so others pick different eggs
      const idx = uncollected.indexOf(nearest);
      if (idx >= 0) uncollected.splice(idx, 1);
    }
  }

  // Move participants toward their eggs and check for collection
  for (const id of activity.participants) {
    const entry = getSheep(id);
    if (!entry) continue;

    const targetIdx = activity.eggAssignments.get(id);
    if (targetIdx === undefined) {
      // No eggs left to find — sit happily
      if (entry.sheep.state !== "sit" && entry.sheep.state !== "idle") {
        (entry.sheep as any).state = "sit";
        (entry.sheep as any).stateTimer = 0;
        (entry.sheep as any).stateDuration = activity.duration;
      }
      continue;
    }

    const egg = eggs[targetIdx];
    if (!egg) continue;

    // Check if reached the egg (before setting walk target so we don't overshoot)
    if (Math.abs(entry.sheep.x - egg.x) < EGG_COLLECTION_RADIUS) {
      activity.collectedEggs!.add(targetIdx);
      activity.eggAssignments.delete(id);
      easterTheme.collectEgg(targetIdx, id);
      const finder = activity.eggFinders?.get(id) ?? { eggsFound: 0, goldenEggsFound: 0 };
      finder.eggsFound += 1;
      if (egg.golden) finder.goldenEggsFound += 1;
      activity.eggFinders?.set(id, finder);

      // Show reaction
      entry.sheep.playAnimation("bounce");
      const personalityKey = entry.personality || (id === "good_colleague" ? "good_colleague" : "");
      const quipPool = EGG_HUNT_PERSONALITY_QUIPS[personalityKey] || EGG_HUNT_QUIPS;
      const quip = quipPool[Math.floor(Math.random() * quipPool.length)];
      entry.bubble.show(quip, 3000);
      continue;
    }

    // Walk toward egg — force into walk state if sitting/idling
    entry.sheep.walkTarget = egg.x;
    const state = entry.sheep.state;
    if (state === "idle" || state === "sit" || state === "idle_sleep" || state === "idle_campfire" ||
        state === "idle_counting" || state === "idle_egg_painting") {
      entry.sheep.facingRight = egg.x > entry.sheep.x;
      (entry.sheep as any).state = "walk";
      (entry.sheep as any).stateTimer = 0;
      (entry.sheep as any).stateDuration = 15000; // long enough to reach the egg
    }
  }

  return activity.collectedEggs.size >= eggs.length && eggs.length > 0;
}

function updateDispersing(activity: GroupActivity): boolean {
  // Dispersal lasts 3s then activity ends
  return activity.timer < 3000;
}

function startDispersing(
  activity: GroupActivity,
  getSheep: (id: string) => { sheep: Sheep; bubble: SpeechBubble; personality?: string } | null,
) {
  activity.phase = "dispersing";
  activity.timer = 0;

  for (const id of activity.participants) {
    const entry = getSheep(id);
    if (entry) {
      const dir = Math.random() > 0.5 ? 1 : -1;
      entry.sheep.walkTarget = entry.sheep.x + dir * (DISPLAY_SIZE * 2 + Math.random() * DISPLAY_SIZE * 3);
    }
  }
}

function startHuntCelebration(
  activity: GroupActivity,
  getSheep: (id: string) => { sheep: Sheep; bubble: SpeechBubble; personality?: string } | null,
  easterTheme?: EasterTheme | null,
) {
  const summary = finalizeHuntSummary(activity, easterTheme, true);
  activity.phase = "celebrating";
  activity.timer = 0;
  activity.eggReactionTimer = 850;

  const speakerId = summary?.winnerId ?? activity.participants[0];
  const speaker = speakerId ? getSheep(speakerId) : null;
  if (speaker) {
    speaker.bubble.show(EGG_HUNT_VICTORY_LINES[Math.floor(Math.random() * EGG_HUNT_VICTORY_LINES.length)], 2200);
  }

  for (const id of activity.participants) {
    const entry = getSheep(id);
    if (entry) {
      entry.sheep.playAnimation("bounce");
    }
  }
}

function finalizeHuntSummary(
  activity: GroupActivity,
  easterTheme?: EasterTheme | null,
  allCollected: boolean = false,
): EasterHuntSummary | undefined {
  if (activity.type !== "easter_egg_hunt") return undefined;

  const finders = activity.participants.map((id) => {
    const stats = activity.eggFinders?.get(id);
    return {
      id,
      eggsFound: stats?.eggsFound ?? 0,
      goldenEggsFound: stats?.goldenEggsFound ?? 0,
    };
  });
  finders.sort((a, b) => (
    b.eggsFound - a.eggsFound ||
    b.goldenEggsFound - a.goldenEggsFound
  ));

  activity.huntSummary = {
    totalEggs: activity.huntSummary?.totalEggs ?? easterTheme?.getEggPositions().length ?? activity.collectedEggs?.size ?? 0,
    durationMs: activity.timer,
    allCollected,
    paintedEggsUsed: activity.huntSummary?.paintedEggsUsed ?? easterTheme?.getPaintedEggsUsedCount() ?? 0,
    winnerId: finders[0] && finders[0].eggsFound > 0 ? finders[0].id : undefined,
    finders,
  };
  return activity.huntSummary;
}

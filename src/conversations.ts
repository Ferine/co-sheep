import { ConversationScript, FriendPersonality } from "./types";
import type { EasterTheme } from "./easter-theme";

type ScriptTemplate = ConversationScript;

export interface ConversationContext {
  personalityA?: FriendPersonality;
  personalityB?: FriendPersonality;
  weather?: string | null;
  hour?: number;
  easterTheme?: EasterTheme | null;
  recentEasterHunt?: boolean;
  eggPaintingActive?: boolean;
}

// $A and $B are placeholders resolved at pick time
const GENERIC_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "Baaaa?", duration: 3000, delay: 0 },
    { speakerId: "$B", text: "Baaaa.", duration: 3000, delay: 500 },
    { speakerId: "$A", text: "...fair enough.", duration: 3000, delay: 800, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "*stares*", duration: 2500, delay: 0 },
    { speakerId: "$B", text: "*stares back*", duration: 2500, delay: 600 },
    { speakerId: "$A", text: "...nice weather.", duration: 3000, delay: 1000 },
  ],
  [
    { speakerId: "$A", text: "You ever wonder what's outside the screen?", duration: 4000, delay: 0 },
    { speakerId: "$B", text: "Don't be weird.", duration: 3000, delay: 800, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "What does the human DO all day?", duration: 4000, delay: 0 },
    { speakerId: "$B", text: "I try not to think about it.", duration: 3500, delay: 700 },
  ],
  [
    { speakerId: "$A", text: "*yawns*", duration: 2500, delay: 0 },
    { speakerId: "$B", text: "*yawns*", duration: 2500, delay: 400 },
    { speakerId: "$A", text: "Hey! Stop that!", duration: 3000, delay: 600, animation: "bounce" },
  ],
  [
    { speakerId: "$B", text: "You come here often?", duration: 3500, delay: 0 },
    { speakerId: "$A", text: "We literally live on the same screen.", duration: 4000, delay: 700, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "Still thinking about tabs?", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "Always.", duration: 2500, delay: 600 },
    { speakerId: "$A", text: "Same.", duration: 2000, delay: 500, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "Do you think pixels dream?", duration: 4000, delay: 0 },
    { speakerId: "$B", text: "Only of higher resolution.", duration: 3500, delay: 800 },
    { speakerId: "$A", text: "That's deep.", duration: 2500, delay: 600, animation: "bounce" },
  ],
  [
    { speakerId: "$B", text: "What's your favorite color?", duration: 3000, delay: 0 },
    { speakerId: "$A", text: "I'm literally tinted. Take a guess.", duration: 4000, delay: 700, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "We should start a band.", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "We don't have hands.", duration: 3000, delay: 700 },
    { speakerId: "$A", text: "Details.", duration: 2000, delay: 500, animation: "bounce" },
  ],
  [
    { speakerId: "$A", text: "Race you to the other side!", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "We walk at the same speed.", duration: 3500, delay: 700 },
    { speakerId: "$A", text: "So it's fair!", duration: 2500, delay: 600, animation: "zoom" },
    { speakerId: "$B", text: "That's not—", duration: 2000, delay: 400 },
  ],
  [
    { speakerId: "$B", text: "What if we just... didn't move?", duration: 3500, delay: 0 },
    { speakerId: "$A", text: "Revolutionary.", duration: 2500, delay: 700 },
    { speakerId: "$B", text: "Thank you. I've been thinking.", duration: 3500, delay: 600 },
  ],
];

const GOOD_COLLEAGUE_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "good_colleague", text: "Hva skjer?", duration: 3000, delay: 0 },
    { speakerId: "$OTHER", text: "...what?", duration: 2500, delay: 600 },
    { speakerId: "good_colleague", text: "Nei, ingenting.", duration: 3000, delay: 800, animation: "headshake" },
  ],
  [
    { speakerId: "good_colleague", text: "Noen som vil ha kaffe?", duration: 3500, delay: 0 },
    { speakerId: "$OTHER", text: "I don't speak... whatever that is.", duration: 4000, delay: 700 },
    { speakerId: "good_colleague", text: "*shrugs*", duration: 2500, delay: 600, animation: "headshake" },
  ],
  [
    { speakerId: "good_colleague", text: "Viktig meeting klokka tre.", duration: 3500, delay: 0 },
    { speakerId: "$OTHER", text: "Are you... scheduling something?", duration: 4000, delay: 800 },
    { speakerId: "good_colleague", text: "Bare prat.", duration: 2500, delay: 600 },
  ],
  [
    { speakerId: "good_colleague", text: "Kontorlivet er hardt.", duration: 3500, delay: 0 },
    { speakerId: "$OTHER", text: "*nods politely*", duration: 2500, delay: 700 },
  ],
  [
    { speakerId: "good_colleague", text: "Har du sett TPS-rapporten?", duration: 3500, delay: 0 },
    { speakerId: "$OTHER", text: "The... what now?", duration: 3000, delay: 700 },
    { speakerId: "good_colleague", text: "Gløm det.", duration: 2500, delay: 600, animation: "headshake" },
  ],
  [
    { speakerId: "good_colleague", text: "Lunsjpause snart.", duration: 3000, delay: 0 },
    { speakerId: "$OTHER", text: "*stomach growls*", duration: 2500, delay: 600 },
    { speakerId: "good_colleague", text: "*tilbyr kaffe*", duration: 3000, delay: 700, animation: "bounce" },
  ],
];

const MAIN_SHEEP_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$FRIEND", text: "Is it always this judgmental?", duration: 4000, delay: 0 },
    { speakerId: "main", text: "I prefer 'observant'.", duration: 3500, delay: 700, animation: "headshake" },
  ],
  [
    { speakerId: "$FRIEND", text: "Why does it keep looking at the screen?", duration: 4500, delay: 0 },
    { speakerId: "main", text: "Wouldn't YOU?", duration: 3000, delay: 800, animation: "bounce" },
  ],
  [
    { speakerId: "good_colleague", text: "Bra jobba i dag.", duration: 3000, delay: 0 },
    { speakerId: "main", text: "He just complimented you... I think.", duration: 4500, delay: 700 },
  ],
  [
    { speakerId: "$FRIEND", text: "What are you thinking about?", duration: 3500, delay: 0 },
    { speakerId: "main", text: "How many tabs the human has open. It haunts me.", duration: 5000, delay: 800, animation: "vibrate" },
  ],
  [
    { speakerId: "$FRIEND", text: "You seem stressed.", duration: 3000, delay: 0 },
    { speakerId: "main", text: "YOU try watching someone code in production.", duration: 4500, delay: 700, animation: "vibrate" },
  ],
  [
    { speakerId: "$FRIEND", text: "Do you ever take a break?", duration: 3500, delay: 0 },
    { speakerId: "main", text: "I literally told the human that 5 minutes ago.", duration: 4500, delay: 700, animation: "headshake" },
    { speakerId: "$FRIEND", text: "Did they listen?", duration: 3000, delay: 600 },
    { speakerId: "main", text: "What do you think.", duration: 3000, delay: 700 },
  ],
];

// --- Personality-pair scripts ---

const SNARKY_WHOLESOME_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "Everything is terrible.", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "But at least we have each other!", duration: 3500, delay: 700, animation: "bounce" },
    { speakerId: "$A", text: "That's... not the comfort you think it is.", duration: 4000, delay: 800, animation: "headshake" },
  ],
  [
    { speakerId: "$B", text: "I made you a friendship pixel!", duration: 3500, delay: 0, animation: "bounce" },
    { speakerId: "$A", text: "It's a white dot.", duration: 2500, delay: 700 },
    { speakerId: "$B", text: "A friendship white dot!", duration: 3000, delay: 600 },
    { speakerId: "$A", text: "...", duration: 2000, delay: 500, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "Stop being so positive. It's suspicious.", duration: 4000, delay: 0 },
    { speakerId: "$B", text: "I can't help it! Life is wonderful!", duration: 4000, delay: 800, animation: "bounce" },
    { speakerId: "$A", text: "*visible discomfort*", duration: 2500, delay: 600 },
  ],
];

const CHAOTIC_CHAOTIC_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "WHAT IF WE SPIN AT THE SAME TIME", duration: 3500, delay: 0, animation: "spin" },
    { speakerId: "$B", text: "GENIUS", duration: 2000, delay: 500, animation: "spin" },
    { speakerId: "$A", text: "I'M SO DIZZY", duration: 2500, delay: 600 },
    { speakerId: "$B", text: "AGAIN???", duration: 2000, delay: 400, animation: "bounce" },
  ],
  [
    { speakerId: "$A", text: "I just had the BEST idea", duration: 3500, delay: 0, animation: "bounce" },
    { speakerId: "$B", text: "TELL ME TELL ME", duration: 2500, delay: 500 },
    { speakerId: "$A", text: "I forgot it.", duration: 2500, delay: 600 },
    { speakerId: "$B", text: "THAT WAS THE BEST IDEA", duration: 3500, delay: 500, animation: "zoom" },
  ],
];

const PA_SNARKY_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "I'm FINE.", duration: 2500, delay: 0 },
    { speakerId: "$B", text: "Nobody asked.", duration: 2500, delay: 700, animation: "headshake" },
    { speakerId: "$A", text: "Wow. Okay then.", duration: 3000, delay: 600 },
  ],
  [
    { speakerId: "$A", text: "Must be nice having opinions.", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "It is, actually.", duration: 3000, delay: 700 },
    { speakerId: "$A", text: "I wouldn't know. I'm just standing here. Alone.", duration: 4500, delay: 800 },
  ],
];

const WHOLESOME_WHOLESOME_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "You're my best friend!", duration: 3000, delay: 0, animation: "bounce" },
    { speakerId: "$B", text: "No, YOU'RE my best friend!", duration: 3000, delay: 600, animation: "bounce" },
    { speakerId: "$A", text: "This is the best day ever!", duration: 3000, delay: 500, animation: "bounce" },
  ],
  [
    { speakerId: "$A", text: "I hope you're having a good day.", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "It's better now!", duration: 3000, delay: 700, animation: "bounce" },
  ],
];

// --- Time-aware scripts ---

const MORNING_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "Good morning!", duration: 3000, delay: 0, animation: "bounce" },
    { speakerId: "$B", text: "*yawns* Is it morning already?", duration: 3500, delay: 700 },
  ],
  [
    { speakerId: "$A", text: "Fresh start energy!", duration: 3000, delay: 0, animation: "bounce" },
    { speakerId: "$B", text: "I need coffee. I mean grass.", duration: 3500, delay: 700 },
  ],
];

const LATE_NIGHT_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "Why are we still awake?", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "Because the human is still awake.", duration: 3500, delay: 700 },
    { speakerId: "$A", text: "That's concerning.", duration: 3000, delay: 600, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "*can barely keep eyes open*", duration: 3000, delay: 0 },
    { speakerId: "$B", text: "Shhh. Just... rest.", duration: 3000, delay: 700 },
  ],
];

const AFTERNOON_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "Post-lunch slump hitting hard.", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "Tell me about it.", duration: 2500, delay: 700 },
    { speakerId: "$A", text: "*slowly slides down*", duration: 3000, delay: 600 },
  ],
];

// --- Weather-aware scripts ---

const RAIN_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "Is that... rain?", duration: 3000, delay: 0 },
    { speakerId: "$B", text: "MY WOOL! IT'LL SHRINK!", duration: 3500, delay: 700, animation: "vibrate" },
    { speakerId: "$A", text: "We're inside a screen.", duration: 3000, delay: 600, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "Rainy day. Perfect for napping.", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "Couldn't agree more.", duration: 3000, delay: 700 },
  ],
];

const SNOW_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "SNOW!", duration: 2000, delay: 0, animation: "bounce" },
    { speakerId: "$B", text: "SNOWBALL FIGHT!", duration: 2500, delay: 500, animation: "bounce" },
    { speakerId: "$A", text: "We don't have hands!", duration: 3000, delay: 600, animation: "headshake" },
    { speakerId: "$B", text: "HEADBUTT FIGHT!", duration: 2500, delay: 500, animation: "zoom" },
  ],
];

const NICE_WEATHER_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "Beautiful day outside.", duration: 3000, delay: 0 },
    { speakerId: "$B", text: "And here we are. On a screen.", duration: 3500, delay: 700 },
    { speakerId: "$A", text: "Living the dream.", duration: 3000, delay: 600, animation: "headshake" },
  ],
];

// --- Easter ---

const EASTER_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "I found more eggs than you.", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "It's not a competition.", duration: 3000, delay: 700 },
    { speakerId: "$A", text: "That's what losers say.", duration: 3000, delay: 600, animation: "bounce" },
  ],
  [
    { speakerId: "$A", text: "Do you think the eggs were always here?", duration: 4000, delay: 0 },
    { speakerId: "$B", text: "What do you mean?", duration: 2500, delay: 800 },
    { speakerId: "$A", text: "Like... who hides them? We're sheep.", duration: 4000, delay: 700, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "I'm going to eat all the chocolate eggs.", duration: 4000, delay: 0, animation: "bounce" },
    { speakerId: "$B", text: "Those are painted. Not chocolate.", duration: 3500, delay: 700 },
    { speakerId: "$A", text: "...what.", duration: 2000, delay: 600, animation: "vibrate" },
  ],
  [
    { speakerId: "$A", text: "Happy Easter!", duration: 2500, delay: 0, animation: "bounce" },
    { speakerId: "$B", text: "Baaaa-ster.", duration: 3000, delay: 600, animation: "spin" },
    { speakerId: "$A", text: "Please stop.", duration: 2500, delay: 700, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "Why does Easter move every year?", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "Something about the moon.", duration: 3000, delay: 800 },
    { speakerId: "$A", text: "The moon controls us all.", duration: 3500, delay: 600, animation: "vibrate" },
  ],
  [
    { speakerId: "$A", text: "I've been painting eggs all day.", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "They're beautiful.", duration: 2500, delay: 700, animation: "bounce" },
    { speakerId: "$A", text: "Thanks. I can't feel my hooves.", duration: 3500, delay: 600 },
  ],
  [
    { speakerId: "$A", text: "Do we get Easter off?", duration: 3000, delay: 0 },
    { speakerId: "$B", text: "Off from what? We stand on a desktop.", duration: 4000, delay: 700 },
    { speakerId: "$A", text: "Fair point.", duration: 2000, delay: 600, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "Spring is here! I can feel it!", duration: 3500, delay: 0, animation: "bounce" },
    { speakerId: "$B", text: "You can feel the changing of seasons?", duration: 3500, delay: 700 },
    { speakerId: "$A", text: "No, I just read the calendar.", duration: 3000, delay: 600 },
  ],
];

const EASTER_GC_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "good_colleague", text: "Påskeegg er seriøs business.", duration: 3500, delay: 0 },
    { speakerId: "$OTHER", text: "What?", duration: 2000, delay: 800 },
    { speakerId: "good_colleague", text: "Nå er det påske, ja.", duration: 3000, delay: 600, animation: "headshake" },
  ],
  [
    { speakerId: "good_colleague", text: "Kvikk Lunsj og påskekrim.", duration: 3500, delay: 0 },
    { speakerId: "$OTHER", text: "Is that... a Norwegian Easter thing?", duration: 3500, delay: 800 },
    { speakerId: "good_colleague", text: "Det er tradisjon.", duration: 3000, delay: 600, animation: "bounce" },
  ],
  [
    { speakerId: "good_colleague", text: "God påske.", duration: 2500, delay: 0, animation: "bounce" },
    { speakerId: "$OTHER", text: "Happy Easter to you too!", duration: 3000, delay: 700, animation: "bounce" },
  ],
];

const EASTER_HUNT_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "I still can't believe you missed the golden egg.", duration: 4200, delay: 0 },
    { speakerId: "$B", text: "I was busy carrying the team.", duration: 3400, delay: 700, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "My basket is still full.", duration: 3200, delay: 0 },
    { speakerId: "$B", text: "That explains the smugness.", duration: 3400, delay: 700 },
  ],
  [
    { speakerId: "$A", text: "Do we get medals for that hunt?", duration: 3200, delay: 0 },
    { speakerId: "$B", text: "No. We get more eggs.", duration: 3000, delay: 700, animation: "bounce" },
  ],
];

const EASTER_PAINTING_SCRIPTS: ScriptTemplate[] = [
  [
    { speakerId: "$A", text: "Hold still. This stripe needs emotional support.", duration: 4200, delay: 0 },
    { speakerId: "$B", text: "You're talking to the egg again.", duration: 3200, delay: 700, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "I have paint on my hooves.", duration: 3200, delay: 0 },
    { speakerId: "$B", text: "That means it's working.", duration: 2800, delay: 700, animation: "bounce" },
  ],
];

// --- Resolver ---

function resolveScript(
  template: ScriptTemplate,
  idA: string,
  idB: string,
): ConversationScript {
  return template.map((line) => {
    let speakerId = line.speakerId;
    if (speakerId === "$A") speakerId = idA;
    else if (speakerId === "$B") speakerId = idB;
    else if (speakerId === "$OTHER") speakerId = idA === "good_colleague" ? idB : idA;
    else if (speakerId === "$FRIEND") speakerId = idA === "main" ? idB : idA;
    return { ...line, speakerId };
  });
}

function pickFrom(pool: ScriptTemplate[], idA: string, idB: string): ConversationScript | null {
  if (pool.length === 0) return null;
  const template = pool[Math.floor(Math.random() * pool.length)];
  return resolveScript(template, idA, idB);
}

function getPersonalityPairPool(pA: FriendPersonality, pB: FriendPersonality): ScriptTemplate[] | null {
  const key = [pA, pB].sort().join("+");
  switch (key) {
    case "snarky+wholesome": return SNARKY_WHOLESOME_SCRIPTS;
    case "chaotic+chaotic": return CHAOTIC_CHAOTIC_SCRIPTS;
    case "passive-aggressive+snarky": return PA_SNARKY_SCRIPTS;
    case "wholesome+wholesome": return WHOLESOME_WHOLESOME_SCRIPTS;
    default: return null;
  }
}

export function pickConversation(
  idA: string,
  idB: string,
  context?: ConversationContext,
): ConversationScript | null {
  // 50% chance to skip — keeps conversations sparse
  if (Math.random() < 0.5) return null;

  const hasGC = idA === "good_colleague" || idB === "good_colleague";
  const hasMain = idA === "main" || idB === "main";
  const hour = context?.hour ?? new Date().getHours();

  // Try personality-pair scripts first (30% chance when available)
  if (context?.personalityA && context?.personalityB && !hasGC && !hasMain) {
    const pairPool = getPersonalityPairPool(context.personalityA, context.personalityB);
    if (pairPool && Math.random() < 0.4) {
      return pickFrom(pairPool, idA, idB);
    }
  }

  // Try Easter scripts with stronger bias around active seasonal moments.
  if (context?.easterTheme?.active) {
    const easterChance = context.recentEasterHunt
      ? 0.8
      : context.eggPaintingActive
        ? 0.65
        : 0.25;
    if (Math.random() < easterChance) {
      if (context.recentEasterHunt) {
        return pickFrom(EASTER_HUNT_SCRIPTS, idA, idB);
      }
      if (context.eggPaintingActive) {
        return pickFrom(EASTER_PAINTING_SCRIPTS, idA, idB);
      }
      if (hasGC) {
        return pickFrom(EASTER_GC_SCRIPTS, idA, idB);
      }
      return pickFrom(EASTER_SCRIPTS, idA, idB);
    }
  }

  // Try Easter scripts (baseline seasonal chance)
  if (context?.easterTheme?.active && Math.random() < 0.25) {
    if (hasGC) {
      return pickFrom(EASTER_GC_SCRIPTS, idA, idB);
    }
    return pickFrom(EASTER_SCRIPTS, idA, idB);
  }

  // Try weather-aware scripts (25% chance when weather active)
  if (context?.weather && Math.random() < 0.25) {
    let weatherPool: ScriptTemplate[] = [];
    if (context.weather === "rain") weatherPool = RAIN_SCRIPTS;
    else if (context.weather === "snow") weatherPool = SNOW_SCRIPTS;
    else if (context.weather === "clear") weatherPool = NICE_WEATHER_SCRIPTS;
    if (weatherPool.length > 0) {
      return pickFrom(weatherPool, idA, idB);
    }
  }

  // Try time-aware scripts (20% chance when time matches)
  if (Math.random() < 0.2) {
    let timePool: ScriptTemplate[] = [];
    if (hour >= 6 && hour <= 9) timePool = MORNING_SCRIPTS;
    else if (hour >= 23 || hour <= 3) timePool = LATE_NIGHT_SCRIPTS;
    else if (hour >= 13 && hour <= 15) timePool = AFTERNOON_SCRIPTS;
    if (timePool.length > 0) {
      return pickFrom(timePool, idA, idB);
    }
  }

  // Fall back to character-specific pools
  let pool: ScriptTemplate[];
  if (hasGC && hasMain) {
    pool = MAIN_SHEEP_SCRIPTS;
  } else if (hasGC) {
    pool = GOOD_COLLEAGUE_SCRIPTS;
  } else if (hasMain) {
    pool = MAIN_SHEEP_SCRIPTS;
  } else {
    pool = GENERIC_SCRIPTS;
  }

  return pickFrom(pool, idA, idB);
}

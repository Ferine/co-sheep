import { SpeechBubble } from "./speech-bubble";
import { SheepAnimation, SheepState } from "./types";

const MESSAGES: Record<string, string[]> = {
  snarky: [
    "You've been staring at that screen for 45 minutes. Your eyes are not invincible.",
    "Break time. Even I need to rest my judgmental gaze sometimes.",
    "Your posture right now is a crime against spines everywhere. Get up.",
    "45 minutes of uninterrupted work? Suspicious. Take a break.",
    "Stand up. Stretch. Touch grass. I'll wait.",
  ],
  wholesome: [
    "Hey friend! You've been working hard for 45 minutes. Time for a little break!",
    "Your dedication is amazing! But please stretch those legs for me?",
    "Break time! Even the best sheep need to rest. You do too!",
    "You've earned a breather! Go get some water, I'll guard the screen.",
    "45 minutes of great work! Time to rest those eyes. I believe in you!",
  ],
  chaotic: [
    "45 MINUTES?! Your eyeballs are going to MELT. STAND UP. NOW.",
    "BREAK TIME BREAK TIME BREAK TIME! *air horn noises*",
    "Fun fact: sitting for 45 minutes straight increases your chance of becoming a desk. GET UP!",
    "I've been counting. 45 minutes. That's 2700 seconds of SITTING. Unacceptable!",
    "Your chair is becoming sentient from absorbing you. MOVE!",
  ],
  "passive-aggressive": [
    "Oh, 45 minutes already? No no, don't mind me. I'm sure your back is FINE.",
    "I'm not saying you SHOULD take a break, but your posture is making ME uncomfortable.",
    "Some people take breaks. But I'm sure YOU know better than centuries of health advice.",
    "45 minutes straight. How... dedicated of you. Your spine sends its regards.",
    "Oh don't worry about stretching. I'm sure rigor mortis is very fashionable.",
  ],
};

export class BreakReminder {
  private lastBoredTime = Date.now();
  private reminderShown = false;
  private enabled = true;
  private readonly WORK_THRESHOLD = 45 * 60 * 1000;
  private readonly CHECK_INTERVAL = 30_000;
  private checkAccum = 0;

  /** Set from app-switched events; names the culprit app in reminders. */
  currentApp: string | null = null;

  update(
    dt: number,
    sheepState: SheepState,
    bubble: SpeechBubble,
    personality: string,
    onAnimation?: (anim: SheepAnimation) => void,
  ) {
    if (!this.enabled) return;

    this.checkAccum += dt;
    if (this.checkAccum < this.CHECK_INTERVAL) return;
    this.checkAccum = 0;

    // Reset timer if sheep is in a "bored" state (meaning user is idle)
    const boredStates: SheepState[] = ["idle_sleep", "idle_campfire", "idle_counting"];
    if (boredStates.includes(sheepState)) {
      this.lastBoredTime = Date.now();
      this.reminderShown = false;
      return;
    }

    if (!this.reminderShown && Date.now() - this.lastBoredTime > this.WORK_THRESHOLD) {
      const pool = MESSAGES[personality] || MESSAGES["snarky"];
      let msg = pool[Math.floor(Math.random() * pool.length)];
      if (this.currentApp) {
        msg += ` (${this.currentApp}, specifically.)`;
      }
      bubble.show(msg, 10000);
      if (onAnimation) onAnimation("headshake");
      this.reminderShown = true;
    }
  }

  setEnabled(on: boolean) {
    this.enabled = on;
  }
}

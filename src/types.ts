export interface ScreenInfo {
  width: number;
  height: number;
}

export type SheepState =
  | "parachute"
  | "idle"
  | "walk"
  | "sit"
  | "sleep"
  | "fall"
  | "grabbed"
  | "petting"
  | "bounce"
  | "spin"
  | "backflip"
  | "headshake"
  | "zoom"
  | "vibrate"
  | "idle_sleep"
  | "idle_campfire"
  | "idle_counting"
  | "idle_judging"
  | "idle_hearts"
  | "idle_zooming"
  | "idle_sighing"
  | "stampede"
  | "trampoline"
  | "stacked"
  | "idle_egg_painting";

export type SheepAnimation = "bounce" | "spin" | "backflip" | "headshake" | "zoom" | "vibrate";

export const ANIMATIONS: SheepAnimation[] = ["bounce", "spin", "backflip", "headshake", "zoom", "vibrate"];

export interface CommentaryEvent {
  text: string;
  animation: SheepAnimation | null;
}

export type FriendColor = "pink" | "blue" | "green" | "gold" | "purple" | "orange";

export type FriendPersonality = "snarky" | "wholesome" | "chaotic" | "passive-aggressive";

export interface FriendConfig {
  id: string;
  name: string;
  color: FriendColor;
  personality?: FriendPersonality;
  accessories?: string[];
  scale?: number;
}

export interface ConversationLine {
  speakerId: string;  // "main", "good_colleague", or a friend id
  text: string;
  duration: number;   // ms to show
  delay: number;      // ms to wait before showing (after previous line ends)
  animation?: SheepAnimation;
}

export type ConversationScript = ConversationLine[];

export interface WindowPlatform {
  x: number;
  y: number;
  w: number;
  h: number;
}

export const FRIEND_TINTS: Record<FriendColor, string> = {
  pink: "hsla(330, 70%, 70%, 0.35)",
  blue: "hsla(210, 70%, 65%, 0.35)",
  green: "hsla(140, 60%, 55%, 0.35)",
  gold: "hsla(45, 90%, 60%, 0.35)",
  purple: "hsla(270, 60%, 65%, 0.35)",
  orange: "hsla(25, 90%, 60%, 0.35)",
};

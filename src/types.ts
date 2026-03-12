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
  | "bounce"
  | "spin"
  | "backflip"
  | "headshake"
  | "zoom"
  | "vibrate";

export type SheepAnimation = "bounce" | "spin" | "backflip" | "headshake" | "zoom" | "vibrate";

export const ANIMATIONS: SheepAnimation[] = ["bounce", "spin", "backflip", "headshake", "zoom", "vibrate"];

export interface CommentaryEvent {
  text: string;
  animation: SheepAnimation | null;
}

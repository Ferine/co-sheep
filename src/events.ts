import { SheepAnimation } from "./types";

/** Every signal that flows through the flock. Payloads are plain data. */
export interface FlockEvents {
  "sheep-petted": { id: string };
  "group-activity": { type: string; participants: string[] };
  "conversation-happened": { idA: string; idB: string; topic: string };
  "app-switched": { app: string; previousApp: string | null; previousDurationMs: number };
  "weather-changed": { condition: string | null };
  "ai-commentary": { animation: SheepAnimation | null };
  "drama-state-changed": { idA: string; idB: string; from: string; to: string; cause: string };
  "spectacle-started": { type: string };
  "spectacle-ended": { type: string };
}

export type FlockEventName = keyof FlockEvents;

class FlockBus {
  private target = new EventTarget();

  emit<K extends FlockEventName>(name: K, payload: FlockEvents[K]): void {
    this.target.dispatchEvent(new CustomEvent(name, { detail: payload }));
  }

  /** Subscribe. Handlers are isolated: one throwing cannot break the rest. */
  on<K extends FlockEventName>(
    name: K,
    handler: (payload: FlockEvents[K]) => void,
  ): () => void {
    const wrapped = (e: Event) => {
      try {
        handler((e as CustomEvent).detail as FlockEvents[K]);
      } catch (err) {
        console.error(`[co-sheep] bus handler for '${name}' failed:`, err);
      }
    };
    this.target.addEventListener(name, wrapped);
    return () => this.target.removeEventListener(name, wrapped);
  }
}

export const bus = new FlockBus();

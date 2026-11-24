// Stand-in for @tauri-apps/api/event. The legacy flock listens for events the
// Rust backend used to emit ("sheep-commentary", "sheep-session"); here the
// artifact shell emits them itself.

type Handler<T> = (event: { event: string; payload: T }) => void;

const handlers = new Map<string, Set<Handler<unknown>>>();

export async function listen<T>(event: string, handler: Handler<T>): Promise<() => void> {
  let set = handlers.get(event);
  if (!set) {
    set = new Set();
    handlers.set(event, set);
  }
  set.add(handler as Handler<unknown>);
  return () => {
    set?.delete(handler as Handler<unknown>);
  };
}

export function emit<T>(event: string, payload: T): void {
  for (const handler of handlers.get(event) ?? []) {
    try {
      handler({ event, payload });
    } catch (e) {
      console.error(`[co-sheep] listener for ${event} failed:`, e);
    }
  }
}

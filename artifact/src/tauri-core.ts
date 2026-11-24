// Stand-in for @tauri-apps/api/core: `invoke` routes the legacy flock's
// backend commands to the in-page backend.
import { handleCommand } from "./backend";

export async function invoke<T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> {
  return (await handleCommand(cmd, args)) as T;
}

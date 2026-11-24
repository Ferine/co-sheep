# co-sheep as a Claude artifact

`co-sheep.html` is the flock as a single-page Claude artifact. It bundles the
legacy TypeScript sim (the Tauri app's `src/`, taken from git history at
`8e7b2db^`) with a small shell in `src/`:

- `backend.ts` stands in for the Rust backend (settings, friends, friend
  brains, diary, opinions, living state), kept in the browser's localStorage.
- `tauri-core.ts` / `tauri-event.ts` replace `@tauri-apps/api` so the legacy
  code runs unchanged apart from the patches in `patch.py`.
- `main.ts` is the new entry: the pretend-desktop "pasture", the desktop
  overlay, menus, chat and the control panel.

Where it runs:

- **Artifact panel / browser**: a pretend desktop with the full flock.
- **Installed from the Claude desktop app** (`desktop` capability): after the
  Overlay and Menu bar permissions, the window turns frameless, transparent,
  always on top and click-through, covering the screen's work area, with a
  menu bar item. "Put the flock back in a window" undoes it.
- Chat and *Comment now* ask Claude through the `sample` capability (the
  viewer is asked once); without it the sheep uses its own lines. Timer-driven
  model calls (friend-to-friend AI chat) stay scripted.

Not ported: screen capture/OCR commentary, window platforms on the real
desktop, weather, the MCP server, the agent herd and Christmas mode (those
last two are Swift-only).

Rebuild with `./build.sh` (needs git, python3 and npm for esbuild).
Publish `co-sheep.html` with capabilities `{ desktop: {}, sample: {} }`.

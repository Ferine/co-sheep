# co-sheep

## Narrate your work through the sheep

When the `co-sheep` MCP server is connected, narrate your work through it so
your progress comes out of the desktop sheep's mouth:

- `session_begin` when you start a task
- `set_task` / `progress` as you go
- `milestone` when you finish (`done`), something breaks (`failed`), or —
  especially — when you're `blocked` or `waiting_on_you` and need the human back
  at the screen

Report plain facts (a short `detail` like "3 tests failing"); the sheep supplies
its own personality, so don't pre-format jokes. Use `say` only to force an exact
line. If the server isn't connected (the app isn't running), just work normally.

## Stack

Native Swift (macOS 27, Swift 6.4, SwiftPM, zero third-party dependencies).
The old Tauri/TypeScript/Rust app lives in git history (`main` before the
Swift merge) and is the behavioral reference for anything ported.

- Build/test: `swift build`, `swift test` (Swift Testing). Keep both clean:
  no warnings, all green.
- Run: `scripts/run.sh` (debug bundle, logs in the terminal). Use
  `CO_SHEEP_HOME=<scratch copy of ~/.co-sheep>` for experiments so the
  user's real sheep data isn't touched; `CO_SHEEP_SNAPSHOT=/x.png` renders
  the overlay without Screen Recording permission (the display must be awake:
  a locked screen renders a blank snapshot).
- Agent herd (`Herd/`, `Sim/Herd.swift`, spec
  `docs/superpowers/specs/2026-10-03-agent-herd-design.md`):
  `CO_SHEEP_HERD_DEMO=1` spawns five demo lambs; `CO_SHEEP_CLAUDE_DIR=<scratch>`
  points the hook installer away from the real `~/.claude`. Never install
  hooks into the user's real settings from a test or experiment.
- Concurrency: default MainActor isolation. Pure value types are
  `nonisolated`; heavy work (OCR, image encode, sockets) is `@concurrent`.
- Drawing goes through `Canvas` (Canvas2D-shaped). Callers wrap entities in
  `ctx.group(key, anchor:)`; anything that moves should be anchored so pure
  motion doesn't re-rasterize. Full-screen effects belong in SpriteKit nodes.
- `~/.co-sheep` JSON stays schema-compatible (serde key names); unparseable
  files are quarantined (`*.corrupt-<ts>`), never overwritten.
- Design docs: `docs/superpowers/specs/2026-09-29-swift-rewrite-design.md`,
  conventions in `docs/superpowers/plans/2026-09-29-swift-port-conventions.md`.

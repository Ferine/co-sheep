# MCP Companion — Design

**Date:** 2026-07-07
**Status:** Approved (embedded rmcp HTTP server; facts-in tools; diegetic sheep-only rendering; no HUD)

## Problem

Claude Code narrates its work to a terminal scrollback nobody watches. co-sheep
already owns a charming, snarky rendering surface (sheep + speech bubble +
flock + mood) fed by a clean one-way rail: the backend `app.emit("sheep-commentary",
CommentaryEvent { text, animation })` and `speech-bubble.ts` paints it.

Goal: let an external Claude Code session push **progress reports** onto that same
surface, so the sheep narrates what Claude is doing — in the sheep's own voice,
not Claude's — via MCP.

## Goals

- Claude Code connects to the running app as an MCP client and drives the sheep.
- Claude reports **facts** (task started, 60%, tests failed); the **sheep** decides
  the whimsy (quip + animation + mood). One consistent voice.
- A live per-session state model (task, progress, health) with a single owner.
- Rendered **diegetically** through existing sheep/bubble/flock/mood — no new window.
- Tools mutate display state only. No filesystem, shell, or exec surface, ever.
- Sheep survives all failure modes (port taken, bad args, malformed events).

## Non-goals

- A status HUD window. State model is built so a HUD *could* subscribe later; we
  don't build one now.
- A granular live tool-call ticker. Folded into semantic `milestone`s (a speech
  bubble is a poor log viewer).
- AI-generated quips in v1. Static curated pools first; on-device generation
  (via existing `apple_ai.rs`) is a later upgrade.
- Claude writing lines directly as the default. `say` is an escape hatch, not the
  main path.
- Remote / LAN access, auth beyond an optional loopback token.

## Architecture

```
Claude Code
   │ HTTP POST 127.0.0.1:4917/mcp   (JSON-RPC tool call: milestone{failed})
   ▼
┌─ Tauri backend ──────────────────────────────────────────┐
│ mcp.rs (rmcp server, async task spawned in lib.rs setup)  │
│    ├─ mutate SessionState (Mutex, app.manage)             │
│    └─ app.emit("sheep-session", SessionEvent)             │
└───────────────────────────────────────────────────────────┘
   │
   ▼  frontend listen("sheep-session")
mcp-companion.ts  ── translate fact → { quip, animation, mood, flockReaction }
   │
   ▼  reuse existing APIs
SpeechBubble  +  Sheep animation  +  Flock reactive emotes  +  mood system
```

`say` reuses the existing `sheep-commentary` rail directly. Structured beats use a
new `sheep-session` event so `CommentaryEvent`'s text+animation shape stays intact.

## Design

### 1. Server — `src-tauri/src/mcp.rs` (new)

- `rmcp` crate (official Rust MCP SDK) with the streamable-HTTP server transport,
  bound to `127.0.0.1:4917`.
- Spawned as an async task in `lib.rs` setup, alongside `vision_loop`.
- Handlers hold an `AppHandle` (to `emit`) and the managed `SessionState`.
- Bind/startup failure → `log!` under tag `mcp` and disable the feature; the app
  continues. Never panics the runtime.
- **Open item for planning:** rmcp's server API (tool macros, transport feature
  flags, axum/hyper wiring) has churned across versions — pin the exact API
  against the current published crate before writing the plan, not from memory.
- New dependency justified: `reqwest` is client-only; nothing installed hosts a
  server or speaks MCP. rmcp pulls axum/hyper transitively — its choice, no extra
  config on our side.

### 2. State — `SessionState` (backend)

Managed via `app.manage`, guarded by a `Mutex`:

```rust
struct SessionState {
    active: bool,               // is a Claude session live
    task: Option<String>,       // current task label
    progress: Option<f32>,      // 0.0..=1.0, clamped
    health: Health,             // Good | Degraded | Failing
}
enum Health { Good, Degraded, Failing }
```

`health` maps onto the existing mood vocabulary (happy / grumpy / sleepy /
excited). Single source of truth; a future HUD subscribes here with no rework.

### 3. MCP tools (facts in, not finished lines)

| tool | args | beat |
| --- | --- | --- |
| `session_begin` | `task?: string` | sheep clocks in ("oh, we're working now?") |
| `set_task` | `label: string` | announces current task (name-tag / bubble) |
| `progress` | `fraction: 0..=1` | **diegetic**: paces when low, counts / sweats near 1.0 |
| `milestone` | `kind, detail?` | the heart — see kinds below |
| `say` | `text, animation?` | escape hatch: force a specific line via `sheep-commentary` |
| `session_end` | `summary?: string` | clocks out, closing quip; `active=false` |

`milestone.kind ∈ { done, failed, blocked, waiting_on_you }`.

All string args truncated to 500 chars at the boundary (mirrors `frontend_log`).
`progress` clamped to `0.0..=1.0`. Bad args → MCP error response; sheep unaffected.

### 4. Fact → whimsy — `src/mcp-companion.ts` (new)

Translation lives frontend-side and **reuses** `drama.ts` / `personality.ts` /
the flock reactive-emote system — no parallel vocabulary. Quips come from
**static curated pools** in the existing scripted style (`drama-scripts.ts`), so
selection is deterministic and vitest-able.

Starter mapping (pools overridable):

```
milestone(failed)        → headshake + mood↓Failing + pool.failure   + flock "Hmm."
milestone(done)          → bounce + hearts + mood↑     + pool.success   + flock "WHAT"
milestone(blocked)       → walk-to-cursor + foot-tap   + pool.blocked
milestone(waiting_on_you)→ nudge / tap-foot idle       + pool.waiting
progress ≥ 0.9           → sit + count sheep + sweat drop
progress < 0.9 (rising)  → pacing walk
set_task(label)          → announce via name-tag / bubble (pool.new_task)
session_begin            → perk-up greeting (pool.clock_in)
session_end              → relax + closing quip (pool.clock_out)
```

Voice stays tsundere per the sheep's established character
("tch. predictable." / "...fine. that worked. don't read into it.").

### 5. Config & wiring

- Settings gain `mcp_enabled` (default true), `mcp_port` (default 4917),
  `mcp_token` (optional; empty = off), following existing config patterns.
- Connect once from Claude Code:
  `claude mcp add --transport http co-sheep http://127.0.0.1:4917/mcp`
  (add `--header "Authorization: Bearer <token>"` if a token is set).
- README gains an MCP section + a `.mcp.json` snippet.
- Lifecycle: server up only while the app runs. App down → Claude's connection
  fails gracefully (correct: no sheep, no narration).

### 6. Safety

- Loopback bind only (`127.0.0.1`); optional bearer token checked per request.
- Tools mutate **display state only** — no fs, no shell, no exec. Worst case for a
  local attacker is making the sheep talk. Enforced by keeping the tool set closed.
- Oversized / malformed input truncated or rejected; never crashes the app.

### 7. Verification

- **Rust unit tests:** `SessionState` transitions (begin → task → progress →
  milestone → end); `progress` clamping; arg truncation at char boundary
  (æ/ø/å); `Health` → mood mapping.
- **TS unit tests (vitest):** fact → whimsy mapping — deterministic pool
  selection asserts animation, mood, and quip pool per event kind; mirrors
  `drama.test.ts` / `gossip.test.ts`.
- **Manual integration:** `claude mcp add …`, call each tool, watch the sheep
  react; kill the app and confirm Claude reports the server unreachable without
  crashing; occupy port 4917 and confirm the app boots with MCP disabled + logged.

## Judgment calls (overridable)

- Default port `4917`.
- `milestone` kinds limited to the four beats above; more can be added later.
- String truncation 500 chars (matches `frontend_log`).
- Static quip pools over AI generation for v1 (deterministic + testable).
- New `sheep-session` event rather than overloading `sheep-commentary`.

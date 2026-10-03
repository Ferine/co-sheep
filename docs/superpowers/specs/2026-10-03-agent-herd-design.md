# Agent Herd — Design

**Date:** 2026-10-03
**Status:** Approved (fresh lambs per session; hooks + transcripts; tool props,
wool meter + shearing, shepherd commentary on the on-device model)
**Inspiration:** [pixtuoid](https://github.com/IvanWng97/pixtuoid) — agent
sessions as pixel coworkers in a terminal office. Ours is an eSheep homage, so
the desktop is the pasture and every agent session is a lamb.

## Problem

The MCP companion only knows what an agent *chooses* to narrate, and it folds
every session into the one main sheep. Run three Claude Code sessions and the
sheep can't tell you which one is stuck on a permission prompt.

## Goals

- Every running Claude Code session gets its own **lamb** on the desktop. It
  parachutes in on `SessionStart` and is sheared and trots off-screen on
  `SessionEnd`. That's the classic eSheep multiplying sheep.
- **Passive**: hooks + transcript tailing. The agent does nothing special. MCP
  narration keeps working on the main sheep as a bonus.
- Glanceable state, eSheep-style, no HUD:
  - **working**: the lamb holds the current tool's prop (knitting = edit,
    shovel = bash, book = read/search, telescope = web, megaphone = subagent,
    chewing cud = compaction, thought cloud = thinking).
  - **waiting on you** (permission prompt): bouncing `?`, vibrate, bleat bubble
    every 45 s naming the tool.
  - **idle** (turn finished): sleeps with z's.
- **Wool meter**: wool fluff grows with tokens burned (tiers 250K / 2M / 16M,
  pixtuoid's thresholds). Hover shows `Σ tokens · tool calls · age`.
- **Wool colour from the repo** (git root hash → hue), so lambs on the same
  repo read as one flock. Name tag = repo folder.
- **Click a lamb** → its terminal app comes to the front.
- **Shepherd commentary**: the main sheep comments on the herd using the
  on-device model (Apple FoundationModels), in the configured personality +
  language. Static fallback lines when the model is unavailable.
- Local-only. Hook shim always exits 0 with empty stdout, never blocks or
  steers the agent.

## Non-goals

- Agent CLIs other than Claude Code (the reducer is source-agnostic; adapters later).
- A dashboard window. The desktop is the dashboard.
- Subagent lamblets (maybe later).
- Focusing the exact terminal tab/window. We bring the terminal app forward.

## Architecture

```
claude ──hook──▶ ~/.co-sheep/hooks/claude-hook.sh  (curl -m 0.3, exit 0)
                    │ POST 127.0.0.1:4917/hook   (stdin JSON + X-Co-Sheep-Pid)
                    ▼
MCPEndpoint ── /mcp → MCPProtocol (unchanged)
            └─ /hook → HookEvent.decode → MCPAction.hook
                    ▼ main actor
HerdStore (single owner)  ◀── TranscriptTailer (@concurrent, 2 s poll, tokens + ai-title)
  │  pure HerdReducer.apply(&state, event, now) -> [HerdChange]
  │  liveness sweep 10 s: agent pid dead, or 45 min silent → ended
  ▼ AppEvents.herd (HerdChange)
Herd (Sim) — owned by Flock
  ├─ AgentLamb × ≤8: Sheep(id "lamb:<sid>", repo tint, scale 0.72) + SpeechBubble
  │    phase-driven idle override, ToolProps, WoolMeter, Shearing+exit
  └─ Shepherd: rate-limited commentary through flock.mainBubble
```

### Hook ingest

- Route `/hook` on the existing loopback HTTP server (same bearer-token +
  Host checks as `/mcp`). Accepts any JSON object, answers `204` immediately.
- `HookEvent` (nonisolated Decodable): `session_id`, `transcript_path`, `cwd`,
  `hook_event_name`, `tool_name?`, `notification_type?`, `message?`,
  `source?`, `reason?`. Unknown fields ignored. The `X-Co-Sheep-Pid` header
  ($PPID of the shim) is attached as `pid`.
- Registered events: `SessionStart`, `SessionEnd`, `UserPromptSubmit`,
  `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `PreCompact`.

### Reducer (pure)

| event | phase after | notes |
|---|---|---|
| SessionStart | idle | create; `source` resume/clear keeps existing lamb |
| UserPromptSubmit | working(thinking) | |
| PreToolUse | working(tool) | toolCalls += 1 |
| PostToolUse | working(tool) | clears waiting |
| Notification permission | waiting(tool from message) | |
| Notification idle | idle | |
| Stop | idle | `turnsDone += 1` |
| PreCompact | working(compacting) | |
| SessionEnd | ended | lamb shears + leaves |

Every event refreshes `lastEventMs` and fills in missing cwd/transcript/pid.
Events for an unknown session (app started mid-session) create it.

### Transcript tailer

Per session: read new bytes from `transcript_path` from the last offset,
split complete lines, `assistant` lines → sum `input + cache_creation +
cache_read + output` once per `message.id` (Claude Code writes one line per
content block, all carrying the same usage). `ai-title` → session title.
The first read of an existing file reads it all. A file that shrank resets.

### Process tree

`ProcessTree` (sysctl `KERN_PROC_PID`): parent pid + name. From the shim's
pid: the nearest ancestor named `claude`/`node` = agent pid (liveness); the
nearest ancestor that is a regular `NSRunningApplication` = terminal (focus).

### Installer

- Writes `~/.co-sheep/hooks/claude-hook.sh` (0700) with port + optional token.
- Merges one matcher group per event into `~/.claude/settings.json`
  (`CO_SHEEP_CLAUDE_DIR` overrides the dir for dev/tests). Idempotent:
  groups whose command is our shim are replaced, nothing else is touched.
  Backup `settings.json.co-sheep-backup-<ts>` before every write. Unparseable
  settings → refuse, never overwrite.
- Uninstall removes only our groups (and empty event arrays / empty `hooks`).
- Status: `.notInstalled | .installed | .stale(reason)` (shim missing, port
  mismatch). Menu: "Connect Claude Code" / "Disconnect Claude Code", with a
  confirmation alert before touching another tool's config.

### Lambs

- `Sheep` gains two seams, no behaviour change for existing sheep:
  `idleOverride: (() -> (SheepState, Double)?)?`, consulted first in
  `transitionFromIdle`; and a `.leaving` state (walk toward `exitDirection`,
  no edge clamp; `hasLeft` once fully off-screen).
- The lamb maps phase → next idle state: working → `.sit` with prop (short
  walks between), waiting → `.idle` + vibrate bursts, idle → `.sleep`.
  Phase changes interrupt calm states immediately.
- Lambs join drag / stack / trampoline / stampede / window platforms, but
  not friend systems (conversations, gossip, spectacles, memories, drama).
- Cap 8 visible. Overflow sessions are tracked and the shepherd mentions them.

### Shepherd

Triggers (one line per ≥ 3 min, skipped while the main bubble is busy or a
chat is open): lamb arrives, lamb waiting ≥ 2 min (once per wait), lamb
finished after ≥ 20 min, periodic herd review every 12 min with ≥ 2 lambs.
Prompt = personality + language + a compact herd table. One sentence,
≤ 20 words, no markdown. Falls back to static pools.

### Config (serde names)

`herd_enabled` (true), `herd_max_lambs` (8), `shepherd_commentary` (true).

## Testing

Pure reducer, transcript parsing (dedupe by message.id, partial lines,
truncation), installer merge/uninstall/idempotence/refusal on temp dirs,
`/hook` routing + auth, lamb phase → state mapping on a headless flock,
shepherd prompt builder + rate limiter, process tree on the test process.

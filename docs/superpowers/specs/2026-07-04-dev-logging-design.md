# Dev Console Logging — Design

**Date:** 2026-07-04
**Status:** Approved (approach A: hand-rolled module, Rust + frontend forwarding, no new deps)

## Problem

`pnpm tauri dev` output is hard to use: ~100 bare `eprintln!` sites with no
timestamps and no subsystem tags, so concurrent loops (vision, reflection,
cursor, app-watch) interleave indistinguishably. One vision tick emits ~15
lines including full raw model dumps; the prerequisite retry loop repeats 5
identical lines every 30s; "Capturing screen..." is logged twice per capture
(vision.rs and capture.rs). Meanwhile the frontend's ~40
`console.log/warn/error` sites (drama, spectacles, gossip) go to the
invisible webview console — a frontend crash shows nothing in the terminal.

## Goals

- Every terminal line: `HH:MM:SS [tag     ] message` (fixed-width tag).
- One vision tick ≤ 4 lines at normal verbosity; full detail behind a flag.
- Frontend console + uncaught errors visible in the terminal during dev.
- Zero new dependencies (chrono already present).

## Non-goals

- Log files, colors, log rotation, `log`/`tracing` crates, tauri-plugin-log.
- Changing what the app does — logging only.

## Design

### 1. `logging.rs` (new module, ~30 lines)

- `pub static DEBUG: LazyLock<bool>` — reads `CO_SHEEP_DEBUG` env var once
  (`"1"` or `"true"` = on).
- `log!(tag, fmt, args...)` macro → `eprintln!("{} [{:<7}] {}", chrono::Local::now().format("%H:%M:%S"), tag, format!(...))`.
- `debug!(tag, fmt, args...)` — same output, only when `*DEBUG`.
- `pub fn truncate_for_log(s: &str, max_bytes: usize) -> Cow<str>` — char-boundary-safe,
  appends `…` when cut. Unit-tested (æ/ø/å boundaries).

### 2. Migration of all `eprintln!` sites

Tags by module: `vision`, `reflect`, `capture`, `cursor`, `weather`,
`memory`, `app` (lib.rs setup/commands), `tray` (menu events), `watch`
(app_watch), `state` (living_state), `web` (frontend forwarding).

Noise policy applied during migration:

| Current | New |
| --- | --- |
| Vision tick: ~15 lines | `tick: capturing` → `classified: <summary> (interesting\|boring)` → `💬 "<text>" [<animation>]` (+ opinion/count line only when present) |
| Capture dims / JPEG bytes / base64 chars / OCR chars | `debug!` |
| Duplicate "Capturing screen..." in capture.rs | `debug!` (vision.rs keeps the tick line) |
| Full raw model responses (vision, chat, friend chat) | `truncate_for_log(raw, 200)` at `log!`; full at `debug!` |
| Prerequisite retry loop (5 lines / 30s) | Log full detail on first failure and on failure-reason *change*; unchanged retries are `debug!`. Log success once. |
| "CGPreflight says no permission" during routine captures | `debug!` (known macOS false-negative; real failures still surface via the capture error) |
| Drag state START/END per mousedown | `debug!` |
| Reflection / backfill / chat lines | Keep at `log!` (already high-signal), timestamp+tag only |
| Errors (pipeline failures, parse failures, permission errors) | Always `log!`, message prefixed `error:` |

### 3. Frontend forwarding

- New Tauri command `frontend_log(level: String, message: String)` → logs
  under tag `web`, message truncated to 500 chars, `warn`/`error` levels
  prefixed (`warn:` / `error:`).
- In `main.ts`, dev-only (`import.meta.env.DEV`): wrap `console.log`,
  `console.warn`, `console.error` to tee a stringified single-line copy to
  `invoke("frontend_log", ...)` with `.catch(() => {})` (logging must never
  throw). Original console behavior preserved.
- `window.onerror` and `unhandledrejection` handlers forward as `error`.
- Packaged builds: wrapper not installed (DEV gate); command exists but idle.

### 4. Verification

- Unit tests: `truncate_for_log` (short passthrough, multibyte boundary, ellipsis).
- Manual dev-run checklist: timestamps + aligned tags on all lines; one tick
  ≤ 4 lines; no retry spam while a failure persists; a `console.log` from
  the webview appears under `[web]`; `CO_SHEEP_DEBUG=1` restores full detail.

## Judgment calls (overridable)

- Tag width 7 chars, left-aligned.
- Raw-response truncation 200 bytes (Rust), frontend messages 500 chars.
- `%H:%M:%S` timestamps — dates are noise for an interactive dev session.

# Dev Console Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `pnpm tauri dev` terminal output timestamped, tagged, low-noise, and inclusive of frontend console logs — with full detail behind `CO_SHEEP_DEBUG=1`.

**Architecture:** A tiny hand-rolled `logging.rs` (two macros + truncation helper, no new deps) replaces all ~100 bare `eprintln!` sites, applying the spec's noise policy during migration. A `frontend_log` Tauri command plus a dev-only console wrapper in `main.ts` tees webview logs and uncaught errors to the same stream. Spec: `docs/superpowers/specs/2026-07-04-dev-logging-design.md`.

**Tech Stack:** Rust (Tauri 2, chrono already present), TypeScript frontend. Tests via `cargo test` and `pnpm tsc --noEmit && pnpm vitest run`.

## Global Constraints

- No new Cargo or npm dependencies.
- Line format exactly: `HH:MM:SS [tag    ] message` — `chrono::Local` time `%H:%M:%S`, tag left-aligned width 7.
- Tags by module: `vision`, `reflect`, `capture`, `cursor`, `weather`, `memory`, `app` (lib.rs), `tray` (menu events), `watch` (app_watch), `state` (living_state), `web` (frontend).
- `debug!` lines print only when env `CO_SHEEP_DEBUG` is `1` or `true` (checked once).
- Raw model responses: truncated to **200 bytes** at normal verbosity, full at debug. Frontend messages truncated to **500** chars.
- After migration: **zero** `eprintln!` outside `src-tauri/src/logging.rs` (the macros' own bodies).
- Logging changes only — no behavior changes. Exception explicitly allowed by spec: `check_prerequisites` may change return type to carry the failure reason, provided its `app.emit` side effects and the 30s retry cadence are preserved.
- One vision tick at normal verbosity ≤ 4 lines (plus opinion/count lines only when present).
- Commit style: short imperative subject, ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `logging.rs` module

**Files:**
- Create: `src-tauri/src/logging.rs`
- Modify: `src-tauri/src/lib.rs:1` (module registration — must be the FIRST `mod` declaration)

**Interfaces:**
- Produces (all later tasks depend on these):
  - `log!(tag, fmt, args...)` and `debug!(tag, fmt, args...)` — bare-callable from any module (via `#[macro_use]`)
  - `pub static DEBUG: LazyLock<bool>` in `crate::logging`
  - `pub fn truncate_for_log(s: &str, max_bytes: usize) -> Cow<'_, str>`
  - `pub fn raw_for_log(s: &str) -> Cow<'_, str>` — full string at debug, 200-byte truncation otherwise

- [ ] **Step 1: Write the failing tests**

Create `src-tauri/src/logging.rs` containing only the test module for now:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_strings_pass_through_borrowed() {
        let s = "bæææ";
        assert!(matches!(truncate_for_log(s, 200), std::borrow::Cow::Borrowed(_)));
        assert_eq!(truncate_for_log(s, 200), "bæææ");
    }

    #[test]
    fn truncation_respects_char_boundaries_and_appends_ellipsis() {
        // 'æ' is 2 bytes; cutting at byte 5 would split the third 'æ'
        let s = "bæææ tenker"; // b(1) æ(2) æ(2) æ(2)...
        let t = truncate_for_log(s, 4);
        assert_eq!(t.as_ref(), "bæ…");
    }

    #[test]
    fn exact_fit_is_not_truncated() {
        let s = "abcd";
        assert_eq!(truncate_for_log(s, 4).as_ref(), "abcd");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd src-tauri && cargo test --lib logging`
Expected: FAIL to compile — `truncate_for_log` not found (module not yet registered is also acceptable; register it in this step if needed to surface the intended error).

- [ ] **Step 3: Implement the module and register it**

Fill `src-tauri/src/logging.rs` above the tests:

```rust
//! Timestamped, tagged dev logging. `log!` always prints; `debug!` only
//! when CO_SHEEP_DEBUG=1|true. Both write to stderr like the bare
//! eprintln!s they replace.

use std::borrow::Cow;
use std::sync::LazyLock;

pub static DEBUG: LazyLock<bool> = LazyLock::new(|| {
    matches!(
        std::env::var("CO_SHEEP_DEBUG").as_deref(),
        Ok("1") | Ok("true")
    )
});

macro_rules! log {
    ($tag:expr, $($arg:tt)*) => {
        eprintln!(
            "{} [{:<7}] {}",
            chrono::Local::now().format("%H:%M:%S"),
            $tag,
            format!($($arg)*)
        )
    };
}

macro_rules! debug {
    ($tag:expr, $($arg:tt)*) => {
        if *$crate::logging::DEBUG {
            log!($tag, $($arg)*);
        }
    };
}

/// Char-boundary-safe head truncation with ellipsis — logs are full of æ/ø/å.
pub fn truncate_for_log(s: &str, max_bytes: usize) -> Cow<'_, str> {
    if s.len() <= max_bytes {
        return Cow::Borrowed(s);
    }
    let mut end = max_bytes;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    Cow::Owned(format!("{}…", &s[..end]))
}

/// Raw model output for a log line: full at debug verbosity, else 200 bytes.
pub fn raw_for_log(s: &str) -> Cow<'_, str> {
    if *DEBUG {
        Cow::Borrowed(s)
    } else {
        truncate_for_log(s, 200)
    }
}
```

In `src-tauri/src/lib.rs`, add as the FIRST module declaration (before `mod app_watch;`) so the textual macro scope covers every other module:

```rust
#[macro_use]
mod logging;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd src-tauri && cargo test --lib logging`
Expected: PASS (3 tests). `cargo build` warns about unused macros/fns — fine until Task 2.

- [ ] **Step 5: Commit**

```bash
git add src-tauri/src/logging.rs src-tauri/src/lib.rs
git commit -m "Add timestamped tagged logging module with debug gating

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Vision pipeline and capture noise policy

**Files:**
- Modify: `src-tauri/src/vision.rs` (all 30 `eprintln!` sites)
- Modify: `src-tauri/src/capture.rs` (all 7 `eprintln!` sites)

**Interfaces:**
- Consumes: `log!`, `debug!`, `crate::logging::raw_for_log` from Task 1.
- Produces: `check_prerequisites(app: &tauri::AppHandle) -> Result<(), String>` (was `-> bool`; Err carries a short failure reason). Only `vision_loop` calls it — no other task depends on it.

- [ ] **Step 1: Migrate capture.rs (tag `capture`)**

All capture chatter demotes to `debug!` except the explicit user action:
- Lines 7, 9, 12, 16 (capture dims), 36 (JPEG bytes), 45 (base64 chars): `eprintln!("[co-sheep] X", ...)` → `debug!("capture", "X", ...)` with the `[co-sheep] ` prefix stripped, e.g. `debug!("capture", "captured {}x{} image, resizing...", w, h);`
- Line 64 (debug screenshot saved — user-triggered): → `log!("capture", "debug screenshot saved to: {}", path_str);`

- [ ] **Step 2: Restructure the prerequisite retry flow in vision.rs**

Change `check_prerequisites` to return `Result<(), String>`:
- Apple Intelligence unavailable → `Err(format!("apple intelligence: {}", reason))`; its internal status lines (`"Apple Intelligence is available"`, `"... unavailable: {}"`) become `debug!("vision", ...)`; the `app.emit` calls stay exactly as they are.
- `"CGPreflight says no permission — requesting dialog"` → `debug!`.
- Test capture failed → `Err(format!("capture: {}", msg))`; panicked → `Err(format!("capture task panicked: {}", e))`. Their eprintln!s become `debug!`. Emits stay.
- Success → `Ok(())`; `"Test capture succeeded — vision pipeline ready"` → `debug!`.

Replace `vision_loop`'s two-phase check (lines 29-40) with a single loop that logs failure reasons only on change:

```rust
    log!("vision", "loop started, waiting 8s for UI...");
    tokio::time::sleep(std::time::Duration::from_secs(8)).await;

    let mut last_failure: Option<String> = None;
    loop {
        match check_prerequisites(&app).await {
            Ok(()) => break,
            Err(reason) => {
                if last_failure.as_deref() != Some(reason.as_str()) {
                    log!("vision", "prerequisites not met: {} (retrying every 30s)", reason);
                    last_failure = Some(reason);
                } else {
                    debug!("vision", "retry: still {}", reason);
                }
                tokio::time::sleep(std::time::Duration::from_secs(30)).await;
            }
        }
    }
    log!("vision", "prerequisites met — entering main vision loop");
```

(First check runs immediately, retries every 30s, emits fire per attempt — cadence and side effects unchanged.)

- [ ] **Step 3: Consolidate the pipeline tick**

In `run_vision_pipeline` and the loop around it:
- Line 49 pipeline error → `log!("vision", "error: pipeline: {}", msg);`
- Line 73 next-check delay → `debug!("vision", "next check in {}s (base: {}s)", delay, base);`
- Line 150 `--- Vision pipeline tick ---` → `log!("vision", "tick: capturing");`
- Line 154 preflight warning → `debug!`
- Line 158 `Capturing screen...` → DELETE (capture.rs's debug line covers it)
- Lines 164/166 OCR → `debug!("vision", "OCR-ing screen...");` / `debug!("vision", "OCR: {} chars", screen_text.len());`
- Line 169 pass 1 → `debug!`
- Classification result (line 171) → `log!("vision", "classified: {} ({})", classification.summary, if classification.interesting { "interesting" } else { "boring" });`
- Line 177 not-interesting notice → `debug!` (the classified line already says "boring")
- Line 187 pass 2 → `debug!`
- Line 195 raw response → `log!("vision", "raw: {}", crate::logging::raw_for_log(&raw_response));`
- Line 199 parsed → replace with the speech line plus conditional opinion/count lines:

```rust
    log!(
        "vision",
        "💬 \"{}\" [{}]",
        parsed.event.text,
        parsed.event.animation.as_deref().unwrap_or("-")
    );
    if let (Some(topic), Some(_)) = (&parsed.opinion_topic, &parsed.opinion) {
        log!("vision", "opinion: [{}]", topic);
    }
```

- Line 216 counter → `log!("vision", "count: {} = {} today", key, n);`
- Line 224 emitted → `debug!`
- Lines 286/299 parse salvage/fallback → `log!("vision", "salvaged text from truncated JSON");` / `log!("vision", "error: unparseable response, using raw text");`
- Line 426 chat raw → `log!("vision", "chat raw: {}", crate::logging::raw_for_log(&raw_response));`
- Line 502 friend chat raw → `log!("vision", "friend chat raw: {}", crate::logging::raw_for_log(&raw));`
- Any remaining vision.rs `eprintln!` → `log!("vision", ...)` with prefix stripped.

- [ ] **Step 4: Verify build and tick shape**

Run: `cd src-tauri && cargo test && cargo build`
Expected: all tests pass, clean build. `grep -c "eprintln!" src/vision.rs src/capture.rs` (from src-tauri/) → `0` for both.
Normal-verbosity tick is now: `tick: capturing` → `classified: …` → `raw: …` → `💬 …` = 4 lines.

- [ ] **Step 5: Commit**

```bash
git add src-tauri/src/vision.rs src-tauri/src/capture.rs
git commit -m "Apply logging noise policy to vision pipeline and capture

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Mechanical migration of remaining Rust modules

**Files:**
- Modify: `src-tauri/src/lib.rs` (47 sites), `src-tauri/src/reflect.rs` (7), `src-tauri/src/cursor.rs` (3), `src-tauri/src/weather.rs` (2), `src-tauri/src/memory.rs` (2), `src-tauri/src/app_watch.rs` (1), `src-tauri/src/living_state.rs` (1)

**Interfaces:**
- Consumes: `log!`, `debug!` from Task 1. No new interfaces produced.

- [ ] **Step 1: Apply the transformation rules**

For every `eprintln!("[co-sheep] MESSAGE", args...)`:
1. Strip the `[co-sheep] ` prefix.
2. Replace with `log!(TAG, "MESSAGE", args...)` where TAG is: lib.rs → `"app"`, EXCEPT lines whose message starts with `Tray menu event` or `App menu event` → `"tray"`; reflect.rs → `"reflect"`; cursor.rs → `"cursor"`; weather.rs → `"weather"`; memory.rs → `"memory"`; app_watch.rs → `"watch"`; living_state.rs → `"state"`.
3. Demotions to `debug!` (spec noise table):
   - lib.rs `Drag state: {}` (line ~577) — fires on every mousedown/mouseup.
   - cursor.rs per-event lines EXCEPT startup/shutdown lines (`"Cursor tracking loop started..."`, `"Cursor tracking active"` stay `log!`).
4. Failure lines (message contains `failed`, `error`, or `panicked`) stay `log!` and gain an `error: ` prefix if not already descriptive of an error, e.g. `log!("app", "error: failed to open friends: {}", e);`

- [ ] **Step 2: Verify zero stray eprintln and green tests**

Run from repo root:
```bash
grep -rn "eprintln!" src-tauri/src --include="*.rs" | grep -v "logging.rs"
```
Expected: no output.
Run: `cd src-tauri && cargo test && cargo build`
Expected: all pass, clean build.

- [ ] **Step 3: Commit**

```bash
git add src-tauri/src
git commit -m "Migrate remaining backend logging to tagged timestamped macros

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Frontend console forwarding

**Files:**
- Modify: `src-tauri/src/lib.rs` (new command + registration in `generate_handler![...]`)
- Modify: `src/main.ts` (dev-only wrapper after the import block, before other top-level code)
- Create: `src/vite-env.d.ts` (the project lacks Vite client types; without this, `import.meta.env` fails `tsc --noEmit`)

**Interfaces:**
- Consumes: `log!`, `crate::logging::truncate_for_log` from Task 1.
- Produces: Tauri command `frontend_log(level: String, message: String)` (frontend invokes with `{ level, message }`).

- [ ] **Step 1: Add the command in lib.rs**

```rust
/// Dev console forwarding — the webview's console.log/warn/error land here.
#[tauri::command]
fn frontend_log(level: String, message: String) {
    let msg = logging::truncate_for_log(&message, 500);
    match level.as_str() {
        "warn" => log!("web", "warn: {}", msg),
        "error" => log!("web", "error: {}", msg),
        _ => log!("web", "{}", msg),
    }
}
```

Add `frontend_log,` to the `tauri::generate_handler![...]` list.

- [ ] **Step 2: Create `src/vite-env.d.ts`**

```typescript
/// <reference types="vite/client" />
```

- [ ] **Step 3: Add the dev-only wrapper in main.ts**

Insert after the import block (before the `let flock: Flock;` declarations):

```typescript
// Dev only: tee console + uncaught errors to the terminal via the backend.
// Fire-and-forget — logging must never break the app.
if (import.meta.env.DEV) {
  const forward = (level: string, args: unknown[]) => {
    try {
      const message = args
        .map((a) => (typeof a === "string" ? a : JSON.stringify(a) ?? String(a)))
        .join(" ")
        .slice(0, 500);
      invoke("frontend_log", { level, message }).catch(() => {});
    } catch {
      // stringify can throw on cycles — drop the log line, never the app
    }
  };
  for (const level of ["log", "warn", "error"] as const) {
    const original = console[level].bind(console);
    console[level] = (...args: unknown[]) => {
      original(...args);
      forward(level, args);
    };
  }
  window.addEventListener("error", (e) =>
    forward("error", [`uncaught: ${e.message} (${e.filename}:${e.lineno})`]),
  );
  window.addEventListener("unhandledrejection", (e) =>
    forward("error", [`unhandled rejection: ${String(e.reason)}`]),
  );
}
```

- [ ] **Step 4: Verify**

Run: `cd src-tauri && cargo build` → clean.
Run from repo root: `pnpm tsc --noEmit && pnpm vitest run`
Expected: clean typecheck, all frontend tests pass.

- [ ] **Step 5: Commit**

```bash
git add src-tauri/src/lib.rs src/main.ts src/vite-env.d.ts
git commit -m "Forward frontend console and uncaught errors to dev terminal

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Live verification (controller-run)

No code. Run `pnpm tauri dev` with output captured; kill the process from the shell when done (do not rely on the tray).

- [ ] **Step 1: Normal verbosity checklist**

Expected in the log:
- Every `[co-sheep]`-era line now reads `HH:MM:SS [tag    ] message` with aligned tags.
- One vision tick ≤ 4 lines (`tick: capturing` / `classified: …` / `raw: …` (truncated, ends with `…` if long) / `💬 …`).
- No capture dims / JPEG / base64 / OCR-char lines.
- If prerequisites fail (sandboxed shell): ONE `prerequisites not met: …` line, then silence on identical retries.
- A frontend line under `[web    ]` (e.g. gossip/drama init logs from main.ts).

- [ ] **Step 2: Debug verbosity spot-check**

Run with `CO_SHEEP_DEBUG=1`. Expected: capture/OCR/raw-full detail lines return.

- [ ] **Step 3: Kill the app from the shell, record results**

`pkill -f "co-sheep" ` (dev binary) or kill the pnpm process group. Note observations for the final report.

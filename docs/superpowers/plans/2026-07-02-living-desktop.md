# Living Desktop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make co-sheep entertaining as a living system: emergent sheep drama, rare spectacle events, and live reactions to the user's frontmost app — all connected through a flock event bus.

**Architecture:** A typed pub/sub bus (`src/events.ts`) carries signals from existing systems plus a new Rust frontmost-app poller. Three consumers: a simulation-driven drama engine (pure logic in `src/drama.ts`, glue in `src/drama-manager.ts`), a spectacle scheduler + scene runner (`src/spectacles.ts`, `src/spectacle-render.ts`), and an app-aware gossip system (`src/gossip.ts`). Pure logic is vitest-tested; visual behavior is verified via a new Debug menu.

**Tech Stack:** TypeScript (Vite webview, canvas), Rust (Tauri v2), vitest (new dev dep), raw CoreGraphics FFI (existing pattern in `src-tauri/src/windows.rs`).

**Spec:** `docs/superpowers/specs/2026-07-02-living-desktop-design.md`

## Global Constraints

- pnpm only, never npm/yarn. Dev deps: `pnpm add -D <pkg>` (exact versions via `savePrefix: ""`).
- Run commands from repo root `/Users/x/dev/co-sheep` unless stated. Rust checks: `cargo check` run in `src-tauri/`.
- No new mandatory AI calls — AI usage only behind existing availability patterns (30% chance, cooldowns, catch-and-fallback).
- No window titles, only app names (no Accessibility permission).
- No new npm runtime dependencies. Only new dev dependency: vitest.
- Frontend private-state mutation of Sheep uses the established `(sheep as any).state = ...` pattern (see `src/group-activities.ts:241-248`) — do not refactor Sheep.
- Event names on the bus are kebab-case; the Tauri event from Rust is `"app-switched"`.
- All new bus subscribers must not throw uncaught — the bus wraps handlers in try/catch (Task 1); rely on it, don't add extra wrapping.
- Commit after each task with the message given in the task's final step. Every commit message ends with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

## Existing interfaces you will touch (reference)

- `Flock` (`src/flock.ts`): `main: Sheep`, `mainBubble: SpeechBubble`, private `friends: Map<string, FriendEntry>` where `FriendEntry = { sheep, bubble, quips, nextQuipTime, personality, pendingReaction? }`. Private `getSheepById(id)` returns `{ sheep, bubble, personality? } | null`. Private `isCalm(state)` = idle|sit|walk. Private `activeConversation = { lines, currentIndex, timer, participants } | null`.
- `SpeechBubble` (`src/speech-bubble.ts`): `show(text: string, durationMs: number)`, `visible: boolean`, `destroy()`.
- `Sheep` (`src/sheep.ts`): public `id, name, x, y, state, displaySize, walkTarget: number | null, facingRight: boolean, personality, screenWidth, screenHeight`; methods `playAnimation(anim)`, `resetActivity()`.
- `ConversationScript` (`src/types.ts`): `Array<{ speakerId, text, duration, delay, animation? }>`.
- Tauri commands (Rust `src-tauri/src/lib.rs`): `get_all_relationships` → `{ [id]: { name, mood, relationships: { [otherId]: number }, stats } }`, `get_friend_moods` → `{ [id]: mood }`, `record_friend_conversation(idA, idB, topic)`, `record_group_activity(participants, activityType)`, `friend_ai_chat(friendAName, friendAPersonality, friendBName, friendBPersonality)`.
- Rust module pattern: modules declared at top of `lib.rs`, commands registered in `tauri::generate_handler![...]`, background loops spawned in `.setup()` via `tauri::async_runtime::spawn`.
- `DISPLAY_SIZE = 96` (both `flock.ts` and `group-activities.ts` define it locally).

---

### Task 1: Test infra + flock event bus

**Files:**
- Create: `src/events.ts`
- Create: `src/events.test.ts`
- Modify: `package.json` (add `test` script; vitest dev dep via pnpm)

**Interfaces:**
- Consumes: nothing.
- Produces: `bus` singleton with `emit<K>(name: K, payload: FlockEvents[K]): void` and `on<K>(name: K, handler: (payload: FlockEvents[K]) => void): () => void` (returns unsubscribe). Event map `FlockEvents` (see code). Later tasks import `{ bus }` from `./events`.

- [ ] **Step 1: Install vitest and add test script**

```bash
pnpm add -D vitest
```

Then in `package.json` `scripts`, add:

```json
"test": "vitest run"
```

- [ ] **Step 2: Write the failing test**

Create `src/events.test.ts`:

```ts
import { describe, it, expect, vi } from "vitest";
import { bus } from "./events";

describe("flock event bus", () => {
  it("delivers payload to subscriber", () => {
    const seen: string[] = [];
    const off = bus.on("sheep-petted", (p) => seen.push(p.id));
    bus.emit("sheep-petted", { id: "good_colleague" });
    off();
    expect(seen).toEqual(["good_colleague"]);
  });

  it("unsubscribe stops delivery", () => {
    const handler = vi.fn();
    const off = bus.on("sheep-petted", handler);
    off();
    bus.emit("sheep-petted", { id: "main" });
    expect(handler).not.toHaveBeenCalled();
  });

  it("a throwing handler does not break other handlers", () => {
    const seen: string[] = [];
    const offA = bus.on("app-switched", () => {
      throw new Error("boom");
    });
    const offB = bus.on("app-switched", (p) => seen.push(p.app));
    bus.emit("app-switched", { app: "Xcode", previousApp: null, previousDurationMs: 0 });
    offA();
    offB();
    expect(seen).toEqual(["Xcode"]);
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pnpm test`
Expected: FAIL — cannot resolve `./events`.

- [ ] **Step 4: Write the implementation**

Create `src/events.ts`:

```ts
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
```

(`EventTarget`/`CustomEvent` are native in both the webview and Node 22, so vitest needs no DOM shim.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `pnpm test`
Expected: PASS (3 tests).

- [ ] **Step 6: Verify the app still typechecks/builds**

Run: `pnpm build`
Expected: clean `tsc` + vite build.

- [ ] **Step 7: Commit**

```bash
git add package.json pnpm-lock.yaml src/events.ts src/events.test.ts
git commit -m "Add flock event bus and vitest test infra"
```

---

### Task 2: Rust — generic living-state persistence + spectacle recorder

**Files:**
- Create: `src-tauri/src/living_state.rs`
- Modify: `src-tauri/src/lib.rs` (module decl, 3 new commands, handler registration)

**Interfaces:**
- Consumes: `memory::append_journal`, `friend_memory::record_group_activity` (both exist).
- Produces: Tauri commands `get_living_state(name: String) -> serde_json::Value` (returns `null` JSON when absent), `save_living_state(name: String, value: serde_json::Value)`, `record_spectacle(kind: String, participants: Vec<String>)`. Frontend calls: `invoke("get_living_state", { name: "drama" })`, `invoke("save_living_state", { name: "drama", value })`, `invoke("record_spectacle", { kind, participants })`. State files live at `~/.co-sheep/<name>.json`; allowed names match `^[a-z0-9_-]+$`.

- [ ] **Step 1: Write the module**

Create `src-tauri/src/living_state.rs`:

```rust
use serde_json::Value;
use std::fs;
use std::path::PathBuf;

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

fn state_path(name: &str) -> PathBuf {
    let home = dirs::home_dir().expect("No home directory");
    home.join(".co-sheep").join(format!("{}.json", name))
}

/// Load a named JSON state blob. Returns Value::Null if missing/invalid.
pub fn load_state(name: &str) -> Value {
    if !valid_name(name) {
        return Value::Null;
    }
    let path = state_path(name);
    if !path.exists() {
        return Value::Null;
    }
    fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null)
}

/// Persist a named JSON state blob to ~/.co-sheep/<name>.json.
pub fn save_state(name: &str, value: &Value) {
    if !valid_name(name) {
        eprintln!("[co-sheep] living_state: rejected name '{}'", name);
        return;
    }
    let path = state_path(name);
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).ok();
    }
    let json = serde_json::to_string_pretty(value).unwrap_or_default();
    fs::write(path, json).ok();
}
```

- [ ] **Step 2: Wire commands into lib.rs**

In `src-tauri/src/lib.rs`, add `mod living_state;` to the module list at the top (alphabetical, after `mod friend_memory;`). Then add these commands next to `record_group_activity` (~line 466):

```rust
#[tauri::command]
fn get_living_state(name: String) -> serde_json::Value {
    living_state::load_state(&name)
}

#[tauri::command]
fn save_living_state(name: String, value: serde_json::Value) {
    living_state::save_state(&name, &value);
}

/// Record a spectacle's aftermath: friend memories + affinity boost + diary entry.
#[tauri::command]
fn record_spectacle(kind: String, participants: Vec<String>) {
    friend_memory::record_group_activity(&participants, &kind);
    memory::append_journal(&format!(
        "*A {} happened on the desktop! The flock is still talking about it.*",
        kind
    ))
    .ok();
}
```

Register all three in `tauri::generate_handler![...]` (append after `open_friend_memory_window`):

```rust
            get_living_state,
            save_living_state,
            record_spectacle,
```

- [ ] **Step 3: Verify it compiles**

Run: `cd src-tauri && cargo check`
Expected: clean (warnings about unused code are acceptable only if pre-existing; new code must be referenced).

- [ ] **Step 4: Commit**

```bash
git add src-tauri/src/living_state.rs src-tauri/src/lib.rs
git commit -m "Add living-state persistence and spectacle recorder commands"
```

---

### Task 3: Rust — frontmost-app watcher

**Files:**
- Create: `src-tauri/src/app_watch.rs`
- Modify: `src-tauri/src/lib.rs` (module decl, spawn loop in setup, one command)

**Interfaces:**
- Consumes: CoreGraphics `CGWindowListCopyWindowInfo` (same FFI pattern as `src-tauri/src/windows.rs`), `memory::increment_today`.
- Produces: Tauri event `"app-switched"` emitted to the webview with payload `{ "app": String, "previousApp": String | null, "previousDurationMs": u64 }`, at most once per app change, polled every 5 s. Also command `record_app_usage(category: String) -> u32` returning the new daily count (stored in `opinions.json` `today_counts` under key `app:<category>`, which automatically feeds the AI's "Today's tallies" context).

- [ ] **Step 1: Write the module**

Create `src-tauri/src/app_watch.rs`:

```rust
use tauri::Emitter;

/// Name of the frontmost app, via the front-to-back CGWindowList:
/// the first on-screen layer-0 window not owned by us belongs to the
/// frontmost app. App *names* need no extra permission (window titles would).
#[cfg(target_os = "macos")]
fn frontmost_app_name(own_pid: u32) -> Option<String> {
    use std::ffi::{c_void, CString};
    use std::ptr;

    const K_CG_WINDOW_LIST_OPTION_ON_SCREEN_ONLY: u32 = 1 << 0;
    const K_CG_WINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS: u32 = 1 << 4;
    const K_CG_NULL_WINDOW_ID: u32 = 0;
    const K_CF_NUMBER_SINT32_TYPE: u32 = 3;
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) -> *const c_void;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFArrayGetCount(arr: *const c_void) -> isize;
        fn CFArrayGetValueAtIndex(arr: *const c_void, idx: isize) -> *const c_void;
        fn CFDictionaryGetValue(dict: *const c_void, key: *const c_void) -> *const c_void;
        fn CFRelease(cf: *const c_void);
        fn CFNumberGetValue(num: *const c_void, ty: u32, out: *mut c_void) -> bool;
        fn CFStringCreateWithCString(
            alloc: *const c_void,
            c_str: *const i8,
            encoding: u32,
        ) -> *const c_void;
        fn CFStringGetCString(s: *const c_void, buf: *mut i8, size: isize, encoding: u32) -> bool;
    }

    unsafe fn make_cfstring(s: &str) -> *const c_void {
        let c = CString::new(s).unwrap();
        CFStringCreateWithCString(ptr::null(), c.as_ptr(), K_CF_STRING_ENCODING_UTF8)
    }

    unsafe fn cfstring_to_string(cf: *const c_void) -> Option<String> {
        if cf.is_null() {
            return None;
        }
        let mut buf = [0i8; 256];
        if !CFStringGetCString(cf, buf.as_mut_ptr(), buf.len() as isize, K_CF_STRING_ENCODING_UTF8)
        {
            return None;
        }
        let cstr = std::ffi::CStr::from_ptr(buf.as_ptr());
        cstr.to_str().ok().map(|s| s.to_string())
    }

    unsafe {
        let info = CGWindowListCopyWindowInfo(
            K_CG_WINDOW_LIST_OPTION_ON_SCREEN_ONLY | K_CG_WINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS,
            K_CG_NULL_WINDOW_ID,
        );
        if info.is_null() {
            return None;
        }

        let key_layer = make_cfstring("kCGWindowLayer");
        let key_pid = make_cfstring("kCGWindowOwnerPID");
        let key_owner = make_cfstring("kCGWindowOwnerName");
        let mut result = None;

        let count = CFArrayGetCount(info);
        for i in 0..count {
            let dict = CFArrayGetValueAtIndex(info, i);
            if dict.is_null() {
                continue;
            }

            let layer_ref = CFDictionaryGetValue(dict, key_layer);
            if layer_ref.is_null() {
                continue;
            }
            let mut layer: i32 = -1;
            CFNumberGetValue(layer_ref, K_CF_NUMBER_SINT32_TYPE, &mut layer as *mut _ as *mut c_void);
            if layer != 0 {
                continue;
            }

            let pid_ref = CFDictionaryGetValue(dict, key_pid);
            if !pid_ref.is_null() {
                let mut pid: i32 = 0;
                CFNumberGetValue(pid_ref, K_CF_NUMBER_SINT32_TYPE, &mut pid as *mut _ as *mut c_void);
                if pid as u32 == own_pid {
                    continue;
                }
            }

            result = cfstring_to_string(CFDictionaryGetValue(dict, key_owner));
            break; // first qualifying window is frontmost
        }

        CFRelease(info);
        CFRelease(key_layer);
        CFRelease(key_pid);
        CFRelease(key_owner);
        result
    }
}

#[cfg(not(target_os = "macos"))]
fn frontmost_app_name(_own_pid: u32) -> Option<String> {
    None
}

/// Poll the frontmost app every 5s; emit "app-switched" on change.
pub async fn app_watch_loop(app: tauri::AppHandle) {
    let own_pid = std::process::id();
    let mut current: Option<String> = None;
    let mut since = std::time::Instant::now();

    loop {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;

        let front = match tokio::task::spawn_blocking(move || frontmost_app_name(own_pid)).await {
            Ok(Some(name)) => name,
            _ => continue,
        };

        if current.as_deref() != Some(front.as_str()) {
            let previous_duration_ms = since.elapsed().as_millis() as u64;
            let payload = serde_json::json!({
                "app": front,
                "previousApp": current,
                "previousDurationMs": if current.is_some() { previous_duration_ms } else { 0 },
            });
            app.emit("app-switched", payload).ok();
            eprintln!("[co-sheep] App switched to: {}", front);
            current = Some(front);
            since = std::time::Instant::now();
        }
    }
}
```

- [ ] **Step 2: Wire into lib.rs**

In `src-tauri/src/lib.rs`:

1. Add `mod app_watch;` at the top of the module list (alphabetical, before `mod apple_ai;`).
2. Add the tally command next to `record_interaction` (~line 76):

```rust
/// Bump the daily usage tally for an app category (feeds AI "Today's tallies").
#[tauri::command]
fn record_app_usage(category: String) -> u32 {
    memory::increment_today(&format!("app:{}", category))
}
```

3. Register `record_app_usage,` in `generate_handler![...]`.
4. In `.setup()`, immediately after the vision loop spawn block (after `vision::vision_loop(vision_handle).await;` closes, ~line 894), add:

```rust
            // Spawn frontmost-app watcher (feeds gossip & live reactions)
            eprintln!("[co-sheep] Spawning app watch loop");
            let app_watch_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                app_watch::app_watch_loop(app_watch_handle).await;
            });
```

- [ ] **Step 3: Verify it compiles**

Run: `cd src-tauri && cargo check`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add src-tauri/src/app_watch.rs src-tauri/src/lib.rs
git commit -m "Add frontmost-app watcher emitting app-switched events"
```

---

### Task 4: Drama engine (pure logic) + tests

**Files:**
- Create: `src/drama.ts`
- Create: `src/drama.test.ts`

**Interfaces:**
- Consumes: nothing (pure module).
- Produces (used by Task 7's manager and Task 9's spectacles):
  - `type RelationshipState = "neutral" | "warm" | "inseparable" | "tension" | "feud" | "reconciling"`
  - `pairKey(a: string, b: string): string` — sorted, `"a|b"`.
  - `interface PairInput { idA: string; idB: string; affinity: number; moodA: string; moodB: string; state: RelationshipState; msInState: number; pettingGap: number; spark: number }`
  - `interface DramaTransition { idA: string; idB: string; from: RelationshipState; to: RelationshipState; cause: string }`
  - `evaluatePair(p: PairInput): DramaTransition | null`
  - `evaluateDrama(pairs: PairInput[]): DramaTransition[]`
  - `blocksGroupActivity(state: RelationshipState): boolean` — true only for `"feud"`.
  - `DRAMA` tuning constants object (exact values below).

- [ ] **Step 1: Write the failing tests**

Create `src/drama.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import {
  DRAMA,
  PairInput,
  evaluatePair,
  evaluateDrama,
  pairKey,
  blocksGroupActivity,
} from "./drama";

function pair(overrides: Partial<PairInput>): PairInput {
  return {
    idA: "friend_a",
    idB: "friend_b",
    affinity: 0,
    moodA: "happy",
    moodB: "happy",
    state: "neutral",
    msInState: DRAMA.MIN_DWELL_MS + 1,
    pettingGap: 0,
    spark: 0.99, // never fires random spark unless a test lowers it
    ...overrides,
  };
}

describe("pairKey", () => {
  it("is order-independent", () => {
    expect(pairKey("b", "a")).toBe("a|b");
    expect(pairKey("a", "b")).toBe("a|b");
  });
});

describe("evaluatePair transitions", () => {
  it("neutral -> warm on high affinity", () => {
    const t = evaluatePair(pair({ affinity: DRAMA.WARM_ENTER }));
    expect(t).toMatchObject({ from: "neutral", to: "warm" });
  });

  it("neutral -> tension on low affinity", () => {
    const t = evaluatePair(pair({ affinity: DRAMA.TENSION_ENTER }));
    expect(t).toMatchObject({ from: "neutral", to: "tension" });
  });

  it("neutral -> tension on jealousy (petting gap)", () => {
    const t = evaluatePair(pair({ affinity: 2, pettingGap: DRAMA.JEALOUSY_GAP }));
    expect(t).toMatchObject({ from: "neutral", to: "tension", cause: "jealousy" });
  });

  it("respects minimum dwell time (no flapping)", () => {
    const t = evaluatePair(pair({ affinity: DRAMA.WARM_ENTER, msInState: 1000 }));
    expect(t).toBeNull();
  });

  it("warm -> inseparable needs affinity AND long dwell", () => {
    const notYet = evaluatePair(
      pair({ state: "warm", affinity: DRAMA.INSEP_ENTER, msInState: DRAMA.MIN_DWELL_MS + 1 }),
    );
    expect(notYet).toBeNull();
    const now = evaluatePair(
      pair({ state: "warm", affinity: DRAMA.INSEP_ENTER, msInState: DRAMA.INSEP_DWELL_MS + 1 }),
    );
    expect(now).toMatchObject({ from: "warm", to: "inseparable" });
  });

  it("warm -> neutral below exit threshold (hysteresis)", () => {
    const stays = evaluatePair(pair({ state: "warm", affinity: DRAMA.WARM_EXIT }));
    expect(stays).toBeNull();
    const cools = evaluatePair(pair({ state: "warm", affinity: DRAMA.WARM_EXIT - 1 }));
    expect(cools).toMatchObject({ from: "warm", to: "neutral" });
  });

  it("tension -> feud when a grump holds a grudge long enough", () => {
    const t = evaluatePair(
      pair({ state: "tension", affinity: -4, moodA: "grumpy", msInState: DRAMA.FEUD_DWELL_MS + 1 }),
    );
    expect(t).toMatchObject({ from: "tension", to: "feud" });
  });

  it("tension -> feud on random spark", () => {
    const t = evaluatePair(pair({ state: "tension", affinity: -4, spark: 0 }));
    expect(t).toMatchObject({ from: "tension", to: "feud", cause: "spark" });
  });

  it("tension -> neutral when cooled off", () => {
    const t = evaluatePair(pair({ state: "tension", affinity: DRAMA.TENSION_EXIT }));
    expect(t).toMatchObject({ from: "tension", to: "neutral" });
  });

  it("feud -> reconciling after tiring out", () => {
    const t = evaluatePair(
      pair({ state: "feud", affinity: -5, msInState: DRAMA.FEUD_TIREOUT_MS + 1 }),
    );
    expect(t).toMatchObject({ from: "feud", to: "reconciling" });
  });

  it("reconciling -> warm quickly", () => {
    const t = evaluatePair(
      pair({ state: "reconciling", affinity: 0, msInState: DRAMA.RECONCILE_MS + 1 }),
    );
    expect(t).toMatchObject({ from: "reconciling", to: "warm" });
  });
});

describe("evaluateDrama", () => {
  it("returns only pairs that transition", () => {
    const out = evaluateDrama([
      pair({ affinity: DRAMA.WARM_ENTER }),
      pair({ idA: "x", idB: "y", affinity: 0 }),
    ]);
    expect(out).toHaveLength(1);
    expect(out[0].to).toBe("warm");
  });
});

describe("blocksGroupActivity", () => {
  it("only feud blocks", () => {
    expect(blocksGroupActivity("feud")).toBe(true);
    expect(blocksGroupActivity("tension")).toBe(false);
    expect(blocksGroupActivity("warm")).toBe(false);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — cannot resolve `./drama`.

- [ ] **Step 3: Write the implementation**

Create `src/drama.ts`:

```ts
/**
 * Simulation-driven relationship drama. Pure logic: state in, transitions out.
 * The AI never owns this state — it only narrates what these rules decide.
 *
 * State graph:  neutral <-> warm -> inseparable
 *               neutral <-> tension -> feud -> reconciling -> warm
 */

export type RelationshipState =
  | "neutral"
  | "warm"
  | "inseparable"
  | "tension"
  | "feud"
  | "reconciling";

export interface PairInput {
  idA: string;
  idB: string;
  /** Symmetric affinity: average of both directions' scores. */
  affinity: number;
  moodA: string;
  moodB: string;
  state: RelationshipState;
  msInState: number;
  /** |petsA - petsB| today — fuel for jealousy. */
  pettingGap: number;
  /** Random [0,1) injected by the caller so tests are deterministic. */
  spark: number;
}

export interface DramaTransition {
  idA: string;
  idB: string;
  from: RelationshipState;
  to: RelationshipState;
  cause: string;
}

/** Tuning constants — thresholds are hysteresis pairs (enter > exit). */
export const DRAMA = {
  WARM_ENTER: 8,
  WARM_EXIT: 5,
  INSEP_ENTER: 15,
  INSEP_EXIT: 10,
  INSEP_DWELL_MS: 24 * 3600 * 1000,
  TENSION_ENTER: -3,
  TENSION_EXIT: 1,
  JEALOUSY_GAP: 5,
  FEUD_DWELL_MS: 12 * 3600 * 1000,
  FEUD_SPARK: 0.005,
  FEUD_TIREOUT_MS: 48 * 3600 * 1000,
  RECONCILE_MS: 10 * 60 * 1000,
  /** No pair may transition twice within this window (anti-flap). */
  MIN_DWELL_MS: 30 * 60 * 1000,
} as const;

export function pairKey(a: string, b: string): string {
  return a < b ? `${a}|${b}` : `${b}|${a}`;
}

export function blocksGroupActivity(state: RelationshipState): boolean {
  return state === "feud";
}

export function evaluatePair(p: PairInput): DramaTransition | null {
  if (p.msInState < DRAMA.MIN_DWELL_MS) return null;

  const t = (to: RelationshipState, cause: string): DramaTransition => ({
    idA: p.idA,
    idB: p.idB,
    from: p.state,
    to,
    cause,
  });

  switch (p.state) {
    case "neutral":
      if (p.pettingGap >= DRAMA.JEALOUSY_GAP) return t("tension", "jealousy");
      if (p.affinity >= DRAMA.WARM_ENTER) return t("warm", "growing affinity");
      if (p.affinity <= DRAMA.TENSION_ENTER) return t("tension", "low affinity");
      return null;

    case "warm":
      if (p.affinity < DRAMA.WARM_EXIT) return t("neutral", "drifted apart");
      if (p.affinity >= DRAMA.INSEP_ENTER && p.msInState >= DRAMA.INSEP_DWELL_MS)
        return t("inseparable", "best friends now");
      return null;

    case "inseparable":
      if (p.affinity < DRAMA.INSEP_EXIT) return t("warm", "cooled slightly");
      return null;

    case "tension":
      if (p.affinity >= DRAMA.TENSION_EXIT && p.pettingGap < DRAMA.JEALOUSY_GAP)
        return t("neutral", "cooled off");
      if (p.spark < DRAMA.FEUD_SPARK) return t("feud", "spark");
      if (
        p.msInState >= DRAMA.FEUD_DWELL_MS &&
        (p.moodA === "grumpy" || p.moodB === "grumpy")
      )
        return t("feud", "grudge");
      return null;

    case "feud":
      if (p.msInState >= DRAMA.FEUD_TIREOUT_MS) return t("reconciling", "tired of fighting");
      return null;

    case "reconciling":
      if (p.msInState >= DRAMA.RECONCILE_MS) return t("warm", "made up");
      return null;
  }
}

export function evaluateDrama(pairs: PairInput[]): DramaTransition[] {
  const out: DramaTransition[] = [];
  for (const p of pairs) {
    const t = evaluatePair(p);
    if (t) out.push(t);
  }
  return out;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm test`
Expected: PASS (all files).

- [ ] **Step 5: Commit**

```bash
git add src/drama.ts src/drama.test.ts
git commit -m "Add pure drama engine with hysteresis state machine"
```

---

### Task 5: Drama conversation scripts

**Files:**
- Create: `src/drama-scripts.ts`

**Interfaces:**
- Consumes: `ConversationScript` from `./types`.
- Produces: `pickDramaScript(kind: DramaScriptKind, idA: string, idB: string, mediatorId?: string): ConversationScript` where `type DramaScriptKind = "feud_start" | "feud_snipe" | "jealousy" | "mediation" | "reconciliation" | "inseparable"`. Placeholders `$A`/`$B`/`$M` resolve to `idA`/`idB`/`mediatorId`.

- [ ] **Step 1: Write the module**

Create `src/drama-scripts.ts`:

```ts
import { ConversationScript } from "./types";

export type DramaScriptKind =
  | "feud_start"
  | "feud_snipe"
  | "jealousy"
  | "mediation"
  | "reconciliation"
  | "inseparable";

// $A/$B are the pair; $M is the mediator (mediation scripts only).
const SCRIPTS: Record<DramaScriptKind, ConversationScript[]> = {
  feud_start: [
    [
      { speakerId: "$A", text: "You know what? No. I'm done.", duration: 3500, delay: 0, animation: "headshake" },
      { speakerId: "$B", text: "DONE? *I'M* done!", duration: 3000, delay: 600, animation: "vibrate" },
      { speakerId: "$A", text: "Fine!", duration: 2000, delay: 500 },
      { speakerId: "$B", text: "FINE!", duration: 2000, delay: 400 },
    ],
    [
      { speakerId: "$A", text: "I saw what you did at the campfire.", duration: 3500, delay: 0 },
      { speakerId: "$B", text: "Oh, we're doing THIS now?", duration: 3000, delay: 700, animation: "headshake" },
      { speakerId: "$A", text: "We are ABSOLUTELY doing this now.", duration: 3500, delay: 600, animation: "vibrate" },
    ],
  ],
  feud_snipe: [
    [
      { speakerId: "$A", text: "*pointedly grazes elsewhere*", duration: 3000, delay: 0 },
      { speakerId: "$B", text: "The grass is better over here anyway.", duration: 3500, delay: 700, animation: "headshake" },
    ],
    [
      { speakerId: "$A", text: "Some sheep have no shame.", duration: 3000, delay: 0 },
      { speakerId: "$B", text: "Some sheep should mind their own wool.", duration: 3500, delay: 700 },
    ],
    [
      { speakerId: "$A", text: "Hmph.", duration: 2000, delay: 0, animation: "headshake" },
      { speakerId: "$B", text: "Hmph indeed.", duration: 2000, delay: 500, animation: "headshake" },
    ],
  ],
  jealousy: [
    [
      { speakerId: "$A", text: "Getting petted a lot lately, huh.", duration: 3500, delay: 0 },
      { speakerId: "$B", text: "...is that a problem?", duration: 3000, delay: 700 },
      { speakerId: "$A", text: "No. It's FINE.", duration: 2500, delay: 500, animation: "vibrate" },
    ],
    [
      { speakerId: "$A", text: "Teacher's pet.", duration: 2500, delay: 0, animation: "headshake" },
      { speakerId: "$B", text: "You're just jealous of my fluff.", duration: 3500, delay: 700, animation: "bounce" },
    ],
  ],
  mediation: [
    [
      { speakerId: "$M", text: "Okay. Both of you. Here. Now.", duration: 3500, delay: 0 },
      { speakerId: "$A", text: "Only if THEY apologize.", duration: 3000, delay: 700 },
      { speakerId: "$B", text: "ME?!", duration: 2000, delay: 400, animation: "vibrate" },
      { speakerId: "$M", text: "*long, tired sheep sigh*", duration: 3000, delay: 600 },
    ],
    [
      { speakerId: "$M", text: "This feud is exhausting the whole flock.", duration: 4000, delay: 0 },
      { speakerId: "$A", text: "...they started it.", duration: 2500, delay: 700 },
      { speakerId: "$M", text: "I don't care. Hug it out. Metaphorically.", duration: 4000, delay: 600, animation: "headshake" },
    ],
  ],
  reconciliation: [
    [
      { speakerId: "$A", text: "Look... I said things.", duration: 3000, delay: 0 },
      { speakerId: "$B", text: "We both said things.", duration: 3000, delay: 700 },
      { speakerId: "$A", text: "Your wool looked fine that day.", duration: 3500, delay: 600 },
      { speakerId: "$B", text: "...thanks. Yours too.", duration: 3000, delay: 500, animation: "bounce" },
    ],
  ],
  inseparable: [
    [
      { speakerId: "$A", text: "Best flockmate?", duration: 2500, delay: 0 },
      { speakerId: "$B", text: "Best flockmate.", duration: 2500, delay: 500, animation: "bounce" },
    ],
    [
      { speakerId: "$A", text: "We should synchronize our grazing.", duration: 3500, delay: 0 },
      { speakerId: "$B", text: "Way ahead of you.", duration: 2500, delay: 600, animation: "bounce" },
    ],
  ],
};

export function pickDramaScript(
  kind: DramaScriptKind,
  idA: string,
  idB: string,
  mediatorId?: string,
): ConversationScript {
  const pool = SCRIPTS[kind];
  const template = pool[Math.floor(Math.random() * pool.length)];
  return template.map((line) => ({
    ...line,
    speakerId:
      line.speakerId === "$A" ? idA :
      line.speakerId === "$B" ? idB :
      line.speakerId === "$M" ? (mediatorId ?? idA) :
      line.speakerId,
  }));
}
```

- [ ] **Step 2: Verify build**

Run: `pnpm build`
Expected: clean. (`drama-scripts.ts` is not imported yet — `noUnusedLocals` applies to locals, not modules, so this passes.)

- [ ] **Step 3: Commit**

```bash
git add src/drama-scripts.ts
git commit -m "Add drama conversation script packs"
```

---

### Task 6: Flock public API for drama & spectacles

**Files:**
- Modify: `src/flock.ts`

**Interfaces:**
- Consumes: existing private members of `Flock`.
- Produces (all on `Flock`, used by Tasks 7 and 9):
  - `getCharacterIds(): string[]` — `"main"` + all friend ids (includes `good_colleague`).
  - `getCharacter(id: string): { sheep: Sheep; bubble: SpeechBubble; personality?: string } | null` — public wrapper over private `getSheepById`.
  - `isCharacterCalm(id: string): boolean`.
  - `startScriptedConversation(script: ConversationScript, participants: string[]): boolean` — returns false (and does nothing) if a conversation or group activity is already active or any participant is busy; otherwise plays the script through the existing conversation machinery.
  - `participantFilter: ((ids: string[]) => string[]) | null` — hook consulted before starting a group activity; drama manager installs a filter that drops feuding co-participants.
  - Bus emits added to existing code paths: `conversation-happened`, `group-activity`, `ai-commentary`, `weather-changed`.

- [ ] **Step 1: Add imports and public members**

In `src/flock.ts` add to the imports:

```ts
import { bus } from "./events";
```

Inside the `Flock` class, next to `onBreakReminderFired`, add:

```ts
  /** Installed by DramaManager: filters group-activity participant lists (drops feuders). */
  participantFilter: ((ids: string[]) => string[]) | null = null;
```

Add these public methods after `getQuip(...)`:

```ts
  /** All character ids: "main" + every friend (incl. good_colleague). */
  getCharacterIds(): string[] {
    return ["main", ...this.friends.keys()];
  }

  /** Public lookup for other systems (drama, spectacles, gossip). */
  getCharacter(id: string): { sheep: Sheep; bubble: SpeechBubble; personality?: string } | null {
    return this.getSheepById(id);
  }

  isCharacterCalm(id: string): boolean {
    const c = this.getSheepById(id);
    return c ? this.isCalm(c.sheep.state) : false;
  }

  /**
   * Play a prepared script through the normal conversation machinery.
   * Refuses (returns false) if the stage is already busy.
   */
  startScriptedConversation(script: ConversationScript, participants: string[]): boolean {
    if (this.activeConversation || this.groupActivity || script.length === 0) return false;
    for (const id of participants) {
      const c = this.getSheepById(id);
      if (!c || !this.isCalm(c.sheep.state) || c.bubble.visible) return false;
    }
    this.activeConversation = {
      lines: script,
      currentIndex: 0,
      timer: 0,
      participants: new Set(participants),
    };
    return true;
  }
```

- [ ] **Step 2: Emit bus events from existing paths**

Four small edits in `src/flock.ts`:

1. **Conversation finished** — in `updateConversations`, inside the `if (pIds.length === 2)` block right after the `invoke("record_friend_conversation", ...)` call, add:

```ts
            bus.emit("conversation-happened", { idA: pIds[0], idB: pIds[1], topic });
```

2. **Group activity completed** — in `clearGroupActivity`, inside the `if (!cancelledEarly)` block right after the `invoke("record_group_activity", ...)` call, add:

```ts
      bus.emit("group-activity", {
        type: this.groupActivity.type,
        participants: this.groupActivity.participants,
      });
```

3. **AI commentary** — in the constructor's `this.mainBubble.onAnimation = (anim) => { ... }` handler, after `this.triggerFriendReactions("commentary");`, add:

```ts
      bus.emit("ai-commentary", { animation: anim });
```

4. **Weather change** — in `setWeatherCondition`, inside the `if (c && c !== prev)` block after `this.triggerFriendReactions("weather");`, add:

```ts
      bus.emit("weather-changed", { condition: c });
```

- [ ] **Step 3: Apply the participant filter to group activities**

In `updateGroupActivityLoop`, replace:

```ts
    const participants = canStartGroupActivity(sheepList);
    if (!participants) return;
```

with:

```ts
    let participants = canStartGroupActivity(sheepList);
    if (!participants) return;
    if (this.participantFilter) {
      participants = this.participantFilter(participants);
      if (participants.length < 3) return; // feud thinned the group below viability
    }
```

- [ ] **Step 4: Verify build and tests**

Run: `pnpm test && pnpm build`
Expected: both clean.

- [ ] **Step 5: Commit**

```bash
git add src/flock.ts
git commit -m "Expose Flock character API, script hook, and bus emits"
```

---

### Task 7: Drama manager — wiring the simulation to the flock

**Files:**
- Create: `src/drama-manager.ts`
- Modify: `src/main.ts` (instantiate; emit `sheep-petted`)
- Modify: `src-tauri/src/lib.rs` (optional `topic` on `friend_ai_chat`)
- Modify: `src-tauri/src/vision.rs` (thread topic into the prompt)

**Interfaces:**
- Consumes: `bus` (Task 1), `drama.ts` (Task 4), `drama-scripts.ts` (Task 5), Flock API (Task 6), commands `get_all_relationships`, `get_friend_moods`, `get_living_state`/`save_living_state` (Task 2), `friend_ai_chat`.
- Produces: `class DramaManager` with:
  - `constructor(flock: Flock)`
  - `start(): Promise<void>` — loads persisted state, subscribes to bus, installs `flock.participantFilter`, starts a 60 s tick.
  - `forceFeud(): string | null` — debug hook (Task 11): forces the first non-feud friend pair into feud, returns its pair key.
  - `getPairStates(): Record<string, { state: RelationshipState; sinceMs: number }>`
  - `resolveShowdown(pair: [string, string], reconciled: boolean): void` — called by the showdown scene (Task 9).
  - `onDramaTriggeredSpectacle: ((kind: "showdown" | "feast", pair: [string, string]) => void) | null` — set by Task 9.
  - Emits `drama-state-changed` on the bus; persists to `~/.co-sheep/drama.json` via `save_living_state`.

- [ ] **Step 1: Extend friend_ai_chat with an optional topic**

In `src-tauri/src/vision.rs`, change `friend_chat` (line ~370) to take a topic:

```rust
pub async fn friend_chat(
    friend_a_name: &str,
    friend_a_personality: &str,
    friend_b_name: &str,
    friend_b_personality: &str,
    topic: Option<&str>,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
```

Replace the existing `let user_msg = format!(...)` line with:

```rust
    let user_msg = match topic {
        Some(t) => format!(
            "Generate a conversation between {} and {}. Context: {}",
            friend_a_name, friend_b_name, t
        ),
        None => format!(
            "Generate a conversation between {} and {}.",
            friend_a_name, friend_b_name
        ),
    };
```

In `src-tauri/src/lib.rs`, update the `friend_ai_chat` command (~line 503):

```rust
#[tauri::command]
async fn friend_ai_chat(
    friend_a_name: String,
    friend_a_personality: String,
    friend_b_name: String,
    friend_b_personality: String,
    topic: Option<String>,
) -> Result<String, String> {
    eprintln!("[co-sheep] Friend AI chat: {} ({}) <-> {} ({})", friend_a_name, friend_a_personality, friend_b_name, friend_b_personality);
    vision::friend_chat(&friend_a_name, &friend_a_personality, &friend_b_name, &friend_b_personality, topic.as_deref())
        .await
        .map_err(|e| e.to_string())
}
```

The existing caller in `src/flock.ts` (`startAIConversation`) passes no `topic`; a missing optional arg deserializes as `None`, so it keeps working unchanged.

Run: `cd src-tauri && cargo check` — expected clean.

- [ ] **Step 2: Write the drama manager**

Create `src/drama-manager.ts`:

```ts
import { invoke } from "@tauri-apps/api/core";
import { Flock } from "./flock";
import { bus } from "./events";
import {
  DramaTransition,
  PairInput,
  RelationshipState,
  blocksGroupActivity,
  evaluateDrama,
  pairKey,
} from "./drama";
import { DramaScriptKind, pickDramaScript } from "./drama-scripts";
import { ConversationScript, SheepAnimation } from "./types";

const TICK_MS = 60_000;
const DISPLAY_SIZE = 96;
const SNIPE_CHANCE = 0.10;        // per tick, per feuding pair
const MEDIATION_CHANCE = 0.05;    // per tick, per feuding pair
const MEDIATION_SUCCESS = 0.6;
const SHOWDOWN_MS = 24 * 3600 * 1000;
const SHOWDOWN_CHANCE = 0.10;
const AI_NARRATION_CHANCE = 0.3;
const AI_NARRATION_COOLDOWN_MS = 10 * 60 * 1000;
const LOG_CAP = 50;

interface PairRecord {
  state: RelationshipState;
  since: number; // epoch ms of last transition
}

interface DramaFile {
  pairs: Record<string, PairRecord>;
  pettingToday: Record<string, number>;
  pettingDate: string;
  log: Array<{ at: string; text: string }>;
}

type RelationshipsSnapshot = Record<
  string,
  { name: string; relationships: Record<string, number> }
>;

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

export class DramaManager {
  private state: DramaFile = { pairs: {}, pettingToday: {}, pettingDate: today(), log: [] };
  private aiNarrationCooldownUntil = 0;
  onDramaTriggeredSpectacle:
    | ((kind: "showdown" | "feast", pair: [string, string]) => void)
    | null = null;

  constructor(private flock: Flock) {}

  async start(): Promise<void> {
    try {
      const saved = await invoke<DramaFile | null>("get_living_state", { name: "drama" });
      if (saved && saved.pairs) this.state = saved;
    } catch (e) {
      console.log("[co-sheep] No saved drama state:", e);
    }
    this.resetPettingIfNewDay();

    bus.on("sheep-petted", ({ id }) => {
      this.resetPettingIfNewDay();
      this.state.pettingToday[id] = (this.state.pettingToday[id] ?? 0) + 1;
    });

    // Feuders refuse shared group activities.
    this.flock.participantFilter = (ids) => this.filterFeuders(ids);

    setInterval(() => {
      this.tick().catch((e) => console.error("[co-sheep] drama tick failed:", e));
    }, TICK_MS);
  }

  getPairStates(): Record<string, { state: RelationshipState; sinceMs: number }> {
    const out: Record<string, { state: RelationshipState; sinceMs: number }> = {};
    const now = Date.now();
    for (const [key, rec] of Object.entries(this.state.pairs)) {
      out[key] = { state: rec.state, sinceMs: now - rec.since };
    }
    return out;
  }

  /** Debug hook: force the first non-feud friend pair into a feud. */
  forceFeud(): string | null {
    const ids = this.flock.getCharacterIds().filter((id) => id !== "main");
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) {
        const key = pairKey(ids[i], ids[j]);
        const rec = this.state.pairs[key];
        if (!rec || rec.state !== "feud") {
          this.applyTransition({
            idA: ids[i] < ids[j] ? ids[i] : ids[j],
            idB: ids[i] < ids[j] ? ids[j] : ids[i],
            from: rec?.state ?? "neutral",
            to: "feud",
            cause: "debug",
          });
          return key;
        }
      }
    }
    return null;
  }

  /** Called by the showdown scene (Task 9) with its outcome. */
  resolveShowdown(pair: [string, string], reconciled: boolean): void {
    const key = pairKey(pair[0], pair[1]);
    const rec = this.state.pairs[key];
    if (!rec || rec.state !== "feud") return;
    if (reconciled) {
      this.applyTransition({
        idA: pair[0], idB: pair[1],
        from: "feud", to: "reconciling", cause: "showdown",
      });
    } else {
      this.state.log.push({
        at: new Date().toISOString(),
        text: `${pair[0]} & ${pair[1]}: showdown ended in a stalemate`,
      });
      this.persist();
    }
  }

  private resetPettingIfNewDay(): void {
    if (this.state.pettingDate !== today()) {
      this.state.pettingToday = {};
      this.state.pettingDate = today();
    }
  }

  private filterFeuders(ids: string[]): string[] {
    const result = [...ids];
    for (let i = 0; i < result.length; i++) {
      for (let j = result.length - 1; j > i; j--) {
        const rec = this.state.pairs[pairKey(result[i], result[j])];
        if (rec && blocksGroupActivity(rec.state)) result.splice(j, 1);
      }
    }
    return result;
  }

  private async tick(): Promise<void> {
    const ids = this.flock.getCharacterIds();
    if (ids.length < 2) return;
    this.resetPettingIfNewDay();

    let rels: RelationshipsSnapshot;
    let moods: Record<string, string>;
    try {
      rels = await invoke<RelationshipsSnapshot>("get_all_relationships");
      moods = await invoke<Record<string, string>>("get_friend_moods");
    } catch (e) {
      console.error("[co-sheep] drama: failed to fetch relationship data:", e);
      return;
    }

    const now = Date.now();
    const inputs: PairInput[] = [];
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) {
        const [a, b] = ids[i] < ids[j] ? [ids[i], ids[j]] : [ids[j], ids[i]];
        const key = pairKey(a, b);
        let rec = this.state.pairs[key];
        if (!rec) {
          rec = { state: "neutral", since: now };
          this.state.pairs[key] = rec;
        }
        // Symmetric affinity: average whichever directions exist
        // ("main" has no brain, so main-pairs use the friend's view only).
        const ab = rels[a]?.relationships?.[b];
        const ba = rels[b]?.relationships?.[a];
        const vals = [ab, ba].filter((v): v is number => typeof v === "number");
        const affinity = vals.length ? vals.reduce((s, v) => s + v, 0) / vals.length : 0;
        const gap = Math.abs(
          (this.state.pettingToday[a] ?? 0) - (this.state.pettingToday[b] ?? 0),
        );
        inputs.push({
          idA: a, idB: b,
          affinity,
          moodA: moods[a] ?? "happy",
          moodB: moods[b] ?? "happy",
          state: rec.state,
          msInState: now - rec.since,
          pettingGap: gap,
          spark: Math.random(),
        });
      }
    }

    for (const t of evaluateDrama(inputs)) {
      this.applyTransition(t);
    }
    this.runOngoingBehaviors(now, rels);
    this.persist();
  }

  private applyTransition(t: DramaTransition): void {
    const key = pairKey(t.idA, t.idB);
    this.state.pairs[key] = { state: t.to, since: Date.now() };
    this.state.log.push({
      at: new Date().toISOString(),
      text: `${t.idA} & ${t.idB}: ${t.from} -> ${t.to} (${t.cause})`,
    });
    if (this.state.log.length > LOG_CAP) {
      this.state.log.splice(0, this.state.log.length - LOG_CAP);
    }
    bus.emit("drama-state-changed", {
      idA: t.idA, idB: t.idB, from: t.from, to: t.to, cause: t.cause,
    });
    console.log(`[co-sheep] DRAMA: ${t.idA} & ${t.idB} ${t.from} -> ${t.to} (${t.cause})`);

    // Visible beat for the transition.
    if (t.to === "feud") {
      this.playScript(t.cause === "jealousy" ? "jealousy" : "feud_start", t.idA, t.idB);
    } else if (t.to === "warm" && t.from === "reconciling") {
      this.playScript("reconciliation", t.idA, t.idB);
    } else if (t.to === "inseparable") {
      this.playScript("inseparable", t.idA, t.idB);
    } else if (t.to === "reconciling" && this.onDramaTriggeredSpectacle) {
      this.onDramaTriggeredSpectacle("feast", [t.idA, t.idB]);
    }

    this.maybeNarrate(t);
    this.persist();
  }

  /** 30% chance of an on-device AI beat about the transition (fire-and-forget). */
  private maybeNarrate(t: DramaTransition): void {
    if (Math.random() >= AI_NARRATION_CHANCE) return;
    if (Date.now() < this.aiNarrationCooldownUntil) return;
    if (t.idA === "main" || t.idB === "main") return; // needs two friend personalities
    const a = this.flock.getCharacter(t.idA);
    const b = this.flock.getCharacter(t.idB);
    if (!a?.personality || !b?.personality) return;
    this.aiNarrationCooldownUntil = Date.now() + AI_NARRATION_COOLDOWN_MS;

    invoke<string>("friend_ai_chat", {
      friendAName: a.sheep.name,
      friendAPersonality: a.personality,
      friendBName: b.sheep.name,
      friendBPersonality: b.personality,
      topic: `their relationship just changed from ${t.from} to ${t.to} because of ${t.cause}`,
    }).then((raw) => {
      try {
        const cleaned = raw.trim().replace(/^```json\s*/i, "").replace(/```\s*$/, "").trim();
        const lines = JSON.parse(cleaned) as Array<{
          speaker: string;
          text: string;
          animation?: string | null;
        }>;
        if (!Array.isArray(lines) || lines.length === 0) return;
        const validAnims = ["bounce", "spin", "backflip", "headshake", "zoom", "vibrate"];
        const script: ConversationScript = lines.map((line, i) => ({
          speakerId: line.speaker === b.sheep.name ? t.idB : t.idA,
          text: line.text,
          duration: 3500,
          delay: i === 0 ? 0 : 800,
          animation:
            line.animation && validAnims.includes(line.animation)
              ? (line.animation as SheepAnimation)
              : undefined,
        }));
        this.flock.startScriptedConversation(script, [t.idA, t.idB]);
      } catch (e) {
        console.error("[co-sheep] drama narration parse failed:", e);
      }
    }).catch((e) => console.error("[co-sheep] drama narration failed:", e));
  }

  /** Per-tick continuous behaviors for pairs in dramatic states. */
  private runOngoingBehaviors(now: number, rels: RelationshipsSnapshot): void {
    for (const [key, rec] of Object.entries(this.state.pairs)) {
      const [idA, idB] = key.split("|");
      const a = this.flock.getCharacter(idA);
      const b = this.flock.getCharacter(idB);
      if (!a || !b) continue;

      if (rec.state === "feud") {
        const dist = Math.abs(a.sheep.x - b.sheep.x);
        if (
          dist < DISPLAY_SIZE * 2 &&
          this.flock.isCharacterCalm(idA) &&
          this.flock.isCharacterCalm(idB)
        ) {
          // Storm apart when too close.
          const dir = a.sheep.x < b.sheep.x ? -1 : 1;
          a.sheep.walkTarget = Math.max(
            0,
            Math.min(a.sheep.screenWidth - DISPLAY_SIZE, a.sheep.x + dir * DISPLAY_SIZE * 3),
          );
          a.sheep.playAnimation("headshake");
        } else if (Math.random() < SNIPE_CHANCE) {
          this.playScript("feud_snipe", idA, idB);
        }

        // Mediation: the best-connected calm third sheep intervenes.
        if (Math.random() < MEDIATION_CHANCE) {
          const mediator = this.pickMediator(idA, idB, rels);
          if (mediator && this.playScript("mediation", idA, idB, mediator)) {
            if (Math.random() < MEDIATION_SUCCESS) {
              this.applyTransition({
                idA, idB, from: "feud", to: "reconciling", cause: "mediation",
              });
            }
          }
        }

        // Long feuds may erupt into a high-noon showdown (Task 9 sets the callback).
        if (
          now - rec.since >= SHOWDOWN_MS &&
          Math.random() < SHOWDOWN_CHANCE &&
          this.onDramaTriggeredSpectacle
        ) {
          this.onDramaTriggeredSpectacle("showdown", [idA, idB]);
        }
      }

      if (rec.state === "inseparable") {
        // Trail each other when separated.
        const dist = Math.abs(a.sheep.x - b.sheep.x);
        if (dist > DISPLAY_SIZE * 4 && this.flock.isCharacterCalm(idB) && b.sheep.walkTarget === null) {
          b.sheep.walkTarget = a.sheep.x;
        }
      }
    }
  }

  /** Calm third sheep with the highest combined affinity to both feuders. */
  private pickMediator(idA: string, idB: string, rels: RelationshipsSnapshot): string | null {
    let best: string | null = null;
    let bestScore = -Infinity;
    for (const id of this.flock.getCharacterIds()) {
      if (id === idA || id === idB || id === "main") continue;
      if (!this.flock.isCharacterCalm(id)) continue;
      const score =
        (rels[id]?.relationships?.[idA] ?? 0) + (rels[id]?.relationships?.[idB] ?? 0);
      if (score > bestScore) {
        bestScore = score;
        best = id;
      }
    }
    return best;
  }

  private playScript(kind: DramaScriptKind, idA: string, idB: string, mediatorId?: string): boolean {
    const script = pickDramaScript(kind, idA, idB, mediatorId);
    const participants = mediatorId ? [idA, idB, mediatorId] : [idA, idB];
    return this.flock.startScriptedConversation(script, participants);
  }

  private persist(): void {
    invoke("save_living_state", { name: "drama", value: this.state }).catch(() => {});
  }
}
```

- [ ] **Step 3: Wire into main.ts**

In `src/main.ts`:

1. Add imports:

```ts
import { bus } from "./events";
import { DramaManager } from "./drama-manager";
```

2. Add a module-level variable next to `let flock: Flock;`:

```ts
let dramaManager: DramaManager;
```

3. In `init()`, right after `flock = new Flock(...)` and its console.log:

```ts
  dramaManager = new DramaManager(flock);
  dramaManager.start();
```

4. In the petting handler (the `mousemove` listener that calls `target.startPetting()`), after the `invoke("record_interaction", ...)` line, add:

```ts
        bus.emit("sheep-petted", { id: target.id });
```

- [ ] **Step 4: Verify**

Run: `pnpm test && pnpm build && (cd src-tauri && cargo check)`
Expected: all clean.

- [ ] **Step 5: Commit**

```bash
git add src/drama-manager.ts src/main.ts src-tauri/src/lib.rs src-tauri/src/vision.rs
git commit -m "Wire drama simulation into the flock with AI narration hook"
```

---

### Task 8: Spectacle scheduler (pure logic) + tests

**Files:**
- Create: `src/spectacles.ts`
- Create: `src/spectacles.test.ts`

**Interfaces:**
- Consumes: nothing (pure module).
- Produces (used by Task 9):
  - `type SpectacleType = "wolf" | "ufo" | "merchant" | "balloon" | "shearing" | "showdown" | "feast"`
  - `interface SpectacleSchedulerState { lastFiredMs: number; lastByType: Partial<Record<SpectacleType, number>> }`
  - `interface SchedulerInput { state: SpectacleSchedulerState; nowMs: number; isNight: boolean; rand: number }`
  - `pickRandomSpectacle(input: SchedulerInput): SpectacleType | null` — random-table types only (never showdown/feast).
  - `markFired(state, type, nowMs): SpectacleSchedulerState`
  - `SPECTACLE` tuning constants.

- [ ] **Step 1: Write the failing tests**

Create `src/spectacles.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import {
  SPECTACLE,
  SpectacleSchedulerState,
  markFired,
  pickRandomSpectacle,
} from "./spectacles";

const DAY = 24 * 3600 * 1000;

function fresh(): SpectacleSchedulerState {
  return { lastFiredMs: 0, lastByType: {} };
}

describe("pickRandomSpectacle", () => {
  it("never fires within MIN_GAP of the last spectacle", () => {
    const state = { ...fresh(), lastFiredMs: 100 * DAY };
    const picked = pickRandomSpectacle({
      state,
      nowMs: 100 * DAY + SPECTACLE.MIN_GAP_MS - 1,
      isNight: false,
      rand: 0, // would otherwise always fire
    });
    expect(picked).toBeNull();
  });

  it("never fires at night", () => {
    const picked = pickRandomSpectacle({
      state: fresh(),
      nowMs: 100 * DAY,
      isNight: true,
      rand: 0,
    });
    expect(picked).toBeNull();
  });

  it("fires on a lucky roll after the gap", () => {
    const picked = pickRandomSpectacle({
      state: { ...fresh(), lastFiredMs: 100 * DAY },
      nowMs: 100 * DAY + SPECTACLE.MIN_GAP_MS + 1,
      isNight: false,
      rand: 0,
    });
    expect(picked).not.toBeNull();
  });

  it("does not fire on an unlucky roll before the pity timer", () => {
    const picked = pickRandomSpectacle({
      state: { ...fresh(), lastFiredMs: 100 * DAY },
      nowMs: 100 * DAY + SPECTACLE.MIN_GAP_MS + 1,
      isNight: false,
      rand: 0.99,
    });
    expect(picked).toBeNull();
  });

  it("pity timer forces a spectacle even on an unlucky roll", () => {
    const picked = pickRandomSpectacle({
      state: { ...fresh(), lastFiredMs: 100 * DAY },
      nowMs: 100 * DAY + SPECTACLE.PITY_MS + 1,
      isNight: false,
      rand: 0.99,
    });
    expect(picked).not.toBeNull();
  });

  it("respects the per-type cooldown", () => {
    // Exhaust every type's cooldown except one; the pick must be that one.
    const nowMs = 100 * DAY;
    let state = fresh();
    state = markFired(state, "wolf", nowMs - 1);
    state = markFired(state, "ufo", nowMs - 1);
    state = markFired(state, "merchant", nowMs - 1);
    state = markFired(state, "shearing", nowMs - 1);
    state = { ...state, lastFiredMs: nowMs - SPECTACLE.MIN_GAP_MS - 1 };
    const picked = pickRandomSpectacle({ state, nowMs, isNight: false, rand: 0 });
    expect(picked).toBe("balloon");
  });

  it("returns null when every type is cooling down", () => {
    const nowMs = 100 * DAY;
    let state = fresh();
    for (const t of ["wolf", "ufo", "merchant", "balloon", "shearing"] as const) {
      state = markFired(state, t, nowMs - 1);
    }
    state = { ...state, lastFiredMs: nowMs - SPECTACLE.PITY_MS - 1 };
    expect(pickRandomSpectacle({ state, nowMs, isNight: false, rand: 0 })).toBeNull();
  });
});

describe("markFired", () => {
  it("stamps both the global and per-type clocks", () => {
    const s = markFired(fresh(), "wolf", 123);
    expect(s.lastFiredMs).toBe(123);
    expect(s.lastByType.wolf).toBe(123);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — cannot resolve `./spectacles`.

- [ ] **Step 3: Write the implementation**

Create `src/spectacles.ts`:

```ts
/**
 * Spectacle scheduling — pure logic. Rare, high-impact desktop events.
 * Random spectacles roll on a timer; showdown/feast are drama-triggered
 * and never come from this table.
 */

export type SpectacleType =
  | "wolf"
  | "ufo"
  | "merchant"
  | "balloon"
  | "shearing"
  | "showdown"
  | "feast";

export interface SpectacleSchedulerState {
  lastFiredMs: number;
  lastByType: Partial<Record<SpectacleType, number>>;
}

export interface SchedulerInput {
  state: SpectacleSchedulerState;
  nowMs: number;
  isNight: boolean;
  /** Random [0,1) injected by the caller for testability. */
  rand: number;
}

export const SPECTACLE = {
  /** Global floor between spectacles (~at most one per day). */
  MIN_GAP_MS: 20 * 3600 * 1000,
  /** Guaranteed something within this window of app uptime. */
  PITY_MS: 72 * 3600 * 1000,
  /** Per 5-min check: expected ~one spectacle every 2 days of uptime. */
  TICK_CHANCE: 0.0017,
  /** Same spectacle won't repeat within a week. */
  TYPE_COOLDOWN_MS: 7 * 24 * 3600 * 1000,
  CHECK_INTERVAL_MS: 5 * 60 * 1000,
} as const;

const RANDOM_TABLE: Array<{ type: SpectacleType; weight: number }> = [
  { type: "wolf", weight: 3 },
  { type: "ufo", weight: 2 },
  { type: "merchant", weight: 2 },
  { type: "balloon", weight: 2 },
  { type: "shearing", weight: 1 },
];

export function pickRandomSpectacle(input: SchedulerInput): SpectacleType | null {
  const { state, nowMs, isNight, rand } = input;
  if (isNight) return null;
  if (nowMs - state.lastFiredMs < SPECTACLE.MIN_GAP_MS) return null;

  const pityDue = nowMs - state.lastFiredMs >= SPECTACLE.PITY_MS;
  if (!pityDue && rand >= SPECTACLE.TICK_CHANCE) return null;

  const eligible = RANDOM_TABLE.filter(({ type }) => {
    const last = state.lastByType[type];
    return last === undefined || nowMs - last >= SPECTACLE.TYPE_COOLDOWN_MS;
  });
  if (eligible.length === 0) return null;

  const totalWeight = eligible.reduce((s, e) => s + e.weight, 0);
  let roll = rand * totalWeight;
  for (const e of eligible) {
    roll -= e.weight;
    if (roll < 0) return e.type;
  }
  return eligible[eligible.length - 1].type;
}

export function markFired(
  state: SpectacleSchedulerState,
  type: SpectacleType,
  nowMs: number,
): SpectacleSchedulerState {
  return {
    lastFiredMs: nowMs,
    lastByType: { ...state.lastByType, [type]: nowMs },
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/spectacles.ts src/spectacles.test.ts
git commit -m "Add pure spectacle scheduler with pity timer"
```

---

### Task 9: Spectacle scenes, rendering, and Flock integration

**Files:**
- Create: `src/spectacle-render.ts`
- Modify: `src/flock.ts` (scene lifecycle, scheduler timer, persistence, draw)
- Modify: `src/main.ts` (connect drama-triggered spectacles)

**Interfaces:**
- Consumes: `spectacles.ts` (Task 8), Flock API (Task 6), `bus`, commands `get_living_state`/`save_living_state`/`record_spectacle` (Task 2), `get_accessories`/`save_accessories` (existing), `DramaManager.resolveShowdown` + `onDramaTriggeredSpectacle` (Task 7).
- Produces:
  - `spectacle-render.ts`: `interface SpectacleScene { type, phase: "enter" | "perform" | "exit", timer, actorX, actorY, facingRight, targetId?, pairIds?, data: Record<string, number> }`, `createSpectacleScene(type, screenW, screenH, calmIds: string[], pair?: [string, string]): SpectacleScene`, `updateSpectacleScene(scene, dt, world): boolean` (false = finished), `drawSpectacleScene(scene, ctx, world): void`, where `world = { getCharacter(id), characterIds(): string[], screenW: number, screenH: number }`.
  - `Flock.startSpectacle(type: SpectacleType, pair?: [string, string]): boolean` — public; refuses if one is already running.
  - `Flock.onShowdownResolved: ((pair: [string, string], reconciled: boolean) => void) | null` — main.ts points this at `dramaManager.resolveShowdown`.
  - Bus emits `spectacle-started` / `spectacle-ended`; aftermath via `record_spectacle`.

**Scene specs (all use phase machines like `group-activities.ts`; ground Y = `screenH - 96 - 10`):**

| Type | enter | perform | exit | aftermath |
|---|---|---|---|---|
| wolf | wolf runs in from left edge to 30% width, 2 s | 6 s: every character gets `walkTarget` away from wolf + `zoom` animation; at 3 s Good Colleague bubble `"Jeg var IKKE redd."` | wolf runs back off-screen, 2.5 s | `record_spectacle("wolf scare", participants)`; survivors huddle bubbles |
| ufo | saucer descends from top to 25% height above target, 2.5 s | 8 s: target sheep state → `"grabbed"` (established `(sheep as any)` pattern), lerp its `y` up toward the saucer; beam drawn | saucer ascends 2 s; target state → `"fall"` (existing physics lands it) | target bubble `"I have SEEN things."` + `spin`; `record_spectacle("UFO encounter", [targetId])` |
| merchant | gray merchant sheep walks in from right to 60% width, 4 s | 6 s: main sheep walks toward it and bubbles `"A traveling merchant!"` (the merchant is a scene actor with no SpeechBubble of its own) | merchant walks off-screen right, 3 s | gift: `get_accessories` → append one random id not already owned from `GIFT_POOL` (14 ids, see code) → `save_accessories` (existing `accessories-changed` listener re-applies the overlay); main bubble `"Ooh, a gift!"`; aftermath recording skipped (participants exclude `"main"`, see integration code) |
| balloon | balloon appears at left edge, 15% height | drifts right across the whole screen over 20 s; calm characters sit (`(sheep as any).state = "sit"` with long duration) and face it; one bubble `"Ooooh."` at 5 s | ends when off-screen right | `record_spectacle("balloon flyover", participants)` |
| shearing | none (0 s) | 60 s: every character `vibrate` once at start, then drawn with the shorn overlay (pink body ellipse, see draw code); staggered mortified bubbles: `"MY WOOL!"`, `"Don't look at me."`, `"This is a violation."`, `"Cold. So cold."` | wool "regrows": overlay alpha fades over the final 10 s | `record_spectacle("shearing day", participants)` |
| showdown | both pair sheep get `walkTarget` = screen center ± 60 px, up to 5 s | 8 s: both face each other, `vibrate` at 0 s and 4 s; tumbleweed drawn rolling across; other calm characters sit at distance | 2 s: outcome roll `Math.random() < 0.5` → reconciled; bubbles `"...truce?"` / `"This isn't over."` | call `flock.onShowdownResolved(pair, reconciled)`; `record_spectacle("high-noon showdown", pair)` |
| feast | all calm characters `walkTarget` toward center, up to 6 s | 15 s: first pair sheep state → `"idle_campfire"`, everyone else `"sit"`; bubbles: pairA `"To making up!"`, pairB `"To wool and friendship!"` | 3 s disperse (random walkTargets like `startDispersing` in group-activities.ts) | `record_spectacle("reconciliation feast", participants)` |

- [ ] **Step 1: Write the scene module**

Create `src/spectacle-render.ts` implementing the table above. Skeleton with the two trickiest scenes complete — implement the rest following the same pattern:

```ts
import { Sheep } from "./sheep";
import { SpeechBubble } from "./speech-bubble";
import { SpectacleType } from "./spectacles";

export interface SpectacleWorld {
  getCharacter(id: string): { sheep: Sheep; bubble: SpeechBubble; personality?: string } | null;
  characterIds(): string[];
  screenW: number;
  screenH: number;
}

export interface SpectacleScene {
  type: SpectacleType;
  phase: "enter" | "perform" | "exit";
  timer: number;
  actorX: number;
  actorY: number;
  facingRight: boolean;
  targetId?: string;
  pairIds?: [string, string];
  participants: string[];
  /** Per-scene scratch values (flags, one-shot markers, outcome). */
  data: Record<string, number>;
}

const SIZE = 96;
const GROUND_OFFSET = SIZE + 10;

export function createSpectacleScene(
  type: SpectacleType,
  screenW: number,
  screenH: number,
  calmIds: string[],
  pair?: [string, string],
): SpectacleScene {
  const scene: SpectacleScene = {
    type,
    phase: type === "shearing" ? "perform" : "enter",
    timer: 0,
    actorX: type === "merchant" ? screenW + SIZE : -SIZE,
    actorY:
      type === "ufo" ? -SIZE :
      type === "balloon" ? screenH * 0.15 :
      screenH - GROUND_OFFSET,
    facingRight: type !== "merchant",
    participants: [...calmIds],
    pairIds: pair,
    data: {},
  };
  if (type === "ufo") {
    scene.targetId = calmIds[Math.floor(Math.random() * calmIds.length)] ?? "main";
  }
  return scene;
}

/** Returns true while running; false once the scene is finished. */
export function updateSpectacleScene(
  scene: SpectacleScene,
  dt: number,
  world: SpectacleWorld,
): boolean {
  scene.timer += dt;
  switch (scene.type) {
    case "wolf": return updateWolf(scene, dt, world);
    case "ufo": return updateUfo(scene, dt, world);
    case "merchant": return updateMerchant(scene, dt, world);
    case "balloon": return updateBalloon(scene, dt, world);
    case "shearing": return updateShearing(scene, dt, world);
    case "showdown": return updateShowdown(scene, dt, world);
    case "feast": return updateFeast(scene, dt, world);
  }
}

function setState(sheep: Sheep, state: string, durationMs: number): void {
  (sheep as any).state = state;
  (sheep as any).stateTimer = 0;
  (sheep as any).stateDuration = durationMs;
}

function updateWolf(scene: SpectacleScene, dt: number, world: SpectacleWorld): boolean {
  const speed = 0.35; // px per ms
  if (scene.phase === "enter") {
    scene.actorX += speed * dt;
    if (scene.actorX >= world.screenW * 0.3 || scene.timer > 2000) {
      scene.phase = "perform";
      scene.timer = 0;
      // Flock flees.
      for (const id of world.characterIds()) {
        const c = world.getCharacter(id);
        if (!c) continue;
        const away = c.sheep.x < scene.actorX ? 0 : world.screenW - SIZE;
        c.sheep.walkTarget = away;
        c.sheep.playAnimation("zoom");
      }
    }
  } else if (scene.phase === "perform") {
    if (scene.timer > 3000 && !scene.data.gcQuip) {
      scene.data.gcQuip = 1;
      const gc = world.getCharacter("good_colleague");
      if (gc && !gc.bubble.visible) gc.bubble.show("Jeg var IKKE redd.", 4000);
    }
    if (scene.timer > 6000) {
      scene.phase = "exit";
      scene.timer = 0;
      scene.facingRight = false;
    }
  } else {
    scene.actorX -= speed * 1.4 * dt;
    if (scene.actorX < -SIZE) return false;
  }
  return true;
}

function updateUfo(scene: SpectacleScene, dt: number, world: SpectacleWorld): boolean {
  const target = world.getCharacter(scene.targetId ?? "main");
  if (!target) return false;
  const hoverY = world.screenH * 0.25;
  if (scene.phase === "enter") {
    scene.actorX = target.sheep.x + SIZE / 2 - 40;
    scene.actorY = Math.min(hoverY, scene.actorY + 0.3 * dt);
    if (scene.actorY >= hoverY || scene.timer > 2500) {
      scene.phase = "perform";
      scene.timer = 0;
      setState(target.sheep, "grabbed", 8000);
    }
  } else if (scene.phase === "perform") {
    // Beam the target upward.
    const liftTo = scene.actorY + 90;
    if (target.sheep.y > liftTo) target.sheep.y -= 0.15 * dt;
    if (scene.timer > 8000) {
      scene.phase = "exit";
      scene.timer = 0;
      setState(target.sheep, "fall", 4000);
    }
  } else {
    scene.actorY -= 0.4 * dt;
    if (scene.actorY < -120 || scene.timer > 2000) {
      if (!target.bubble.visible) target.bubble.show("I have SEEN things.", 5000);
      target.sheep.playAnimation("spin");
      return false;
    }
  }
  return true;
}

const GIFT_POOL = [
  "party_hat", "crown", "sunglasses", "bow_tie", "flower", "scarf", "top_hat",
  "monocle", "wizard_hat", "bandana", "mustache", "cape", "chef_hat", "necklace",
];

function updateMerchant(scene: SpectacleScene, dt: number, world: SpectacleWorld): boolean {
  const speed = 0.2;
  if (scene.phase === "enter") {
    scene.actorX -= speed * dt;
    if (scene.actorX <= world.screenW * 0.6 || scene.timer > 4000) {
      scene.phase = "perform";
      scene.timer = 0;
      const main = world.getCharacter("main");
      if (main) {
        main.sheep.walkTarget = scene.actorX - SIZE;
        if (!main.bubble.visible) main.bubble.show("A traveling merchant!", 3500);
      }
    }
  } else if (scene.phase === "perform") {
    if (scene.timer > 6000) {
      scene.phase = "exit";
      scene.timer = 0;
      scene.facingRight = true;
      giftAccessory(world);
    }
  } else {
    scene.actorX += speed * 1.5 * dt;
    if (scene.actorX > world.screenW + SIZE) return false;
  }
  return true;
}

/** Fire-and-forget: gift the main sheep one accessory it doesn't own yet. */
function giftAccessory(world: SpectacleWorld): void {
  invoke<string[]>("get_accessories")
    .then((owned) => {
      const options = GIFT_POOL.filter((id) => !owned.includes(id));
      if (options.length === 0) return;
      const gift = options[Math.floor(Math.random() * options.length)];
      return invoke("save_accessories", { accessories: [...owned, gift] }).then(() => {
        const main = world.getCharacter("main");
        if (main) {
          if (!main.bubble.visible) main.bubble.show("Ooh, a gift!", 4000);
          main.sheep.playAnimation("bounce");
        }
      });
    })
    .catch((e) => console.error("[co-sheep] merchant gift failed:", e));
}

function updateBalloon(scene: SpectacleScene, dt: number, world: SpectacleWorld): boolean {
  if (scene.phase === "enter") {
    scene.phase = "perform";
    scene.timer = 0;
    scene.actorX = -60;
    for (const id of scene.participants) {
      const c = world.getCharacter(id);
      if (c) setState(c.sheep, "sit", 20000);
    }
  } else {
    scene.actorX += ((world.screenW + 120) / 20000) * dt;
    if (scene.timer > 5000 && !scene.data.ooh) {
      scene.data.ooh = 1;
      const c = scene.participants[0] ? world.getCharacter(scene.participants[0]) : null;
      if (c && !c.bubble.visible) c.bubble.show("Ooooh.", 3000);
    }
    for (const id of scene.participants) {
      const c = world.getCharacter(id);
      if (c) c.sheep.facingRight = scene.actorX > c.sheep.x; // track the balloon
    }
    if (scene.actorX > world.screenW + 60) return false;
  }
  return true;
}

const SHEARING_BUBBLES = ["MY WOOL!", "Don't look at me.", "This is a violation.", "Cold. So cold."];
const SHEARING_TOTAL_MS = 60_000;

function updateShearing(scene: SpectacleScene, _dt: number, world: SpectacleWorld): boolean {
  // Scene is created directly in "perform"; the shorn overlay is drawn
  // by drawShornOverlays and fades back in over the final 10 s.
  if (!scene.data.started) {
    scene.data.started = 1;
    for (const id of scene.participants) {
      world.getCharacter(id)?.sheep.playAnimation("vibrate");
    }
  }
  for (let i = 0; i < SHEARING_BUBBLES.length; i++) {
    const flag = `bubble${i}`;
    if (scene.timer > i * 2000 && !scene.data[flag]) {
      scene.data[flag] = 1;
      const id = scene.participants[i % Math.max(1, scene.participants.length)];
      const c = id ? world.getCharacter(id) : null;
      if (c && !c.bubble.visible) c.bubble.show(SHEARING_BUBBLES[i], 3000);
    }
  }
  return scene.timer < SHEARING_TOTAL_MS;
}

function updateShowdown(scene: SpectacleScene, _dt: number, world: SpectacleWorld): boolean {
  if (!scene.pairIds) return false;
  const a = world.getCharacter(scene.pairIds[0]);
  const b = world.getCharacter(scene.pairIds[1]);
  if (!a || !b) return false;
  const center = world.screenW / 2;
  const aSpot = center - 60 - SIZE / 2;
  const bSpot = center + 60 - SIZE / 2;

  if (scene.phase === "enter") {
    if (!scene.data.summoned) {
      scene.data.summoned = 1;
      a.sheep.walkTarget = aSpot;
      b.sheep.walkTarget = bSpot;
      for (const id of scene.participants) {
        if (id === scene.pairIds[0] || id === scene.pairIds[1]) continue;
        const c = world.getCharacter(id);
        if (c) setState(c.sheep, "sit", 15000); // spectators settle in
      }
    }
    const gathered =
      Math.abs(a.sheep.x - aSpot) < SIZE && Math.abs(b.sheep.x - bSpot) < SIZE;
    if (gathered || scene.timer > 5000) {
      scene.phase = "perform";
      scene.timer = 0;
    }
  } else if (scene.phase === "perform") {
    a.sheep.facingRight = b.sheep.x > a.sheep.x;
    b.sheep.facingRight = a.sheep.x > b.sheep.x;
    if (!scene.data.vibe0) {
      scene.data.vibe0 = 1;
      a.sheep.playAnimation("vibrate");
      b.sheep.playAnimation("vibrate");
    }
    if (scene.timer > 4000 && !scene.data.vibe4) {
      scene.data.vibe4 = 1;
      a.sheep.playAnimation("vibrate");
      b.sheep.playAnimation("vibrate");
    }
    if (scene.timer > 8000) {
      scene.phase = "exit";
      scene.timer = 0;
      scene.data.reconciled = Math.random() < 0.5 ? 1 : 0;
      const rec = scene.data.reconciled === 1;
      if (!a.bubble.visible) a.bubble.show(rec ? "...truce?" : "This isn't over.", 4000);
      if (!b.bubble.visible) b.bubble.show(rec ? "...fine. Truce." : "Not even CLOSE to over.", 4000);
    }
  } else if (scene.timer > 2000) {
    return false;
  }
  return true;
}

function updateFeast(scene: SpectacleScene, _dt: number, world: SpectacleWorld): boolean {
  const center = world.screenW / 2;
  if (scene.phase === "enter") {
    if (!scene.data.gathered) {
      scene.data.gathered = 1;
      let slot = 0;
      for (const id of scene.participants) {
        const c = world.getCharacter(id);
        if (!c) continue;
        c.sheep.walkTarget = center + (slot - scene.participants.length / 2) * SIZE * 0.9;
        slot++;
      }
    }
    if (scene.timer > 6000) {
      scene.phase = "perform";
      scene.timer = 0;
      const host = scene.pairIds?.[0] ?? scene.participants[0];
      const hostChar = host ? world.getCharacter(host) : null;
      if (hostChar) {
        setState(hostChar.sheep, "idle_campfire", 15000);
        (hostChar.sheep as any).campfireSparks = [];
      }
      for (const id of scene.participants) {
        if (id === host) continue;
        const c = world.getCharacter(id);
        if (c) setState(c.sheep, "sit", 15000);
      }
    }
  } else if (scene.phase === "perform") {
    if (scene.timer > 2000 && !scene.data.toasted && scene.pairIds) {
      scene.data.toasted = 1;
      const a = world.getCharacter(scene.pairIds[0]);
      const b = world.getCharacter(scene.pairIds[1]);
      if (a && !a.bubble.visible) a.bubble.show("To making up!", 3500);
      if (b) {
        setTimeout(() => {
          if (!b.bubble.visible) b.bubble.show("To wool and friendship!", 3500);
        }, 1200);
      }
    }
    if (scene.timer > 15000) {
      scene.phase = "exit";
      scene.timer = 0;
      for (const id of scene.participants) {
        const c = world.getCharacter(id);
        if (c) {
          const dir = Math.random() > 0.5 ? 1 : -1;
          c.sheep.walkTarget = c.sheep.x + dir * (SIZE * 2 + Math.random() * SIZE * 3);
        }
      }
    }
  } else if (scene.timer > 3000) {
    return false;
  }
  return true;
}
```

(`spectacle-render.ts` needs `import { invoke } from "@tauri-apps/api/core";` at the top for `giftAccessory`.)

Then the drawing half of the module — complete procedural pixel-art, no image assets:

```ts
export function drawSpectacleScene(
  scene: SpectacleScene,
  ctx: CanvasRenderingContext2D,
  world: SpectacleWorld,
): void {
  switch (scene.type) {
    case "wolf": drawWolf(ctx, scene.actorX, scene.actorY, scene.facingRight); break;
    case "ufo": drawUfo(ctx, scene.actorX, scene.actorY, scene.phase === "perform"); break;
    case "merchant": drawMerchant(ctx, scene.actorX, scene.actorY, scene.facingRight); break;
    case "balloon": drawBalloon(ctx, scene.actorX, scene.actorY); break;
    case "shearing": drawShornOverlays(ctx, scene, world); break;
    case "showdown": drawTumbleweed(ctx, scene, world); break;
    case "feast": break; // campfire visuals come from the existing idle_campfire state
  }
}

function drawWolf(ctx: CanvasRenderingContext2D, x: number, y: number, facingRight: boolean) {
  ctx.save();
  ctx.translate(x + 48, y + 48);
  if (!facingRight) ctx.scale(-1, 1);
  ctx.translate(-48, -48);
  const s = 3;
  ctx.fillStyle = "#4a4a55";                       // body
  ctx.fillRect(8 * s, 14 * s, 18 * s, 8 * s);
  ctx.fillRect(22 * s, 9 * s, 8 * s, 7 * s);       // head
  ctx.fillStyle = "#3a3a44";
  ctx.fillRect(27 * s, 6 * s, 3 * s, 4 * s);       // ear
  ctx.fillRect(4 * s, 13 * s, 5 * s, 3 * s);       // tail
  ctx.fillRect(9 * s, 22 * s, 3 * s, 5 * s);       // legs
  ctx.fillRect(14 * s, 22 * s, 3 * s, 5 * s);
  ctx.fillRect(19 * s, 22 * s, 3 * s, 5 * s);
  ctx.fillRect(23 * s, 22 * s, 3 * s, 5 * s);
  ctx.fillStyle = "#e94560";                       // eye
  ctx.fillRect(26 * s, 10 * s, 2 * s, 2 * s);
  ctx.fillStyle = "#ffffff";                       // fang
  ctx.fillRect(29 * s, 14 * s, 1 * s, 2 * s);
  ctx.restore();
}

function drawUfo(ctx: CanvasRenderingContext2D, x: number, y: number, beamOn: boolean) {
  ctx.save();
  if (beamOn) {
    const grad = ctx.createLinearGradient(x + 40, y + 20, x + 40, y + 400);
    grad.addColorStop(0, "rgba(120, 255, 160, 0.35)");
    grad.addColorStop(1, "rgba(120, 255, 160, 0)");
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.moveTo(x + 25, y + 20);
    ctx.lineTo(x + 55, y + 20);
    ctx.lineTo(x + 95, y + 400);
    ctx.lineTo(x - 15, y + 400);
    ctx.closePath();
    ctx.fill();
  }
  ctx.fillStyle = "#8899aa";                        // saucer
  ctx.beginPath();
  ctx.ellipse(x + 40, y + 14, 40, 12, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = "#bfe8ff";                        // dome
  ctx.beginPath();
  ctx.arc(x + 40, y + 6, 14, Math.PI, 0);
  ctx.fill();
  ctx.fillStyle = "#ffe066";                        // lights
  const t = Math.floor(Date.now() / 300) % 3;
  for (let i = 0; i < 3; i++) {
    ctx.globalAlpha = i === t ? 1 : 0.35;
    ctx.fillRect(x + 18 + i * 20, y + 16, 6, 4);
  }
  ctx.restore();
}

function drawMerchant(ctx: CanvasRenderingContext2D, x: number, y: number, facingRight: boolean) {
  const s = 3;
  ctx.save();
  ctx.translate(x + 48, y + 48);
  if (!facingRight) ctx.scale(-1, 1);
  ctx.translate(-48, -48);
  ctx.fillStyle = "#9a9aa5";                        // grey wool body
  ctx.fillRect(8 * s, 12 * s, 16 * s, 10 * s);
  ctx.fillRect(21 * s, 8 * s, 7 * s, 8 * s);        // head
  ctx.fillStyle = "#6f6f7a";
  ctx.fillRect(10 * s, 22 * s, 3 * s, 5 * s);       // legs
  ctx.fillRect(19 * s, 22 * s, 3 * s, 5 * s);
  ctx.fillStyle = "#1a1a2e";                        // top hat
  ctx.fillRect(21 * s, 3 * s, 7 * s, 2 * s);
  ctx.fillRect(22.5 * s, 0 * s, 4 * s, 3 * s);
  ctx.fillStyle = "#7a5230";                        // wares bundle
  ctx.fillRect(6 * s, 8 * s, 7 * s, 6 * s);
  ctx.strokeStyle = "#4d3319";
  ctx.lineWidth = 2;
  ctx.strokeRect(6 * s, 8 * s, 7 * s, 6 * s);
  ctx.fillStyle = "#1a1a2e";                        // eye
  ctx.fillRect(25 * s, 10 * s, 2 * s, 2 * s);
  ctx.restore();
}

function drawBalloon(ctx: CanvasRenderingContext2D, x: number, y: number) {
  ctx.save();
  const bob = Math.sin(Date.now() / 900) * 6;
  const by = y + bob;
  ctx.fillStyle = "#e94560";                        // envelope
  ctx.beginPath();
  ctx.arc(x, by, 34, Math.PI * 0.95, Math.PI * 2.05);
  ctx.fill();
  ctx.fillStyle = "#d4a520";
  ctx.beginPath();
  ctx.arc(x, by, 34, Math.PI * 1.25, Math.PI * 1.75);
  ctx.fill();
  ctx.strokeStyle = "#6f4e37";                      // ropes
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(x - 20, by + 24); ctx.lineTo(x - 9, by + 48);
  ctx.moveTo(x + 20, by + 24); ctx.lineTo(x + 9, by + 48);
  ctx.stroke();
  ctx.fillStyle = "#7a5230";                        // basket
  ctx.fillRect(x - 11, by + 48, 22, 14);
  ctx.restore();
}

function drawShornOverlays(ctx: CanvasRenderingContext2D, scene: SpectacleScene, world: SpectacleWorld) {
  // Pink "naked" ellipse over each sheep's wool; fades back in the last 10s.
  const total = 60_000;
  const fadeStart = total - 10_000;
  const alpha = scene.timer < fadeStart ? 0.65 : 0.65 * (1 - (scene.timer - fadeStart) / 10_000);
  if (alpha <= 0) return;
  ctx.save();
  ctx.globalAlpha = Math.max(0, alpha);
  ctx.fillStyle = "#f2b9c4";
  for (const id of scene.participants) {
    const c = world.getCharacter(id);
    if (!c) continue;
    const sz = c.sheep.displaySize;
    ctx.beginPath();
    ctx.ellipse(c.sheep.x + sz * 0.45, c.sheep.y + sz * 0.55, sz * 0.32, sz * 0.24, 0, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.restore();
}

function drawTumbleweed(ctx: CanvasRenderingContext2D, scene: SpectacleScene, world: SpectacleWorld) {
  if (scene.phase !== "perform") return;
  const x = (scene.data.tumbleX = (scene.data.tumbleX ?? -20) + 4);
  const y = world.screenH - 130 + Math.abs(Math.sin(x / 40)) * -18;
  ctx.save();
  ctx.strokeStyle = "#b0925a";
  ctx.lineWidth = 2;
  ctx.translate(x, y);
  ctx.rotate(x / 30);
  ctx.beginPath();
  ctx.arc(0, 0, 12, 0, Math.PI * 2);
  for (let i = 0; i < 4; i++) {
    ctx.moveTo(-12, 0);
    ctx.quadraticCurveTo(0, (i - 1.5) * 8, 12, 0);
  }
  ctx.stroke();
  ctx.restore();
}
```

The five remaining `update*` functions must be fully written out (the comment block above lists every behavior and one-shot; convert each bullet into code following `updateWolf`/`updateUfo` structure). No stubs may remain.

- [ ] **Step 2: Integrate into Flock**

In `src/flock.ts`:

1. Imports:

```ts
import { SPECTACLE, SpectacleSchedulerState, SpectacleType, markFired, pickRandomSpectacle } from "./spectacles";
import { SpectacleScene, SpectacleWorld, createSpectacleScene, drawSpectacleScene, updateSpectacleScene } from "./spectacle-render";
```

2. Fields (near `groupActivity`):

```ts
  private spectacle: SpectacleScene | null = null;
  private spectacleSchedulerState: SpectacleSchedulerState = { lastFiredMs: 0, lastByType: {} };
  private spectacleCheckTimer = 0;
  private spectacleStateLoaded = false;
  /** main.ts points this at dramaManager.resolveShowdown. */
  onShowdownResolved: ((pair: [string, string], reconciled: boolean) => void) | null = null;
```

3. In the constructor, load persisted scheduler state:

```ts
    invoke<SpectacleSchedulerState | null>("get_living_state", { name: "spectacles" })
      .then((s) => {
        if (s && typeof s.lastFiredMs === "number") this.spectacleSchedulerState = s;
        this.spectacleStateLoaded = true;
      })
      .catch(() => { this.spectacleStateLoaded = true; });
```

4. Public start method:

```ts
  /** Begin a spectacle. Refuses while another scene is running. */
  startSpectacle(type: SpectacleType, pair?: [string, string]): boolean {
    if (this.spectacle) return false;
    this.cancelConversation();
    const calmIds = this.getCharacterIds().filter((id) => this.isCharacterCalm(id));
    if (type !== "balloon" && calmIds.length === 0) return false;
    this.spectacle = createSpectacleScene(type, this.screenWidth, this.screenHeight, calmIds, pair);
    this.spectacleSchedulerState = markFired(this.spectacleSchedulerState, type, Date.now());
    invoke("save_living_state", { name: "spectacles", value: this.spectacleSchedulerState }).catch(() => {});
    bus.emit("spectacle-started", { type });
    console.log(`[co-sheep] SPECTACLE: ${type}`);
    return true;
  }
```

5. In `update(dt)`, after `this.updateGroupActivityLoop(...)`, add the scene pump and scheduler:

```ts
    // Spectacles: run the active scene, else roll the scheduler every 5 min.
    if (this.spectacle) {
      const world = this.spectacleWorld();
      const alive = updateSpectacleScene(this.spectacle, dt, world);
      if (!alive) {
        const finished = this.spectacle;
        this.spectacle = null;
        bus.emit("spectacle-ended", { type: finished.type });
        if (finished.type === "showdown" && finished.pairIds && this.onShowdownResolved) {
          this.onShowdownResolved(finished.pairIds, finished.data.reconciled === 1);
        }
        const kindLabels: Record<SpectacleType, string> = {
          wolf: "wolf scare", ufo: "UFO encounter", merchant: "merchant visit",
          balloon: "balloon flyover", shearing: "shearing day",
          showdown: "high-noon showdown", feast: "reconciliation feast",
        };
        // "main" has no friend brain — never pass it to record_spectacle
        // or friend_memory would mint a brain file for it.
        const who = (finished.type === "showdown" && finished.pairIds
          ? [...finished.pairIds]
          : finished.participants
        ).filter((id) => id !== "main");
        if (who.length > 0) {
          invoke("record_spectacle", { kind: kindLabels[finished.type], participants: who }).catch(() => {});
        }
      }
    } else if (this.spectacleStateLoaded) {
      this.spectacleCheckTimer += dt;
      if (this.spectacleCheckTimer >= SPECTACLE.CHECK_INTERVAL_MS) {
        this.spectacleCheckTimer = 0;
        const hour = new Date().getHours();
        const type = pickRandomSpectacle({
          state: this.spectacleSchedulerState,
          nowMs: Date.now(),
          isNight: hour >= 20 || hour < 6,
          rand: Math.random(),
        });
        if (type) this.startSpectacle(type);
      }
    }
```

6. World adapter (private method):

```ts
  private spectacleWorld(): SpectacleWorld {
    return {
      getCharacter: (id) => this.getSheepById(id),
      characterIds: () => this.getCharacterIds(),
      screenW: this.screenWidth,
      screenH: this.screenHeight,
    };
  }
```

7. In `draw(ctx)`, after the friends draw loop (so actors render above sheep):

```ts
    if (this.spectacle) {
      drawSpectacleScene(this.spectacle, ctx, this.spectacleWorld());
    }
```

8. Guard group activities during spectacles — in `updateGroupActivityLoop`, next to the `if (this.activeConversation) return;` line, add:

```ts
    if (this.spectacle) return;
```

- [ ] **Step 3: Connect drama-triggered spectacles in main.ts**

In `src/main.ts` `init()`, right after `dramaManager.start();`:

```ts
  dramaManager.onDramaTriggeredSpectacle = (kind, pair) => {
    flock.startSpectacle(kind, pair);
  };
  flock.onShowdownResolved = (pair, reconciled) => {
    dramaManager.resolveShowdown(pair, reconciled);
  };
```

- [ ] **Step 4: Verify**

Run: `pnpm test && pnpm build`
Expected: clean. (Visual verification comes with the Debug menu in Task 11.)

- [ ] **Step 5: Commit**

```bash
git add src/spectacle-render.ts src/flock.ts src/main.ts
git commit -m "Add spectacle scenes with scheduler and drama triggers"
```

---

### Task 10: Gossip & app-aware reactions

**Files:**
- Create: `src/gossip.ts`
- Modify: `src/main.ts` (bridge Tauri `app-switched` → bus; instantiate GossipManager)
- Modify: `src/break-reminder.ts` (name the actual app)

**Interfaces:**
- Consumes: `bus`, Flock API (Task 6), commands `record_app_usage` (Task 3), `record_friend_conversation` (existing).
- Produces: `class GossipManager { constructor(flock: Flock); start(): void }`, `categorizeApp(appName: string): AppCategory` (exported for tests if wanted), `type AppCategory = "dev" | "terminal" | "social" | "browser" | "meetings" | "music" | "mail" | "notes" | "other"`. `BreakReminder` gains public `currentApp: string | null`.

- [ ] **Step 1: Write the gossip module**

Create `src/gossip.ts`:

```ts
import { invoke } from "@tauri-apps/api/core";
import { Flock } from "./flock";
import { bus } from "./events";
import { ConversationScript } from "./types";

export type AppCategory =
  | "dev" | "terminal" | "social" | "browser" | "meetings"
  | "music" | "mail" | "notes" | "other";

const CATEGORY_APPS: Record<Exclude<AppCategory, "other">, string[]> = {
  dev: ["Code", "Visual Studio Code", "Xcode", "IntelliJ IDEA", "WebStorm", "Zed", "Cursor", "Sublime Text"],
  terminal: ["Terminal", "iTerm2", "Warp", "Ghostty", "kitty", "Alacritty"],
  social: ["Twitter", "X", "Discord", "Slack", "Telegram", "Messages", "WhatsApp", "Signal"],
  browser: ["Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser", "Microsoft Edge"],
  meetings: ["zoom.us", "Microsoft Teams", "FaceTime", "Google Meet", "Webex"],
  music: ["Music", "Spotify", "Tidal"],
  mail: ["Mail", "Microsoft Outlook", "Superhuman", "Mimestream"],
  notes: ["Notes", "Obsidian", "Notion", "Bear"],
};

export function categorizeApp(appName: string): AppCategory {
  const lower = appName.toLowerCase();
  for (const [category, names] of Object.entries(CATEGORY_APPS)) {
    if (names.some((n) => lower === n.toLowerCase() || lower.includes(n.toLowerCase()))) {
      return category as AppCategory;
    }
  }
  return "other";
}

/** Instant one-liners on switching INTO a category. Personality-neutral. */
const INSTANT_BITS: Record<AppCategory, string[]> = {
  dev: ["Ah, the code mines.", "Xcode again? Bold.", "*peers at the syntax*", "May the compiler be gentle."],
  terminal: ["Back to the green glow.", "*watches the cursor blink*", "Type faster. It's judging you. I'm judging you."],
  social: ["Ooh, are we procrastinating?", "Say hi from me.", "*leans in to read the drama*"],
  browser: ["Down the rabbit hole we go.", "How many tabs is that now?", "*pretends not to count the tabs*"],
  meetings: ["Say baa if you need rescuing.", "*sits very quietly*", "You're muted. Probably."],
  music: ["*bobs head*", "DJ human, volume up.", "Finally, some culture."],
  mail: ["Inbox zero is a myth.", "*watches you type 'per my last email'*"],
  notes: ["Writing things down. Growth.", "*peeks at the notes*"],
  other: ["What IS that app?", "*squints at the unfamiliar window*"],
};

/** Gossip templates about measured habits. $A/$B placeholders; {hours}/{app} filled. */
const GOSSIP_TEMPLATES: ConversationScript[] = [
  [
    { speakerId: "$A", text: "Hour {hours} in {app}.", duration: 3500, delay: 0 },
    { speakerId: "$B", text: "Blink twice if you need help, human.", duration: 4000, delay: 700, animation: "headshake" },
  ],
  [
    { speakerId: "$A", text: "{app}. Again. That's hour {hours}.", duration: 4000, delay: 0 },
    { speakerId: "$B", text: "We should stage an intervention.", duration: 3500, delay: 700 },
    { speakerId: "$A", text: "We ARE the intervention.", duration: 3000, delay: 600, animation: "bounce" },
  ],
  [
    { speakerId: "$A", text: "Psst. {hours} hours of {app} today.", duration: 4000, delay: 0 },
    { speakerId: "$B", text: "I heard. The whole flock heard.", duration: 3500, delay: 700, animation: "headshake" },
  ],
];

const INSTANT_BIT_COOLDOWN_MS = 10 * 60 * 1000;
const GOSSIP_HOUR_MS = 3600 * 1000;

export class GossipManager {
  private categoryMsToday: Partial<Record<AppCategory, number>> = {};
  private gossipedHours: Partial<Record<AppCategory, number>> = {};
  private day = new Date().toISOString().slice(0, 10);
  private lastInstantBit = 0;
  private currentCategory: AppCategory | null = null;

  constructor(private flock: Flock) {}

  start(): void {
    bus.on("app-switched", ({ app, previousApp, previousDurationMs }) => {
      this.rollDay();

      // Credit the finished session to the previous app's category.
      if (previousApp && previousDurationMs > 0) {
        const prevCat = categorizeApp(previousApp);
        this.categoryMsToday[prevCat] = (this.categoryMsToday[prevCat] ?? 0) + previousDurationMs;
      }

      const cat = categorizeApp(app);
      const isNewCategory = cat !== this.currentCategory;
      this.currentCategory = cat;

      if (isNewCategory) {
        // Daily tally (lands in opinions.json → feeds AI "Today's tallies").
        invoke("record_app_usage", { category: cat }).catch(() => {});
        this.maybeInstantBit(cat);
      }
      this.maybeGossip(cat);
    });
  }

  private rollDay(): void {
    const today = new Date().toISOString().slice(0, 10);
    if (today !== this.day) {
      this.day = today;
      this.categoryMsToday = {};
      this.gossipedHours = {};
    }
  }

  private maybeInstantBit(cat: AppCategory): void {
    const now = Date.now();
    if (now - this.lastInstantBit < INSTANT_BIT_COOLDOWN_MS) return;

    // A random calm friend delivers the bit.
    const candidates = this.flock
      .getCharacterIds()
      .filter((id) => id !== "main" && this.flock.isCharacterCalm(id));
    if (candidates.length === 0) return;
    const speaker = this.flock.getCharacter(candidates[Math.floor(Math.random() * candidates.length)]);
    if (!speaker || speaker.bubble.visible) return;

    const pool = INSTANT_BITS[cat];
    speaker.bubble.show(pool[Math.floor(Math.random() * pool.length)], 4000);
    this.lastInstantBit = now;
  }

  private maybeGossip(cat: AppCategory): void {
    const ms = this.categoryMsToday[cat] ?? 0;
    const hours = Math.floor(ms / GOSSIP_HOUR_MS);
    if (hours < 1) return;
    if ((this.gossipedHours[cat] ?? 0) >= hours) return; // one gossip per hour milestone

    const friends = this.flock
      .getCharacterIds()
      .filter((id) => id !== "main" && this.flock.isCharacterCalm(id));
    if (friends.length < 2) return;
    const [a, b] = friends.sort(() => Math.random() - 0.5);

    const appLabel = cat === "other" ? "that app" : `the ${cat === "dev" ? "editor" : cat}`;
    const template = GOSSIP_TEMPLATES[Math.floor(Math.random() * GOSSIP_TEMPLATES.length)];
    const script: ConversationScript = template.map((line) => ({
      ...line,
      speakerId: line.speakerId === "$A" ? a : line.speakerId === "$B" ? b : line.speakerId,
      text: line.text.replace("{hours}", String(hours)).replace("{app}", appLabel),
    }));

    if (this.flock.startScriptedConversation(script, [a, b])) {
      this.gossipedHours[cat] = hours;
      // Gossip becomes a shared memory + affinity bump via the existing command.
      invoke("record_friend_conversation", {
        idA: a, idB: b,
        topic: `the human's ${hours}h of ${cat}`,
      }).catch(() => {});
    }
  }
}
```

- [ ] **Step 2: Bridge the Tauri event and instantiate**

In `src/main.ts`:

1. Import:

```ts
import { GossipManager } from "./gossip";
```

2. In `init()`, after the drama manager block:

```ts
  const gossipManager = new GossipManager(flock);
  gossipManager.start();

  // Bridge the Rust app watcher onto the flock bus.
  listen<{ app: string; previousApp: string | null; previousDurationMs: number }>(
    "app-switched",
    (event) => {
      bus.emit("app-switched", event.payload);
      breakReminder.currentApp = event.payload.app;
    },
  );
```

- [ ] **Step 3: Name the app in break reminders**

In `src/break-reminder.ts`:

1. Add a public field to the class:

```ts
  /** Set from app-switched events; names the culprit app in reminders. */
  currentApp: string | null = null;
```

2. In `update(...)`, replace:

```ts
      const pool = MESSAGES[personality] || MESSAGES["snarky"];
      const msg = pool[Math.floor(Math.random() * pool.length)];
      bubble.show(msg, 10000);
```

with:

```ts
      const pool = MESSAGES[personality] || MESSAGES["snarky"];
      let msg = pool[Math.floor(Math.random() * pool.length)];
      if (this.currentApp) {
        msg += ` (${this.currentApp}, specifically.)`;
      }
      bubble.show(msg, 10000);
```

- [ ] **Step 4: Verify**

Run: `pnpm test && pnpm build`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add src/gossip.ts src/main.ts src/break-reminder.ts
git commit -m "Add app-aware gossip, instant reactions, and named break reminders"
```

---

### Task 11: Debug menu

**Files:**
- Modify: `src-tauri/src/lib.rs` (Debug submenu on tray + app menu)
- Modify: `src/main.ts` (listen for `debug-command`, dispatch)

**Interfaces:**
- Consumes: `DramaManager.forceFeud` (Task 7), `Flock.startSpectacle` (Task 9), `bus` (Task 1).
- Produces: Tauri event `"debug-command"` with a string payload, one of: `force-feud`, `spectacle:wolf`, `spectacle:ufo`, `spectacle:merchant`, `spectacle:balloon`, `spectacle:shearing`, `spectacle:showdown`, `spectacle:feast`, `app-switch`.

- [ ] **Step 1: Build the Debug submenu in Rust**

In `src-tauri/src/lib.rs` setup, before `let tray_menu = ...`, add:

```rust
            // Debug submenu — every item just emits a debug-command to the webview.
            const DEBUG_ITEMS: [(&str, &str); 9] = [
                ("debug_force_feud", "Force Feud"),
                ("debug_spectacle_wolf", "Spectacle: Wolf"),
                ("debug_spectacle_ufo", "Spectacle: UFO"),
                ("debug_spectacle_merchant", "Spectacle: Merchant"),
                ("debug_spectacle_balloon", "Spectacle: Balloon"),
                ("debug_spectacle_shearing", "Spectacle: Shearing"),
                ("debug_spectacle_showdown", "Spectacle: Showdown"),
                ("debug_spectacle_feast", "Spectacle: Feast"),
                ("debug_app_switch", "Simulate App Switch"),
            ];
            let debug_item_refs: Vec<tauri::menu::MenuItem<tauri::Wry>> = DEBUG_ITEMS
                .iter()
                .map(|(id, label)| {
                    tauri::menu::MenuItem::with_id(app, *id, *label, true, None::<&str>)
                })
                .collect::<Result<Vec<_>, _>>()?;
            let debug_items_dyn: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> = debug_item_refs
                .iter()
                .map(|i| i as &dyn tauri::menu::IsMenuItem<tauri::Wry>)
                .collect();
            let debug_submenu =
                tauri::menu::Submenu::with_items(app, "Debug", true, &debug_items_dyn)?;
```

Add `&debug_submenu` to the tray menu item list (before `&quit`) and to the app submenu item list (before `&app_menu_quit`).

Then add ONE arm to BOTH menu-event `match` statements (tray and app menu), before the `_ => {}` arm:

```rust
                        id if id.starts_with("debug_") => {
                            let cmd = match id {
                                "debug_force_feud" => "force-feud",
                                "debug_spectacle_wolf" => "spectacle:wolf",
                                "debug_spectacle_ufo" => "spectacle:ufo",
                                "debug_spectacle_merchant" => "spectacle:merchant",
                                "debug_spectacle_balloon" => "spectacle:balloon",
                                "debug_spectacle_shearing" => "spectacle:shearing",
                                "debug_spectacle_showdown" => "spectacle:showdown",
                                "debug_spectacle_feast" => "spectacle:feast",
                                "debug_app_switch" => "app-switch",
                                _ => return,
                            };
                            app.emit("debug-command", cmd).ok();
                        }
```

(If the closure's return type makes the bare `return` awkward in the tray handler, use `_ => ""` plus an `if !cmd.is_empty()` guard — match whichever compiles cleanly.)

- [ ] **Step 2: Dispatch in the frontend**

In `src/main.ts` `init()`, next to the other `listen(...)` calls:

```ts
  listen<string>("debug-command", (event) => {
    const cmd = event.payload;
    console.log("[co-sheep] debug-command:", cmd);
    if (cmd === "force-feud") {
      const key = dramaManager.forceFeud();
      flock.mainBubble.show(key ? `Feud forced: ${key}` : "No pair available to feud.", 4000);
    } else if (cmd.startsWith("spectacle:")) {
      const type = cmd.slice("spectacle:".length) as
        "wolf" | "ufo" | "merchant" | "balloon" | "shearing" | "showdown" | "feast";
      if (type === "showdown" || type === "feast") {
        const ids = flock.getCharacterIds().filter((id) => id !== "main");
        if (ids.length >= 2) flock.startSpectacle(type, [ids[0], ids[1]]);
      } else {
        flock.startSpectacle(type);
      }
    } else if (cmd === "app-switch") {
      bus.emit("app-switched", {
        app: "Xcode",
        previousApp: "Safari",
        previousDurationMs: 3_700_000, // >1h so gossip fires too
      });
    }
  });
```

- [ ] **Step 3: Verify compile, then verify visually**

Run: `pnpm test && pnpm build && (cd src-tauri && cargo check)`
Expected: clean.

Then run the app (`pnpm tauri dev`), open the tray Debug submenu, and trigger at least: Spectacle: Wolf (flock scatters, wolf crosses), Spectacle: UFO (a sheep levitates and drops), Force Feud (snipe dialogue fires within a minute or two), Simulate App Switch (a friend delivers an instant bit; gossip conversation about "hour 1" fires). Fix what doesn't behave before committing.

- [ ] **Step 4: Commit**

```bash
git add src-tauri/src/lib.rs src/main.ts
git commit -m "Add Debug menu for triggering drama and spectacles on demand"
```

---

### Task 12: Docs + final verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the new systems in README.md**

Add a section after "## Ambient Effects":

```markdown
## Living Desktop

The flock runs a social simulation — drama emerges from real relationship data, not scripts:

- **Drama engine** — relationships move through `neutral → warm → inseparable` or `tension → feud → reconciling` based on affinity, moods, and jealousy (pet one sheep too much and the others notice). Feuding sheep refuse group activities, storm apart, and snipe at each other; a mutual friend eventually attempts mediation.
- **Spectacles** — rare desktop events (~at most one a day, guaranteed within three): a wolf scatters the flock, a UFO abducts someone, a traveling merchant gifts an accessory, a balloon drifts by, shearing day embarrasses everyone. Long feuds can erupt into a high-noon showdown; reconciliations end in a feast.
- **App awareness** — the sheep see which app is frontmost (name only, no extra permissions, no AI calls) and react: instant quips on app switches, gossip about your measured habits ("Hour 3 in the terminal. Blink twice if you need help."), and break reminders that name the culprit app.
- **Debug menu** — tray → Debug lets you summon any spectacle or force a feud on demand.

Drama state persists in `~/.co-sheep/drama.json`; spectacle timing in `~/.co-sheep/spectacles.json`.
```

Also update the "It keeps daily tallies" bullet in "What it does" to mention app usage:

```markdown
- It keeps daily tallies ("that's the 5th time on Twitter today"), tracks which apps you actually use, and writes a markdown diary
```

- [ ] **Step 2: Full verification**

Run: `pnpm test && pnpm build && (cd src-tauri && cargo check)`
Expected: all clean.

Run the app once more (`pnpm tauri dev`) and let it idle for two minutes with 3+ friends: no console errors from the drama tick, gossip, or scheduler.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document Living Desktop systems in README"
```

---

## Execution order & dependencies

```
Task 1 (bus + vitest)
├── Task 2 (Rust living_state) ──┐
├── Task 3 (Rust app_watch) ─────┼── Task 7 (drama manager) ── Task 9 (spectacle scenes)
├── Task 4 (drama engine) ───────┤         │                        │
├── Task 5 (drama scripts) ──────┤         │                        │
└── Task 6 (Flock API) ──────────┘         └── Task 10 (gossip)     │
Task 8 (spectacle scheduler) ──────────────────────────────────────┘
Task 11 (debug menu) — after 7 & 9
Task 12 (docs) — last
```

Tasks 2, 3, 4, 5 are independent of each other and can be done in any order after Task 1. Task 8 only needs Task 1.

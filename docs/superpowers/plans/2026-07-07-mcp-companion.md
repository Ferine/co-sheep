# MCP Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Claude Code session drive the co-sheep desktop companion over MCP — Claude reports facts (task, progress, milestones), the sheep's personality engine renders the whimsy.

**Architecture:** The Tauri backend hosts an `rmcp` streamable-HTTP MCP server on `127.0.0.1:4917`. Fact-shaped tool calls mutate a shared `SessionState` and `emit("sheep-session", …)`. A frontend `McpCompanion` translates each fact into a tsundere line + animation and drives the existing sheep/bubble/flock. The `say` tool reuses the existing `sheep-commentary` rail directly.

**Tech Stack:** Rust (Tauri 2, tokio, rmcp 2.1, axum), TypeScript (Vite), vitest.

## Global Constraints

- Tools mutate **display state only** — no filesystem, shell, or exec surface, ever.
- Server binds `127.0.0.1` only. Default port `4917`. Optional bearer token.
- Bind/startup failure must **log and disable**, never panic the app.
- All string args truncated to **500 chars** at a char boundary (mirrors `frontend_log`). `progress` clamped to `0.0..=1.0`.
- Quip selection is **deterministic and unit-tested** (static pools, injectable selector). No AI generation in v1.
- New event name is `sheep-session`; do **not** overload `sheep-commentary`.
- Reuse existing systems: `flock.onChatReply()`, `flock.mainBubble`, `Sheep.playAnimation()`. No parallel animation/reaction vocabulary.
- Follow existing config pattern: `SheepConfig` fields with `#[serde(default = …)]`.

## Deferred / simplified from spec (call-outs)

- **Diegetic progress states** (pacing / counting / sweat): v1 renders progress as a bubble line + optional bounce. Hooking the existing `idle_counting` state is a future enhancement (requires exposing a public state trigger on `Sheep`).
- **On-device AI-generated quips:** v1 uses static pools. `apple_ai.rs` generation is a later upgrade.
- No HUD window (per spec). `SessionState` is built so a HUD could subscribe later.

---

## File Structure

- Create `src-tauri/src/mcp.rs` — MCP server: `SessionState`/`Health` core (pure, testable), `SheepMcp` tool server, `serve()`.
- Modify `src-tauri/src/lib.rs` — `mod mcp;`, `.manage(mcp::SessionStore::default())`, spawn `mcp::serve` in `setup`.
- Modify `src-tauri/src/onboarding.rs` — add `mcp_enabled` / `mcp_port` / `mcp_token` to `SheepConfig`.
- Modify `src-tauri/Cargo.toml` — add `rmcp`, `axum`.
- Create `src/mcp-companion.ts` — `pickReaction()` (pure) + `McpCompanion` (listens `sheep-session`, drives flock).
- Create `src/mcp-companion.test.ts` — determinism tests for `pickReaction`.
- Modify `src/types.ts` — add `SessionEvent`.
- Modify `src/main.ts` — construct + start `McpCompanion`.
- Modify `README.md` — MCP connect section + `.mcp.json` snippet.

---

## Task 1: Config surface + dependencies

**Files:**
- Modify: `src-tauri/Cargo.toml` (`[dependencies]`)
- Modify: `src-tauri/src/onboarding.rs:34-84` (`SheepConfig` + defaults + `Default`)
- Test: `src-tauri/src/onboarding.rs` (inline `#[cfg(test)]`)

**Interfaces:**
- Produces: `SheepConfig.mcp_enabled: bool`, `SheepConfig.mcp_port: u16`, `SheepConfig.mcp_token: String`; defaults `true` / `4917` / `""`.

- [ ] **Step 1: Add dependencies to `Cargo.toml`**

Under `[dependencies]` add:

```toml
rmcp = { version = "2.1", features = ["server", "transport-streamable-http-server", "macros"] }
axum = "0.8"
```

(rmcp re-exports `schemars`; no separate schemars dep. `tokio`/`serde`/`serde_json` are already present.)

- [ ] **Step 2: Write the failing test** (append to `onboarding.rs`)

```rust
#[cfg(test)]
mod mcp_config_tests {
    use super::*;

    #[test]
    fn defaults_enable_mcp_on_4917() {
        let c = SheepConfig::default();
        assert!(c.mcp_enabled);
        assert_eq!(c.mcp_port, 4917);
        assert_eq!(c.mcp_token, "");
    }

    #[test]
    fn config_missing_mcp_fields_deserializes_with_defaults() {
        let json = r#"{"name":"S","personality":"snarky","interval_secs":150}"#;
        let c: SheepConfig = serde_json::from_str(json).unwrap();
        assert!(c.mcp_enabled);
        assert_eq!(c.mcp_port, 4917);
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd src-tauri && cargo test mcp_config_tests`
Expected: FAIL — `no field mcp_enabled on type SheepConfig`.

- [ ] **Step 4: Add the fields + defaults**

In `SheepConfig` (after `accessories`):

```rust
    #[serde(default = "default_mcp_enabled")]
    pub mcp_enabled: bool,
    #[serde(default = "default_mcp_port")]
    pub mcp_port: u16,
    #[serde(default)]
    pub mcp_token: String,
```

Add the default fns near the other `default_*` fns:

```rust
fn default_mcp_enabled() -> bool {
    true
}

fn default_mcp_port() -> u16 {
    4917
}
```

In `impl Default for SheepConfig`, add to the struct literal:

```rust
            mcp_enabled: true,
            mcp_port: 4917,
            mcp_token: String::new(),
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd src-tauri && cargo test mcp_config_tests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add src-tauri/Cargo.toml src-tauri/Cargo.lock src-tauri/src/onboarding.rs
git commit -m "feat(mcp): add mcp config fields (enabled/port/token) + deps"
```

---

## Task 2: Session state core (pure, testable)

**Files:**
- Create: `src-tauri/src/mcp.rs`
- Test: same file (inline `#[cfg(test)]`)

**Interfaces:**
- Produces:
  - `enum Health { Good, Degraded, Failing }` with `fn as_str(&self) -> &'static str`.
  - `struct SessionState { active: bool, task: Option<String>, progress: Option<f32>, health: Health }` (derive `Default`).
  - `enum Fact { Begin{task:Option<String>}, Task{label:String}, Progress{fraction:f32}, Milestone{kind:String, detail:Option<String>}, End{summary:Option<String>} }`
  - `struct SessionEvent { kind:String, task:Option<String>, progress:Option<f32>, milestone:Option<String>, detail:Option<String>, health:String }` (derive `Serialize, Clone`).
  - `fn apply(state:&mut SessionState, fact:Fact) -> SessionEvent` — mutates state, returns the event to emit.
  - `fn truncate(s:&str, max:usize) -> String` — char-boundary safe.
  - `fn clamp01(f:f32) -> f32`.

- [ ] **Step 1: Write the failing test** (`src-tauri/src/mcp.rs`, start the file with the test so it drives the types)

```rust
//! MCP companion server: fact-shaped tools drive the sheep.

use serde::Serialize;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn begin_marks_active_and_good() {
        let mut s = SessionState::default();
        let ev = apply(&mut s, Fact::Begin { task: Some("wire mpls".into()) });
        assert!(s.active);
        assert_eq!(s.task.as_deref(), Some("wire mpls"));
        assert_eq!(s.health, Health::Good);
        assert_eq!(ev.kind, "begin");
        assert_eq!(ev.health, "good");
    }

    #[test]
    fn milestone_failed_sets_failing() {
        let mut s = SessionState::default();
        apply(&mut s, Fact::Begin { task: None });
        let ev = apply(&mut s, Fact::Milestone { kind: "failed".into(), detail: Some("3 tests".into()) });
        assert_eq!(s.health, Health::Failing);
        assert_eq!(ev.milestone.as_deref(), Some("failed"));
        assert_eq!(ev.health, "failing");
    }

    #[test]
    fn milestone_done_recovers_to_good() {
        let mut s = SessionState { health: Health::Failing, active: true, ..Default::default() };
        apply(&mut s, Fact::Milestone { kind: "done".into(), detail: None });
        assert_eq!(s.health, Health::Good);
    }

    #[test]
    fn blocked_is_degraded() {
        let mut s = SessionState::default();
        apply(&mut s, Fact::Milestone { kind: "blocked".into(), detail: None });
        assert_eq!(s.health, Health::Degraded);
    }

    #[test]
    fn progress_is_clamped_and_recorded() {
        let mut s = SessionState::default();
        let ev = apply(&mut s, Fact::Progress { fraction: 1.7 });
        assert_eq!(s.progress, Some(1.0));
        assert_eq!(ev.progress, Some(1.0));
        apply(&mut s, Fact::Progress { fraction: -0.2 });
        assert_eq!(s.progress, Some(0.0));
    }

    #[test]
    fn end_deactivates() {
        let mut s = SessionState { active: true, ..Default::default() };
        let ev = apply(&mut s, Fact::End { summary: None });
        assert!(!s.active);
        assert_eq!(ev.kind, "end");
    }

    #[test]
    fn truncate_respects_char_boundary() {
        let s = "æøå".repeat(400); // 1200 chars, 2 bytes each
        let t = truncate(&s, 500);
        assert!(t.chars().count() <= 500);
        assert!(s.starts_with(&t) || t.len() < s.len());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src-tauri && cargo test --lib mcp::tests`
Expected: FAIL — types/functions not defined. (Add `mod mcp;` temporarily to `lib.rs` if the module isn't compiled yet; Task 3 wires it permanently.)

- [ ] **Step 3: Write the implementation** (above the `#[cfg(test)]` block)

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Health {
    #[default]
    Good,
    Degraded,
    Failing,
}

impl Health {
    pub fn as_str(&self) -> &'static str {
        match self {
            Health::Good => "good",
            Health::Degraded => "degraded",
            Health::Failing => "failing",
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct SessionState {
    pub active: bool,
    pub task: Option<String>,
    pub progress: Option<f32>,
    pub health: Health,
}

pub enum Fact {
    Begin { task: Option<String> },
    Task { label: String },
    Progress { fraction: f32 },
    Milestone { kind: String, detail: Option<String> },
    End { summary: Option<String> },
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionEvent {
    pub kind: String,
    pub task: Option<String>,
    pub progress: Option<f32>,
    pub milestone: Option<String>,
    pub detail: Option<String>,
    pub health: String,
}

pub fn clamp01(f: f32) -> f32 {
    f.clamp(0.0, 1.0)
}

pub fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    s.chars().take(max).collect()
}

pub fn apply(state: &mut SessionState, fact: Fact) -> SessionEvent {
    let (kind, milestone, detail) = match fact {
        Fact::Begin { task } => {
            state.active = true;
            state.health = Health::Good;
            state.progress = None;
            state.task = task.map(|t| truncate(&t, 500));
            ("begin", None, None)
        }
        Fact::Task { label } => {
            state.task = Some(truncate(&label, 500));
            ("task", None, None)
        }
        Fact::Progress { fraction } => {
            state.progress = Some(clamp01(fraction));
            ("progress", None, None)
        }
        Fact::Milestone { kind, detail } => {
            state.health = match kind.as_str() {
                "failed" => Health::Failing,
                "done" => Health::Good,
                _ => Health::Degraded, // blocked / waiting_on_you
            };
            let d = detail.map(|d| truncate(&d, 500));
            ("milestone", Some(truncate(&kind, 32)), d)
        }
        Fact::End { summary } => {
            state.active = false;
            ("end", None, summary.map(|s| truncate(&s, 500)))
        }
    };
    SessionEvent {
        kind: kind.to_string(),
        task: state.task.clone(),
        progress: state.progress,
        milestone,
        detail,
        health: state.health.as_str().to_string(),
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd src-tauri && cargo test --lib mcp::tests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add src-tauri/src/mcp.rs src-tauri/src/lib.rs
git commit -m "feat(mcp): session state reducer + event core (tested)"
```

---

## Task 3: MCP server, tools, and app wiring

**Files:**
- Modify: `src-tauri/src/mcp.rs` (add server + `serve` + `check_auth`)
- Modify: `src-tauri/src/lib.rs:610-612` (`mod mcp;`, `.manage`) and `:658` (`setup`)
- Test: `src-tauri/src/mcp.rs` (`check_auth` unit test) + manual checklist

**Interfaces:**
- Consumes: `apply`, `SessionState`, `SessionEvent` (Task 2); `onboarding::load_config` (Task 1).
- Produces: `struct SessionStore(pub std::sync::Mutex<SessionState>)` (derive `Default`); `pub async fn serve(app: tauri::AppHandle, port: u16, token: String) -> Result<(), Box<dyn std::error::Error + Send + Sync>>`; `fn check_auth(header: Option<&str>, expected: &str) -> bool`.
- Emits Tauri events: `sheep-session` (`SessionEvent`) for all facts; `sheep-commentary` (string) for `say`.

> **rmcp import note:** the type/macro **names** below (`StreamableHttpService`, `LocalSessionManager`, `ToolRouter`, `Parameters`, `CallToolResult`, `Content`, `ServerHandler`, `ServerInfo`, `#[tool_router]`, `#[tool]`, `#[tool_handler]`) are stable in rmcp 2.1. Only **module paths** occasionally shift between releases. Do Step 1 first: `cargo build` and let the compiler pin exact paths (docs.rs/rmcp/2.1.0). Do not proceed to tools until the skeleton compiles.

- [ ] **Step 1: Add `SessionStore`, server skeleton, and `serve` — get it to compile**

Add imports at the top of `mcp.rs`:

```rust
use rmcp::{
    handler::server::tool::{Parameters, ToolRouter},
    model::{CallToolResult, Content, Implementation, ServerCapabilities, ServerInfo},
    tool, tool_handler, tool_router,
    transport::streamable_http_server::{
        session::local::LocalSessionManager, StreamableHttpService,
    },
    ErrorData as McpError, ServerHandler,
};
use rmcp::schemars;
use tauri::{Emitter, Manager};
```

Add the shared store + server struct:

```rust
#[derive(Default)]
pub struct SessionStore(pub std::sync::Mutex<SessionState>);

#[derive(Clone)]
pub struct SheepMcp {
    app: tauri::AppHandle,
    tool_router: ToolRouter<SheepMcp>,
}

impl SheepMcp {
    fn new(app: tauri::AppHandle) -> Self {
        Self { app, tool_router: Self::tool_router() }
    }

    /// Lock the shared store, apply a fact, emit the resulting event.
    fn commit(&self, fact: Fact) {
        let store = self.app.state::<SessionStore>();
        let ev = {
            let mut guard = store.0.lock().unwrap();
            apply(&mut guard, fact)
        };
        self.app.emit("sheep-session", &ev).ok();
    }
}

#[tool_handler]
impl ServerHandler for SheepMcp {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            capabilities: ServerCapabilities::builder().enable_tools().build(),
            server_info: Implementation {
                name: "co-sheep".to_string(),
                version: env!("CARGO_PKG_VERSION").to_string(),
                ..Default::default()
            },
            instructions: Some(
                "Drive the co-sheep desktop companion. Report facts about your work \
                 (session_begin, set_task, progress, milestone, session_end); the sheep \
                 supplies the personality. Use `say` only to force a specific line."
                    .to_string(),
            ),
            ..Default::default()
        }
    }
}

pub fn check_auth(header: Option<&str>, expected: &str) -> bool {
    if expected.is_empty() {
        return true; // no token configured → loopback binding is the control
    }
    header == Some(&format!("Bearer {expected}"))
}

pub async fn serve(
    app: tauri::AppHandle,
    port: u16,
    token: String,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let service = StreamableHttpService::new(
        move || Ok(SheepMcp::new(app.clone())),
        LocalSessionManager::default().into(),
        Default::default(),
    );
    // Optional bearer auth. Empty token → check_auth passes everything (loopback
    // binding is then the only control). Non-empty → every request must match.
    let expected = std::sync::Arc::new(token);
    let router = axum::Router::new()
        .nest_service("/mcp", service)
        .layer(axum::middleware::from_fn(
            move |req: axum::extract::Request, next: axum::middleware::Next| {
                let expected = expected.clone();
                async move {
                    let header = req
                        .headers()
                        .get(axum::http::header::AUTHORIZATION)
                        .and_then(|v| v.to_str().ok());
                    if check_auth(header, &expected) {
                        Ok(next.run(req).await)
                    } else {
                        Err(axum::http::StatusCode::UNAUTHORIZED)
                    }
                }
            },
        ));
    let addr = format!("127.0.0.1:{port}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    log!("mcp", "server ready at http://{}/mcp", addr);
    axum::serve(listener, router).await?;
    Ok(())
}
```

Run: `cd src-tauri && cargo build`
Expected: compiles (fix rmcp module paths here if the compiler flags any; names are stable).

- [ ] **Step 2: Add the tools** to the `#[tool_router] impl SheepMcp` block. Put this block right after `impl SheepMcp { fn new … fn commit … }` (it re-opens `impl` with the macro):

```rust
#[derive(serde::Deserialize, schemars::JsonSchema)]
pub struct SayArgs {
    #[schemars(description = "The exact line for the sheep to say")]
    text: String,
    #[schemars(description = "Optional animation: bounce|spin|backflip|headshake|zoom|vibrate")]
    animation: Option<String>,
}

#[derive(serde::Deserialize, schemars::JsonSchema)]
pub struct BeginArgs {
    #[schemars(description = "Optional label for the task you're starting")]
    task: Option<String>,
}

#[derive(serde::Deserialize, schemars::JsonSchema)]
pub struct TaskArgs {
    #[schemars(description = "Short label of the current task")]
    label: String,
}

#[derive(serde::Deserialize, schemars::JsonSchema)]
pub struct ProgressArgs {
    #[schemars(description = "Progress fraction 0.0..1.0")]
    fraction: f32,
}

#[derive(serde::Deserialize, schemars::JsonSchema)]
pub struct MilestoneArgs {
    #[schemars(description = "One of: done | failed | blocked | waiting_on_you")]
    kind: String,
    #[schemars(description = "Optional detail, e.g. '3 tests failed'")]
    detail: Option<String>,
}

#[derive(serde::Deserialize, schemars::JsonSchema)]
pub struct EndArgs {
    #[schemars(description = "Optional closing summary")]
    summary: Option<String>,
}

fn ok() -> Result<CallToolResult, McpError> {
    Ok(CallToolResult::success(vec![Content::text("ok")]))
}

#[tool_router]
impl SheepMcp {
    #[tool(description = "Clock in: a work session is starting. The sheep perks up.")]
    async fn session_begin(&self, Parameters(a): Parameters<BeginArgs>) -> Result<CallToolResult, McpError> {
        self.commit(Fact::Begin { task: a.task });
        ok()
    }

    #[tool(description = "Set the current task label the sheep is watching.")]
    async fn set_task(&self, Parameters(a): Parameters<TaskArgs>) -> Result<CallToolResult, McpError> {
        self.commit(Fact::Task { label: a.label });
        ok()
    }

    #[tool(description = "Report progress on the current task, 0.0 to 1.0.")]
    async fn progress(&self, Parameters(a): Parameters<ProgressArgs>) -> Result<CallToolResult, McpError> {
        self.commit(Fact::Progress { fraction: a.fraction });
        ok()
    }

    #[tool(description = "Report a milestone: done | failed | blocked | waiting_on_you.")]
    async fn milestone(&self, Parameters(a): Parameters<MilestoneArgs>) -> Result<CallToolResult, McpError> {
        self.commit(Fact::Milestone { kind: a.kind, detail: a.detail });
        ok()
    }

    #[tool(description = "Force the sheep to say a specific line (escape hatch).")]
    async fn say(&self, Parameters(a): Parameters<SayArgs>) -> Result<CallToolResult, McpError> {
        let ev = crate::vision_commentary(truncate(&a.text, 500), a.animation);
        self.app.emit("sheep-commentary", &ev).ok();
        ok()
    }

    #[tool(description = "Clock out: the work session is ending.")]
    async fn session_end(&self, Parameters(a): Parameters<EndArgs>) -> Result<CallToolResult, McpError> {
        self.commit(Fact::End { summary: a.summary });
        ok()
    }
}
```

Add a small helper to `lib.rs` (re-uses the existing `CommentaryEvent` shape the bubble already understands). Near the top of `lib.rs`:

```rust
/// Build a `sheep-commentary` payload the speech bubble already renders.
pub(crate) fn vision_commentary(text: String, animation: Option<String>) -> serde_json::Value {
    serde_json::json!({ "text": text, "animation": animation })
}
```

Run: `cd src-tauri && cargo build`
Expected: compiles.

- [ ] **Step 3: Write the failing `check_auth` test** (add to the `#[cfg(test)] mod tests` in `mcp.rs`)

```rust
    #[test]
    fn auth_open_when_no_token() {
        assert!(check_auth(None, ""));
        assert!(check_auth(Some("anything"), ""));
    }

    #[test]
    fn auth_requires_matching_bearer() {
        assert!(check_auth(Some("Bearer s3cret"), "s3cret"));
        assert!(!check_auth(Some("Bearer wrong"), "s3cret"));
        assert!(!check_auth(None, "s3cret"));
    }
```

Run: `cd src-tauri && cargo test --lib mcp::tests::auth`
Expected: PASS (the `check_auth` fn from Step 1 already satisfies these).

- [ ] **Step 4: Wire into `lib.rs`**

At the top with the other `mod` lines (make the Task 2 temporary `mod mcp;` permanent):

```rust
mod mcp;
```

In `run()`, add to the builder chain right after `.manage(cursor::SheepHitState::new())`:

```rust
        .manage(mcp::SessionStore::default())
```

Inside `.setup(|app| { … })`, after the existing startup logging, add:

```rust
            // MCP companion server — Claude Code drives the sheep over loopback.
            let cfg = onboarding::load_config().unwrap_or_default();
            if cfg.mcp_enabled {
                let mcp_app = app.handle().clone();
                let port = cfg.mcp_port;
                let token = cfg.mcp_token.clone();
                tauri::async_runtime::spawn(async move {
                    if let Err(e) = mcp::serve(mcp_app, port, token).await {
                        log!("mcp", "error: server disabled: {}", e);
                    }
                });
            } else {
                log!("mcp", "disabled via config");
            }
```

Run: `cd src-tauri && cargo build`
Expected: compiles.

- [ ] **Step 5: Manual verification** (no automated harness for the live protocol)

```bash
# terminal 1
pnpm tauri dev
# terminal 2
claude mcp add --transport http co-sheep http://127.0.0.1:4917/mcp
claude          # then, in the session:
#   "use the co-sheep milestone tool with kind=failed detail='3 tests'"
```

Confirm: dev log prints `[mcp] server ready …`; the tool call returns `ok`; a `sheep-session` event fires (visible in the `[web]` forwarded console once Task 4 lands). Then:
- Occupy the port (`nc -l 127.0.0.1 4917 &`) and relaunch → app boots, logs `[mcp] error: server disabled`, sheep still works.

- [ ] **Step 6: Commit**

```bash
git add src-tauri/src/mcp.rs src-tauri/src/lib.rs
git commit -m "feat(mcp): rmcp streamable-http server + fact tools, wired into setup"
```

---

## Task 4: Frontend companion (fact → whimsy)

**Files:**
- Modify: `src/types.ts` (add `SessionEvent`)
- Create: `src/mcp-companion.ts`
- Create: `src/mcp-companion.test.ts`
- Modify: `src/main.ts:91-105` (construct + start companion)

**Interfaces:**
- Consumes: `Flock` (`flock.mainBubble.show`, `flock.onChatReply`), `SheepAnimation` from `types.ts`, backend `sheep-session` event.
- Produces:
  - `interface SessionEvent { kind:string; task:string|null; progress:number|null; milestone:string|null; detail:string|null; health:string }`
  - `function pickReaction(ev: SessionEvent, rng?: () => number): { text: string; animation: SheepAnimation | null }`
  - `class McpCompanion { constructor(flock: Flock); start(): void; stop(): void }`

- [ ] **Step 1: Add the `SessionEvent` type** to `src/types.ts` (after `CommentaryEvent`)

```typescript
export interface SessionEvent {
  kind: string;              // begin | task | progress | milestone | end
  task: string | null;
  progress: number | null;   // 0..1
  milestone: string | null;  // done | failed | blocked | waiting_on_you
  detail: string | null;
  health: string;            // good | degraded | failing
}
```

- [ ] **Step 2: Write the failing test** (`src/mcp-companion.test.ts`)

```typescript
import { describe, it, expect } from "vitest";
import { pickReaction } from "./mcp-companion";
import { SessionEvent } from "./types";

const ev = (o: Partial<SessionEvent>): SessionEvent => ({
  kind: "milestone", task: null, progress: null,
  milestone: null, detail: null, health: "good", ...o,
});

const first = () => 0; // deterministic: always the first pool entry

describe("pickReaction", () => {
  it("failed milestone -> headshake + a snarky failure line", () => {
    const r = pickReaction(ev({ milestone: "failed", health: "failing" }), first);
    expect(r.animation).toBe("headshake");
    expect(r.text.length).toBeGreaterThan(0);
  });

  it("done milestone -> bounce", () => {
    const r = pickReaction(ev({ milestone: "done", health: "good" }), first);
    expect(r.animation).toBe("bounce");
  });

  it("blocked milestone -> vibrate", () => {
    const r = pickReaction(ev({ milestone: "blocked", health: "degraded" }), first);
    expect(r.animation).toBe("vibrate");
  });

  it("begin -> a greeting line, no crash", () => {
    const r = pickReaction(ev({ kind: "begin", milestone: null }), first);
    expect(r.text.length).toBeGreaterThan(0);
  });

  it("high progress announces near-done", () => {
    const r = pickReaction(ev({ kind: "progress", progress: 0.95, milestone: null }), first);
    expect(r.text.length).toBeGreaterThan(0);
  });

  it("rng selects within the pool deterministically", () => {
    const a = pickReaction(ev({ milestone: "failed" }), () => 0);
    const b = pickReaction(ev({ milestone: "failed" }), () => 0.999);
    expect(a.text).not.toBe(b.text); // different indices → different lines
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pnpm test mcp-companion`
Expected: FAIL — `pickReaction` not defined.

- [ ] **Step 4: Implement `src/mcp-companion.ts`**

```typescript
import { listen } from "@tauri-apps/api/event";
import { Flock } from "./flock";
import { SessionEvent, SheepAnimation } from "./types";

// Static tsundere pools — deterministic, testable. One consistent voice.
const POOLS = {
  clock_in: [
    "Oh. We're working now, are we?",
    "Tch. Fine. I was watching anyway.",
    "Back at it. Don't expect applause.",
  ],
  new_task: [
    "This again? Predictable.",
    "Hm. Watching you wrestle with this.",
    "Go on then. I'm observing.",
  ],
  progress_mid: [
    "Halfway. Don't get comfortable.",
    "Still going. Barely.",
    "Adequate pace. For you.",
  ],
  progress_high: [
    "Almost there. I counted.",
    "Nearly done. Try not to break it now.",
    "So close. Don't fumble it.",
  ],
  done: [
    "...Fine. That worked. Don't read into it.",
    "Hmph. Not terrible. For a human.",
    "It's done. I'm as surprised as you.",
  ],
  failed: [
    "Tch. Predictable.",
    "Saw that coming three commits ago.",
    "That's the third time. I'm keeping count.",
  ],
  blocked: [
    "Your move, sorcerer.",
    "Stuck? Obviously.",
    "I'll wait. Not that I mind.",
  ],
  waiting: [
    "*taps foot* Any day now.",
    "Waiting on you. As usual.",
    "Well? I'm right here.",
  ],
  clock_out: [
    "Done already? Hmph.",
    "Off you go. I'll be here.",
    "That's a wrap. Don't miss me.",
  ],
} as const;

function pick(pool: readonly string[], rng: () => number): string {
  return pool[Math.min(pool.length - 1, Math.floor(rng() * pool.length))];
}

export function pickReaction(
  ev: SessionEvent,
  rng: () => number = Math.random,
): { text: string; animation: SheepAnimation | null } {
  if (ev.kind === "milestone") {
    switch (ev.milestone) {
      case "failed":
        return { text: pick(POOLS.failed, rng), animation: "headshake" };
      case "done":
        return { text: pick(POOLS.done, rng), animation: "bounce" };
      case "blocked":
        return { text: pick(POOLS.blocked, rng), animation: "vibrate" };
      case "waiting_on_you":
        return { text: pick(POOLS.waiting, rng), animation: "vibrate" };
    }
  }
  if (ev.kind === "begin") return { text: pick(POOLS.clock_in, rng), animation: "bounce" };
  if (ev.kind === "end") return { text: pick(POOLS.clock_out, rng), animation: null };
  if (ev.kind === "task") return { text: pick(POOLS.new_task, rng), animation: null };
  if (ev.kind === "progress") {
    const p = ev.progress ?? 0;
    return { text: pick(p >= 0.9 ? POOLS.progress_high : POOLS.progress_mid, rng), animation: null };
  }
  return { text: pick(POOLS.new_task, rng), animation: null };
}

/** Listens for backend `sheep-session` facts and renders them through the flock. */
export class McpCompanion {
  private unlisten: (() => void) | null = null;

  constructor(private flock: Flock) {}

  start() {
    listen<SessionEvent>("sheep-session", (event) => {
      try {
        const { text, animation } = pickReaction(event.payload);
        this.flock.mainBubble.show(text, 6000);
        this.flock.onChatReply(animation); // animates main sheep + friend reactions
      } catch (e) {
        console.error("[co-sheep] mcp-companion render failed:", e);
      }
    }).then((fn) => {
      this.unlisten = fn;
    });
  }

  stop() {
    if (this.unlisten) {
      this.unlisten();
      this.unlisten = null;
    }
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pnpm test mcp-companion`
Expected: PASS (6 tests).

- [ ] **Step 6: Wire into `main.ts`** (after `gossipManager.start();` around line 105)

Add the import at the top with the other imports:

```typescript
import { McpCompanion } from "./mcp-companion";
```

And after the gossip manager is started:

```typescript
  const mcpCompanion = new McpCompanion(flock);
  mcpCompanion.start();
  console.log("[co-sheep] MCP companion listening for sheep-session events");
```

- [ ] **Step 7: Typecheck + full test run**

Run: `pnpm build` (runs `tsc`) and `pnpm test`
Expected: no type errors; all tests pass.

- [ ] **Step 8: Commit**

```bash
git add src/types.ts src/mcp-companion.ts src/mcp-companion.test.ts src/main.ts
git commit -m "feat(mcp): frontend companion translates facts to sheep whimsy"
```

---

## Task 5: Documentation

**Files:**
- Modify: `README.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Add an MCP section to `README.md`** (after the "Interactions" section)

````markdown
## MCP: Claude Code narrates through the sheep

co-sheep runs a local MCP server (`127.0.0.1:4917`) while the app is open. Point
Claude Code at it and your progress reports come out of the sheep's mouth — in
the sheep's voice, not Claude's.

Connect once:

```bash
claude mcp add --transport http co-sheep http://127.0.0.1:4917/mcp
```

Or add to `.mcp.json`:

```json
{
  "mcpServers": {
    "co-sheep": { "type": "http", "url": "http://127.0.0.1:4917/mcp" }
  }
}
```

Tools: `session_begin`, `set_task`, `progress`, `milestone` (`done`/`failed`/
`blocked`/`waiting_on_you`), `say`, `session_end`. You report facts; the sheep
supplies the snark, animations, and mood. Tools only affect what the sheep
displays — no filesystem or shell access.

Config lives in `~/.co-sheep/config.json`: `mcp_enabled` (default `true`),
`mcp_port` (default `4917`), `mcp_token` (optional bearer token; add
`--header "Authorization: Bearer <token>"` to the connect command if set).
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(mcp): how to connect Claude Code to the sheep"
```

---

## Self-Review

**Spec coverage:**
- Embedded rmcp HTTP server on loopback → Task 3 (`serve`, bind `127.0.0.1`).
- SessionState (active/task/progress/health) single owner → Task 2 core + Task 3 `SessionStore` managed.
- Facts-in tools (begin/set_task/progress/milestone/say/session_end) → Task 3.
- Health → mood mapping → Task 2 `apply` (health) + Task 4 pool tone.
- Diegetic sheep-only rendering, no HUD → Task 4 (`flock.mainBubble` + `onChatReply`).
- `say` reuses `sheep-commentary` → Task 3 `say` tool.
- Static quip pools, deterministic + tested → Task 4.
- Config `mcp_enabled`/`mcp_port`/`mcp_token` → Task 1.
- 500-char truncation, progress clamp → Task 2 (`truncate`, `clamp01`).
- Bind failure logs + disables, no panic → Task 3 Step 4 (`if let Err … log`).
- Loopback + optional token → Task 3 (`check_auth`, bind addr).
- Rust + TS tests → Tasks 1, 2, 3 (check_auth), 4.
- README + `.mcp.json` → Task 5.
- Safety: display-state-only tools → enforced by tool set (no fs/shell tools defined).

**Placeholder scan:** none — every code step is complete. The rmcp import note is a compile-verify step (Step 1 of Task 3), not a deferred implementation.

**Type consistency:** `SessionEvent` fields identical in Rust (`mcp.rs`) and TS (`types.ts`): `kind, task, progress, milestone, detail, health`. `Fact` variants ↔ tool calls ↔ `apply` all aligned. `pickReaction` signature matches its test and its `McpCompanion` caller. `serve(app, port, token)` matches the `lib.rs` spawn call.

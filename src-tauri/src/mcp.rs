//! MCP companion server: fact-shaped tools drive the sheep.

use rmcp::{
    handler::server::tool::ToolRouter,
    handler::server::wrapper::Parameters,
    model::{CallToolResult, ContentBlock, Implementation, ServerCapabilities, ServerInfo},
    tool, tool_handler, tool_router,
    transport::streamable_http_server::{
        session::local::LocalSessionManager, StreamableHttpService,
    },
    ErrorData as McpError, ServerHandler,
};
use rmcp::schemars;
use serde::Serialize;
use tauri::{Emitter, Manager};

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
    Ok(CallToolResult::success(vec![ContentBlock::text("ok")]))
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

#[tool_handler(router = self.tool_router)]
impl ServerHandler for SheepMcp {
    fn get_info(&self) -> ServerInfo {
        // `ServerInfo`/`Implementation` are `#[non_exhaustive]` in rmcp 2.1 — build
        // via their constructors rather than struct-literal syntax (brief's shape
        // used a literal, which the compiler rejects with E0639 for external crates).
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("co-sheep", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "Drive the co-sheep desktop companion. Report facts about your work \
                 (session_begin, set_task, progress, milestone, session_end); the sheep \
                 supplies the personality. Use `say` only to force a specific line.",
            )
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
        assert!(s.starts_with(&t));
    }

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
}

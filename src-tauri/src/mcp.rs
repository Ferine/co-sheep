//! MCP companion server: fact-shaped tools drive the sheep.

use serde::Serialize;

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

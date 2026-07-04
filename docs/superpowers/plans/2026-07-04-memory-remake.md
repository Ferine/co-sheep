# Memory Remake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the sheep's memory situational recall (conviction × recency × relevance), a daily model-driven reflection pass with historical backfill, canonical topic keys, and friend chats that read the social memory they write.

**Architecture:** Evolve-in-place per `docs/superpowers/specs/2026-07-04-memory-remake-design.md`. Storage stays `opinions.json` / `journal/*.md` / `friends/*.json`. New pure scoring functions in `memory.rs`; a new `reflect.rs` module holds the op protocol (model proposes, Rust disposes) and a background loop that runs daily reflection plus throttled backfill when the vision pipeline is idle.

**Tech Stack:** Rust (Tauri 2 backend in `src-tauri/`), chrono, serde/serde_json, tokio. Frontend TypeScript touched only to pass friend ids. On-device model via the existing `apple_ai` sidecar bridge.

## Global Constraints

- No new Cargo or npm dependencies.
- On-device model context is ~4k tokens — every prompt input must be explicitly budgeted (constants below).
- Spec constants, verbatim: recency half-life **14 days**; relevance boost cap **2.0**; context selection **top 20** opinions; prune **≤ 3 per run**, only opinions with `times_seen ≤ 2` **or** idle **> 21 days**; add **≤ 5 per run**; backfill prune **forbidden**; backfill throttle **one journal file per 180 s, idle-only**; friend chat context **≤ 300 chars per participant**.
- Unparseable `last_seen` ⇒ recency weight **0.5**; counts as *not idle* for prune eligibility.
- New `SheepBrain` fields must be `#[serde(default)]` — existing `opinions.json` files load unchanged.
- All Rust tests must be pure (no `CO_SHEEP_HOME`, no env vars, no HOME dirs) — `friend_memory`'s existing test already owns the env-var pattern and parallel tests would race it. Testable functions take explicit data or `&Path` parameters; thin wrappers resolve real paths.
- Rust tests run from `src-tauri/`: `cargo test`. Frontend checks: `pnpm tsc --noEmit && pnpm vitest run`.
- Commit style: short imperative subject, no prefix (match `git log`), each ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Existing behavior that must not change: opinion context line format `- [topic] text (seen N times, last: …)`; journal file format; friend affinity mechanics.

---

### Task 1: Opinion scoring and selection (`memory.rs`)

**Files:**
- Modify: `src-tauri/src/memory.rs` (add scoring section after the `Opinion`/`SheepBrain` definitions, around line 90)

**Interfaces:**
- Consumes: existing `pub struct Opinion` (fields `topic`, `opinion`, `times_seen: u32`, `first_seen`, `last_seen`, `category`, all `pub`).
- Produces: `pub fn select_opinions<'a>(opinions: &'a [Opinion], query: Option<&str>, today: chrono::NaiveDate) -> Vec<&'a Opinion>` — sorted best-first, max 20. Task 2 calls this from `get_recent_context`.

- [ ] **Step 1: Write the failing tests**

Add at the bottom of `src-tauri/src/memory.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn opinion(topic: &str, text: &str, times_seen: u32, last_seen: &str) -> Opinion {
        Opinion {
            topic: topic.into(),
            opinion: text.into(),
            times_seen,
            first_seen: "2026-01-01".into(),
            last_seen: last_seen.into(),
            category: "habit".into(),
        }
    }

    fn today() -> chrono::NaiveDate {
        chrono::NaiveDate::from_ymd_opt(2026, 7, 4).unwrap()
    }

    #[test]
    fn recency_halves_score_per_half_life() {
        let fresh = opinion("a", "x", 10, "2026-07-04 10:00");
        let two_weeks = opinion("b", "x", 10, "2026-06-20 10:00");
        let none = std::collections::HashSet::new();
        let s_fresh = score_opinion(&fresh, &none, today());
        let s_old = score_opinion(&two_weeks, &none, today());
        assert!((s_fresh - 10.0).abs() < 1e-9);
        assert!((s_old - 5.0).abs() < 1e-9);
    }

    #[test]
    fn unparseable_last_seen_scores_midpoint() {
        let bad = opinion("a", "x", 10, "garbage");
        let none = std::collections::HashSet::new();
        assert!((score_opinion(&bad, &none, today()) - 5.0).abs() < 1e-9);
    }

    #[test]
    fn stale_strong_opinion_loses_to_fresh_relevant_one() {
        // Strong stale opinion vs weak fresh one that matches the query
        let strong = opinion("tab_hoarding", "hoards tabs", 40, "2026-03-01 10:00");
        let weak = opinion("twitter_usage", "always on twitter", 3, "2026-07-03 10:00");
        let ops = vec![strong, weak];
        let picked = select_opinions(&ops, Some("Twitter home timeline trending"), today());
        assert_eq!(picked[0].topic, "twitter_usage");
    }

    #[test]
    fn relevance_boost_is_capped() {
        let op = opinion("twitter_usage", "twitter twitter twitter", 1, "2026-07-04 10:00");
        let q = tokenize("twitter usage twitter twitter");
        assert!(relevance_boost(&op, &q) <= 2.0 + 1e-9);
    }

    #[test]
    fn short_tokens_are_dropped() {
        let toks = tokenize("Go is ok C no");
        assert!(toks.is_empty());
    }

    #[test]
    fn selection_caps_at_twenty() {
        let ops: Vec<Opinion> = (0..30)
            .map(|i| opinion(&format!("t{}", i), "x", i + 1, "2026-07-04 10:00"))
            .collect();
        let picked = select_opinions(&ops, None, today());
        assert_eq!(picked.len(), 20);
        assert_eq!(picked[0].topic, "t29"); // highest conviction first
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd src-tauri && cargo test --lib memory`
Expected: FAIL to compile — `score_opinion`, `tokenize`, `relevance_boost`, `select_opinions` not found.

- [ ] **Step 3: Implement the scoring section**

Insert into `src-tauri/src/memory.rs` after the `SheepBrain` `Default` impl (below line 89):

```rust
// ═══════════════════════════════════════════════════════════
// Opinion scoring — conviction × recency × relevance.
// Selection for the prompt context; nothing here touches disk.
// ═══════════════════════════════════════════════════════════

const RECENCY_HALF_LIFE_DAYS: f64 = 14.0;
const RELEVANCE_CAP: f64 = 2.0;
const MAX_CONTEXT_OPINIONS: usize = 20;
const TOPIC_TOKEN_WEIGHT: f64 = 1.0;
const TEXT_TOKEN_WEIGHT: f64 = 0.5;

fn tokenize(s: &str) -> std::collections::HashSet<String> {
    s.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| t.len() >= 3)
        .map(str::to_string)
        .collect()
}

/// 0.5^(days_idle / half-life). Unparseable last_seen scores the midpoint —
/// neither fresh nor ancient.
fn recency_weight(last_seen: &str, today: chrono::NaiveDate) -> f64 {
    let Some(date) = last_seen
        .get(..10)
        .and_then(|d| chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").ok())
    else {
        return 0.5;
    };
    let days = (today - date).num_days().max(0) as f64;
    0.5_f64.powf(days / RECENCY_HALF_LIFE_DAYS)
}

/// Token overlap between the query and the opinion; topic-key tokens weigh
/// double text tokens. Capped so relevance can re-rank but not dominate.
fn relevance_boost(op: &Opinion, query_tokens: &std::collections::HashSet<String>) -> f64 {
    if query_tokens.is_empty() {
        return 0.0;
    }
    let topic_hits = tokenize(&op.topic).intersection(query_tokens).count() as f64;
    let text_hits = tokenize(&op.opinion).intersection(query_tokens).count() as f64;
    (topic_hits * TOPIC_TOKEN_WEIGHT + text_hits * TEXT_TOKEN_WEIGHT).min(RELEVANCE_CAP)
}

fn score_opinion(
    op: &Opinion,
    query_tokens: &std::collections::HashSet<String>,
    today: chrono::NaiveDate,
) -> f64 {
    op.times_seen as f64
        * recency_weight(&op.last_seen, today)
        * (1.0 + relevance_boost(op, query_tokens))
}

/// Top opinions for the prompt, best first.
pub fn select_opinions<'a>(
    opinions: &'a [Opinion],
    query: Option<&str>,
    today: chrono::NaiveDate,
) -> Vec<&'a Opinion> {
    let query_tokens = query.map(tokenize).unwrap_or_default();
    let mut scored: Vec<(f64, &Opinion)> = opinions
        .iter()
        .map(|o| (score_opinion(o, &query_tokens, today), o))
        .collect();
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    scored
        .into_iter()
        .take(MAX_CONTEXT_OPINIONS)
        .map(|(_, o)| o)
        .collect()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd src-tauri && cargo test --lib memory`
Expected: PASS (6 tests). `cargo build` may warn `select_opinions` unused — fine until Task 2.

- [ ] **Step 5: Commit**

```bash
git add src-tauri/src/memory.rs
git commit -m "Add conviction × recency × relevance opinion scoring

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Thread the query into `get_recent_context`

**Files:**
- Modify: `src-tauri/src/memory.rs:236-256` (`get_recent_context`)
- Modify: `src-tauri/src/vision.rs:179` (vision pipeline call site), `src-tauri/src/vision.rs:390` (chat call site)

**Interfaces:**
- Consumes: `select_opinions` from Task 1.
- Produces: `pub fn get_recent_context(query: Option<&str>) -> Result<String, Box<dyn std::error::Error>>` — same output format as before, selection now scored. All later tasks use this signature.

- [ ] **Step 1: Change the signature and selection**

In `src-tauri/src/memory.rs`, change `get_recent_context` (line 236) to:

```rust
/// Build the full context for the AI: opinions + daily counts + recent journal.
/// `query` (screen text or chat message) steers which opinions surface.
pub fn get_recent_context(query: Option<&str>) -> Result<String, Box<dyn std::error::Error>> {
```

and replace the opinion block (the `if !brain.opinions.is_empty()` body, lines 241-256) with:

```rust
    if !brain.opinions.is_empty() {
        let today = Local::now().date_naive();
        let selected = select_opinions(&brain.opinions, query, today);

        let mut opinion_lines: Vec<String> = Vec::new();
        for op in selected {
            opinion_lines.push(format!(
                "- [{}] {} (seen {} times, last: {})",
                op.topic, op.opinion, op.times_seen, op.last_seen
            ));
        }
        parts.push(format!(
            "## Your opinions about your human (strongest first)\n{}",
            opinion_lines.join("\n")
        ));
    }
```

- [ ] **Step 2: Update the two call sites**

`src-tauri/src/vision.rs:179` (vision pipeline — `screen_text` is the OCR result in scope):

```rust
    let recent_context = memory::get_recent_context(Some(&screen_text)).unwrap_or_default();
```

`src-tauri/src/vision.rs:390` (chat — `user_message` is the truncated message):

```rust
    let recent_context = memory::get_recent_context(Some(user_message)).unwrap_or_default();
```

- [ ] **Step 3: Verify it compiles and all tests pass**

Run: `cd src-tauri && cargo test`
Expected: PASS (memory, friend_memory, and vision test modules). No remaining callers of the zero-arg form — `cargo build` must emit no errors.

- [ ] **Step 4: Commit**

```bash
git add src-tauri/src/memory.rs src-tauri/src/vision.rs
git commit -m "Steer opinion selection with screen text and chat queries

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Topic-key canonicalization and prompt key-reuse

**Files:**
- Modify: `src-tauri/src/memory.rs` (`save_opinion`, line 120; new `canonicalize_topic` beside it; tests)
- Modify: `src-tauri/src/personality.rs` (both prompt builders)

**Interfaces:**
- Produces: `pub fn canonicalize_topic(topic: &str) -> String` — lowercase, trimmed, whitespace runs → single `_`. Task 4's op applier reuses it.

- [ ] **Step 1: Write the failing tests**

Add to the `tests` module in `src-tauri/src/memory.rs`:

```rust
    #[test]
    fn canonicalize_lowercases_and_underscores() {
        assert_eq!(canonicalize_topic("  Twitter Usage "), "twitter_usage");
        assert_eq!(canonicalize_topic("dark_mode"), "dark_mode");
        assert_eq!(canonicalize_topic("Tab   Hoarding"), "tab_hoarding");
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src-tauri && cargo test --lib memory canonicalize`
Expected: FAIL to compile — `canonicalize_topic` not found.

- [ ] **Step 3: Implement and apply in `save_opinion`**

Add above `save_opinion` in `src-tauri/src/memory.rs`:

```rust
/// Canonical topic key: lowercase, trimmed, whitespace runs become one `_`.
/// Keeps model-invented variants like "Twitter Usage" from fragmenting
/// conviction across duplicate opinions.
pub fn canonicalize_topic(topic: &str) -> String {
    topic
        .trim()
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("_")
}
```

In `save_opinion`, insert as the first line after the lock guard (after line 125) and use `&topic` in place of `topic` throughout the function:

```rust
    let topic = canonicalize_topic(topic);
```

(The two uses: `find(|o| o.topic == topic)` and `topic: topic.to_string()` — both work against the canonicalized `String`.)

- [ ] **Step 4: Add the key-reuse instruction to both prompts**

In `src-tauri/src/personality.rs`, in `get_system_prompt`, after the `DAILY COUNTS:` paragraph (after line 136), add:

```rust
TOPIC KEYS: If your new opinion concerns something you already have an opinion about
(the keys in [brackets] above), reuse that exact topic key — never invent a variant.
```

(This is inside the existing `format!` raw string — plain text, no new placeholders.)

In `get_chat_prompt`, after the line `You can form opinions about what they say. Be yourself — don't be helpful or assistant-like.` (line 195), add:

```rust
When forming an opinion on a topic you already have a key for (in [brackets] above), reuse that exact key.
```

- [ ] **Step 5: Run tests, verify pass, commit**

Run: `cd src-tauri && cargo test`
Expected: PASS.

```bash
git add src-tauri/src/memory.rs src-tauri/src/personality.rs
git commit -m "Canonicalize opinion topic keys and instruct key reuse

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Reflection op protocol — parse and apply (`reflect.rs`)

**Files:**
- Create: `src-tauri/src/reflect.rs`
- Modify: `src-tauri/src/lib.rs:1-15` (add `mod reflect;` to the module list)

**Interfaces:**
- Consumes: `memory::Opinion`, `memory::SheepBrain` (pub fields), `memory::canonicalize_topic` from Task 3.
- Produces (Tasks 6-7 depend on these exact signatures):
  - `pub enum ReflectOp { Merge { from: Vec<String>, into: String, text: String }, Update { topic: String, text: String }, Prune { topic: String }, Add { topic: String, text: String, category: Option<String> } }`
  - `pub fn parse_ops(raw: &str) -> Result<Vec<ReflectOp>, String>`
  - `pub struct ReflectPolicy { allow_prune, max_prunes, max_adds, prune_min_idle_days, prune_max_times_seen, today }` with `ReflectPolicy::daily(today: NaiveDate)` and `ReflectPolicy::backfill(today: NaiveDate)`
  - `pub fn apply_ops(brain: &mut SheepBrain, ops: &[ReflectOp], policy: &ReflectPolicy) -> ApplyStats` (`ApplyStats { merged, updated, pruned, added, skipped }`, all `usize`, derives `Debug, Default, PartialEq`)

- [ ] **Step 1: Create the module skeleton and register it**

Create `src-tauri/src/reflect.rs` with just the header; add `mod reflect;` to `src-tauri/src/lib.rs` after `mod personality;`:

```rust
//! Memory consolidation — the sheep sleeps on it.
//!
//! A reflection pass feeds a day's journal plus the opinion list to the
//! on-device model, which proposes explicit ops (merge/update/prune/add).
//! Rust validates and applies them: model proposes, Rust disposes.
```

- [ ] **Step 2: Write the failing tests**

Add to `src-tauri/src/reflect.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory::{Opinion, SheepBrain};

    fn opinion(topic: &str, times_seen: u32, last_seen: &str) -> Opinion {
        Opinion {
            topic: topic.into(),
            opinion: format!("about {}", topic),
            times_seen,
            first_seen: "2026-01-01".into(),
            last_seen: last_seen.into(),
            category: "habit".into(),
        }
    }

    fn brain(opinions: Vec<Opinion>) -> SheepBrain {
        SheepBrain { opinions, ..SheepBrain::default() }
    }

    fn today() -> chrono::NaiveDate {
        chrono::NaiveDate::from_ymd_opt(2026, 7, 4).unwrap()
    }

    #[test]
    fn parses_ops_with_markdown_fences() {
        let raw = "```json\n{\"ops\": [{\"op\": \"prune\", \"topic\": \"dead\"}]}\n```";
        let ops = parse_ops(raw).unwrap();
        assert_eq!(ops, vec![ReflectOp::Prune { topic: "dead".into() }]);
    }

    #[test]
    fn parse_rejects_garbage() {
        assert!(parse_ops("the sheep dreams of electric grass").is_err());
    }

    #[test]
    fn parses_empty_ops() {
        assert!(parse_ops(r#"{"ops": []}"#).unwrap().is_empty());
    }

    #[test]
    fn merge_sums_conviction_and_keeps_date_range() {
        let mut b = brain(vec![
            Opinion { first_seen: "2026-02-01".into(), last_seen: "2026-06-01 10:00".into(), ..opinion("twitter_usage", 10, "") },
            Opinion { first_seen: "2026-03-01".into(), last_seen: "2026-07-01 10:00".into(), ..opinion("twitter_habit", 5, "") },
        ]);
        let ops = vec![ReflectOp::Merge {
            from: vec!["twitter_usage".into(), "twitter_habit".into()],
            into: "twitter_usage".into(),
            text: "chronically online".into(),
        }];
        let stats = apply_ops(&mut b, &ops, &ReflectPolicy::daily(today()));
        assert_eq!(stats.merged, 1);
        assert_eq!(b.opinions.len(), 1);
        let m = &b.opinions[0];
        assert_eq!(m.topic, "twitter_usage");
        assert_eq!(m.times_seen, 15);
        assert_eq!(m.first_seen, "2026-02-01");
        assert_eq!(m.last_seen, "2026-07-01 10:00");
        assert_eq!(m.opinion, "chronically online");
    }

    #[test]
    fn merge_with_fewer_than_two_real_sources_is_skipped() {
        let mut b = brain(vec![opinion("a", 3, "2026-07-01 10:00")]);
        let ops = vec![ReflectOp::Merge { from: vec!["a".into(), "ghost".into()], into: "a".into(), text: String::new() }];
        let stats = apply_ops(&mut b, &ops, &ReflectPolicy::daily(today()));
        assert_eq!(stats.merged, 0);
        assert_eq!(stats.skipped, 1);
        assert_eq!(b.opinions[0].times_seen, 3);
    }

    #[test]
    fn prune_respects_strength_and_idleness() {
        let mut b = brain(vec![
            opinion("strong_active", 40, "2026-07-03 10:00"), // strong + fresh: protected
            opinion("weak", 1, "2026-07-03 10:00"),           // weak: prunable
            opinion("stale", 40, "2026-05-01 10:00"),         // idle > 21d: prunable
        ]);
        let ops = vec![
            ReflectOp::Prune { topic: "strong_active".into() },
            ReflectOp::Prune { topic: "weak".into() },
            ReflectOp::Prune { topic: "stale".into() },
        ];
        let stats = apply_ops(&mut b, &ops, &ReflectPolicy::daily(today()));
        assert_eq!(stats.pruned, 2);
        assert_eq!(stats.skipped, 1);
        assert!(b.opinions.iter().any(|o| o.topic == "strong_active"));
    }

    #[test]
    fn prune_capped_per_run() {
        let mut b = brain((0..5).map(|i| opinion(&format!("w{}", i), 1, "2026-07-03 10:00")).collect());
        let ops: Vec<ReflectOp> = (0..5).map(|i| ReflectOp::Prune { topic: format!("w{}", i) }).collect();
        let stats = apply_ops(&mut b, &ops, &ReflectPolicy::daily(today()));
        assert_eq!(stats.pruned, 3);
        assert_eq!(b.opinions.len(), 2);
    }

    #[test]
    fn backfill_policy_rejects_all_prunes() {
        let mut b = brain(vec![opinion("weak", 1, "2026-07-03 10:00")]);
        let ops = vec![ReflectOp::Prune { topic: "weak".into() }];
        let stats = apply_ops(&mut b, &ops, &ReflectPolicy::backfill(today()));
        assert_eq!(stats.pruned, 0);
        assert_eq!(b.opinions.len(), 1);
    }

    #[test]
    fn unparseable_last_seen_counts_as_not_idle() {
        let mut b = brain(vec![opinion("mystery", 40, "garbage")]);
        let ops = vec![ReflectOp::Prune { topic: "mystery".into() }];
        let stats = apply_ops(&mut b, &ops, &ReflectPolicy::daily(today()));
        assert_eq!(stats.pruned, 0); // strong + not-provably-idle: protected
    }

    #[test]
    fn add_caps_and_skips_existing() {
        let mut b = brain(vec![opinion("existing", 3, "2026-07-03 10:00")]);
        let mut ops: Vec<ReflectOp> = (0..7)
            .map(|i| ReflectOp::Add { topic: format!("new_{}", i), text: "x".into(), category: Some("habit".into()) })
            .collect();
        ops.push(ReflectOp::Add { topic: "existing".into(), text: "dup".into(), category: None });
        let stats = apply_ops(&mut b, &ops, &ReflectPolicy::daily(today()));
        assert_eq!(stats.added, 5);
        assert_eq!(stats.skipped, 3); // 2 over cap + 1 duplicate
        assert_eq!(b.opinions.len(), 6);
    }

    #[test]
    fn update_replaces_text_only_for_known_topics() {
        let mut b = brain(vec![opinion("known", 3, "2026-07-03 10:00")]);
        let ops = vec![
            ReflectOp::Update { topic: "known".into(), text: "new view".into() },
            ReflectOp::Update { topic: "ghost".into(), text: "boo".into() },
        ];
        let stats = apply_ops(&mut b, &ops, &ReflectPolicy::daily(today()));
        assert_eq!(stats.updated, 1);
        assert_eq!(stats.skipped, 1);
        assert_eq!(b.opinions[0].opinion, "new view");
        assert_eq!(b.opinions[0].times_seen, 3);
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd src-tauri && cargo test --lib reflect`
Expected: FAIL to compile — types not defined.

- [ ] **Step 4: Implement the op protocol**

Add to `src-tauri/src/reflect.rs` above the tests:

```rust
use crate::memory::{self, Opinion, SheepBrain};
use chrono::NaiveDate;
use serde::Deserialize;

#[derive(Deserialize, Debug, PartialEq)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum ReflectOp {
    Merge {
        from: Vec<String>,
        into: String,
        #[serde(default)]
        text: String,
    },
    Update {
        topic: String,
        text: String,
    },
    Prune {
        topic: String,
    },
    Add {
        topic: String,
        text: String,
        #[serde(default)]
        category: Option<String>,
    },
}

#[derive(Deserialize)]
struct OpsEnvelope {
    ops: Vec<ReflectOp>,
}

pub fn parse_ops(raw: &str) -> Result<Vec<ReflectOp>, String> {
    let trimmed = raw
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();
    serde_json::from_str::<OpsEnvelope>(trimmed)
        .map(|e| e.ops)
        .map_err(|e| format!("bad reflection ops: {} — raw: {}", e, trimmed))
}

pub struct ReflectPolicy {
    pub allow_prune: bool,
    pub max_prunes: usize,
    pub max_adds: usize,
    pub prune_min_idle_days: i64,
    pub prune_max_times_seen: u32,
    pub today: NaiveDate,
}

impl ReflectPolicy {
    pub fn daily(today: NaiveDate) -> Self {
        Self {
            allow_prune: true,
            max_prunes: 3,
            max_adds: 5,
            prune_min_idle_days: 21,
            prune_max_times_seen: 2,
            today,
        }
    }

    /// Months-old evidence must not delete current beliefs.
    pub fn backfill(today: NaiveDate) -> Self {
        Self { allow_prune: false, ..Self::daily(today) }
    }
}

#[derive(Debug, Default, PartialEq)]
pub struct ApplyStats {
    pub merged: usize,
    pub updated: usize,
    pub pruned: usize,
    pub added: usize,
    pub skipped: usize,
}

fn idle_days(op: &Opinion, today: NaiveDate) -> Option<i64> {
    op.last_seen
        .get(..10)
        .and_then(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").ok())
        .map(|d| (today - d).num_days())
}

fn prune_eligible(op: &Opinion, policy: &ReflectPolicy) -> bool {
    op.times_seen <= policy.prune_max_times_seen
        || idle_days(op, policy.today).is_some_and(|d| d > policy.prune_min_idle_days)
}

/// Apply model-proposed ops under policy. Invalid ops are skipped, never fatal.
pub fn apply_ops(brain: &mut SheepBrain, ops: &[ReflectOp], policy: &ReflectPolicy) -> ApplyStats {
    let mut stats = ApplyStats::default();
    for op in ops {
        match op {
            ReflectOp::Merge { from, into, text } => {
                let into_key = memory::canonicalize_topic(into);
                let mut sources: Vec<String> =
                    from.iter().map(|k| memory::canonicalize_topic(k)).collect();
                if !sources.contains(&into_key) {
                    sources.push(into_key.clone());
                }
                let found: Vec<Opinion> = brain
                    .opinions
                    .iter()
                    .filter(|o| sources.contains(&o.topic))
                    .cloned()
                    .collect();
                if found.len() < 2 {
                    stats.skipped += 1;
                    continue;
                }
                let times: u32 = found.iter().map(|o| o.times_seen).sum();
                let first = found.iter().map(|o| o.first_seen.clone()).min().unwrap_or_default();
                let last = found.iter().map(|o| o.last_seen.clone()).max().unwrap_or_default();
                let merged_text = if text.trim().is_empty() {
                    found[0].opinion.clone()
                } else {
                    text.clone()
                };
                let category = found[0].category.clone();
                brain.opinions.retain(|o| !sources.contains(&o.topic));
                brain.opinions.push(Opinion {
                    topic: into_key,
                    opinion: merged_text,
                    times_seen: times,
                    first_seen: first,
                    last_seen: last,
                    category,
                });
                stats.merged += 1;
            }
            ReflectOp::Update { topic, text } => {
                let key = memory::canonicalize_topic(topic);
                if text.trim().is_empty() {
                    stats.skipped += 1;
                    continue;
                }
                match brain.opinions.iter_mut().find(|o| o.topic == key) {
                    Some(existing) => {
                        existing.opinion = text.clone();
                        stats.updated += 1;
                    }
                    None => stats.skipped += 1,
                }
            }
            ReflectOp::Prune { topic } => {
                if !policy.allow_prune || stats.pruned >= policy.max_prunes {
                    stats.skipped += 1;
                    continue;
                }
                let key = memory::canonicalize_topic(topic);
                let Some(pos) = brain.opinions.iter().position(|o| o.topic == key) else {
                    stats.skipped += 1;
                    continue;
                };
                if !prune_eligible(&brain.opinions[pos], policy) {
                    stats.skipped += 1;
                    continue;
                }
                brain.opinions.remove(pos);
                stats.pruned += 1;
            }
            ReflectOp::Add { topic, text, category } => {
                if stats.added >= policy.max_adds {
                    stats.skipped += 1;
                    continue;
                }
                let key = memory::canonicalize_topic(topic);
                if key.is_empty()
                    || text.trim().is_empty()
                    || brain.opinions.iter().any(|o| o.topic == key)
                {
                    stats.skipped += 1;
                    continue;
                }
                let today = policy.today.format("%Y-%m-%d").to_string();
                brain.opinions.push(Opinion {
                    topic: key,
                    opinion: text.clone(),
                    times_seen: 1,
                    first_seen: today.clone(),
                    last_seen: format!("{} 00:00", today),
                    category: category.clone().unwrap_or_else(|| "opinion".into()),
                });
                stats.added += 1;
            }
        }
    }
    stats
}
```

- [ ] **Step 5: Run tests, verify pass, commit**

Run: `cd src-tauri && cargo test --lib reflect`
Expected: PASS (11 tests).

```bash
git add src-tauri/src/reflect.rs src-tauri/src/lib.rs
git commit -m "Add reflection op protocol: model proposes, Rust disposes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Memory plumbing — brain mutation helper, snapshot, journal access

**Files:**
- Modify: `src-tauri/src/memory.rs` (new `SheepBrain` fields; helpers; make `tail_at_char_boundary` `pub(crate)`; tests)

**Interfaces:**
- Produces (Tasks 6-7 depend on these):
  - `SheepBrain.last_reflection_date: String` and `SheepBrain.backfill_cursor: String`, both `#[serde(default)]`
  - `pub fn update_brain<F: FnOnce(&mut SheepBrain)>(f: F) -> Result<(), Box<dyn std::error::Error>>` — lock, load, mutate, save
  - `pub fn snapshot_opinions()` — copies `opinions.json` → `opinions.json.bak` if present
  - `pub fn read_journal_for(date: &str) -> Option<String>` — full text of `journal/<date>.md`
  - `pub fn list_journal_days() -> Vec<String>` — sorted `YYYY-MM-DD` stems in the journal dir
  - `pub(crate) fn tail_at_char_boundary(s: &str, max_bytes: usize) -> &str` (existing fn, widened visibility)

- [ ] **Step 1: Write the failing test for journal-day listing**

The listing logic takes an explicit `&Path` so the test uses a temp dir — no env vars (the `friend_memory` test owns `CO_SHEEP_HOME`; racing it is forbidden). Add to the `tests` module in `src-tauri/src/memory.rs`:

```rust
    #[test]
    fn lists_journal_days_sorted_ignoring_strays() {
        let dir = std::env::temp_dir().join(format!("co-sheep-journal-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for name in ["2026-07-02.md", "2026-06-30.md", "notes.md", "2026-07-01.md"] {
            std::fs::write(dir.join(name), "x").unwrap();
        }
        let days = list_journal_days_in(&dir);
        assert_eq!(days, vec!["2026-06-30", "2026-07-01", "2026-07-02"]);
        std::fs::remove_dir_all(&dir).ok();
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src-tauri && cargo test --lib memory lists_journal`
Expected: FAIL to compile — `list_journal_days_in` not found.

- [ ] **Step 3: Implement fields and helpers**

In `src-tauri/src/memory.rs`:

a) Add to `SheepBrain` (after `total_interactions`, line 76):

```rust
    /// Date the daily reflection pass last ran (or was marked done)
    #[serde(default)]
    pub last_reflection_date: String,
    /// Last journal date processed by the historical backfill
    #[serde(default)]
    pub backfill_cursor: String,
```

b) Add both fields to the manual `Default` impl (line 79-89):

```rust
            last_reflection_date: String::new(),
            backfill_cursor: String::new(),
```

c) Change `fn tail_at_char_boundary` (line 14) to `pub(crate) fn tail_at_char_boundary`.

d) Add after `save_brain` (line 115):

```rust
/// Locked load → mutate → save. The reflection pass uses this so its writes
/// can't drop a concurrent commentary tick's opinion update.
pub fn update_brain<F: FnOnce(&mut SheepBrain)>(f: F) -> Result<(), Box<dyn std::error::Error>> {
    let _guard = BRAIN_LOCK.lock().unwrap();
    let mut brain = load_brain();
    f(&mut brain);
    save_brain(&brain)
}

/// One-generation backup before a reflection pass touches opinions.
pub fn snapshot_opinions() {
    let src = opinions_path();
    if src.exists() {
        fs::copy(&src, sheep_dir().join("opinions.json.bak")).ok();
    }
}
```

e) Add after `get_today_journal` (line 228):

```rust
/// Full journal text for a specific day, if that day has entries.
pub fn read_journal_for(date: &str) -> Option<String> {
    fs::read_to_string(journal_dir().join(format!("{}.md", date))).ok()
}

/// All journal dates on disk, oldest first.
pub fn list_journal_days() -> Vec<String> {
    list_journal_days_in(&journal_dir())
}

fn list_journal_days_in(dir: &std::path::Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut days: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.path().file_stem().and_then(|s| s.to_str()).map(String::from))
        .filter(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").is_ok())
        .collect();
    days.sort();
    days
}
```

- [ ] **Step 4: Run tests, verify pass, commit**

Run: `cd src-tauri && cargo test`
Expected: PASS. (`update_brain`/`snapshot_opinions` are exercised in Task 6; unused-fn warnings until then are fine.)

```bash
git add src-tauri/src/memory.rs
git commit -m "Add brain mutation helper, opinion snapshot, and journal-day access

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Daily reflection runner and background loop

**Files:**
- Modify: `src-tauri/src/reflect.rs` (prompt builder, runner, loop)
- Modify: `src-tauri/src/lib.rs:21` (new static), `src-tauri/src/lib.rs:1013` (spawn loop after the vision loop spawn)
- Modify: `src-tauri/src/vision.rs:138-146` (busy flag around the pipeline)

**Interfaces:**
- Consumes: Task 4 (`parse_ops`, `apply_ops`, `ReflectPolicy`), Task 5 (`update_brain`, `snapshot_opinions`, `read_journal_for`, `tail_at_char_boundary`), `apple_ai::generate`.
- Produces: `pub async fn reflection_loop()` (spawned once at startup), `crate::VISION_TICK_RUNNING: AtomicBool`. Task 7 adds its step inside `reflection_loop`.

- [ ] **Step 1: Write the failing test for the prompt builder**

Add to the `tests` module in `src-tauri/src/reflect.rs`:

```rust
    #[test]
    fn reflection_prompt_lists_opinions_and_journal() {
        let ops = vec![opinion("twitter_usage", 5, "2026-07-01 10:00")];
        let p = build_reflection_prompt(&ops, "## 10:00 AM\nScrolled twitter again.", "Diary for 2026-07-03");
        assert!(p.contains("[twitter_usage]"));
        assert!(p.contains("Scrolled twitter again."));
        assert!(p.contains("Diary for 2026-07-03"));
        assert!(p.contains(r#""ops""#));
    }

    #[test]
    fn reflection_prompt_budgets_long_journals() {
        let ops = vec![opinion("a", 1, "2026-07-01 10:00")];
        let huge = "baa ".repeat(2000); // 8000 bytes
        let p = build_reflection_prompt(&ops, &huge, "Diary");
        assert!(p.len() < 6500);
    }

    #[test]
    fn reflection_prompt_caps_opinion_count() {
        let many: Vec<Opinion> = (0..80).map(|i| opinion(&format!("t{}", i), i, "2026-07-01 10:00")).collect();
        let p = build_reflection_prompt(&many, "x", "Diary");
        // Strongest survive the cap; weakest are cut
        assert!(p.contains("[t79]"));
        assert!(!p.contains("[t0]"));
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd src-tauri && cargo test --lib reflect prompt`
Expected: FAIL to compile — `build_reflection_prompt` not found.

- [ ] **Step 3: Implement prompt builder and runner**

Add to `src-tauri/src/reflect.rs`:

```rust
type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// ~4k-token window: opinions and journal each get an explicit byte budget.
const JOURNAL_BUDGET: usize = 2500;
const MAX_PROMPT_OPINIONS: usize = 60;

const REFLECT_SYSTEM: &str = "You are the memory-consolidation process for a desktop sheep. \
You tidy the sheep's opinion list using its diary. Reply with ONLY valid JSON, no markdown.";

pub fn build_reflection_prompt(opinions: &[Opinion], journal: &str, journal_label: &str) -> String {
    let mut sorted: Vec<&Opinion> = opinions.iter().collect();
    sorted.sort_by(|a, b| b.times_seen.cmp(&a.times_seen));
    let op_lines: Vec<String> = sorted
        .iter()
        .take(MAX_PROMPT_OPINIONS)
        .map(|o| {
            format!(
                "- [{}] {} (category: {}, seen {}x, last: {})",
                o.topic, o.opinion, o.category, o.times_seen, o.last_seen
            )
        })
        .collect();
    let journal_tail = memory::tail_at_char_boundary(journal, JOURNAL_BUDGET);

    format!(
        r#"Current opinions:
{}

{}:
{}

Tidy the opinions:
- merge: topics that mean the same thing
- update: opinion text the diary shows is outdated
- prune: opinions that no longer matter
- add: a clear recurring pattern in the diary that has no opinion yet

Reply with JSON only:
{{"ops": [
  {{"op": "merge", "from": ["key_a", "key_b"], "into": "key_a", "text": "combined opinion"}},
  {{"op": "update", "topic": "key", "text": "new text"}},
  {{"op": "prune", "topic": "key"}},
  {{"op": "add", "topic": "new_key", "text": "opinion text", "category": "habit"}}
]}}
If nothing needs tidying: {{"ops": []}}"#,
        op_lines.join("\n"),
        journal_label,
        journal_tail
    )
}

/// One generate → parse → snapshot → apply cycle over a day's journal.
async fn reflect_once(
    opinions: &[Opinion],
    journal: &str,
    label: &str,
    policy: ReflectPolicy,
) -> Result<ApplyStats, BoxError> {
    let prompt = build_reflection_prompt(opinions, journal, label);
    let raw = crate::apple_ai::generate(REFLECT_SYSTEM, &prompt).await?;
    let ops = parse_ops(&raw)?;
    memory::snapshot_opinions();
    let mut stats = ApplyStats::default();
    memory::update_brain(|b| {
        stats = apply_ops(b, &ops, &policy);
    })
    .map_err(|e| e.to_string())?;
    Ok(stats)
}

/// Consolidate yesterday's journal into the opinion list. Runs once per
/// calendar day; the date is marked *before* the model call so a garbage
/// output retries tomorrow, never in a loop.
pub async fn run_daily_reflection() {
    let today = chrono::Local::now().date_naive();
    let today_str = today.format("%Y-%m-%d").to_string();
    let brain = memory::load_brain();
    if brain.last_reflection_date == today_str {
        return;
    }

    let marked = today_str.clone();
    if memory::update_brain(move |b| b.last_reflection_date = marked).is_err() {
        return;
    }

    let yesterday = (today - chrono::Duration::days(1)).format("%Y-%m-%d").to_string();
    let Some(journal) = memory::read_journal_for(&yesterday) else {
        eprintln!("[co-sheep] Reflection: no journal for {}, nothing to tidy", yesterday);
        return;
    };

    eprintln!("[co-sheep] Reflection: consolidating {}", yesterday);
    let label = format!("Diary for {}", yesterday);
    match reflect_once(&brain.opinions, &journal, &label, ReflectPolicy::daily(today)).await {
        Ok(stats) => {
            eprintln!("[co-sheep] Reflection applied: {:?}", stats);
            memory::append_journal("*Slept on it. Tidied my thoughts.*").ok();
        }
        Err(e) => eprintln!("[co-sheep] Reflection failed (retry tomorrow): {}", e),
    }
}

const LOOP_INTERVAL_SECS: u64 = 180;

/// Background loop: daily reflection, then (Task 7) one backfill step per
/// interval — only while the vision pipeline isn't mid-tick.
pub async fn reflection_loop() {
    tokio::time::sleep(std::time::Duration::from_secs(90)).await;
    loop {
        if !crate::VISION_TICK_RUNNING.load(std::sync::atomic::Ordering::Relaxed) {
            run_daily_reflection().await;
        }
        tokio::time::sleep(std::time::Duration::from_secs(LOOP_INTERVAL_SECS)).await;
    }
}
```

- [ ] **Step 4: Add the busy flag and spawn the loop**

a) `src-tauri/src/lib.rs`, next to `COMMENTARY_PAUSED` (line 21):

```rust
/// True while a vision-pipeline tick is running — reflection/backfill yield.
pub static VISION_TICK_RUNNING: AtomicBool = AtomicBool::new(false);
```

b) `src-tauri/src/vision.rs`, at the top of `run_vision_pipeline`'s body (line 141, before the first `eprintln!`) — RAII so every return path clears the flag:

```rust
    struct TickGuard;
    impl Drop for TickGuard {
        fn drop(&mut self) {
            crate::VISION_TICK_RUNNING.store(false, Ordering::Relaxed);
        }
    }
    crate::VISION_TICK_RUNNING.store(true, Ordering::Relaxed);
    let _tick_guard = TickGuard;
```

c) `src-tauri/src/lib.rs`, after the vision loop spawn (line 1012):

```rust
            // Spawn memory reflection loop (daily consolidation + backfill)
            eprintln!("[co-sheep] Spawning reflection loop");
            tauri::async_runtime::spawn(async move {
                reflect::reflection_loop().await;
            });
```

- [ ] **Step 5: Run tests and build, commit**

Run: `cd src-tauri && cargo test && cargo build`
Expected: tests PASS, build clean.

```bash
git add src-tauri/src/reflect.rs src-tauri/src/lib.rs src-tauri/src/vision.rs
git commit -m "Run daily memory reflection when the vision pipeline is idle

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Historical backfill

**Files:**
- Modify: `src-tauri/src/reflect.rs` (pending-day selection, backfill step, loop wiring)

**Interfaces:**
- Consumes: Task 5 (`list_journal_days`, `read_journal_for`, `update_brain`, `backfill_cursor`), Task 6 (`reflect_once`, `reflection_loop`).
- Produces: `pub fn pending_backfill_day(days: &[String], cursor: &str, today: &str) -> Option<String>`, `pub async fn run_backfill_step() -> bool`.

- [ ] **Step 1: Write the failing tests**

Add to the `tests` module in `src-tauri/src/reflect.rs`:

```rust
    #[test]
    fn backfill_picks_oldest_unprocessed_day_before_today() {
        let days: Vec<String> =
            ["2026-06-30", "2026-07-01", "2026-07-03", "2026-07-04"].map(String::from).into();
        assert_eq!(pending_backfill_day(&days, "", "2026-07-04"), Some("2026-06-30".into()));
        assert_eq!(pending_backfill_day(&days, "2026-06-30", "2026-07-04"), Some("2026-07-01".into()));
        assert_eq!(pending_backfill_day(&days, "2026-07-01", "2026-07-04"), Some("2026-07-03".into()));
        // Today is excluded; cursor at last eligible day means done
        assert_eq!(pending_backfill_day(&days, "2026-07-03", "2026-07-04"), None);
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src-tauri && cargo test --lib reflect backfill_picks`
Expected: FAIL to compile — `pending_backfill_day` not found.

- [ ] **Step 3: Implement the backfill step**

Add to `src-tauri/src/reflect.rs`:

```rust
/// Oldest journal day after the cursor, strictly before today.
pub fn pending_backfill_day(days: &[String], cursor: &str, today: &str) -> Option<String> {
    days.iter()
        .find(|d| d.as_str() > cursor && d.as_str() < today)
        .cloned()
}

/// Distill one archived journal day into opinions. Returns false when the
/// archive is exhausted. The cursor advances even on failure — a garbage
/// day is skipped, not retried forever.
pub async fn run_backfill_step() -> bool {
    let today = chrono::Local::now().date_naive();
    let today_str = today.format("%Y-%m-%d").to_string();
    let brain = memory::load_brain();
    let days = memory::list_journal_days();
    let Some(day) = pending_backfill_day(&days, &brain.backfill_cursor, &today_str) else {
        return false;
    };

    let cursor = day.clone();
    if memory::update_brain(move |b| b.backfill_cursor = cursor).is_err() {
        return false;
    }

    let Some(journal) = memory::read_journal_for(&day) else {
        return true;
    };
    eprintln!("[co-sheep] Backfill: distilling journal {}", day);
    let label = format!("Diary for {}", day);
    match reflect_once(&brain.opinions, &journal, &label, ReflectPolicy::backfill(today)).await {
        Ok(stats) => eprintln!("[co-sheep] Backfill {} applied: {:?}", day, stats),
        Err(e) => eprintln!("[co-sheep] Backfill {} failed, skipped: {}", day, e),
    }
    true
}
```

In `reflection_loop`, extend the idle branch:

```rust
        if !crate::VISION_TICK_RUNNING.load(std::sync::atomic::Ordering::Relaxed) {
            run_daily_reflection().await;
            run_backfill_step().await;
        }
```

- [ ] **Step 4: Run tests, verify pass, commit**

Run: `cd src-tauri && cargo test`
Expected: PASS.

```bash
git add src-tauri/src/reflect.rs
git commit -m "Backfill the journal archive into opinions, one day per idle tick

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Friend chat recall, dead-code cleanup, final verification

**Files:**
- Modify: `src-tauri/src/friend_memory.rs` (replace `get_friend_context` with compact chat context; delete `get_affinity`)
- Modify: `src-tauri/src/vision.rs:441-483` (`friend_chat` signature + prompt)
- Modify: `src-tauri/src/lib.rs:556-568` (`friend_ai_chat` command)
- Modify: `src/flock.ts:1089-1094`, `src/drama-manager.ts:251-256` (pass ids)
- Modify: `src-tauri/src/memory.rs:309-320` (delete `get_long_term_memory` and its section)

**Interfaces:**
- Consumes: existing `FriendBrain` (pub fields), `load_brain` (private — wrapper lives in `friend_memory.rs`).
- Produces: `pub fn get_chat_context(id: &str, other_id: &str) -> String` (≤ 300 chars); `vision::friend_chat` gains leading `friend_a_id: &str` / `friend_b_id: &str` params; Tauri command `friend_ai_chat` gains `friend_a_id: String, friend_b_id: String` (frontend keys `friendAId`/`friendBId`).

- [ ] **Step 1: Write the failing test**

The formatter is pure — it takes a `FriendBrain` directly, so no `CO_SHEEP_HOME`/CACHE involvement (the existing removal test owns that pattern; racing it is forbidden). Add to the `tests` module in `src-tauri/src/friend_memory.rs`:

```rust
    #[test]
    fn chat_context_is_compact_and_capped() {
        let mut brain = new_brain("pelle", "Pelle");
        brain.mood = "grumpy".into();
        brain.relationships.insert("kari".into(), 35);
        for i in 0..10 {
            add_memory(
                &mut brain,
                &format!("Talked with Kari about very important sheep business number {}", i),
                "conversation",
                Some("kari".into()),
            );
        }
        let ctx = format_chat_context(&brain, "kari", "Kari");
        assert!(ctx.starts_with("Pelle is grumpy and loves Kari."));
        assert!(ctx.contains("number 9")); // most recent memory included
        assert!(!ctx.contains("number 0")); // only the last 3
        assert!(ctx.len() <= 300);
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src-tauri && cargo test --lib friend_memory chat_context`
Expected: FAIL to compile — `format_chat_context` not found.

- [ ] **Step 3: Replace `get_friend_context` in `friend_memory.rs`**

Delete `get_friend_context` (lines 344-382) and `get_affinity` (lines 237-240). Add in their place:

```rust
/// Compact social context for friend-to-friend chat prompts, ≤ 300 chars:
/// mood, affinity toward the partner, and the last few memories.
pub fn get_chat_context(id: &str, other_id: &str) -> String {
    let brain = load_brain(id);
    let other_name = load_brain(other_id).name.clone();
    format_chat_context(&brain, other_id, &other_name)
}

fn format_chat_context(brain: &FriendBrain, other_id: &str, other_name: &str) -> String {
    let affinity = brain.relationships.get(other_id).copied().unwrap_or(0);
    let label = if affinity > 30 {
        "loves"
    } else if affinity > 10 {
        "likes"
    } else if affinity < 0 {
        "avoids"
    } else {
        "is neutral toward"
    };
    let mut s = format!("{} is {} and {} {}.", brain.name, brain.mood, label, other_name);
    let recent: Vec<String> = brain.memories.iter().rev().take(3).map(|m| m.text.clone()).collect();
    if !recent.is_empty() {
        s.push_str(&format!(" Remembers: {}.", recent.join("; ")));
    }
    if s.len() > 300 {
        let mut end = 300;
        while !s.is_char_boundary(end) {
            end -= 1;
        }
        s.truncate(end);
    }
    s
}
```

- [ ] **Step 4: Wire context into `friend_chat`**

In `src-tauri/src/vision.rs`, change the signature (line 441) and insert the memory section:

```rust
pub async fn friend_chat(
    friend_a_id: &str,
    friend_a_name: &str,
    friend_a_personality: &str,
    friend_b_id: &str,
    friend_b_name: &str,
    friend_b_personality: &str,
    topic: Option<&str>,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let language = crate::onboarding::get_language();
    let memory_section = format!(
        "{}\n{}",
        crate::friend_memory::get_chat_context(friend_a_id, friend_b_id),
        crate::friend_memory::get_chat_context(friend_b_id, friend_a_id),
    );
```

and in the `system_prompt` `format!`, after the line `Write a 2-4 line exchange. …desktop.`, add (with a matching `mem = memory_section,` binding in the `format!` args):

```text
WHAT THEY KNOW:
{mem}
Let their history color the exchange subtly — a callback, a grudge, warmth. Don't recite it.
```

In `src-tauri/src/lib.rs`, update the command (line 556):

```rust
#[tauri::command]
async fn friend_ai_chat(
    friend_a_id: String,
    friend_a_name: String,
    friend_a_personality: String,
    friend_b_id: String,
    friend_b_name: String,
    friend_b_personality: String,
    topic: Option<String>,
) -> Result<String, String> {
    eprintln!("[co-sheep] Friend AI chat: {} ({}) <-> {} ({})", friend_a_name, friend_a_personality, friend_b_name, friend_b_personality);
    vision::friend_chat(&friend_a_id, &friend_a_name, &friend_a_personality, &friend_b_id, &friend_b_name, &friend_b_personality, topic.as_deref())
        .await
        .map_err(|e| e.to_string())
}
```

- [ ] **Step 5: Pass ids from the frontend**

`src/flock.ts:1089` (inside `startAIConversation`, `idA`/`idB` are parameters):

```typescript
    invoke<string>("friend_ai_chat", {
      friendAId: idA,
      friendAName: entryA.sheep.name,
      friendAPersonality: entryA.personality,
      friendBId: idB,
      friendBName: entryB.sheep.name,
      friendBPersonality: entryB.personality,
    }).then((raw) => {
```

`src/drama-manager.ts:251` (inside `maybeNarrate`, `t.idA`/`t.idB` in scope):

```typescript
    invoke<string>("friend_ai_chat", {
      friendAId: t.idA,
      friendAName: a.sheep.name,
      friendAPersonality: a.personality,
      friendBId: t.idB,
      friendBName: b.sheep.name,
      friendBPersonality: b.personality,
      topic: `their relationship just changed from ${t.from} to ${t.to} because of ${t.cause}`,
    }).then((raw) => {
```

- [ ] **Step 6: Delete the legacy memory.md shim**

In `src-tauri/src/memory.rs`, delete the entire `Backward compat` section (lines 309-320): the section banner comment and `pub fn get_long_term_memory`.

- [ ] **Step 7: Full verification**

Run: `cd src-tauri && cargo test && cargo build`
Expected: all tests PASS, build clean, no dead-code warnings for the removed fns.

Run: `pnpm tsc --noEmit && pnpm vitest run`
Expected: clean typecheck, 40 tests PASS.

- [ ] **Step 8: Commit**

```bash
git add src-tauri/src/friend_memory.rs src-tauri/src/vision.rs src-tauri/src/lib.rs src-tauri/src/memory.rs src/flock.ts src/drama-manager.ts
git commit -m "Recall friend memories in friend chats; drop dead memory shims

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Manual live verification (requires the sidecar / Apple Intelligence)

No code — a checklist against the running app, since `cargo test` cannot reach the model.

- [ ] **Step 1: Launch dev app and watch reflection**

Run: `pnpm tauri dev` and watch stderr.
Expected within ~2 minutes: `[co-sheep] Reflection: consolidating <yesterday>` then `Reflection applied: ApplyStats {...}`; `~/.co-sheep/opinions.json` gains `last_reflection_date` = today and `opinions.json.bak` exists. Today's journal ends with `*Slept on it. Tidied my thoughts.*`.

- [ ] **Step 2: Watch backfill progress**

Expected: every ~3 minutes, `[co-sheep] Backfill: distilling journal <date>` advancing oldest-first; `backfill_cursor` in `opinions.json` advances; opinion list grows/merges but **never shrinks** during backfill (prune disabled).

- [ ] **Step 3: Situational recall spot-check**

Open a site matching a strong opinion topic (e.g. Twitter), use the tray's "Comment Now", and confirm the comment references the existing opinion rather than forming a duplicate topic key.

- [ ] **Step 4: Friend chat recall spot-check**

Trigger a friend AI chat (wait for one, or lower `aiChatCooldown` temporarily) and confirm stderr shows the WHAT THEY KNOW section flowing through, with dialogue that isn't stranger-talk.

- [ ] **Step 5: Restart safety**

Quit and relaunch the app. Expected: no second reflection the same day (`last_reflection_date` guard), backfill resumes from the cursor, brains load without serde errors.

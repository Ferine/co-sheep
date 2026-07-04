//! Memory consolidation — the sheep sleeps on it.
//!
//! A reflection pass feeds a day's journal plus the opinion list to the
//! on-device model, which proposes explicit ops (merge/update/prune/add).
//! Rust validates and applies them: model proposes, Rust disposes.

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

const LOOP_INTERVAL_SECS: u64 = 180;

/// Background loop: daily reflection, then (Task 7) one backfill step per
/// interval — only while the vision pipeline isn't mid-tick.
pub async fn reflection_loop() {
    tokio::time::sleep(std::time::Duration::from_secs(90)).await;
    loop {
        if !crate::VISION_TICK_RUNNING.load(std::sync::atomic::Ordering::Relaxed) {
            run_daily_reflection().await;
            run_backfill_step().await;
        }
        tokio::time::sleep(std::time::Duration::from_secs(LOOP_INTERVAL_SECS)).await;
    }
}

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
}

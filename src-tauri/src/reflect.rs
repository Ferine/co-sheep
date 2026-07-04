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

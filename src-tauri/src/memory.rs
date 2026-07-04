use chrono::Local;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

/// Serializes load→mutate→save cycles on opinions.json so concurrent
/// commands (vision loop, chat, interactions) don't drop each other's writes.
static BRAIN_LOCK: Mutex<()> = Mutex::new(());

/// Last `max_bytes` of `s`, cut forward to a char boundary so slicing
/// never panics on multibyte UTF-8 (the journal is full of æ/ø/å).
pub(crate) fn tail_at_char_boundary(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let mut start = s.len() - max_bytes;
    while !s.is_char_boundary(start) {
        start += 1;
    }
    &s[start..]
}

fn sheep_dir() -> PathBuf {
    let home = dirs::home_dir().expect("Could not find home directory");
    home.join(".co-sheep")
}

fn journal_dir() -> PathBuf {
    sheep_dir().join("journal")
}

fn today_journal_path() -> PathBuf {
    let date = Local::now().format("%Y-%m-%d").to_string();
    journal_dir().join(format!("{}.md", date))
}

fn opinions_path() -> PathBuf {
    sheep_dir().join("opinions.json")
}

// ═══════════════════════════════════════════════════════════
// Opinions — the sheep's persistent beliefs about its human.
// Each opinion has a conviction score that grows with repeated
// observations, letting the sheep say things like
// "that's the 5th time today" naturally.
// ═══════════════════════════════════════════════════════════

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Opinion {
    /// Short topic key for dedup (e.g. "twitter_usage", "dark_mode", "rust_project")
    pub topic: String,
    /// The sheep's opinion text, evolves over time
    pub opinion: String,
    /// How many times this pattern has been observed
    pub times_seen: u32,
    /// First time noticed
    pub first_seen: String,
    /// Most recent observation
    pub last_seen: String,
    /// Category: "habit", "fact", "opinion", "pattern"
    pub category: String,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct SheepBrain {
    pub opinions: Vec<Opinion>,
    /// Counts for today — reset daily. Tracks things like "twitter visits today"
    pub today_counts: std::collections::HashMap<String, u32>,
    /// Which date the today_counts belong to
    pub counts_date: String,
    /// Total times the sheep has commented
    pub total_comments: u32,
    /// Total user interactions (pets, double-clicks, file drops)
    pub total_interactions: u32,
    /// Date the daily reflection pass last ran (or was marked done)
    #[serde(default)]
    pub last_reflection_date: String,
    /// Last journal date processed by the historical backfill
    #[serde(default)]
    pub backfill_cursor: String,
}

impl Default for SheepBrain {
    fn default() -> Self {
        Self {
            opinions: Vec::new(),
            today_counts: std::collections::HashMap::new(),
            counts_date: Local::now().format("%Y-%m-%d").to_string(),
            total_comments: 0,
            total_interactions: 0,
            last_reflection_date: String::new(),
            backfill_cursor: String::new(),
        }
    }
}

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

pub fn load_brain() -> SheepBrain {
    let path = opinions_path();
    if !path.exists() {
        return SheepBrain::default();
    }
    let content = fs::read_to_string(path).unwrap_or_default();
    let mut brain: SheepBrain = serde_json::from_str(&content).unwrap_or_default();

    // Reset daily counts if it's a new day
    let today = Local::now().format("%Y-%m-%d").to_string();
    if brain.counts_date != today {
        brain.today_counts.clear();
        brain.counts_date = today;
    }

    brain
}

fn save_brain(brain: &SheepBrain) -> Result<(), Box<dyn std::error::Error>> {
    let dir = sheep_dir();
    fs::create_dir_all(&dir)?;
    let json = serde_json::to_string_pretty(brain)?;
    fs::write(opinions_path(), json)?;
    Ok(())
}

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

/// Called by the AI to save or update an opinion.
/// If topic already exists, updates the opinion text and increments the count.
/// If new, creates it.
pub fn save_opinion(
    topic: &str,
    opinion_text: &str,
    category: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let _guard = BRAIN_LOCK.lock().unwrap();
    let topic = canonicalize_topic(topic);
    let mut brain = load_brain();
    let now = Local::now().format("%Y-%m-%d %H:%M").to_string();
    let today = Local::now().format("%Y-%m-%d").to_string();

    if let Some(existing) = brain.opinions.iter_mut().find(|o| o.topic == topic) {
        existing.times_seen += 1;
        existing.last_seen = now;
        // Update opinion text if the AI has refined it
        if !opinion_text.is_empty() {
            existing.opinion = opinion_text.to_string();
        }
        eprintln!(
            "[co-sheep] Opinion updated: {} (seen {} times)",
            topic, existing.times_seen
        );
    } else {
        brain.opinions.push(Opinion {
            topic: topic.to_string(),
            opinion: opinion_text.to_string(),
            times_seen: 1,
            first_seen: today,
            last_seen: now,
            category: category.to_string(),
        });
        eprintln!("[co-sheep] New opinion formed: {}", topic);
    }

    save_brain(&brain)
}

/// Increment a daily counter (e.g. "twitter_visits") and return the new count.
pub fn increment_today(key: &str) -> u32 {
    let _guard = BRAIN_LOCK.lock().unwrap();
    let mut brain = load_brain();
    let count = brain.today_counts.entry(key.to_string()).or_insert(0);
    *count += 1;
    let result = *count;
    save_brain(&brain).ok();
    result
}

/// Record that the sheep made a comment
pub fn record_comment() {
    let _guard = BRAIN_LOCK.lock().unwrap();
    let mut brain = load_brain();
    brain.total_comments += 1;
    save_brain(&brain).ok();
}

/// Record a user interaction (pet, double-click, file drop, etc.)
pub fn record_interaction(interaction_type: &str) {
    {
        let _guard = BRAIN_LOCK.lock().unwrap();
        let mut brain = load_brain();
        brain.total_interactions += 1;
        save_brain(&brain).ok();
    }

    // Also log to today's journal
    append_journal(&format!("*My human {} me!*", interaction_type)).ok();
}

// ═══════════════════════════════════════════════════════════
// Daily Journal — raw timestamped observations
// ═══════════════════════════════════════════════════════════

pub fn append_journal(entry: &str) -> Result<(), Box<dyn std::error::Error>> {
    let dir = journal_dir();
    fs::create_dir_all(&dir)?;

    let path = today_journal_path();
    let time = Local::now().format("%I:%M %p").to_string();

    let formatted = if path.exists() {
        format!("\n## {}\n{}\n", time, entry)
    } else {
        let date_header = Local::now().format("%B %d, %Y").to_string();
        let name = crate::onboarding::get_sheep_name().unwrap_or_else(|| "Sheep".to_string());
        format!(
            "# {} — {}'s Diary\n\n## {}\n{}\n",
            date_header, name, time, entry
        )
    };

    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    file.write_all(formatted.as_bytes())?;

    Ok(())
}

/// Returns recent journal entries from today (last ~2000 chars).
pub fn get_today_journal() -> Result<String, Box<dyn std::error::Error>> {
    let path = today_journal_path();
    if !path.exists() {
        return Ok(String::new());
    }

    let content = fs::read_to_string(&path)?;
    Ok(tail_at_char_boundary(&content, 2000).to_string())
}

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

// ═══════════════════════════════════════════════════════════
// Combined Context — what gets fed to the model
// ═══════════════════════════════════════════════════════════

/// Build the full context for the AI: opinions + daily counts + recent journal.
/// This is what lets the sheep feel like it *knows* you.
/// Build the full context for the AI: opinions + daily counts + recent journal.
/// `query` (screen text or chat message) steers which opinions surface.
pub fn get_recent_context(query: Option<&str>) -> Result<String, Box<dyn std::error::Error>> {
    let mut parts = Vec::new();
    let brain = load_brain();

    // 1. Opinions — sorted by conviction (times_seen), strongest first
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

    // 2. Today's pattern counts
    if !brain.today_counts.is_empty() {
        let mut counts: Vec<String> = brain
            .today_counts
            .iter()
            .map(|(k, v)| format!("- {}: {} times today", k, v))
            .collect();
        counts.sort();
        parts.push(format!("## Today's tallies\n{}", counts.join("\n")));
    }

    // 3. Stats
    parts.push(format!(
        "## Stats\nTotal comments made: {}\nTotal interactions with human: {}",
        brain.total_comments, brain.total_interactions
    ));

    // 4. Today's journal (recent observations)
    let journal = get_today_journal()?;
    if !journal.is_empty() {
        // Only the tail — the opinions carry the persistent knowledge
        let tail = if journal.len() > 1200 {
            let approx = tail_at_char_boundary(&journal, 1200);
            // Start at the next full line if we cut mid-line
            approx
                .find('\n')
                .map(|i| &approx[i + 1..])
                .unwrap_or(approx)
        } else {
            &journal
        };
        parts.push(format!("## Recent diary entries (today)\n{}", tail));
    }

    Ok(parts.join("\n\n"))
}

/// For the memory viewer UI — returns both opinions and journal
pub fn get_brain_for_display() -> serde_json::Value {
    let brain = load_brain();
    let journal = get_today_journal().unwrap_or_default();

    serde_json::json!({
        "opinions": brain.opinions,
        "today_counts": brain.today_counts,
        "total_comments": brain.total_comments,
        "total_interactions": brain.total_interactions,
        "today_journal": journal,
    })
}

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

    #[test]
    fn canonicalize_lowercases_and_underscores() {
        assert_eq!(canonicalize_topic("  Twitter Usage "), "twitter_usage");
        assert_eq!(canonicalize_topic("dark_mode"), "dark_mode");
        assert_eq!(canonicalize_topic("Tab   Hoarding"), "tab_hoarding");
    }

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
}

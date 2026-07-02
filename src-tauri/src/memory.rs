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
fn tail_at_char_boundary(s: &str, max_bytes: usize) -> &str {
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
}

impl Default for SheepBrain {
    fn default() -> Self {
        Self {
            opinions: Vec::new(),
            today_counts: std::collections::HashMap::new(),
            counts_date: Local::now().format("%Y-%m-%d").to_string(),
            total_comments: 0,
            total_interactions: 0,
        }
    }
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

/// Called by the AI to save or update an opinion.
/// If topic already exists, updates the opinion text and increments the count.
/// If new, creates it.
pub fn save_opinion(
    topic: &str,
    opinion_text: &str,
    category: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let _guard = BRAIN_LOCK.lock().unwrap();
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

// ═══════════════════════════════════════════════════════════
// Combined Context — what gets fed to Sonnet
// ═══════════════════════════════════════════════════════════

/// Build the full context for the AI: opinions + daily counts + recent journal.
/// This is what lets the sheep feel like it *knows* you.
pub fn get_recent_context() -> Result<String, Box<dyn std::error::Error>> {
    let mut parts = Vec::new();
    let brain = load_brain();

    // 1. Opinions — sorted by conviction (times_seen), strongest first
    if !brain.opinions.is_empty() {
        let mut sorted = brain.opinions.clone();
        sorted.sort_by(|a, b| b.times_seen.cmp(&a.times_seen));

        let mut opinion_lines: Vec<String> = Vec::new();
        for op in sorted.iter().take(20) {
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

// ═══════════════════════════════════════════════════════════
// Backward compat — old memory.md migration
// ═══════════════════════════════════════════════════════════

/// Returns old memory.md content for migration/display, then can be removed
pub fn get_long_term_memory() -> String {
    let path = sheep_dir().join("memory.md");
    if !path.exists() {
        return String::new();
    }
    fs::read_to_string(path).unwrap_or_default()
}

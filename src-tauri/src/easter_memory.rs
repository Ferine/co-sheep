use chrono::{Duration, Local};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Clone, Default)]
pub struct EasterHunterStats {
    pub sheep_id: String,
    pub sheep_name: String,
    #[serde(default)]
    pub eggs_found_total: u32,
    #[serde(default)]
    pub eggs_found_today: u32,
    #[serde(default)]
    pub golden_eggs_found: u32,
    #[serde(default)]
    pub hunts_won: u32,
    #[serde(default)]
    pub hunts_participated: u32,
}

#[derive(Serialize, Deserialize, Clone, Default)]
pub struct EasterStats {
    #[serde(default)]
    pub last_reset_date: String,
    #[serde(default)]
    pub last_hunt_date: String,
    #[serde(default)]
    pub eggs_found_total: u32,
    #[serde(default)]
    pub eggs_found_today: u32,
    #[serde(default)]
    pub golden_eggs_total: u32,
    #[serde(default)]
    pub golden_eggs_today: u32,
    #[serde(default)]
    pub hunts_completed: u32,
    #[serde(default)]
    pub hunts_today: u32,
    #[serde(default)]
    pub current_streak: u32,
    #[serde(default)]
    pub best_streak: u32,
    #[serde(default)]
    pub painted_eggs_used_total: u32,
    #[serde(default)]
    pub flock_score: u32,
    #[serde(default)]
    pub top_hunter_id: String,
    #[serde(default)]
    pub top_hunter_name: String,
    #[serde(default)]
    pub last_winner_id: String,
    #[serde(default)]
    pub last_winner_name: String,
    #[serde(default)]
    pub hunters: HashMap<String, EasterHunterStats>,
}

// These two arrive from the frontend, which sends camelCase keys
// (totalEggs, eggsFound, ...); without the rename every field would
// silently fall back to its serde default.
#[derive(Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct EasterHunterResult {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub eggs_found: u32,
    #[serde(default)]
    pub golden_eggs_found: u32,
}

#[derive(Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct EasterHuntResult {
    #[serde(default)]
    pub total_eggs: u32,
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default)]
    pub all_collected: bool,
    #[serde(default)]
    pub painted_eggs_used: u32,
    #[serde(default)]
    pub hunters: Vec<EasterHunterResult>,
}

fn stats_path() -> PathBuf {
    let home = dirs::home_dir().expect("No home directory");
    home.join(".co-sheep").join("easter.json")
}

fn today() -> String {
    Local::now().format("%Y-%m-%d").to_string()
}

fn yesterday() -> String {
    (Local::now() - Duration::days(1))
        .format("%Y-%m-%d")
        .to_string()
}

fn default_stats() -> EasterStats {
    EasterStats {
        last_reset_date: today(),
        ..EasterStats::default()
    }
}

fn load_stats() -> EasterStats {
    let path = stats_path();
    if !path.exists() {
        return default_stats();
    }

    match fs::read_to_string(path) {
        Ok(content) => serde_json::from_str(&content).unwrap_or_else(|_| default_stats()),
        Err(_) => default_stats(),
    }
}

fn save_stats(stats: &EasterStats) {
    if let Some(dir) = stats_path().parent() {
        fs::create_dir_all(dir).ok();
    }
    let json = serde_json::to_string_pretty(stats).unwrap_or_default();
    fs::write(stats_path(), json).ok();
}

fn reset_daily_counters_if_needed(stats: &mut EasterStats) -> bool {
    let today_str = today();
    if stats.last_reset_date == today_str {
        return false;
    }

    stats.last_reset_date = today_str;
    stats.eggs_found_today = 0;
    stats.golden_eggs_today = 0;
    stats.hunts_today = 0;
    for hunter in stats.hunters.values_mut() {
        hunter.eggs_found_today = 0;
    }
    true
}

fn recalculate_leaderboard(stats: &mut EasterStats) {
    if let Some(best) = stats.hunters.values().max_by(|a, b| {
        a.eggs_found_total
            .cmp(&b.eggs_found_total)
            .then(a.golden_eggs_found.cmp(&b.golden_eggs_found))
            .then(a.hunts_won.cmp(&b.hunts_won))
    }) {
        stats.top_hunter_id = best.sheep_id.clone();
        stats.top_hunter_name = best.sheep_name.clone();
    } else {
        stats.top_hunter_id.clear();
        stats.top_hunter_name.clear();
    }

    stats.flock_score = stats.eggs_found_total
        + (stats.golden_eggs_total * 4)
        + (stats.hunts_completed * 3)
        + (stats.best_streak * 2)
        + stats.painted_eggs_used_total;
}

fn update_streak(stats: &mut EasterStats) {
    let today_str = today();
    if stats.last_hunt_date == today_str {
        return;
    }

    if stats.last_hunt_date == yesterday() {
        stats.current_streak += 1;
    } else {
        stats.current_streak = 1;
    }
    stats.best_streak = stats.best_streak.max(stats.current_streak);
    stats.last_hunt_date = today_str;
}

pub fn get_stats() -> EasterStats {
    let mut stats = load_stats();
    let changed = reset_daily_counters_if_needed(&mut stats);
    recalculate_leaderboard(&mut stats);
    if changed {
        save_stats(&stats);
    }
    stats
}

pub fn record_hunt(result: EasterHuntResult) -> EasterStats {
    let mut stats = load_stats();
    reset_daily_counters_if_needed(&mut stats);

    let total_found: u32 = result.hunters.iter().map(|hunter| hunter.eggs_found).sum();
    let golden_found: u32 = result
        .hunters
        .iter()
        .map(|hunter| hunter.golden_eggs_found)
        .sum();

    stats.eggs_found_total += total_found;
    stats.eggs_found_today += total_found;
    stats.golden_eggs_total += golden_found;
    stats.golden_eggs_today += golden_found;
    stats.painted_eggs_used_total += result.painted_eggs_used;
    stats.hunts_today += 1;

    let winner_id = result
        .hunters
        .iter()
        .max_by(|a, b| {
            a.eggs_found
                .cmp(&b.eggs_found)
                .then(a.golden_eggs_found.cmp(&b.golden_eggs_found))
        })
        .map(|hunter| hunter.id.clone())
        .unwrap_or_default();

    for hunter in &result.hunters {
        let entry = stats
            .hunters
            .entry(hunter.id.clone())
            .or_insert_with(|| EasterHunterStats {
                sheep_id: hunter.id.clone(),
                sheep_name: hunter.name.clone(),
                ..EasterHunterStats::default()
            });

        entry.sheep_name = hunter.name.clone();
        entry.eggs_found_total += hunter.eggs_found;
        entry.eggs_found_today += hunter.eggs_found;
        entry.golden_eggs_found += hunter.golden_eggs_found;
        entry.hunts_participated += 1;
        if hunter.id == winner_id && hunter.eggs_found > 0 {
            entry.hunts_won += 1;
            stats.last_winner_id = hunter.id.clone();
            stats.last_winner_name = hunter.name.clone();
        }
    }

    if result.all_collected {
        stats.hunts_completed += 1;
        update_streak(&mut stats);
    }

    recalculate_leaderboard(&mut stats);
    save_stats(&stats);
    stats
}

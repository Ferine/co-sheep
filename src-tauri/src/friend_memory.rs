use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};

#[derive(Serialize, Deserialize, Clone)]
pub struct FriendBrain {
    pub id: String,
    pub name: String,
    pub mood: String,
    pub relationships: HashMap<String, i32>,
    pub memories: Vec<FriendMemory>,
    pub stats: FriendStats,
    pub last_mood_change: String,
    /// Last date decay_affinities ran for this brain — persisted so app
    /// restarts within the same day don't decay/age the brain again.
    #[serde(default)]
    pub last_decay_date: String,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct FriendMemory {
    pub text: String,
    pub kind: String,
    pub timestamp: String,
    #[serde(default)]
    pub with: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Default)]
pub struct FriendStats {
    pub conversations_today: u32,
    pub conversations_total: u32,
    pub times_petted: u32,
    pub group_activities: u32,
    pub days_alive: u32,
}

static CACHE: LazyLock<Mutex<HashMap<String, FriendBrain>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

static LAST_DECAY_DATE: LazyLock<Mutex<String>> =
    LazyLock::new(|| Mutex::new(String::new()));

fn friends_dir() -> PathBuf {
    // Overridable so tests can run against a temp dir instead of real data
    if let Ok(dir) = std::env::var("CO_SHEEP_HOME") {
        return PathBuf::from(dir).join("friends");
    }
    let home = dirs::home_dir().expect("No home directory");
    home.join(".co-sheep").join("friends")
}

fn friend_path(id: &str) -> PathBuf {
    friends_dir().join(format!("{}.json", id))
}

fn now_iso() -> String {
    chrono::Local::now().format("%Y-%m-%d %H:%M").to_string()
}

fn today() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

fn load_brain(id: &str) -> FriendBrain {
    let mut cache = CACHE.lock().unwrap();
    if let Some(brain) = cache.get(id) {
        return brain.clone();
    }

    let path = friend_path(id);
    let brain = if path.exists() {
        let content = fs::read_to_string(&path).unwrap_or_default();
        serde_json::from_str(&content).unwrap_or_else(|_| new_brain(id, id))
    } else {
        new_brain(id, id)
    };

    cache.insert(id.to_string(), brain.clone());
    brain
}

fn save_brain(brain: &FriendBrain) {
    let dir = friends_dir();
    fs::create_dir_all(&dir).ok();
    let json = serde_json::to_string_pretty(brain).unwrap_or_default();
    fs::write(friend_path(&brain.id), json).ok();

    let mut cache = CACHE.lock().unwrap();
    cache.insert(brain.id.clone(), brain.clone());
}

fn new_brain(id: &str, name: &str) -> FriendBrain {
    let mood = if id == "good_colleague" { "grumpy" } else { "happy" };
    let mut relationships = HashMap::new();
    if id == "good_colleague" {
        relationships.insert("main".to_string(), 10);
    }
    FriendBrain {
        id: id.to_string(),
        name: name.to_string(),
        mood: mood.to_string(),
        relationships,
        memories: Vec::new(),
        stats: FriendStats::default(),
        last_mood_change: now_iso(),
        last_decay_date: today(),
    }
}

fn add_memory(brain: &mut FriendBrain, text: &str, kind: &str, with: Option<String>) {
    brain.memories.push(FriendMemory {
        text: text.to_string(),
        kind: kind.to_string(),
        timestamp: now_iso(),
        with,
    });
    // Keep only the most recent 20
    if brain.memories.len() > 20 {
        brain.memories.drain(0..brain.memories.len() - 20);
    }
}

fn adjust_affinity(brain: &mut FriendBrain, other_id: &str, delta: i32) {
    let current = brain.relationships.get(other_id).copied().unwrap_or(0);
    let new_val = (current + delta).clamp(-10, 100);
    brain.relationships.insert(other_id.to_string(), new_val);
}

// --- Public API ---

pub fn ensure_brain(id: &str, name: &str) {
    let mut cache = CACHE.lock().unwrap();
    if cache.contains_key(id) {
        return;
    }
    let path = friend_path(id);
    let brain = if path.exists() {
        let content = fs::read_to_string(&path).unwrap_or_default();
        let mut b: FriendBrain = serde_json::from_str(&content).unwrap_or_else(|_| new_brain(id, name));
        b.name = name.to_string();
        b
    } else {
        new_brain(id, name)
    };
    cache.insert(id.to_string(), brain);
}

pub fn record_conversation(id_a: &str, id_b: &str, topic: &str) {
    let name_b = {
        let b = load_brain(id_b);
        b.name.clone()
    };
    let name_a = {
        let a = load_brain(id_a);
        a.name.clone()
    };

    let mut a = load_brain(id_a);
    adjust_affinity(&mut a, id_b, 1);
    add_memory(&mut a, &format!("Talked with {} about {}", name_b, topic), "conversation", Some(id_b.to_string()));
    a.stats.conversations_total += 1;
    a.stats.conversations_today += 1;
    save_brain(&a);

    let mut b = load_brain(id_b);
    adjust_affinity(&mut b, id_a, 1);
    add_memory(&mut b, &format!("Talked with {} about {}", name_a, topic), "conversation", Some(id_a.to_string()));
    b.stats.conversations_total += 1;
    b.stats.conversations_today += 1;
    save_brain(&b);
}

pub fn record_group_activity(participant_ids: &[String], activity_type: &str) {
    let names: HashMap<String, String> = participant_ids
        .iter()
        .map(|id| (id.clone(), load_brain(id).name.clone()))
        .collect();

    for id in participant_ids {
        let mut brain = load_brain(id);
        let other_names: Vec<&str> = participant_ids
            .iter()
            .filter(|other| *other != id)
            .map(|other| names.get(other).map(|n| n.as_str()).unwrap_or("someone"))
            .collect();
        let text = format!("Joined a {} with {}", activity_type, other_names.join(", "));
        add_memory(&mut brain, &text, "activity", None);
        brain.stats.group_activities += 1;
        for other_id in participant_ids {
            if other_id != id {
                adjust_affinity(&mut brain, other_id, 2);
            }
        }
        save_brain(&brain);
    }
}

pub fn record_pet(id: &str) {
    let mut brain = load_brain(id);
    adjust_affinity(&mut brain, "main", 1);
    add_memory(&mut brain, "Got petted by human!", "interaction", Some("main".to_string()));
    brain.stats.times_petted += 1;
    brain.mood = "happy".to_string();
    brain.last_mood_change = now_iso();
    save_brain(&brain);
}

/// A friend was removed: delete its brain, evict it from the cache (or the
/// Relationships viewer shows a ghost until restart), and scrub its id from
/// every remaining brain's relationships map. Memories that mention it are
/// kept on purpose — the flock remembers the departed.
pub fn remove_brain(id: &str) {
    fs::remove_file(friend_path(id)).ok();
    CACHE.lock().unwrap().remove(id);

    let Ok(entries) = fs::read_dir(friends_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(other_id) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if other_id == id {
            continue;
        }
        let mut brain = load_brain(other_id);
        if brain.relationships.remove(id).is_some() {
            save_brain(&brain);
        }
    }
}

pub fn get_mood(id: &str) -> String {
    load_brain(id).mood.clone()
}

pub fn get_friend_brain_json(id: &str) -> serde_json::Value {
    let brain = load_brain(id);
    serde_json::to_value(&brain).unwrap_or_default()
}

pub fn get_all_relationships() -> serde_json::Value {
    let cache = CACHE.lock().unwrap();
    let mut result = serde_json::Map::new();
    for (id, brain) in cache.iter() {
        result.insert(
            id.clone(),
            serde_json::json!({
                "name": brain.name,
                "mood": brain.mood,
                "relationships": brain.relationships,
                "stats": {
                    "conversations_total": brain.stats.conversations_total,
                    "times_petted": brain.stats.times_petted,
                    "group_activities": brain.stats.group_activities,
                }
            }),
        );
    }
    serde_json::Value::Object(result)
}

pub fn get_all_moods() -> HashMap<String, String> {
    let cache = CACHE.lock().unwrap();
    cache.iter().map(|(id, b)| (id.clone(), b.mood.clone())).collect()
}

pub fn decay_affinities() {
    let today_str = today();
    {
        // Cheap in-process fast path; the real once-per-day guard is the
        // persisted per-brain last_decay_date below.
        let mut last = LAST_DECAY_DATE.lock().unwrap();
        if *last == today_str {
            return;
        }
        *last = today_str.clone();
    }

    let mut cache = CACHE.lock().unwrap();
    for brain in cache.values_mut() {
        if brain.last_decay_date == today_str {
            continue;
        }
        brain.last_decay_date = today_str.clone();
        // Reset daily conversation count
        brain.stats.conversations_today = 0;
        brain.stats.days_alive += 1;
        // Decay affinities by 1
        for val in brain.relationships.values_mut() {
            if *val > 0 {
                *val -= 1;
            } else if *val < -5 {
                *val = -5;
            }
        }
        // Save to disk
        let dir = friends_dir();
        fs::create_dir_all(&dir).ok();
        let json = serde_json::to_string_pretty(brain).unwrap_or_default();
        fs::write(friend_path(&brain.id), json).ok();
    }
}

pub fn update_mood(id: &str) {
    let mut brain = load_brain(id);
    let convos = brain.stats.conversations_today;
    let hour = chrono::Local::now().format("%H").to_string().parse::<u32>().unwrap_or(12);

    let new_mood = if convos >= 5 {
        "excited"
    } else if convos >= 2 {
        "happy"
    } else if hour >= 23 || hour <= 4 {
        "sleepy"
    } else if brain.stats.times_petted > 0 && brain.mood == "happy" {
        "happy"
    } else if id == "good_colleague" {
        "grumpy" // GC defaults to grumpy
    } else {
        // Drift toward neutral
        match brain.mood.as_str() {
            "excited" => "happy",
            _ => "happy",
        }
    };

    if brain.mood != new_mood {
        brain.mood = new_mood.to_string();
        brain.last_mood_change = now_iso();
        save_brain(&brain);
    }
}

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

#[cfg(test)]
mod tests {
    use super::*;

    /// One test covering the whole removal scenario — the brain CACHE and
    /// CO_SHEEP_HOME are process-global, so splitting this into multiple
    /// parallel tests would race.
    #[test]
    fn remove_brain_deletes_file_and_scrubs_relationships() {
        let tmp = std::env::temp_dir().join(format!("co-sheep-test-{}", std::process::id()));
        std::env::set_var("CO_SHEEP_HOME", &tmp);

        ensure_brain("friend_a", "A");
        ensure_brain("friend_b", "B");
        record_conversation("friend_a", "friend_b", "tabs vs spaces");

        assert!(friend_path("friend_a").exists());
        assert!(get_friend_brain_json("friend_b")["relationships"]
            .get("friend_a")
            .is_some());

        remove_brain("friend_a");

        assert!(!friend_path("friend_a").exists(), "brain file must be deleted");
        assert!(
            !CACHE.lock().unwrap().contains_key("friend_a"),
            "cache must evict the removed brain"
        );
        assert!(
            get_friend_brain_json("friend_b")["relationships"]
                .get("friend_a")
                .is_none(),
            "other brains must be scrubbed"
        );
        // Scrub must persist, not just touch the cache. Memories still
        // mention the departed friend by design — only relationships scrub.
        let on_disk: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(friend_path("friend_b")).unwrap())
                .unwrap();
        assert!(on_disk["relationships"].get("friend_a").is_none());
        assert!(on_disk["memories"][0]["with"].as_str() == Some("friend_a"));

        std::fs::remove_dir_all(&tmp).ok();
    }

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
}

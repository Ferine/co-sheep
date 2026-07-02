use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

/// Serializes read-modify-write cycles on config.json so concurrent
/// commands (settings save, add/remove friend, wardrobe) can't drop
/// each other's changes.
static CONFIG_LOCK: Mutex<()> = Mutex::new(());

#[derive(Serialize, Deserialize, Clone)]
pub struct FriendDef {
    pub id: String,
    pub name: String,
    pub color: String,
    #[serde(default = "default_friend_personality")]
    pub personality: String,
    #[serde(default)]
    pub accessories: Vec<String>,
    #[serde(default = "default_friend_scale")]
    pub scale: f64,
}

fn default_friend_personality() -> String {
    "wholesome".to_string()
}

fn default_friend_scale() -> f64 {
    1.0
}

// AI runs exclusively on-device (Apple Intelligence); old provider fields
// (api_key, ai_provider, lmstudio_*) in existing config files are ignored.
#[derive(Serialize, Deserialize, Clone)]
pub struct SheepConfig {
    pub name: String,
    pub personality: String,
    pub interval_secs: u64,
    #[serde(default = "default_language")]
    pub language: String,
    #[serde(default)]
    pub friends: Vec<FriendDef>,
    #[serde(default = "default_break_reminders")]
    pub break_reminders: bool,
    #[serde(default = "default_easter_mode")]
    pub easter_mode: String,
    #[serde(default = "default_summer_mode")]
    pub summer_mode: String,
    #[serde(default)]
    pub weather_location: String,
    #[serde(default)]
    pub accessories: Vec<String>,
}

fn default_language() -> String {
    "nynorsk".to_string()
}

fn default_break_reminders() -> bool {
    true
}

fn default_easter_mode() -> String {
    "auto".to_string()
}

fn default_summer_mode() -> String {
    "auto".to_string()
}

impl Default for SheepConfig {
    fn default() -> Self {
        Self {
            name: "Sheep".to_string(),
            personality: "snarky".to_string(),
            interval_secs: 150,
            language: "nynorsk".to_string(),
            friends: Vec::new(),
            break_reminders: true,
            easter_mode: "auto".to_string(),
            summer_mode: "auto".to_string(),
            weather_location: String::new(),
            accessories: Vec::new(),
        }
    }
}

fn config_path() -> PathBuf {
    let home = dirs::home_dir().expect("Could not find home directory");
    home.join(".co-sheep").join("config.json")
}

pub fn needs_onboarding() -> Result<bool, Box<dyn std::error::Error>> {
    Ok(!config_path().exists())
}

pub fn save_config(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    // Preserve existing config if it exists, just update the name
    update_config(|c| c.name = name.to_string()).map(|_| ())
}

/// Load for a read-modify-write: a missing file yields defaults, but a
/// corrupt file is an error — otherwise the next save would silently
/// replace the API key, friends, and settings with defaults.
fn load_config_strict() -> Result<SheepConfig, Box<dyn std::error::Error>> {
    let path = config_path();
    if !path.exists() {
        return Ok(SheepConfig::default());
    }
    let content = fs::read_to_string(path)?;
    Ok(serde_json::from_str(&content)?)
}

/// Locked read-modify-write of the config. All mutations must go through
/// here rather than load_config() + write_config().
pub fn update_config<F>(mutate: F) -> Result<SheepConfig, Box<dyn std::error::Error>>
where
    F: FnOnce(&mut SheepConfig),
{
    let _guard = CONFIG_LOCK.lock().unwrap();
    let mut config = load_config_strict()?;
    mutate(&mut config);
    write_config(&config)?;
    Ok(config)
}

pub fn load_config() -> Option<SheepConfig> {
    let path = config_path();
    if !path.exists() {
        return None;
    }
    let content = fs::read_to_string(path).ok()?;
    serde_json::from_str(&content).ok()
}

pub fn write_config(config: &SheepConfig) -> Result<(), Box<dyn std::error::Error>> {
    let dir = config_path().parent().unwrap().to_path_buf();
    fs::create_dir_all(&dir)?;

    let json = serde_json::to_string_pretty(config)?;
    fs::write(config_path(), json)?;

    Ok(())
}

pub fn get_sheep_name() -> Option<String> {
    load_config().map(|c| c.name)
}

pub fn get_interval_secs() -> u64 {
    load_config()
        .map(|c| c.interval_secs)
        .unwrap_or(150)
}

pub fn get_personality() -> String {
    load_config()
        .map(|c| c.personality)
        .unwrap_or_else(|| "snarky".to_string())
}

pub fn get_language() -> String {
    load_config()
        .map(|c| c.language)
        .unwrap_or_else(|| "nynorsk".to_string())
}

pub fn get_break_reminders() -> bool {
    load_config().map(|c| c.break_reminders).unwrap_or(true)
}

pub fn get_weather_location() -> String {
    load_config()
        .map(|c| c.weather_location)
        .unwrap_or_default()
}

pub fn get_easter_mode() -> String {
    load_config()
        .map(|c| c.easter_mode)
        .unwrap_or_else(default_easter_mode)
}

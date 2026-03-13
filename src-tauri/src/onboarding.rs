use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Clone)]
pub struct SheepConfig {
    pub name: String,
    pub personality: String,
    pub interval_secs: u64,
    #[serde(default)]
    pub api_key: String,
    #[serde(default = "default_language")]
    pub language: String,
    #[serde(default = "default_ai_provider")]
    pub ai_provider: String,
    #[serde(default = "default_lmstudio_endpoint")]
    pub lmstudio_endpoint: String,
    #[serde(default = "default_lmstudio_model")]
    pub lmstudio_model: String,
}

fn default_ai_provider() -> String {
    "anthropic".to_string()
}

fn default_lmstudio_endpoint() -> String {
    "http://localhost:1234".to_string()
}

fn default_lmstudio_model() -> String {
    "qwen3.5-9b".to_string()
}

fn default_language() -> String {
    "nynorsk".to_string()
}

impl Default for SheepConfig {
    fn default() -> Self {
        Self {
            name: "Sheep".to_string(),
            personality: "snarky".to_string(),
            interval_secs: 150,
            api_key: String::new(),
            language: "nynorsk".to_string(),
            ai_provider: "anthropic".to_string(),
            lmstudio_endpoint: "http://localhost:1234".to_string(),
            lmstudio_model: "qwen3.5-9b".to_string(),
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
    let mut config = load_config().unwrap_or_default();
    config.name = name.to_string();

    write_config(&config)
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

/// Returns API key from config, falling back to env var.
pub fn get_api_key() -> Option<String> {
    // Config takes priority
    if let Some(config) = load_config() {
        if !config.api_key.is_empty() {
            return Some(config.api_key);
        }
    }
    // Fall back to env var
    std::env::var("ANTHROPIC_API_KEY").ok()
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

pub fn get_ai_provider() -> String {
    load_config()
        .map(|c| c.ai_provider)
        .unwrap_or_else(|| "anthropic".to_string())
}

pub fn get_lmstudio_endpoint() -> String {
    load_config()
        .map(|c| c.lmstudio_endpoint)
        .unwrap_or_else(|| "http://localhost:1234".to_string())
}

pub fn get_lmstudio_model() -> String {
    load_config()
        .map(|c| c.lmstudio_model)
        .unwrap_or_else(|| "qwen3.5-9b".to_string())
}

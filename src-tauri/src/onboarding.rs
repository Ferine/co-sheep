use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Serialize, Deserialize)]
pub struct SheepConfig {
    pub name: String,
    pub personality: String,
    pub interval_secs: u64,
}

fn config_path() -> PathBuf {
    let home = dirs::home_dir().expect("Could not find home directory");
    home.join(".co-sheep").join("config.json")
}

pub fn needs_onboarding() -> Result<bool, Box<dyn std::error::Error>> {
    Ok(!config_path().exists())
}

pub fn save_config(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    let config = SheepConfig {
        name: name.to_string(),
        personality: "snarky".to_string(),
        interval_secs: 150,
    };

    let dir = config_path().parent().unwrap().to_path_buf();
    fs::create_dir_all(&dir)?;

    let json = serde_json::to_string_pretty(&config)?;
    fs::write(config_path(), json)?;

    Ok(())
}

pub fn get_sheep_name() -> Option<String> {
    let path = config_path();
    if !path.exists() {
        return None;
    }
    let content = fs::read_to_string(path).ok()?;
    let config: SheepConfig = serde_json::from_str(&content).ok()?;
    Some(config.name)
}

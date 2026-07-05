use serde_json::Value;
use std::fs;
use std::path::PathBuf;

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

fn state_path(name: &str) -> PathBuf {
    let home = dirs::home_dir().expect("No home directory");
    home.join(".co-sheep").join(format!("{}.json", name))
}

/// Load a named JSON state blob. Returns Value::Null if missing/invalid.
pub fn load_state(name: &str) -> Value {
    if !valid_name(name) {
        return Value::Null;
    }
    let path = state_path(name);
    if !path.exists() {
        return Value::Null;
    }
    fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null)
}

/// Persist a named JSON state blob to ~/.co-sheep/<name>.json.
pub fn save_state(name: &str, value: &Value) {
    if !valid_name(name) {
        log!("state", "error: living_state: rejected name '{}'", name);
        return;
    }
    let path = state_path(name);
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).ok();
    }
    let json = serde_json::to_string_pretty(value).unwrap_or_default();
    fs::write(path, json).ok();
}

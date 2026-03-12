use chrono::Local;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

fn journal_dir() -> PathBuf {
    let home = dirs::home_dir().expect("Could not find home directory");
    home.join(".co-sheep").join("journal")
}

fn today_journal_path() -> PathBuf {
    let date = Local::now().format("%Y-%m-%d").to_string();
    journal_dir().join(format!("{}.md", date))
}

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

pub fn get_recent_context() -> Result<String, Box<dyn std::error::Error>> {
    let path = today_journal_path();
    if !path.exists() {
        return Ok(String::new());
    }

    let content = fs::read_to_string(&path)?;

    // Return last ~2000 chars (roughly last 5 entries)
    if content.len() > 2000 {
        Ok(content[content.len() - 2000..].to_string())
    } else {
        Ok(content)
    }
}

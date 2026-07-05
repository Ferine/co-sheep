use crate::onboarding;
use serde::Deserialize;
use std::sync::{LazyLock, Mutex};
use std::time::Instant;

#[derive(Clone)]
pub struct WeatherInfo {
    pub condition: String,
    pub description: String,
    pub temp_c: Option<f64>,
}

struct WeatherCache {
    info: Option<WeatherInfo>,
    fetched_at: Option<Instant>,
}

static CACHE: LazyLock<Mutex<WeatherCache>> = LazyLock::new(|| {
    Mutex::new(WeatherCache {
        info: None,
        fetched_at: None,
    })
});

const CACHE_TTL_SECS: u64 = 30 * 60; // 30 minutes

#[derive(Deserialize)]
struct WttrResponse {
    current_condition: Vec<WttrCondition>,
}

#[derive(Deserialize)]
struct WttrCondition {
    #[serde(rename = "temp_C")]
    temp_c: String,
    #[serde(rename = "FeelsLikeC")]
    feels_like_c: String,
    humidity: String,
    #[serde(rename = "weatherDesc")]
    weather_desc: Vec<WttrDesc>,
    #[allow(dead_code)]
    #[serde(rename = "weatherCode")]
    weather_code: String,
}

#[derive(Deserialize)]
struct WttrDesc {
    value: String,
}

async fn fetch_weather(location: &str) -> Result<WeatherInfo, Box<dyn std::error::Error + Send + Sync>> {
    // Percent-encode the location as a path segment — characters like
    // '/', '?', '#' or '%' in a user-entered location would otherwise
    // corrupt the URL and drop the ?format=j1 query.
    let encoded: String = location
        .bytes()
        .map(|b| match b {
            b' ' => "+".to_string(),
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b',' => {
                (b as char).to_string()
            }
            _ => format!("%{:02X}", b),
        })
        .collect();
    let url = format!("https://wttr.in/{}?format=j1", encoded);
    log!("weather", "Fetching weather from: {}", url);

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;
    let resp = client
        .get(&url)
        .header("User-Agent", "co-sheep/0.1")
        .send()
        .await?;

    if !resp.status().is_success() {
        return Err(format!("Weather API returned {}", resp.status()).into());
    }

    let data: WttrResponse = resp.json().await?;
    let c = data
        .current_condition
        .first()
        .ok_or("No current_condition in response")?;

    let desc_text = c
        .weather_desc
        .first()
        .map(|d| d.value.clone())
        .unwrap_or_default();

    Ok(WeatherInfo {
        condition: desc_text.clone(),
        description: format!(
            "{}, {}C (feels like {}C), {}% humidity",
            desc_text, c.temp_c, c.feels_like_c, c.humidity
        ),
        temp_c: c.temp_c.parse().ok(),
    })
}

pub async fn get_weather() -> Option<WeatherInfo> {
    let location = onboarding::get_weather_location();
    if location.is_empty() {
        return None;
    }

    // Check cache
    {
        let cache = CACHE.lock().unwrap();
        if let (Some(ref info), Some(ref at)) = (&cache.info, &cache.fetched_at) {
            if at.elapsed().as_secs() < CACHE_TTL_SECS {
                return Some(info.clone());
            }
        }
    }

    // Fetch fresh
    match fetch_weather(&location).await {
        Ok(info) => {
            let mut cache = CACHE.lock().unwrap();
            cache.info = Some(info.clone());
            cache.fetched_at = Some(Instant::now());
            Some(info)
        }
        Err(e) => {
            log!("weather", "error: Weather fetch failed: {}", e);
            // Return stale cache on error
            let cache = CACHE.lock().unwrap();
            cache.info.clone()
        }
    }
}

pub async fn get_weather_context() -> String {
    match get_weather().await {
        Some(info) => format!("WEATHER: {} outside.", info.description),
        None => String::new(),
    }
}

/// Maps weather description to a simplified key for frontend effects
fn simplify_condition(desc: &str) -> &'static str {
    let desc = desc.to_lowercase();
    if desc.contains("rain") || desc.contains("drizzle") || desc.contains("shower") {
        "rain"
    } else if desc.contains("snow") || desc.contains("blizzard") || desc.contains("sleet") || desc.contains("ice") {
        "snow"
    } else if desc.contains("fog") || desc.contains("mist") || desc.contains("haze") {
        "fog"
    } else if desc.contains("cloud") || desc.contains("overcast") {
        "cloudy"
    } else {
        "clear"
    }
}

/// Simplified condition plus temperature, for frontend effects and the
/// summer event trigger.
#[derive(serde::Serialize)]
pub struct WeatherSnapshot {
    pub condition: String,
    pub temp_c: Option<f64>,
}

pub async fn get_weather_snapshot() -> Option<WeatherSnapshot> {
    let info = get_weather().await?;
    Some(WeatherSnapshot {
        condition: simplify_condition(&info.condition).to_string(),
        temp_c: info.temp_c,
    })
}

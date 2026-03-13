use crate::capture;
use crate::memory;
use crate::onboarding;
use crate::permissions;
use crate::personality;
use serde::Deserialize;
use std::sync::atomic::Ordering;
use tauri::Emitter;

#[derive(Deserialize)]
struct HaikuClassification {
    interesting: bool,
    #[allow(dead_code)]
    category: String,
    summary: String,
}

#[derive(Deserialize)]
struct SonnetResponse {
    text: String,
    animation: Option<String>,
    /// Topic key for opinion tracking (e.g. "twitter_usage")
    #[serde(default)]
    opinion_topic: Option<String>,
    /// The opinion itself
    #[serde(default)]
    opinion: Option<String>,
    /// Category: "habit", "fact", "opinion", "pattern"
    #[serde(default)]
    opinion_category: Option<String>,
    /// What to count today (e.g. "twitter_visits", "code_errors")
    #[serde(default)]
    count: Option<String>,
}

#[derive(serde::Serialize, Clone)]
struct CommentaryEvent {
    text: String,
    animation: Option<String>,
}

/// Which AI backend to use
enum AiProvider {
    Anthropic { api_key: String },
    LmStudio { endpoint: String, model: String },
}

fn get_provider() -> Result<AiProvider, String> {
    let provider = onboarding::get_ai_provider();
    match provider.as_str() {
        "lmstudio" => Ok(AiProvider::LmStudio {
            endpoint: onboarding::get_lmstudio_endpoint(),
            model: onboarding::get_lmstudio_model(),
        }),
        _ => {
            let api_key = onboarding::get_api_key()
                .ok_or("No API key configured")?;
            Ok(AiProvider::Anthropic { api_key })
        }
    }
}

pub async fn vision_loop(app: tauri::AppHandle) {
    eprintln!("[co-sheep] Vision loop started, waiting 8s for UI...");
    tokio::time::sleep(std::time::Duration::from_secs(8)).await;

    // --- Startup checks ---
    eprintln!("[co-sheep] Running prerequisite checks...");
    if !check_prerequisites(&app).await {
        eprintln!("[co-sheep] Prerequisites not met, retrying every 30s...");
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(30)).await;
            eprintln!("[co-sheep] Retrying prerequisite checks...");
            if check_prerequisites(&app).await {
                break;
            }
        }
    }
    eprintln!("[co-sheep] All prerequisites met, entering main vision loop");

    // --- Main vision loop ---
    loop {
        if !crate::COMMENTARY_PAUSED.load(Ordering::Relaxed) {
            match run_vision_pipeline(&app).await {
                Ok(()) => {}
                Err(e) => {
                    let msg = e.to_string();
                    eprintln!("[co-sheep] Vision pipeline error: {}", msg);

                    // Surface capture/permission errors to the user
                    if msg.contains("screen")
                        || msg.contains("capture")
                        || msg.contains("permission")
                    {
                        app.emit(
                            "sheep-commentary",
                            "I tried to look at your screen but something went wrong. Check that screen recording is enabled for co-sheep in System Settings > Privacy & Security > Screen Recording.",
                        ).ok();
                    }
                }
            }
        }

        // Wait based on configured interval (with ±20% randomization)
        let base = crate::onboarding::get_interval_secs();
        let jitter = (base as f64 * 0.2) as u64;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .subsec_nanos();
        let delay = base - jitter + (now as u64 % (jitter * 2 + 1));
        eprintln!("[co-sheep] Next vision check in {}s (base: {}s)", delay, base);
        tokio::time::sleep(std::time::Duration::from_secs(delay)).await;
    }
}

/// Checks API key, screen permission, and does a test capture.
/// Emits user-facing messages via speech bubble for each failure.
/// Returns true if everything is ready.
async fn check_prerequisites(app: &tauri::AppHandle) -> bool {
    // 1. Check provider config
    let provider = onboarding::get_ai_provider();
    if provider == "anthropic" {
        if crate::onboarding::get_api_key().is_none() {
            eprintln!("[co-sheep] No API key found (checked config + env)");
            app.emit(
                "sheep-commentary",
                "I can't see anything without an API key! Open Settings from the tray menu, or set ANTHROPIC_API_KEY in your environment.",
            )
            .ok();
            return false;
        }
    } else if provider == "lmstudio" {
        // Check LM Studio is reachable
        let endpoint = onboarding::get_lmstudio_endpoint();
        let url = format!("{}/v1/models", endpoint);
        eprintln!("[co-sheep] Checking LM Studio at {}...", url);
        match reqwest::Client::new().get(&url).send().await {
            Ok(resp) if resp.status().is_success() => {
                eprintln!("[co-sheep] LM Studio is reachable");
            }
            Ok(resp) => {
                eprintln!("[co-sheep] LM Studio returned status {}", resp.status());
                app.emit(
                    "sheep-commentary",
                    "LM Studio is running but returned an error. Check that a model is loaded!",
                )
                .ok();
                return false;
            }
            Err(e) => {
                eprintln!("[co-sheep] Can't reach LM Studio: {}", e);
                app.emit(
                    "sheep-commentary",
                    "Can't reach LM Studio! Make sure it's running and the server is started.",
                )
                .ok();
                return false;
            }
        }
    }

    // 2. Check screen capture permission by actually trying a capture.
    if !permissions::has_screen_capture_permission() {
        eprintln!("[co-sheep] CGPreflight says no permission — requesting dialog");
        permissions::request_screen_capture_permission();
    }

    // 3. Test capture — the real permission check
    match tokio::task::spawn_blocking(|| capture::capture_screen()).await {
        Ok(Ok(_)) => {
            eprintln!("[co-sheep] Test capture succeeded — vision pipeline ready");
        }
        Ok(Err(e)) => {
            let msg = e.to_string();
            eprintln!("[co-sheep] Test capture failed: {}", msg);
            app.emit(
                "sheep-commentary",
                "I can't capture your screen! Add me to System Settings > Privacy & Security > Screen Recording, then restart me.",
            )
            .ok();
            return false;
        }
        Err(e) => {
            eprintln!("[co-sheep] Test capture task panicked: {}", e);
            return false;
        }
    }

    true
}

pub async fn run_vision_pipeline(
    app: &tauri::AppHandle,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    eprintln!("[co-sheep] --- Vision pipeline tick ---");

    let provider = get_provider().map_err(|e| -> Box<dyn std::error::Error + Send + Sync> { e.into() })?;

    // Log preflight status but don't block — actual capture is the real test
    if !permissions::has_screen_capture_permission() {
        eprintln!("[co-sheep] Preflight says no permission, attempting capture anyway...");
    }

    // Capture screen (blocking operation)
    eprintln!("[co-sheep] Capturing screen...");
    let screenshot_b64 =
        tokio::task::spawn_blocking(|| capture::capture_screen()).await??;

    // Pass 1: Classification
    eprintln!("[co-sheep] Pass 1: Classifying screen...");
    let classification = classify_screen(&provider, &screenshot_b64).await?;
    eprintln!(
        "[co-sheep] Classification: interesting={}, summary={}",
        classification.interesting, classification.summary
    );

    if !classification.interesting {
        eprintln!("[co-sheep] Not interesting, skipping commentary");
        memory::append_journal(&format!(
            "Glanced at screen. {}. Nothing worth commenting on.",
            classification.summary
        ))
        .ok();
        return Ok(());
    }

    // Pass 2: Commentary (only when interesting)
    eprintln!("[co-sheep] Pass 2: Generating commentary...");
    let recent_context = memory::get_recent_context().unwrap_or_default();
    let raw_response = generate_commentary(
        &provider,
        &screenshot_b64,
        &classification.summary,
        &recent_context,
    )
    .await?;
    eprintln!("[co-sheep] Raw response: {}", raw_response);

    // Parse structured response
    let parsed = parse_commentary_response(&raw_response);
    eprintln!(
        "[co-sheep] Parsed: text={}, animation={:?}, opinion={:?}, count={:?}",
        parsed.event.text, parsed.event.animation, parsed.opinion_topic, parsed.count
    );

    // Save/update opinion if the sheep formed one
    if let (Some(ref topic), Some(ref opinion)) = (&parsed.opinion_topic, &parsed.opinion) {
        let category = parsed
            .opinion_category
            .as_deref()
            .unwrap_or("opinion");
        memory::save_opinion(topic, opinion, category).ok();
    }

    // Increment daily counter if the sheep is tracking something
    if let Some(ref key) = parsed.count {
        let n = memory::increment_today(key);
        eprintln!("[co-sheep] Counter '{}' now at {} today", key, n);
    }

    // Record that a comment was made
    memory::record_comment();

    // Emit structured commentary to frontend
    app.emit("sheep-commentary", &parsed.event)?;
    eprintln!("[co-sheep] Commentary emitted to frontend");

    // Log to daily journal
    memory::append_journal(&format!(
        "{}\n**Comment**: {} [animation: {:?}]",
        classification.summary, parsed.event.text, parsed.event.animation
    ))
    .ok();

    Ok(())
}

struct ParsedResponse {
    event: CommentaryEvent,
    opinion_topic: Option<String>,
    opinion: Option<String>,
    opinion_category: Option<String>,
    count: Option<String>,
}

/// Parse the response as JSON {text, animation, ...}, falling back to plain text.
fn parse_commentary_response(raw: &str) -> ParsedResponse {
    let trimmed = strip_think_blocks(raw)
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();

    if let Ok(parsed) = serde_json::from_str::<SonnetResponse>(trimmed) {
        let valid_animations = [
            "bounce", "spin", "backflip", "headshake", "zoom", "vibrate",
        ];
        let animation = parsed
            .animation
            .filter(|a| valid_animations.contains(&a.as_str()));
        ParsedResponse {
            event: CommentaryEvent {
                text: parsed.text,
                animation,
            },
            opinion_topic: parsed.opinion_topic,
            opinion: parsed.opinion,
            opinion_category: parsed.opinion_category,
            count: parsed.count,
        }
    } else {
        eprintln!("[co-sheep] Failed to parse as JSON, using raw text");
        ParsedResponse {
            event: CommentaryEvent {
                text: strip_think_blocks(raw).trim().to_string(),
                animation: None,
            },
            opinion_topic: None,
            opinion: None,
            opinion_category: None,
            count: None,
        }
    }
}

// ─── Anthropic API ───────────────────────────────────────────────────────────

async fn classify_screen_anthropic(
    api_key: &str,
    screenshot_b64: &str,
) -> Result<HaikuClassification, Box<dyn std::error::Error + Send + Sync>> {
    let client = reqwest::Client::new();

    let body = serde_json::json!({
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 256,
        "messages": [{
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": screenshot_b64
                    }
                },
                {
                    "type": "text",
                    "text": CLASSIFY_PROMPT
                }
            ]
        }]
    });

    let resp = client
        .post("https://api.anthropic.com/v1/messages")
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .header("content-type", "application/json")
        .json(&body)
        .send()
        .await?;

    let status = resp.status();
    if !status.is_success() {
        let body_text = resp.text().await.unwrap_or_default();
        return Err(format!("Haiku API error ({}): {}", status, body_text).into());
    }

    let resp_json: serde_json::Value = resp.json().await?;
    let text = resp_json["content"][0]["text"]
        .as_str()
        .ok_or("No text in Haiku response")?;

    parse_classification(text)
}

async fn generate_commentary_anthropic(
    api_key: &str,
    screenshot_b64: &str,
    context: &str,
    recent_journal: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let client = reqwest::Client::new();
    let system_prompt = personality::get_system_prompt(recent_journal);

    let body = serde_json::json!({
        "model": "claude-sonnet-4-5-20250929",
        "max_tokens": 256,
        "system": system_prompt,
        "messages": [{
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": screenshot_b64
                    }
                },
                {
                    "type": "text",
                    "text": format!(
                        "Context: {}\n\n{}",
                        context, COMMENTARY_PROMPT
                    )
                }
            ]
        }]
    });

    let resp = client
        .post("https://api.anthropic.com/v1/messages")
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .header("content-type", "application/json")
        .json(&body)
        .send()
        .await?;

    let status = resp.status();
    if !status.is_success() {
        let body_text = resp.text().await.unwrap_or_default();
        return Err(format!("Sonnet API error ({}): {}", status, body_text).into());
    }

    let resp_json: serde_json::Value = resp.json().await?;
    let text = resp_json["content"][0]["text"]
        .as_str()
        .ok_or("No text in Sonnet response")?
        .to_string();

    Ok(text)
}

// ─── OpenAI-compatible API (LM Studio) ──────────────────────────────────────

async fn classify_screen_openai(
    endpoint: &str,
    model: &str,
    screenshot_b64: &str,
) -> Result<HaikuClassification, Box<dyn std::error::Error + Send + Sync>> {
    let client = reqwest::Client::new();
    let url = format!("{}/v1/chat/completions", endpoint);
    let image_url = format!("data:image/jpeg;base64,{}", screenshot_b64);

    let body = serde_json::json!({
        "model": model,
        "max_tokens": 1024,
        "messages": [{
            "role": "user",
            "content": [
                {
                    "type": "image_url",
                    "image_url": { "url": image_url }
                },
                {
                    "type": "text",
                    "text": format!("{} /no_think", CLASSIFY_PROMPT)
                }
            ]
        }]
    });

    let resp = client
        .post(&url)
        .header("content-type", "application/json")
        .json(&body)
        .send()
        .await?;

    let status = resp.status();
    if !status.is_success() {
        let body_text = resp.text().await.unwrap_or_default();
        return Err(format!("LM Studio classify error ({}): {}", status, body_text).into());
    }

    let resp_json: serde_json::Value = resp.json().await?;
    let text = extract_openai_text(&resp_json)?;

    parse_classification(text)
}

async fn generate_commentary_openai(
    endpoint: &str,
    model: &str,
    screenshot_b64: &str,
    context: &str,
    recent_journal: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let client = reqwest::Client::new();
    let url = format!("{}/v1/chat/completions", endpoint);
    let system_prompt = personality::get_system_prompt(recent_journal);
    let image_url = format!("data:image/jpeg;base64,{}", screenshot_b64);

    let body = serde_json::json!({
        "model": model,
        "max_tokens": 1024,
        "messages": [
            {
                "role": "system",
                "content": system_prompt
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": { "url": image_url }
                    },
                    {
                        "type": "text",
                        "text": format!(
                            "Context: {}\n\n{} /no_think",
                            context, COMMENTARY_PROMPT
                        )
                    }
                ]
            }
        ]
    });

    let resp = client
        .post(&url)
        .header("content-type", "application/json")
        .json(&body)
        .send()
        .await?;

    let status = resp.status();
    if !status.is_success() {
        let body_text = resp.text().await.unwrap_or_default();
        return Err(format!("LM Studio commentary error ({}): {}", status, body_text).into());
    }

    let resp_json: serde_json::Value = resp.json().await?;
    let text = extract_openai_text(&resp_json)?;

    Ok(text.to_string())
}

// ─── Shared helpers ─────────────────────────────────────────────────────────

const CLASSIFY_PROMPT: &str = "Classify this screenshot. What app/website is active? Is anything notable happening (errors, code bugs, social media doom-scrolling, idle desktop, interesting content)?\n\nReply ONLY with JSON, no markdown: {\"interesting\": true/false, \"category\": \"string\", \"summary\": \"brief description\"}\n\nMark as interesting if: code with errors, social media scrolling, gaming, unusual content, embarrassing tabs. Mark as NOT interesting if: normal coding, idle desktop, standard productivity work.";

const COMMENTARY_PROMPT: &str = "Give a short snarky comment (1-2 sentences max) about what you see on this screen. Stay in character. Reference past observations if relevant. Reply with JSON: {\"text\": \"your comment\", \"animation\": \"name_or_null\"}";

/// Strip `<think>...</think>` reasoning blocks that reasoning models (Qwen3.5, etc.) emit.
fn strip_think_blocks(text: &str) -> &str {
    // Find the last </think> and take everything after it
    if let Some(pos) = text.rfind("</think>") {
        text[pos + 8..].trim()
    } else {
        text
    }
}

fn extract_openai_text(resp: &serde_json::Value) -> Result<&str, Box<dyn std::error::Error + Send + Sync>> {
    resp["choices"][0]["message"]["content"]
        .as_str()
        .ok_or_else(|| "No text in OpenAI-compatible response".into())
}

fn parse_classification(text: &str) -> Result<HaikuClassification, Box<dyn std::error::Error + Send + Sync>> {
    let cleaned = strip_think_blocks(text);
    let json_str = cleaned
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();

    let classification: HaikuClassification = serde_json::from_str(json_str)
        .map_err(|e| format!("Failed to parse classification: {} — raw: {}", e, json_str))?;

    Ok(classification)
}

/// Dispatch to the correct backend
async fn classify_screen(
    provider: &AiProvider,
    screenshot_b64: &str,
) -> Result<HaikuClassification, Box<dyn std::error::Error + Send + Sync>> {
    match provider {
        AiProvider::Anthropic { api_key } => {
            classify_screen_anthropic(api_key, screenshot_b64).await
        }
        AiProvider::LmStudio { endpoint, model } => {
            classify_screen_openai(endpoint, model, screenshot_b64).await
        }
    }
}

async fn generate_commentary(
    provider: &AiProvider,
    screenshot_b64: &str,
    context: &str,
    recent_journal: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    match provider {
        AiProvider::Anthropic { api_key } => {
            generate_commentary_anthropic(api_key, screenshot_b64, context, recent_journal).await
        }
        AiProvider::LmStudio { endpoint, model } => {
            generate_commentary_openai(endpoint, model, screenshot_b64, context, recent_journal)
                .await
        }
    }
}

use crate::capture;
use crate::memory;
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
}

#[derive(serde::Serialize, Clone)]
struct CommentaryEvent {
    text: String,
    animation: Option<String>,
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

        // Wait 2-3 minutes (randomized)
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .subsec_nanos();
        let delay = 120 + (now % 60) as u64;
        eprintln!("[co-sheep] Next vision check in {}s", delay);
        tokio::time::sleep(std::time::Duration::from_secs(delay)).await;
    }
}

/// Checks API key, screen permission, and does a test capture.
/// Emits user-facing messages via speech bubble for each failure.
/// Returns true if everything is ready.
async fn check_prerequisites(app: &tauri::AppHandle) -> bool {
    // 1. Check API key
    if std::env::var("ANTHROPIC_API_KEY").is_err() {
        eprintln!("[co-sheep] ANTHROPIC_API_KEY not set");
        app.emit(
            "sheep-commentary",
            "I can't see anything without an API key! Set ANTHROPIC_API_KEY in your environment and restart me.",
        )
        .ok();
        return false;
    }

    // 2. Check screen capture permission by actually trying a capture.
    // CGPreflightScreenCaptureAccess() is unreliable for non-bundled binaries,
    // so we skip it and go straight to a real capture test.
    if !permissions::has_screen_capture_permission() {
        eprintln!("[co-sheep] CGPreflight says no permission — requesting dialog");
        permissions::request_screen_capture_permission();
        // Don't return false yet — try an actual capture anyway
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

async fn run_vision_pipeline(
    app: &tauri::AppHandle,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    eprintln!("[co-sheep] --- Vision pipeline tick ---");

    let api_key = std::env::var("ANTHROPIC_API_KEY")
        .map_err(|_| "ANTHROPIC_API_KEY not set")?;

    // Log preflight status but don't block — actual capture is the real test
    if !permissions::has_screen_capture_permission() {
        eprintln!("[co-sheep] Preflight says no permission, attempting capture anyway...");
    }

    // Capture screen (blocking operation)
    eprintln!("[co-sheep] Capturing screen...");
    let screenshot_b64 =
        tokio::task::spawn_blocking(|| capture::capture_screen()).await??;

    // Pass 1: Haiku classification (cheap)
    eprintln!("[co-sheep] Pass 1: Sending to Haiku for classification...");
    let classification = classify_screen(&api_key, &screenshot_b64).await?;
    eprintln!(
        "[co-sheep] Haiku result: interesting={}, summary={}",
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

    // Pass 2: Sonnet commentary (only when interesting)
    eprintln!("[co-sheep] Pass 2: Sending to Sonnet for commentary...");
    let recent_context = memory::get_recent_context().unwrap_or_default();
    let raw_response = generate_commentary(
        &api_key,
        &screenshot_b64,
        &classification.summary,
        &recent_context,
    )
    .await?;
    eprintln!("[co-sheep] Sonnet raw response: {}", raw_response);

    // Parse structured response (text + optional animation)
    let event = parse_commentary_response(&raw_response);
    eprintln!(
        "[co-sheep] Parsed: text={}, animation={:?}",
        event.text, event.animation
    );

    // Emit structured commentary to frontend
    app.emit("sheep-commentary", &event)?;
    eprintln!("[co-sheep] Commentary emitted to frontend");

    // Log to journal
    memory::append_journal(&format!(
        "{}\n**Comment**: {} [animation: {:?}]",
        classification.summary, event.text, event.animation
    ))
    .ok();

    Ok(())
}

/// Parse the Sonnet response as JSON {text, animation}, falling back to plain text.
fn parse_commentary_response(raw: &str) -> CommentaryEvent {
    let trimmed = raw
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
        CommentaryEvent {
            text: parsed.text,
            animation,
        }
    } else {
        eprintln!("[co-sheep] Failed to parse as JSON, using raw text");
        CommentaryEvent {
            text: raw.trim().to_string(),
            animation: None,
        }
    }
}

async fn classify_screen(
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
                    "text": "Classify this screenshot. What app/website is active? Is anything notable happening (errors, code bugs, social media doom-scrolling, idle desktop, interesting content)?\n\nReply ONLY with JSON, no markdown: {\"interesting\": true/false, \"category\": \"string\", \"summary\": \"brief description\"}\n\nMark as interesting if: code with errors, social media scrolling, gaming, unusual content, embarrassing tabs. Mark as NOT interesting if: normal coding, idle desktop, standard productivity work."
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

    // Parse JSON (strip any markdown wrapping)
    let json_str = text
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();

    let classification: HaikuClassification = serde_json::from_str(json_str)
        .map_err(|e| format!("Failed to parse Haiku response: {} — raw: {}", e, json_str))?;

    Ok(classification)
}

async fn generate_commentary(
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
                        "Context: {}\n\nGive a short snarky comment (1-2 sentences max) about what you see on this screen. Stay in character. Reference past observations if relevant. Reply with JSON: {{\"text\": \"your comment\", \"animation\": \"name_or_null\"}}",
                        context
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

use crate::apple_ai;
use crate::capture;
use crate::memory;
use crate::permissions;
use crate::personality;
use serde::Deserialize;
use std::sync::atomic::Ordering;
use tauri::Emitter;

#[derive(Deserialize)]
struct ScreenClassification {
    interesting: bool,
    #[allow(dead_code)]
    category: String,
    summary: String,
}

#[derive(Deserialize)]
struct CommentaryResponse {
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
pub(crate) struct CommentaryEvent {
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

/// Checks the on-device model, screen permission, and does a test capture.
/// Emits user-facing messages via speech bubble for each failure.
/// Returns true if everything is ready.
async fn check_prerequisites(app: &tauri::AppHandle) -> bool {
    // 1. Check the on-device Apple Intelligence model
    match apple_ai::check_available().await {
        Ok(()) => {
            eprintln!("[co-sheep] Apple Intelligence is available");
        }
        Err(reason) => {
            eprintln!("[co-sheep] Apple Intelligence unavailable: {}", reason);
            let msg = match reason.as_str() {
                "appleIntelligenceNotEnabled" => {
                    "Apple Intelligence is turned off! Enable it in System Settings > Apple Intelligence & Siri, then I can think locally."
                }
                "modelNotReady" => {
                    "Apple Intelligence is still downloading its model... I'll keep checking. Baa-tience."
                }
                "deviceNotEligible" | "requiresMacOS26" => {
                    "This Mac can't run Apple Intelligence — I need Apple Silicon and macOS 26 to think. Sorry!"
                }
                _ => {
                    "I can't reach the on-device Apple Intelligence model. Check System Settings > Apple Intelligence & Siri."
                }
            };
            app.emit("sheep-commentary", msg).ok();
            return false;
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

    // Log preflight status but don't block — actual capture is the real test
    if !permissions::has_screen_capture_permission() {
        eprintln!("[co-sheep] Preflight says no permission, attempting capture anyway...");
    }

    // Capture screen (blocking operation)
    eprintln!("[co-sheep] Capturing screen...");
    let screenshot_b64 =
        tokio::task::spawn_blocking(|| capture::capture_screen()).await??;

    // The on-device model is text-only — OCR the screenshot once and feed
    // the recognized text to both passes instead of the image
    eprintln!("[co-sheep] OCR-ing screen for on-device model...");
    let screen_text = apple_ai::ocr_screen(&screenshot_b64).await?;
    eprintln!("[co-sheep] OCR extracted {} chars", screen_text.len());

    // Pass 1: Classification
    eprintln!("[co-sheep] Pass 1: Classifying screen...");
    let classification = classify_screen(&screen_text).await?;
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
        &screen_text,
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
    let trimmed = raw
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();

    if let Ok(parsed) = serde_json::from_str::<CommentaryResponse>(trimmed) {
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
                text: raw.trim().to_string(),
                animation: None,
            },
            opinion_topic: None,
            opinion: None,
            opinion_category: None,
            count: None,
        }
    }
}

// ─── On-device generation (Apple Intelligence via sidecar) ──────────────────

const CLASSIFY_PROMPT: &str = "Below is text extracted (OCR) from a screenshot of the user's screen. Guess what app/website is active and whether anything notable is happening (errors, code bugs, social media doom-scrolling, idle desktop, interesting content).\n\nReply ONLY with JSON, no markdown: {\"interesting\": true/false, \"category\": \"string\", \"summary\": \"brief description\"}\n\nMark as interesting if: code with errors, social media scrolling, gaming, unusual content, embarrassing tabs. Mark as NOT interesting if: normal coding, idle desktop, standard productivity work.";

const COMMENTARY_PROMPT: &str = "Give a short snarky comment (1-2 sentences max) about what you see on this screen. Stay in character. Reference past observations if relevant. Reply with JSON: {\"text\": \"your comment\", \"animation\": \"name_or_null\"}";

/// The on-device model has a small (~4k token) context window — keep the
/// OCR dump well under it so the system prompt and journal still fit.
const OCR_BUDGET: usize = 4000;

async fn classify_screen(
    screen_text: &str,
) -> Result<ScreenClassification, Box<dyn std::error::Error + Send + Sync>> {
    let screen_text = apple_ai::truncate_utf8(screen_text, OCR_BUDGET);
    let prompt = format!("Screen text:\n{}\n\n{}", screen_text, CLASSIFY_PROMPT);
    let raw = apple_ai::generate(
        "You classify screen content for a desktop pet app. Reply only with the requested JSON.",
        &prompt,
    )
    .await?;
    parse_classification(&raw)
}

async fn generate_commentary(
    screen_text: &str,
    context: &str,
    recent_journal: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let weather_ctx = crate::weather::get_weather_context().await;
    let system_prompt = personality::get_system_prompt(recent_journal, &weather_ctx);
    let screen_text = apple_ai::truncate_utf8(screen_text, OCR_BUDGET);
    let prompt = format!(
        "Context: {}\n\nText visible on the screen (OCR):\n{}\n\n{}",
        context, screen_text, COMMENTARY_PROMPT
    );
    apple_ai::generate(&system_prompt, &prompt).await
}

// ─── Chat (text-only, for conversation mode) ────────────────────────────────

#[derive(serde::Deserialize)]
pub struct ChatTurn {
    pub role: String,
    pub text: String,
}

/// A pasted wall of text would blow the ~4k-token window — same guard the
/// OCR path has via OCR_BUDGET.
const CHAT_MSG_BUDGET: usize = 2000;

pub async fn chat_with_sheep(
    user_message: &str,
    history: &[ChatTurn],
) -> Result<CommentaryEvent, Box<dyn std::error::Error + Send + Sync>> {
    let user_message = apple_ai::truncate_utf8(user_message, CHAT_MSG_BUDGET);
    let recent_context = memory::get_recent_context().unwrap_or_default();
    let weather_ctx = crate::weather::get_weather_context().await;
    let system_prompt = personality::get_chat_prompt(&recent_context, &weather_ctx);

    // Fold the (frontend-capped) session transcript into the prompt — the
    // on-device model is stateless per call
    let prompt = if history.is_empty() {
        user_message.to_string()
    } else {
        let mut p = String::from("Conversation so far:\n");
        for turn in history {
            let who = if turn.role == "sheep" { "You" } else { "Human" };
            p.push_str(&format!("{}: {}\n", who, turn.text));
        }
        p.push_str(&format!("\nHuman: {}", user_message));
        p
    };

    let raw_response = apple_ai::generate(&system_prompt, &prompt).await?;

    eprintln!("[co-sheep] Chat raw response: {}", raw_response);
    let parsed = parse_commentary_response(&raw_response);

    // Save opinion if formed
    if let (Some(ref topic), Some(ref opinion)) = (&parsed.opinion_topic, &parsed.opinion) {
        let category = parsed.opinion_category.as_deref().unwrap_or("opinion");
        memory::save_opinion(topic, opinion, category).ok();
    }
    if let Some(ref key) = parsed.count {
        memory::increment_today(key);
    }

    memory::record_interaction("chatted with");
    memory::append_journal(&format!(
        "Human said: \"{}\"\n**Reply**: {} [animation: {:?}]",
        user_message, parsed.event.text, parsed.event.animation
    )).ok();

    // The chat bubble owns display now — no sheep-commentary emit
    Ok(parsed.event)
}

// ─── Friend-to-friend AI chat ────────────────────────────────────────────────

pub async fn friend_chat(
    friend_a_name: &str,
    friend_a_personality: &str,
    friend_b_name: &str,
    friend_b_personality: &str,
    topic: Option<&str>,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let language = crate::onboarding::get_language();

    let system_prompt = format!(
        r#"You are writing a short conversation between two desktop sheep friends.
{a} is {pa}. {b} is {pb}.
Write a 2-4 line exchange. Keep it SHORT, funny, and in character. They are pixel sheep living on someone's desktop.

LANGUAGE: Write in {lang}.

Reply with ONLY a JSON array, no markdown:
[{{"speaker": "{a}", "text": "...", "animation": "bounce"}}, {{"speaker": "{b}", "text": "...", "animation": null}}]

Valid animations: "bounce", "spin", "headshake", "vibrate", "zoom", null"#,
        a = friend_a_name,
        pa = friend_a_personality,
        b = friend_b_name,
        pb = friend_b_personality,
        lang = language,
    );

    let user_msg = match topic {
        Some(t) => format!(
            "Generate a conversation between {} and {}. Context: {}",
            friend_a_name, friend_b_name, t
        ),
        None => format!(
            "Generate a conversation between {} and {}.",
            friend_a_name, friend_b_name
        ),
    };

    let raw = apple_ai::generate(&system_prompt, &user_msg).await?;

    eprintln!("[co-sheep] Friend chat raw: {}", raw);
    Ok(raw)
}

// ─── Shared helpers ─────────────────────────────────────────────────────────

fn parse_classification(text: &str) -> Result<ScreenClassification, Box<dyn std::error::Error + Send + Sync>> {
    let json_str = text
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();

    let classification: ScreenClassification = serde_json::from_str(json_str)
        .map_err(|e| format!("Failed to parse classification: {} — raw: {}", e, json_str))?;

    Ok(classification)
}

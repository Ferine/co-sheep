//! Bridge to the `apple-ai-helper` sidecar, which exposes Apple's
//! on-device foundation model (Apple Intelligence) and Vision OCR to the
//! Rust backend. FoundationModels is a Swift-only API, so each request
//! spawns the bundled helper binary and talks to it over stdin/stdout.

use std::path::PathBuf;
use std::process::Stdio;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

#[cfg(target_arch = "aarch64")]
const HOST_TRIPLE: &str = "aarch64-apple-darwin";
#[cfg(target_arch = "x86_64")]
const HOST_TRIPLE: &str = "x86_64-apple-darwin";
#[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
const HOST_TRIPLE: &str = "";

/// Locate the sidecar. In a bundled app Tauri places external binaries next
/// to the main executable (Contents/MacOS); in dev the triple-suffixed
/// build output lives in src-tauri/binaries relative to target/<profile>.
fn helper_path() -> PathBuf {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for candidate in [
                dir.join("apple-ai-helper"),
                dir.join(format!("apple-ai-helper-{}", HOST_TRIPLE)),
                dir.join("../../binaries")
                    .join(format!("apple-ai-helper-{}", HOST_TRIPLE)),
            ] {
                if candidate.exists() {
                    return candidate;
                }
            }
        }
    }
    // Last resort: hope it's on PATH
    PathBuf::from("apple-ai-helper")
}

async fn run_helper(args: &[&str], stdin_data: &[u8]) -> Result<String, BoxError> {
    let path = helper_path();
    let mut child = Command::new(&path)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to launch {} : {}", path.display(), e))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(stdin_data).await?;
        // Dropping stdin closes the pipe so the helper sees EOF
    }

    let output = child.wait_with_output().await?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("apple-ai-helper {} failed: {}", args.join(" "), stderr.trim()).into());
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Check whether the on-device model can be used. Err carries the reason
/// string the helper reported (e.g. "appleIntelligenceNotEnabled").
pub async fn check_available() -> Result<(), String> {
    let raw = run_helper(&["check"], b"").await.map_err(|e| e.to_string())?;
    let parsed: serde_json::Value =
        serde_json::from_str(&raw).map_err(|e| format!("bad check output: {} — {}", e, raw))?;
    if parsed["available"].as_bool() == Some(true) {
        Ok(())
    } else {
        Err(parsed["reason"].as_str().unwrap_or("unknown").to_string())
    }
}

/// OCR a base64-encoded JPEG screenshot into plain screen text.
pub async fn ocr_screen(screenshot_b64: &str) -> Result<String, BoxError> {
    run_helper(&["ocr"], screenshot_b64.as_bytes()).await
}

/// Run a text generation on the on-device model.
pub async fn generate(system: &str, prompt: &str) -> Result<String, BoxError> {
    let body = serde_json::json!({ "system": system, "prompt": prompt });
    run_helper(&["generate"], body.to_string().as_bytes()).await
}

/// Truncate to at most `max_bytes`, respecting char boundaries — the
/// on-device model has a small (~4k token) context window.
pub fn truncate_utf8(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let mut end = max_bytes;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

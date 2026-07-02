use base64::Engine;
use image::codecs::jpeg::JpegEncoder;
use image::DynamicImage;
use xcap::Monitor;

pub fn capture_screen() -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    eprintln!("[co-sheep] Enumerating monitors...");
    let monitors = Monitor::all()?;
    eprintln!("[co-sheep] Found {} monitor(s)", monitors.len());

    let monitor = monitors.into_iter().next().ok_or("No monitor found")?;
    eprintln!("[co-sheep] Capturing screen...");
    let screenshot = monitor.capture_image()?;

    let (orig_w, orig_h) = (screenshot.width(), screenshot.height());
    eprintln!(
        "[co-sheep] Captured {}x{} image, resizing...",
        orig_w, orig_h
    );

    let dynamic = DynamicImage::ImageRgba8(screenshot);

    // Resize so longest side is at most 1568px (Claude vision optimal) —
    // never upscale smaller screens, that only blurs and bloats the payload
    let (w, h) = (dynamic.width(), dynamic.height());
    let scale = (1568.0 / w.max(h) as f64).min(1.0);
    let new_w = (w as f64 * scale) as u32;
    let new_h = (h as f64 * scale) as u32;
    let resized = dynamic.resize_exact(new_w, new_h, image::imageops::FilterType::Lanczos3);

    // Encode to JPEG quality 70
    let mut buf = Vec::new();
    let encoder = JpegEncoder::new_with_quality(&mut buf, 70);
    resized.write_with_encoder(encoder)?;

    eprintln!(
        "[co-sheep] Encoded to JPEG: {}x{}, {} bytes",
        new_w,
        new_h,
        buf.len()
    );

    // Base64 encode
    let b64 = base64::engine::general_purpose::STANDARD.encode(&buf);
    eprintln!("[co-sheep] Base64 encoded: {} chars", b64.len());
    Ok(b64)
}

/// Save a debug screenshot to ~/Desktop so the user can verify what the sheep sees.
pub fn save_debug_screenshot() -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let monitors = Monitor::all()?;
    let monitor = monitors.into_iter().next().ok_or("No monitor found")?;
    let screenshot = monitor.capture_image()?;

    let path = dirs::home_dir()
        .expect("No home dir")
        .join("Desktop")
        .join("co-sheep-debug-capture.png");

    let dynamic = DynamicImage::ImageRgba8(screenshot);
    dynamic.save(&path)?;

    let path_str = path.to_string_lossy().to_string();
    eprintln!("[co-sheep] Debug screenshot saved to: {}", path_str);
    Ok(path_str)
}

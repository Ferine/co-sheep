use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use tauri::Manager;

#[repr(C)]
#[derive(Clone, Copy)]
struct CGPoint {
    x: f64,
    y: f64,
}

#[cfg(target_os = "macos")]
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventCreate(source: *const std::ffi::c_void) -> *mut std::ffi::c_void;
    fn CGEventGetLocation(event: *const std::ffi::c_void) -> CGPoint;
}

#[cfg(target_os = "macos")]
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(cf: *const std::ffi::c_void);
}

fn get_cursor_position() -> (f64, f64) {
    #[cfg(target_os = "macos")]
    {
        unsafe {
            let event = CGEventCreate(std::ptr::null());
            if event.is_null() {
                return (0.0, 0.0);
            }
            let pos = CGEventGetLocation(event);
            CFRelease(event);
            (pos.x, pos.y)
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        (0.0, 0.0)
    }
}

pub struct SheepHitState {
    /// All character bounding boxes: Vec<(x, y, width, height)>
    pub bounds: Mutex<Vec<(f64, f64, f64, f64)>>,
    /// True while the user is actively dragging any sheep
    pub is_dragging: AtomicBool,
    /// True while the chat input bubble is open
    pub is_input_active: AtomicBool,
}

impl SheepHitState {
    pub fn new() -> Self {
        Self {
            bounds: Mutex::new(Vec::new()),
            is_dragging: AtomicBool::new(false),
            is_input_active: AtomicBool::new(false),
        }
    }
}

/// Polls global cursor position ~20 times/sec.
/// Toggles window click-through based on whether the cursor overlaps any character.
pub async fn cursor_tracking_loop(app: tauri::AppHandle) {
    log!("cursor", "Cursor tracking loop started, waiting for sheep to spawn...");
    // Wait for the sheep to spawn
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    log!("cursor", "Cursor tracking active");

    let mut was_over = false;

    loop {
        let state = app.state::<SheepHitState>();

        // Never toggle during an active drag or chat input — the window must stay interactive
        if !state.is_dragging.load(Ordering::Relaxed)
            && !state.is_input_active.load(Ordering::Relaxed)
        {
            let (cx, cy) = get_cursor_position();
            let bounds_list = state.bounds.lock().unwrap();

            let over_any = bounds_list.iter().any(|(bx, by, bw, bh)| {
                *bw > 0.0
                    && *bh > 0.0
                    && cx >= *bx
                    && cx <= *bx + *bw
                    && cy >= *by
                    && cy <= *by + *bh
            });

            // Only log on state change to avoid spamming
            if over_any != was_over {
                debug!(
                    "cursor", "Cursor {} character (cursor: {:.0},{:.0})",
                    if over_any { "OVER" } else { "LEFT" },
                    cx, cy,
                );
                was_over = over_any;
            }

            if let Some(window) = app.get_webview_window("main") {
                window.set_ignore_cursor_events(!over_any).ok();
            }
        }

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}

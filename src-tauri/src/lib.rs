mod capture;
mod cursor;
mod memory;
mod onboarding;
mod permissions;
mod personality;
mod screen_info;
mod vision;

use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{Emitter, Manager};

pub static COMMENTARY_PAUSED: AtomicBool = AtomicBool::new(false);

#[tauri::command]
async fn check_onboarding() -> Result<bool, String> {
    let needs = onboarding::needs_onboarding().map_err(|e| e.to_string())?;
    eprintln!("[co-sheep] Onboarding needed: {}", needs);
    Ok(needs)
}

#[tauri::command]
async fn save_sheep_name(app: tauri::AppHandle, name: String) -> Result<(), String> {
    eprintln!("[co-sheep] Saving sheep name: {}", name);
    onboarding::save_config(&name).map_err(|e| e.to_string())?;
    app.emit("naming-complete", &name)
        .map_err(|e| e.to_string())?;
    if let Some(win) = app.get_webview_window("naming") {
        win.close().ok();
    }
    eprintln!("[co-sheep] Naming complete, config saved");
    Ok(())
}

#[tauri::command]
async fn open_naming_window(app: tauri::AppHandle) -> Result<(), String> {
    eprintln!("[co-sheep] Opening naming window");
    if app.get_webview_window("naming").is_some() {
        eprintln!("[co-sheep] Naming window already exists, skipping");
        return Ok(());
    }
    tauri::WebviewWindowBuilder::new(
        &app,
        "naming",
        tauri::WebviewUrl::App("naming.html".into()),
    )
    .title("Name your sheep!")
    .inner_size(380.0, 180.0)
    .center()
    .decorations(true)
    .always_on_top(true)
    .resizable(false)
    .build()
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
async fn get_screen_info() -> Result<screen_info::ScreenInfo, String> {
    screen_info::get_primary_screen_info().map_err(|e| e.to_string())
}

#[tauri::command]
async fn check_api_key() -> bool {
    std::env::var("ANTHROPIC_API_KEY").is_ok()
}

#[tauri::command]
async fn check_screen_permission() -> bool {
    permissions::has_screen_capture_permission()
}

/// Called by the frontend every ~50ms with the sheep's bounding box.
#[tauri::command]
fn update_sheep_bounds(
    state: tauri::State<cursor::SheepHitState>,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
) {
    *state.bounds.lock().unwrap() = (x, y, w, h);
}

/// Called by the frontend on mousedown/mouseup to lock click-through off during drag.
#[tauri::command]
fn set_dragging(
    app: tauri::AppHandle,
    state: tauri::State<cursor::SheepHitState>,
    dragging: bool,
) {
    eprintln!("[co-sheep] Drag state: {}", if dragging { "START" } else { "END" });
    state.is_dragging.store(dragging, Ordering::Relaxed);
    // When drag ends, immediately restore click-through
    if !dragging {
        if let Some(window) = app.get_webview_window("main") {
            window.set_ignore_cursor_events(true).ok();
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(cursor::SheepHitState::new())
        .invoke_handler(tauri::generate_handler![
            check_onboarding,
            save_sheep_name,
            open_naming_window,
            get_screen_info,
            check_api_key,
            check_screen_permission,
            update_sheep_bounds,
            set_dragging,
        ])
        .setup(|app| {
            eprintln!("[co-sheep] === co-sheep starting ===");

            // Main overlay — start click-through
            let window = app.get_webview_window("main").unwrap();
            if let Err(e) = window.set_ignore_cursor_events(true) {
                eprintln!("[co-sheep] Failed to set click-through: {}", e);
            } else {
                eprintln!("[co-sheep] Click-through enabled on main window");
            }

            // Request screen capture permission early (just triggers the dialog)
            let preflight = permissions::has_screen_capture_permission();
            eprintln!("[co-sheep] Screen capture preflight: {}", if preflight { "granted" } else { "not granted (will try actual capture later)" });
            if !preflight {
                permissions::request_screen_capture_permission();
            }

            // Resize window to fill screen
            if let Ok(ref info) = screen_info::get_primary_screen_info() {
                eprintln!("[co-sheep] Screen info: {}x{}", info.width, info.height);
                window
                    .set_size(tauri::LogicalSize::new(
                        info.width as f64,
                        info.height as f64,
                    ))
                    .ok();
                window
                    .set_position(tauri::LogicalPosition::new(0.0, 0.0))
                    .ok();
            }

            // System tray
            let quit =
                tauri::menu::MenuItem::with_id(app, "quit", "Quit co-sheep", true, None::<&str>)?;
            let pause = tauri::menu::MenuItem::with_id(
                app,
                "pause",
                "Pause Commentary",
                true,
                None::<&str>,
            )?;
            let menu = tauri::menu::Menu::with_items(app, &[&pause, &quit])?;

            let _tray = tauri::tray::TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                .on_menu_event(move |app, event| match event.id().as_ref() {
                    "quit" => app.exit(0),
                    "pause" => {
                        let paused = COMMENTARY_PAUSED.load(Ordering::Relaxed);
                        COMMENTARY_PAUSED.store(!paused, Ordering::Relaxed);
                    }
                    _ => {}
                })
                .build(app)?;
            eprintln!("[co-sheep] System tray created");

            // Spawn cursor tracking loop (for drag-and-drop hit detection)
            eprintln!("[co-sheep] Spawning cursor tracking loop");
            let cursor_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                cursor::cursor_tracking_loop(cursor_handle).await;
            });

            // Spawn vision loop
            eprintln!("[co-sheep] Spawning vision loop");
            let vision_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                vision::vision_loop(vision_handle).await;
            });

            eprintln!("[co-sheep] Setup complete");
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

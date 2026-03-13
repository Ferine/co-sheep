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
    onboarding::get_api_key().is_some()
}

#[tauri::command]
fn record_interaction(interaction: String) {
    memory::record_interaction(&interaction);
}

#[tauri::command]
async fn debug_capture(app: tauri::AppHandle) -> Result<String, String> {
    eprintln!("[co-sheep] Debug capture requested");
    match tokio::task::spawn_blocking(|| capture::save_debug_screenshot()).await {
        Ok(Ok(path)) => {
            app.emit("sheep-commentary", "Saved what I see to your Desktop! Check co-sheep-debug-capture.png")
                .ok();
            Ok(path)
        }
        Ok(Err(e)) => {
            let msg = format!("Capture failed: {}", e);
            app.emit("sheep-commentary", &msg).ok();
            Err(msg)
        }
        Err(e) => Err(format!("Task panicked: {}", e)),
    }
}

#[tauri::command]
async fn get_memory() -> Result<serde_json::Value, String> {
    Ok(memory::get_brain_for_display())
}

#[tauri::command]
async fn open_memory_window(app: tauri::AppHandle) -> Result<(), String> {
    eprintln!("[co-sheep] Opening memory window");
    if let Some(win) = app.get_webview_window("memory") {
        win.set_focus().ok();
        return Ok(());
    }
    tauri::WebviewWindowBuilder::new(
        &app,
        "memory",
        tauri::WebviewUrl::App("memory.html".into()),
    )
    .title("Sheep's Brain")
    .inner_size(550.0, 600.0)
    .center()
    .decorations(true)
    .always_on_top(true)
    .resizable(true)
    .build()
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
async fn get_settings() -> Result<onboarding::SheepConfig, String> {
    Ok(onboarding::load_config().unwrap_or_default())
}

#[tauri::command]
async fn save_settings(
    name: String,
    personality: String,
    interval_secs: u64,
    api_key: String,
    language: String,
    ai_provider: String,
    lmstudio_endpoint: String,
    lmstudio_model: String,
) -> Result<(), String> {
    eprintln!(
        "[co-sheep] Saving settings: name={}, personality={}, interval={}s, language={}, provider={}, api_key={}",
        name, personality, interval_secs, language, ai_provider,
        if api_key.is_empty() { "(empty)" } else { "(set)" }
    );
    let config = onboarding::SheepConfig {
        name,
        personality,
        interval_secs,
        api_key,
        language,
        ai_provider,
        lmstudio_endpoint,
        lmstudio_model,
    };
    onboarding::write_config(&config).map_err(|e| e.to_string())
}

#[tauri::command]
async fn open_settings_window(app: tauri::AppHandle) -> Result<(), String> {
    eprintln!("[co-sheep] Opening settings window");
    if let Some(win) = app.get_webview_window("settings") {
        win.set_focus().ok();
        return Ok(());
    }
    tauri::WebviewWindowBuilder::new(
        &app,
        "settings",
        tauri::WebviewUrl::App("settings.html".into()),
    )
    .title("co-sheep Settings")
    .inner_size(420.0, 520.0)
    .center()
    .decorations(true)
    .always_on_top(true)
    .resizable(false)
    .build()
    .map_err(|e| e.to_string())?;
    Ok(())
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
            get_settings,
            save_settings,
            open_settings_window,
            get_memory,
            open_memory_window,
            record_interaction,
            debug_capture,
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

            // System tray + macOS app menu
            let settings_item = tauri::menu::MenuItem::with_id(
                app,
                "settings",
                "Settings...",
                true,
                None::<&str>,
            )?;
            let memory_item = tauri::menu::MenuItem::with_id(
                app,
                "memory",
                "Sheep's Brain...",
                true,
                None::<&str>,
            )?;
            let comment_now = tauri::menu::MenuItem::with_id(
                app,
                "comment_now",
                "Comment Now",
                true,
                None::<&str>,
            )?;
            let pause = tauri::menu::MenuItem::with_id(
                app,
                "pause",
                "Pause Commentary",
                true,
                None::<&str>,
            )?;
            let quit =
                tauri::menu::MenuItem::with_id(app, "quit", "Quit co-sheep", true, None::<&str>)?;

            // Tray icon menu
            let tray_menu = tauri::menu::Menu::with_items(app, &[&settings_item, &memory_item, &comment_now, &pause, &quit])?;

            let _tray = tauri::tray::TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&tray_menu)
                .menu_on_left_click(true)
                .on_menu_event(move |app, event| {
                    eprintln!("[co-sheep] Tray menu event: {}", event.id().as_ref());
                    match event.id().as_ref() {
                        "quit" => app.exit(0),
                        "pause" => {
                            let paused = COMMENTARY_PAUSED.load(Ordering::Relaxed);
                            COMMENTARY_PAUSED.store(!paused, Ordering::Relaxed);
                        }
                        "comment_now" => {
                            let handle = app.clone();
                            tauri::async_runtime::spawn(async move {
                                eprintln!("[co-sheep] Manual commentary triggered");
                                if let Err(e) = vision::run_vision_pipeline(&handle).await {
                                    eprintln!("[co-sheep] Manual commentary failed: {}", e);
                                }
                            });
                        }
                        "settings" => {
                            let handle = app.clone();
                            tauri::async_runtime::spawn(async move {
                                if let Err(e) = open_settings_window(handle).await {
                                    eprintln!("[co-sheep] Failed to open settings: {}", e);
                                }
                            });
                        }
                        "memory" => {
                            let handle = app.clone();
                            tauri::async_runtime::spawn(async move {
                                if let Err(e) = open_memory_window(handle).await {
                                    eprintln!("[co-sheep] Failed to open memory: {}", e);
                                }
                            });
                        }
                        _ => {}
                    }
                })
                .build(app)?;

            // macOS top menu bar — co-sheep submenu with same items
            let app_menu_settings = tauri::menu::MenuItem::with_id(
                app,
                "menu_settings",
                "Settings...",
                true,
                None::<&str>,
            )?;
            let app_menu_memory = tauri::menu::MenuItem::with_id(
                app,
                "menu_memory",
                "Sheep's Brain...",
                true,
                None::<&str>,
            )?;
            let app_menu_comment_now = tauri::menu::MenuItem::with_id(
                app,
                "menu_comment_now",
                "Comment Now",
                true,
                None::<&str>,
            )?;
            let app_menu_pause = tauri::menu::MenuItem::with_id(
                app,
                "menu_pause",
                "Pause Commentary",
                true,
                None::<&str>,
            )?;
            let app_menu_debug = tauri::menu::MenuItem::with_id(
                app,
                "menu_debug_capture",
                "Debug Capture...",
                true,
                None::<&str>,
            )?;
            let app_menu_quit = tauri::menu::MenuItem::with_id(
                app,
                "menu_quit",
                "Quit co-sheep",
                true,
                None::<&str>,
            )?;
            let app_submenu = tauri::menu::Submenu::with_items(
                app,
                "co-sheep",
                true,
                &[&app_menu_settings, &app_menu_memory, &app_menu_comment_now, &app_menu_pause, &app_menu_debug, &app_menu_quit],
            )?;
            let app_menu = tauri::menu::Menu::with_items(app, &[&app_submenu])?;
            app.set_menu(app_menu)?;
            app.on_menu_event(move |app, event| {
                eprintln!("[co-sheep] App menu event: {}", event.id().as_ref());
                match event.id().as_ref() {
                    "menu_quit" => app.exit(0),
                    "menu_pause" => {
                        let paused = COMMENTARY_PAUSED.load(Ordering::Relaxed);
                        COMMENTARY_PAUSED.store(!paused, Ordering::Relaxed);
                    }
                    "menu_comment_now" => {
                        let handle = app.clone();
                        tauri::async_runtime::spawn(async move {
                            eprintln!("[co-sheep] Manual commentary triggered (menu)");
                            if let Err(e) = vision::run_vision_pipeline(&handle).await {
                                eprintln!("[co-sheep] Manual commentary failed: {}", e);
                            }
                        });
                    }
                    "menu_settings" => {
                        let handle = app.clone();
                        tauri::async_runtime::spawn(async move {
                            if let Err(e) = open_settings_window(handle).await {
                                eprintln!("[co-sheep] Failed to open settings: {}", e);
                            }
                        });
                    }
                    "menu_memory" => {
                        let handle = app.clone();
                        tauri::async_runtime::spawn(async move {
                            if let Err(e) = open_memory_window(handle).await {
                                eprintln!("[co-sheep] Failed to open memory: {}", e);
                            }
                        });
                    }
                    "menu_debug_capture" => {
                        let handle = app.clone();
                        tauri::async_runtime::spawn(async move {
                            if let Err(e) = debug_capture(handle).await {
                                eprintln!("[co-sheep] Debug capture failed: {}", e);
                            }
                        });
                    }
                    _ => {}
                }
            });
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

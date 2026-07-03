mod app_watch;
mod apple_ai;
mod capture;
mod cursor;
mod easter_memory;
mod friend_memory;
mod living_state;
mod memory;
mod onboarding;
mod permissions;
mod personality;
mod screen_info;
mod vision;
mod weather;
mod windows;

use base64::Engine;
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

/// Whether the on-device Apple Intelligence model is ready to use.
#[tauri::command]
async fn check_ai_ready() -> bool {
    apple_ai::check_available().await.is_ok()
}

#[tauri::command]
fn record_interaction(interaction: String) {
    memory::record_interaction(&interaction);
}

/// Bump the daily usage tally for an app category (feeds AI "Today's tallies").
#[tauri::command]
fn record_app_usage(category: String) -> u32 {
    memory::increment_today(&format!("app:{}", category))
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
    app: tauri::AppHandle,
    name: String,
    personality: String,
    interval_secs: u64,
    language: String,
    break_reminders: bool,
    easter_mode: String,
    summer_mode: String,
    weather_location: String,
) -> Result<(), String> {
    eprintln!(
        "[co-sheep] Saving settings: name={}, personality={}, interval={}s, language={}",
        name, personality, interval_secs, language
    );
    // Preserve existing friends and accessories when saving settings
    let config = onboarding::update_config(|c| {
        c.name = name;
        c.personality = personality;
        c.interval_secs = interval_secs;
        c.language = language;
        c.break_reminders = break_reminders;
        c.easter_mode = easter_mode;
        c.summer_mode = summer_mode;
        c.weather_location = weather_location;
    })
    .map_err(|e| e.to_string())?;
    app.emit(
        "settings-changed",
        serde_json::json!({
            "name": config.name,
            "personality": config.personality,
            "interval_secs": config.interval_secs,
            "language": config.language,
            "break_reminders": config.break_reminders,
            "easter_mode": config.easter_mode,
            "summer_mode": config.summer_mode,
            "weather_location": config.weather_location,
        }),
    )
        .map_err(|e| e.to_string())?;
    Ok(())
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
    .inner_size(420.0, 600.0)
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

#[derive(serde::Deserialize)]
struct BoundsRect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

/// Called by the frontend every ~50ms with all character bounding boxes.
#[tauri::command]
fn update_sheep_bounds_multi(
    state: tauri::State<cursor::SheepHitState>,
    bounds: Vec<BoundsRect>,
) {
    let mut stored = state.bounds.lock().unwrap();
    *stored = bounds.iter().map(|b| (b.x, b.y, b.w, b.h)).collect();
}

#[tauri::command]
async fn get_friends() -> Result<Vec<onboarding::FriendDef>, String> {
    let friends = onboarding::load_config()
        .map(|c| c.friends)
        .unwrap_or_default();
    // Ensure friend brains are initialized (including Good Colleague)
    friend_memory::ensure_brain("good_colleague", "Good Colleague");
    for f in &friends {
        friend_memory::ensure_brain(&f.id, &f.name);
    }
    friend_memory::decay_affinities(); // daily decay check
    Ok(friends)
}

#[tauri::command]
async fn add_friend(app: tauri::AppHandle, name: String, color: String, personality: String) -> Result<(), String> {
    let base_id = format!(
        "friend_{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    );
    let scale = 0.85 + (rand_f64() * 0.3); // 0.85–1.15
    let mut id = base_id.clone();
    let mut at_capacity = false;
    onboarding::update_config(|config| {
        // The friends UI disables its button at 4, but the flock also hard
        // caps at 5 sheep (4 + Good Colleague) — enforce here so config
        // can't silently hold friends that never spawn
        if config.friends.len() >= 4 {
            at_capacity = true;
            return;
        }
        // Two adds in the same millisecond would otherwise share an id
        // (and thus a brain file)
        let mut suffix = 1;
        while config.friends.iter().any(|f| f.id == id) {
            id = format!("{}_{}", base_id, suffix);
            suffix += 1;
        }
        config.friends.push(onboarding::FriendDef {
            id: id.clone(),
            name: name.clone(),
            color: color.clone(),
            personality: personality.clone(),
            accessories: Vec::new(),
            scale,
        });
    })
    .map_err(|e| e.to_string())?;
    if at_capacity {
        return Err("Max 4 friends — the desktop only fits so much wool.".to_string());
    }
    friend_memory::ensure_brain(&id, &name);
    app.emit(
        "add-friend",
        serde_json::json!({ "id": id, "name": name, "color": color, "personality": personality, "scale": scale }),
    )
    .map_err(|e| e.to_string())?;
    eprintln!("[co-sheep] Added friend: {} ({}, {})", name, color, personality);
    Ok(())
}

fn rand_f64() -> f64 {
    // RandomState is seeded from OS entropy, so hashing the clock gives a
    // usable spread even on platforms whose clock has coarse granularity
    // (raw low nanosecond digits can be constantly zero).
    use std::hash::{BuildHasher, Hasher};
    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    hasher.write_u128(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos(),
    );
    (hasher.finish() % 1_000_000) as f64 / 1_000_000.0
}

#[tauri::command]
async fn save_friend_accessories(app: tauri::AppHandle, id: String, accessories: Vec<String>) -> Result<(), String> {
    onboarding::update_config(|config| {
        if let Some(friend) = config.friends.iter_mut().find(|f| f.id == id) {
            friend.accessories = accessories.clone();
        }
    })
    .map_err(|e| e.to_string())?;
    app.emit("friend-accessories-changed", serde_json::json!({ "id": id, "accessories": accessories }))
        .map_err(|e| e.to_string())?;
    eprintln!("[co-sheep] Friend {} accessories saved", id);
    Ok(())
}

#[tauri::command]
async fn remove_friend(app: tauri::AppHandle, id: String) -> Result<(), String> {
    onboarding::update_config(|config| config.friends.retain(|f| f.id != id))
        .map_err(|e| e.to_string())?;
    // Delete the brain and scrub the id from every remaining brain — or the
    // Relationships viewer shows ghosts and affinity maps rot forever
    friend_memory::remove_brain(&id);
    app.emit("remove-friend", &id)
        .map_err(|e| e.to_string())?;
    eprintln!("[co-sheep] Removed friend: {}", id);
    Ok(())
}

#[tauri::command]
async fn open_friends_window(app: tauri::AppHandle) -> Result<(), String> {
    eprintln!("[co-sheep] Opening friends window");
    if let Some(win) = app.get_webview_window("friends") {
        win.set_focus().ok();
        return Ok(());
    }
    tauri::WebviewWindowBuilder::new(
        &app,
        "friends",
        tauri::WebviewUrl::App("friends.html".into()),
    )
    .title("Manage Friends")
    .inner_size(400.0, 550.0)
    .center()
    .decorations(true)
    .always_on_top(true)
    .resizable(false)
    .build()
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn set_cursor_events(
    app: tauri::AppHandle,
    state: tauri::State<cursor::SheepHitState>,
    ignore: bool,
) {
    eprintln!("[co-sheep] set_cursor_events: ignore={}", ignore);
    state.is_input_active.store(!ignore, Ordering::Relaxed);
    if let Some(window) = app.get_webview_window("main") {
        window.set_ignore_cursor_events(ignore).ok();
    }
}

#[tauri::command]
async fn chat_with_sheep(
    message: String,
    history: Vec<vision::ChatTurn>,
) -> Result<vision::CommentaryEvent, String> {
    eprintln!("[co-sheep] Chat request: {}", message);
    vision::chat_with_sheep(&message, &history).await.map_err(|e| {
        eprintln!("[co-sheep] Chat failed: {}", e);
        // One entry per settings.html language option
        match onboarding::get_language().to_lowercase().as_str() {
            "nynorsk" => "Bæææ... hjernen min verkar ikkje akkurat no. Prøv igjen?",
            "bokmål" => "Bæææ... hjernen min virker ikke akkurat nå. Prøv igjen?",
            "swedish" => "Bäää... min hjärna funkar inte just nu. Försök igen?",
            "danish" => "Bæææ... min hjerne virker ikke lige nu. Prøv igen?",
            "german" => "Määä... mein Gehirn funktioniert gerade nicht. Versuch's nochmal?",
            "french" => "Bêêê... mon cerveau ne marche pas là. Réessaie ?",
            "spanish" => "Beee... mi cerebro no funciona ahora. ¿Intentas de nuevo?",
            "japanese" => "メェェ…今、頭が働かないの。もう一度試して？",
            "korean" => "메에에... 지금 머리가 안 돌아가요. 다시 해볼래요?",
            _ => "Baaaa... my brain isn't working right now. Try again?",
        }
        .to_string()
    })
}

#[tauri::command]
async fn save_moment(image_data: String) -> Result<String, String> {
    let b64 = image_data
        .strip_prefix("data:image/png;base64,")
        .unwrap_or(&image_data);
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64)
        .map_err(|e| format!("Base64 decode error: {}", e))?;

    let home = dirs::home_dir().ok_or("No home directory")?;
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let path = home
        .join("Desktop")
        .join(format!("co-sheep-moment-{}.png", ts));
    std::fs::write(&path, bytes).map_err(|e| format!("Write error: {}", e))?;
    let p = path.to_string_lossy().to_string();
    eprintln!("[co-sheep] Moment saved to {}", p);
    Ok(p)
}

#[tauri::command]
async fn get_weather_snapshot() -> Option<weather::WeatherSnapshot> {
    weather::get_weather_snapshot().await
}

#[tauri::command]
async fn get_window_positions() -> Vec<windows::WindowRect> {
    let pid = std::process::id();
    windows::get_visible_window_rects(pid)
}

#[tauri::command]
async fn get_accessories() -> Vec<String> {
    onboarding::load_config()
        .map(|c| c.accessories)
        .unwrap_or_default()
}

#[tauri::command]
async fn save_accessories(app: tauri::AppHandle, accessories: Vec<String>) -> Result<(), String> {
    onboarding::update_config(|config| config.accessories = accessories)
        .map_err(|e| e.to_string())?;
    app.emit("accessories-changed", ())
        .map_err(|e| e.to_string())?;
    eprintln!("[co-sheep] Accessories saved");
    Ok(())
}

#[tauri::command]
async fn open_wardrobe_window(app: tauri::AppHandle) -> Result<(), String> {
    eprintln!("[co-sheep] Opening wardrobe window");
    if let Some(win) = app.get_webview_window("wardrobe") {
        win.set_focus().ok();
        return Ok(());
    }
    tauri::WebviewWindowBuilder::new(
        &app,
        "wardrobe",
        tauri::WebviewUrl::App("wardrobe.html".into()),
    )
    .title("Wardrobe")
    .inner_size(400.0, 580.0)
    .center()
    .decorations(true)
    .always_on_top(true)
    .resizable(false)
    .build()
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
async fn open_friend_memory_window(app: tauri::AppHandle) -> Result<(), String> {
    if let Some(win) = app.get_webview_window("friend_memory") {
        win.set_focus().ok();
        return Ok(());
    }
    tauri::WebviewWindowBuilder::new(
        &app,
        "friend_memory",
        tauri::WebviewUrl::App("friend-memory.html".into()),
    )
    .title("Friend Relationships")
    .inner_size(420.0, 500.0)
    .center()
    .decorations(true)
    .always_on_top(true)
    .resizable(true)
    .build()
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn record_friend_conversation(id_a: String, id_b: String, topic: String) {
    friend_memory::record_conversation(&id_a, &id_b, &topic);
}

#[tauri::command]
fn record_group_activity(participants: Vec<String>, activity_type: String) {
    friend_memory::record_group_activity(&participants, &activity_type);
}

#[tauri::command]
fn get_living_state(name: String) -> serde_json::Value {
    living_state::load_state(&name)
}

#[tauri::command]
fn save_living_state(name: String, value: serde_json::Value) {
    living_state::save_state(&name, &value);
}

/// Record a spectacle's aftermath: friend memories + affinity boost + diary entry.
#[tauri::command]
fn record_spectacle(kind: String, participants: Vec<String>) {
    friend_memory::record_group_activity(&participants, &kind);
    memory::append_journal(&format!(
        "*A {} happened on the desktop! The flock is still talking about it.*",
        kind
    ))
    .ok();
}

#[tauri::command]
fn record_friend_pet(id: String) {
    friend_memory::record_pet(&id);
}

#[tauri::command]
async fn get_friend_memory(id: String) -> Result<serde_json::Value, String> {
    Ok(friend_memory::get_friend_brain_json(&id))
}

#[tauri::command]
async fn get_all_relationships() -> Result<serde_json::Value, String> {
    Ok(friend_memory::get_all_relationships())
}

#[tauri::command]
async fn get_friend_moods() -> Result<std::collections::HashMap<String, String>, String> {
    Ok(friend_memory::get_all_moods())
}

#[tauri::command]
async fn get_easter_stats() -> Result<easter_memory::EasterStats, String> {
    Ok(easter_memory::get_stats())
}

#[tauri::command]
async fn record_easter_hunt(
    result: easter_memory::EasterHuntResult,
) -> Result<easter_memory::EasterStats, String> {
    Ok(easter_memory::record_hunt(result))
}

#[tauri::command]
async fn friend_ai_chat(
    friend_a_name: String,
    friend_a_personality: String,
    friend_b_name: String,
    friend_b_personality: String,
    topic: Option<String>,
) -> Result<String, String> {
    eprintln!("[co-sheep] Friend AI chat: {} ({}) <-> {} ({})", friend_a_name, friend_a_personality, friend_b_name, friend_b_personality);
    vision::friend_chat(&friend_a_name, &friend_a_personality, &friend_b_name, &friend_b_personality, topic.as_deref())
        .await
        .map_err(|e| e.to_string())
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
            check_ai_ready,
            check_screen_permission,
            update_sheep_bounds_multi,
            set_dragging,
            set_cursor_events,
            chat_with_sheep,
            get_settings,
            save_settings,
            open_settings_window,
            get_memory,
            open_memory_window,
            record_interaction,
            record_app_usage,
            debug_capture,
            get_friends,
            add_friend,
            remove_friend,
            open_friends_window,
            save_moment,
            get_weather_snapshot,
            get_window_positions,
            get_accessories,
            save_accessories,
            open_wardrobe_window,
            save_friend_accessories,
            friend_ai_chat,
            record_friend_conversation,
            record_group_activity,
            record_friend_pet,
            get_friend_memory,
            get_all_relationships,
            get_friend_moods,
            get_easter_stats,
            record_easter_hunt,
            open_friend_memory_window,
            get_living_state,
            save_living_state,
            record_spectacle,
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
            let friends_item = tauri::menu::MenuItem::with_id(
                app,
                "friends",
                "Manage Friends...",
                true,
                None::<&str>,
            )?;
            let chat_item = tauri::menu::MenuItem::with_id(
                app,
                "chat",
                "Chat with Sheep...",
                true,
                None::<&str>,
            )?;
            let capture_moment_item = tauri::menu::MenuItem::with_id(
                app,
                "capture_moment",
                "Capture Moment",
                true,
                None::<&str>,
            )?;
            let wardrobe_item = tauri::menu::MenuItem::with_id(
                app,
                "wardrobe",
                "Wardrobe...",
                true,
                None::<&str>,
            )?;
            let quit =
                tauri::menu::MenuItem::with_id(app, "quit", "Quit co-sheep", true, None::<&str>)?;

            // Debug submenu — every item just emits a debug-command to the webview.
            const DEBUG_ITEMS: [(&str, &str); 9] = [
                ("debug_force_feud", "Force Feud"),
                ("debug_spectacle_wolf", "Spectacle: Wolf"),
                ("debug_spectacle_ufo", "Spectacle: UFO"),
                ("debug_spectacle_merchant", "Spectacle: Merchant"),
                ("debug_spectacle_balloon", "Spectacle: Balloon"),
                ("debug_spectacle_shearing", "Spectacle: Shearing"),
                ("debug_spectacle_showdown", "Spectacle: Showdown"),
                ("debug_spectacle_feast", "Spectacle: Feast"),
                ("debug_app_switch", "Simulate App Switch"),
            ];
            let debug_item_refs: Vec<tauri::menu::MenuItem<tauri::Wry>> = DEBUG_ITEMS
                .iter()
                .map(|(id, label)| {
                    tauri::menu::MenuItem::with_id(app, *id, *label, true, None::<&str>)
                })
                .collect::<Result<Vec<_>, _>>()?;
            let debug_items_dyn: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> = debug_item_refs
                .iter()
                .map(|i| i as &dyn tauri::menu::IsMenuItem<tauri::Wry>)
                .collect();
            let debug_submenu =
                tauri::menu::Submenu::with_items(app, "Debug", true, &debug_items_dyn)?;

            // Tray icon menu
            let tray_menu = tauri::menu::Menu::with_items(app, &[&settings_item, &memory_item, &friends_item, &wardrobe_item, &chat_item, &capture_moment_item, &comment_now, &pause, &debug_submenu, &quit])?;

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
                        "friends" => {
                            let handle = app.clone();
                            tauri::async_runtime::spawn(async move {
                                if let Err(e) = open_friends_window(handle).await {
                                    eprintln!("[co-sheep] Failed to open friends: {}", e);
                                }
                            });
                        }
                        "chat" => {
                            app.emit("open-chat", ()).ok();
                        }
                        "capture_moment" => {
                            app.emit("capture-moment", ()).ok();
                        }
                        "wardrobe" => {
                            let handle = app.clone();
                            tauri::async_runtime::spawn(async move {
                                if let Err(e) = open_wardrobe_window(handle).await {
                                    eprintln!("[co-sheep] Failed to open wardrobe: {}", e);
                                }
                            });
                        }
                        id if id.starts_with("debug_") => {
                            let cmd = match id {
                                "debug_force_feud" => "force-feud",
                                "debug_spectacle_wolf" => "spectacle:wolf",
                                "debug_spectacle_ufo" => "spectacle:ufo",
                                "debug_spectacle_merchant" => "spectacle:merchant",
                                "debug_spectacle_balloon" => "spectacle:balloon",
                                "debug_spectacle_shearing" => "spectacle:shearing",
                                "debug_spectacle_showdown" => "spectacle:showdown",
                                "debug_spectacle_feast" => "spectacle:feast",
                                "debug_app_switch" => "app-switch",
                                _ => "",
                            };
                            if !cmd.is_empty() {
                                app.emit("debug-command", cmd).ok();
                            }
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
            let app_menu_friends = tauri::menu::MenuItem::with_id(
                app,
                "menu_friends",
                "Manage Friends...",
                true,
                None::<&str>,
            )?;
            let app_menu_chat = tauri::menu::MenuItem::with_id(
                app,
                "menu_chat",
                "Chat with Sheep...",
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
            let app_menu_capture_moment = tauri::menu::MenuItem::with_id(
                app,
                "menu_capture_moment",
                "Capture Moment",
                true,
                None::<&str>,
            )?;
            let app_menu_wardrobe = tauri::menu::MenuItem::with_id(
                app,
                "menu_wardrobe",
                "Wardrobe...",
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
                &[&app_menu_settings, &app_menu_memory, &app_menu_friends, &app_menu_wardrobe, &app_menu_chat, &app_menu_capture_moment, &app_menu_comment_now, &app_menu_pause, &app_menu_debug, &debug_submenu, &app_menu_quit],
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
                    "menu_friends" => {
                        let handle = app.clone();
                        tauri::async_runtime::spawn(async move {
                            if let Err(e) = open_friends_window(handle).await {
                                eprintln!("[co-sheep] Failed to open friends: {}", e);
                            }
                        });
                    }
                    "menu_chat" => {
                        app.emit("open-chat", ()).ok();
                    }
                    "menu_capture_moment" => {
                        app.emit("capture-moment", ()).ok();
                    }
                    "menu_wardrobe" => {
                        let handle = app.clone();
                        tauri::async_runtime::spawn(async move {
                            if let Err(e) = open_wardrobe_window(handle).await {
                                eprintln!("[co-sheep] Failed to open wardrobe: {}", e);
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
                    id if id.starts_with("debug_") => {
                        let cmd = match id {
                            "debug_force_feud" => "force-feud",
                            "debug_spectacle_wolf" => "spectacle:wolf",
                            "debug_spectacle_ufo" => "spectacle:ufo",
                            "debug_spectacle_merchant" => "spectacle:merchant",
                            "debug_spectacle_balloon" => "spectacle:balloon",
                            "debug_spectacle_shearing" => "spectacle:shearing",
                            "debug_spectacle_showdown" => "spectacle:showdown",
                            "debug_spectacle_feast" => "spectacle:feast",
                            "debug_app_switch" => "app-switch",
                            _ => "",
                        };
                        if !cmd.is_empty() {
                            app.emit("debug-command", cmd).ok();
                        }
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

            // Spawn frontmost-app watcher (feeds gossip & live reactions)
            eprintln!("[co-sheep] Spawning app watch loop");
            let app_watch_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                app_watch::app_watch_loop(app_watch_handle).await;
            });

            eprintln!("[co-sheep] Setup complete");
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

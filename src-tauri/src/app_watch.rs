use tauri::Emitter;

/// Name of the frontmost app, via the front-to-back CGWindowList:
/// the first on-screen layer-0 window not owned by us belongs to the
/// frontmost app. App *names* need no extra permission (window titles would).
#[cfg(target_os = "macos")]
fn frontmost_app_name(own_pid: u32) -> Option<String> {
    use std::ffi::{c_void, CString};
    use std::ptr;

    const K_CG_WINDOW_LIST_OPTION_ON_SCREEN_ONLY: u32 = 1 << 0;
    const K_CG_WINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS: u32 = 1 << 4;
    const K_CG_NULL_WINDOW_ID: u32 = 0;
    const K_CF_NUMBER_SINT32_TYPE: u32 = 3;
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) -> *const c_void;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFArrayGetCount(arr: *const c_void) -> isize;
        fn CFArrayGetValueAtIndex(arr: *const c_void, idx: isize) -> *const c_void;
        fn CFDictionaryGetValue(dict: *const c_void, key: *const c_void) -> *const c_void;
        fn CFRelease(cf: *const c_void);
        fn CFNumberGetValue(num: *const c_void, ty: u32, out: *mut c_void) -> bool;
        fn CFStringCreateWithCString(
            alloc: *const c_void,
            c_str: *const i8,
            encoding: u32,
        ) -> *const c_void;
        fn CFStringGetCString(s: *const c_void, buf: *mut i8, size: isize, encoding: u32) -> bool;
    }

    unsafe fn make_cfstring(s: &str) -> *const c_void {
        let c = CString::new(s).unwrap();
        CFStringCreateWithCString(ptr::null(), c.as_ptr(), K_CF_STRING_ENCODING_UTF8)
    }

    unsafe fn cfstring_to_string(cf: *const c_void) -> Option<String> {
        if cf.is_null() {
            return None;
        }
        let mut buf = [0i8; 256];
        if !CFStringGetCString(cf, buf.as_mut_ptr(), buf.len() as isize, K_CF_STRING_ENCODING_UTF8)
        {
            return None;
        }
        let cstr = std::ffi::CStr::from_ptr(buf.as_ptr());
        cstr.to_str().ok().map(|s| s.to_string())
    }

    unsafe {
        let info = CGWindowListCopyWindowInfo(
            K_CG_WINDOW_LIST_OPTION_ON_SCREEN_ONLY | K_CG_WINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS,
            K_CG_NULL_WINDOW_ID,
        );
        if info.is_null() {
            return None;
        }

        let key_layer = make_cfstring("kCGWindowLayer");
        let key_pid = make_cfstring("kCGWindowOwnerPID");
        let key_owner = make_cfstring("kCGWindowOwnerName");
        let mut result = None;

        let count = CFArrayGetCount(info);
        for i in 0..count {
            let dict = CFArrayGetValueAtIndex(info, i);
            if dict.is_null() {
                continue;
            }

            let layer_ref = CFDictionaryGetValue(dict, key_layer);
            if layer_ref.is_null() {
                continue;
            }
            let mut layer: i32 = -1;
            CFNumberGetValue(layer_ref, K_CF_NUMBER_SINT32_TYPE, &mut layer as *mut _ as *mut c_void);
            if layer != 0 {
                continue;
            }

            let pid_ref = CFDictionaryGetValue(dict, key_pid);
            if !pid_ref.is_null() {
                let mut pid: i32 = 0;
                CFNumberGetValue(pid_ref, K_CF_NUMBER_SINT32_TYPE, &mut pid as *mut _ as *mut c_void);
                if pid as u32 == own_pid {
                    continue;
                }
            }

            result = cfstring_to_string(CFDictionaryGetValue(dict, key_owner));
            break; // first qualifying window is frontmost
        }

        CFRelease(info);
        CFRelease(key_layer);
        CFRelease(key_pid);
        CFRelease(key_owner);
        result
    }
}

#[cfg(not(target_os = "macos"))]
fn frontmost_app_name(_own_pid: u32) -> Option<String> {
    None
}

/// Poll the frontmost app every 5s; emit "app-switched" on change.
pub async fn app_watch_loop(app: tauri::AppHandle) {
    let own_pid = std::process::id();
    let mut current: Option<String> = None;
    let mut since = std::time::Instant::now();

    loop {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;

        let front = match tokio::task::spawn_blocking(move || frontmost_app_name(own_pid)).await {
            Ok(Some(name)) => name,
            _ => continue,
        };

        if current.as_deref() != Some(front.as_str()) {
            let previous_duration_ms = since.elapsed().as_millis() as u64;
            let payload = serde_json::json!({
                "app": front,
                "previousApp": current,
                "previousDurationMs": if current.is_some() { previous_duration_ms } else { 0 },
            });
            app.emit("app-switched", payload).ok();
            log!("watch", "App switched to: {}", front);
            current = Some(front);
            since = std::time::Instant::now();
        }
    }
}

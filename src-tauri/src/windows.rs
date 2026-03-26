use serde::Serialize;

#[derive(Serialize, Clone, Debug)]
pub struct WindowRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// Returns bounding rects of visible, normal-layer windows (excluding our own app).
pub fn get_visible_window_rects(own_pid: u32) -> Vec<WindowRect> {
    #[cfg(target_os = "macos")]
    {
        get_macos_windows(own_pid)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = own_pid;
        Vec::new()
    }
}

#[cfg(target_os = "macos")]
fn get_macos_windows(own_pid: u32) -> Vec<WindowRect> {
    use std::ffi::{c_void, CString};
    use std::ptr;

    // CoreGraphics constants
    const K_CG_WINDOW_LIST_OPTION_ON_SCREEN_ONLY: u32 = 1 << 0;
    const K_CG_WINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS: u32 = 1 << 4;
    const K_CG_NULL_WINDOW_ID: u32 = 0;
    const K_CF_NUMBER_SINT32_TYPE: u32 = 3; // CFNumberType

    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGWindowListCopyWindowInfo(option: u32, relativeToWindow: u32) -> *const c_void;
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFArrayGetCount(arr: *const c_void) -> isize;
        fn CFArrayGetValueAtIndex(arr: *const c_void, idx: isize) -> *const c_void;
        fn CFDictionaryGetValue(dict: *const c_void, key: *const c_void) -> *const c_void;
        fn CFRelease(cf: *const c_void);
        fn CGRectMakeWithDictionaryRepresentation(
            dict: *const c_void,
            rect: *mut CGRect,
        ) -> bool;
        fn CFNumberGetValue(
            num: *const c_void,
            the_type: u32,
            value_ptr: *mut c_void,
        ) -> bool;
        fn CFStringCreateWithCString(
            alloc: *const c_void,
            c_str: *const i8,
            encoding: u32,
        ) -> *const c_void;
    }

    #[repr(C)]
    #[derive(Default)]
    struct CGRect {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    }

    unsafe fn make_cfstring(s: &str) -> *const c_void {
        let c = CString::new(s).unwrap();
        CFStringCreateWithCString(ptr::null(), c.as_ptr(), K_CF_STRING_ENCODING_UTF8)
    }

    let mut results = Vec::new();

    unsafe {
        let info = CGWindowListCopyWindowInfo(
            K_CG_WINDOW_LIST_OPTION_ON_SCREEN_ONLY | K_CG_WINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS,
            K_CG_NULL_WINDOW_ID,
        );
        if info.is_null() {
            return results;
        }

        let count = CFArrayGetCount(info);
        let key_bounds = make_cfstring("kCGWindowBounds");
        let key_layer = make_cfstring("kCGWindowLayer");
        let key_pid = make_cfstring("kCGWindowOwnerPID");

        for i in 0..count {
            let dict = CFArrayGetValueAtIndex(info, i);
            if dict.is_null() {
                continue;
            }

            // Only normal windows (layer 0)
            let layer_ref = CFDictionaryGetValue(dict, key_layer);
            if !layer_ref.is_null() {
                let mut layer: i32 = -1;
                CFNumberGetValue(
                    layer_ref,
                    K_CF_NUMBER_SINT32_TYPE,
                    &mut layer as *mut _ as *mut c_void,
                );
                if layer != 0 {
                    continue;
                }
            }

            // Skip our own app windows
            let pid_ref = CFDictionaryGetValue(dict, key_pid);
            if !pid_ref.is_null() {
                let mut pid: i32 = 0;
                CFNumberGetValue(
                    pid_ref,
                    K_CF_NUMBER_SINT32_TYPE,
                    &mut pid as *mut _ as *mut c_void,
                );
                if pid as u32 == own_pid {
                    continue;
                }
            }

            // Get bounds
            let bounds_ref = CFDictionaryGetValue(dict, key_bounds);
            if bounds_ref.is_null() {
                continue;
            }

            let mut rect = CGRect::default();
            if !CGRectMakeWithDictionaryRepresentation(bounds_ref, &mut rect) {
                continue;
            }

            // Skip tiny windows (status bar items, popups, etc.)
            if rect.width < 200.0 || rect.height < 100.0 {
                continue;
            }

            // Skip windows positioned off-screen (negative or very large)
            if rect.x < -500.0 || rect.y < -500.0 || rect.x > 10000.0 || rect.y > 10000.0 {
                continue;
            }

            results.push(WindowRect {
                x: rect.x,
                y: rect.y,
                w: rect.width,
                h: rect.height,
            });
        }

        CFRelease(info);
        CFRelease(key_bounds);
        CFRelease(key_layer);
        CFRelease(key_pid);
    }

    results
}

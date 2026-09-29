import CoreGraphics
import Foundation

// Ex-windows.rs and the window half of app_watch.rs: `CGWindowListCopyWindowInfo`
// called directly from Swift instead of hand-declared CoreFoundation FFI.
// Window *names* need no extra permission (window titles would), and neither
// does reading the bounds.

nonisolated enum WindowList {
    /// On-screen windows, front to back, without desktop elements.
    static func onScreenWindowInfo() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// ex-`get_visible_window_rects`: bounds of visible, normal-layer windows,
    /// excluding our own app. The sim uses them as platforms for the sheep.
    static func getVisibleWindowRects(ownPid: Int32 = ProcessInfo.processInfo.processIdentifier)
        -> [WindowPlatform]
    {
        visibleWindowRects(in: onScreenWindowInfo(), ownPid: ownPid)
    }

    /// ex-`frontmost_app_name`: the first on-screen layer-0 window not owned by
    /// us belongs to the frontmost app.
    static func frontmostAppName(ownPid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String? {
        frontmostAppName(in: onScreenWindowInfo(), ownPid: ownPid)
    }

    // MARK: - Filtering (pure, testable with synthetic window dictionaries)

    /// windows.rs filtering. Note the layer test only rejects windows that
    /// *have* a layer other than 0; a row without a layer key is kept.
    static func visibleWindowRects(in info: [[String: Any]], ownPid: Int32) -> [WindowPlatform] {
        var results: [WindowPlatform] = []
        for dict in info {
            // Only normal windows (layer 0)
            if let layerRef = dict[kCGWindowLayer as String] {
                if int32(layerRef) ?? -1 != 0 { continue }
            }

            // Skip our own app windows
            if let pidRef = dict[kCGWindowOwnerPID as String] {
                if (int32(pidRef) ?? 0) == ownPid { continue }
            }

            // Get bounds
            guard let boundsRef = dict[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsRef as CFDictionary)
            else { continue }

            // Skip tiny windows (status bar items, popups, etc.)
            if rect.width < 200 || rect.height < 100 { continue }

            // Skip windows positioned off-screen (negative or very large)
            if rect.origin.x < -500 || rect.origin.y < -500 || rect.origin.x > 10000 || rect.origin.y > 10000 {
                continue
            }

            results.append(WindowPlatform(
                x: Double(rect.origin.x), y: Double(rect.origin.y),
                w: Double(rect.size.width), h: Double(rect.size.height)))
        }
        return results
    }

    /// app_watch.rs filtering. Stricter on the layer than windows.rs (a row
    /// without a layer key is skipped), no size or bounds filter, and the first
    /// qualifying window decides the answer even if its owner name is unusable.
    static func frontmostAppName(in info: [[String: Any]], ownPid: Int32) -> String? {
        for dict in info {
            guard let layerRef = dict[kCGWindowLayer as String] else { continue }
            if int32(layerRef) ?? -1 != 0 { continue }

            if let pidRef = dict[kCGWindowOwnerPID as String] {
                if (int32(pidRef) ?? 0) == ownPid { continue }
            }

            // First qualifying window is frontmost. The Rust read the name into a
            // 256-byte C buffer, so a name over 255 UTF-8 bytes counts as absent.
            guard let name = dict[kCGWindowOwnerName as String] as? String, name.utf8.count <= 255 else {
                return nil
            }
            return name
        }
        return nil
    }

    /// `CFNumberGetValue(…, kCFNumberSInt32Type, …)`.
    private static func int32(_ value: Any) -> Int32? {
        (value as? NSNumber)?.int32Value
    }
}

import CoreGraphics

// Ex-permissions.rs.

nonisolated enum Permissions {
    /// ex-`has_screen_capture_permission`: `CGPreflightScreenCaptureAccess`.
    /// Does not prompt. macOS may keep answering false until the app restarts
    /// even after the user grants access, which is why callers still try a real
    /// capture as the actual test.
    static func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// ex-`request_screen_capture_permission`: triggers the system permission
    /// dialog if access has not been granted. Returns true if permission was
    /// already granted, false if the dialog was shown (the user still needs to
    /// grant it and restart).
    @discardableResult
    static func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

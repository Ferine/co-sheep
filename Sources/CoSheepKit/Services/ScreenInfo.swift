import CoreGraphics
import Foundation

// Ex-screen_info.rs.

/// Error type shared by the platform services (capture, screen info, weather,
/// MCP server). Carries the same kind of plain message the Rust `Box<dyn Error>`
/// strings did.
nonisolated struct PlatformError: Error, CustomStringConvertible, Equatable {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Primary display size in points (ex-`ScreenInfo { width: u32, height: u32 }`).
nonisolated struct ScreenInfo: Equatable, Codable {
    var width: Int
    var height: Int
}

nonisolated extension ScreenInfo {
    /// The display xcap treated as "the monitor": `Monitor::all()?.first()`, i.e.
    /// the first entry of `CGGetActiveDisplayList` (the main display).
    /// Throws "No monitor found" when there is no active display.
    static func primaryDisplayID() throws -> CGDirectDisplayID {
        let maxDisplays: UInt32 = 16
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var count: UInt32 = 0
        let err = CGGetActiveDisplayList(maxDisplays, &ids, &count)
        guard err == .success else {
            throw PlatformError("CGGetActiveDisplayList failed: \(err.rawValue)")
        }
        guard count > 0 else { throw PlatformError("No monitor found") }
        return ids[0]
    }

    /// ex-`get_primary_screen_info`. Width/height are `CGDisplayBounds` in points,
    /// truncated to whole numbers like xcap's `as u32`.
    static func getPrimaryScreenInfo() throws -> ScreenInfo {
        let id = try primaryDisplayID()
        let bounds = CGDisplayBounds(id)
        return ScreenInfo(width: Int(bounds.size.width), height: Int(bounds.size.height))
    }
}

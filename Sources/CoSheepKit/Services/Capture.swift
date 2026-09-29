import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// Ex-capture.rs. xcap's `CGWindowListCreateImage` is replaced by
// ScreenCaptureKit; the JPEG q70 + base64 hop was only transport to the sidecar
// and is gone (the OCR runs on the CGImage directly).

nonisolated enum Capture {
    /// capture.rs downscales so the longest side is at most 1568 px ("plenty
    /// for OCR"), never upscaling, because OCR cost grows with pixel count.
    static let maxLongestSide = 1568.0

    /// ex-`let scale = (1568.0 / w.max(h) as f64).min(1.0)` and the truncating
    /// `as u32` casts.
    static func targetSize(width: Int, height: Int, maxLongestSide: Double = Capture.maxLongestSide)
        -> (width: Int, height: Int)
    {
        let scale = min(maxLongestSide / Double(max(width, height)), 1.0)
        return (Int(Double(width) * scale), Int(Double(height) * scale))
    }

    /// ex-`capture_screen`: the primary display, downscaled for OCR. Asks
    /// ScreenCaptureKit for the target size directly, so no full-resolution
    /// copy is made just to be resized. Like xcap, the cursor is not captured
    /// and our own overlay window is not excluded.
    static func captureScreen() async throws -> CGImage {
        Log.debug("capture", "enumerating monitors...")
        let (filter, pixelWidth, pixelHeight) = try await primaryDisplayFilter()
        let target = targetSize(width: pixelWidth, height: pixelHeight)
        Log.debug("capture", "capturing screen...")
        let image = try await screenshot(filter: filter, width: target.width, height: target.height)
        Log.debug(
            "capture",
            "captured \(pixelWidth)x\(pixelHeight) screen, downscaled to \(image.width)x\(image.height)")
        return image
    }

    /// ex-`save_debug_screenshot`: full-resolution PNG of the primary display,
    /// saved so the user can verify what the sheep sees. Returns the file path.
    /// `directory` defaults to `~/Desktop`; the file is `co-sheep-debug-capture.png`.
    static func saveDebugScreenshot(directory: URL? = nil) async throws -> String {
        let (filter, pixelWidth, pixelHeight) = try await primaryDisplayFilter()
        let image = try await screenshot(filter: filter, width: pixelWidth, height: pixelHeight)

        let dir = directory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let url = dir.appendingPathComponent("co-sheep-debug-capture.png")
        try await writePNG(image, to: url)

        let path = url.path
        Log.info("capture", "debug screenshot saved to: \(path)")
        return path
    }

    /// PNG-encode `image` to `url`. Off the main thread: encoding a Retina
    /// screenshot is CPU-heavy.
    @concurrent
    static func writePNG(_ image: CGImage, to url: URL) async throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw PlatformError("Failed to create PNG destination at \(url.path)") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw PlatformError("Failed to write PNG to \(url.path)")
        }
    }

    // MARK: - ScreenCaptureKit

    /// Content filter for the primary display plus its size in pixels.
    private static func primaryDisplayFilter() async throws -> (SCContentFilter, Int, Int) {
        let content = try await SCShareableContent.current
        Log.debug("capture", "found \(content.displays.count) monitor(s)")
        let primaryID = try ScreenInfo.primaryDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == primaryID })
                ?? content.displays.first
        else { throw PlatformError("No monitor found") }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = Double(filter.pointPixelScale)
        let pixelWidth = Int((filter.contentRect.width * scale).rounded())
        let pixelHeight = Int((filter.contentRect.height * scale).rounded())
        return (filter, pixelWidth, pixelHeight)
    }

    private static func screenshot(filter: SCContentFilter, width: Int, height: Int) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = max(1, width)
        config.height = max(1, height)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CoSheepKit

// capture.rs, screen_info.rs and permissions.rs had no Rust tests. The pure
// parts run everywhere; live screen capture only runs when Screen Recording
// access is already granted (asking would pop a system dialog on a dev Mac).

func makeTestImage(width: Int, height: Int, gray: CGFloat = 1) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

@Suite("capture")
struct CaptureTests {
    // MARK: downscaling (capture.rs: longest side <= 1568, never upscale)

    @Test func longestSideIsCappedAt1568() {
        #expect(Capture.maxLongestSide == 1568)
        #expect(Capture.targetSize(width: 3456, height: 2234) == (1568, 1013)) // 14" MacBook Pro native
        #expect(Capture.targetSize(width: 3024, height: 1964) == (1568, 1018))
        #expect(Capture.targetSize(width: 2560, height: 1440) == (1568, 882))
        #expect(Capture.targetSize(width: 5120, height: 2880) == (1568, 882))
        #expect(Capture.targetSize(width: 3840, height: 2160) == (1568, 882))
    }

    @Test func smallerScreensAreNeverUpscaled() {
        #expect(Capture.targetSize(width: 1440, height: 900) == (1440, 900))
        #expect(Capture.targetSize(width: 1568, height: 1000) == (1568, 1000))
        #expect(Capture.targetSize(width: 1568, height: 1568) == (1568, 1568))
        #expect(Capture.targetSize(width: 1, height: 1) == (1, 1))
    }

    @Test func justOverTheLimitShrinksSlightly() {
        #expect(Capture.targetSize(width: 1569, height: 1000) == (1568, 999))
    }

    @Test func portraitScreensCapTheHeight() {
        // The same IEEE double arithmetic as the Rust `(h as f64 * scale) as u32`,
        // so the truncation lands on 1567 there too.
        #expect(Capture.targetSize(width: 1000, height: 3000) == (522, 1567))
    }

    @Test func customLimit() {
        #expect(Capture.targetSize(width: 2000, height: 1000, maxLongestSide: 1000) == (1000, 500))
    }

    // MARK: PNG writing (save_debug_screenshot)

    @Test func writePNGRoundTrips() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("co-sheep-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shot.png")

        try await Capture.writePNG(makeTestImage(width: 64, height: 40, gray: 0.5), to: url)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64)
        #expect(image.height == 40)
    }

    @Test func writePNGToAMissingDirectoryThrows() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("co-sheep-missing-\(UUID().uuidString)/nested/shot.png")
        await #expect(throws: PlatformError.self) {
            try await Capture.writePNG(makeTestImage(width: 4, height: 4), to: url)
        }
    }

    // MARK: live capture, only with permission already granted

    @Test(.enabled(if: Permissions.hasScreenCapturePermission() && (try? ScreenInfo.primaryDisplayID()) != nil))
    func liveCaptureIsDownscaledForOCR() async throws {
        let image = try await Capture.captureScreen()
        #expect(max(image.width, image.height) <= Int(Capture.maxLongestSide))
        #expect(image.width > 0 && image.height > 0)
    }

    @Test(.enabled(if: Permissions.hasScreenCapturePermission() && (try? ScreenInfo.primaryDisplayID()) != nil))
    func liveDebugScreenshotIsSavedAsPNG() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("co-sheep-debug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try await Capture.saveDebugScreenshot(directory: dir)

        #expect(path == dir.appendingPathComponent("co-sheep-debug-capture.png").path)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

@Suite("screen info")
struct ScreenInfoTests {
    @Test(.enabled(if: (try? ScreenInfo.primaryDisplayID()) != nil))
    func primaryScreenHasASize() throws {
        let info = try ScreenInfo.getPrimaryScreenInfo()
        #expect(info.width > 0)
        #expect(info.height > 0)
    }

    @Test(.enabled(if: (try? ScreenInfo.primaryDisplayID()) != nil))
    func sizeMatchesTheDisplayBoundsInPoints() throws {
        let id = try ScreenInfo.primaryDisplayID()
        let bounds = CGDisplayBounds(id)
        let info = try ScreenInfo.getPrimaryScreenInfo()
        #expect(info.width == Int(bounds.width))
        #expect(info.height == Int(bounds.height))
    }

    @Test func jsonShapeMatchesTheRustStruct() throws {
        let data = try JSONEncoder().encode(ScreenInfo(width: 1440, height: 900))
        #expect(try JSONDecoder().decode(JSONValue.self, from: data)
            == .object(["width": .number(1440), "height": .number(900)]))
        let back = try JSONDecoder().decode(ScreenInfo.self, from: Data(#"{"width":2560,"height":1440}"#.utf8))
        #expect(back == ScreenInfo(width: 2560, height: 1440))
    }

    @Test func platformErrorPrintsItsMessage() {
        #expect("\(PlatformError("No monitor found"))" == "No monitor found")
    }
}

@Suite("permissions")
struct PermissionsTests {
    // Requesting would show the system dialog, so only the preflight is exercised.
    @Test func preflightIsStableAndDoesNotPrompt() {
        let first = Permissions.hasScreenCapturePermission()
        let second = Permissions.hasScreenCapturePermission()
        #expect(first == second)
    }
}

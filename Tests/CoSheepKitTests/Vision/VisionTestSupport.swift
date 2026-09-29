import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

// Fakes for the vision pipeline and AppController: a scriptable model, a fake
// screen (no ScreenCaptureKit, no permission dialog), a commentary collector
// on a private `AppEvents`, and a sleeper that ends the loop after N waits.

func visionTestImage(width: Int = 8, height: Int = 8) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// Scriptable `LanguageModel`: availability, OCR text, and one canned reply per
/// call kind. Classification is told apart from commentary by its system prompt.
final class ScriptedModel: LanguageModel {
    var reason: String?
    var ocrText = "error[E0308]: mismatched types in main.rs"
    var ocrFailure: (any Error)?
    var onOCR: (() -> Void)?
    var classification = #"{"interesting": true, "category": "code", "summary": "Rust compile errors in a terminal"}"#
    var commentary = #"{"text": "Baaa.", "animation": "bounce"}"#
    var chatReply = #"{"text": "Baaa.", "animation": null}"#
    var generateFailure: (any Error)?
    var chatFailure: (any Error)?

    private(set) var generateCalls: [(system: String, prompt: String)] = []
    private(set) var chatCalls: [(system: String, prompt: String, history: [HistoryTurn])] = []
    private(set) var ocrCalls = 0

    func unavailableReason() -> String? { reason }

    func generate(system: String, prompt: String) async throws -> String {
        generateCalls.append((system, prompt))
        if let generateFailure { throw generateFailure }
        return system == VisionPipeline.CLASSIFY_SYSTEM ? classification : commentary
    }

    func generateChat(system: String, prompt: String, history: [HistoryTurn]) async throws -> String {
        chatCalls.append((system, prompt, history))
        if let chatFailure { throw chatFailure }
        return chatReply
    }

    func ocr(_ image: CGImage) async throws -> String {
        ocrCalls += 1
        onOCR?()
        if let ocrFailure { throw ocrFailure }
        return ocrText
    }
}

/// A `ScreenAccess` that hands back a solid image and counts what was asked.
final class ScreenRecorder {
    var permitted = true
    /// Runs on every capture with the 1-based call number; throw to fail it.
    var captureHook: ((Int) throws -> Void)?
    var debugResult: Result<String, any Error> = .success("/tmp/co-sheep-debug-capture.png")

    private(set) var captureCount = 0
    private(set) var permissionRequests = 0
    private(set) var debugDirectories: [URL] = []
    let image = visionTestImage()

    var access: ScreenAccess {
        ScreenAccess(
            captureScreen: { [self] in
                captureCount += 1
                try captureHook?(captureCount)
                return image
            },
            saveDebugScreenshot: { [self] directory in
                debugDirectories.append(directory)
                return try debugResult.get()
            },
            hasScreenCapturePermission: { [self] in permitted },
            requestScreenCapturePermission: { [self] in permissionRequests += 1 })
    }
}

/// Collects `sheep-commentary` emissions from a private `AppEvents`.
final class CommentaryLog {
    let events = AppEvents()
    private(set) var lines: [CommentaryEvent] = []

    init() {
        events.sheepCommentary.on { [self] in lines.append($0) }
    }

    var texts: [String] { lines.map(\.text) }
}

/// The loop's `sleep`: records every wait and throws `CancellationError` on the
/// `limit`-th one, which ends `run()` exactly like a cancelled `Task.sleep`.
final class SleepScript {
    let limit: Int
    private(set) var calls: [Double] = []
    /// Runs with the 1-based call number, before the limit check.
    var onCall: ((Int) -> Void)?

    init(limit: Int) { self.limit = limit }

    func sleep(_ seconds: Double) async throws {
        calls.append(seconds)
        onCall?(calls.count)
        if calls.count >= limit { throw CancellationError() }
    }
}

/// A pipeline wired to the fakes. Weather is disabled (empty location) unless
/// given, jitter nanos are pinned to 0 (so the interval is `base - 20%`).
final class VisionRig {
    let model = ScriptedModel()
    let screen = ScreenRecorder()
    let commentary = CommentaryLog()
    let sleeps: SleepScript
    let pipeline: VisionPipeline

    init(sleepLimit: Int = 1, weather: Weather = Weather(location: { "" }), nanos: UInt64 = 0) {
        let sleeps = SleepScript(limit: sleepLimit)
        self.sleeps = sleeps
        pipeline = VisionPipeline(
            model: model, screen: screen.access, events: commentary.events, weather: weather,
            sleep: { try await sleeps.sleep($0) }, nanos: { nanos })
    }
}

/// The whole of today's journal file ("" when nothing was written).
func todaysJournal() -> String {
    Memory.readJournalFor(BrainTime.today()) ?? ""
}

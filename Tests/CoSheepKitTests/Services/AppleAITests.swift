import CoreGraphics
import CoreText
import Foundation
import FoundationModels
import Synchronization
import Testing
@testable import CoSheepKit

// apple_ai.rs and the sidecar had no tests. The transcript building is pure and
// always runs; anything that needs the model or the Vision runtime is skipped
// when this machine cannot provide it.

private func renderText(_ text: String, fontSize: CGFloat = 72) -> CGImage {
    let width = 1400, height = 200
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
    ]
    let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
    ctx.textPosition = CGPoint(x: 40, y: 70)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
    return ctx.makeImage()!
}

@Suite("apple ai")
struct AppleAITests {
    // MARK: transcript (ex-`runGenerate`)

    private func text(of segments: [Transcript.Segment]) -> String? {
        guard segments.count == 1, case .text(let t) = segments[0] else { return nil }
        return t.content
    }

    @Test func transcriptStartsWithTheInstructions() throws {
        let t = AppleAI.makeTranscript(system: "You are a sheep.", history: [])
        #expect(t.count == 1)
        guard case .instructions(let instructions) = t[0] else {
            Issue.record("first entry must be instructions")
            return
        }
        #expect(text(of: instructions.segments) == "You are a sheep.")
        #expect(instructions.toolDefinitions.isEmpty)
    }

    @Test func sheepTurnsAreResponsesAndEverythingElseIsAPrompt() {
        let history = [
            HistoryTurn(role: "human", text: "hi"),
            HistoryTurn(role: "sheep", text: "baa"),
            HistoryTurn(role: "human", text: "again?"),
            HistoryTurn(role: "narrator", text: "anything else is a prompt"),
        ]
        let t = AppleAI.makeTranscript(system: "sys", history: history)
        #expect(t.count == 5)

        guard case .prompt(let p1) = t[1], case .response(let r) = t[2],
              case .prompt(let p2) = t[3], case .prompt(let p3) = t[4]
        else {
            Issue.record("unexpected entry kinds: \(Array(t))")
            return
        }
        #expect(text(of: p1.segments) == "hi")
        #expect(text(of: r.segments) == "baa")
        #expect(r.assetIDs.isEmpty)
        #expect(text(of: p2.segments) == "again?")
        #expect(text(of: p3.segments) == "anything else is a prompt")
    }

    @Test func historyKeepsItsOrderAndUnicode() {
        let history = (0..<6).map { HistoryTurn(role: $0 % 2 == 0 ? "human" : "sheep", text: "æøå \($0)") }
        let t = AppleAI.makeTranscript(system: "sys", history: history)
        #expect(t.count == 7)
        for (i, turn) in history.enumerated() {
            switch t[i + 1] {
            case .prompt(let p): #expect(turn.role == "human" && text(of: p.segments) == turn.text)
            case .response(let r): #expect(turn.role == "sheep" && text(of: r.segments) == turn.text)
            default: Issue.record("unexpected entry at \(i + 1)")
            }
        }
    }

    // MARK: availability

    @Test func unavailableReasonMapsTheSystemAvailability() {
        let reason = AppleAI().unavailableReason()
        switch SystemLanguageModel.default.availability {
        case .available:
            #expect(reason == nil)
        case .unavailable(let why):
            #expect(reason == String(describing: why))
            #expect(reason?.isEmpty == false)
        }
    }

    // MARK: generation, only with Apple Intelligence available

    @Test(.enabled(if: SystemLanguageModel.default.isAvailable))
    func generatesText() async throws {
        let ai = AppleAI()
        let reply = try await ai.generate(system: "Reply with one short word.", prompt: "Say hello.")
        #expect(!reply.isEmpty)
        #expect(reply == reply.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test(.enabled(if: SystemLanguageModel.default.isAvailable))
    func generatesChatWithHistory() async throws {
        let ai = AppleAI()
        let reply = try await ai.generateChat(
            system: "Reply with one short sentence.", prompt: "What did I just say?",
            history: [HistoryTurn(role: "human", text: "My favourite colour is green."),
                      HistoryTurn(role: "sheep", text: "Noted.")])
        #expect(!reply.isEmpty)
    }

    // MARK: OCR (Vision needs its ML runtime, which sandboxed shells may lack)

    // One test on purpose. Where the recognizer cannot run, the first attempt
    // fails only after about half a minute, so the wait is capped and the test
    // is cancelled (skipped) instead of holding the whole suite up.
    @Test func ocrReadsRenderedTextAndNothingFromABlankImage() async throws {
        let ai = AppleAI()
        let outcome = await withTimeout(.seconds(10)) { try await ai.ocr(renderText("HELLO SHEEP 42")) }
        let text: String
        switch outcome {
        case nil:
            try Test.cancel("Vision text recognition did not answer within 10 s (no ML runtime here?)")
        case .failure(let error)?:
            // Same wrapper the helper's `fail("ocr: \u{2026}")` had.
            #expect((error as? CoSheepKit.LanguageModelError)?.description.hasPrefix("ocr: ") == true)
            try Test.cancel("Vision text recognition is unavailable in this environment: \(error)")
        case .success(let recognized)?:
            text = recognized
        }
        #expect(text.uppercased().contains("HELLO"))
        #expect(text.uppercased().contains("SHEEP"))
        #expect(text == text.trimmingCharacters(in: .whitespacesAndNewlines))

        let blank = try await ai.ocr(makeTestImage(width: 200, height: 100))
        #expect(blank.isEmpty)
    }
}

/// Result of `work`, or nil if it has not finished after `limit`. The work is
/// not cancelled on timeout (a blocking Vision call cannot be), it just stops
/// being waited for.
private func withTimeout(
    _ limit: Duration, _ work: @escaping () async throws -> String
) async -> Result<String, any Error>? {
    let gate = OnceGate()
    return await withCheckedContinuation { continuation in
        Task {
            let result: Result<String, any Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            if gate.claim() { continuation.resume(returning: result) }
        }
        Task {
            try? await Task.sleep(for: limit)
            if gate.claim() { continuation.resume(returning: nil) }
        }
    }
}

private nonisolated final class OnceGate: Sendable {
    private let claimed = Mutex(false)
    /// True for the first caller only.
    func claim() -> Bool {
        claimed.withLock { taken in
            defer { taken = true }
            return !taken
        }
    }
}

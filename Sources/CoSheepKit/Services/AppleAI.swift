import CoreGraphics
import Foundation
import FoundationModels
import Vision

// Ex-apple_ai.rs + helper/apple-ai-helper.swift. The sidecar (one process per
// request over stdin/stdout) is gone: FoundationModels and Vision are called
// in-process. Semantics are kept exactly as the helper had them, including the
// `.trim()` Rust applied to whatever the helper printed.

/// The real `LanguageModel`: Apple's on-device foundation model plus Vision OCR.
final class AppleAI: LanguageModel {
    init() {}

    /// ex-`availability()` / `check_available()`. nil when the model is usable,
    /// else `String(describing:)` of the unavailable reason (e.g.
    /// "appleIntelligenceNotEnabled"), exactly what the helper reported.
    func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return String(describing: reason)
        }
    }

    /// ex-`generate`: a fresh session per request.
    func generate(system: String, prompt: String) async throws -> String {
        try await run(system: system, prompt: prompt, history: [])
    }

    /// ex-`generate_chat`: prior turns are replayed as a native `Transcript` so
    /// the model's own chat template owns turn structure, which a small model
    /// handles far better than history folded into the prompt.
    func generateChat(system: String, prompt: String, history: [HistoryTurn]) async throws -> String {
        try await run(system: system, prompt: prompt, history: history)
    }

    /// ex-`ocr_screen`: Vision text recognition, one line per observation.
    func ocr(_ image: CGImage) async throws -> String {
        try await Self.recognizeText(in: image)
    }

    // MARK: - Generation (ex-`runGenerate`)

    private func run(system: String, prompt: String, history: [HistoryTurn]) async throws -> String {
        let session = Self.makeSession(system: system, history: history)
        do {
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw LanguageModelError("generate: \(error)")
        }
    }

    static func makeSession(system: String, history: [HistoryTurn]) -> LanguageModelSession {
        if history.isEmpty {
            return LanguageModelSession(instructions: system)
        }
        return LanguageModelSession(transcript: makeTranscript(system: system, history: history))
    }

    /// Rebuilds the conversation as a native Transcript: an instructions entry,
    /// then `sheep` turns as responses and anything else as prompts.
    static func makeTranscript(system: String, history: [HistoryTurn]) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [textSegment(system)], toolDefinitions: []))
        ]
        for turn in history {
            if turn.role == "sheep" {
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [textSegment(turn.text)])))
            } else {
                entries.append(.prompt(Transcript.Prompt(segments: [textSegment(turn.text)])))
            }
        }
        return Transcript(entries: entries)
    }

    private static func textSegment(_ content: String) -> Transcript.Segment {
        .text(Transcript.TextSegment(content: content))
    }

    // MARK: - OCR (ex-`runOCR`)

    /// Accurate-level recognition with language correction, lines joined with
    /// "\n" and trimmed. `@concurrent` keeps the blocking recognition off the
    /// main thread.
    ///
    /// This deliberately stays on `VNRecognizeTextRequest`, the request the
    /// helper used, with its defaults untouched. The newer `RecognizeTextRequest`
    /// spells one default differently (`minimumTextHeightFraction` is an explicit
    /// 1/32 where the old `minimumTextHeight` is 0), and screenshots are full of
    /// small text, so switching APIs could change what gets recognized.
    @concurrent
    static func recognizeText(in image: CGImage) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw LanguageModelError("ocr: \(error)")
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

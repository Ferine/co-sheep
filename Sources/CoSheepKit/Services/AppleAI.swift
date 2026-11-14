import CoreGraphics
import Foundation
import FoundationModels
import Synchronization
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

    func generate(system: String, prompt: String, shape: ReplyShape) async throws -> String {
        try await run(system: system, prompt: prompt, history: [], shape: shape)
    }

    func generateChat(system: String, prompt: String, history: [HistoryTurn], shape: ReplyShape) async throws -> String {
        try await run(system: system, prompt: prompt, history: history, shape: shape)
    }

    /// ex-`ocr_screen`: Vision text recognition, one line per observation.
    func ocr(_ image: CGImage) async throws -> String {
        try await Self.recognizeText(in: image)
    }

    // MARK: - Generation (ex-`runGenerate`)

    private func run(
        system: String, prompt: String, history: [HistoryTurn], shape: ReplyShape? = nil
    ) async throws -> String {
        let session = Self.makeSession(system: system, history: history)
        do {
            if let shape {
                // Guided generation: the reply is the schema's JSON, nothing else.
                let response = try await session.respond(to: prompt, schema: try Self.schema(for: shape))
                return response.content.jsonString
            }
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Self.describe(error)
        }
    }

    /// Our error for a failed generation, keeping what the caller can act on.
    static func describe(_ error: any Error) -> LanguageModelError {
        var kind = LanguageModelError.Kind.other
        if let failure = error as? FoundationModels.LanguageModelError {
            switch failure {
            case .contextSizeExceeded: kind = .contextTooLarge
            case .guardrailViolation, .refusal: kind = .refused
            case .unsupportedLanguageOrLocale: kind = .unsupportedLanguage
            default: break
            }
        }
        return LanguageModelError("generate: \(error)", kind: kind)
    }

    // MARK: - Guided generation

    static let animationNames = SheepAnimation.allCases.map(\.rawValue)
    static let opinionCategories = ["habit", "fact", "opinion", "pattern"]

    /// The schema the model's reply is constrained to.
    static func schema(for shape: ReplyShape) throws -> GenerationSchema {
        switch shape {
        case .screenClassification:
            let root = DynamicGenerationSchema(name: "ScreenClassification", properties: [
                .init(name: "interesting", description: "Whether anything notable is happening",
                      schema: .init(type: Bool.self)),
                .init(name: "category", description: "The kind of app or content, in a word or two",
                      schema: .init(type: String.self)),
                .init(name: "summary", description: "Brief description of what is on the screen",
                      schema: .init(type: String.self)),
            ])
            return try GenerationSchema(root: root, dependencies: [])
        case .sheepLine:
            let animation = DynamicGenerationSchema(name: "Animation", anyOf: animationNames)
            let category = DynamicGenerationSchema(name: "OpinionCategory", anyOf: opinionCategories)
            let root = DynamicGenerationSchema(name: "SheepLine", properties: [
                .init(name: "text", description: "What the sheep says", schema: .init(type: String.self)),
                .init(name: "animation", description: "Physical animation; leave out for a calm observation",
                      schema: .init(referenceTo: "Animation"), isOptional: true),
                .init(name: "opinion_topic", description: "Short topic key, only when forming an opinion",
                      schema: .init(type: String.self), isOptional: true),
                .init(name: "opinion", description: "The opinion, only when genuinely relevant",
                      schema: .init(type: String.self), isOptional: true),
                .init(name: "opinion_category", schema: .init(referenceTo: "OpinionCategory"), isOptional: true),
                .init(name: "count", description: "Daily counter key, only when tracking something recurring",
                      schema: .init(type: String.self), isOptional: true),
            ])
            return try GenerationSchema(root: root, dependencies: [animation, category])
        }
    }

    // MARK: - What this Mac's model can do

    /// BCP 47 codes of the Settings language options.
    nonisolated static let languageCodes = [
        "nynorsk": "nn", "bokmål": "nb", "english": "en", "swedish": "sv", "danish": "da",
        "german": "de", "french": "fr", "spanish": "es", "japanese": "ja", "korean": "ko",
    ]

    /// Whether the on-device model lists the Settings language `key` as one
    /// it supports. True when there is nothing useful to say: an unknown key,
    /// or no model to ask. (An unlisted language still gets answers, since the
    /// instructions are in English, but the sheep slips into other languages.)
    static func supportsLanguage(_ key: String) -> Bool {
        guard let code = languageCodes[key.lowercased()] else { return true }
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return true }
        return model.supportsLocale(Locale(identifier: code))
    }

    /// The model's context window in tokens (4,096 on the first models,
    /// 8,192 on the macOS 27 ones).
    static var contextSize: Int { SystemLanguageModel.default.contextSize }

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
        // Some macOS 27 builds fail the accurate recognizer outright
        // (`e5rtError … 13` building its compute op, even CPU-only) while the
        // fast recognizer works. Fall back once and remember it for the
        // process lifetime: the failing probe can take ~15 s the first time.
        if !accurateUnavailable.withLock({ $0 }) {
            do {
                return try perform(image, level: .accurate)
            } catch {
                accurateUnavailable.withLock { $0 = true }
                Log.info("vision", "error: accurate OCR failed (\(error)); falling back to fast recognition")
            }
        }
        do {
            return try perform(image, level: .fast)
        } catch {
            throw LanguageModelError("ocr: \(error)")
        }
    }

    nonisolated private static let accurateUnavailable = Mutex(false)

    nonisolated private static func perform(_ image: CGImage, level: VNRequestTextRecognitionLevel) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

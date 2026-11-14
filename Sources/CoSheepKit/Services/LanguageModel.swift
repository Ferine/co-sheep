import CoreGraphics
import Foundation

/// One prior chat turn, replayed as a native Transcript entry.
nonisolated struct HistoryTurn: Equatable, Codable {
    var role: String   // "human" | "sheep"
    var text: String
}

/// The JSON a reply has to be. `AppleAI` enforces it with guided generation
/// (the framework constrains the model's output to a schema), so the reply
/// always parses and a field like `animation` can only hold one of its real
/// values. Asked for JSON in prose alone, the model now and then copies a
/// placeholder out of the prompt (`"animation": "name_or_null"`).
nonisolated enum ReplyShape: Equatable, Sendable {
    /// `{"interesting": bool, "category": string, "summary": string}`
    case screenClassification
    /// `{"text": string}` plus the optional `animation`, `opinion_topic`,
    /// `opinion`, `opinion_category` and `count`.
    case sheepLine
}

/// The on-device model + OCR surface Brain and Vision code against.
/// `AppleAI` is the real implementation; tests inject fakes.
///
/// (FoundationModels has had a `LanguageModel` protocol and a
/// `LanguageModelError` of its own since the macOS 27 SDK. These are ours;
/// a file that imports FoundationModels must spell Apple's with the module
/// name.)
protocol LanguageModel: AnyObject {
    /// nil when available, else the reason string (e.g. "appleIntelligenceNotEnabled").
    func unavailableReason() -> String?
    func generate(system: String, prompt: String) async throws -> String
    func generateChat(system: String, prompt: String, history: [HistoryTurn]) async throws -> String
    /// `generate`, with the reply held to `shape`.
    func generate(system: String, prompt: String, shape: ReplyShape) async throws -> String
    /// `generateChat`, with the reply held to `shape`.
    func generateChat(system: String, prompt: String, history: [HistoryTurn], shape: ReplyShape) async throws -> String
    /// Recognized screen text, one line per observation.
    func ocr(_ image: CGImage) async throws -> String
}

extension LanguageModel {
    // A model that can't constrain its output (the test fakes) just answers.
    func generate(system: String, prompt: String, shape: ReplyShape) async throws -> String {
        try await generate(system: system, prompt: prompt)
    }

    func generateChat(system: String, prompt: String, history: [HistoryTurn], shape: ReplyShape) async throws -> String {
        try await generateChat(system: system, prompt: prompt, history: history)
    }
}

nonisolated struct LanguageModelError: Error, CustomStringConvertible {
    /// What went wrong, where the caller can do something about it.
    enum Kind: Equatable, Sendable {
        case other
        /// The prompt did not fit the model's context window: send less.
        case contextTooLarge
        /// A guardrail stopped it, or the model declined to answer.
        case refused
        /// The model can't work in the language it was given.
        case unsupportedLanguage
    }

    var description: String
    var kind: Kind

    init(_ description: String, kind: Kind = .other) {
        self.description = description
        self.kind = kind
    }
}

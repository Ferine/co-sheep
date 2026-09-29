import CoreGraphics
import Foundation

/// One prior chat turn, replayed as a native Transcript entry.
nonisolated struct HistoryTurn: Equatable, Codable {
    var role: String   // "human" | "sheep"
    var text: String
}

/// The on-device model + OCR surface Brain and Vision code against.
/// `AppleAI` is the real implementation; tests inject fakes.
protocol LanguageModel: AnyObject {
    /// nil when available, else the reason string (e.g. "appleIntelligenceNotEnabled").
    func unavailableReason() -> String?
    func generate(system: String, prompt: String) async throws -> String
    func generateChat(system: String, prompt: String, history: [HistoryTurn]) async throws -> String
    /// Recognized screen text, one line per observation.
    func ocr(_ image: CGImage) async throws -> String
}

nonisolated struct LanguageModelError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

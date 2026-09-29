import Foundation

// Ex-chat-transcript.ts.

/// One exchange line in a chat session with the main sheep.
nonisolated struct ChatTurn: Equatable {
    enum Role: String {
        case human
        case sheep
    }

    var role: Role
    var text: String

    init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

nonisolated enum ChatTranscriptLimits {
    static let MAX_TURNS = 8
    static let CHAR_BUDGET = 1500
}

/// Cap a chat transcript for the on-device model's small context window:
/// last `MAX_TURNS` turns, dropping the oldest until the total text fits
/// `CHAR_BUDGET`. The newest turn is always kept.
nonisolated func capTranscript(_ turns: [ChatTurn]) -> [ChatTurn] {
    let recent = Array(turns.suffix(ChatTranscriptLimits.MAX_TURNS))
    var kept: [ChatTurn] = []
    var total = 0
    for i in stride(from: recent.count - 1, through: 0, by: -1) {
        // JS `string.length` counts UTF-16 code units.
        total += recent[i].text.utf16.count
        if total > ChatTranscriptLimits.CHAR_BUDGET, !kept.isEmpty { break }
        kept.insert(recent[i], at: 0)
    }
    return kept
}

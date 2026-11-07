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

/// One chat window's transcript plus its in-flight bookkeeping. Each message
/// gets a sequence number; a reply (or failure) only counts when no newer
/// message superseded it, and an unanswered human turn never stays behind —
/// otherwise a superseded or failed message left two human turns in a row in
/// the transcript and in the next prompt's history.
nonisolated struct ChatSessionLog: Equatable {
    private(set) var turns: [ChatTurn] = []
    private(set) var seq = 0
    /// The last turn is a human message still waiting for its answer.
    private var awaiting = false

    /// A new message. Returns its sequence number and the (capped) history
    /// the model gets, which excludes the message itself.
    mutating func send(_ text: String) -> (seq: Int, history: [ChatTurn]) {
        // The slow-reply warning hands the input back while a request is
        // still pending: a newer message supersedes the unanswered one.
        if awaiting, turns.last?.role == .human { turns.removeLast() }
        seq += 1
        let history = capTranscript(turns)
        turns.append(ChatTurn(role: .human, text: text))
        awaiting = true
        return (seq, history)
    }

    func isCurrent(_ seq: Int) -> Bool { seq == self.seq }

    /// The reply for `seq` arrived. False (and no change) if superseded.
    @discardableResult
    mutating func answered(_ seq: Int, _ text: String) -> Bool {
        guard isCurrent(seq), awaiting else { return false }
        turns.append(ChatTurn(role: .sheep, text: text))
        awaiting = false
        return true
    }

    /// The request for `seq` failed: its turn is dropped so a retry isn't
    /// doubled. False (and no change) if superseded.
    @discardableResult
    mutating func failed(_ seq: Int) -> Bool {
        guard isCurrent(seq), awaiting else { return false }
        if turns.last?.role == .human { turns.removeLast() }
        awaiting = false
        return true
    }
}

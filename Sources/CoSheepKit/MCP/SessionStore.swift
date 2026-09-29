import Foundation

// Ex-mcp.rs, the reducer half: MCP facts in, session snapshot out.

nonisolated enum Health: String, Equatable {
    case good, degraded, failing

    /// ex-`Health::as_str`.
    var asStr: String { rawValue }
}

nonisolated struct SessionState: Equatable {
    var active = false
    var task: String?
    var progress: Double?
    var health: Health = .good
}

/// What a fact-shaped MCP tool call reports (ex-`Fact`).
nonisolated enum Fact: Equatable {
    case begin(task: String?)
    case task(label: String)
    case progress(fraction: Double)
    case milestone(kind: String, detail: String?)
    case end(summary: String?)
}

/// The pure functions of mcp.rs (`clamp01`, `truncate`, `apply`, `check_auth`),
/// namespaced so their short names cannot collide with other helpers in the module.
nonisolated enum SessionReducer {
    /// ex-`clamp01`.
    static func clamp01(_ f: Double) -> Double {
        min(max(f, 0.0), 1.0)
    }

    /// ex-`truncate`: at most `max` characters, where a Rust `char` is a Unicode
    /// scalar, so this counts scalars (not grapheme clusters) and can never split
    /// one.
    static func truncate(_ s: String, _ max: Int) -> String {
        if s.unicodeScalars.count <= max { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.prefix(max)))
    }

    /// ex-`apply`: folds a fact into the state and returns the snapshot event.
    static func apply(_ state: inout SessionState, _ fact: Fact) -> SessionEvent {
        let kind: String
        var milestone: String?
        var detail: String?
        switch fact {
        case .begin(let task):
            state.active = true
            state.health = .good
            state.progress = nil
            state.task = task.map { truncate($0, 500) }
            kind = "begin"
        case .task(let label):
            state.task = truncate(label, 500)
            kind = "task"
        case .progress(let fraction):
            state.progress = clamp01(fraction)
            kind = "progress"
        case .milestone(let milestoneKind, let d):
            state.health = switch milestoneKind {
            case "failed": .failing
            case "done": .good
            default: .degraded // blocked / waiting_on_you
            }
            detail = d.map { truncate($0, 500) }
            milestone = truncate(milestoneKind, 32)
            kind = "milestone"
        case .end(let summary):
            state.active = false
            detail = summary.map { truncate($0, 500) }
            kind = "end"
        }
        return SessionEvent(
            kind: kind,
            task: state.task,
            progress: state.progress,
            milestone: milestone,
            detail: detail,
            health: state.health.asStr)
    }

    /// ex-`check_auth`. No token configured means the loopback binding is the
    /// control. Otherwise the header must be exactly `Bearer <token>`; compared in
    /// constant time since it guards a local control channel.
    static func checkAuth(_ header: String?, expected: String) -> Bool {
        if expected.isEmpty { return true }
        guard let header else { return false }
        let a = Array(header.utf8)
        let b = Array("Bearer \(expected)".utf8)
        var diff = a.count ^ b.count
        for i in 0..<Swift.max(a.count, b.count) {
            diff |= Int(i < a.count ? a[i] : 0) ^ Int(i < b.count ? b[i] : 0)
        }
        return diff == 0
    }
}

/// ex-`SessionStore(Mutex<SessionState>)` plus `SheepMcp::commit`: applies a
/// fact to the shared state and publishes the resulting `sheep-session` event.
/// Main actor only (the Rust needed a mutex because tokio threads shared it).
final class SessionStore {
    static let shared = SessionStore()

    private(set) var state: SessionState
    private let events: AppEvents

    init(state: SessionState = SessionState(), events: AppEvents = .shared) {
        self.state = state
        self.events = events
    }

    /// Apply a fact, emit the resulting `sheep-session` event, and return it.
    @discardableResult
    func commit(_ fact: Fact) -> SessionEvent {
        let event = SessionReducer.apply(&state, fact)
        events.sheepSession.emit(event)
        return event
    }
}

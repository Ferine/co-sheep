import Foundation

// The pure fold behind the agent herd: hook events, transcript updates and
// liveness sweeps go in, session state and `HerdChange`s come out. No clocks, no
// I/O, no globals: `HerdStore` owns the state and feeds it. Spec:
// docs/superpowers/specs/2026-10-03-agent-herd-design.md ("Reducer (pure)").

/// Everything the reducer folds into: the live sessions, plus the sessions that
/// just ended with `/clear` and may be about to come back under a new id.
nonisolated struct HerdState: Equatable, Sendable {
    /// A session whose `SessionEnd` said `clear`. Claude Code follows it with a
    /// `SessionStart` (source `clear`) under a new id from the same process; if
    /// that arrives in time the lamb is re-keyed instead of leaving.
    struct Cleared: Equatable, Sendable {
        /// The session as the lamb last saw it (no change was emitted for the clear).
        var session: AgentSession
        var atMs: Double

        var id: String { session.id }
        var agentPid: Int32? { session.agentPid }
        var cwd: String? { session.cwd }
    }

    var sessions: [String: AgentSession] = [:]
    var recentlyCleared: [Cleared] = []

    init(sessions: [String: AgentSession] = [:], recentlyCleared: [Cleared] = []) {
        self.sessions = sessions
        self.recentlyCleared = recentlyCleared
    }
}

nonisolated enum HerdReducer {
    /// A `SessionStart(clear)` re-keys a cleared session only this soon after it.
    static let clearWindowMs = 10_000.0
    /// No hook event and no transcript growth for this long: the session is over.
    static let silenceLimitMs = 45.0 * 60_000
    /// A `working` session this quiet is probably stuck on a missed event.
    static let staleWorkingMs = 10.0 * 60_000
    static let waitingForMax = 120
    static let lastErrorMax = 200

    /// The hook events the reducer understands. Anything else only proves the
    /// session is alive.
    private static let known: Set<String> = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PermissionDenied", "PostToolUse", "PostToolUseFailure", "Notification", "Stop",
        "StopFailure", "SubagentStart", "SubagentStop", "PreCompact",
    ]

    // MARK: Hook events

    /// Folds one hook event. Returns the changes to publish: usually one, none
    /// when the event is ignorable (an unknown event name, a `SessionEnd` for a
    /// session we never saw, an internal subagent, a `/clear` that may yet be
    /// re-keyed).
    static func apply(_ state: inout HerdState, _ event: HookEvent, nowMs: Double) -> [HerdChange] {
        let id = event.sessionId
        let name = event.hookEventName
        guard !id.isEmpty else { return [] }

        // The old id of a /clear that is waiting for its SessionStart.
        if let i = state.recentlyCleared.firstIndex(where: { $0.session.id == id }) {
            switch name {
            case "SessionStart":
                state.sessions[id] = state.recentlyCleared.remove(at: i).session // it came back: not a clear
            case "SessionEnd" where event.reason != "clear":
                return [departure(of: state.recentlyCleared.remove(at: i).session, nowMs: nowMs)]
            default:
                return [] // a late event from before the clear; the lamb is already on its way
            }
        }

        if name == "SessionStart", event.source == "clear", state.sessions[id] == nil,
           let change = rekey(&state, event, nowMs: nowMs) {
            return [change]
        }

        let existing = state.sessions[id]
        let internalSubagent = (name == "SubagentStart" || name == "SubagentStop")
            && (event.agentType ?? "").isEmpty
        if existing == nil, name == "SessionEnd" || internalSubagent || !known.contains(name) {
            return []
        }

        var s = existing ?? AgentSession(id: id, nowMs: nowMs)
        let before = existing?.phase
        fill(&s, event, nowMs: nowMs)

        if internalSubagent || !known.contains(name) {
            state.sessions[id] = s
            return []
        }

        if name == "SessionEnd" {
            if event.reason == "clear" {
                state.sessions[id] = nil
                state.recentlyCleared.append(HerdState.Cleared(session: s, atMs: nowMs))
                return []
            }
            state.sessions[id] = nil
            return [departure(of: s, nowMs: nowMs)]
        }

        let beat = fold(&s, event, nowMs: nowMs)
        state.sessions[id] = s
        return [HerdChange(session: s, previousPhase: before, beat: existing == nil ? .arrived : beat)]
    }

    /// Fills what the event knows and the session doesn't, and refreshes the
    /// liveness clock.
    private static func fill(_ s: inout AgentSession, _ e: HookEvent, nowMs: Double) {
        s.lastEventMs = nowMs
        if s.cwd == nil, let v = nonEmpty(e.cwd) { s.cwd = v }
        if s.transcriptPath == nil, let v = nonEmpty(e.transcriptPath) { s.transcriptPath = v }
        // The mode changes mid-session (plan mode, accept edits): keep the latest.
        if let v = nonEmpty(e.permissionMode) { s.permissionMode = v }
        if let pid = e.pid, pid > 0 {
            // A SessionStart under a known id is a restarted process: trust its pid.
            if s.agentPid == nil || (e.hookEventName == "SessionStart" && s.agentPid != pid) {
                s.agentPid = pid
                s.terminalPid = nil
            }
        }
    }

    /// The reducer table. Returns the beat for this event (the caller overrides
    /// it with `.arrived` for a brand-new session).
    private static func fold(_ s: inout AgentSession, _ e: HookEvent, nowMs: Double) -> HerdBeat? {
        switch e.hookEventName {
        case "SessionStart":
            // Known id: resume, compact, restart. New id: just arrived.
            setPhase(&s, .idle, nowMs: nowMs)
            setTool(&s, toolName: nil)
            return nil

        case "UserPromptSubmit":
            setPhase(&s, .working, nowMs: nowMs)
            setTool(&s, toolName: nil)
            return nil

        case "PreToolUse":
            setTool(&s, toolName: e.toolName)
            if e.agentId == nil { s.toolCalls += 1 } // a subagent's calls aren't the lamb's own
            if e.toolName == "AskUserQuestion" {
                setPhase(&s, .waiting, nowMs: nowMs)
                s.waitingFor = e.toolName
            } else {
                setPhase(&s, .working, nowMs: nowMs)
            }
            return nil

        case "PermissionRequest":
            setTool(&s, toolName: e.toolName)
            setPhase(&s, .waiting, nowMs: nowMs)
            s.waitingFor = e.toolName.map { SessionReducer.truncate($0, waitingForMax) }
            return nil

        case "Notification":
            switch e.notificationType {
            case "permission_prompt", "agent_needs_input", "elicitation_dialog":
                // PermissionRequest already named the tool; only fill a gap.
                let alreadyWaiting = s.phase == .waiting
                setPhase(&s, .waiting, nowMs: nowMs)
                if !alreadyWaiting || s.waitingFor == nil {
                    s.waitingFor = e.message.map { SessionReducer.truncate($0, waitingForMax) }
                }
            case "idle_prompt":
                setPhase(&s, .idle, nowMs: nowMs)
                s.tool = .thinking
            default:
                break
            }
            return nil

        case "PostToolUse":
            setTool(&s, toolName: e.toolName)
            setPhase(&s, .working, nowMs: nowMs)
            return nil

        case "PostToolUseFailure":
            setTool(&s, toolName: e.toolName)
            if e.isInterrupt == true {
                setPhase(&s, .idle, nowMs: nowMs)
                s.tool = .thinking
                return .interrupted
            }
            setPhase(&s, .working, nowMs: nowMs)
            s.failures += 1
            s.lastError = e.error.map { SessionReducer.truncate($0, lastErrorMax) }
            return .toolFailed

        case "PermissionDenied":
            if e.toolName != nil { setTool(&s, toolName: e.toolName) }
            setPhase(&s, .working, nowMs: nowMs)
            return .permissionDenied

        case "Stop":
            setPhase(&s, .idle, nowMs: nowMs)
            s.tool = .thinking
            s.turnsDone += 1
            return .turnDone

        case "StopFailure":
            setPhase(&s, .idle, nowMs: nowMs)
            s.tool = .thinking
            if let text = e.error ?? e.message { s.lastError = SessionReducer.truncate(text, lastErrorMax) }
            return .apiError

        case "SubagentStart":
            s.subagents += 1
            return nil

        case "SubagentStop":
            s.subagents = max(0, s.subagents - 1)
            return nil

        case "PreCompact":
            setPhase(&s, .working, nowMs: nowMs)
            s.tool = .compacting
            s.toolName = nil
            return .compacted

        default: // SessionEnd is folded in `apply`; nothing else reaches here
            return nil
        }
    }

    /// Phase change bookkeeping: `phaseSinceMs` moves only when the phase does,
    /// and `waitingFor` lives only while waiting.
    private static func setPhase(_ s: inout AgentSession, _ phase: AgentPhase, nowMs: Double) {
        if s.phase != phase {
            s.phase = phase
            s.phaseSinceMs = nowMs
        }
        if phase != .waiting { s.waitingFor = nil }
    }

    private static func setTool(_ s: inout AgentSession, toolName: String?) {
        s.toolName = toolName
        s.tool = ToolKind.classify(toolName)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    // MARK: /clear

    /// `SessionStart(clear)` for an id we don't know: if a session cleared a
    /// moment ago from the same process (or, without pids, the same directory),
    /// the lamb stays and takes the new id.
    private static func rekey(_ state: inout HerdState, _ e: HookEvent, nowMs: Double) -> HerdChange? {
        func matches(_ c: HerdState.Cleared) -> Bool {
            guard nowMs - c.atMs <= clearWindowMs else { return false }
            if let a = c.agentPid, let b = e.pid, b > 0 { return a == b }
            if let a = c.cwd, let b = e.cwd { return a == b }
            return false
        }
        let candidates = state.recentlyCleared.enumerated().filter { matches($0.element) }
        guard let pick = candidates.max(by: { $0.element.atMs < $1.element.atMs }) else { return nil }

        var s = state.recentlyCleared.remove(at: pick.offset).session
        let oldId = s.id
        let previous = s.phase
        s.id = e.sessionId
        // A fresh conversation in the same lamb (startedMs stays: same lamb, same place in the herd).
        s.tokens = 0
        s.title = nil
        s.toolCalls = 0
        s.turnsDone = 0
        s.failures = 0
        s.subagents = 0
        s.lastError = nil
        s.transcriptPath = nonEmpty(e.transcriptPath) // the old file isn't this conversation's
        fill(&s, e, nowMs: nowMs)
        s.phase = .idle
        s.phaseSinceMs = nowMs
        setTool(&s, toolName: nil)
        s.waitingFor = nil
        state.sessions[s.id] = s
        return HerdChange(session: s, previousPhase: previous, beat: .cleared, previousId: oldId)
    }

    private static func departure(of session: AgentSession, nowMs: Double) -> HerdChange {
        var s = session
        let previous = s.phase
        s.phase = .ended
        s.phaseSinceMs = nowMs
        s.waitingFor = nil
        return HerdChange(session: s, previousPhase: previous, beat: .departed)
    }

    // MARK: Liveness

    /// The periodic check, in this order per session: the agent process is gone,
    /// or nothing (hook event, transcript growth) for 45 min: ended. `working`
    /// and silent for 10 min: idle. Then cleared sessions whose `SessionStart`
    /// never came leave. Ended sessions are removed after their change.
    static func sweep(
        _ state: inout HerdState,
        nowMs: Double,
        isAlive: (Int32) -> Bool,
        transcriptActivityMs: (String) -> Double?
    ) -> [HerdChange] {
        var changes: [HerdChange] = []

        let ordered = state.sessions.values.sorted { ($0.startedMs, $0.id) < ($1.startedMs, $1.id) }
        for original in ordered {
            var s = original
            let silentMs = nowMs - max(s.lastEventMs, transcriptActivityMs(s.id) ?? 0)
            let processGone = s.agentPid.map { !isAlive($0) } ?? false
            if processGone || silentMs >= silenceLimitMs {
                state.sessions[s.id] = nil
                changes.append(departure(of: s, nowMs: nowMs))
            } else if s.phase == .working, silentMs >= staleWorkingMs {
                setPhase(&s, .idle, nowMs: nowMs)
                s.tool = .thinking
                state.sessions[s.id] = s
                changes.append(HerdChange(session: s, previousPhase: .working, beat: nil))
            }
        }

        let expired = state.recentlyCleared.filter { nowMs - $0.atMs > clearWindowMs }
        if !expired.isEmpty {
            state.recentlyCleared.removeAll { nowMs - $0.atMs > clearWindowMs }
            for c in expired { changes.append(departure(of: c.session, nowMs: nowMs)) }
        }
        return changes
    }

    // MARK: Transcript

    /// Folds what the tailer read: tokens add up, the title is set, and an
    /// interrupt (which fires no hook) returns a working or waiting lamb to idle.
    /// Does not touch `lastEventMs`: transcript growth is reported to `sweep`
    /// separately. Returns nil when nothing changed or the session is unknown.
    static func applyTranscript(
        _ state: inout HerdState, sessionId: String, update: TranscriptUpdate, nowMs: Double
    ) -> HerdChange? {
        guard var s = state.sessions[sessionId] else { return nil }
        let before = s
        let previous = s.phase

        if update.tokensDelta > 0 { s.tokens += update.tokensDelta }
        if let title = update.title, !title.isEmpty { s.title = title }

        var beat: HerdBeat?
        if update.interrupted, s.phase == .working || s.phase == .waiting {
            setPhase(&s, .idle, nowMs: nowMs)
            s.tool = .thinking
            beat = .interrupted
        }

        guard s != before else { return nil }
        state.sessions[sessionId] = s
        return HerdChange(session: s, previousPhase: previous, beat: beat)
    }
}

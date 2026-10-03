import Foundation

// The single owner of the herd's `HerdState`. Hook events arrive through
// `ingest` (from the `/hook` route), transcripts are tailed every 2 s, and a
// sweep every 10 s retires sessions whose process is gone or that went quiet.
// Every fold is published on `AppEvents.herd` for the lambs. Spec:
// docs/superpowers/specs/2026-10-03-agent-herd-design.md.

final class HerdStore {
    static let shared = HerdStore()

    static let transcriptIntervalSeconds = 2.0
    static let sweepIntervalSeconds = 10.0

    /// A session's transcript being followed.
    private struct Tail {
        var path: String
        var cursor = TranscriptCursor()
        /// A read has returned bytes: later reads are live, not history.
        var hasRead = false
        /// Tells a poll that the tail it started with was replaced while it awaited.
        var serial: Int
    }

    private let events: AppEvents
    private let now: () -> Double
    private let isAlive: (Int32) -> Bool
    private let readTranscript: TranscriptReader
    private let findTerminal: (Int32) -> Int32?
    private let findRepo: (String) -> (key: String, name: String)
    private let acceptsTranscript: (_ path: String, _ sessionId: String) -> Bool
    private let transcriptInterval: Double
    private let sweepInterval: Double

    private(set) var state = HerdState()
    private var tails: [String: Tail] = [:]
    private var nextTailSerial = 0
    /// When each session's transcript last grew (the sweep counts it as activity).
    private var transcriptGrowthMs: [String: Double] = [:]
    private var repoCache: [String: (key: String, name: String)] = [:]
    private var terminalCache: [Int32: Int32] = [:]
    private var terminalMisses: Set<Int32> = []

    private var transcriptLoop: Task<Void, Never>?
    private var sweepLoop: Task<Void, Never>?

    /// - Parameters:
    ///   - now: epoch milliseconds.
    ///   - isAlive: whether a process exists (`kill(pid, 0)`).
    ///   - readTranscript: reads new transcript bytes off the main actor.
    ///   - findTerminal: the terminal app hosting an agent pid (looked up once per pid).
    ///   - findRepo: the repo identity for a cwd (looked up once per cwd).
    ///   - acceptsTranscript: whether a payload's `transcript_path` may be tailed.
    init(
        events: AppEvents = .shared,
        now: @escaping () -> Double = { SimClock.nowMs() },
        isAlive: @escaping (Int32) -> Bool = { ProcessTree.isAlive($0) },
        readTranscript: @escaping TranscriptReader = { path, cursor, nowMs in
            await TranscriptTailer.read(path: path, cursor: cursor, nowMs: nowMs)
        },
        findTerminal: @escaping (Int32) -> Int32? = { TerminalFocus.terminalPid(forAgentPid: $0) },
        findRepo: @escaping (String) -> (key: String, name: String) = { RepoIdentity.resolve(cwd: $0) },
        acceptsTranscript: @escaping (_ path: String, _ sessionId: String) -> Bool = {
            TranscriptTailer.isTranscriptPath($0, sessionId: $1)
        },
        transcriptInterval: Double = HerdStore.transcriptIntervalSeconds,
        sweepInterval: Double = HerdStore.sweepIntervalSeconds
    ) {
        self.events = events
        self.now = now
        self.isAlive = isAlive
        self.readTranscript = readTranscript
        self.findTerminal = findTerminal
        self.findRepo = findRepo
        self.acceptsTranscript = acceptsTranscript
        self.transcriptInterval = transcriptInterval
        self.sweepInterval = sweepInterval
    }

    /// Live sessions, oldest first.
    var sessions: [AgentSession] {
        state.sessions.values.sorted { ($0.startedMs, $0.id) < ($1.startedMs, $1.id) }
    }

    var isRunning: Bool { transcriptLoop != nil }

    // MARK: Hooks

    /// Folds one hook event and publishes what changed.
    func ingest(_ event: HookEvent) {
        publish(HerdReducer.apply(&state, event, nowMs: now()))
    }

    // MARK: Loops

    /// Starts the transcript poll (2 s) and the liveness sweep (10 s). Starting
    /// twice is a no-op.
    func start() {
        guard transcriptLoop == nil else { return }
        transcriptLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.transcriptInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self?.pollTranscripts()
            }
        }
        sweepLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.sweepInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                self?.sweep()
            }
        }
        Log.info("herd", "watching Claude Code sessions")
    }

    func stop() {
        transcriptLoop?.cancel()
        transcriptLoop = nil
        sweepLoop?.cancel()
        sweepLoop = nil
    }

    /// One liveness pass: dead or silent sessions leave, quiet `working` ones
    /// go idle, unclaimed `/clear`s depart.
    func sweep() {
        let growth = transcriptGrowthMs
        let changes = HerdReducer.sweep(
            &state, nowMs: now(), isAlive: isAlive, transcriptActivityMs: { growth[$0] })
        publish(changes)
    }

    /// One transcript pass: read what each live session's file gained since the
    /// last pass (off the main actor) and fold it in.
    func pollTranscripts() async {
        let targets = tails
            .filter { state.sessions[$0.key] != nil }
            .sorted { $0.key < $1.key }
        for (id, tail) in targets {
            let result = await readTranscript(tail.path, tail.cursor, now())
            // The session may have ended, re-keyed or changed file while we read.
            guard var current = tails[id], current.serial == tail.serial else { continue }
            current.cursor = result.cursor
            let isHistory = !current.hasRead
            if result.update != nil { current.hasRead = true }
            tails[id] = current

            guard var update = result.update else { continue }
            if let grew = update.grewAtMs { transcriptGrowthMs[id] = grew }
            // The first read replays the whole file: an interrupt in it is old news.
            if isHistory { update.interrupted = false }
            if let change = HerdReducer.applyTranscript(&state, sessionId: id, update: update, nowMs: now()) {
                publish([change])
            }
        }
    }

    // MARK: Publishing

    private func publish(_ changes: [HerdChange]) {
        for var change in changes {
            enrich(&change)
            followTranscript(of: change)
            log(change)
            events.herd.emit(change)
        }
    }

    /// Repo identity (per cwd) and terminal app (per agent pid), resolved once
    /// and written into both the state and the change.
    private func enrich(_ change: inout HerdChange) {
        var s = change.session
        var touched = false

        if s.repoKey == nil, let cwd = s.cwd, !cwd.isEmpty {
            let repo = repoCache[cwd] ?? findRepo(cwd)
            repoCache[cwd] = repo
            s.repoKey = repo.key
            s.repoName = repo.name
            touched = true
        }
        if s.terminalPid == nil, let agentPid = s.agentPid {
            if let cached = terminalCache[agentPid] {
                s.terminalPid = cached
                touched = true
            } else if !terminalMisses.contains(agentPid) {
                if let found = findTerminal(agentPid) {
                    terminalCache[agentPid] = found
                    s.terminalPid = found
                    touched = true
                } else {
                    terminalMisses.insert(agentPid)
                }
            }
        }

        guard touched else { return }
        change.session = s
        if state.sessions[s.id] != nil { state.sessions[s.id] = s }
    }

    /// Keeps `tails` in step with the session: new transcript path, re-key, end.
    private func followTranscript(of change: HerdChange) {
        let s = change.session
        if let oldId = change.previousId {
            tails[oldId] = nil
            transcriptGrowthMs[oldId] = nil
        }
        if s.phase == .ended {
            tails[s.id] = nil
            transcriptGrowthMs[s.id] = nil
            return
        }
        if let path = s.transcriptPath, tails[s.id]?.path != path, acceptsTranscript(path, s.id) {
            nextTailSerial += 1
            tails[s.id] = Tail(path: path, serial: nextTailSerial)
        }
    }

    private func log(_ change: HerdChange) {
        let s = change.session
        let who = "\(s.displayName) [\(s.id.prefix(8))]"
        switch change.beat {
        case .arrived?:
            Log.info("herd", "lamb arrived: \(who)\(s.agentPid.map { " pid \($0)" } ?? "")")
        case .cleared?:
            Log.info("herd", "lamb cleared: \(who) (was \(change.previousId.map { String($0.prefix(8)) } ?? "?"))")
        case .departed?:
            let minutes = Int(max(0, now() - s.startedMs) / 60_000)
            Log.info("herd", "lamb departed: \(who) after \(minutes)m, \(s.tokens) tokens")
        default:
            break
        }
    }
}

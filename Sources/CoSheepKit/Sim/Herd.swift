import Foundation

// The agent herd: every running Claude Code session is a lamb on the desktop.
// `Herd` is owned by `Flock`. It consumes `HerdChange` values (published on
// `AppEvents.herd` by HerdStore), spawns / re-keys / retires `AgentLamb`s,
// enforces the lamb cap, and draws and hit-tests them. It never produces
// changes. Spec: docs/superpowers/specs/2026-10-03-agent-herd-design.md.
//
// Lambs are sheep for the physical world (drag, stack, trampoline, stampede,
// window platforms) but stay out of every friend system: they have no
// personality, memory, conversations, gossip, drama or spectacles.

final class Herd {
    static let DEFAULT_MAX_LAMBS = 8
    static let DEMO_PREFIX = "demo-"

    // MARK: State

    /// Insertion order = draw order (the newest lamb is on top).
    private(set) var lambs: [AgentLamb] = []
    /// Live sessions with no lamb: over the cap, or the herd is switched off.
    /// Promoted (oldest first) when a slot frees up.
    private(set) var overflow: [String: AgentSession] = [:]
    /// Lambs on screen at once. Lowering it retires the newest lambs into
    /// `overflow`; raising it promotes sessions back.
    var maxLambs: Int = Herd.DEFAULT_MAX_LAMBS {
        didSet { if oldValue != maxLambs { rebalance() } }
    }
    /// Off: every lamb trots away quietly (no bubbles) and sessions are only
    /// tracked. On again: they parachute back in.
    var isEnabled = true {
        didSet { if oldValue != isEnabled { rebalance() } }
    }
    private(set) var hovered: AgentLamb?
    private(set) var screenWidth: Double
    private(set) var screenHeight: Double
    private(set) var platforms: [WindowPlatform] = []

    // MARK: Seams (wired by the integrator, deliberately left nil here)

    /// Bring the lamb's terminal app to the front.
    var focusTerminal: ((AgentSession) -> Void)?
    /// Called after every applied change (for the shepherd's commentary).
    var onChange: ((HerdChange) -> Void)?
    /// Flock hands each new lamb's sheep its seasonal overlay.
    var configureSheep: ((Sheep) -> Void)?

    private var unlisten: (() -> Void)?

    // Demo
    private var demoTimers: [TimerToken] = []
    private var demoSessions: [String: AgentSession] = [:]

    init(_ screenWidth: Double, _ screenHeight: Double) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    isolated deinit {
        unlisten?()
        demoTimers.forEach { $0.cancel() }
    }

    // MARK: Lifecycle

    /// Subscribe to `events.herd`.
    func start(events: AppEvents = .shared) {
        stop()
        unlisten = events.herd.on { [weak self] change in self?.apply(change) }
    }

    func stop() {
        unlisten?()
        unlisten = nil
    }

    // MARK: Queries

    /// Live sessions, lambs first (insertion order), then the overflow
    /// (oldest first). Departing lambs are on their way out and not listed.
    var sessions: [AgentSession] {
        lambs.filter { !$0.isDeparting }.map(\.session) + overflowInOrder
    }

    private var overflowInOrder: [AgentSession] {
        overflow.values.sorted { ($0.startedMs, $0.id) < ($1.startedMs, $1.id) }
    }

    /// Lambs that count against the cap (not already trotting off).
    var activeLambs: [AgentLamb] { lambs.filter { !$0.isDeparting } }

    func lamb(for sheep: Sheep) -> AgentLamb? {
        lambs.first { $0.sheep === sheep }
    }

    func lamb(id: String) -> AgentLamb? {
        activeLamb(id)
    }

    private func activeLamb(_ id: String) -> AgentLamb? {
        lambs.first { $0.id == id && !$0.isDeparting }
    }

    /// Topmost lamb under the point (the newest is drawn last, so it wins).
    func hitTest(_ px: Double, _ py: Double) -> AgentLamb? {
        for lamb in lambs.reversed() where !lamb.isDeparting {
            if lamb.sheep.hitTest(px, py) { return lamb }
        }
        return nil
    }

    func setHover(_ sheep: Sheep?) {
        hovered = sheep.flatMap { lamb(for: $0) }
    }

    /// The sheep a dropped sheep can stack on, topmost first.
    var stackTargets: [Sheep] {
        activeLambs.reversed().map(\.sheep)
    }

    /// Click-through bounds, like the other characters'.
    var bounds: [FlockBounds] {
        let pad: Double = 12
        return activeLambs.map { lamb in
            let s = lamb.sheep
            return FlockBounds(x: s.x - pad, y: s.y - pad, w: s.displaySize + pad * 2, h: s.displaySize + pad * 2)
        }
    }

    // MARK: Screen

    func updateScreenSize(_ w: Double, _ h: Double) {
        screenWidth = w
        screenHeight = h
        for lamb in lambs {
            lamb.sheep.screenWidth = w
            lamb.sheep.screenHeight = h
            lamb.sheep.reground()
        }
    }

    func setWindowPlatforms(_ platforms: [WindowPlatform]) {
        self.platforms = platforms
        for lamb in lambs { lamb.sheep.platforms = platforms }
    }

    // MARK: Changes

    /// The entry point: `AppEvents.herd`, tests and the demo all come here.
    func apply(_ change: HerdChange) {
        ingest(change)
        onChange?(change)
    }

    private func ingest(_ change: HerdChange) {
        let session = change.session

        // /clear re-keys an existing session: the lamb stays, sheared.
        if let previous = change.previousId, previous != session.id {
            if let lamb = activeLamb(previous) {
                lamb.apply(change)
                relabel()
                promoteOverflow()
                return
            }
            if overflow[previous] != nil {
                overflow[previous] = nil
                overflow[session.id] = session.phase == .ended ? nil : session
                promoteOverflow()
                return
            }
        }

        if let lamb = activeLamb(session.id) {
            lamb.apply(change)
            relabel()
        } else if overflow[session.id] != nil {
            overflow[session.id] = session.phase == .ended ? nil : session
        } else if session.phase != .ended {
            if isEnabled && activeLambs.count < maxLambs {
                spawn(session, announce: change.beat == .arrived)
            } else {
                overflow[session.id] = session
            }
        }
        promoteOverflow()
    }

    private func spawn(_ session: AgentSession, announce: Bool) {
        // Draw-tile keys come from the sheep id, so it must be unique even
        // while an earlier lamb of the same session is still trotting off.
        var sheepId = "lamb:\(session.id)"
        var suffix = 1
        while lambs.contains(where: { $0.sheep.id == sheepId }) {
            suffix += 1
            sheepId = "lamb:\(session.id)~\(suffix)"
        }
        let lamb = AgentLamb(session: session, screenWidth: screenWidth, screenHeight: screenHeight,
                             startX: pickStartX(), platforms: platforms, sheepId: sheepId)
        configureSheep?(lamb.sheep)
        lambs.append(lamb)
        relabel()
        lamb.arrive(announce: announce)
        Log.info("herd", "lamb \(lamb.sheep.name) arrived (\(session.id.prefix(8)))")
    }

    /// A parachute landing spot away from the other lambs: the best of a few
    /// random candidates.
    private func pickStartX() -> Double {
        let ds = (Sheep.DISPLAY_SIZE * AgentLamb.SCALE).rounded()
        let lo = ds * 0.3
        let hi = max(lo + 1, screenWidth - ds * 1.3)
        var best = lo
        var bestGap = -Double.infinity
        for _ in 0..<4 {
            let x = lo + SimRandom.next() * (hi - lo)
            let gap = lambs.filter { !$0.isDeparting }.map { abs($0.sheep.x - x) }.min() ?? .infinity
            if gap > bestGap { bestGap = gap; best = x }
        }
        return best
    }

    private func promoteOverflow() {
        guard isEnabled else { return }
        while activeLambs.count < maxLambs, let next = overflowInOrder.first {
            overflow[next.id] = nil
            spawn(next, announce: true)
        }
    }

    /// Cap or switch changed: retire the surplus, promote what fits.
    private func rebalance() {
        if !isEnabled {
            for lamb in activeLambs { demote(lamb) }
            return
        }
        let active = activeLambs
        if active.count > maxLambs {
            for lamb in active.dropFirst(max(0, maxLambs)) { demote(lamb) }
        }
        promoteOverflow()
    }

    /// The session keeps living in `overflow`; its lamb trots off quietly.
    private func demote(_ lamb: AgentLamb) {
        overflow[lamb.id] = lamb.session
        lamb.depart(sheared: false)
        if hovered === lamb { hovered = nil }
        relabel()
    }

    /// " #2", " #3" for lambs sharing a repo; ordinals are stable while a
    /// lamb lives, new lambs take the smallest free one.
    private func relabel() {
        var groups: [String: [AgentLamb]] = [:]
        for lamb in lambs where !lamb.isDeparting {
            groups[lamb.session.displayName, default: []].append(lamb)
        }
        for (name, group) in groups {
            var taken = Set<Int>()
            var fresh: [AgentLamb] = []
            for lamb in group {
                if lamb.labelBase == name, !taken.contains(lamb.ordinal) {
                    taken.insert(lamb.ordinal)
                } else {
                    fresh.append(lamb)
                }
            }
            for lamb in fresh {
                var n = 1
                while taken.contains(n) { n += 1 }
                taken.insert(n)
                lamb.setLabel(ordinal: n, shared: group.count > 1)
            }
            for lamb in group where !fresh.contains(where: { $0 === lamb }) {
                lamb.setLabel(ordinal: lamb.ordinal, shared: group.count > 1)
            }
        }
    }

    // MARK: Update

    func update(_ dt: Double) {
        for lamb in lambs { lamb.update(dt) }
        let gone = lambs.filter(\.isGone)
        if !gone.isEmpty {
            for lamb in gone {
                if hovered === lamb { hovered = nil }
                lamb.teardown()
            }
            lambs.removeAll { lamb in gone.contains { $0 === lamb } }
            relabel()
        }
        promoteOverflow()
    }

    // MARK: Interaction

    /// A click on a lamb: bring its terminal forward, happy bounce.
    func clicked(_ lamb: AgentLamb) {
        focusTerminal?(lamb.session)
        lamb.sheep.resetActivity()
        lamb.sheep.playAnimation(.bounce)
    }

    /// Petting a lamb: a lamb line, nothing recorded about it anywhere.
    func petted(_ lamb: AgentLamb) {
        lamb.pettedLine()
    }

    /// The mouse was shaken: every lamb that isn't leaving scatters.
    func stampede(_ mouseX: Double) {
        for lamb in activeLambs { lamb.sheep.startStampede(mouseX) }
    }

    /// Someone started trampolining: up to `limit` calm lambs cheer.
    /// Returns how many will.
    @discardableResult
    func reactToTrampoline(of sheep: Sheep, limit: Int) -> Int {
        var count = 0
        for lamb in activeLambs {
            if count >= limit { break }
            if lamb.sheep === sheep || !lamb.isCalm || lamb.bubble.visible { continue }
            lamb.reactToTrampoline()
            count += 1
        }
        return count
    }

    // MARK: Draw

    /// World layer: each lamb in its own anchored tile, flying wool in a
    /// separate one. Called after the friends.
    func draw(_ ctx: Canvas) {
        for lamb in lambs {
            let s = lamb.sheep
            // `sheep.id` is already "lamb:<session id>" and stays put when
            // /clear re-keys the session, so the tile survives it.
            ctx.group(s.id, anchor: CGPoint(x: s.x, y: s.y)) { s.draw(ctx) }
            if !lamb.particles.isEmpty {
                ctx.group("\(s.id):fx") { lamb.drawParticles(ctx) }
            }
        }
    }

    /// Overlay layer: speech bubbles, then the hover card on top.
    func drawOverlay(_ ctx: Canvas) {
        for lamb in lambs where lamb.bubble.visible {
            ctx.group("bubble:\(lamb.sheep.id)", layer: .overlay, anchor: Flock.bubbleAnchor(lamb.bubble)) {
                lamb.bubble.draw(ctx)
            }
        }
        if let lamb = hovered, !lamb.isDeparting {
            let s = lamb.sheep
            let lift = lamb.bubble.visible ? lamb.bubble.layout.height + 18 + AgentLamb.BUBBLE_LIFT : AgentLamb.BUBBLE_LIFT
            ctx.group("\(s.id):card", layer: .overlay, anchor: CGPoint(x: s.x, y: s.y)) {
                lamb.drawCard(ctx, screenWidth: screenWidth, lift: lift)
            }
        }
    }

    // MARK: Demo (herd:demo)

    private struct DemoLamb {
        var repo: String
        var phase: AgentPhase
        var tool: ToolKind
        var tokens: Int
        var toolCalls: Int
        var subagents: Int
        var minutes: Double
        var title: String?
        var tools: [ToolKind]
    }

    private static let demoLambs: [DemoLamb] = [
        DemoLamb(repo: "co-sheep", phase: .working, tool: .edit, tokens: 300_000, toolCalls: 37, subagents: 0,
                 minutes: 14, title: "Wire up the agent herd", tools: [.edit, .read, .bash, .plan, .thinking]),
        DemoLamb(repo: "neas-scripts", phase: .working, tool: .bash, tokens: 3_000_000, toolCalls: 212, subagents: 0,
                 minutes: 63, title: "Fix the OSPF template", tools: [.bash, .read, .edit, .other]),
        DemoLamb(repo: "junos-lab", phase: .waiting, tool: .bash, tokens: 450_000, toolCalls: 58, subagents: 0,
                 minutes: 22, title: nil, tools: [.bash]),
        DemoLamb(repo: "docs-site", phase: .idle, tool: .thinking, tokens: 20_000_000, toolCalls: 540, subagents: 0,
                 minutes: 190, title: "Rewrite the whole handbook", tools: [.thinking]),
        DemoLamb(repo: "scratch", phase: .working, tool: .web, tokens: 120_000, toolCalls: 9, subagents: 2,
                 minutes: 4, title: "Research optics vendors", tools: [.web, .mcp, .subagent, .read]),
    ]

    private static func toolName(_ kind: ToolKind) -> String? {
        switch kind {
        case .thinking, .compacting: nil
        case .edit: "Edit"
        case .bash: "Bash"
        case .read: "Read"
        case .web: "WebFetch"
        case .subagent: "Task"
        case .plan: "TodoWrite"
        case .mcp: "mcp__github__search"
        case .ask: "AskUserQuestion"
        case .other: "Skill"
        }
    }

    /// `herd:demo`: five fake sessions through `apply`, then a little life:
    /// the working lambs change tools every 6 s (and swell), one finishes a
    /// turn, and after ~40 s one is sheared and leaves.
    func startDemo() {
        clearDemo()
        let now = SimClock.nowMs()
        for (i, def) in Self.demoLambs.enumerated() {
            let id = "\(Self.DEMO_PREFIX)\(i + 1)"
            var s = AgentSession(id: id, nowMs: now - def.minutes * 60_000)
            s.cwd = "/demo/\(def.repo)"
            s.repoKey = "/demo/\(def.repo)"
            s.repoName = def.repo
            s.phase = def.phase
            s.tool = def.tool
            s.toolName = Self.toolName(def.tool)
            s.waitingFor = def.phase == .waiting ? Self.toolName(def.tool) : nil
            s.tokens = def.tokens
            s.toolCalls = def.toolCalls
            s.subagents = def.subagents
            s.title = def.title
            s.lastEventMs = now
            demoSessions[id] = s
            apply(HerdChange(session: s, previousPhase: nil, beat: .arrived, previousId: nil))
        }

        var tick = 0
        demoTimers.append(SimTimers.every(6000) { [weak self] in
            guard let self else { return }
            tick += 1
            for (i, def) in Self.demoLambs.enumerated() {
                let id = "\(Self.DEMO_PREFIX)\(i + 1)"
                guard var s = self.demoSessions[id], s.phase == .working, def.tools.count > 1 else { continue }
                let previous = s.phase
                s.tool = def.tools[(tick + i) % def.tools.count]
                s.toolName = Self.toolName(s.tool)
                s.toolCalls += 1
                s.tokens += def.tokens / 5 + 20_000
                self.demoSessions[id] = s
                self.apply(HerdChange(session: s, previousPhase: previous, beat: nil, previousId: nil))
            }
        })
        demoTimers.append(SimTimers.after(18_000) { [weak self] in
            self?.demoTurnDone("\(Self.DEMO_PREFIX)2")
        })
        demoTimers.append(SimTimers.after(26_000) { [weak self] in
            self?.demoResume("\(Self.DEMO_PREFIX)2", tool: .bash)
        })
        demoTimers.append(SimTimers.after(40_000) { [weak self] in
            self?.demoDepart("\(Self.DEMO_PREFIX)5")
        })
    }

    private func demoTurnDone(_ id: String) {
        guard var s = demoSessions[id] else { return }
        let previous = s.phase
        s.phase = .idle
        s.tool = .thinking
        s.toolName = nil
        s.turnsDone += 1
        demoSessions[id] = s
        apply(HerdChange(session: s, previousPhase: previous, beat: .turnDone, previousId: nil))
    }

    private func demoResume(_ id: String, tool: ToolKind) {
        guard var s = demoSessions[id], s.phase == .idle else { return }
        s.phase = .working
        s.tool = tool
        s.toolName = Self.toolName(tool)
        demoSessions[id] = s
        apply(HerdChange(session: s, previousPhase: .idle, beat: nil, previousId: nil))
    }

    private func demoDepart(_ id: String) {
        guard var s = demoSessions[id], s.phase != .ended else { return }
        let previous = s.phase
        s.phase = .ended
        demoSessions[id] = s
        apply(HerdChange(session: s, previousPhase: previous, beat: .departed, previousId: nil))
    }

    /// `herd:clear-demo`: every demo lamb is sheared and trots off.
    func clearDemo() {
        demoTimers.forEach { $0.cancel() }
        demoTimers.removeAll()
        for id in demoSessions.keys.sorted() { demoDepart(id) }
        demoSessions.removeAll()
        for id in Array(overflow.keys) where id.hasPrefix(Self.DEMO_PREFIX) { overflow[id] = nil }
    }
}

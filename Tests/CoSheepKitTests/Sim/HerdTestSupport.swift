import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

// Shared fixtures for the agent-herd suites: a world that points the
// process-wide globals (Paths.root, clock, randomness, bubble viewport) at
// throwaway values, and small builders for sessions and changes.

let herdW = 1512.0
let herdH = 982.0

/// Local wall-clock epoch ms on 2026-09-29 (no season theme is active then).
func herdNowMs(hour: Int = 12) -> Double {
    Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: hour))!
        .timeIntervalSince1970 * 1000
}

/// Swaps the globals the sim touches for the length of a synchronous test:
/// `Paths.root` (a temp dir, so nothing near `~/.co-sheep`), the clock, the
/// random source and the bubble viewport.
final class HerdWorld {
    let root: URL
    let nowMs: Double
    /// While set, every `SimRandom.next()` returns this (0 passes every
    /// `< p` gate; 0.99 misses them).
    var forced: Double?
    private var saved: (root: URL, now: () -> Double, random: () -> Double, viewport: ScreenSize)?

    init(seed: UInt64 = 1, hour: Int = 12) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("co-sheep-herd-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        nowMs = herdNowMs(hour: hour)
        let seeded = SimRandom.seeded(seed)
        saved = (Paths.root, SimClock.nowSource, SimRandom.source, SpeechBubble.viewport)
        Paths.root = root
        let now = nowMs
        SimClock.nowSource = { now }
        SimRandom.source = { [unowned self] in self.forced ?? seeded() }
        FriendMemory.resetCache()
        // No spectacle may fire during a test.
        LivingState.saveState("spectacles", .object([
            "lastFiredMs": .number(now + 1e12),
            "lastByType": .object([:]),
        ]))
    }

    func close() {
        if let saved {
            Paths.root = saved.root
            SimClock.nowSource = saved.now
            SimRandom.source = saved.random
            SpeechBubble.viewport = saved.viewport
            FriendMemory.resetCache()
        }
        saved = nil
        try? FileManager.default.removeItem(at: root)
    }
}

@discardableResult
func withHerdWorld<T>(seed: UInt64 = 1, hour: Int = 12, _ body: (HerdWorld) throws -> T) rethrows -> T {
    let world = HerdWorld(seed: seed, hour: hour)
    defer { world.close() }
    return try body(world)
}

func lambSession(_ id: String = "s1", repo: String? = "co-sheep", phase: AgentPhase = .idle,
                 tool: ToolKind = .thinking, tokens: Int = 0, subagents: Int = 0,
                 toolName: String? = nil, waitingFor: String? = nil) -> AgentSession {
    var s = AgentSession(id: id, nowMs: SimClock.nowMs() - 14 * 60_000)
    if let repo {
        s.cwd = "/demo/\(repo)"
        s.repoKey = "/demo/\(repo)"
        s.repoName = repo
    }
    s.phase = phase
    s.tool = tool
    s.toolName = toolName
    s.waitingFor = waitingFor
    s.tokens = tokens
    s.subagents = subagents
    s.toolCalls = 37
    return s
}

func herdChange(_ s: AgentSession, from previous: AgentPhase? = nil, beat: HerdBeat? = nil,
                previousId: String? = nil) -> HerdChange {
    HerdChange(session: s, previousPhase: previous, beat: beat, previousId: previousId)
}

/// Step `herd` in 16 ms frames for about `ms` of sim time.
func run(_ herd: Herd, ms: Double, frame: Double = 16) {
    var t = 0.0
    while t < ms {
        herd.update(frame)
        t += frame
    }
}

func run(_ flock: Flock, ms: Double, frame: Double = 16) {
    var t = 0.0
    while t < ms {
        flock.update(frame)
        t += frame
    }
}

/// Step until no lamb is parachuting any more.
func land(_ herd: Herd, maxMs: Double = 30_000) {
    var t = 0.0
    while t < maxMs, herd.lambs.contains(where: { $0.sheep.state == .parachute }) {
        herd.update(16)
        t += 16
    }
}

/// A landed lamb in `herd` for the session (applied as an arrival).
@discardableResult
func landedLamb(_ herd: Herd, _ s: AgentSession) -> AgentLamb {
    herd.apply(herdChange(s, beat: .arrived))
    land(herd)
    return herd.lamb(id: s.id)!
}

/// Park a sheep: standing calm on the ground at `x`, for good.
func stand(_ sheep: Sheep, x: Double? = nil) {
    if let x { sheep.x = x }
    sheep.y = sheep.groundY
    sheep.state = .idle
    sheep.stateTimer = 0
    sheep.stateDuration = 1e12
}

func stand(_ lamb: AgentLamb, x: Double? = nil) {
    stand(lamb.sheep, x: x)
}

/// Display-list size of the lamb's sheep (sprite + overlay), optionally
/// without the lamb overlay (the bare sprite).
func opCount(_ lamb: AgentLamb, overlay: Bool = true) -> Int {
    let saved = lamb.sheep.drawOverlay
    if !overlay { lamb.sheep.drawOverlay = nil }
    defer { lamb.sheep.drawOverlay = saved }
    let c = Canvas()
    c.beginFrame()
    c.group("x") { lamb.sheep.draw(c) }
    return c.groups.first?.ops.count ?? 0
}

/// The ops of the lamb drawn in an anchored group, like `Herd.draw` does.
func lambOps(_ lamb: AgentLamb) -> [DrawOp] {
    let c = Canvas()
    c.beginFrame()
    c.group("x", anchor: CGPoint(x: lamb.sheep.x, y: lamb.sheep.y)) { lamb.sheep.draw(c) }
    return c.groups.first?.ops ?? []
}

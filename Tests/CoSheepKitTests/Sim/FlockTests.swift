import CoreGraphics
import Foundation
import SpriteKit
import Testing
@testable import CoSheepKit

// No TS tests exist for flock.ts: these pin the ported behavior and run the
// whole flock headless (no scene, no run loop) against a virtual clock.

private let W = 1512.0
private let H = 982.0
private let DS = 96.0

/// Local wall-clock epoch ms on 2026-09-29 (no season theme is active then).
private func localMs(hour: Int, minute: Int = 0) -> Double {
    Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: hour, minute: minute))!
        .timeIntervalSince1970 * 1000
}

/// Everything the flock touches globally, swapped for the length of a test:
/// `Paths.root` (a temp dir), the virtual clock, the random source, the bubble
/// viewport and the friend-brain cache.
///
/// Tests run one at a time on the main actor and never interleave — except at
/// an `await`, where another test may run. So a synchronous test holds the
/// world for its whole body (`withWorld`), and an async test only enters it
/// around its synchronous stretches (`inWorld`) and never across an `await`,
/// so worlds always nest strictly and restore what they found.
///
/// (Run-loop spinning in `pump` services timers only: the main dispatch queue
/// is busy running the test itself, so no other test can start inside it.)
private final class World {
    let root: URL
    /// Virtual `Date.now()` in epoch ms; `step` advances it.
    var now: Double
    /// While set, every `SimRandom.next()` returns this (to force the rare
    /// probability rolls: 0 passes every `Math.random() < p` gate).
    var forcedRandom: Double?
    /// Rolls handed out first (in order) before falling back to `scriptTail`
    /// (if set) or the seeded stream.
    var script: [Double] = []
    var scriptTail: Double?
    /// The sim can't fire `SimTimers` (they're real timers), so bubbles never
    /// hide by themselves; this hides each one after this many virtual ms.
    var autoHideMs: Double? = 3500

    private var saved: (root: URL, now: () -> Double, random: () -> Double, viewport: ScreenSize)?
    private var clock: (() -> Double)?
    private var random: (() -> Double)?
    private var shown: [ObjectIdentifier: (text: String, since: Double)] = [:]

    init(seed: UInt64, hour: Int) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("co-sheep-flock-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        now = localMs(hour: hour)
        let seeded = SimRandom.seeded(seed)
        clock = { [unowned self] in self.now }
        random = { [unowned self] in
            if let forced = self.forcedRandom { return forced }
            if !self.script.isEmpty { return self.script.removeFirst() }
            return self.scriptTail ?? seeded()
        }
    }

    /// Point the process-wide globals at this world (remembering what was there).
    func enter() {
        precondition(saved == nil, "world entered twice")
        saved = (Paths.root, SimClock.nowSource, SimRandom.source, SpeechBubble.viewport)
        reassert()
        FriendMemory.resetCache()
    }

    func leave() {
        guard let saved else { return }
        Paths.root = saved.root
        SimClock.nowSource = saved.now
        SimRandom.source = saved.random
        SpeechBubble.viewport = saved.viewport
        FriendMemory.resetCache()
        self.saved = nil
    }

    func reassert() {
        Paths.root = root
        SimClock.nowSource = clock!
        SimRandom.source = random!
    }

    /// Run a synchronous stretch inside the world.
    func inWorld<T>(_ body: () throws -> T) rethrows -> T {
        enter()
        defer { leave() }
        return try body()
    }

    func close() {
        leave()
        try? FileManager.default.removeItem(at: root)
    }

    /// One frame: advance the clock, update the flock, hide stale bubbles.
    func step(_ flock: Flock, _ dt: Double = 16) {
        now += dt
        flock.update(dt)
        hideStaleBubbles(flock)
    }

    /// One social tick (dt 600) whose first rolls are `rolls`; everything after
    /// them is `0.9` (every `< p` gate misses).
    func socialTick(_ flock: Flock, rolls: [Double]) {
        script = rolls
        scriptTail = 0.9
        step(flock, 600)
        script = []
        scriptTail = nil
    }

    /// Step until `condition` holds; returns frames used (-1 on timeout).
    @discardableResult
    func run(_ flock: Flock, maxFrames: Int = 6000, until condition: () -> Bool) -> Int {
        for frame in 1...maxFrames {
            step(flock)
            if condition() { return frame }
        }
        return -1
    }

    func run(_ flock: Flock, frames: Int) {
        for _ in 0..<frames { step(flock) }
    }

    /// Spin the main run loop (real time) until `condition` holds or `timeout`
    /// passes: the sim's `setTimeout`s (`SimTimers`) are real timers.
    func pump(timeout: Double = 3, until condition: () -> Bool) {
        let end = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < end {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func hideStaleBubbles(_ flock: Flock) {
        guard let limit = autoHideMs else { return }
        for id in flock.getCharacterIds() {
            guard let bubble = flock.getCharacter(id)?.bubble else { continue }
            let key = ObjectIdentifier(bubble)
            if bubble.visible {
                if shown[key]?.text != bubble.currentText { shown[key] = (bubble.currentText, now) }
                if now - shown[key]!.since >= limit {
                    bubble.hide()
                    shown[key] = nil
                }
            } else {
                shown[key] = nil
            }
        }
    }
}

@discardableResult
private func withWorld<T>(seed: UInt64 = 1, hour: Int = 12, _ body: (World) throws -> T) rethrows -> T {
    let world = World(seed: seed, hour: hour)
    world.enter()
    defer { world.close() }
    return try body(world)
}

/// Records flock bus events for the length of a (synchronous) test. Async tests
/// don't use it: the bus is global and other tests run while they are suspended.
private final class EventLog {
    private(set) var events: [FlockEvent] = []
    private var unsubscribes: [() -> Void] = []

    init() {
        for name in FlockEventName.allCases {
            unsubscribes.append(bus.on(name) { [unowned self] event in self.events.append(event) })
        }
    }

    isolated deinit {
        unsubscribes.forEach { $0() }
    }

    var spectacleStarted: [String] {
        events.compactMap { if case .spectacleStarted(let t) = $0 { t } else { nil } }
    }

    var spectacleEnded: [String] {
        events.compactMap { if case .spectacleEnded(let t) = $0 { t } else { nil } }
    }

    var groupActivities: [(type: String, participants: [String])] {
        events.compactMap { if case .groupActivity(let t, let p) = $0 { (t, p) } else { nil } }
    }

    var conversations: [(idA: String, idB: String, topic: String)] {
        events.compactMap { if case .conversationHappened(let a, let b, let t) = $0 { (a, b, t) } else { nil } }
    }

    var weather: [String?] {
        var out: [String?] = []
        for case .weatherChanged(let c) in events { out.append(c) }
        return out
    }

    var commentary: [SheepAnimation?] {
        var out: [SheepAnimation?] = []
        for case .aiCommentary(let a) in events { out.append(a) }
        return out
    }
}

/// How the spectacle scheduler starts out.
private enum SchedulerStart {
    /// A spectacle "fired" in the far future: the 20h minimum gap holds forever,
    /// so big time jumps in a test can't start one.
    case quiet
    /// Whatever `spectacles.json` holds (nothing = a fresh state, pity timer due).
    case asIs
}

/// A flock with the Good Colleague plus the given friends.
private func makeFlock(friends: [FriendConfig] = [], colleague: Bool = true,
                       scheduler: SchedulerStart = .quiet) -> Flock {
    if scheduler == .quiet {
        LivingState.saveState("spectacles", .object([
            "lastFiredMs": .number(SimClock.nowMs() + 1e12),
            "lastByType": .object([:]),
        ]))
    }
    let flock = Flock(W, H)
    if colleague { flock.spawnGoodColleague() }
    for f in friends { flock.addFriend(f) }
    return flock
}

private func friend(_ id: String, _ name: String? = nil, color: FriendColor = .pink,
                    personality: FriendPersonality? = .wholesome, scale: Double? = 1) -> FriendConfig {
    FriendConfig(id: id, name: name ?? id.capitalized, color: color, personality: personality,
                 accessories: nil, scale: scale)
}

/// Land a sheep where it stands, calm, for (practically) ever.
private func park(_ sheep: Sheep, x: Double? = nil) {
    if let x { sheep.x = x }
    sheep.y = sheep.groundY
    sheep.state = .idle
    sheep.stateTimer = 0
    sheep.stateDuration = 1e12
    sheep.walkTarget = nil
}

/// Park everyone spread 270px apart (beyond conversation range) and block
/// group activities, so a test only sees what it provokes.
private func quietStage(_ flock: Flock) {
    for (i, id) in flock.getCharacterIds().enumerated() {
        park(flock.getCharacter(id)!.sheep, x: 40 + Double(i) * 270)
    }
    flock.participantFilter = { _ in [] }
}

private func sheep(_ flock: Flock, _ id: String) -> Sheep { flock.getCharacter(id)!.sheep }
private func bubble(_ flock: Flock, _ id: String) -> SpeechBubble { flock.getCharacter(id)!.bubble }

private let sceneKeepAlive = SceneKeeper()
private final class SceneKeeper {
    var scenes: [OverlayScene] = []
}

@Suite("roster", .serialized)
struct FlockRosterTests {
    @Test func startsWithJustTheMainSheep() {
        withWorld { _ in
            let flock = Flock(W, H)
            #expect(flock.getCharacterIds() == ["main"])
            #expect(flock.main.id == "main")
            #expect(flock.main.state == .parachute)
            #expect(flock.getCharacter("main")?.personality == nil)
            #expect(flock.getCharacter("nobody") == nil)
            #expect(flock.getFriendEntry("nobody") == nil)
            #expect(!flock.isCharacterCalm("nobody"))
        }
    }

    @Test func theViewportFollowsTheScreenSize() {
        withWorld { _ in
            let flock = Flock(1200, 800)
            #expect(SpeechBubble.viewport == ScreenSize(width: 1200, height: 800))
            flock.updateScreenSize(1600, 900)
            #expect(SpeechBubble.viewport == ScreenSize(width: 1600, height: 900))
        }
    }

    @Test func goodColleagueIsANamedBlueSnarkyFriendWithHerOwnAccessories() throws {
        try withWorld { _ in
            let flock = Flock(W, H)
            flock.spawnGoodColleague()
            #expect(flock.getCharacterIds() == ["main", "good_colleague"])
            let entry = try #require(flock.getFriendEntry("good_colleague"))
            #expect(entry.sheep.name == "Good Colleague")
            #expect(entry.sheep.tint == FRIEND_TINTS[.blue])
            #expect(entry.personality == .snarky)
            #expect(entry.quips == Flock.GOOD_COLLEAGUE_QUIPS)
            #expect(entry.sheep.drawOverlay != nil)
            #expect(flock.getCharacter("good_colleague")?.personality == "snarky")
            #expect(entry.sheep.x >= DS / 2 && entry.sheep.x <= W - DS * 2 + DS / 2)
            // First quip 15-45s out.
            let wait = entry.nextQuipTime - SimClock.nowMs()
            #expect(wait >= 15000 && wait <= 45000)
            // Spawning again replaces her (JS Map.set) instead of adding a second one.
            flock.spawnGoodColleague()
            #expect(flock.getCharacterIds() == ["main", "good_colleague"])
        }
    }

    @Test func goodColleagueParachutesInThreeSecondsAfterLaunch() {
        withWorld { world in
            let flock = Flock(W, H)
            #expect(flock.getFriendEntry("good_colleague") == nil)
            world.pump(timeout: 4) { flock.getFriendEntry("good_colleague") != nil }
            #expect(flock.getFriendEntry("good_colleague") != nil)
        }
    }

    @Test func aNewFriendGetsItsColorPersonalityScaleAndAccessories() throws {
        try withWorld { _ in
            let flock = Flock(W, H)
            flock.addFriend(FriendConfig(id: "bob", name: "Bob", color: .green, personality: .chaotic,
                                         accessories: ["crown"], scale: 1.1))
            let entry = try #require(flock.getFriendEntry("bob"))
            #expect(entry.sheep.name == "Bob")
            #expect(entry.sheep.personality == .chaotic)
            #expect(entry.personality == .chaotic)
            #expect(entry.sheep.scaleMultiplier == 1.1)
            #expect(entry.sheep.tint == FRIEND_TINTS[.green])
            #expect(entry.sheep.drawOverlay != nil)
            #expect(entry.quips == getPersonalityQuips(.chaotic))
            #expect(entry.sheep.id == "bob")
            let wait = entry.nextQuipTime - SimClock.nowMs()
            #expect(wait >= 30000 && wait <= 90000)
            #expect(flock.getCharacter("bob")?.personality == "chaotic")
        }
    }

    @Test func defaultsAreWholesomeRandomScaleAndNoOverlay() throws {
        try withWorld { _ in
            let flock = Flock(W, H)
            flock.addFriend(FriendConfig(id: "amy", name: "Amy", color: .pink, personality: nil,
                                         accessories: nil, scale: nil))
            flock.addFriend(FriendConfig(id: "cy", name: "Cy", color: .gold, personality: .snarky,
                                         accessories: [], scale: nil))
            let amy = try #require(flock.getFriendEntry("amy"))
            #expect(amy.personality == .wholesome)
            #expect(amy.sheep.personality == .wholesome)
            #expect(amy.sheep.scaleMultiplier >= 0.85 && amy.sheep.scaleMultiplier <= 1.15)
            #expect(amy.sheep.drawOverlay == nil)
            #expect(flock.getFriendEntry("cy")?.sheep.drawOverlay == nil)
            #expect(flock.getFriendEntry("cy")?.sheep.tint == FRIEND_TINTS[.gold])
        }
    }

    @Test func duplicatesAndAFifthFriendAreRefused() {
        withWorld { _ in
            let flock = makeFlock(friends: [friend("a"), friend("b"), friend("c"), friend("d")])
            #expect(flock.getCharacterIds() == ["main", "good_colleague", "a", "b", "c", "d"])
            flock.addFriend(friend("e")) // already five friends (incl. the colleague)
            #expect(flock.getFriendEntry("e") == nil)
            flock.addFriend(FriendConfig(id: "a", name: "Other", color: .blue))
            #expect(flock.getFriendEntry("a")?.sheep.name == "A")
        }
    }

    @Test func friendsKeepInsertionOrder() {
        withWorld { _ in
            let flock = makeFlock(friends: [friend("zed"), friend("amy"), friend("mia")])
            #expect(flock.getCharacterIds() == ["main", "good_colleague", "zed", "amy", "mia"])
            flock.removeFriend("amy")
            flock.addFriend(friend("amy"))
            #expect(flock.getCharacterIds() == ["main", "good_colleague", "zed", "mia", "amy"])
        }
    }

    @Test func theColleagueCannotBeRemovedFriendsCanAndTheirStackIsReleased() {
        withWorld { _ in
            let flock = makeFlock(friends: [friend("a"), friend("b")])
            flock.removeFriend("good_colleague")
            #expect(flock.getFriendEntry("good_colleague") != nil)
            flock.removeFriend("nobody") // no-op

            let a = sheep(flock, "a")
            let b = sheep(flock, "b")
            park(b)
            a.stackOn(b)
            #expect(a.stackedOn === b)
            flock.removeFriend("b")
            #expect(flock.getFriendEntry("b") == nil)
            #expect(flock.getCharacterIds() == ["main", "good_colleague", "a"])
            // The sheep riding the removed friend falls instead of tracking a ghost.
            #expect(a.stackedOn == nil)
            #expect(a.state == .fall)
        }
    }

    @Test func friendsAreHitFirstThenTheMainSheep() {
        withWorld { _ in
            let flock = makeFlock(friends: [friend("a")])
            let main = flock.main
            let gc = sheep(flock, "good_colleague")
            let a = sheep(flock, "a")
            park(main, x: 500)
            park(gc, x: 520)
            park(a, x: 540)
            // All three overlap at (560, ground+10): the last drawn (a) wins.
            #expect(flock.hitTest(560, main.groundY + 10) === a)
            // Only the main sheep at the far left of the pile.
            #expect(flock.hitTest(495, main.groundY + 10) === main)
            // 12px of padding around the box, none beyond.
            #expect(flock.hitTest(500 - 12, main.groundY + 10) === main)
            #expect(flock.hitTest(500 - 13, main.groundY + 10) == nil)
            #expect(flock.hitTest(100, 100) == nil)
        }
    }

    @Test func bubblesAndQuipsBelongToTheRightSheep() {
        withWorld { _ in
            let flock = makeFlock(friends: [friend("a", personality: .chaotic)])
            #expect(flock.getBubble(flock.main) === flock.mainBubble)
            #expect(flock.getBubble(sheep(flock, "a")) === bubble(flock, "a"))
            #expect(flock.getBubble(sheep(flock, "a")) !== flock.mainBubble)
            // Unknown sheep fall back to the main bubble.
            let stranger = Sheep(W, H, "stranger")
            #expect(flock.getBubble(stranger) === flock.mainBubble)

            #expect(getPersonalityQuips(.chaotic).contains(flock.getQuip(sheep(flock, "a"))))
            #expect(Flock.GOOD_COLLEAGUE_QUIPS.contains(flock.getQuip(sheep(flock, "good_colleague"))))
            #expect(!flock.getQuip(flock.main).isEmpty)
            #expect(!flock.getQuip(stranger).isEmpty)
        }
    }

    @Test func boundsPadEachSheepByTwelvePixels() {
        withWorld { _ in
            let flock = makeFlock(friends: [friend("a", scale: 1.5)])
            let bounds = flock.getAllBounds()
            #expect(bounds.count == 3)
            let main = flock.main
            #expect(bounds[0] == FlockBounds(x: main.x - 12, y: main.y - 12,
                                             w: main.displaySize + 24, h: main.displaySize + 24))
            let a = sheep(flock, "a")
            #expect(bounds[2] == FlockBounds(x: a.x - 12, y: a.y - 12, w: a.displaySize + 24, h: a.displaySize + 24))
            #expect(a.displaySize == 144)
        }
    }

    @Test func windowPlatformsReachEverySheep() {
        withWorld { _ in
            let flock = makeFlock(friends: [friend("a")])
            let platforms = [WindowPlatform(x: 100, y: 300, w: 400, h: 300)]
            flock.setWindowPlatforms(platforms)
            for id in flock.getCharacterIds() { #expect(sheep(flock, id).platforms == platforms, "\(id)") }
        }
    }

    @Test func resizingRegroundsEveryoneAndClampsThemOntoTheScreen() {
        withWorld { _ in
            let flock = makeFlock(friends: [friend("a")])
            for id in flock.getCharacterIds() { park(sheep(flock, id), x: 1400) }
            flock.updateScreenSize(1000, 700)
            for id in flock.getCharacterIds() {
                let s = sheep(flock, id)
                #expect(s.screenWidth == 1000 && s.screenHeight == 700, "\(id)")
                #expect(s.x <= 1000 - s.displaySize, "\(id)")
                #expect(s.y == 700 - s.displaySize - 80, "\(id)")
            }
        }
    }

    @Test func calmMeansIdleSitOrWalkAndNotListening() {
        withWorld { _ in
            let flock = makeFlock(friends: [friend("a")])
            let a = sheep(flock, "a")
            for state in SheepState.allCases {
                a.state = state
                #expect(flock.isCharacterCalm("a") == (state == .idle || state == .sit || state == .walk), "\(state)")
            }
            a.state = .idle
            a.startListening() // the human is chatting: hands off
            #expect(!flock.isCharacterCalm("a"))
            a.stopListening()
            #expect(flock.isCharacterCalm("a"))
        }
    }

    @Test func modeAndStatsCallsAreSafeAndQuiet() {
        withWorld { world in
            let log = EventLog()
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            flock.setEasterMode(.on)
            flock.setEasterMode(.off)
            flock.setEasterMode(.auto)
            flock.setSummerMode(.on)
            flock.setSummerMode(.auto)
            flock.applyEasterStats(nil)
            flock.applyEasterStats(EasterStatsSnapshot(eggsFoundTotal: 3))
            flock.applyEasterStats(EasterStats())
            world.run(flock, frames: 5)
            #expect(log.events.isEmpty)
        }
    }
}

@Suite("stacking and trampoline", .serialized)
struct FlockStackingTests {
    private func stage() -> (Flock, Sheep, Sheep) {
        let flock = makeFlock(friends: [friend("a"), friend("b")])
        quietStage(flock)
        let a = sheep(flock, "a")
        let b = sheep(flock, "b")
        park(a, x: 600)
        park(b, x: 900)
        return (flock, a, b)
    }

    /// Drop `dropped` so its feet land `overlap`px into `target`'s box, `dx` off-center.
    private func drop(_ dropped: Sheep, onto target: Sheep, dx: Double = 0, overlap: Double = 46) {
        dropped.x = target.x + dx
        dropped.y = target.y + overlap - dropped.displaySize
    }

    @Test func aDroppedSheepStacksOnACalmSheepBelowIt() {
        withWorld { _ in
            let (flock, a, b) = stage()
            drop(a, onto: b, dx: 30)
            #expect(flock.tryStack(a) === b)
        }
    }

    @Test func stackingNeedsHorizontalOverlapAndTheRightHeight() {
        withWorld { _ in
            let (flock, a, b) = stage()
            drop(a, onto: b, dx: 0.7 * b.displaySize + 1)
            #expect(flock.tryStack(a) == nil) // too far off-center
            drop(a, onto: b, dx: 0.7 * b.displaySize - 1)
            #expect(flock.tryStack(a) === b)
            // Feet must be within (-0.3, +0.6) of the target's height relative to its top.
            drop(a, onto: b, overlap: -0.3 * b.displaySize - 1)
            #expect(flock.tryStack(a) == nil) // way above
            drop(a, onto: b, overlap: -0.3 * b.displaySize + 1)
            #expect(flock.tryStack(a) === b)
            drop(a, onto: b, overlap: 0.6 * b.displaySize + 1)
            #expect(flock.tryStack(a) == nil) // sunk in too deep
            drop(a, onto: b, overlap: 0.6 * b.displaySize - 1)
            #expect(flock.tryStack(a) === b)
        }
    }

    @Test func wildOrAlreadyStackedTargetsAreSkipped() {
        withWorld { _ in
            let (flock, a, b) = stage()
            drop(a, onto: b)
            for state in [SheepState.grabbed, .parachute, .fall, .stampede, .trampoline, .stacked] {
                b.state = state
                #expect(flock.tryStack(a) == nil, "\(state)")
            }
            for state in [SheepState.idle, .walk, .sit, .sleep, .bounce] {
                b.state = state
                #expect(flock.tryStack(a) === b, "\(state)")
            }
            b.state = .idle
            let c = sheep(flock, "good_colleague")
            park(c, x: b.x + 300)
            c.stackOn(b) // b now carries c
            #expect(flock.tryStack(a) == nil)
        }
    }

    @Test func aSheepNeverStacksOnItselfAndFriendsWinOverMain() {
        withWorld { _ in
            let (flock, a, b) = stage()
            park(flock.main, x: b.x + 10)
            drop(a, onto: b, dx: 5)
            // Both b and main are under the drop; friends are checked first.
            #expect(flock.tryStack(a) === b)
            #expect(flock.tryStack(b) !== b)
            // The main sheep can be stacked on too.
            park(flock.main, x: 200)
            drop(a, onto: flock.main)
            #expect(flock.tryStack(a) === flock.main)
        }
    }

    @Test func stackedDialogueBottomComplainsNowTopBragsAfterAMoment() throws {
        try withWorld { world in
            let (flock, a, b) = stage()
            a.stackOn(b)
            flock.onSheepStacked(a, b)

            #expect(Flock.STACK_BOTTOM_QUIPS.contains(bubble(flock, "b").currentText))
            #expect(bubble(flock, "b").visible)
            #expect(b.state == .headshake)
            #expect(!bubble(flock, "a").visible)

            // 1.5s later, if the top is still stacked, it answers.
            world.pump { bubble(flock, "a").visible }
            #expect(Flock.STACK_TOP_QUIPS.contains(bubble(flock, "a").currentText))

            let journal = try Memory.getTodayJournal()
            #expect(journal.contains("*My human stacked a on b me!*"))
            #expect(Memory.loadBrain().totalInteractions == 1)
        }
    }

    @Test func aTopThatGotOffKeepsQuiet() {
        withWorld { world in
            let (flock, a, b) = stage()
            let c = sheep(flock, "good_colleague")
            park(c, x: 300)
            a.stackOn(b)
            flock.onSheepStacked(a, b)
            a.unstack()
            a.state = .idle
            // A second, still-stacked pair as the clock: its top speaks at 1.5s too.
            c.stackOn(flock.main)
            flock.onSheepStacked(c, flock.main)
            world.pump { bubble(flock, "good_colleague").visible }
            #expect(bubble(flock, "good_colleague").visible)
            #expect(!bubble(flock, "a").visible)
        }
    }

    @Test func trampolineHasAtMostTwoCalmOnlookersReactAfterADelay() throws {
        try withWorld { world in
            let flock = makeFlock(friends: [friend("a"), friend("b", personality: .chaotic), friend("c")])
            quietStage(flock)
            let jumper = sheep(flock, "a")
            sheep(flock, "c").state = .grabbed // not calm: skipped
            flock.onTrampolineStarted(jumper)

            // Friend order: good_colleague, a (the jumper: skipped), b, c (busy: skipped).
            let gc = try #require(flock.getFriendEntry("good_colleague")?.pendingReaction)
            let b = try #require(flock.getFriendEntry("b")?.pendingReaction)
            #expect(flock.getFriendEntry("a")?.pendingReaction == nil)
            #expect(flock.getFriendEntry("c")?.pendingReaction == nil)
            #expect(Flock.TRAMPOLINE_REACTIONS[.snarky]!.contains(gc.text))
            #expect(Flock.TRAMPOLINE_REACTIONS[.chaotic]!.contains(b.text))
            #expect(gc.animation == .bounce && b.animation == .bounce)
            #expect(gc.delay >= 800 && gc.delay <= 2300)
            #expect(b.delay >= 800 && b.delay <= 2300)
            let journalText = try Memory.getTodayJournal()
            #expect(journalText.contains("*My human trampoline by a me!*"))

            // Once the delay passes, the friend cheers and bounces.
            world.autoHideMs = nil
            world.run(flock) { bubble(flock, "good_colleague").visible }
            #expect(Flock.TRAMPOLINE_REACTIONS[.snarky]!.contains(bubble(flock, "good_colleague").currentText))
            #expect(sheep(flock, "good_colleague").state == .bounce)
            #expect(flock.getFriendEntry("good_colleague")?.pendingReaction == nil)
        }
    }

    @Test func aReactionIsDroppedIfTheFriendIsBusyWhenItFires() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            world.autoHideMs = nil
            flock.onTrampolineStarted(flock.main)
            let entry = flock.getFriendEntry("good_colleague")!
            #expect(entry.pendingReaction != nil)
            bubble(flock, "good_colleague").show("occupied", duration: 600_000)
            world.run(flock, frames: 200) // > 2.3s
            #expect(entry.pendingReaction == nil)
            #expect(bubble(flock, "good_colleague").currentText == "occupied")
        }
    }

    @Test func aStackedTopFollowsItsBottomThroughTheFlockUpdate() {
        withWorld { world in
            let (flock, a, b) = stage()
            a.stackOn(b)
            b.x = 700
            world.run(flock, frames: 3)
            #expect(a.x == b.x + (b.displaySize - a.displaySize) / 2)
            #expect(a.y == b.y - a.displaySize * 0.7)
        }
    }
}

@Suite("stampede", .serialized)
struct FlockStampedeTests {
    @Test func everyoneRunsFromTheMouseAndTheConversationIsCancelled() {
        withWorld { _ in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            let script: ConversationScript = [ConversationLine(speakerId: "main", text: "hi", duration: 1000, delay: 0)]
            #expect(flock.startScriptedConversation(script, ["main", "a"]))
            #expect(flock.activeConversation != nil)

            flock.triggerStampede(100, 0)
            #expect(flock.activeConversation == nil)
            for id in flock.getCharacterIds() {
                #expect(sheep(flock, id).state == .stampede, "\(id)")
            }
            // Everybody faces away from x=100 unless it is near an edge (main at x=40 flips).
            #expect(sheep(flock, "a").facingRight)
        }
    }

    @Test func parachutingSheepAreExemptAndStampedeCooldownLastsFifteenSeconds() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            sheep(flock, "a").state = .parachute
            flock.triggerStampede(100, 0)
            #expect(sheep(flock, "a").state == .parachute)
            #expect(sheep(flock, "good_colleague").state == .stampede)

            // Let it run out, then try again inside the 15s cooldown: ignored.
            world.run(flock) { sheep(flock, "good_colleague").state != .stampede }
            flock.triggerStampede(700, 0)
            #expect(sheep(flock, "good_colleague").state != .stampede)
            // After the cooldown: works again.
            world.autoHideMs = 100
            for _ in 0..<1000 { world.step(flock) } // 16s
            park(sheep(flock, "good_colleague"))
            flock.triggerStampede(700, 0)
            #expect(sheep(flock, "good_colleague").state == .stampede)
        }
    }

    @Test func nobodyStampedingMeansNoAftermathDialogue() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            for id in flock.getCharacterIds() { sheep(flock, id).state = .parachute }
            flock.triggerStampede(100, 0)
            world.run(flock, frames: 400)
            for id in flock.getCharacterIds() { #expect(!bubble(flock, id).visible, "\(id)") }
        }
    }

    @Test func onceItsOverTwoSheepTalkItThrough() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            world.autoHideMs = nil
            flock.triggerStampede(1500, 0)
            let anyone = { flock.getCharacterIds().first { bubble(flock, $0).visible } }
            // Stampede runs 1.2–2.0s, then 2.5s minimum before the dialogue.
            let frames = world.run(flock, maxFrames: 1000) { anyone() != nil }
            #expect(frames > 0)
            let firstId = anyone()!
            #expect(Flock.STAMPEDE_QUIPS_A.contains(bubble(flock, firstId).currentText))
            #expect(sheep(flock, firstId).state == .vibrate)
            // ...and a second calm sheep answers two seconds later.
            world.pump(timeout: 3) { flock.getCharacterIds().filter { bubble(flock, $0).visible }.count >= 2 }
            let answered = flock.getCharacterIds().filter { $0 != firstId && bubble(flock, $0).visible }
            #expect(answered.count == 1)
            #expect(Flock.STAMPEDE_QUIPS_B.contains(bubble(flock, answered[0]).currentText))
            #expect(sheep(flock, answered[0]).state == .headshake)
        }
    }
}

@Suite("conversations", .serialized)
struct FlockConversationTests {
    private func line(_ id: String, _ text: String, _ duration: Double = 1000, _ delay: Double = 0,
                      _ animation: SheepAnimation? = nil) -> ConversationLine {
        ConversationLine(speakerId: id, text: text, duration: duration, delay: delay, animation: animation)
    }

    @Test func aScriptedConversationPlaysItsLinesOntoTheRightBubbles() throws {
        try withWorld { world in
            let log = EventLog()
            let flock = makeFlock(friends: [friend("a", "Amy")])
            quietStage(flock)
            world.autoHideMs = nil
            let script = [
                line("good_colleague", "first line", 1000, 0),
                line("a", "second line", 1000, 500, .bounce),
                line("good_colleague", "third line", 1000, 300),
            ]
            #expect(flock.startScriptedConversation(script, ["good_colleague", "a"]))
            // Busy stage: a second script is refused.
            #expect(!flock.startScriptedConversation(script, ["good_colleague", "a"]))

            // Line 1 lands on the first update (timer starts at 0).
            world.step(flock)
            #expect(bubble(flock, "good_colleague").currentText == "first line")
            #expect(!bubble(flock, "a").visible)

            // Line 2 at duration(1000) + delay(500) = 1500ms after line 1.
            let f2 = world.run(flock) { bubble(flock, "a").visible }
            #expect(abs(Double(f2) * 16 - 1500) <= 32, "\(f2)")
            #expect(bubble(flock, "a").currentText == "second line")
            #expect(sheep(flock, "a").state == .bounce) // the line's animation
            #expect(!log.events.contains { if case .conversationHappened = $0 { true } else { false } })

            // Line 3 at 1000 + 300 later, on the first speaker again.
            bubble(flock, "good_colleague").hide()
            let f3 = world.run(flock) { bubble(flock, "good_colleague").visible }
            #expect(abs(Double(f3) * 16 - 1300) <= 32, "\(f3)")
            #expect(bubble(flock, "good_colleague").currentText == "third line")

            // The end comes after the last line's duration: recorded once.
            #expect(flock.activeConversation != nil)
            let done = world.run(flock) { flock.activeConversation == nil }
            #expect(abs(Double(done) * 16 - 1000) <= 32, "\(done)")
            let convo = try #require(log.conversations.first)
            #expect(log.conversations.count == 1)
            #expect(convo.idA == "good_colleague" && convo.idB == "a")
            #expect(convo.topic == "first line")
            // ...and into both friends' memories.
            let gc = FriendMemory.getFriendBrain("good_colleague")
            #expect(gc.memories.last?.text == "Talked with a about first line")
            #expect(gc.relationships["a"] == 1)
            #expect(FriendMemory.getFriendBrain("a").stats.conversationsTotal == 1)
        }
    }

    @Test func aTopicIsTheFirstThirtyUTF16UnitsOfTheFirstLine() {
        withWorld { world in
            let log = EventLog()
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            world.autoHideMs = nil
            let text = "Nå blir det godt med medda, ja verkeleg 🐑🐑🐑"
            #expect(flock.startScriptedConversation([line("a", text, 100, 0)], ["a", "good_colleague"]))
            world.run(flock) { flock.activeConversation == nil }
            let topic = log.conversations.first?.topic ?? ""
            #expect(topic == "Nå blir det godt med medda, ja")
            #expect(topic.utf16.count == 30)

            // A pair straddling the cut is dropped whole (JS would keep half a surrogate).
            for id in ["a", "good_colleague"] { bubble(flock, id).hide() }
            let straddling = String(repeating: "x", count: 29) + "🐑🐑"
            #expect(flock.startScriptedConversation([line("a", straddling, 100, 0)], ["a", "good_colleague"]))
            world.run(flock) { flock.activeConversation == nil }
            #expect(log.conversations.last?.topic == String(repeating: "x", count: 29))
        }
    }

    @Test func threeWayScriptsAreNotRecordedAsFriendConversations() {
        withWorld { world in
            let log = EventLog()
            let flock = makeFlock(friends: [friend("a"), friend("b")])
            quietStage(flock)
            world.autoHideMs = nil
            let script = [line("a", "one", 100, 0), line("b", "two", 100, 0), line("good_colleague", "three", 100, 0)]
            #expect(flock.startScriptedConversation(script, ["a", "b", "good_colleague"]))
            world.run(flock) { flock.activeConversation == nil }
            #expect(log.conversations.isEmpty)
            #expect(FriendMemory.getFriendBrain("a").stats.conversationsTotal == 0)
        }
    }

    @Test func aScriptIsRefusedWhenTheStageIsBusyOrCastIsNotCalm() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            let script = [line("a", "hello")]

            #expect(!flock.startScriptedConversation([], ["a"])) // nothing to say
            #expect(!flock.startScriptedConversation(script, ["a", "ghost"])) // unknown participant

            sheep(flock, "a").state = .grabbed
            #expect(!flock.startScriptedConversation(script, ["a"]))
            sheep(flock, "a").state = .idle

            sheep(flock, "a").startListening() // chatting with the human
            #expect(!flock.startScriptedConversation(script, ["a"]))
            sheep(flock, "a").stopListening()
            park(sheep(flock, "a"))

            bubble(flock, "a").show("talking", duration: 600_000)
            #expect(!flock.startScriptedConversation(script, ["a"]))
            bubble(flock, "a").hide()

            flock.groupActivity = createGroupActivity(.huddle, ["main", "good_colleague", "a"], 300)
            #expect(!flock.startScriptedConversation(script, ["a"]))
            flock.cancelConversation()
            #expect(flock.groupActivity == nil)

            #expect(flock.startScriptedConversation(script, ["a"]))
            world.run(flock, frames: 2)
        }
    }

    @Test func unknownSpeakersAreSkippedAndTheScriptStillEnds() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            world.autoHideMs = nil
            #expect(flock.startScriptedConversation([line("ghost", "boo", 100, 0), line("a", "hi", 100, 0)], ["a"]))
            world.run(flock) { flock.activeConversation == nil }
            #expect(bubble(flock, "a").currentText == "hi")
        }
    }

    @Test func closePairsStartTemplateConversationsOnASocialTickWhenTheRollHits() throws {
        try withWorld { world in
            let log = EventLog()
            let flock = makeFlock(friends: [friend("a")])
            let gc = sheep(flock, "good_colleague")
            let a = sheep(flock, "a")
            park(flock.main, x: 1300)
            park(gc, x: 200)
            park(a, x: 260)
            flock.participantFilter = { _ in [] }
            flock.friendAIChat = nil

            // Not a social tick yet (dt < 500): nothing.
            world.forcedRandom = 0
            world.step(flock, 100)
            #expect(flock.activeConversation == nil)

            // Social tick, but the 2% roll misses.
            world.forcedRandom = 0.5
            world.step(flock, 500)
            #expect(flock.activeConversation == nil)

            // Roll hits, but AI chat is not chosen (0.3 gate misses on the second roll).
            var rolls = [0.0, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9]
            let savedSource = SimRandom.source
            world.forcedRandom = nil
            SimRandom.source = { rolls.isEmpty ? 0.9 : rolls.removeFirst() }
            world.step(flock, 600)
            SimRandom.source = savedSource

            let conv = try #require(flock.activeConversation)
            #expect(conv.participants == ["good_colleague", "a"])
            #expect(conv.currentIndex == 0 && conv.timer == 0)
            #expect(!conv.lines.isEmpty)
            #expect(log.conversations.isEmpty)
        }
    }

    @Test func farApartOrBusyOrTalkingPairsDoNotConverse() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            let gc = sheep(flock, "good_colleague")
            let a = sheep(flock, "a")
            park(flock.main, x: 1300)
            park(gc, x: 200)
            park(a, x: 200 + 193) // just beyond two display widths
            flock.participantFilter = { _ in [] }
            world.forcedRandom = 0
            world.step(flock, 600)
            #expect(flock.activeConversation == nil)

            park(a, x: 260)
            a.state = .grabbed
            world.step(flock, 600)
            #expect(flock.activeConversation == nil)

            a.state = .idle
            bubble(flock, "a").show("busy", duration: 600_000)
            world.step(flock, 600)
            #expect(flock.activeConversation == nil)
        }
    }

    @Test func aFinishedConversationStartsAThreeToFiveMinuteCooldown() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            world.autoHideMs = nil
            #expect(flock.startScriptedConversation([line("a", "bye", 100, 0)], ["a", "good_colleague"]))
            world.run(flock) { flock.activeConversation == nil }

            // Main next to the colleague (a template pair, no AI roll); a far away.
            let regroup = {
                park(flock.main, x: 200)
                park(sheep(flock, "good_colleague"), x: 260)
                park(sheep(flock, "a"), x: 1300)
                for id in flock.getCharacterIds() { bubble(flock, id).hide() }
            }

            // Within the cooldown (>= 180s) even a hit roll does nothing.
            world.autoHideMs = 50
            world.step(flock, 100_000)
            regroup()
            world.socialTick(flock, rolls: [0.0, 0.9])
            #expect(flock.activeConversation == nil)

            // After the longest cooldown (300s) it starts again.
            world.step(flock, 200_000)
            regroup()
            world.step(flock, 100)
            world.socialTick(flock, rolls: [0.0, 0.9])
            #expect(flock.activeConversation?.participants == ["main", "good_colleague"])
        }
    }

    @Test func aChatReplyCancelsChatterAnimatesMainAndPromptsFriendReactions() {
        withWorld { world in
            let log = EventLog()
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            park(flock.main, x: 500)
            park(sheep(flock, "good_colleague"), x: 600) // within 3 display widths
            park(sheep(flock, "a"), x: 1000) // too far
            world.autoHideMs = nil
            flock.groupActivity = createGroupActivity(.huddle, ["main", "good_colleague", "a"], 500)

            flock.onChatReply(.spin)
            #expect(flock.groupActivity == nil)
            #expect(flock.main.state == .spin)
            #expect(log.commentary == [.spin])
            let reaction = flock.getFriendEntry("good_colleague")?.pendingReaction
            #expect(reaction != nil)
            #expect(Flock.REACTION_MESSAGES[.snarky]!.contains(reaction?.text ?? ""))
            #expect(reaction?.animation == .headshake) // snarky
            #expect((reaction?.delay ?? 0) >= 1000 && (reaction?.delay ?? 0) <= 3000)
            #expect(flock.getFriendEntry("a")?.pendingReaction == nil)

            // The 30s reactive cooldown mutes the second reply.
            flock.getFriendEntry("good_colleague")?.pendingReaction = nil
            flock.onChatReply(nil)
            #expect(flock.getFriendEntry("good_colleague")?.pendingReaction == nil)
            #expect(log.commentary == [.spin, nil])
            world.run(flock, frames: 1)
        }
    }

    @Test func theMainBubblesCommentaryEventsAnimateTheMainSheep() {
        withWorld { _ in
            let log = EventLog()
            let flock = makeFlock()
            park(flock.main)
            AppEvents.shared.sheepCommentary.emit(CommentaryEvent(text: "baa", animation: .zoom))
            #expect(flock.mainBubble.currentText == "baa")
            #expect(flock.main.state == .zoom)
            #expect(log.commentary == [.zoom])
        }
    }
}

@Suite("friend AI chat", .serialized)
struct FlockAIChatTests {
    /// GC (200) and Amy (260) close together, main far away, so only that pair converses.
    private func stage() -> Flock {
        let flock = makeFlock(friends: [friend("amy", "Amy", personality: .wholesome)])
        park(flock.main, x: 1300)
        park(sheep(flock, "good_colleague"), x: 200)
        park(sheep(flock, "amy"), x: 260)
        flock.participantFilter = { _ in [] }
        return flock
    }

    /// One social tick with the pair roll (2%) and the AI roll (30%) both hitting: the chat
    /// request starts as a main-actor `Task` — the caller awaits `flock.aiChatTask` outside the world.
    private func aiTick(_ world: World, _ flock: Flock) {
        world.forcedRandom = 0
        world.step(flock, 600)
        world.forcedRandom = nil
    }

    /// One social tick whose pair roll hits and whose AI roll would miss (or is skipped):
    /// a template conversation.
    private func templateTick(_ world: World, _ flock: Flock) {
        world.socialTick(flock, rolls: [0.0, 0.9])
    }

    /// After a long jump in time the friends have blurted quips and animations:
    /// put everyone back and let the bubbles clear.
    private func regroup(_ world: World, _ flock: Flock) {
        park(flock.main, x: 1300)
        park(sheep(flock, "good_colleague"), x: 200)
        park(sheep(flock, "amy"), x: 260)
        for id in flock.getCharacterIds() { bubble(flock, id).hide() }
        world.step(flock, 100)
    }

    private static let reply = """
    ```json
    [
      {"speaker": "Good Colleague", "text": "Hei, Amy.", "animation": "spin"},
      {"speaker": "Amy", "text": "Hi there!", "animation": "nonsense"},
      {"speaker": "Someone Else", "text": "Who?", "animation": null}
    ]
    ```
    """

    @Test func aModelReplyBecomesAConversationBetweenThePair() async throws {
        let world = World(seed: 1, hour: 12)
        defer { world.close() }
        var args: [String?] = []
        let flock = world.inWorld { () -> Flock in
            let flock = stage()
            flock.friendAIChat = { aId, aName, aP, bId, bName, bP, topic in
                args = [aId, aName, aP, bId, bName, bP, topic]
                return Self.reply
            }
            aiTick(world, flock)
            #expect(flock.aiChatPending)
            return flock
        }
        await flock.aiChatTask?.value

        try world.inWorld {
            #expect(args == ["good_colleague", "Good Colleague", "snarky", "amy", "Amy", "wholesome", nil])
            #expect(!flock.aiChatPending)
            let conv = try #require(flock.activeConversation)
            #expect(conv.participants == ["good_colleague", "amy"])
            #expect(conv.lines.map(\.speakerId) == ["good_colleague", "amy", "good_colleague"])
            #expect(conv.lines.map(\.text) == ["Hei, Amy.", "Hi there!", "Who?"])
            #expect(conv.lines.map(\.animation) == [.spin, nil, nil])
            #expect(conv.lines.map(\.duration) == [3500, 3500, 3500])
            #expect(conv.lines.map(\.delay) == [0, 800, 800])
        }
    }

    @Test func theAIReplyPlaysAndIsRemembered() async {
        let world = World(seed: 1, hour: 12)
        defer { world.close() }
        let flock = world.inWorld { () -> Flock in
            let flock = stage()
            world.autoHideMs = nil
            flock.friendAIChat = { _, _, _, _, _, _, _ in Self.reply }
            aiTick(world, flock)
            return flock
        }
        await flock.aiChatTask?.value

        world.inWorld {
            world.run(flock) { flock.activeConversation == nil }
            #expect(bubble(flock, "good_colleague").currentText == "Who?")
            #expect(bubble(flock, "amy").currentText == "Hi there!")
            let gc = FriendMemory.getFriendBrain("good_colleague")
            #expect(gc.memories.last?.text == "Talked with amy about Hei, Amy.")
            #expect(FriendMemory.getFriendBrain("amy").stats.conversationsTotal == 1)
        }
    }

    @Test func aFailedCallBacksOffForTenMinutes() async {
        let world = World(seed: 1, hour: 12)
        defer { world.close() }
        var calls = 0
        let flock = world.inWorld { () -> Flock in
            let flock = stage()
            flock.friendAIChat = { _, _, _, _, _, _, _ in
                calls += 1
                throw CancellationError()
            }
            aiTick(world, flock)
            return flock
        }
        await flock.aiChatTask?.value

        world.inWorld {
            #expect(calls == 1)
            #expect(flock.activeConversation == nil)
            // 60s template-conversation cooldown, then a hit roll: a template
            // conversation, not another AI call (10 min back-off).
            world.autoHideMs = 50
            world.step(flock, 61_000)
            regroup(world, flock)
            templateTick(world, flock)
            #expect(calls == 1)
            #expect(flock.activeConversation != nil)
        }
    }

    @Test func anUnwiredSeamBehavesLikeAFailedCall() async {
        let world = World(seed: 1, hour: 12)
        defer { world.close() }
        let flock = world.inWorld { () -> Flock in
            let flock = stage()
            flock.friendAIChat = nil
            aiTick(world, flock)
            return flock
        }
        await flock.aiChatTask?.value

        world.inWorld {
            #expect(flock.activeConversation == nil)
            // Backed off: the next hit roll after the 60s cooldown yields a template conversation.
            world.step(flock, 61_000)
            regroup(world, flock)
            templateTick(world, flock)
            #expect(flock.activeConversation != nil)
        }
    }

    @Test(arguments: ["not json at all", "[]", "{\"speaker\": \"x\"}", "[{\"speaker\": \"Amy\"}]"])
    func garbageOrEmptyRepliesStartNothingButStillBackOff(reply: String) async {
        let world = World(seed: 1, hour: 12)
        defer { world.close() }
        var calls = 0
        let flock = world.inWorld { () -> Flock in
            let flock = stage()
            flock.friendAIChat = { _, _, _, _, _, _, _ in calls += 1; return reply }
            aiTick(world, flock)
            return flock
        }
        await flock.aiChatTask?.value

        world.inWorld {
            #expect(calls == 1)
            #expect(flock.activeConversation == nil)
            world.autoHideMs = 50
            world.step(flock, 61_000)
            regroup(world, flock)
            templateTick(world, flock)
            #expect(calls == 1) // AI cooldown was burned
            #expect(flock.activeConversation != nil)
        }
    }

    @Test func noSecondRequestWhileOneIsPending() async {
        let world = World(seed: 1, hour: 12)
        defer { world.close() }
        var calls = 0
        let flock = world.inWorld { () -> Flock in
            let flock = stage()
            flock.friendAIChat = { _, _, _, _, _, _, _ in
                calls += 1
                return "[]"
            }
            // The request stays pending until its Task runs: more hit ticks in between must not fire another.
            world.forcedRandom = 0
            world.step(flock, 600)
            #expect(flock.aiChatPending)
            world.step(flock, 600)
            world.step(flock, 600)
            world.forcedRandom = nil
            return flock
        }
        await flock.aiChatTask?.value
        #expect(calls == 1)
        #expect(!flock.aiChatPending)
    }

    @Test func noAICallWhenMainIsInThePair() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("amy")])
            park(flock.main, x: 200)
            park(sheep(flock, "good_colleague"), x: 1300)
            park(sheep(flock, "amy"), x: 260)
            flock.participantFilter = { _ in [] }
            var calls = 0
            flock.friendAIChat = { _, _, _, _, _, _, _ in calls += 1; return "[]" }
            templateTick(world, flock)
            #expect(calls == 0)
            #expect(flock.aiChatTask == nil)
            #expect(flock.activeConversation?.participants == ["main", "amy"]) // a template conversation instead
        }
    }

    @Test func parseFriendChatScriptHandlesFencesAnimationsAndSpeakers() throws {
        let plain = #"[{"speaker":"Bo","text":"a","animation":"bounce"},{"speaker":"Al","text":"b"}]"#
        let script = try #require(try Flock.parseFriendChatScript(plain, idA: "A", idB: "B", nameB: "Bo"))
        #expect(script.map(\.speakerId) == ["B", "A"])
        #expect(script.map(\.animation) == [.bounce, nil])
        #expect(script.map(\.delay) == [0, 800])

        let fenced = "  ```JSON\n" + plain + "\n```  "
        #expect(try Flock.parseFriendChatScript(fenced, idA: "A", idB: "B", nameB: "Bo")?.count == 2)

        for anim in ["bounce", "spin", "backflip", "headshake", "zoom", "vibrate"] {
            let s = try #require(try Flock.parseFriendChatScript(
                #"[{"speaker":"x","text":"t","animation":"\#(anim)"}]"#, idA: "A", idB: "B", nameB: "B"))
            #expect(s[0].animation?.rawValue == anim)
        }
        for anim in ["", "dance", "Bounce"] {
            let s = try #require(try Flock.parseFriendChatScript(
                #"[{"speaker":"x","text":"t","animation":"\#(anim)"}]"#, idA: "A", idB: "B", nameB: "B"))
            #expect(s[0].animation == nil, "\(anim)")
        }
        #expect(try Flock.parseFriendChatScript("[]", idA: "A", idB: "B", nameB: "B") == nil)
        #expect(throws: (any Error).self) { try Flock.parseFriendChatScript("nope", idA: "A", idB: "B", nameB: "B") }
        #expect(throws: (any Error).self) { try Flock.parseFriendChatScript("{}", idA: "A", idB: "B", nameB: "B") }
    }
}

@Suite("notifications, quips and social behavior", .serialized)
struct FlockSocialTests {
    @Test func oneFriendGreetsTheHumanEightSecondsAfterLaunchOnceLanded() throws {
        try withWorld { world in
            let flock = makeFlock(friends: [friend("a"), friend("b")])
            quietStage(flock)
            world.autoHideMs = nil
            // The colleague is still parachuting (high up), so she is skipped.
            let gc = sheep(flock, "good_colleague")
            gc.state = .parachute
            gc.y = -DS
            world.run(flock, frames: 490) // 7.84s
            #expect(flock.getFriendEntry("a")?.pendingReaction == nil)
            world.run(flock, frames: 12) // 8.03s
            let reaction = try #require(flock.getFriendEntry("a")?.pendingReaction)
            #expect(Flock.GREETINGS[.wholesome]!.contains(reaction.text))
            #expect(reaction.animation == nil)
            #expect(reaction.delay > 900 && reaction.delay <= 4000)
            #expect(flock.getFriendEntry("b")?.pendingReaction == nil) // only one greets
            #expect(flock.getFriendEntry("good_colleague")?.pendingReaction == nil)

            world.run(flock) { bubble(flock, "a").visible }
            #expect(Flock.GREETINGS[.wholesome]!.contains(bubble(flock, "a").currentText))
        }
    }

    @Test func greetingWaitsUntilSomeoneHasLanded() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            for id in ["good_colleague", "a"] {
                let s = sheep(flock, id)
                s.state = .parachute
                s.y = -DS // 600 frames of parachuting (80px/s) never reach the ground
            }
            world.run(flock, frames: 600)
            #expect(flock.getFriendEntry("a")?.pendingReaction == nil)
            #expect(flock.getFriendEntry("good_colleague")?.pendingReaction == nil)
            // Once one lands, it greets.
            park(sheep(flock, "a"))
            world.run(flock, frames: 2)
            #expect(flock.getFriendEntry("a")?.pendingReaction != nil)
            #expect(flock.getFriendEntry("good_colleague")?.pendingReaction == nil)
        }
    }

    @Test func nightfallAtTwentyTwentyTwoAndMidnightGetsOneCalmFriendsComment() {
        withWorld(hour: 20) { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            world.autoHideMs = nil
            // Crossing into hour 20 at the first update: the first calm friend comments.
            world.step(flock)
            #expect(Flock.NIGHT_MESSAGES[.snarky]!.contains(bubble(flock, "good_colleague").currentText))
            #expect(!bubble(flock, "a").visible)

            // The launch greeting (8s in) restarts the notification cooldown; get it out of the way.
            world.step(flock, 9000)
            bubble(flock, "good_colleague").hide()
            bubble(flock, "a").hide()
            // Hour 22 arrives while the 2-minute notification cooldown is running: silence.
            world.now = localMs(hour: 22)
            world.step(flock)
            #expect(!bubble(flock, "good_colleague").visible)
            #expect(!bubble(flock, "a").visible)

            // After the cooldown, midnight speaks up again.
            world.step(flock, 121_000)
            world.now = localMs(hour: 23, minute: 59)
            world.step(flock)
            for id in ["good_colleague", "a"] {
                bubble(flock, id).hide()
                park(sheep(flock, id))
            }
            world.now = localMs(hour: 0)
            world.step(flock)
            #expect(Flock.NIGHT_MESSAGES[.snarky]!.contains(bubble(flock, "good_colleague").currentText))
            #expect(!bubble(flock, "a").visible)
        }
    }

    @Test func hoursOutsideTwentyTwentyTwoZeroAreSilent() {
        withWorld(hour: 21) { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            world.autoHideMs = nil
            world.step(flock)
            for id in ["good_colleague", "a"] { #expect(!bubble(flock, id).visible) }
        }
    }

    @Test func breakReminderEchoIsAFriendsDelayedFiveSecondReplyWithATwoMinuteCooldown() throws {
        try withWorld { world in
            let flock = makeFlock(friends: [friend("a", personality: .chaotic)])
            quietStage(flock)
            bubble(flock, "good_colleague").show("busy", duration: 600_000) // skipped
            flock.echoBreakReminder()
            let reaction = try #require(flock.getFriendEntry("a")?.pendingReaction)
            #expect(Flock.ECHO_MESSAGES[.chaotic]!.contains(reaction.text))
            #expect(reaction.delay == 5000)
            #expect(reaction.animation == nil)
            #expect(flock.getFriendEntry("good_colleague")?.pendingReaction == nil)

            // Cooldown: a second reminder does nothing.
            flock.getFriendEntry("a")?.pendingReaction = nil
            flock.echoBreakReminder()
            #expect(flock.getFriendEntry("a")?.pendingReaction == nil)

            // ...until it decays (120s) — the launch greeting (8s in) restarts it, so let that pass first.
            world.autoHideMs = 50
            world.step(flock, 9000)
            world.step(flock, 121_000)
            for id in ["good_colleague", "a"] {
                bubble(flock, id).hide()
                park(sheep(flock, id))
                flock.getFriendEntry(id)?.pendingReaction = nil
            }
            flock.echoBreakReminder()
            #expect(flock.getFriendEntry("good_colleague")?.pendingReaction != nil)
            #expect(flock.getFriendEntry("a")?.pendingReaction == nil) // one echo only
        }
    }

    @Test func friendsBlurtAQuipWhenTheirTimerIsUpAndRearmFortyFiveToNinetySeconds() throws {
        try withWorld { world in
            let flock = makeFlock(friends: [friend("a", personality: .snarky)])
            quietStage(flock)
            world.autoHideMs = nil
            let a = try #require(flock.getFriendEntry("a"))
            a.nextQuipTime = world.now - 1
            world.forcedRandom = 0.99 // no themed pool, no animation
            world.step(flock, 600)
            world.forcedRandom = nil
            #expect(getPersonalityQuips(.snarky).contains(bubble(flock, "a").currentText))
            #expect(!bubble(flock, "good_colleague").visible) // its quip time is 15-45s away
            let rearm = a.nextQuipTime - world.now
            #expect(rearm >= 45000 && rearm <= 90000)
        }
    }

    @Test func seasonThemesSwapInTheirQuipPools() throws {
        try withWorld { world in
            let flock = makeFlock(friends: [friend("a", personality: .snarky)])
            quietStage(flock)
            world.autoHideMs = nil
            flock.setEasterMode(.on)
            let a = try #require(flock.getFriendEntry("a"))
            a.nextQuipTime = world.now - 1
            world.forcedRandom = 0 // the 35% roll hits
            world.step(flock, 600)
            #expect(Flock.EASTER_IDLE_QUIPS.contains(bubble(flock, "a").currentText))

            flock.setEasterMode(.off)
            flock.setSummerMode(.on)
            bubble(flock, "a").hide()
            park(sheep(flock, "a")) // the first quip may have played an animation
            a.nextQuipTime = world.now - 1
            world.step(flock, 600)
            #expect(SUMMER_IDLE_QUIPS.contains(bubble(flock, "a").currentText))
            world.forcedRandom = nil
        }
    }

    @Test func aBusyFriendKeepsItsQuipForLaterButRearms() throws {
        try withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            let a = try #require(flock.getFriendEntry("a"))
            sheep(flock, "a").state = .grabbed
            a.nextQuipTime = world.now - 1
            world.step(flock, 600)
            #expect(!bubble(flock, "a").visible)
            #expect(a.nextQuipTime > world.now + 44000) // rescheduled anyway
        }
    }

    @Test func idleFriendsSometimesWalkTowardTheNearestFarAwayCharacter() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            park(flock.main, x: 40)
            park(sheep(flock, "good_colleague"), x: 1000)
            park(sheep(flock, "a"), x: 1300)
            flock.participantFilter = { _ in [] }
            world.forcedRandom = 0
            world.step(flock, 600)
            world.forcedRandom = nil
            // a's nearest is the colleague (300 > 288 away): walk to it; the colleague's nearest is a.
            #expect(sheep(flock, "a").walkTarget == 1000)
            #expect(sheep(flock, "good_colleague").walkTarget == 1300)
        }
    }

    @Test func friendsCloserThanThreeDisplayWidthsStayPut() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            park(flock.main, x: 40)
            park(sheep(flock, "good_colleague"), x: 1000)
            park(sheep(flock, "a"), x: 1250) // 250 < 288
            flock.participantFilter = { _ in [] }
            world.forcedRandom = 0
            world.step(flock, 600)
            world.forcedRandom = nil
            #expect(sheep(flock, "a").walkTarget == nil)
            #expect(sheep(flock, "good_colleague").walkTarget == nil)
        }
    }

    @Test func weatherChangesReactOncePerChangeAndTheColleaguesMutedByCooldown() {
        withWorld { world in
            let log = EventLog()
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            park(flock.main, x: 500)
            park(sheep(flock, "good_colleague"), x: 600)
            park(sheep(flock, "a"), x: 700)

            flock.setWeatherCondition("rain", 12)
            #expect(log.weather == ["rain"])
            #expect(flock.getFriendEntry("good_colleague")?.pendingReaction != nil)
            #expect(flock.getFriendEntry("a")?.pendingReaction != nil) // 2 calm friends near main

            flock.setWeatherCondition("rain") // unchanged: no event
            flock.setWeatherCondition(nil) // cleared: no event
            flock.setWeatherCondition("")
            #expect(log.weather == ["rain"])

            // Reactive cooldown (30s) is running: snow still emits the event, but nobody reacts.
            flock.getFriendEntry("good_colleague")?.pendingReaction = nil
            flock.getFriendEntry("a")?.pendingReaction = nil
            flock.setWeatherCondition("snow")
            #expect(log.weather == ["rain", "snow"])
            #expect(flock.getFriendEntry("good_colleague")?.pendingReaction == nil)
            world.run(flock, frames: 1)
        }
    }
}

@Suite("group activities in the flock", .serialized)
struct FlockGroupActivityTests {
    /// Three sheep `gap` px apart around x=720. The default gap (220) is beyond
    /// conversation range (192) but inside the 480px activity cluster.
    private func cluster(_ flock: Flock, gap: Double = 220) {
        park(flock.main, x: 720 - gap)
        park(sheep(flock, "good_colleague"), x: 720)
        park(sheep(flock, "a"), x: 720 + gap)
        flock.friendAIChat = nil
    }

    @Test func aRareSocialTickStartsAnActivityAmongTheCluster() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            cluster(flock)
            world.forcedRandom = 0.5
            world.step(flock, 600) // 0.5 > 0.001: no start
            #expect(flock.groupActivity == nil)
            world.forcedRandom = 0
            world.step(flock, 600)
            world.forcedRandom = nil
            let activity = flock.groupActivity
            #expect(activity?.type == .campfireCircle) // roll 0 → first standard type
            #expect(activity?.participants == ["main", "good_colleague", "a"])
            #expect(activity?.centerX == 720.0)
            #expect(activity?.phase == .gathering)
        }
    }

    @Test func needsTwoFriendsAndThreeCalmSheepInRange() {
        withWorld { world in
            let flock = makeFlock() // only the colleague
            park(flock.main, x: 500)
            park(sheep(flock, "good_colleague"), x: 720)
            world.forcedRandom = 0
            world.step(flock, 600)
            #expect(flock.groupActivity == nil)

            flock.addFriend(friend("a"))
            cluster(flock)
            sheep(flock, "a").state = .grabbed
            world.step(flock, 600)
            #expect(flock.groupActivity == nil) // only two calm sheep
            sheep(flock, "a").state = .idle
            world.step(flock, 600)
            world.forcedRandom = nil
            #expect(flock.groupActivity != nil)
        }
    }

    @Test func noActivityWhileAConversationOrSpectacleRuns() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            cluster(flock)
            #expect(flock.startScriptedConversation(
                [ConversationLine(speakerId: "a", text: "hm", duration: 60_000, delay: 0)], ["a"]))
            world.forcedRandom = 0
            world.step(flock, 600)
            #expect(flock.groupActivity == nil)
            flock.cancelConversation()

            #expect(flock.startSpectacle(.balloon))
            world.step(flock, 600)
            #expect(flock.groupActivity == nil)
            world.forcedRandom = nil
        }
    }

    @Test func theParticipantFilterCanThinOrBlockTheGroup() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            cluster(flock)
            world.forcedRandom = 0
            flock.participantFilter = { ids in ids.filter { $0 != "a" } } // a feuds with somebody
            world.step(flock, 600)
            #expect(flock.groupActivity == nil)
            flock.participantFilter = { $0 }
            world.step(flock, 600)
            #expect(flock.groupActivity?.participants == ["main", "good_colleague", "a"])
            world.forcedRandom = nil
        }
    }

    @Test func aFinishedActivityIsRecordedBroadcastAndCoolsDownForFiveToTenMinutes() throws {
        try withWorld { world in
            let log = EventLog()
            let flock = makeFlock(friends: [friend("a")])
            cluster(flock)
            world.autoHideMs = 50
            flock.groupActivity = createGroupActivity(.huddle, ["main", "good_colleague", "a"], 720)
            let frames = world.run(flock, maxFrames: 3000) { flock.groupActivity == nil }
            #expect(frames > 0)
            #expect(log.groupActivities.count == 1)
            #expect(log.groupActivities.first?.type == "huddle")
            #expect(log.groupActivities.first?.participants == ["main", "good_colleague", "a"])

            // ...into every participant's memory (the TS passes "main" along too).
            let gc = FriendMemory.getFriendBrain("good_colleague")
            let mem = try #require(gc.memories.last)
            #expect(mem.kind == "activity")
            #expect(mem.text.hasPrefix("Joined a huddle with "))
            #expect(gc.stats.groupActivities == 1)
            #expect(FriendMemory.getFriendBrain("a").stats.groupActivities == 1)

            // Cooldown: no new activity for ≥ 300s even when the roll hits.
            world.forcedRandom = 0
            cluster(flock)
            world.step(flock, 250_000)
            world.step(flock, 600)
            #expect(flock.groupActivity == nil)
            cluster(flock)
            world.step(flock, 360_000) // 250s + 360s > the longest cooldown (600s)
            world.step(flock, 600)
            world.step(flock, 600)
            world.forcedRandom = nil
            #expect(flock.groupActivity != nil)
        }
    }

    @Test(arguments: GroupActivityType.allCases)
    func everyActivityTypeRunsToCompletionInTheFlock(type: GroupActivityType) throws {
        try withWorld { world in
            let log = EventLog()
            let flock = makeFlock(friends: [friend("a")])
            cluster(flock, gap: 80)
            if type == .easterEggHunt { flock.setEasterMode(.on) }
            world.autoHideMs = 50
            let ids = ["main", "good_colleague", "a"]
            flock.groupActivity = createGroupActivity(type, ids, 720)
            let frames = world.run(flock, maxFrames: 6000) { flock.groupActivity == nil }
            #expect(frames > 0, "\(type) never finished")
            #expect(log.groupActivities.map(\.type) == [type.rawValue])
            #expect(log.groupActivities.first?.participants == ids)
            let memory = try #require(FriendMemory.getFriendBrain("a").memories.last { $0.kind == "activity" })
            #expect(memory.text.hasPrefix("Joined a \(type.rawValue) with "))
        }
    }

    @Test func cancellingMidActivityReleasesEveryoneWithoutRecordingIt() {
        withWorld { world in
            let log = EventLog()
            let flock = makeFlock(friends: [friend("a")])
            cluster(flock, gap: 80) // already gathered
            flock.groupActivity = createGroupActivity(.campfireCircle, ["main", "good_colleague", "a"], 720)
            world.run(flock, frames: 20)
            #expect(sheep(flock, "main").state == .idleCampfire)
            sheep(flock, "a").walkTarget = 123

            flock.cancelConversation()
            #expect(flock.groupActivity == nil)
            for id in ["main", "good_colleague", "a"] {
                #expect(sheep(flock, id).state == .idle, "\(id)")
                #expect(sheep(flock, id).walkTarget == nil, "\(id)")
                let d = sheep(flock, id).stateDuration
                #expect(d >= 1000 && d <= 3000)
            }
            #expect(log.groupActivities.isEmpty)
            #expect(FriendMemory.getFriendBrain("a").stats.groupActivities == 0)
        }
    }

    @Test func anEasterHuntIsScoredIntoTheEasterStats() {
        withWorld { world in
            let log = EventLog()
            let flock = makeFlock(friends: [friend("a")])
            cluster(flock, gap: 80)
            flock.setEasterMode(.on)
            world.autoHideMs = 50
            let ids = ["main", "good_colleague", "a"]
            flock.groupActivity = createGroupActivity(.easterEggHunt, ids, 720)
            // Sheep walk at 60px/s: hop each onto its assigned egg instead.
            let frames = world.run(flock, maxFrames: 6000) {
                if let activity = flock.groupActivity, activity.phase == .performing,
                   let assignments = activity.eggAssignments {
                    let eggs = flock.easterTheme.getEggPositions()
                    for id in ids {
                        if let idx = assignments[id] {
                            sheep(flock, id).x = eggs[idx].x - sheep(flock, id).displaySize / 2
                        }
                    }
                }
                return flock.groupActivity == nil
            }
            #expect(frames > 0)
            #expect(log.groupActivities.count == 1)
            #expect(log.groupActivities.first?.type == "easter_egg_hunt")

            let stats = EasterMemory.getStats()
            #expect(stats.huntsToday == 1)
            #expect(stats.eggsFoundToday > 0)
            #expect(stats.huntsCompleted == 1) // everything was collected
            #expect(stats.hunters["good_colleague"]?.sheepName == "Good Colleague")
            #expect(stats.hunters["a"]?.sheepName == "A")
            #expect(stats.hunters.values.reduce(0) { $0 + $1.eggsFoundToday } == stats.eggsFoundToday)
        }
    }

    @Test func turningEasterOffCancelsARunningHuntAndDiscardsTheEggsFoundSoFar() throws {
        // Ported as-is: the hunt's summary is only finalized when the hunt ends
        // (all eggs found / time up), so a hunt cancelled mid-way has an empty
        // finder list and nothing is scored.
        try withWorld { world in
            let log = EventLog()
            let flock = makeFlock(friends: [friend("a")])
            cluster(flock, gap: 80)
            flock.setEasterMode(.on)
            let ids = ["main", "good_colleague", "a"]
            let activity = createGroupActivity(.easterEggHunt, ids, 720)
            flock.groupActivity = activity
            world.run(flock) { activity.phase == .performing && !(activity.eggAssignments ?? [:]).isEmpty }
            // One sheep grabs its egg.
            let eggs = flock.easterTheme.getEggPositions()
            let idx = try #require(activity.eggAssignments?["a"])
            sheep(flock, "a").x = eggs[idx].x - DS / 2
            world.run(flock) { (activity.collectedEggs?.count ?? 0) >= 1 }
            #expect(activity.eggFinders?["a"]?.eggsFound == 1)

            flock.setEasterMode(.off)
            #expect(flock.groupActivity == nil)
            #expect(log.groupActivities.isEmpty) // cancelled early: not announced
            let stats = EasterMemory.getStats()
            #expect(stats.huntsToday == 0)
            #expect(stats.eggsFoundToday == 0)
        }
    }

    @Test func aHuntThatRunsOutOfTimeIsScoredWithTheEggsFound() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            cluster(flock, gap: 80)
            flock.setEasterMode(.on)
            world.autoHideMs = 50
            let ids = ["main", "good_colleague", "a"]
            let activity = createGroupActivity(.easterEggHunt, ids, 720)
            flock.groupActivity = activity
            // Sheep walk toward their eggs at 60px/s and would collect them all; instead pin
            // everyone to the left edge (out of reach of every egg) except one hop by `a`.
            world.run(flock, maxFrames: 6000) {
                guard flock.groupActivity != nil, activity.phase == .performing else { return flock.groupActivity == nil }
                if (activity.collectedEggs?.count ?? 0) == 0, let idx = activity.eggAssignments?["a"] {
                    let eggs = flock.easterTheme.getEggPositions()
                    sheep(flock, "a").x = eggs[idx].x - DS / 2
                    for id in ["main", "good_colleague"] { sheep(flock, id).x = 0 }
                } else {
                    for id in ids { sheep(flock, id).x = 0 }
                }
                return false
            }
            #expect(flock.groupActivity == nil)
            let stats = EasterMemory.getStats()
            #expect(stats.huntsToday == 1)
            #expect(stats.eggsFoundToday == 1)
            #expect(stats.huntsCompleted == 0) // not every egg was found
            #expect(stats.hunters["a"]?.huntsWon == 1)
            #expect(stats.lastWinnerName == "A")
        }
    }

    @Test func easterStatsConvertToTheSnapshotTheHudReads() throws {
        var stats = EasterStats()
        stats.eggsFoundTotal = 12
        stats.eggsFoundToday = 3
        stats.goldenEggsTotal = 2
        stats.huntsCompleted = 4
        stats.currentStreak = 2
        stats.bestStreak = 5
        stats.paintedEggsUsedTotal = 7
        stats.flockScore = 99
        stats.topHunterName = "Amy"
        stats.lastWinnerName = "Bo"
        let snapshot = try #require(Flock.snapshot(of: stats))
        #expect(snapshot.eggsFoundTotal == 12)
        #expect(snapshot.eggsFoundToday == 3)
        #expect(snapshot.goldenEggsTotal == 2)
        #expect(snapshot.huntsCompleted == 4)
        #expect(snapshot.currentStreak == 2)
        #expect(snapshot.bestStreak == 5)
        #expect(snapshot.paintedEggsUsedTotal == 7)
        #expect(snapshot.flockScore == 99)
        #expect(snapshot.topHunterName == "Amy")
        #expect(snapshot.lastWinnerName == "Bo")
    }

    @Test func turningEasterOffDuringOtherActivitiesLeavesThemAlone() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            cluster(flock)
            flock.groupActivity = createGroupActivity(.huddle, ["main", "good_colleague", "a"], 720)
            flock.setEasterMode(.off)
            #expect(flock.groupActivity != nil)
            world.run(flock, frames: 2)
        }
    }
}

@Suite("spectacles in the flock", .serialized)
struct FlockSpectacleTests {
    private func stage(extra: [FriendConfig] = [friend("a"), friend("b")],
                       scheduler: SchedulerStart = .quiet) -> Flock {
        let flock = makeFlock(friends: extra, scheduler: scheduler)
        quietStage(flock)
        flock.friendAIChat = nil
        return flock
    }

    private func pair(for type: SpectacleType) -> (String, String)? {
        (type == .showdown || type == .feast) ? ("a", "b") : nil
    }

    @Test func everySpectacleTypeStartsRunsAndEndsWithEvents() throws {
        for type in SpectacleType.allCases {
            try withWorld(seed: 7) { world in
                let log = EventLog()
                let flock = stage()
                #expect(flock.startSpectacle(type, pair(for: type)), "\(type)")
                let scene = try #require(flock.spectacle)
                #expect(scene.type == type)
                #expect(log.spectacleStarted == [type.rawValue])
                #expect(log.spectacleEnded.isEmpty)

                // Only one at a time.
                #expect(!flock.startSpectacle(.balloon))
                #expect(log.spectacleStarted == [type.rawValue])

                let frames = world.run(flock, maxFrames: 6000) { flock.spectacle == nil }
                #expect(frames > 0, "\(type) never ended")
                #expect(log.spectacleEnded == [type.rawValue])

                // The scheduler state is persisted (living state "spectacles").
                let state = LivingState.loadState("spectacles")
                #expect(state["lastFiredMs"]?.doubleValue == localMs(hour: 12))
                #expect(state["lastByType"]?[type.rawValue]?.doubleValue == localMs(hour: 12))
            }
        }
    }

    @Test func startingCancelsAConversationAndAnActivity() {
        withWorld { world in
            let flock = stage()
            #expect(flock.startScriptedConversation(
                [ConversationLine(speakerId: "a", text: "hm", duration: 60_000, delay: 0)], ["a"]))
            #expect(flock.startSpectacle(.wolf))
            #expect(flock.activeConversation == nil)
            world.run(flock, maxFrames: 3000) { flock.spectacle == nil }
            flock.groupActivity = createGroupActivity(.huddle, ["main", "good_colleague", "a"], 400)
            #expect(flock.startSpectacle(.balloon))
            #expect(flock.groupActivity == nil)
        }
    }

    @Test func aSpectacleThatNeedsCalmSheepRefusesWhenNobodyIsCalm() {
        withWorld { _ in
            let log = EventLog()
            let flock = Flock(W, H) // everyone still parachuting
            #expect(!flock.startSpectacle(.wolf))
            #expect(!flock.startSpectacle(.ufo))
            #expect(flock.spectacle == nil)
            #expect(log.spectacleStarted.isEmpty)
            // The balloon floats over an empty sky just fine.
            #expect(flock.startSpectacle(.balloon))
            #expect(log.spectacleStarted == ["balloon"])
        }
    }

    @Test func endingRecordsTheFlocksMemoryAndADiaryEntryWithoutMain() throws {
        try withWorld { world in
            let log = EventLog()
            let flock = stage()
            flock.startSpectacle(.wolf)
            world.run(flock, maxFrames: 3000) { flock.spectacle == nil }
            let journal = try Memory.getTodayJournal()
            #expect(journal.contains("*A wolf scare happened on the desktop! The flock is still talking about it.*"))
            let a = FriendMemory.getFriendBrain("a")
            #expect(a.memories.contains { $0.text.hasPrefix("Joined a wolf scare with ") })
            #expect(a.stats.groupActivities == 1)
            // "main" has no friend brain: a spectacle must not mint one (a chat between main and a
            // friend would, exactly like the TS, so only check runs without one).
            if !log.conversations.contains(where: { $0.idA == "main" || $0.idB == "main" }) {
                #expect(!FileManager.default.fileExists(atPath: Paths.friends.appendingPathComponent("main.json").path))
            }
        }
    }

    @Test func aUfoRecordsOnlyItsAbductee() throws {
        try withWorld(seed: 3) { world in
            let flock = stage()
            // Force the abductee: the roll picks the third calm sheep.
            world.forcedRandom = 0.6
            flock.startSpectacle(.ufo)
            world.forcedRandom = nil
            let target = try #require(flock.spectacle?.targetId)
            #expect(target == "a") // ["main", "good_colleague", "a", "b"][2]
            world.run(flock, maxFrames: 3000) { flock.spectacle == nil }
            let journalText = try Memory.getTodayJournal()
            #expect(journalText.contains("*A UFO encounter happened"))
            #expect(FriendMemory.getFriendBrain("a").stats.groupActivities == 1)
            #expect(FriendMemory.getFriendBrain("b").stats.groupActivities == 0)
            #expect(FriendMemory.getFriendBrain("good_colleague").stats.groupActivities == 0)
        }
    }

    @Test func aUfoThatAbductedMainWritesNoFriendMemory() throws {
        try withWorld { world in
            let log = EventLog()
            let flock = stage()
            world.forcedRandom = 0
            flock.startSpectacle(.ufo)
            world.forcedRandom = nil
            #expect(flock.spectacle?.targetId == "main")
            world.run(flock, maxFrames: 3000) { flock.spectacle == nil }
            let journal = try Memory.getTodayJournal()
            #expect(!journal.contains("UFO encounter"))
            if !log.conversations.contains(where: { $0.idA == "main" || $0.idB == "main" }) {
                #expect(!FileManager.default.fileExists(atPath: Paths.friends.appendingPathComponent("main.json").path))
            }
        }
    }

    @Test func showdownResolutionReachesTheDramaCallbackWithThePairAndOutcome() throws {
        for reconcile in [true, false] {
            try withWorld { world in
                let flock = stage()
                var resolved: [(String, String, Bool)] = []
                flock.onShowdownResolved = { pair, reconciled in resolved.append((pair.0, pair.1, reconciled)) }
                flock.startSpectacle(.showdown, ("a", "b"))
                let scene = try #require(flock.spectacle)
                // Steer the outcome (the roll < 0.5 ⇒ reconciled): wait for the phase flip, then force it.
                var forced = false
                world.run(flock, maxFrames: 3000) {
                    if !forced, scene.phase == .perform, scene.timer > 7900 {
                        forced = true
                        world.forcedRandom = reconcile ? 0.1 : 0.9
                    }
                    if scene.phase == .exit { world.forcedRandom = nil }
                    return flock.spectacle == nil
                }
                #expect(resolved.count == 1)
                #expect(resolved[0].0 == "a" && resolved[0].1 == "b")
                #expect(resolved[0].2 == reconcile)
                #expect(scene.data["reconciled"] == (reconcile ? 1.0 : 0.0))
                // Only the duelists are remembered (main and spectators are not).
                #expect(FriendMemory.getFriendBrain("a").stats.groupActivities == 1)
                #expect(FriendMemory.getFriendBrain("good_colleague").stats.groupActivities == 0)
                let journalText = try Memory.getTodayJournal()
                #expect(journalText.contains("*A high-noon showdown happened"))
            }
        }
    }

    @Test func feastSeatsThePairAsHostsAndIsRecordedForEveryone() throws {
        try withWorld { world in
            let flock = stage()
            flock.startSpectacle(.feast, ("a", "b"))
            world.run(flock, maxFrames: 3000) { flock.spectacle == nil }
            let journalText = try Memory.getTodayJournal()
            #expect(journalText.contains("*A reconciliation feast happened"))
            for id in ["good_colleague", "a", "b"] {
                #expect(FriendMemory.getFriendBrain(id).stats.groupActivities == 1, "\(id)")
            }
        }
    }

    @Test func theMerchantsGiftGoesThroughTheSaveSeam() {
        withWorld { world in
            let flock = stage()
            var saved: [[String]] = []
            flock.saveMainAccessories = { saved.append($0); return true }
            flock.startSpectacle(.merchant)
            world.run(flock, maxFrames: 3000) { flock.spectacle == nil }
            #expect(saved.count == 1)
            #expect(saved[0].count == 1)
            #expect(SpectacleRenderData.GIFT_POOL.contains(saved[0][0]))
        }
    }

    @Test func theSchedulerRollsEveryFiveMinutesOnlyByDayAndOnlyOutsideAMinimumGap() {
        // Fresh state + long uptime: the pity timer fires on the first 5-minute check.
        withWorld { world in
            let log = EventLog()
            let flock = stage(scheduler: .asIs)
            world.step(flock, SPECTACLE.CHECK_INTERVAL_MS - 1000)
            #expect(log.spectacleStarted.isEmpty)
            world.forcedRandom = 0.99
            world.step(flock, 1000)
            world.forcedRandom = nil
            #expect(log.spectacleStarted.count == 1)
        }
        // By night: never.
        withWorld(hour: 22) { world in
            let log = EventLog()
            let flock = stage(scheduler: .asIs)
            world.step(flock, SPECTACLE.CHECK_INTERVAL_MS)
            world.step(flock, SPECTACLE.CHECK_INTERVAL_MS)
            #expect(log.spectacleStarted.isEmpty)
        }
        // A spectacle fired an hour ago (persisted from the last run): inside the 20h gap.
        withWorld { world in
            let log = EventLog()
            let fired = world.now - 3_600_000
            LivingState.saveState("spectacles", .object(["lastFiredMs": .number(fired), "lastByType": .object([:])]))
            let flock = stage(scheduler: .asIs)
            world.forcedRandom = 0
            world.step(flock, SPECTACLE.CHECK_INTERVAL_MS)
            world.forcedRandom = nil
            #expect(log.spectacleStarted.isEmpty)
        }
        // A persisted state that predates the gap by a day allows one again.
        withWorld { world in
            let log = EventLog()
            LivingState.saveState("spectacles", .object([
                "lastFiredMs": .number(world.now - 25 * 3_600_000),
                "lastByType": .object(["wolf": .number(world.now - 25 * 3_600_000)]),
            ]))
            let flock = stage(scheduler: .asIs)
            world.forcedRandom = 0 // lucky roll
            world.step(flock, SPECTACLE.CHECK_INTERVAL_MS)
            world.forcedRandom = nil
            #expect(log.spectacleStarted.count == 1)
            #expect(log.spectacleStarted.first != "wolf") // wolf is on cooldown for a week
        }
    }

    @Test func aBrokenLivingStateFallsBackToTheDefaultScheduler() {
        withWorld { world in
            try? write("not json", to: Paths.livingState("spectacles"))
            let log = EventLog()
            let flock = stage(scheduler: .asIs)
            world.forcedRandom = 0.99
            world.step(flock, SPECTACLE.CHECK_INTERVAL_MS)
            world.forcedRandom = nil
            #expect(log.spectacleStarted.count == 1) // fresh state ⇒ pity timer
        }
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

@Suite("draw", .serialized)
struct FlockDrawTests {
    private func frame(_ flock: Flock) -> Canvas {
        let canvas = Canvas()
        canvas.beginFrame()
        flock.draw(canvas)
        return canvas
    }

    private func landed(_ flock: Flock) {
        for id in flock.getCharacterIds() { park(sheep(flock, id)) }
    }

    @Test func aBareFlockDrawsTheThemeAndSheepGroupsInBackToFrontOrder() {
        withWorld { _ in
            let flock = Flock(W, H)
            landed(flock)
            let canvas = frame(flock)
            #expect(canvas.groups.map(\.key) == [
                "easter:bg", "summer:bg", "easter:mid", "summer:mid", "sheep:main", "easter:fg", "summer:fg",
            ])
            #expect(canvas.groups.allSatisfy { $0.layer == .world })
            // Themes are off in September; the main sheep draws its sprite.
            #expect(canvas.groups.first { $0.key == "sheep:main" }?.ops.isEmpty == false)
            #expect(canvas.groups.first { $0.key == "easter:bg" }?.ops.isEmpty == true)
        }
    }

    @Test func friendsGetOneGroupEachInMapOrderAfterMain() {
        withWorld { _ in
            let flock = makeFlock(friends: [friend("zed"), friend("amy")])
            landed(flock)
            let keys = frame(flock).groups.map(\.key)
            let sheepKeys = keys.filter { $0.hasPrefix("sheep:") }
            #expect(sheepKeys == ["sheep:main", "sheep:good_colleague", "sheep:zed", "sheep:amy"])
            let order = keys.firstIndex(of: "sheep:amy")!
            #expect(keys.firstIndex(of: "summer:mid")! < keys.firstIndex(of: "sheep:main")!)
            #expect(order < keys.firstIndex(of: "easter:fg")!)
        }
    }

    @Test func aRunningSpectacleDrawsBetweenTheSheepAndTheForeground() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            flock.startSpectacle(.balloon)
            world.step(flock)
            let keys = frame(flock).groups.map(\.key)
            let spectacle = keys.firstIndex(of: "spectacle")
            #expect(spectacle != nil)
            #expect(keys.firstIndex(of: "sheep:a")! < spectacle!)
            #expect(spectacle! < keys.firstIndex(of: "easter:fg")!)

            world.run(flock, maxFrames: 3000) { flock.spectacle == nil }
            #expect(!frame(flock).groups.map(\.key).contains("spectacle"))
        }
    }

    @Test func shearingDayAddsOneTilePerSheepInsideTheSpectacleGroup() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            world.autoHideMs = nil
            flock.startSpectacle(.shearing)
            world.step(flock)
            let keys = frame(flock).groups.map(\.key)
            let shorn = keys.filter { $0.hasPrefix("spectacle:shorn:") }
            #expect(shorn == ["spectacle:shorn:main", "spectacle:shorn:good_colleague", "spectacle:shorn:a"])
        }
    }

    @Test func visibleBubblesDrawLastInTheOverlayLayer() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            world.autoHideMs = nil
            flock.mainBubble.show("hello there", duration: 600_000)
            bubble(flock, "a").show("me too", duration: 600_000)
            world.step(flock) // positions the bubbles
            let canvas = frame(flock)
            let keys = canvas.groups.map(\.key)
            #expect(keys.suffix(2) == ["bubble:main", "bubble:a"])
            for g in canvas.groups {
                #expect(g.layer == (g.key.hasPrefix("bubble:") ? .overlay : .world), "\(g.key)")
            }
            #expect(!keys.contains("bubble:good_colleague"))
            let main = canvas.groups.first { $0.key == "bubble:main" }!
            #expect(!main.ops.isEmpty)
            // The bubble sits above its sheep (anchored groups record relative
            // to their anchor, so map the bounds back to canvas space).
            let a = main.anchor ?? .zero
            let abs = main.bounds.offsetBy(dx: a.x, dy: a.y)
            #expect(abs.maxY <= flock.main.y + 30)
            #expect(Swift.abs(abs.midX - (flock.main.x + flock.main.displaySize / 2)) < 60)
        }
    }

    @Test func aHiddenBubbleIsNotDrawnAndNeitherIsBeforeItsFirstPosition() {
        withWorld { _ in
            let flock = makeFlock()
            landed(flock)
            flock.mainBubble.show("fresh", duration: 600_000)
            // No update yet → the bubble has no position, but the group exists and is empty.
            let canvas = frame(flock)
            #expect(canvas.groups.first { $0.key == "bubble:main" }?.ops.isEmpty == true)
            flock.mainBubble.hide()
            #expect(!frame(flock).groups.map(\.key).contains("bubble:main"))
        }
    }

    @Test func campfiresAtTheGroundGetTheirOwnTileWhileTheSheepStandsOnAWindow() {
        withWorld { world in
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            let a = sheep(flock, "a")
            a.state = .idleCampfire
            a.stateDuration = 1e12
            a.y = a.groundY - 300 // up on a window
            world.autoHideMs = nil
            world.step(flock)
            let keys = frame(flock).groups.map(\.key)
            #expect(keys.contains("sheep:a"))
            #expect(keys.contains("sheep:a:ground"))
        }
    }

    @Test func themesDrawIntoTheirOwnGroupsWhenActive() {
        withWorld { world in
            let flock = makeFlock()
            landed(flock)
            flock.setEasterMode(.on)
            flock.setSummerMode(.on)
            world.step(flock)
            let canvas = frame(flock)
            for key in ["easter:bg", "summer:bg", "easter:mid", "summer:mid", "easter:fg", "summer:fg"] {
                // Themes draw into the group itself or into per-element sub-groups
                // ("<key>:…") so moving particles get small anchored tiles.
                let ops = canvas.groups.filter { $0.key == key || $0.key.hasPrefix(key + ":") }.flatMap(\.ops)
                #expect(!ops.isEmpty, "\(key)")
            }
        }
    }

    @Test func nightAndWeatherEffectsAreSpriteKitNativeAndAttachToTheScene() throws {
        try withWorld(hour: 23) { world in
            let scene = OverlayScene(size: CGSize(width: W, height: H))
            scene.backingScale = 2
            sceneKeepAlive.scenes.append(scene)
            let flock = makeFlock(friends: [friend("a")])
            quietStage(flock)
            flock.attach(to: scene)
            #expect(scene.nightBackLayer.children.count == 1)
            #expect(scene.nightFrontLayer.children.count == 1)
            #expect(scene.weatherLayer.children.count == 1)

            flock.setWeatherCondition("rain")
            world.run(flock, frames: 5)
            let canvas = frame(flock)
            // Never drawn into the canvas...
            #expect(!canvas.groups.map(\.key).contains { $0.contains("night") || $0.contains("weather") })
            // ...but their nodes are live: stars by night, rain in the weather layer.
            let back = try #require(scene.nightBackLayer.children.first)
            #expect(!back.isHidden)
            #expect(back.children.count > 30)
            let rain = try #require(scene.weatherLayer.children.first)
            #expect(!rain.isHidden)
            #expect(rain.children.filter { !$0.isHidden }.count == 50)

            flock.setWeatherCondition(nil)
            world.step(flock)
            _ = frame(flock)
            #expect(rain.isHidden)
        }
    }

    @Test func byDayTheNightLayersStayHidden() throws {
        try withWorld(hour: 13) { world in
            let scene = OverlayScene(size: CGSize(width: W, height: H))
            scene.backingScale = 2
            sceneKeepAlive.scenes.append(scene)
            let flock = makeFlock()
            flock.attach(to: scene)
            world.step(flock)
            _ = frame(flock)
            let back = try #require(scene.nightBackLayer.children.first)
            let front = try #require(scene.nightFrontLayer.children.first)
            #expect(back.isHidden)
            #expect(front.isHidden)
        }
    }
}

@Suite("whole-flock simulation", .serialized)
struct FlockSimulationTests {
    /// Every sheep keeps at least half of its box on screen (parachuting sheep start just above it;
    /// a stacked top is centered on its bottom sheep, so it may overhang the edge by a few pixels).
    private func onScreen(_ flock: Flock) -> String? {
        for id in flock.getCharacterIds() {
            let s = sheep(flock, id)
            let half = s.displaySize / 2
            let ok = s.x.isFinite && s.y.isFinite
                && s.x >= -half && s.x + half <= W
                && s.y >= -s.displaySize - 0.5 && s.y + half <= H
            if !ok { return "\(id) left the screen at (\(s.x), \(s.y)) in state \(s.state)" }
        }
        return nil
    }

    private func runSimulation(seed: UInt64, hour: Int, minute: Int = 0, frames: Int = 20_000,
                               chaos: Bool = false, themed: Bool = false) -> (spoke: Int, log: EventLog) {
        withWorld(seed: seed, hour: hour) { world in
            world.now = localMs(hour: hour, minute: minute)
            let log = EventLog()
            let flock = makeFlock(friends: [
                friend("amy", color: .pink, personality: .wholesome, scale: nil),
                friend("bo", color: .blue, personality: .chaotic, scale: nil),
                friend("cy", color: .gold, personality: .snarky, scale: nil),
                friend("dee", color: .purple, personality: .passiveAggressive, scale: nil),
            ], scheduler: .asIs)
            flock.friendAIChat = nil
            var canvas = Canvas()
            var spoke = 0
            var lastText: [String: String] = [:]

            for frame in 1...frames {
                if chaos { self.chaosEvent(frame, flock, world) }
                if themed { self.themedEvent(frame, flock) }
                world.step(flock)
                if let problem = onScreen(flock) {
                    Issue.record("frame \(frame): \(problem)")
                    break
                }
                for id in flock.getCharacterIds() {
                    let text = bubble(flock, id).visible ? bubble(flock, id).currentText : ""
                    if text != lastText[id] && !text.isEmpty { spoke += 1 }
                    lastText[id] = text
                }
                if frame % 25 == 0 {
                    canvas = Canvas()
                    canvas.beginFrame()
                    flock.draw(canvas)
                }
            }
            _ = canvas
            return (spoke, log)
        }
    }

    /// Season themes and weather changes for the themed run.
    private func themedEvent(_ frame: Int, _ flock: Flock) {
        switch frame {
        case 1:
            flock.setEasterMode(.on)
            flock.setSummerMode(.on)
            flock.setWeatherCondition("rain", 20)
        case 6000: flock.setWeatherCondition("snow", 0)
        case 9000: flock.setWeatherCondition("clear", 25)
        case 12000: flock.setEasterMode(.off)
        case 15000: flock.setSummerMode(.off)
        case 17000: flock.setWeatherCondition(nil)
        default: break
        }
    }

    /// Scheduled provocations for the chaos run.
    private func chaosEvent(_ frame: Int, _ flock: Flock, _ world: World) {
        switch frame {
        case 1500: flock.startSpectacle(.wolf)
        case 3200: flock.triggerStampede(700, 0)
        case 5000:
            flock.main.grab()
            flock.main.y = 120
            flock.main.release() // very high: trampoline
            flock.onTrampolineStarted(flock.main)
        case 6500: flock.startSpectacle(.ufo)
        case 8500:
            let ids = flock.getCharacterIds().filter { $0 != "main" }
            let top = sheep(flock, ids[0]), bottom = sheep(flock, ids[1])
            top.grab()
            top.x = bottom.x
            top.y = bottom.y - 50
            if let target = flock.tryStack(top) {
                top.stackOn(target)
                flock.onSheepStacked(top, target)
            } else {
                top.release()
            }
        case 10000: flock.startSpectacle(.balloon)
        case 11500: flock.startSpectacle(.merchant)
        case 13000:
            let ids = flock.getCharacterIds().filter { $0 != "main" }
            flock.startSpectacle(.showdown, (ids[0], ids[1]))
        case 14500:
            let ids = flock.getCharacterIds().filter { $0 != "main" }
            flock.startSpectacle(.feast, (ids[2], ids[3]))
        case 16500: flock.startSpectacle(.shearing)
        case 18000:
            flock.setEasterMode(.on)
            flock.groupActivity = createGroupActivity(.easterEggHunt, Array(flock.getCharacterIds().prefix(3)), 700)
        case 19000: flock.setEasterMode(.off)
        default: break
        }
    }

    /// (seed, hour, minute) — the clock starts there and runs 320s of virtual time; 19:57 crosses into
    /// night (stars, fireflies, the nightfall comment), 22:00 and 23:50 are night, 3:55 crosses into morning.
    @Test(arguments: [
        (UInt64(11), 12, 0), (UInt64(29), 19, 57), (UInt64(3), 6, 30), (UInt64(7), 22, 0),
        (UInt64(13), 23, 50), (UInt64(17), 14, 0), (UInt64(23), 8, 0), (UInt64(31), 3, 55),
    ])
    func twentyThousandFramesWithFourFriendsKeepsEveryoneOnScreen(seed: UInt64, hour: Int, minute: Int) {
        let result = runSimulation(seed: seed, hour: hour, minute: minute)
        #expect(result.spoke > 0, "the flock never said anything")
    }

    @Test func aThemedRunWithSeasonsAndWeatherKeepsEveryoneOnScreen() {
        let result = runSimulation(seed: 9, hour: 13, themed: true)
        #expect(result.spoke > 0)
        #expect(result.log.weather.compactMap { $0 } == ["rain", "snow", "clear"])
    }

    @Test func aChaoticTwentyThousandFramesWithEveryProvocationKeepsEveryoneOnScreen() {
        let result = runSimulation(seed: 5, hour: 12, chaos: true)
        #expect(result.spoke > 0)
        let started = result.log.spectacleStarted
        // The scheduled spectacles that could start did (the stage is busy for long stretches).
        #expect(started.contains("wolf"))
        #expect(started.count == result.log.spectacleEnded.count || started.count == result.log.spectacleEnded.count + 1)
    }
}

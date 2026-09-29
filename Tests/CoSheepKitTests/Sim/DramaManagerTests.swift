import Foundation
import Testing
@testable import CoSheepKit

// No TS tests exist for drama-manager.ts: these pin the ported behavior. The
// manager runs against a real (headless) Flock, a temp `Paths.root`, a virtual
// clock and scripted dice, and `tick()` is driven directly (the 60s timer is
// only started, never waited on).

private let W = 1512.0
private let H = 982.0
private let HOUR = 3_600_000.0
private let MINUTE = 60_000.0
/// 2026-09-29T12:00:00Z (drama.json keys its day on the UTC date).
private let NOW = 1_790_683_200_000.0

/// Scripted `Math.random()`: `script` is handed out first, then `tail` (0.99
/// misses every `< p` gate).
private final class Dice {
    var script: [Double] = []
    var tail = 0.99

    func next() -> Double { script.isEmpty ? tail : script.removeFirst() }
}

private final class Ticker {
    var now = NOW
}

/// Records `drama-state-changed` bus events.
private final class DramaEvents {
    struct Change: Equatable {
        var idA: String, idB: String, from: String, to: String, cause: String
    }

    private(set) var changes: [Change] = []
    private var unsubscribe: (() -> Void)?

    init() {
        unsubscribe = bus.on(.dramaStateChanged) { [unowned self] event in
            if case .dramaStateChanged(let a, let b, let from, let to, let cause) = event {
                self.changes.append(Change(idA: a, idB: b, from: from, to: to, cause: cause))
            }
        }
    }

    isolated deinit {
        unsubscribe?()
    }
}

/// A flock (main + the given friends, parked calm and 270px apart), a drama
/// manager over it, and the swapped globals. Must be `close()`d.
private final class Stage {
    let clock = Ticker()
    let dice = Dice()
    let flock: Flock
    let manager: DramaManager
    private let savedRandom: () -> Double
    /// Every spectacle the manager asked for.
    private(set) var spectacles: [(type: SpectacleType, pair: (String, String))] = []

    init(friends: [String] = ["a", "b"]) {
        savedRandom = SimRandom.source
        let c = clock, d = dice
        SimClock.nowSource = { c.now }
        SimRandom.source = { d.next() }

        flock = Flock(W, H)
        for id in friends {
            flock.addFriend(FriendConfig(id: id, name: id.uppercased(), color: .pink,
                                         personality: .wholesome, accessories: nil, scale: 1))
        }
        for (i, id) in flock.getCharacterIds().enumerated() {
            Self.park(flock.getCharacter(id)!.sheep, x: 40 + Double(i) * 270)
        }
        manager = DramaManager(flock)
        manager.onDramaTriggeredSpectacle = { [unowned self] type, pair in
            self.spectacles.append((type, pair))
        }
    }

    /// `"<type> <idA>|<idB>"` per requested spectacle.
    var spectacleKeys: [String] {
        spectacles.map { "\($0.type.rawValue) \($0.pair.0)|\($0.pair.1)" }
    }

    func close() {
        manager.stop()
        SimRandom.source = savedRandom
    }

    var now: Double {
        get { clock.now }
        set { clock.now = newValue }
    }

    /// Land a sheep where it stands, calm, for (practically) ever.
    static func park(_ sheep: Sheep, x: Double) {
        sheep.x = x
        sheep.y = sheep.groundY
        sheep.state = .idle
        sheep.stateTimer = 0
        sheep.stateDuration = 1e12
        sheep.walkTarget = nil
    }

    func sheep(_ id: String) -> Sheep { flock.getCharacter(id)!.sheep }

    /// `n` sparks that miss every threshold (one per pair, `n(n-1)/2` for `n` characters).
    static func sparks(_ characters: Int) -> [Double] {
        Array(repeating: 0.9, count: characters * (characters - 1) / 2)
    }

    /// Seed drama.json (the TS shape) so `start()` loads it.
    func seed(_ root: URL, pairs: [(String, RelationshipState, Double)],
              petting: [String: Int] = [:], date: String = "2026-09-29") throws {
        var pairsJSON: [String: JSONValue] = [:]
        for (key, state, since) in pairs {
            pairsJSON[key] = .object(["state": .string(state.rawValue), "since": .number(since)])
        }
        var pettingJSON: [String: JSONValue] = [:]
        for (id, n) in petting { pettingJSON[id] = .number(Double(n)) }
        try JSONFile.write(JSONValue.object([
            "pairs": .object(pairsJSON),
            "pettingToday": .object(pettingJSON),
            "pettingDate": .string(date),
            "log": .array([]),
        ]), to: root.appendingPathComponent("drama.json"))
    }
}

private func dramaJSON(_ root: URL) throws -> JSONValue {
    try readJSON(root.appendingPathComponent("drama.json"))
}

extension BrainTests {
    @Suite("drama manager")
    struct DramaManagerTests {
        // MARK: ISO helpers

        @Test func isoTimestampMatchesJsToISOString() {
            #expect(SimISO.timestamp(0) == "1970-01-01T00:00:00.000Z")
            #expect(SimISO.timestamp(1_000_000_000_123) == "2001-09-09T01:46:40.123Z")
            #expect(SimISO.timestamp(NOW + 789) == "2026-09-29T12:00:00.789Z")
            #expect(SimISO.timestamp(-1) == "1969-12-31T23:59:59.999Z")
            #expect(SimISO.day(NOW) == "2026-09-29")
            #expect(SimISO.day(NOW + 12 * HOUR) == "2026-09-30")
        }

        // MARK: persistence (drama.json)

        @Test func startWithoutSavedStateKeepsFreshDefaults() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.manager.start()
                #expect(s.manager.state.pairs.isEmpty)
                #expect(s.manager.state.pettingToday.isEmpty)
                #expect(s.manager.state.pettingDate == "2026-09-29")
                #expect(s.manager.state.log.isEmpty)
            }
        }

        @Test func stateRoundTripsThroughDramaJsonInTheTsShape() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                let saved: JSONValue = .object([
                    "pairs": .object(["a|b": .object(["state": .string("feud"), "since": .number(1000)])]),
                    "pettingToday": .object(["a": .number(3)]),
                    "pettingDate": .string("2026-09-29"),
                    "log": .array([.object([
                        "at": .string("2026-09-29T10:00:00.000Z"),
                        "text": .string("a & b: tension -> feud (spark)"),
                    ])]),
                ])
                try JSONFile.write(saved, to: root.appendingPathComponent("drama.json"))

                s.manager.start()
                #expect(s.manager.state.pairs["a|b"] == DramaPairRecord(state: .feud, since: 1000))
                #expect(s.manager.state.pettingToday == ["a": 3])
                #expect(s.manager.state.pettingDate == "2026-09-29")
                #expect(s.manager.state.log == [DramaLogEntry(
                    at: "2026-09-29T10:00:00.000Z", text: "a & b: tension -> feud (spark)")])

                // Any persist writes the very same shape back.
                s.manager.onFriendRemoved("nobody")
                #expect(try dramaJSON(root) == saved)

                // ...which a fresh manager loads to the same state.
                let second = DramaManager(s.flock)
                second.start()
                defer { second.stop() }
                #expect(second.state == s.manager.state)
            }
        }

        @Test func aSavedFileWithoutPairsIsIgnored() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try write(#"{"pettingToday": {"a": 9}, "pettingDate": "2026-09-29"}"#,
                          to: root.appendingPathComponent("drama.json"))
                s.manager.start()
                #expect(s.manager.state.pairs.isEmpty)
                #expect(s.manager.state.pettingToday.isEmpty)
            }
        }

        @Test func malformedPairRecordsAreDroppedAndMissingFieldsDefault() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try write("""
                {"pairs": {"a|b": {"state": "weird", "since": 1},
                           "a|c": {"state": "warm"},
                           "b|c": {"state": "warm", "since": 5}}}
                """, to: root.appendingPathComponent("drama.json"))
                s.manager.start()
                #expect(s.manager.state.pairs == ["b|c": DramaPairRecord(state: .warm, since: 5)])
                #expect(s.manager.state.pettingToday.isEmpty)
                #expect(s.manager.state.pettingDate == "2026-09-29") // reset on load
                #expect(s.manager.state.log.isEmpty)
            }
        }

        @Test func aNewDayClearsTodaysPetting() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [], petting: ["a": 3], date: "2026-09-28")
                s.manager.start()
                #expect(s.manager.state.pettingToday.isEmpty)
                #expect(s.manager.state.pettingDate == "2026-09-29")
            }
        }

        // MARK: bus and lifecycle

        @Test func pettedEventsCountPerFriendAndRollOverAtUtcMidnight() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.manager.start()
                bus.emit(.sheepPetted(id: "a"))
                bus.emit(.sheepPetted(id: "a"))
                bus.emit(.sheepPetted(id: "b"))
                #expect(s.manager.state.pettingToday == ["a": 2, "b": 1])

                s.now = NOW + 13 * HOUR // 2026-09-30 01:00Z
                bus.emit(.sheepPetted(id: "b"))
                #expect(s.manager.state.pettingToday == ["b": 1])
                #expect(s.manager.state.pettingDate == "2026-09-30")
            }
        }

        @Test func stopUnsubscribesAndHandsTheFilterBack() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                #expect(s.flock.participantFilter == nil)
                s.manager.start()
                #expect(s.flock.participantFilter != nil)

                s.manager.stop()
                #expect(s.flock.participantFilter == nil)
                bus.emit(.sheepPetted(id: "a"))
                #expect(s.manager.state.pettingToday.isEmpty)
            }
        }

        @Test func startingTwiceDoesNotDoubleCount() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.manager.start()
                s.manager.start()
                bus.emit(.sheepPetted(id: "a"))
                #expect(s.manager.state.pettingToday == ["a": 1])
            }
        }

        @Test func theFilterDropsFeudersFromGroupActivities() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .feud, NOW), ("a|c", .tension, NOW), ("b|c", .warm, NOW)])
                s.manager.start()
                let filter = try #require(s.flock.participantFilter)
                #expect(filter(["a", "b", "c"]) == ["a", "c"])
                #expect(filter(["b", "a", "c"]) == ["b", "c"])
                #expect(filter(["b", "c"]) == ["b", "c"])   // only feuds block
                #expect(filter(["a", "c"]) == ["a", "c"])
                #expect(filter(["a"]) == ["a"])
                #expect(filter([]) == [])
            }
        }

        // MARK: forceFeud

        @Test func forceFeudPicksTheFirstNonFeudFriendPairAndNeverMain() {
            withBrainRoot { root in
                let s = Stage(friends: ["a", "b", "c"])
                defer { s.close() }
                let events = DramaEvents()
                s.dice.tail = 0.5 // narration (>= 0.3) stays quiet

                #expect(s.manager.forceFeud() == "a|b")
                #expect(s.manager.state.pairs["a|b"] == DramaPairRecord(state: .feud, since: NOW))
                #expect(s.manager.state.log.last?.text == "a & b: neutral -> feud (debug)")
                #expect(s.manager.state.log.last?.at == "2026-09-29T12:00:00.000Z")
                #expect(events.changes == [.init(idA: "a", idB: "b", from: "neutral", to: "feud", cause: "debug")])

                #expect(s.manager.forceFeud() == "a|c")
                #expect(s.manager.forceFeud() == "b|c")
                #expect(s.manager.forceFeud() == nil)
                #expect(s.manager.state.pairs.keys.sorted() == ["a|b", "a|c", "b|c"])

                let file = try? dramaJSON(root)
                #expect(file?["pairs"]?["a|b"]?["state"] == .string("feud"))
            }
        }

        @Test func forceFeudNeedsTwoFriends() {
            withBrainRoot { _ in
                let s = Stage(friends: ["a"])
                defer { s.close() }
                #expect(s.manager.forceFeud() == nil)
                #expect(s.manager.state.pairs.isEmpty)
            }
        }

        @Test func forceFeudFromTensionRecordsTheRealFromState() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .tension, NOW - HOUR)])
                s.manager.start()
                let events = DramaEvents()
                s.dice.tail = 0.5
                #expect(s.manager.forceFeud() == "a|b")
                #expect(events.changes.first?.from == "tension")
            }
        }

        @Test func aFeudStartsWithTheFeudStartScript() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.dice.script = [0.99] // pickDramaScript: the second feud_start template
                s.dice.tail = 0.5
                _ = s.manager.forceFeud()
                let convo = s.flock.activeConversation
                #expect(convo?.participants == ["a", "b"])
                #expect(convo?.lines.map(\.text) == [
                    "I saw what you did at the campfire.",
                    "Oh, we're doing THIS now?",
                    "We are ABSOLUTELY doing this now.",
                ])
                #expect(convo?.lines.map(\.speakerId) == ["a", "b", "a"])
            }
        }

        // MARK: friend removal

        @Test func onFriendRemovedPrunesPairsAndPettingAndPersists() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .feud, 1), ("a|c", .warm, 2), ("b|c", .tension, 3)],
                           petting: ["a": 1, "b": 2])
                s.manager.start()

                s.manager.onFriendRemoved("a")
                #expect(s.manager.state.pairs == ["b|c": DramaPairRecord(state: .tension, since: 3)])
                #expect(s.manager.state.pettingToday == ["b": 2])

                let file = try dramaJSON(root)
                #expect(file["pairs"]?.objectValue?.keys.sorted() == ["b|c"])
                #expect(file["pettingToday"] == .object(["b": .number(2)]))
            }
        }

        @Test func onFriendRemovedLeavesUnrelatedFeudsAlone() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .feud, 1)])
                s.manager.start()
                s.manager.onFriendRemoved("zed")
                #expect(s.manager.state.pairs["a|b"]?.state == .feud)
            }
        }

        @Test func getPairStatesReportsTimeInState() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .warm, NOW - 5 * MINUTE)])
                s.manager.start()
                let states = s.manager.getPairStates()
                #expect(states["a|b"]?.state == .warm)
                #expect(states["a|b"]?.sinceMs == 5 * MINUTE)
            }
        }

        // MARK: tick

        @Test func tickNeedsTwoCharacters() {
            withBrainRoot { root in
                let s = Stage(friends: [])
                defer { s.close() }
                s.manager.start()
                s.manager.tick()
                #expect(s.manager.state.pairs.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("drama.json").path))
            }
        }

        @Test func tickRegistersEveryPairAsNeutralAndPersists() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                s.manager.start()
                s.dice.script = Stage.sparks(3)
                s.manager.tick()
                #expect(s.manager.state.pairs.keys.sorted() == ["a|b", "a|main", "b|main"])
                #expect(s.manager.state.pairs.values.allSatisfy { $0 == DramaPairRecord(state: .neutral, since: NOW) })
                let file = try dramaJSON(root)
                #expect(file["pairs"]?.objectValue?.count == 3)
            }
        }

        @Test func pettingGapTurnsIntoJealousyTension() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .neutral, NOW - HOUR)])
                s.manager.start()
                let events = DramaEvents()
                for _ in 0..<5 { bus.emit(.sheepPetted(id: "a")) }

                s.dice.script = Stage.sparks(3)
                s.manager.tick()
                #expect(s.manager.state.pairs["a|b"] == DramaPairRecord(state: .tension, since: NOW))
                #expect(s.manager.state.log.last?.text == "a & b: neutral -> tension (jealousy)")
                #expect(events.changes == [
                    .init(idA: "a", idB: "b", from: "neutral", to: "tension", cause: "jealousy"),
                ])
            }
        }

        @Test func affinityFromTheFriendBrainsWarmsAPair() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                for _ in 0..<4 { FriendMemory.recordGroupActivity(["a", "b"], "campfire") } // +8 each way
                try s.seed(root, pairs: [("a|b", .neutral, NOW - HOUR)])
                s.manager.start()

                s.dice.script = Stage.sparks(3)
                s.manager.tick()
                #expect(s.manager.state.pairs["a|b"]?.state == .warm)
                #expect(s.manager.state.log.last?.text == "a & b: neutral -> warm (growing affinity)")
            }
        }

        @Test func aSparkIgnitesTensionIntoAFeudWithTheFeudStartScript() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .tension, NOW - HOUR)])
                s.manager.start()

                // sparks: main|a, main|b, then a|b < 0.005; then the script pick, then no narration
                s.dice.script = [0.9, 0.9, 0.001, 0.99]
                s.manager.tick()
                #expect(s.manager.state.pairs["a|b"]?.state == .feud)
                #expect(s.manager.state.log.last?.text == "a & b: tension -> feud (spark)")
                #expect(s.flock.activeConversation?.lines.first?.text == "I saw what you did at the campfire.")
            }
        }

        @Test func aTiredFeudReconcilesAndCallsForAFeastThenMakesUp() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .feud, NOW - 49 * HOUR)])
                s.manager.start()

                s.dice.script = Stage.sparks(3)
                s.manager.tick()
                #expect(s.manager.state.pairs["a|b"]?.state == .reconciling)
                #expect(s.manager.state.log.last?.text == "a & b: feud -> reconciling (tired of fighting)")
                #expect(s.spectacleKeys == ["feast a|b"])

                s.now += 11 * MINUTE
                s.dice.script = Stage.sparks(3)
                s.manager.tick()
                #expect(s.manager.state.pairs["a|b"]?.state == .warm)
                #expect(s.manager.state.log.last?.text == "a & b: reconciling -> warm (made up)")
                #expect(s.flock.activeConversation?.lines.first?.text == "Look... I said things.")
                #expect(s.flock.activeConversation?.participants == ["a", "b"])
                #expect(s.spectacleKeys == ["feast a|b"])
            }
        }

        @Test func aReconcilingPairWithoutACallbackJustReconciles() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                s.manager.onDramaTriggeredSpectacle = nil
                try s.seed(root, pairs: [("a|b", .feud, NOW - 49 * HOUR)])
                s.manager.start()
                s.dice.script = Stage.sparks(3)
                s.manager.tick()
                #expect(s.manager.state.pairs["a|b"]?.state == .reconciling)
            }
        }

        @Test func inseparablePairsTrailEachOther() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                // Young enough that the 30-minute anti-flap dwell keeps the state.
                try s.seed(root, pairs: [("a|b", .inseparable, NOW - MINUTE)])
                s.manager.start()
                Stage.park(s.sheep("a"), x: 100)
                Stage.park(s.sheep("b"), x: 700) // 600 > 4 * 96

                s.dice.script = Stage.sparks(3)
                s.manager.tick()
                #expect(s.sheep("b").walkTarget == 100)
                #expect(s.sheep("a").walkTarget == nil)

                // Close enough: no trailing.
                Stage.park(s.sheep("b"), x: 300)
                s.dice.script = Stage.sparks(3)
                s.manager.tick()
                #expect(s.sheep("b").walkTarget == nil)
            }
        }

        // MARK: feud behaviors

        @Test func feudersStormApartWhenTooClose() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .feud, NOW - HOUR)])
                s.manager.start()
                Stage.park(s.sheep("a"), x: 500)
                Stage.park(s.sheep("b"), x: 600) // 100 < 2 * 96

                s.dice.script = Stage.sparks(3)
                s.manager.tick()
                #expect(s.sheep("a").walkTarget == 212) // 500 - 3 * 96
                #expect(s.sheep("a").state == .headshake)
                #expect(s.sheep("b").walkTarget == nil)

                // A sheep against the wall clamps at 0 instead.
                Stage.park(s.sheep("a"), x: 20)
                Stage.park(s.sheep("b"), x: 60)
                s.dice.script = Stage.sparks(3)
                s.manager.tick()
                #expect(s.sheep("a").walkTarget == 0)

                // And storms right when it is the left-hand sheep's partner.
                Stage.park(s.sheep("a"), x: 600)
                Stage.park(s.sheep("b"), x: 500)
                s.dice.script = Stage.sparks(3)
                s.manager.tick()
                #expect(s.sheep("a").walkTarget == 888) // 600 + 3 * 96
            }
        }

        @Test func aFeudSometimesSnipes() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .feud, NOW - HOUR)])
                s.manager.start()

                // sparks, snipe roll passes, script pick (third feud_snipe template), mediation misses
                s.dice.script = Stage.sparks(3) + [0.0, 0.99]
                s.manager.tick()
                #expect(s.flock.activeConversation?.lines.map(\.text) == ["Hmph.", "Hmph indeed."])
                #expect(s.flock.activeConversation?.participants == ["a", "b"])
            }
        }

        @Test func aFeudUsuallyStaysQuiet() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .feud, NOW - HOUR)])
                s.manager.start()
                s.dice.script = Stage.sparks(3) // then 0.99 for snipe, mediation
                s.manager.tick()
                #expect(s.flock.activeConversation == nil)
                #expect(s.manager.state.pairs["a|b"]?.state == .feud)
            }
        }

        @Test func aLongFeudEruptsIntoAShowdown() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .feud, NOW - 25 * HOUR)])
                s.manager.start()

                // sparks, snipe misses, mediation misses, showdown roll passes
                s.dice.script = Stage.sparks(3) + [0.99, 0.99, 0.0]
                s.manager.tick()
                #expect(s.spectacleKeys == ["showdown a|b"])
                #expect(s.manager.state.pairs["a|b"]?.state == .feud) // the scene decides the outcome
            }
        }

        @Test func aYoungFeudNeverStartsAShowdown() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .feud, NOW - 23 * HOUR)])
                s.manager.start()
                s.dice.tail = 0.0 // every roll passes
                s.manager.tick()
                #expect(s.spectacles.isEmpty)
            }
        }

        @Test func showdownWithoutACallbackIsSkippedAfterTheRoll() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                s.manager.onDramaTriggeredSpectacle = nil
                try s.seed(root, pairs: [("a|b", .feud, NOW - 25 * HOUR)])
                s.manager.start()
                s.dice.script = Stage.sparks(3) + [0.99, 0.99, 0.0]
                s.manager.tick() // must not crash
                #expect(s.manager.state.pairs["a|b"]?.state == .feud)
            }
        }

        // MARK: mediation

        /// Feud a|b with four friends; c is the best-connected (4) beside d (2).
        private func mediationStage(_ root: URL) throws -> Stage {
            let s = Stage(friends: ["a", "b", "c", "d"])
            FriendMemory.recordGroupActivity(["c", "a"], "x")
            FriendMemory.recordGroupActivity(["c", "b"], "x")
            FriendMemory.recordGroupActivity(["d", "a"], "x")
            try s.seed(root, pairs: [("a|b", .feud, NOW - HOUR)])
            s.manager.start()
            return s
        }

        @Test func theBestConnectedCalmThirdSheepMediatesAndSucceeds() throws {
            try withBrainRoot { root in
                let s = try mediationStage(root)
                defer { s.close() }

                // 10 sparks, snipe misses, mediation passes, script pick, success passes
                s.dice.script = Stage.sparks(5) + [0.99, 0.0, 0.0, 0.0]
                s.manager.tick()

                let convo = s.flock.activeConversation
                #expect(convo?.participants == ["a", "b", "c"])
                #expect(convo?.lines.first?.speakerId == "c")
                #expect(convo?.lines.first?.text == "Okay. Both of you. Here. Now.")
                #expect(s.manager.state.pairs["a|b"]?.state == .reconciling)
                #expect(s.manager.state.log.last?.text == "a & b: feud -> reconciling (mediation)")
                #expect(s.spectacleKeys == ["feast a|b"])
            }
        }

        @Test func aFailedMediationLeavesTheFeud() throws {
            try withBrainRoot { root in
                let s = try mediationStage(root)
                defer { s.close() }
                s.dice.script = Stage.sparks(5) + [0.99, 0.0, 0.0, 0.9]
                s.manager.tick()
                #expect(s.flock.activeConversation?.participants == ["a", "b", "c"])
                #expect(s.manager.state.pairs["a|b"]?.state == .feud)
                #expect(s.spectacles.isEmpty)
            }
        }

        @Test func mediationNeedsACalmThirdSheep() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .feud, NOW - HOUR)])
                s.manager.start()
                s.dice.script = Stage.sparks(3) + [0.99, 0.0] // mediation rolls, but nobody can step in
                s.manager.tick()
                #expect(s.flock.activeConversation == nil)
                #expect(s.manager.state.pairs["a|b"]?.state == .feud)
            }
        }

        // MARK: showdown resolution and the spectacle hand-off

        @Test func aReconciledShowdownMovesTheFeudToReconcilingWithAFeast() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .feud, NOW - 25 * HOUR)])
                s.manager.start()
                s.now += 5 * MINUTE

                s.manager.resolveShowdown(("a", "b"), true)
                #expect(s.manager.state.pairs["a|b"] == DramaPairRecord(state: .reconciling, since: s.now))
                #expect(s.manager.state.log.last?.text == "a & b: feud -> reconciling (showdown)")
                #expect(s.spectacleKeys == ["feast a|b"])
                #expect(try dramaJSON(root)["pairs"]?["a|b"]?["state"] == .string("reconciling"))
            }
        }

        @Test func aStalemateOnlyLogsAndKeepsTheFeud() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .feud, NOW - 25 * HOUR)])
                s.manager.start()

                s.manager.resolveShowdown(("b", "a"), false) // either order finds the pair
                #expect(s.manager.state.pairs["a|b"] == DramaPairRecord(state: .feud, since: NOW - 25 * HOUR))
                #expect(s.manager.state.log.last?.text == "b & a: showdown ended in a stalemate")
                #expect(s.spectacles.isEmpty)
                let log = try dramaJSON(root)["log"]?.arrayValue
                #expect(log?.last?["text"] == .string("b & a: showdown ended in a stalemate"))
            }
        }

        @Test func resolvingAShowdownForANonFeudPairDoesNothing() throws {
            try withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                try s.seed(root, pairs: [("a|b", .warm, NOW - HOUR)])
                s.manager.start()
                s.manager.resolveShowdown(("a", "b"), true)
                s.manager.resolveShowdown(("a", "b"), false)
                s.manager.resolveShowdown(("a", "zzz"), true)
                #expect(s.manager.state.pairs["a|b"]?.state == .warm)
                #expect(s.manager.state.log.isEmpty)
                #expect(s.spectacles.isEmpty)
            }
        }

        @Test func aFeudBecomesAShowdownThroughTheFlockAndThenResolves() {
            withBrainRoot { root in
                let s = Stage()
                defer { s.close() }
                var started: [String] = []
                let unsubscribe = bus.on(.spectacleStarted) { event in
                    if case .spectacleStarted(let type) = event { started.append(type) }
                }
                defer { unsubscribe() }

                // The overlay glue: drama callback -> flock spectacle, scene outcome -> resolveShowdown.
                s.manager.onDramaTriggeredSpectacle = { type, pair in
                    s.flock.startSpectacle(type, pair)
                }
                s.flock.onShowdownResolved = { pair, reconciled in
                    s.manager.resolveShowdown(pair, reconciled)
                }

                #expect(s.manager.forceFeud() == "a|b")
                s.flock.cancelConversation() // the feud_start script would otherwise hold the stage
                s.now += 25 * HOUR

                s.dice.script = Stage.sparks(3) + [0.99, 0.99, 0.0] // snipe, mediation miss; showdown passes
                s.manager.tick()
                #expect(s.flock.spectacle != nil)
                #expect(started == ["showdown"])
                #expect(s.manager.state.pairs["a|b"]?.state == .feud)

                s.flock.onShowdownResolved?(("a", "b"), true)
                #expect(s.manager.state.pairs["a|b"]?.state == .reconciling)
            }
        }

        // MARK: AI narration

        private static let narration = """
        ```json
        [{"speaker": "B", "text": "hi", "animation": "bounce"}, {"speaker": "A", "text": "yo", "animation": "nope"}]
        ```
        """

        private final class ChatLog {
            var calls: [(aId: String, aName: String, aPersonality: String, bId: String, bName: String,
                         bPersonality: String, topic: String?)] = []
        }

        @Test func aTransitionIsSometimesNarratedByTheModel() async throws {
            try await withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                let chats = ChatLog()
                s.flock.friendAIChat = { aId, aName, aPers, bId, bName, bPers, topic in
                    chats.calls.append((aId, aName, aPers, bId, bName, bPers, topic))
                    return Self.narration
                }

                s.dice.script = [0.0, 0.1] // feud script pick, then the narration roll passes
                s.dice.tail = 0.99
                _ = s.manager.forceFeud()
                s.flock.cancelConversation() // free the stage for the narration
                await s.manager.narrationTask?.value

                #expect(chats.calls.count == 1)
                let call = try #require(chats.calls.first)
                #expect(call.aId == "a" && call.bId == "b")
                #expect(call.aName == "A" && call.bName == "B")
                #expect(call.aPersonality == "wholesome" && call.bPersonality == "wholesome")
                #expect(call.topic == "their relationship just changed from neutral to feud because of debug")

                let convo = try #require(s.flock.activeConversation)
                #expect(convo.participants == ["a", "b"])
                #expect(convo.lines.map(\.text) == ["hi", "yo"])
                #expect(convo.lines.map(\.speakerId) == ["b", "a"])
                #expect(convo.lines.map(\.animation) == [.bounce, nil])
                #expect(convo.lines.map(\.duration) == [3500, 3500])
                #expect(convo.lines.map(\.delay) == [0, 800])
            }
        }

        @Test func narrationHasATenMinuteCooldownAndSkipsOnAMissedRoll() async {
            await withBrainRoot { _ in
                let s = Stage(friends: ["a", "b", "c"])
                defer { s.close() }
                let chats = ChatLog()
                s.flock.friendAIChat = { aId, aName, aPers, bId, bName, bPers, topic in
                    chats.calls.append((aId, aName, aPers, bId, bName, bPers, topic))
                    return "[]"
                }

                s.dice.script = [0.0, 0.9] // roll misses (>= 0.3): no call
                _ = s.manager.forceFeud()
                #expect(s.manager.narrationTask == nil)

                s.dice.script = [0.0, 0.1]
                _ = s.manager.forceFeud() // a|c
                await s.manager.narrationTask?.value
                #expect(chats.calls.count == 1)

                s.dice.script = [0.0, 0.1] // rolls pass but the cooldown holds
                s.now += 9 * MINUTE
                _ = s.manager.forceFeud() // b|c
                await s.manager.narrationTask?.value
                #expect(chats.calls.count == 1)
            }
        }

        @Test func narrationWithoutAChatSeamFailsQuietly() async {
            await withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.dice.script = [0.0, 0.1]
                _ = s.manager.forceFeud()
                s.flock.cancelConversation()
                await s.manager.narrationTask?.value
                #expect(s.flock.activeConversation == nil)
            }
        }

        @Test func narrationIgnoresGarbageFromTheModel() async {
            await withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.flock.friendAIChat = { _, _, _, _, _, _, _ in "not json at all" }
                s.dice.script = [0.0, 0.1]
                _ = s.manager.forceFeud()
                s.flock.cancelConversation()
                await s.manager.narrationTask?.value
                #expect(s.flock.activeConversation == nil)
            }
        }
    }
}

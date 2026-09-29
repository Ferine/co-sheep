import Foundation
import Testing
@testable import CoSheepKit

private final class FakeEaster: EasterThemeHooks {
    var active: Bool
    init(active: Bool) { self.active = active }
    func registerPaintedEgg(_ sheepId: String, _ sheepName: String) {}
}

/// Feeds `pickConversation` a scripted sequence of `Math.random()` values
/// (in call order), then 0.99 forever.
@MainActor
private func withRandom<T>(_ values: [Double], _ body: @MainActor () -> T) -> T {
    let saved = SimRandom.source
    defer { SimRandom.source = saved }
    var i = 0
    SimRandom.source = {
        defer { i += 1 }
        return i < values.count ? values[i] : 0.99
    }
    return body()
}

/// First line's text of the script picked with the given random sequence.
@MainActor
private func firstLine(_ values: [Double], _ a: String = "friend_a", _ b: String = "friend_b",
                       _ ctx: ConversationContext? = nil) -> String? {
    withRandom(values) { pickConversation(a, b, ctx)?.first?.text }
}

/// Number of distinct scripts reachable through a path: `prefix` are the
/// gate rolls, the final roll sweeps the pool index.
@MainActor
private func poolSize(_ prefix: [Double], _ a: String = "friend_a", _ b: String = "friend_b",
                      _ ctx: ConversationContext? = nil) -> Int {
    var seen = Set<[String]>()
    for step in 0..<100 {
        let script = withRandom(prefix + [Double(step) / 100]) { pickConversation(a, b, ctx) }
        if let script { seen.insert(script.map(\.text)) }
    }
    return seen.count
}

// Ex-conversations.ts (no vitest file; behavior tests for the port).
@Suite("conversations", .serialized)
struct ConversationsTests {
    // rolls: [skip-gate 0.9 passes, ...]
    private let pass = 0.9

    @Test func skipsHalfTheTime() {
        #expect(firstLine([0.49]) == nil)
        #expect(firstLine([0.5, pass, 0]) != nil)
    }

    @Test func genericPoolForTwoFriends() {
        #expect(firstLine([pass, pass, 0]) == "Baaaa?")
        #expect(poolSize([pass, pass]) == 12)
    }

    @Test func mainSheepPool() {
        #expect(firstLine([pass, pass, 0], "main", "friend_a") == "Is it always this judgmental?")
        #expect(poolSize([pass, pass], "main", "friend_a") == 5)
        #expect(poolSize([pass, pass], "friend_a", "main") == 5)
    }

    @Test func goodColleaguePool() {
        #expect(firstLine([pass, pass, 0], "good_colleague", "friend_a") == "Hva skjer?")
        #expect(poolSize([pass, pass], "friend_a", "good_colleague") == 6)
    }

    @Test func goodColleagueWithMainAddsTheDedicatedScript() {
        #expect(poolSize([pass, pass], "good_colleague", "main") == 6)
        #expect(firstLine([pass, pass, 0.999], "main", "good_colleague") == "Bra jobba i dag.")
    }

    @Test func speakerPlaceholdersResolve() {
        // $A/$B
        let ab = withRandom([pass, pass, 0]) { pickConversation("id_a", "id_b") }!
        #expect(ab.map(\.speakerId) == ["id_a", "id_b", "id_a"])
        // $OTHER: the non-Good-Colleague participant, whichever slot he is in
        let gc1 = withRandom([pass, pass, 0]) { pickConversation("good_colleague", "friend_1") }!
        #expect(gc1.map(\.speakerId) == ["good_colleague", "friend_1", "good_colleague"])
        let gc2 = withRandom([pass, pass, 0]) { pickConversation("friend_1", "good_colleague") }!
        #expect(gc2.map(\.speakerId) == ["good_colleague", "friend_1", "good_colleague"])
        // $FRIEND: the non-main participant
        let m1 = withRandom([pass, pass, 0]) { pickConversation("main", "friend_1") }!
        #expect(m1.map(\.speakerId) == ["friend_1", "main"])
        let m2 = withRandom([pass, pass, 0]) { pickConversation("friend_1", "main") }!
        #expect(m2.map(\.speakerId) == ["friend_1", "main"])
    }

    @Test func lineDataIsCarriedOver() throws {
        let script = try #require(withRandom([pass, pass, 0]) { pickConversation("a", "b") })
        #expect(script.count == 3)
        #expect(script.map(\.duration) == [3000, 3000, 3000])
        #expect(script.map(\.delay) == [0, 500, 800])
        #expect(script.map(\.animation) == [nil, nil, .headshake])
        #expect(script[2].text == "...fair enough.")
    }

    @Test func noPlaceholderSurvivesAnyPath() {
        let saved = SimRandom.source
        defer { SimRandom.source = saved }
        SimRandom.source = SimRandom.seeded(42)
        let easter = FakeEaster(active: true)
        let contexts: [ConversationContext?] = [
            nil,
            ConversationContext(personalityA: .snarky, personalityB: .wholesome),
            ConversationContext(weather: "rain"),
            ConversationContext(weather: "snow"),
            ConversationContext(weather: "clear"),
            ConversationContext(hour: 7),
            ConversationContext(hour: 2),
            ConversationContext(hour: 14),
            ConversationContext(easterTheme: easter),
            ConversationContext(easterTheme: easter, recentEasterHunt: true),
            ConversationContext(easterTheme: easter, eggPaintingActive: true),
            ConversationContext(summerActive: true),
        ]
        let pairs = [("a", "b"), ("main", "a"), ("a", "main"), ("good_colleague", "a"), ("a", "good_colleague"),
                     ("main", "good_colleague")]
        for ctx in contexts {
            for (a, b) in pairs {
                for _ in 0..<60 {
                    guard let script = pickConversation(a, b, ctx) else { continue }
                    #expect(!script.isEmpty)
                    for line in script {
                        #expect(!line.speakerId.hasPrefix("$"))
                        #expect([a, b, "good_colleague", "main"].contains(line.speakerId))
                        #expect(line.duration > 0 && line.delay >= 0)
                        #expect(!line.text.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: personality pairs (40% once the 50% skip passes)

    @Test func personalityPairScripts() {
        func ctx(_ a: FriendPersonality, _ b: FriendPersonality) -> ConversationContext {
            ConversationContext(personalityA: a, personalityB: b)
        }
        let roll = [pass, 0.1, 0.0]
        #expect(firstLine(roll, "a", "b", ctx(.snarky, .wholesome)) == "Everything is terrible.")
        #expect(firstLine(roll, "a", "b", ctx(.wholesome, .snarky)) == "Everything is terrible.")
        #expect(firstLine(roll, "a", "b", ctx(.chaotic, .chaotic)) == "WHAT IF WE SPIN AT THE SAME TIME")
        #expect(firstLine(roll, "a", "b", ctx(.passiveAggressive, .snarky)) == "I'm FINE.")
        #expect(firstLine(roll, "a", "b", ctx(.snarky, .passiveAggressive)) == "I'm FINE.")
        #expect(firstLine(roll, "a", "b", ctx(.wholesome, .wholesome)) == "You're my best friend!")
        #expect(poolSize([pass, 0.1], "a", "b", ctx(.snarky, .wholesome)) == 3)
        #expect(poolSize([pass, 0.1], "a", "b", ctx(.chaotic, .chaotic)) == 2)
        #expect(poolSize([pass, 0.1], "a", "b", ctx(.passiveAggressive, .snarky)) == 2)
        #expect(poolSize([pass, 0.1], "a", "b", ctx(.wholesome, .wholesome)) == 2)
    }

    @Test func personalityPairFallsThroughOnTheFortyPercentRoll() {
        let c = ConversationContext(personalityA: .snarky, personalityB: .wholesome, hour: 12)
        // 0.4 is not < 0.4 → generic pool
        #expect(firstLine([pass, 0.4, pass, 0.0], "a", "b", c) == "Baaaa?")
    }

    @Test func unmatchedPersonalityPairsConsumeNoRoll() {
        // snarky+snarky has no pool, so the very next roll is the time gate.
        let c = ConversationContext(personalityA: .snarky, personalityB: .snarky, hour: 12)
        #expect(firstLine([pass, pass, 0.0], "a", "b", c) == "Baaaa?")
    }

    @Test func personalityScriptsNeverApplyWithMainOrGoodColleague() {
        let c = ConversationContext(personalityA: .snarky, personalityB: .wholesome, hour: 12)
        #expect(firstLine([pass, pass, 0.0], "main", "b", c) == "Is it always this judgmental?")
        #expect(firstLine([pass, pass, 0.0], "good_colleague", "b", c) == "Hva skjer?")
    }

    // MARK: Easter

    @Test func easterScriptsOnlyWhileActive() {
        let hour = 12
        let on = ConversationContext(hour: hour, easterTheme: FakeEaster(active: true))
        #expect(firstLine([pass, 0.1, 0.0], "a", "b", on) == "I found more eggs than you.")
        #expect(poolSize([pass, 0.1], "a", "b", on) == 8)
        // inactive theme: no Easter roll is consumed
        let off = ConversationContext(hour: hour, easterTheme: FakeEaster(active: false))
        #expect(firstLine([pass, pass, 0.0], "a", "b", off) == "Baaaa?")
    }

    @Test func easterChanceDependsOnTheMoment() {
        let theme = FakeEaster(active: true)
        // plain: 25%
        let plain = ConversationContext(hour: 12, easterTheme: theme)
        #expect(firstLine([pass, 0.24, 0.0], "a", "b", plain) == "I found more eggs than you.")
        #expect(firstLine([pass, 0.26, pass, 0.0], "a", "b", plain) == "Baaaa?")
        // recent hunt: 80%
        let hunt = ConversationContext(hour: 12, easterTheme: theme, recentEasterHunt: true)
        #expect(firstLine([pass, 0.79, 0.0], "a", "b", hunt) == "I still can't believe you missed the golden egg.")
        #expect(firstLine([pass, 0.81, pass, 0.0], "a", "b", hunt) == "Baaaa?")
        #expect(poolSize([pass, 0.1], "a", "b", hunt) == 3)
        // egg painting: 65%
        let paint = ConversationContext(hour: 12, easterTheme: theme, eggPaintingActive: true)
        #expect(firstLine([pass, 0.64, 0.0], "a", "b", paint) == "Hold still. This stripe needs emotional support.")
        #expect(firstLine([pass, 0.66, pass, 0.0], "a", "b", paint) == "Baaaa?")
        #expect(poolSize([pass, 0.1], "a", "b", paint) == 2)
    }

    @Test func recentHuntBeatsPaintingAndGoodColleaguePool() {
        let theme = FakeEaster(active: true)
        let both = ConversationContext(hour: 12, easterTheme: theme, recentEasterHunt: true, eggPaintingActive: true)
        #expect(firstLine([pass, 0.1, 0.0], "a", "b", both) == "I still can't believe you missed the golden egg.")
        let hunt = ConversationContext(hour: 12, easterTheme: theme, recentEasterHunt: true)
        #expect(firstLine([pass, 0.1, 0.0], "good_colleague", "b", hunt) == "I still can't believe you missed the golden egg.")
    }

    @Test func easterGoodColleaguePool() {
        let c = ConversationContext(hour: 12, easterTheme: FakeEaster(active: true))
        #expect(firstLine([pass, 0.1, 0.0], "good_colleague", "b", c) == "Påskeegg er seriøs business.")
        #expect(poolSize([pass, 0.1], "good_colleague", "b", c) == 3)
    }

    @Test func easterBeatsPersonalityPairOnlyWhenPairRollFails() {
        let c = ConversationContext(personalityA: .snarky, personalityB: .wholesome, hour: 12,
                                    easterTheme: FakeEaster(active: true))
        // pair roll 0.5 (>= 0.4) → falls through to Easter (0.1 < 0.25)
        #expect(firstLine([pass, 0.5, 0.1, 0.0], "a", "b", c) == "I found more eggs than you.")
        // pair roll 0.3 → personality script wins
        #expect(firstLine([pass, 0.3, 0.0], "a", "b", c) == "Everything is terrible.")
    }

    // MARK: summer

    @Test func summerScripts() {
        let c = ConversationContext(hour: 12, summerActive: true)
        #expect(firstLine([pass, 0.1, 0.0], "a", "b", c) == "Is it just me or is the sun EXTRA today?")
        #expect(poolSize([pass, 0.1], "a", "b", c) == 5)
        #expect(firstLine([pass, 0.1, 0.0], "good_colleague", "b", c) == "Fellesferie snart.")
        #expect(poolSize([pass, 0.1], "good_colleague", "b", c) == 3)
        // 25% gate
        #expect(firstLine([pass, 0.25, pass, 0.0], "a", "b", c) == "Baaaa?")
    }

    // MARK: weather

    @Test func weatherScripts() {
        func w(_ s: String?) -> ConversationContext { ConversationContext(weather: s, hour: 12) }
        #expect(firstLine([pass, 0.1, 0.0], "a", "b", w("rain")) == "Is that... rain?")
        #expect(poolSize([pass, 0.1], "a", "b", w("rain")) == 2)
        #expect(firstLine([pass, 0.1, 0.0], "a", "b", w("snow")) == "SNOW!")
        #expect(poolSize([pass, 0.1], "a", "b", w("snow")) == 1)
        #expect(firstLine([pass, 0.1, 0.0], "a", "b", w("clear")) == "Beautiful day outside.")
        #expect(poolSize([pass, 0.1], "a", "b", w("clear")) == 1)
        // 25% gate
        #expect(firstLine([pass, 0.25, pass, 0.0], "a", "b", w("rain")) == "Baaaa?")
    }

    @Test func unknownWeatherConsumesItsRollThenFallsThrough() {
        let c = ConversationContext(weather: "fog", hour: 12)
        // roll order: skip, weather gate (passes, but no pool), time gate, index
        #expect(firstLine([pass, 0.1, pass, 0.0], "a", "b", c) == "Baaaa?")
    }

    @Test func emptyOrMissingWeatherConsumesNoRoll() {
        // JS: `context?.weather && Math.random() < 0.25` — "" is falsy.
        #expect(firstLine([pass, pass, 0.0], "a", "b", ConversationContext(weather: "", hour: 12)) == "Baaaa?")
        #expect(firstLine([pass, pass, 0.0], "a", "b", ConversationContext(weather: nil, hour: 12)) == "Baaaa?")
    }

    // MARK: time of day

    @Test func timeOfDayPools() {
        func h(_ hour: Int) -> ConversationContext { ConversationContext(hour: hour) }
        let roll = [pass, 0.1, 0.0]
        for hour in [6, 7, 9] {
            #expect(firstLine(roll, "a", "b", h(hour)) == "Good morning!", "hour \(hour)")
        }
        for hour in [23, 0, 2, 3] {
            #expect(firstLine(roll, "a", "b", h(hour)) == "Why are we still awake?", "hour \(hour)")
        }
        for hour in [13, 14, 15] {
            #expect(firstLine(roll, "a", "b", h(hour)) == "Post-lunch slump hitting hard.", "hour \(hour)")
        }
        // gaps in the day fall through to the character pools
        for hour in [4, 5, 10, 11, 12, 16, 22] {
            #expect(firstLine(roll, "a", "b", h(hour)) == "Baaaa?", "hour \(hour)")
        }
        #expect(poolSize([pass, 0.1], "a", "b", h(7)) == 2)
        #expect(poolSize([pass, 0.1], "a", "b", h(2)) == 2)
        #expect(poolSize([pass, 0.1], "a", "b", h(14)) == 1)
        // 20% gate
        #expect(firstLine([pass, 0.2, 0.0], "a", "b", h(7)) == "Baaaa?")
    }

    @Test func hourDefaultsToTheSimClock() {
        let savedNow = SimClock.nowSource
        defer { SimClock.nowSource = savedNow }
        let seven = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 7, minute: 30))!
        SimClock.nowSource = { seven.timeIntervalSince1970 * 1000 }
        #expect(firstLine([pass, 0.1, 0.0]) == "Good morning!")
        let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 12))!
        SimClock.nowSource = { noon.timeIntervalSince1970 * 1000 }
        #expect(firstLine([pass, 0.1, 0.0]) == "Baaaa?")
    }

    // MARK: gate order

    @Test func seasonalGatesComeBeforeWeatherAndTime() {
        let theme = FakeEaster(active: true)
        let c = ConversationContext(weather: "rain", hour: 7, easterTheme: theme, summerActive: true)
        #expect(firstLine([pass, 0.1, 0.0], "a", "b", c) == "I found more eggs than you.")
        let noEaster = ConversationContext(weather: "rain", hour: 7, summerActive: true)
        #expect(firstLine([pass, 0.1, 0.0], "a", "b", noEaster) == "Is it just me or is the sun EXTRA today?")
        let weatherOnly = ConversationContext(weather: "rain", hour: 7)
        #expect(firstLine([pass, 0.1, 0.0], "a", "b", weatherOnly) == "Is that... rain?")
    }
}

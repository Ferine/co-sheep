import Foundation
import Testing
@testable import CoSheepKit

/// Collects everything a signal emits until `stop()`.
final class Captured<T> {
    private(set) var values: [T] = []
    private var off: (() -> Void)?

    init(_ signal: Signal<T>) {
        off = signal.on { [self] value in values.append(value) }
    }

    func stop() {
        off?()
        off = nil
    }
}

/// Pin `SimClock` / `SimRandom` for the length of `body` (both restored after).
func withPinned<T>(nowMs: Double? = nil, random: Double? = nil, _ body: () throws -> T) rethrows -> T {
    let savedNow = SimClock.nowSource
    let savedRandom = SimRandom.source
    defer {
        SimClock.nowSource = savedNow
        SimRandom.source = savedRandom
    }
    if let nowMs { SimClock.nowSource = { nowMs } }
    if let random { SimRandom.source = { random } }
    return try body()
}

// The commands mutate the process-global `Paths.root`, so they live inside
// the serialized Brain suite (separate top-level suites would run in parallel
// with the Brain tests and race on it).
extension BrainTests {
    @Suite("window commands")
    struct WindowCommandsTests {
        private func seed(_ mutate: (inout SheepConfig) -> Void = { _ in }) throws {
            var config = SheepConfig()
            config.name = "Woolly"
            mutate(&config)
            try Config.writeConfig(config)
        }

        private func friend(_ id: String, _ name: String, accessories: [String] = []) -> FriendDef {
            FriendDef(id: id, name: name, color: "green", personality: "snarky", accessories: accessories, scale: 1.0)
        }

        private func brainFile(_ id: String) -> URL {
            Paths.friends.appendingPathComponent("\(id).json")
        }

        // MARK: settings

        @Test func getSettingsIsDefaultWhenThereIsNoConfig() {
            withBrainRoot { _ in
                #expect(WindowCommands.getSettings() == SheepConfig())
            }
        }

        @Test func getSettingsReturnsTheSavedConfig() throws {
            try withBrainRoot { _ in
                try seed { $0.language = "german"; $0.weatherLocation = "Oslo" }
                let s = WindowCommands.getSettings()
                #expect(s.name == "Woolly")
                #expect(s.language == "german")
                #expect(s.weatherLocation == "Oslo")
            }
        }

        @Test func saveSettingsWritesEightFieldsKeepsTheRestAndEmits() throws {
            try withBrainRoot { _ in
                try seed {
                    $0.friends = [friend("friend_1", "Fluffy", accessories: ["crown"])]
                    $0.accessories = ["cape"]
                    $0.mcpPort = 5000
                    $0.mcpToken = "tok"
                }
                let events = Captured(AppEvents.shared.settingsChanged)
                defer { events.stop() }

                let saved = try WindowCommands.saveSettings(
                    name: "Dolly", personality: "chaotic", intervalSecs: 90, language: "english",
                    breakReminders: false, easterMode: "on", summerMode: "off", weatherLocation: "Tokyo")

                let onDisk = try #require(Config.loadConfig())
                #expect(onDisk == saved)
                #expect(onDisk.name == "Dolly")
                #expect(onDisk.personality == "chaotic")
                #expect(onDisk.intervalSecs == 90)
                #expect(onDisk.language == "english")
                #expect(onDisk.breakReminders == false)
                #expect(onDisk.easterMode == "on")
                #expect(onDisk.summerMode == "off")
                #expect(onDisk.weatherLocation == "Tokyo")
                // Friends, accessories and MCP settings are preserved.
                #expect(onDisk.friends == [friend("friend_1", "Fluffy", accessories: ["crown"])])
                #expect(onDisk.accessories == ["cape"])
                #expect(onDisk.mcpPort == 5000)
                #expect(onDisk.mcpToken == "tok")
                // settings-changed carries the saved config.
                #expect(events.values == [saved])
            }
        }

        @Test func saveSettingsCreatesTheConfigOnFirstRun() throws {
            try withBrainRoot { _ in
                #expect(Config.needsOnboarding())
                try WindowCommands.saveSettings(
                    name: "Sheep", personality: "snarky", intervalSecs: 150, language: "nynorsk",
                    breakReminders: true, easterMode: "auto", summerMode: "auto", weatherLocation: "")
                #expect(!Config.needsOnboarding())
            }
        }

        @Test func saveSettingsOnACorruptConfigThrowsWithoutEmittingOrOverwriting() throws {
            try withBrainRoot { _ in
                try write("{ not json", to: Paths.config)
                let events = Captured(AppEvents.shared.settingsChanged)
                defer { events.stop() }

                #expect(throws: (any Error).self) {
                    try WindowCommands.saveSettings(
                        name: "X", personality: "snarky", intervalSecs: 150, language: "nynorsk",
                        breakReminders: true, easterMode: "auto", summerMode: "auto", weatherLocation: "")
                }
                #expect(events.values.isEmpty)
                #expect(try String(contentsOf: Paths.config, encoding: .utf8) == "{ not json")
            }
        }

        // MARK: friends

        @Test func getFriendsEnsuresBrainsForGoodColleagueAndEveryFriend() throws {
            try withBrainRoot { _ in
                try seed { $0.friends = [friend("friend_1", "Fluffy"), friend("friend_2", "Bjørn")] }
                let friends = WindowCommands.getFriends()
                #expect(friends.map(\.id) == ["friend_1", "friend_2"])

                let cards = FriendMemory.getAllRelationships()
                #expect(Set(cards.keys) == ["good_colleague", "friend_1", "friend_2"])
                #expect(cards["good_colleague"]?.name == "Good Colleague")
                #expect(cards["good_colleague"]?.mood == "grumpy")
                #expect(cards["friend_2"]?.name == "Bjørn")
            }
        }

        @Test func getFriendsWithoutConfigStillLoadsGoodColleague() {
            withBrainRoot { _ in
                #expect(WindowCommands.getFriends().isEmpty)
                #expect(Set(FriendMemory.getAllRelationships().keys) == ["good_colleague"])
            }
        }

        @Test func getFriendsRunsTheDailyDecay() throws {
            try withBrainRoot { _ in
                try seed { $0.friends = [friend("friend_1", "Fluffy")] }
                // A brain last decayed on an earlier day, with an affinity of 5.
                var brain = FriendMemory.newBrain("friend_1", "Fluffy")
                brain.lastDecayDate = "2000-01-01"
                brain.relationships["main"] = 5
                brain.stats.conversationsToday = 3
                try JSONFile.write(brain, to: brainFile("friend_1"))

                _ = WindowCommands.getFriends()

                let after = WindowCommands.getFriendMemory(id: "friend_1")
                #expect(after.relationships["main"] == 4)
                #expect(after.stats.conversationsToday == 0)
                #expect(after.stats.daysAlive == 1)
                #expect(after.lastDecayDate == BrainTime.today())
            }
        }

        @Test func addFriendMintsIdAndScaleSavesItAndEmits() throws {
            try withBrainRoot { _ in
                try seed()
                let events = Captured(AppEvents.shared.addFriend)
                defer { events.stop() }

                let added = try withPinned(nowMs: 1_700_000_000_123, random: 0.5) {
                    try WindowCommands.addFriend(name: "Fluffy", color: "green", personality: "snarky")
                }

                #expect(added.id == "friend_1700000000123")
                #expect(abs(added.scale - 1.0) < 1e-9)
                #expect(added.accessories.isEmpty)
                let saved = try #require(Config.loadConfig()?.friends)
                #expect(saved == [added])
                #expect(saved[0].name == "Fluffy")
                #expect(saved[0].color == "green")
                #expect(saved[0].personality == "snarky")

                // Its brain exists, under the new name.
                #expect(FriendMemory.getAllRelationships()[added.id]?.name == "Fluffy")

                #expect(events.values == [
                    FriendConfig(
                        id: added.id, name: "Fluffy", color: .green, personality: .snarky,
                        accessories: nil, scale: added.scale)
                ])
            }
        }

        @Test func addFriendScaleSpansPoint85ToOnePoint15() throws {
            try withBrainRoot { _ in
                try seed()
                let low = try withPinned(nowMs: 1, random: 0.0) {
                    try WindowCommands.addFriend(name: "Low", color: "pink", personality: "wholesome")
                }
                let high = try withPinned(nowMs: 2, random: 0.999999) {
                    try WindowCommands.addFriend(name: "High", color: "pink", personality: "wholesome")
                }
                #expect(abs(low.scale - 0.85) < 1e-9)
                #expect(high.scale > 1.149 && high.scale < 1.15)
            }
        }

        @Test func addFriendTwiceInTheSameMillisecondGetsSuffixedIds() throws {
            try withBrainRoot { _ in
                try seed()
                let ids = try withPinned(nowMs: 1_700_000_000_000, random: 0.5) {
                    try (0..<3).map { i in
                        try WindowCommands.addFriend(name: "F\(i)", color: "gold", personality: "chaotic").id
                    }
                }
                #expect(ids == [
                    "friend_1700000000000", "friend_1700000000000_1", "friend_1700000000000_2",
                ])
                #expect(Config.loadConfig()?.friends.map(\.id) == ids)
            }
        }

        @Test func addFriendRefusesAFifthSheep() throws {
            try withBrainRoot { _ in
                let existing = (1...4).map { friend("friend_\($0)", "F\($0)") }
                try seed { $0.friends = existing }
                let events = Captured(AppEvents.shared.addFriend)
                defer { events.stop() }

                var thrown: WindowCommandError?
                do {
                    try WindowCommands.addFriend(name: "Fifth", color: "pink", personality: "snarky")
                } catch let e as WindowCommandError {
                    thrown = e
                }
                #expect(thrown == .maxFriends)
                #expect(thrown?.localizedDescription == "Max 4 friends — the desktop only fits so much wool.")
                #expect(Config.loadConfig()?.friends == existing)
                #expect(events.values.isEmpty)
                #expect(FriendMemory.getAllRelationships().isEmpty)
            }
        }

        @Test func addFriendAllowsTheFourthAndKeepsTheConfigIntact() throws {
            try withBrainRoot { _ in
                try seed {
                    $0.friends = (1...3).map { friend("friend_\($0)", "F\($0)") }
                    $0.accessories = ["halo"]
                }
                try WindowCommands.addFriend(name: "Fourth", color: "purple", personality: "passive-aggressive")
                let config = try #require(Config.loadConfig())
                #expect(config.friends.count == 4)
                #expect(config.friends.last?.personality == "passive-aggressive")
                #expect(config.accessories == ["halo"])
            }
        }

        @Test func addFriendEventFallsBackForUnknownColorAndPersonality() throws {
            try withBrainRoot { _ in
                try seed()
                let events = Captured(AppEvents.shared.addFriend)
                defer { events.stop() }
                try WindowCommands.addFriend(name: "Odd", color: "chartreuse", personality: "grumpy")
                // The config keeps the raw strings; the overlay gets the closest typed values.
                #expect(Config.loadConfig()?.friends.first?.color == "chartreuse")
                #expect(events.values.first?.color == .pink)
                #expect(events.values.first?.personality == nil)
            }
        }

        @Test func removeFriendDropsConfigBrainAndRelationshipsThenEmits() throws {
            try withBrainRoot { _ in
                try seed { $0.friends = [friend("friend_a", "A"), friend("friend_b", "B")] }
                _ = WindowCommands.getFriends()
                FriendMemory.recordConversation("friend_a", "friend_b", "tabs")
                #expect(FileManager.default.fileExists(atPath: brainFile("friend_b").path))
                let events = Captured(AppEvents.shared.removeFriend)
                defer { events.stop() }

                try WindowCommands.removeFriend(id: "friend_b")

                #expect(Config.loadConfig()?.friends.map(\.id) == ["friend_a"])
                #expect(!FileManager.default.fileExists(atPath: brainFile("friend_b").path))
                #expect(FriendMemory.getAllRelationships()["friend_b"] == nil)
                #expect(WindowCommands.getFriendMemory(id: "friend_a").relationships["friend_b"] == nil)
                #expect(events.values == ["friend_b"])
            }
        }

        @Test func removeFriendOfAnUnknownIdStillEmits() throws {
            try withBrainRoot { _ in
                try seed { $0.friends = [friend("friend_a", "A")] }
                let events = Captured(AppEvents.shared.removeFriend)
                defer { events.stop() }
                try WindowCommands.removeFriend(id: "ghost")
                #expect(Config.loadConfig()?.friends.map(\.id) == ["friend_a"])
                #expect(events.values == ["ghost"])
            }
        }

        @Test func saveFriendAccessoriesUpdatesOnlyThatFriendAndEmits() throws {
            try withBrainRoot { _ in
                try seed {
                    $0.friends = [friend("friend_a", "A", accessories: ["crown"]), friend("friend_b", "B")]
                }
                let events = Captured(AppEvents.shared.friendAccessoriesChanged)
                defer { events.stop() }

                try WindowCommands.saveFriendAccessories(id: "friend_b", accessories: ["halo", "cape"])

                let friends = try #require(Config.loadConfig()?.friends)
                #expect(friends[0].accessories == ["crown"])
                #expect(friends[1].accessories == ["halo", "cape"])
                #expect(events.values.count == 1)
                #expect(events.values[0].id == "friend_b")
                #expect(events.values[0].accessories == ["halo", "cape"])
            }
        }

        @Test func saveFriendAccessoriesForAnUnknownIdChangesNothingButStillEmits() throws {
            try withBrainRoot { _ in
                try seed { $0.friends = [friend("friend_a", "A")] }
                let events = Captured(AppEvents.shared.friendAccessoriesChanged)
                defer { events.stop() }
                try WindowCommands.saveFriendAccessories(id: "ghost", accessories: ["halo"])
                #expect(Config.loadConfig()?.friends == [friend("friend_a", "A")])
                #expect(events.values.count == 1)
                #expect(events.values[0].id == "ghost")
            }
        }

        // MARK: wardrobe

        @Test func accessoriesRoundTripAndEmit() throws {
            try withBrainRoot { _ in
                #expect(WindowCommands.getAccessories().isEmpty)
                try seed { $0.friends = [friend("friend_a", "A")] }
                let events = Captured(AppEvents.shared.accessoriesChanged)
                defer { events.stop() }

                try WindowCommands.saveAccessories(["crown", "sunglasses"])

                #expect(WindowCommands.getAccessories() == ["crown", "sunglasses"])
                #expect(events.values == [["crown", "sunglasses"]])
                // Friends are untouched.
                #expect(Config.loadConfig()?.friends == [friend("friend_a", "A")])
            }
        }

        // MARK: memory

        @Test func getMemoryShowsOpinionsTalliesStatsAndDiary() throws {
            try withBrainRoot { _ in
                try seed()
                try Memory.saveOpinion(topic: "Dark Mode", opinion: "Respect.", category: "opinion")
                Memory.incrementToday("app:browser")
                Memory.incrementToday("app:browser")
                Memory.recordComment()
                Memory.recordInteraction("petted")

                let m = WindowCommands.getMemory()
                #expect(m.opinions.map(\.topic) == ["dark_mode"])
                #expect(m.todayCounts == ["app:browser": 2])
                #expect(m.totalComments == 1)
                #expect(m.totalInteractions == 1)
                #expect(m.todayJournal.contains("*My human petted me!*"))
            }
        }

        @Test func getMemoryOfAFreshSheepIsEmpty() {
            withBrainRoot { _ in
                let m = WindowCommands.getMemory()
                #expect(m.opinions.isEmpty)
                #expect(m.todayCounts.isEmpty)
                #expect(m.todayJournal.isEmpty)
            }
        }

        @Test func friendMemoryAndRelationshipsReadTheFriendBrains() throws {
            try withBrainRoot { _ in
                try seed { $0.friends = [friend("friend_a", "A"), friend("friend_b", "B")] }
                _ = WindowCommands.getFriends()
                FriendMemory.recordConversation("friend_a", "friend_b", "tabs")

                let brain = WindowCommands.getFriendMemory(id: "friend_a")
                #expect(brain.id == "friend_a")
                #expect(brain.relationships["friend_b"] == 1)
                #expect(brain.memories.last?.text == "Talked with B about tabs")
                #expect(brain.stats.conversationsTotal == 1)

                let cards = WindowCommands.getAllRelationships()
                #expect(cards["friend_a"]?.name == "A")
                #expect(cards["friend_a"]?.stats.conversationsTotal == 1)
                #expect(cards["friend_b"]?.relationships["friend_a"] == 1)
            }
        }

        // MARK: naming

        @Test func saveSheepNameCreatesTheConfigAndEmitsNamingComplete() throws {
            try withBrainRoot { _ in
                #expect(Config.needsOnboarding())
                let events = Captured(AppEvents.shared.namingComplete)
                defer { events.stop() }

                try WindowCommands.saveSheepName("Dolly")

                #expect(!Config.needsOnboarding())
                #expect(Config.getSheepName() == "Dolly")
                #expect(events.values == ["Dolly"])
            }
        }

        @Test func saveSheepNameKeepsTheRestOfTheConfig() throws {
            try withBrainRoot { _ in
                try seed {
                    $0.friends = [friend("friend_a", "A")]
                    $0.accessories = ["halo"]
                    $0.language = "german"
                }
                try WindowCommands.saveSheepName("Renamed")
                let config = try #require(Config.loadConfig())
                #expect(config.name == "Renamed")
                #expect(config.friends == [friend("friend_a", "A")])
                #expect(config.accessories == ["halo"])
                #expect(config.language == "german")
            }
        }
    }
}

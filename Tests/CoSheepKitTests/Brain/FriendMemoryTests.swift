import Foundation
import Testing
@testable import CoSheepKit

// Ex-friend_memory.rs tests + persistence/decay/mood coverage.
extension BrainTests {
    @Suite("friend memory")
    struct FriendMemoryTests {
        private func brainFile(_ id: String) -> URL {
            Paths.friends.appendingPathComponent("\(id).json")
        }

        // MARK: ported from friend_memory.rs

        /// One test covering the whole removal scenario (the brain cache is process-global).
        @Test func removeBrainDeletesFileAndScrubsRelationships() throws {
            try withBrainRoot { _ in
                FriendMemory.ensureBrain("friend_a", "A")
                FriendMemory.ensureBrain("friend_b", "B")
                FriendMemory.recordConversation("friend_a", "friend_b", "tabs vs spaces")

                #expect(FileManager.default.fileExists(atPath: brainFile("friend_a").path))
                #expect(FriendMemory.getFriendBrainJSON("friend_b")["relationships"]?["friend_a"] != nil)

                FriendMemory.removeBrain("friend_a")

                #expect(!FileManager.default.fileExists(atPath: brainFile("friend_a").path),
                        "brain file must be deleted")
                #expect(FriendMemory.getAllMoods()["friend_a"] == nil,
                        "cache must evict the removed brain")
                #expect(FriendMemory.getFriendBrainJSON("friend_b")["relationships"]?["friend_a"] == nil,
                        "other brains must be scrubbed")
                // Scrub must persist, not just touch the cache. Memories still
                // mention the departed friend by design — only relationships scrub.
                let onDisk = try readJSON(brainFile("friend_b"))
                #expect(onDisk["relationships"]?["friend_a"] == nil)
                #expect(onDisk["memories"]?.arrayValue?[0]["with"]?.stringValue == "friend_a")
            }
        }

        @Test func chatContextIsCompactAndCapped() {
            withBrainRoot { _ in
                var brain = FriendMemory.newBrain("pelle", "Pelle")
                brain.mood = "grumpy"
                brain.relationships["kari"] = 35
                for i in 0..<10 {
                    FriendMemory.addMemory(
                        &brain, "Talked with Kari about very important sheep business number \(i)",
                        "conversation", with: "kari")
                }
                let ctx = FriendMemory.formatChatContext(brain, "kari", "Kari")
                #expect(ctx.hasPrefix("Pelle is grumpy and loves Kari."))
                #expect(ctx.contains("number 9")) // most recent memory included
                #expect(!ctx.contains("number 0")) // only the last 3
                #expect(ctx.utf8.count <= 300)
            }
        }

        // MARK: new — chat context

        @Test func chatContextAffinityLabels() {
            withBrainRoot { _ in
                var brain = FriendMemory.newBrain("a", "A")
                brain.mood = "happy"
                for (affinity, label) in [(31, "loves"), (30, "likes"), (11, "likes"), (10, "is neutral toward"),
                                          (0, "is neutral toward"), (-1, "avoids")] {
                    brain.relationships["b"] = affinity
                    #expect(FriendMemory.formatChatContext(brain, "b", "B") == "A is happy and \(label) B.")
                }
                #expect(FriendMemory.formatChatContext(brain, "stranger", "S") == "A is happy and is neutral toward S.")
            }
        }

        @Test func chatContextCapCutsOnACharBoundary() {
            withBrainRoot { _ in
                var brain = FriendMemory.newBrain("a", "A")
                for _ in 0..<3 {
                    FriendMemory.addMemory(&brain, String(repeating: "æ", count: 100), "conversation", with: nil)
                }
                let ctx = FriendMemory.formatChatContext(brain, "b", "B")
                #expect(ctx.utf8.count <= 300)
                #expect(ctx.utf8.count >= 299)
                #expect(String(ctx.last!) == "æ")
            }
        }

        // MARK: new — brains

        @Test func newBrainDefaults() {
            withBrainRoot(now: localDate(2026, 7, 4, 9, 5)) { _ in
                let gc = FriendMemory.newBrain("good_colleague", "Good Colleague")
                #expect(gc.mood == "grumpy")
                #expect(gc.relationships == ["main": 10])
                let other = FriendMemory.newBrain("friend_1", "Pelle")
                #expect(other.mood == "happy")
                #expect(other.relationships.isEmpty)
                #expect(other.stats == FriendStats())
                #expect(other.lastMoodChange == "2026-07-04 09:05")
                #expect(other.lastDecayDate == "2026-07-04")
            }
        }

        @Test func brainJSONKeepsRustShapeIncludingNullWith() throws {
            try withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                FriendMemory.ensureBrain("a", "A")
                FriendMemory.ensureBrain("b", "B")
                FriendMemory.recordGroupActivity(["a", "b"], "campfire")
                FriendMemory.recordConversation("a", "b", "wool")
                let json = try #require(try readJSON(brainFile("a")).objectValue)
                #expect(Set(json.keys) == [
                    "id", "name", "mood", "relationships", "memories", "stats",
                    "last_mood_change", "last_decay_date",
                ])
                let stats = try #require(json["stats"]?.objectValue)
                #expect(Set(stats.keys) == [
                    "conversations_today", "conversations_total", "times_petted",
                    "group_activities", "days_alive",
                ])
                let memories = try #require(json["memories"]?.arrayValue)
                #expect(memories[0]["with"] == .null)        // group activity: `"with": null`, key present
                #expect(memories[0].objectValue?.keys.contains("with") == true)
                #expect(memories[1]["with"] == .string("b"))
            }
        }

        @Test func loadsALegacyBrainFileWithoutLastDecayDate() throws {
            try withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                try write(#"""
                {"id":"friend_9","name":"Old","mood":"sleepy","relationships":{"main":4},
                 "memories":[{"text":"Got petted by human!","kind":"interaction","timestamp":"2026-07-01 10:00"}],
                 "stats":{"conversations_today":0,"conversations_total":3,"times_petted":1,"group_activities":0,"days_alive":6},
                 "last_mood_change":"2026-07-01 10:00"}
                """#, to: brainFile("friend_9"))
                FriendMemory.ensureBrain("friend_9", "Renamed")
                let b = FriendMemory.getFriendBrain("friend_9")
                #expect(b.name == "Renamed")               // ensure_brain adopts the configured name
                #expect(b.lastDecayDate == "")
                #expect(b.memories.first?.with == nil)
                #expect(b.stats.daysAlive == 6)
                #expect(FriendMemory.getMood("friend_9") == "sleepy")
            }
        }

        @Test func corruptBrainFileFallsBackToANewBrain() throws {
            try withBrainRoot { _ in
                try write("{ nope", to: brainFile("friend_x"))
                FriendMemory.ensureBrain("friend_x", "Xavier")
                #expect(FriendMemory.getFriendBrain("friend_x").name == "Xavier")
                #expect(FriendMemory.getMood("friend_x") == "happy")
            }
        }

        @Test func unknownIdsGetABrainNamedAfterTheirId() {
            withBrainRoot { _ in
                #expect(FriendMemory.getFriendBrain("ghost").name == "ghost")
                #expect(FriendMemory.getAllMoods()["ghost"] == "happy")
            }
        }

        @Test func ensureBrainDoesNotTouchDiskOrAnExistingCacheEntry() {
            withBrainRoot { _ in
                FriendMemory.ensureBrain("a", "A")
                #expect(!FileManager.default.fileExists(atPath: brainFile("a").path))
                FriendMemory.ensureBrain("a", "Different")
                #expect(FriendMemory.getFriendBrain("a").name == "A")
            }
        }

        // MARK: new — recording

        @Test func recordConversationUpdatesBothSides() {
            withBrainRoot(now: localDate(2026, 7, 4, 10, 30)) { _ in
                FriendMemory.ensureBrain("a", "Anna")
                FriendMemory.ensureBrain("b", "Bo")
                FriendMemory.recordConversation("a", "b", "tabs")
                let a = FriendMemory.getFriendBrain("a")
                let b = FriendMemory.getFriendBrain("b")
                #expect(a.relationships["b"] == 1)
                #expect(b.relationships["a"] == 1)
                #expect(a.memories == [FriendMemoryEntry(
                    text: "Talked with Bo about tabs", kind: "conversation",
                    timestamp: "2026-07-04 10:30", with: "b")])
                #expect(b.memories.first?.text == "Talked with Anna about tabs")
                #expect(a.stats.conversationsTotal == 1 && a.stats.conversationsToday == 1)
                #expect(b.stats.conversationsTotal == 1 && b.stats.conversationsToday == 1)
            }
        }

        @Test func recordGroupActivityListsTheOthersAndBoostsAffinity() {
            withBrainRoot { _ in
                for (id, name) in [("a", "Anna"), ("b", "Bo"), ("c", "Cy")] { FriendMemory.ensureBrain(id, name) }
                FriendMemory.recordGroupActivity(["a", "b", "c"], "campfire")
                let a = FriendMemory.getFriendBrain("a")
                #expect(a.memories.last?.text == "Joined a campfire with Bo, Cy")
                #expect(a.memories.last?.kind == "activity")
                #expect(a.memories.last?.with == nil)
                #expect(a.relationships == ["b": 2, "c": 2])
                #expect(a.stats.groupActivities == 1)
            }
        }

        @Test func recordPetMakesTheFriendHappy() {
            withBrainRoot(now: localDate(2026, 7, 4, 8, 0)) { _ in
                FriendMemory.ensureBrain("good_colleague", "Good Colleague")
                #expect(FriendMemory.getMood("good_colleague") == "grumpy")
                FriendMemory.recordPet("good_colleague")
                let gc = FriendMemory.getFriendBrain("good_colleague")
                #expect(gc.mood == "happy")
                #expect(gc.relationships["main"] == 11)
                #expect(gc.stats.timesPetted == 1)
                #expect(gc.memories.last?.text == "Got petted by human!")
                #expect(gc.memories.last?.with == "main")
                #expect(gc.lastMoodChange == "2026-07-04 08:00")
            }
        }

        @Test func memoriesAreCappedAtTwenty() {
            withBrainRoot { _ in
                var brain = FriendMemory.newBrain("a", "A")
                for i in 0..<25 { FriendMemory.addMemory(&brain, "m\(i)", "conversation", with: nil) }
                #expect(brain.memories.count == 20)
                #expect(brain.memories.first?.text == "m5")
                #expect(brain.memories.last?.text == "m24")
            }
        }

        @Test func affinityIsClamped() {
            withBrainRoot { _ in
                var brain = FriendMemory.newBrain("a", "A")
                FriendMemory.adjustAffinity(&brain, "b", 500)
                #expect(brain.relationships["b"] == 100)
                FriendMemory.adjustAffinity(&brain, "b", -500)
                #expect(brain.relationships["b"] == -10)
            }
        }

        // MARK: new — decay, mood, viewers

        @Test func decayAgesBrainsOncePerDayAndPersists() throws {
            try withBrainRoot(now: localDate(2026, 7, 4, 12, 0)) { _ in
                try write(#"""
                {"id":"a","name":"A","mood":"happy","relationships":{"b":5,"c":0,"d":-3,"e":-9},
                 "memories":[],"stats":{"conversations_today":4,"conversations_total":4,"times_petted":0,"group_activities":0,"days_alive":2},
                 "last_mood_change":"2026-07-03 10:00","last_decay_date":"2026-07-03"}
                """#, to: brainFile("a"))
                FriendMemory.ensureBrain("a", "A")

                FriendMemory.decayAffinities()
                var a = FriendMemory.getFriendBrain("a")
                #expect(a.relationships == ["b": 4, "c": 0, "d": -3, "e": -5])
                #expect(a.stats.conversationsToday == 0)
                #expect(a.stats.daysAlive == 3)
                #expect(a.lastDecayDate == "2026-07-04")
                #expect(try readJSON(brainFile("a"))["last_decay_date"] == .string("2026-07-04"))

                // Same day again (in-process guard), and after a "restart" (persisted guard).
                FriendMemory.decayAffinities()
                #expect(FriendMemory.getFriendBrain("a").stats.daysAlive == 3)
                FriendMemory.resetCache()
                FriendMemory.ensureBrain("a", "A")
                FriendMemory.decayAffinities()
                a = FriendMemory.getFriendBrain("a")
                #expect(a.stats.daysAlive == 3)
                #expect(a.relationships["b"] == 4)
            }
        }

        @Test func decayAgainOnTheNextDay() {
            withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                FriendMemory.ensureBrain("a", "A")   // new brain: last_decay_date = today
                FriendMemory.decayAffinities()
                #expect(FriendMemory.getFriendBrain("a").stats.daysAlive == 0)
                SimClock.nowSource = { localDate(2026, 7, 5).timeIntervalSince1970 * 1000 }
                FriendMemory.decayAffinities()
                #expect(FriendMemory.getFriendBrain("a").stats.daysAlive == 1)
            }
        }

        @Test func updateMoodFollowsConversationsAndHour() {
            func mood(hour: Int, convos: Int, petted: Int = 0, start: String = "happy", id: String = "a") -> String {
                SimClock.nowSource = { localDate(2026, 7, 4, hour, 0).timeIntervalSince1970 * 1000 }
                FriendMemory.resetCache()
                var b = FriendMemory.newBrain(id, id)
                b.mood = start
                b.stats.conversationsToday = convos
                b.stats.timesPetted = petted
                // Persist the crafted brain, then load it through the cache.
                try? JSONFile.write(b, to: brainFile(id))
                FriendMemory.ensureBrain(id, id)
                FriendMemory.updateMood(id)
                return FriendMemory.getMood(id)
            }
            withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                #expect(mood(hour: 12, convos: 5) == "excited")
                #expect(mood(hour: 12, convos: 2) == "happy")
                #expect(mood(hour: 23, convos: 0) == "sleepy")
                #expect(mood(hour: 4, convos: 0) == "sleepy")
                #expect(mood(hour: 5, convos: 0, start: "sleepy") == "happy")
                #expect(mood(hour: 12, convos: 0, petted: 1, start: "happy", id: "good_colleague") == "happy")
                #expect(mood(hour: 12, convos: 0, petted: 0, start: "happy", id: "good_colleague") == "grumpy")
                #expect(mood(hour: 12, convos: 1, start: "excited") == "happy")
            }
        }

        @Test func relationshipsAndMoodsCoverEveryCachedBrain() {
            withBrainRoot { _ in
                FriendMemory.ensureBrain("good_colleague", "Good Colleague")
                FriendMemory.ensureBrain("f1", "Pelle")
                FriendMemory.recordPet("f1")
                let rels = FriendMemory.getAllRelationships()
                #expect(Set(rels.keys) == ["good_colleague", "f1"])
                #expect(rels["f1"]?.name == "Pelle")
                #expect(rels["f1"]?.mood == "happy")
                #expect(rels["f1"]?.relationships == ["main": 1])
                #expect(rels["f1"]?.stats == .init(conversationsTotal: 0, timesPetted: 1, groupActivities: 0))
                #expect(FriendMemory.getAllMoods() == ["good_colleague": "grumpy", "f1": "happy"])
            }
        }
    }
}

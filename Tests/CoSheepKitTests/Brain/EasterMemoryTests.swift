import Foundation
import Testing
@testable import CoSheepKit

// easter_memory.rs had no tests; these pin its behavior and serde shape.
extension BrainTests {
    @Suite("easter memory")
    struct EasterMemoryTests {
        private func hunt(
            allCollected: Bool = true, painted: Int = 0,
            _ hunters: [(id: String, name: String, eggs: Int, golden: Int)]
        ) -> EasterHuntResult {
            EasterHuntResult(
                totalEggs: hunters.reduce(0) { $0 + $1.eggs }, durationMs: 60_000,
                allCollected: allCollected, paintedEggsUsed: painted,
                hunters: hunters.map {
                    EasterHunterResult(id: $0.id, name: $0.name, eggsFound: $0.eggs, goldenEggsFound: $0.golden)
                })
        }

        private func playOn(_ y: Int, _ m: Int, _ d: Int, allCollected: Bool = true) -> EasterStats {
            SimClock.nowSource = { localDate(y, m, d, 12).timeIntervalSince1970 * 1000 }
            return EasterMemory.recordHunt(hunt(allCollected: allCollected, [(id: "a", name: "A", eggs: 1, golden: 0)]))
        }

        @Test func huntResultDecodesTheOverlaysCamelCase() throws {
            let json = #"""
            {"totalEggs": 9, "durationMs": 61234, "allCollected": true, "paintedEggsUsed": 2,
             "hunters": [{"id": "main", "name": "Dolly", "eggsFound": 5, "goldenEggsFound": 1},
                         {"id": "f1", "name": "Pelle"}]}
            """#
            let r = try JSONDecoder().decode(EasterHuntResult.self, from: Data(json.utf8))
            #expect(r.totalEggs == 9)
            #expect(r.durationMs == 61_234)
            #expect(r.allCollected)
            #expect(r.paintedEggsUsed == 2)
            #expect(r.hunters == [
                EasterHunterResult(id: "main", name: "Dolly", eggsFound: 5, goldenEggsFound: 1),
                EasterHunterResult(id: "f1", name: "Pelle"),
            ])
            let empty = try JSONDecoder().decode(EasterHuntResult.self, from: Data("{}".utf8))
            #expect(empty == EasterHuntResult())
        }

        @Test func statsDecodeFromAnEmptyObjectAndKeepSnakeCaseKeys() throws {
            let s = try JSONDecoder().decode(EasterStats.self, from: Data("{}".utf8))
            #expect(s == EasterStats())
            let data = try JSONEncoder().encode(EasterStats())
            let json = try #require(try JSONDecoder().decode(JSONValue.self, from: data).objectValue)
            #expect(Set(json.keys) == [
                "last_reset_date", "last_hunt_date", "eggs_found_total", "eggs_found_today",
                "golden_eggs_total", "golden_eggs_today", "hunts_completed", "hunts_today",
                "current_streak", "best_streak", "painted_eggs_used_total", "flock_score",
                "top_hunter_id", "top_hunter_name", "last_winner_id", "last_winner_name", "hunters",
            ])
        }

        @Test func firstStatsAreFreshWithTodaysResetDate() {
            withBrainRoot(now: localDate(2026, 4, 5)) { _ in
                let s = EasterMemory.getStats()
                #expect(s == { var e = EasterStats(); e.lastResetDate = "2026-04-05"; return e }())
                #expect(!FileManager.default.fileExists(atPath: Paths.easterStats.path)) // unchanged: not saved
            }
        }

        @Test func recordHuntAggregatesAndPersists() throws {
            try withBrainRoot(now: localDate(2026, 4, 5)) { _ in
                let stats = EasterMemory.recordHunt(hunt(painted: 2, [
                    (id: "main", name: "Dolly", eggs: 5, golden: 1),
                    (id: "f1", name: "Pelle", eggs: 3, golden: 0),
                ]))
                #expect(stats.eggsFoundTotal == 8 && stats.eggsFoundToday == 8)
                #expect(stats.goldenEggsTotal == 1 && stats.goldenEggsToday == 1)
                #expect(stats.paintedEggsUsedTotal == 2)
                #expect(stats.huntsToday == 1 && stats.huntsCompleted == 1)
                #expect(stats.currentStreak == 1 && stats.bestStreak == 1)
                #expect(stats.lastHuntDate == "2026-04-05")
                #expect(stats.lastWinnerId == "main" && stats.lastWinnerName == "Dolly")
                #expect(stats.topHunterId == "main" && stats.topHunterName == "Dolly")
                // 8 eggs + 1 golden×4 + 1 hunt×3 + best streak 1×2 + 2 painted
                #expect(stats.flockScore == 8 + 4 + 3 + 2 + 2)
                let main = try #require(stats.hunters["main"])
                #expect(main == EasterHunterStats(
                    sheepId: "main", sheepName: "Dolly", eggsFoundTotal: 5, eggsFoundToday: 5,
                    goldenEggsFound: 1, huntsWon: 1, huntsParticipated: 1))
                #expect(stats.hunters["f1"]?.huntsWon == 0)

                // Persisted in the Rust shape, and reloaded unchanged.
                let json = try #require(try readJSON(Paths.easterStats).objectValue)
                #expect(json["hunters"]?["main"]?["sheep_name"] == .string("Dolly"))
                #expect(EasterMemory.getStats() == stats)
            }
        }

        @Test func winnerNeedsEggsAndTiesGoToTheLaterHunter() {
            withBrainRoot(now: localDate(2026, 4, 5)) { _ in
                var s = EasterMemory.recordHunt(hunt([(id: "a", name: "A", eggs: 0, golden: 0)]))
                #expect(s.lastWinnerId == "")
                #expect(s.hunters["a"]?.huntsWon == 0)
                #expect(s.hunters["a"]?.huntsParticipated == 1)
                // tie on eggs and golden: Rust `max_by` keeps the last
                s = EasterMemory.recordHunt(hunt([
                    (id: "a", name: "A", eggs: 2, golden: 0),
                    (id: "b", name: "B", eggs: 2, golden: 0),
                ]))
                #expect(s.lastWinnerId == "b")
                // golden eggs break the tie
                s = EasterMemory.recordHunt(hunt([
                    (id: "a", name: "A", eggs: 2, golden: 1),
                    (id: "b", name: "B", eggs: 2, golden: 0),
                ]))
                #expect(s.lastWinnerId == "a")
            }
        }

        @Test func hunterNamesFollowTheLatestResult() {
            withBrainRoot(now: localDate(2026, 4, 5)) { _ in
                EasterMemory.recordHunt(hunt([(id: "f1", name: "Old", eggs: 1, golden: 0)]))
                let s = EasterMemory.recordHunt(hunt([(id: "f1", name: "New", eggs: 1, golden: 0)]))
                #expect(s.hunters["f1"]?.sheepName == "New")
                #expect(s.hunters["f1"]?.eggsFoundTotal == 2)
                #expect(s.topHunterName == "New")
            }
        }

        @Test func streakGrowsOnConsecutiveDaysAndResetsAfterAGap() {
            withBrainRoot(now: localDate(2026, 4, 5)) { _ in
                #expect(playOn(2026, 4, 5).currentStreak == 1)
                #expect(playOn(2026, 4, 5).currentStreak == 1)   // same day: no double count
                #expect(playOn(2026, 4, 6).currentStreak == 2)
                #expect(playOn(2026, 4, 7, allCollected: false).currentStreak == 2)   // incomplete: untouched
                var s = playOn(2026, 4, 9)                        // gap
                #expect(s.currentStreak == 1)
                #expect(s.bestStreak == 2)
                s = playOn(2026, 4, 10)
                #expect(s.currentStreak == 2)
                #expect(s.huntsCompleted == 5)
            }
        }

        @Test func dailyCountersRollOverOnANewDay() throws {
            try withBrainRoot(now: localDate(2026, 4, 5)) { _ in
                EasterMemory.recordHunt(hunt([(id: "a", name: "A", eggs: 4, golden: 1)]))
                SimClock.nowSource = { localDate(2026, 4, 6, 8).timeIntervalSince1970 * 1000 }
                let s = EasterMemory.getStats()
                #expect(s.eggsFoundToday == 0 && s.goldenEggsToday == 0 && s.huntsToday == 0)
                #expect(s.hunters["a"]?.eggsFoundToday == 0)
                #expect(s.eggsFoundTotal == 4)
                #expect(s.lastResetDate == "2026-04-06")
                // and the rollover was written back
                let onDisk = try readJSON(Paths.easterStats)
                #expect(onDisk["last_reset_date"] == .string("2026-04-06"))
            }
        }

        @Test func leaderboardBreaksTiesOnGoldenThenWins() {
            withBrainRoot(now: localDate(2026, 4, 5)) { _ in
                EasterMemory.recordHunt(hunt(allCollected: false, [(id: "a", name: "A", eggs: 3, golden: 0)]))
                let s = EasterMemory.recordHunt(hunt(allCollected: false, [(id: "b", name: "B", eggs: 3, golden: 1)]))
                #expect(s.topHunterId == "b")
            }
        }

        @Test func corruptStatsFileFallsBackToFreshStats() throws {
            try withBrainRoot(now: localDate(2026, 4, 5)) { _ in
                try write("not json", to: Paths.easterStats)
                #expect(EasterMemory.getStats().eggsFoundTotal == 0)
            }
        }
    }
}

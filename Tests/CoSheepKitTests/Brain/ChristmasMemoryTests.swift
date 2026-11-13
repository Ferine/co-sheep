import Foundation
import Testing
@testable import CoSheepKit

extension BrainTests {
    @Suite("christmas memory")
    struct ChristmasMemoryTests {
        private let december13 = localDate(2026, 12, 13)

        @Test func aFreshCalendarStartsWithTheSeasonYearAndNothingOpened() throws {
            try withBrainRoot(now: december13) { _ in
                let stats = ChristmasMemory.getStats()
                #expect(stats.seasonYear == 2026)
                #expect(stats.doorsOpened.isEmpty)
                #expect(stats.lastDoorDate == "")
                #expect(stats.giftsOpenedTotal == 0 && stats.carolsSungTotal == 0 && stats.sleighsSeenTotal == 0)
                // Rolling into the season is persisted
                let json = try #require(try readJSON(Paths.christmasStats).objectValue)
                #expect(json["season_year"] == .number(2026))
            }
        }

        @Test func openingADoorPersistsItSortedAndOnce() throws {
            try withBrainRoot(now: december13) { _ in
                ChristmasMemory.openDoor(7)
                ChristmasMemory.openDoor(3)
                let stats = ChristmasMemory.openDoor(7)
                #expect(stats.doorsOpened == [3, 7])
                #expect(stats.lastDoorDate == "2026-12-13")
                #expect(ChristmasMemory.getStats() == stats)

                let json = try #require(try readJSON(Paths.christmasStats).objectValue)
                #expect(Set(json.keys) == [
                    "season_year", "doors_opened", "last_door_date",
                    "gifts_opened_total", "carols_sung_total", "sleighs_seen_total",
                ])
                #expect(json["doors_opened"] == .array([.number(3), .number(7)]))
            }
        }

        @Test func doorsOutsideTheCalendarAreIgnored() {
            withBrainRoot(now: december13) { _ in
                ChristmasMemory.openDoor(0)
                ChristmasMemory.openDoor(25)
                let stats = ChristmasMemory.openDoor(-3)
                #expect(stats.doorsOpened.isEmpty)
                #expect(stats.lastDoorDate == "")
            }
        }

        @Test func theNextDoorCatchesUpOldestFirst() {
            var stats = ChristmasStats()
            #expect(stats.nextDoor(dueDoor: nil) == nil)
            #expect(stats.nextDoor(dueDoor: 0) == nil)
            #expect(stats.nextDoor(dueDoor: 1) == 1)
            stats.doorsOpened = [1, 2, 4]
            #expect(stats.nextDoor(dueDoor: 5) == 3)
            stats.doorsOpened = [1, 2, 3, 4, 5]
            #expect(stats.nextDoor(dueDoor: 5) == nil)
            #expect(stats.nextDoor(dueDoor: 6) == 6)
            stats.doorsOpened = Array(1...24)
            #expect(stats.nextDoor(dueDoor: 24) == nil)
            #expect(stats.nextDoor(dueDoor: 99) == nil)
        }

        @Test func talliesAddUp() {
            withBrainRoot(now: december13) { _ in
                ChristmasMemory.recordGifts(3)
                ChristmasMemory.recordGifts(-2) // never subtracts
                ChristmasMemory.recordCarol()
                ChristmasMemory.recordCarol()
                let stats = ChristmasMemory.recordSleigh()
                #expect(stats.giftsOpenedTotal == 3)
                #expect(stats.carolsSungTotal == 2)
                #expect(stats.sleighsSeenTotal == 1)
            }
        }

        @Test func januaryKeepsTheCalendarOfTheDecemberBefore() {
            withBrainRoot(now: december13) { _ in
                ChristmasMemory.openDoor(1)
                ChristmasMemory.openDoor(2)
                SimClock.nowSource = { localDate(2027, 1, 4).timeIntervalSince1970 * 1000 }
                let stats = ChristmasMemory.getStats()
                #expect(stats.seasonYear == 2026)
                #expect(stats.doorsOpened == [1, 2])
            }
        }

        @Test func aNewDecemberStartsAFreshCalendarButKeepsTheTallies() {
            withBrainRoot(now: december13) { _ in
                ChristmasMemory.openDoor(1)
                ChristmasMemory.recordGifts(4)
                ChristmasMemory.recordCarol()
                SimClock.nowSource = { localDate(2027, 12, 2).timeIntervalSince1970 * 1000 }
                let stats = ChristmasMemory.getStats()
                #expect(stats.seasonYear == 2027)
                #expect(stats.doorsOpened.isEmpty)
                #expect(stats.lastDoorDate == "")
                #expect(stats.giftsOpenedTotal == 4)
                #expect(stats.carolsSungTotal == 1)
                // A write in the new season rolls it too
                #expect(ChristmasMemory.openDoor(2).doorsOpened == [2])
            }
        }

        @Test func anEmptyObjectIsAValidFileAndDoorsAreNormalizedOnLoad() throws {
            try withBrainRoot(now: december13) { _ in
                try write("{}", to: Paths.christmasStats)
                #expect(ChristmasMemory.getStats().doorsOpened.isEmpty)

                try write(#"{"season_year": 2026, "doors_opened": [5, 99, 2, 5, 0], "gifts_opened_total": 7}"#,
                          to: Paths.christmasStats)
                let stats = ChristmasMemory.getStats()
                #expect(stats.doorsOpened == [2, 5])
                #expect(stats.giftsOpenedTotal == 7)
            }
        }

        @Test func aCorruptFileIsQuarantinedNotOverwritten() throws {
            try withBrainRoot(now: december13) { root in
                try write("ho ho no", to: Paths.christmasStats)
                let stats = ChristmasMemory.getStats()
                #expect(stats.seasonYear == 2026 && stats.doorsOpened.isEmpty)
                let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
                #expect(names.contains { $0.hasPrefix("christmas.json.corrupt-") })
            }
        }
    }
}

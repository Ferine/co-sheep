import Foundation
import Testing
@testable import CoSheepKit

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    localDate(y, m, d, h, min)
}

@Suite("christmas season")
struct ChristmasSeasonTests {
    @Test func runsFromDecemberFirstThroughJanuarySixth() {
        #expect(ChristmasSeason.isSeason(at(2026, 11, 30, 23, 59)) == false)
        #expect(ChristmasSeason.isSeason(at(2026, 12, 1, 0, 0)) == true)
        #expect(ChristmasSeason.isSeason(at(2026, 12, 24)) == true)
        #expect(ChristmasSeason.isSeason(at(2026, 12, 31, 23, 59)) == true)
        #expect(ChristmasSeason.isSeason(at(2027, 1, 1, 0, 0)) == true)
        #expect(ChristmasSeason.isSeason(at(2027, 1, 6, 23, 59)) == true)
        #expect(ChristmasSeason.isSeason(at(2027, 1, 7, 0, 0)) == false)
        #expect(ChristmasSeason.isSeason(at(2026, 7, 15)) == false)
    }

    @Test func theOverrideBeatsTheCalendar() {
        let july = at(2026, 7, 15)
        let december = at(2026, 12, 15)
        #expect(ChristmasSeason.isActive(mode: .on, july))
        #expect(!ChristmasSeason.isActive(mode: .off, december))
        #expect(!ChristmasSeason.isActive(mode: .auto, july))
        #expect(ChristmasSeason.isActive(mode: .auto, december))
        #expect(ChristmasMode.allCases.map(\.rawValue) == ["auto", "on", "off"])
    }

    @Test func defaultsToTheSimClock() {
        withSim(now: localMs(2026, 12, 15)) {
            #expect(ChristmasSeason.isSeason())
            #expect(ChristmasSeason.isActive(mode: .auto))
            #expect(ChristmasSeason.dueDoor() == 15)
            #expect(ChristmasSeason.seasonYear() == 2026)
            #expect(ChristmasSeason.daysUntilChristmasEve() == 9)
            #expect(ChristmasSeason.moment() == .advent(day: 15, daysLeft: 9))
        }
        withSim(now: localMs(2026, 7, 15)) {
            #expect(!ChristmasSeason.isSeason())
            #expect(ChristmasSeason.dueDoor() == nil)
            #expect(ChristmasSeason.moment() == .outOfSeason)
        }
    }

    @Test func januaryBelongsToTheCalendarOfTheYearBefore() {
        #expect(ChristmasSeason.seasonYear(at(2026, 12, 1)) == 2026)
        #expect(ChristmasSeason.seasonYear(at(2027, 1, 3)) == 2026)
        #expect(ChristmasSeason.seasonYear(at(2027, 2, 1)) == 2027)
        #expect(ChristmasSeason.seasonYear(at(2027, 7, 15)) == 2027)
    }

    @Test func theDueDoorIsTheDayOfDecemberCappedAtTwentyFour() {
        #expect(ChristmasSeason.doorCount == 24)
        #expect(ChristmasSeason.dueDoor(at(2026, 11, 30)) == nil)
        #expect(ChristmasSeason.dueDoor(at(2026, 12, 1, 0, 0)) == 1)
        #expect(ChristmasSeason.dueDoor(at(2026, 12, 13)) == 13)
        #expect(ChristmasSeason.dueDoor(at(2026, 12, 24)) == 24)
        // After Christmas Eve every door may be caught up, until the season ends
        #expect(ChristmasSeason.dueDoor(at(2026, 12, 28)) == 24)
        #expect(ChristmasSeason.dueDoor(at(2027, 1, 6)) == 24)
        #expect(ChristmasSeason.dueDoor(at(2027, 1, 7)) == nil)
    }

    @Test func countsTheDaysToChristmasEve() {
        #expect(ChristmasSeason.daysUntilChristmasEve(at(2026, 12, 1)) == 23)
        #expect(ChristmasSeason.daysUntilChristmasEve(at(2026, 12, 23)) == 1)
        #expect(ChristmasSeason.daysUntilChristmasEve(at(2026, 12, 24)) == 0)
        #expect(ChristmasSeason.daysUntilChristmasEve(at(2026, 12, 25)) == nil)
        #expect(ChristmasSeason.daysUntilChristmasEve(at(2026, 11, 30)) == nil)
        #expect(ChristmasSeason.daysUntilChristmasEve(at(2027, 1, 2)) == nil)
    }

    @Test func momentsOfTheSeason() {
        #expect(ChristmasSeason.moment(at(2026, 12, 1)) == .advent(day: 1, daysLeft: 23))
        #expect(ChristmasSeason.moment(at(2026, 12, 23)) == .advent(day: 23, daysLeft: 1))
        #expect(ChristmasSeason.moment(at(2026, 12, 24)) == .christmasEve)
        #expect(ChristmasSeason.moment(at(2026, 12, 25)) == .christmasDay)
        #expect(ChristmasSeason.moment(at(2026, 12, 26)) == .romjul)
        #expect(ChristmasSeason.moment(at(2026, 12, 30)) == .romjul)
        #expect(ChristmasSeason.moment(at(2026, 12, 31)) == .newYearsEve)
        #expect(ChristmasSeason.moment(at(2027, 1, 1)) == .newYearsDay)
        #expect(ChristmasSeason.moment(at(2027, 1, 2)) == .windingDown)
        #expect(ChristmasSeason.moment(at(2027, 1, 6)) == .windingDown)
        #expect(ChristmasSeason.moment(at(2027, 1, 7)) == .outOfSeason)
        #expect(ChristmasSeason.moment(at(2026, 7, 15)) == .outOfSeason)
    }

    @Test func thePromptContextIsEmptyWhileChristmasIsOff() {
        #expect(ChristmasSeason.promptContext(mode: .auto, at(2026, 7, 15)) == "")
        #expect(ChristmasSeason.promptContext(mode: .off, at(2026, 12, 15)) == "")
    }

    @Test func thePromptContextDescribesTheSceneAndTheDay() {
        let scene = "SEASON: It's Christmas time (jul). The desktop is decorated with a Christmas tree, "
            + "string lights and snow, and every sheep wears a red Santa hat (nisselue)."
        func context(_ m: Int, _ d: Int, year: Int = 2026) -> String {
            ChristmasSeason.promptContext(mode: .auto, at(year, m, d))
        }
        #expect(context(12, 13) == scene
            + " It's December 13: 11 days until Christmas Eve, and today's julekalender door is number 13.")
        #expect(context(12, 23).contains("It's December 23: 1 day until Christmas Eve"))
        #expect(context(12, 24) == scene + " It's Christmas Eve (julaften), the big night.")
        #expect(context(12, 25) == scene + " It's Christmas Day.")
        #expect(context(12, 28) == scene + " It's romjul, the lazy days between Christmas and New Year.")
        #expect(context(12, 31) == scene + " It's New Year's Eve.")
        #expect(context(1, 1, year: 2027) == scene + " It's New Year's Day, and the tree is still up.")
        #expect(context(1, 5, year: 2027) == scene + " Christmas is winding down: the tree comes down after January 6.")
        // Forced on in July: the scene is real, the calendar is not
        #expect(ChristmasSeason.promptContext(mode: .on, at(2026, 7, 15)) == scene)
    }
}

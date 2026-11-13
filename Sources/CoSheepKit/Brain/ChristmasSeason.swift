import Foundation

// The Christmas calendar: when the season runs, which julekalender door is
// due, and what the prompts are told about it. Pure date math in `SimClock`'s
// zone, shared by the prompts (Brain) and the theme (Sim).

/// Settings override for the Christmas event (`christmas_mode` in config.json).
nonisolated enum ChristmasMode: String, CaseIterable, Codable {
    case auto, on, off
}

enum ChristmasSeason {
    /// A julekalender has 24 doors: December 1 through Christmas Eve.
    static let doorCount = 24

    private static var now: Date { Date(timeIntervalSince1970: SimClock.nowMs() / 1000) }

    private static func monthDay(_ date: Date) -> (month: Int, day: Int) {
        let c = SimClock.calendar.dateComponents([.month, .day], from: date)
        return (c.month ?? 1, c.day ?? 1)
    }

    /// December 1 through January 6 (trettendedag jul), so romjul still counts.
    /// `date` defaults to `SimClock`'s now (tests can pass one instead of overriding the clock).
    static func isSeason(_ date: Date? = nil) -> Bool {
        let (month, day) = monthDay(date ?? now)
        return month == 12 || (month == 1 && day <= 6)
    }

    /// The settings override wins; `auto` follows the calendar.
    static func isActive(mode: ChristmasMode, _ date: Date? = nil) -> Bool {
        switch mode {
        case .on: true
        case .off: false
        case .auto: isSeason(date)
        }
    }

    /// The December a date's julekalender belongs to: January still counts
    /// toward the calendar that started the year before.
    static func seasonYear(_ date: Date? = nil) -> Int {
        let date = date ?? now
        let c = SimClock.calendar.dateComponents([.year, .month], from: date)
        let year = c.year ?? 1970
        return c.month == 1 ? year - 1 : year
    }

    /// The highest door that may be open: the day of the month in December
    /// (capped at 24), all of them until the season ends, nil outside it.
    static func dueDoor(_ date: Date? = nil) -> Int? {
        let date = date ?? now
        guard isSeason(date) else { return nil }
        let (month, day) = monthDay(date)
        return month == 12 ? min(day, doorCount) : doorCount
    }

    /// Days left until Christmas Eve: 23 on December 1, 0 on the 24th, nil otherwise.
    static func daysUntilChristmasEve(_ date: Date? = nil) -> Int? {
        let (month, day) = monthDay(date ?? now)
        guard month == 12, day <= doorCount else { return nil }
        return doorCount - day
    }

    /// Where in the season a date falls, for the HUD and the prompts.
    enum Moment: Equatable {
        /// December 1–23: `day` of the month, `daysLeft` until Christmas Eve.
        case advent(day: Int, daysLeft: Int)
        case christmasEve
        case christmasDay
        /// December 26–30: the lazy days between Christmas and New Year.
        case romjul
        case newYearsEve
        case newYearsDay
        /// January 2–6: the tree is still up.
        case windingDown
        /// Forced on outside the season.
        case outOfSeason
    }

    static func moment(_ date: Date? = nil) -> Moment {
        let date = date ?? now
        guard isSeason(date) else { return .outOfSeason }
        let (month, day) = monthDay(date)
        if month == 1 { return day == 1 ? .newYearsDay : .windingDown }
        switch day {
        case ..<24: return .advent(day: day, daysLeft: doorCount - day)
        case 24: return .christmasEve
        case 25: return .christmasDay
        case 31: return .newYearsEve
        default: return .romjul
        }
    }

    /// "SEASON: …" for the system prompts, or "" while Christmas is off.
    static func promptContext(mode: ChristmasMode, _ date: Date? = nil) -> String {
        guard isActive(mode: mode, date) else { return "" }
        let scene = "SEASON: It's Christmas time (jul). The desktop is decorated with a Christmas tree, "
            + "string lights and snow, and every sheep wears a red Santa hat (nisselue)."
        let today: String
        switch moment(date) {
        case .advent(let day, let daysLeft):
            let left = daysLeft == 1 ? "1 day" : "\(daysLeft) days"
            today = " It's December \(day): \(left) until Christmas Eve, and today's julekalender door is number \(day)."
        case .christmasEve:
            today = " It's Christmas Eve (julaften), the big night."
        case .christmasDay:
            today = " It's Christmas Day."
        case .romjul:
            today = " It's romjul, the lazy days between Christmas and New Year."
        case .newYearsEve:
            today = " It's New Year's Eve."
        case .newYearsDay:
            today = " It's New Year's Day, and the tree is still up."
        case .windingDown:
            today = " Christmas is winding down: the tree comes down after January 6."
        case .outOfSeason:
            today = ""
        }
        return scene + today
    }
}

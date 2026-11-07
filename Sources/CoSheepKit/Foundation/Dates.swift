import Foundation

// Calendar dates and clock formatting shared by every layer. All of it reads
// `SimClock.nowMs()`, so tests can pin the time.

/// A calendar date without time or zone (ex-`chrono::NaiveDate`).
nonisolated struct NaiveDate: Hashable, Comparable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= Self.daysInMonth(year: year, month: month) else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// chrono `parse_from_str(s, "%Y-%m-%d")`: `Y-M-D`, 1–4 / 1–2 / 1–2 digits, nothing else.
    init?(parsing s: String) {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count <= 4, parts[1].count <= 2, parts[2].count <= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    private static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        default: isLeap(year) ? 29 : 28
        }
    }

    /// Days since 1970-01-01 (proleptic Gregorian; Hinnant's days_from_civil).
    var epochDays: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    init(epochDays z0: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        // Always valid by construction.
        self.year = y
        self.month = m
        self.day = d
    }

    func addingDays(_ n: Int) -> NaiveDate { NaiveDate(epochDays: epochDays + n) }

    /// `(self - other).num_days()`.
    func daysSince(_ other: NaiveDate) -> Int { epochDays - other.epochDays }

    /// `%Y-%m-%d`.
    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    static func < (a: NaiveDate, b: NaiveDate) -> Bool { a.epochDays < b.epochDays }
}

/// Local wall-clock helpers (ex-`chrono::Local::now().format(..)`). Reads
/// `SimClock.nowMs()` so tests can pin the time.
enum BrainTime {
    static var now: Date { Date(timeIntervalSince1970: SimClock.nowMs() / 1000) }

    private static var formatters: [String: DateFormatter] = [:]

    /// strftime-style output through fixed English POSIX patterns, in the
    /// local time zone, regardless of the user's locale/calendar settings.
    static func format(_ pattern: String, _ date: Date? = nil) -> String {
        let f: DateFormatter
        if let cached = formatters[pattern] {
            f = cached
        } else {
            f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.dateFormat = pattern
            formatters[pattern] = f
        }
        f.timeZone = SimClock.timeZone
        return f.string(from: date ?? now)
    }

    /// `%Y-%m-%d`
    static func today() -> String { format("yyyy-MM-dd") }

    /// `%Y-%m-%d %H:%M`
    static func nowStamp() -> String { format("yyyy-MM-dd HH:mm") }

    private static var calendar: Calendar { SimClock.calendar }

    /// `Local::now().date_naive()`
    static func todayNaive() -> NaiveDate { naive(now) }

    static func naive(_ date: Date) -> NaiveDate {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return NaiveDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
            ?? NaiveDate(epochDays: 0)
    }

    /// Local hour 0–23.
    static func hour() -> Int { calendar.component(.hour, from: now) }
}

/// `new Date().toISOString()` for an epoch-ms value: always UTC, always
/// `YYYY-MM-DDTHH:MM:SS.mmmZ`, computed with integer math so a millisecond
/// never rounds away. drama.json log entries carry it.
enum SimISO {
    static func timestamp(_ ms: Double) -> String {
        let total = ms.isFinite ? Int(max(-8.64e15, min(8.64e15, ms.rounded(.down)))) : 0
        let msPerDay = 86_400_000
        var days = total / msPerDay
        var rem = total % msPerDay
        if rem < 0 {
            rem += msPerDay
            days -= 1
        }
        let date = NaiveDate(epochDays: days)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            date.year, date.month, date.day,
            rem / 3_600_000, (rem / 60_000) % 60, (rem / 1000) % 60, rem % 1000)
    }
}

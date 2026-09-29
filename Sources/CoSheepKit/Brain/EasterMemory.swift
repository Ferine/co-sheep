import Foundation

// Ex-easter_memory.rs — the flock's egg-hunt scoreboard (`easter.json`).

nonisolated struct EasterHunterStats: Codable, Equatable {
    var sheepId: String
    var sheepName: String
    var eggsFoundTotal: Int = 0
    var eggsFoundToday: Int = 0
    var goldenEggsFound: Int = 0
    var huntsWon: Int = 0
    var huntsParticipated: Int = 0

    enum CodingKeys: String, CodingKey {
        case sheepId = "sheep_id"
        case sheepName = "sheep_name"
        case eggsFoundTotal = "eggs_found_total"
        case eggsFoundToday = "eggs_found_today"
        case goldenEggsFound = "golden_eggs_found"
        case huntsWon = "hunts_won"
        case huntsParticipated = "hunts_participated"
    }

    init(
        sheepId: String = "", sheepName: String = "", eggsFoundTotal: Int = 0, eggsFoundToday: Int = 0,
        goldenEggsFound: Int = 0, huntsWon: Int = 0, huntsParticipated: Int = 0
    ) {
        self.sheepId = sheepId
        self.sheepName = sheepName
        self.eggsFoundTotal = eggsFoundTotal
        self.eggsFoundToday = eggsFoundToday
        self.goldenEggsFound = goldenEggsFound
        self.huntsWon = huntsWon
        self.huntsParticipated = huntsParticipated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sheepId = try c.decode(String.self, forKey: .sheepId)
        sheepName = try c.decode(String.self, forKey: .sheepName)
        eggsFoundTotal = try c.decodeSerdeDefault(Int.self, forKey: .eggsFoundTotal, default: 0)
        eggsFoundToday = try c.decodeSerdeDefault(Int.self, forKey: .eggsFoundToday, default: 0)
        goldenEggsFound = try c.decodeSerdeDefault(Int.self, forKey: .goldenEggsFound, default: 0)
        huntsWon = try c.decodeSerdeDefault(Int.self, forKey: .huntsWon, default: 0)
        huntsParticipated = try c.decodeSerdeDefault(Int.self, forKey: .huntsParticipated, default: 0)
    }
}

nonisolated struct EasterStats: Codable, Equatable {
    var lastResetDate: String = ""
    var lastHuntDate: String = ""
    var eggsFoundTotal: Int = 0
    var eggsFoundToday: Int = 0
    var goldenEggsTotal: Int = 0
    var goldenEggsToday: Int = 0
    var huntsCompleted: Int = 0
    var huntsToday: Int = 0
    var currentStreak: Int = 0
    var bestStreak: Int = 0
    var paintedEggsUsedTotal: Int = 0
    var flockScore: Int = 0
    var topHunterId: String = ""
    var topHunterName: String = ""
    var lastWinnerId: String = ""
    var lastWinnerName: String = ""
    var hunters: [String: EasterHunterStats] = [:]

    enum CodingKeys: String, CodingKey {
        case lastResetDate = "last_reset_date"
        case lastHuntDate = "last_hunt_date"
        case eggsFoundTotal = "eggs_found_total"
        case eggsFoundToday = "eggs_found_today"
        case goldenEggsTotal = "golden_eggs_total"
        case goldenEggsToday = "golden_eggs_today"
        case huntsCompleted = "hunts_completed"
        case huntsToday = "hunts_today"
        case currentStreak = "current_streak"
        case bestStreak = "best_streak"
        case paintedEggsUsedTotal = "painted_eggs_used_total"
        case flockScore = "flock_score"
        case topHunterId = "top_hunter_id"
        case topHunterName = "top_hunter_name"
        case lastWinnerId = "last_winner_id"
        case lastWinnerName = "last_winner_name"
        case hunters
    }

    /// `EasterStats::default()` (all zero / empty — `last_reset_date` too).
    init() {}

    /// Every field is `#[serde(default)]`, so `{}` is a valid file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastResetDate = try c.decodeSerdeDefault(String.self, forKey: .lastResetDate, default: "")
        lastHuntDate = try c.decodeSerdeDefault(String.self, forKey: .lastHuntDate, default: "")
        eggsFoundTotal = try c.decodeSerdeDefault(Int.self, forKey: .eggsFoundTotal, default: 0)
        eggsFoundToday = try c.decodeSerdeDefault(Int.self, forKey: .eggsFoundToday, default: 0)
        goldenEggsTotal = try c.decodeSerdeDefault(Int.self, forKey: .goldenEggsTotal, default: 0)
        goldenEggsToday = try c.decodeSerdeDefault(Int.self, forKey: .goldenEggsToday, default: 0)
        huntsCompleted = try c.decodeSerdeDefault(Int.self, forKey: .huntsCompleted, default: 0)
        huntsToday = try c.decodeSerdeDefault(Int.self, forKey: .huntsToday, default: 0)
        currentStreak = try c.decodeSerdeDefault(Int.self, forKey: .currentStreak, default: 0)
        bestStreak = try c.decodeSerdeDefault(Int.self, forKey: .bestStreak, default: 0)
        paintedEggsUsedTotal = try c.decodeSerdeDefault(Int.self, forKey: .paintedEggsUsedTotal, default: 0)
        flockScore = try c.decodeSerdeDefault(Int.self, forKey: .flockScore, default: 0)
        topHunterId = try c.decodeSerdeDefault(String.self, forKey: .topHunterId, default: "")
        topHunterName = try c.decodeSerdeDefault(String.self, forKey: .topHunterName, default: "")
        lastWinnerId = try c.decodeSerdeDefault(String.self, forKey: .lastWinnerId, default: "")
        lastWinnerName = try c.decodeSerdeDefault(String.self, forKey: .lastWinnerName, default: "")
        hunters = try c.decodeSerdeDefault([String: EasterHunterStats].self, forKey: .hunters, default: [:])
    }
}

// The two result types arrive from the overlay as camelCase (totalEggs,
// eggsFound, ...): Swift's own names are already camelCase, so no CodingKeys.

nonisolated struct EasterHunterResult: Codable, Equatable {
    var id: String
    var name: String
    var eggsFound: Int = 0
    var goldenEggsFound: Int = 0

    init(id: String, name: String, eggsFound: Int = 0, goldenEggsFound: Int = 0) {
        self.id = id
        self.name = name
        self.eggsFound = eggsFound
        self.goldenEggsFound = goldenEggsFound
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        eggsFound = try c.decodeSerdeDefault(Int.self, forKey: .eggsFound, default: 0)
        goldenEggsFound = try c.decodeSerdeDefault(Int.self, forKey: .goldenEggsFound, default: 0)
    }
}

nonisolated struct EasterHuntResult: Codable, Equatable {
    var totalEggs: Int = 0
    var durationMs: Int = 0
    var allCollected: Bool = false
    var paintedEggsUsed: Int = 0
    var hunters: [EasterHunterResult] = []

    init(
        totalEggs: Int = 0, durationMs: Int = 0, allCollected: Bool = false,
        paintedEggsUsed: Int = 0, hunters: [EasterHunterResult] = []
    ) {
        self.totalEggs = totalEggs
        self.durationMs = durationMs
        self.allCollected = allCollected
        self.paintedEggsUsed = paintedEggsUsed
        self.hunters = hunters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalEggs = try c.decodeSerdeDefault(Int.self, forKey: .totalEggs, default: 0)
        durationMs = try c.decodeSerdeDefault(Int.self, forKey: .durationMs, default: 0)
        allCollected = try c.decodeSerdeDefault(Bool.self, forKey: .allCollected, default: false)
        paintedEggsUsed = try c.decodeSerdeDefault(Int.self, forKey: .paintedEggsUsed, default: 0)
        hunters = try c.decodeSerdeDefault([EasterHunterResult].self, forKey: .hunters, default: [])
    }
}

extension Sequence {
    /// Rust `Iterator::max_by`: on a tie the *last* maximal element wins.
    nonisolated func lastMax(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows -> Element? {
        var best: Element?
        for e in self {
            if let b = best {
                // keep `b` only if it is strictly greater than `e`
                best = try areInIncreasingOrder(e, b) ? b : e
            } else {
                best = e
            }
        }
        return best
    }
}

/// Namespace for the `easter_memory::*` functions.
enum EasterMemory {
    private static func today() -> String { BrainTime.today() }

    /// `Local::now() - 24h`, formatted (not a calendar-day subtraction).
    private static func yesterday() -> String {
        BrainTime.format("yyyy-MM-dd", BrainTime.now.addingTimeInterval(-86_400))
    }

    private static func defaultStats() -> EasterStats {
        var s = EasterStats()
        s.lastResetDate = today()
        return s
    }

    private static func loadStats() -> EasterStats {
        guard FileManager.default.fileExists(atPath: Paths.easterStats.path) else { return defaultStats() }
        return JSONFile.read(EasterStats.self, from: Paths.easterStats) ?? defaultStats()
    }

    private static func saveStats(_ stats: EasterStats) {
        try? JSONFile.write(stats, to: Paths.easterStats)
    }

    @discardableResult
    private static func resetDailyCountersIfNeeded(_ stats: inout EasterStats) -> Bool {
        let todayStr = today()
        if stats.lastResetDate == todayStr { return false }

        stats.lastResetDate = todayStr
        stats.eggsFoundToday = 0
        stats.goldenEggsToday = 0
        stats.huntsToday = 0
        for id in stats.hunters.keys {
            stats.hunters[id]?.eggsFoundToday = 0
        }
        return true
    }

    private static func recalculateLeaderboard(_ stats: inout EasterStats) {
        // Rust iterated a HashMap (random order) with last-max-wins ties;
        // sorted ids make the tie-break deterministic.
        let best = stats.hunters.keys.sorted().compactMap { stats.hunters[$0] }.lastMax { a, b in
            (a.eggsFoundTotal, a.goldenEggsFound, a.huntsWon) < (b.eggsFoundTotal, b.goldenEggsFound, b.huntsWon)
        }
        if let best {
            stats.topHunterId = best.sheepId
            stats.topHunterName = best.sheepName
        } else {
            stats.topHunterId = ""
            stats.topHunterName = ""
        }

        stats.flockScore = stats.eggsFoundTotal
            + (stats.goldenEggsTotal * 4)
            + (stats.huntsCompleted * 3)
            + (stats.bestStreak * 2)
            + stats.paintedEggsUsedTotal
    }

    private static func updateStreak(_ stats: inout EasterStats) {
        let todayStr = today()
        if stats.lastHuntDate == todayStr { return }

        if stats.lastHuntDate == yesterday() {
            stats.currentStreak += 1
        } else {
            stats.currentStreak = 1
        }
        stats.bestStreak = max(stats.bestStreak, stats.currentStreak)
        stats.lastHuntDate = todayStr
    }

    /// Current scoreboard; rolls the daily counters over (and persists) on a new day.
    static func getStats() -> EasterStats {
        var stats = loadStats()
        let changed = resetDailyCountersIfNeeded(&stats)
        recalculateLeaderboard(&stats)
        if changed {
            saveStats(stats)
        }
        return stats
    }

    @discardableResult
    static func recordHunt(_ result: EasterHuntResult) -> EasterStats {
        var stats = loadStats()
        resetDailyCountersIfNeeded(&stats)

        let totalFound = result.hunters.reduce(0) { $0 + $1.eggsFound }
        let goldenFound = result.hunters.reduce(0) { $0 + $1.goldenEggsFound }

        stats.eggsFoundTotal += totalFound
        stats.eggsFoundToday += totalFound
        stats.goldenEggsTotal += goldenFound
        stats.goldenEggsToday += goldenFound
        stats.paintedEggsUsedTotal += result.paintedEggsUsed
        stats.huntsToday += 1

        let winnerId = result.hunters.lastMax { a, b in
            (a.eggsFound, a.goldenEggsFound) < (b.eggsFound, b.goldenEggsFound)
        }?.id ?? ""

        for hunter in result.hunters {
            var entry = stats.hunters[hunter.id]
                ?? EasterHunterStats(sheepId: hunter.id, sheepName: hunter.name)

            entry.sheepName = hunter.name
            entry.eggsFoundTotal += hunter.eggsFound
            entry.eggsFoundToday += hunter.eggsFound
            entry.goldenEggsFound += hunter.goldenEggsFound
            entry.huntsParticipated += 1
            if hunter.id == winnerId && hunter.eggsFound > 0 {
                entry.huntsWon += 1
                stats.lastWinnerId = hunter.id
                stats.lastWinnerName = hunter.name
            }
            stats.hunters[hunter.id] = entry
        }

        if result.allCollected {
            stats.huntsCompleted += 1
            updateStreak(&stats)
        }

        recalculateLeaderboard(&stats)
        saveStats(stats)
        return stats
    }
}

extension Paths {
    /// `easter.json` — the egg-hunt scoreboard.
    static var easterStats: URL { file("easter.json") }
}

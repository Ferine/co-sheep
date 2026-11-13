import Foundation

// The flock's julekalender and Christmas tallies (`christmas.json`).

nonisolated struct ChristmasStats: Codable, Equatable {
    /// The December the opened doors belong to (see `ChristmasSeason.seasonYear`).
    var seasonYear: Int = 0
    /// Opened julekalender doors this season, ascending, each 1...24.
    var doorsOpened: [Int] = []
    /// `yyyy-MM-dd` of the last door opened.
    var lastDoorDate: String = ""
    var giftsOpenedTotal: Int = 0
    var carolsSungTotal: Int = 0
    var sleighsSeenTotal: Int = 0

    enum CodingKeys: String, CodingKey {
        case seasonYear = "season_year"
        case doorsOpened = "doors_opened"
        case lastDoorDate = "last_door_date"
        case giftsOpenedTotal = "gifts_opened_total"
        case carolsSungTotal = "carols_sung_total"
        case sleighsSeenTotal = "sleighs_seen_total"
    }

    init() {}

    /// Every field is optional on disk, so `{}` is a valid file. Doors are
    /// normalized on the way in: out-of-range and duplicate entries are dropped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasonYear = try c.decodeSerdeDefault(Int.self, forKey: .seasonYear, default: 0)
        let doors = try c.decodeSerdeDefault([Int].self, forKey: .doorsOpened, default: [])
        doorsOpened = Self.normalized(doors)
        lastDoorDate = try c.decodeSerdeDefault(String.self, forKey: .lastDoorDate, default: "")
        giftsOpenedTotal = try c.decodeSerdeDefault(Int.self, forKey: .giftsOpenedTotal, default: 0)
        carolsSungTotal = try c.decodeSerdeDefault(Int.self, forKey: .carolsSungTotal, default: 0)
        sleighsSeenTotal = try c.decodeSerdeDefault(Int.self, forKey: .sleighsSeenTotal, default: 0)
    }

    static func normalized(_ doors: [Int]) -> [Int] {
        Set(doors).filter { (1...24).contains($0) }.sorted()
    }

    /// The lowest unopened door that is due: missed days are caught up oldest
    /// first. nil when nothing is due (out of season, or all caught up).
    func nextDoor(dueDoor: Int?) -> Int? {
        guard let dueDoor, dueDoor >= 1 else { return nil }
        return (1...min(dueDoor, 24)).first { !doorsOpened.contains($0) }
    }
}

/// Namespace for the julekalender's persistence.
enum ChristmasMemory {
    private static func load() -> ChristmasStats {
        guard FileManager.default.fileExists(atPath: Paths.christmasStats.path) else { return ChristmasStats() }
        return JSONFile.readOrQuarantine(ChristmasStats.self, from: Paths.christmasStats) ?? ChristmasStats()
    }

    private static func save(_ stats: ChristmasStats) {
        try? JSONFile.write(stats, to: Paths.christmasStats)
    }

    /// A new December starts a fresh calendar; the lifetime tallies stay.
    @discardableResult
    private static func rollSeasonIfNeeded(_ stats: inout ChristmasStats) -> Bool {
        let year = ChristmasSeason.seasonYear()
        if stats.seasonYear == year { return false }
        stats.seasonYear = year
        stats.doorsOpened = []
        stats.lastDoorDate = ""
        return true
    }

    /// Current tallies; starts a fresh calendar (and persists) in a new season.
    static func getStats() -> ChristmasStats {
        var stats = load()
        if rollSeasonIfNeeded(&stats) { save(stats) }
        return stats
    }

    private static func update(_ mutate: (inout ChristmasStats) -> Void) -> ChristmasStats {
        var stats = load()
        rollSeasonIfNeeded(&stats)
        mutate(&stats)
        save(stats)
        return stats
    }

    /// Mark a door as opened. Doors outside 1...24 are ignored.
    @discardableResult
    static func openDoor(_ door: Int) -> ChristmasStats {
        update { stats in
            guard (1...ChristmasSeason.doorCount).contains(door) else { return }
            stats.doorsOpened = ChristmasStats.normalized(stats.doorsOpened + [door])
            stats.lastDoorDate = BrainTime.today()
        }
    }

    @discardableResult
    static func recordGifts(_ count: Int) -> ChristmasStats {
        update { $0.giftsOpenedTotal += max(0, count) }
    }

    @discardableResult
    static func recordCarol() -> ChristmasStats {
        update { $0.carolsSungTotal += 1 }
    }

    @discardableResult
    static func recordSleigh() -> ChristmasStats {
        update { $0.sleighsSeenTotal += 1 }
    }
}

extension Paths {
    /// `christmas.json`: julekalender doors and Christmas tallies.
    static var christmasStats: URL { file("christmas.json") }
}

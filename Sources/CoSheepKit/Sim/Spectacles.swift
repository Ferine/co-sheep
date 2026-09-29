import Foundation

// Ex-spectacles.ts.
// Spectacle scheduling — pure logic. Rare, high-impact desktop events.
// Random spectacles roll on a timer; showdown/feast are drama-triggered
// and never come from this table.

nonisolated enum SpectacleType: String, CaseIterable, Codable {
    case wolf, ufo, merchant, balloon, shearing, showdown, feast
}

/// Persisted verbatim as living state "spectacles":
/// `{"lastFiredMs": 123, "lastByType": {"wolf": 123}}`.
nonisolated struct SpectacleSchedulerState: Equatable, Codable {
    var lastFiredMs: Double
    var lastByType: [SpectacleType: Double]

    init(lastFiredMs: Double = 0, lastByType: [SpectacleType: Double] = [:]) {
        self.lastFiredMs = lastFiredMs
        self.lastByType = lastByType
    }

    private enum CodingKeys: String, CodingKey { case lastFiredMs, lastByType }

    /// Mirrors the TS load check `s && typeof s.lastFiredMs === "number"`:
    /// a missing/non-numeric `lastFiredMs` fails the decode (caller keeps its
    /// default); `lastByType` is tolerant (missing, malformed or unknown keys
    /// are dropped), and is a plain string-keyed object on disk — Swift would
    /// otherwise encode an enum-keyed dictionary as a flat array.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastFiredMs = try c.decode(Double.self, forKey: .lastFiredMs)
        var byType: [SpectacleType: Double] = [:]
        if let raw = try? c.decodeIfPresent([String: Double].self, forKey: .lastByType) {
            for (k, v) in raw {
                if let t = SpectacleType(rawValue: k) { byType[t] = v }
            }
        }
        lastByType = byType
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lastFiredMs, forKey: .lastFiredMs)
        var raw: [String: Double] = [:]
        for (t, v) in lastByType { raw[t.rawValue] = v }
        try c.encode(raw, forKey: .lastByType)
    }
}

nonisolated struct SchedulerInput {
    var state: SpectacleSchedulerState
    var nowMs: Double
    var isNight: Bool
    /// Random [0,1) injected by the caller for testability.
    var rand: Double
}

nonisolated enum SPECTACLE {
    /// Global floor between spectacles (~at most one per day).
    static let MIN_GAP_MS: Double = 20 * 3600 * 1000
    /// Guaranteed something within this window of app uptime.
    static let PITY_MS: Double = 72 * 3600 * 1000
    /// Per 5-min check: expected ~one spectacle every 2 days of uptime.
    static let TICK_CHANCE: Double = 0.0017
    /// Same spectacle won't repeat within a week.
    static let TYPE_COOLDOWN_MS: Double = 7 * 24 * 3600 * 1000
    static let CHECK_INTERVAL_MS: Double = 5 * 60 * 1000
}

nonisolated private let RANDOM_TABLE: [(type: SpectacleType, weight: Double)] = [
    (.wolf, 3),
    (.ufo, 2),
    (.merchant, 2),
    (.balloon, 2),
    (.shearing, 1),
]

nonisolated func pickRandomSpectacle(_ input: SchedulerInput) -> SpectacleType? {
    let state = input.state, nowMs = input.nowMs, isNight = input.isNight, rand = input.rand
    if isNight { return nil }
    if nowMs - state.lastFiredMs < SPECTACLE.MIN_GAP_MS { return nil }

    let pityDue = nowMs - state.lastFiredMs >= SPECTACLE.PITY_MS
    if !pityDue && rand >= SPECTACLE.TICK_CHANCE { return nil }

    // The gate consumed rand's magnitude: on the non-pity path only
    // rand < TICK_CHANCE survives, so rescale it back to [0,1) or the
    // weighted walk below would always land on the first entry.
    let pickRand = pityDue ? rand : rand / SPECTACLE.TICK_CHANCE

    let eligible = RANDOM_TABLE.filter { entry in
        guard let last = state.lastByType[entry.type] else { return true }
        return nowMs - last >= SPECTACLE.TYPE_COOLDOWN_MS
    }
    if eligible.isEmpty { return nil }

    let totalWeight = eligible.reduce(0) { $0 + $1.weight }
    var roll = pickRand * totalWeight
    for e in eligible {
        roll -= e.weight
        if roll < 0 { return e.type }
    }
    return eligible[eligible.count - 1].type
}

nonisolated func markFired(_ state: SpectacleSchedulerState, _ type: SpectacleType,
                           _ nowMs: Double) -> SpectacleSchedulerState {
    var byType = state.lastByType
    byType[type] = nowMs
    return SpectacleSchedulerState(lastFiredMs: nowMs, lastByType: byType)
}

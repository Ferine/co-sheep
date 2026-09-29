import Foundation

// Ex-drama.ts.
// Simulation-driven relationship drama. Pure logic: state in, transitions out.
// The AI never owns this state — it only narrates what these rules decide.
//
// State graph:  neutral <-> warm -> inseparable
//               neutral <-> tension -> feud -> reconciling -> warm

nonisolated enum RelationshipState: String, CaseIterable, Codable {
    case neutral, warm, inseparable, tension, feud, reconciling
}

nonisolated struct PairInput: Equatable {
    var idA: String
    var idB: String
    /// Symmetric affinity: average of both directions' scores.
    var affinity: Double
    var moodA: String
    var moodB: String
    var state: RelationshipState
    var msInState: Double
    /// |petsA - petsB| today — fuel for jealousy.
    var pettingGap: Double
    /// Random [0,1) injected by the caller so tests are deterministic.
    var spark: Double
}

nonisolated struct DramaTransition: Equatable {
    var idA: String
    var idB: String
    var from: RelationshipState
    var to: RelationshipState
    var cause: String
}

/// Tuning constants — thresholds are hysteresis pairs (enter > exit).
nonisolated enum DRAMA {
    static let WARM_ENTER: Double = 8
    static let WARM_EXIT: Double = 5
    static let INSEP_ENTER: Double = 15
    static let INSEP_EXIT: Double = 10
    static let INSEP_DWELL_MS: Double = 24 * 3600 * 1000
    static let TENSION_ENTER: Double = -3
    static let TENSION_EXIT: Double = 1
    static let JEALOUSY_GAP: Double = 5
    static let FEUD_DWELL_MS: Double = 12 * 3600 * 1000
    static let FEUD_SPARK: Double = 0.005
    static let FEUD_TIREOUT_MS: Double = 48 * 3600 * 1000
    static let RECONCILE_MS: Double = 10 * 60 * 1000
    /// No pair may transition twice within this window (anti-flap).
    static let MIN_DWELL_MS: Double = 30 * 60 * 1000
}

nonisolated func pairKey(_ a: String, _ b: String) -> String {
    // JS `a < b` on strings compares UTF-16 code units, which differs from
    // Swift's `String <` outside the BMP; ids are ASCII today, but keep the
    // key ordering compatible with what drama.json already holds.
    a.utf16.lexicographicallyPrecedes(b.utf16) ? "\(a)|\(b)" : "\(b)|\(a)"
}

/// Drop every pair record involving a departed character. Ids never come
/// back (they're timestamped), so their pairs would otherwise live in
/// drama.json forever.
nonisolated func pruneCharacterFromPairs<T>(_ pairs: [String: T], _ id: String) -> [String: T] {
    var out: [String: T] = [:]
    for (key, rec) in pairs {
        // `const [a, b] = key.split("|")` — a missing part is `undefined`, never equal to id.
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        let a: String? = parts.count > 0 ? String(parts[0]) : nil
        let b: String? = parts.count > 1 ? String(parts[1]) : nil
        if a != id && b != id { out[key] = rec }
    }
    return out
}

nonisolated func blocksGroupActivity(_ state: RelationshipState) -> Bool {
    state == .feud
}

nonisolated func evaluatePair(_ p: PairInput) -> DramaTransition? {
    func t(_ to: RelationshipState, _ cause: String) -> DramaTransition {
        DramaTransition(idA: p.idA, idB: p.idB, from: p.state, to: to, cause: cause)
    }

    switch p.state {
    case .neutral:
        if p.msInState < DRAMA.MIN_DWELL_MS { return nil }
        if p.pettingGap >= DRAMA.JEALOUSY_GAP { return t(.tension, "jealousy") }
        if p.affinity >= DRAMA.WARM_ENTER { return t(.warm, "growing affinity") }
        if p.affinity <= DRAMA.TENSION_ENTER { return t(.tension, "low affinity") }
        return nil

    case .warm:
        if p.msInState < DRAMA.MIN_DWELL_MS { return nil }
        if p.affinity < DRAMA.WARM_EXIT { return t(.neutral, "drifted apart") }
        if p.affinity >= DRAMA.INSEP_ENTER && p.msInState >= DRAMA.INSEP_DWELL_MS {
            return t(.inseparable, "best friends now")
        }
        return nil

    case .inseparable:
        if p.msInState < DRAMA.MIN_DWELL_MS { return nil }
        if p.affinity < DRAMA.INSEP_EXIT { return t(.warm, "cooled slightly") }
        return nil

    case .tension:
        if p.msInState < DRAMA.MIN_DWELL_MS { return nil }
        if p.affinity >= DRAMA.TENSION_EXIT && p.pettingGap < DRAMA.JEALOUSY_GAP {
            return t(.neutral, "cooled off")
        }
        if p.spark < DRAMA.FEUD_SPARK { return t(.feud, "spark") }
        if p.msInState >= DRAMA.FEUD_DWELL_MS && (p.moodA == "grumpy" || p.moodB == "grumpy") {
            return t(.feud, "grudge")
        }
        return nil

    case .feud:
        if p.msInState >= DRAMA.FEUD_TIREOUT_MS { return t(.reconciling, "tired of fighting") }
        return nil

    case .reconciling:
        if p.msInState >= DRAMA.RECONCILE_MS { return t(.warm, "made up") }
        return nil
    }
}

nonisolated func evaluateDrama(_ pairs: [PairInput]) -> [DramaTransition] {
    var out: [DramaTransition] = []
    for p in pairs {
        if let t = evaluatePair(p) { out.append(t) }
    }
    return out
}

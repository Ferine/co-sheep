import Foundation

// Ex-drama-manager.ts.
// Runs the relationship drama (drama.swift's pure rules) against the live
// flock: once a minute it feeds every pair's affinity / mood / petting gap
// into `evaluateDrama`, applies the transitions, plays the visible beats
// (scripted conversations, spectacles), and persists the state as living
// state "drama" (`~/.co-sheep/drama.json`, same shape the TS wrote).

private let TICK_MS: Double = 60_000
private let DISPLAY_SIZE: Double = 96
private let SNIPE_CHANCE = 0.10        // per tick, per feuding pair
private let MEDIATION_CHANCE = 0.05    // per tick, per feuding pair
private let MEDIATION_SUCCESS = 0.6
private let SHOWDOWN_MS: Double = 24 * 3600 * 1000
private let SHOWDOWN_CHANCE = 0.10
private let AI_NARRATION_CHANCE = 0.3
private let AI_NARRATION_COOLDOWN_MS: Double = 10 * 60 * 1000
private let LOG_CAP = 50

/// `new Date().toISOString()` for an epoch-ms value: always UTC, always
/// `YYYY-MM-DDTHH:MM:SS.mmmZ`, computed with integer math so a millisecond
/// never rounds away. drama.json (and the gossip day roll) key on it.
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

    /// `toISOString().slice(0, 10)` — the UTC calendar day.
    static func day(_ ms: Double) -> String {
        String(timestamp(ms).prefix(10))
    }
}

/// ex-`PairRecord`.
nonisolated struct DramaPairRecord: Codable, Equatable {
    var state: RelationshipState
    /// Epoch ms of the last transition.
    var since: Double
}

/// ex-`DramaFile.log[]`.
nonisolated struct DramaLogEntry: Codable, Equatable {
    var at: String
    var text: String
}

/// ex-`DramaFile`: the persisted drama state (living state "drama").
///
/// Decoding mirrors the TS load check `saved && saved.pairs`: a missing or
/// non-object `pairs` fails the decode (the caller keeps its fresh default).
/// Everything else is tolerant — a missing `pettingToday` / `pettingDate` /
/// `log` gets its default, and a pair record or log entry that is malformed
/// (unknown state, no numeric `since`) is dropped instead of poisoning the file.
nonisolated struct DramaFile: Codable, Equatable {
    var pairs: [String: DramaPairRecord]
    var pettingToday: [String: Int]
    var pettingDate: String
    var log: [DramaLogEntry]

    init(pairs: [String: DramaPairRecord] = [:], pettingToday: [String: Int] = [:],
         pettingDate: String, log: [DramaLogEntry] = []) {
        self.pairs = pairs
        self.pettingToday = pettingToday
        self.pettingDate = pettingDate
        self.log = log
    }

    private enum CodingKeys: String, CodingKey { case pairs, pettingToday, pettingDate, log }

    /// Decodes `T`, or nil when it is malformed (never throws).
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawPairs = try c.decode([String: Lossy<DramaPairRecord>].self, forKey: .pairs)
        pairs = rawPairs.compactMapValues(\.value)
        let petting = (try? c.decodeIfPresent([String: Double].self, forKey: .pettingToday)) ?? [:]
        pettingToday = petting.compactMapValues { Int(exactly: $0.rounded(.towardZero)) }
        pettingDate = (try? c.decodeIfPresent(String.self, forKey: .pettingDate)) ?? ""
        let rawLog = (try? c.decodeIfPresent([Lossy<DramaLogEntry>].self, forKey: .log)) ?? []
        log = rawLog.compactMap(\.value)
    }
}

/// `get_all_relationships`' payload (ex-`RelationshipsSnapshot`).
private typealias RelationshipsSnapshot = [String: FriendRelationshipSummary]

/// JS `a < b` on strings (UTF-16 code units), as drama.json's pair keys expect.
private func jsLess(_ a: String, _ b: String) -> Bool {
    a.utf16.lexicographicallyPrecedes(b.utf16)
}

final class DramaManager {
    private let flock: Flock
    /// Internal (not private) so tests can inspect it.
    private(set) var state = DramaFile(pettingDate: SimISO.day(SimClock.nowMs()))
    private var aiNarrationCooldownUntil: Double = 0
    private var unsubscribePetted: (() -> Void)?
    private var tickTimer: TimerToken?
    private var installedFilter = false
    /// The in-flight AI narration request (tests await it).
    private(set) var narrationTask: Task<Void, Never>?

    /// main.ts wires this to `flock.startSpectacle(kind, pair)`.
    var onDramaTriggeredSpectacle: ((SpectacleType, (String, String)) -> Void)?

    private struct NarrationUnavailable: Error {}

    init(_ flock: Flock) {
        self.flock = flock
    }

    func start() {
        stop()

        // ex-`invoke("get_living_state", { name: "drama" })` — the file is tiny,
        // so it is read inline.
        if let saved = Self.decodeState(LivingState.loadState("drama")) {
            state = saved
        }
        resetPettingIfNewDay()

        unsubscribePetted = bus.on(.sheepPetted) { [weak self] event in
            guard let self, case .sheepPetted(let id) = event else { return }
            self.resetPettingIfNewDay()
            self.state.pettingToday[id, default: 0] += 1
        }

        // Feuders refuse shared group activities.
        flock.participantFilter = { [weak self] ids in self?.filterFeuders(ids) ?? ids }
        installedFilter = true

        tickTimer = SimTimers.every(TICK_MS) { [weak self] in
            self?.tick()
        }
    }

    /// Cancel the tick, unsubscribe from the bus and hand the group-activity
    /// filter back. State stays as it is (and stays persisted).
    func stop() {
        tickTimer?.cancel()
        tickTimer = nil
        unsubscribePetted?()
        unsubscribePetted = nil
        if installedFilter {
            flock.participantFilter = nil
            installedFilter = false
        }
    }

    /// A friend was removed — its id never returns, so drop its drama state.
    /// Called from the remove-friend event, NOT the tick: friends spawn
    /// staggered at startup, so pruning against live ids would eat real feuds.
    func onFriendRemoved(_ id: String) {
        state.pairs = pruneCharacterFromPairs(state.pairs, id)
        state.pettingToday[id] = nil
        persist()
    }

    func getPairStates() -> [String: (state: RelationshipState, sinceMs: Double)] {
        var out: [String: (state: RelationshipState, sinceMs: Double)] = [:]
        let now = SimClock.nowMs()
        for (key, rec) in state.pairs {
            out[key] = (rec.state, now - rec.since)
        }
        return out
    }

    /// Debug hook: force the first non-feud friend pair into a feud.
    @discardableResult
    func forceFeud() -> String? {
        let ids = flock.getCharacterIds().filter { $0 != "main" }
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                let key = pairKey(ids[i], ids[j])
                let rec = state.pairs[key]
                if rec == nil || rec!.state != .feud {
                    let aFirst = jsLess(ids[i], ids[j])
                    applyTransition(DramaTransition(
                        idA: aFirst ? ids[i] : ids[j],
                        idB: aFirst ? ids[j] : ids[i],
                        from: rec?.state ?? .neutral,
                        to: .feud,
                        cause: "debug"))
                    return key
                }
            }
        }
        return nil
    }

    /// Called by the showdown scene with its outcome.
    func resolveShowdown(_ pair: (String, String), _ reconciled: Bool) {
        let key = pairKey(pair.0, pair.1)
        guard let rec = state.pairs[key], rec.state == .feud else { return }
        if reconciled {
            applyTransition(DramaTransition(
                idA: pair.0, idB: pair.1, from: .feud, to: .reconciling, cause: "showdown"))
        } else {
            state.log.append(DramaLogEntry(
                at: SimISO.timestamp(SimClock.nowMs()),
                text: "\(pair.0) & \(pair.1): showdown ended in a stalemate"))
            persist()
        }
    }

    // MARK: State

    /// `saved && saved.pairs` → the typed file, nil for anything else.
    private static func decodeState(_ value: JSONValue) -> DramaFile? {
        guard value.objectValue != nil,
              let data = try? JSONFile.encoder().encode(value) else { return nil }
        return try? JSONFile.decoder().decode(DramaFile.self, from: data)
    }

    private func resetPettingIfNewDay() {
        let today = SimISO.day(SimClock.nowMs())
        if state.pettingDate != today {
            state.pettingToday = [:]
            state.pettingDate = today
        }
    }

    private func filterFeuders(_ ids: [String]) -> [String] {
        var result = ids
        var i = 0
        while i < result.count {
            var j = result.count - 1
            while j > i {
                if let rec = state.pairs[pairKey(result[i], result[j])], blocksGroupActivity(rec.state) {
                    result.remove(at: j)
                }
                j -= 1
            }
            i += 1
        }
        return result
    }

    // MARK: Tick

    /// One drama minute. Internal (not private) so tests can run it without
    /// waiting for the timer.
    func tick() {
        let ids = flock.getCharacterIds()
        if ids.count < 2 { return }
        resetPettingIfNewDay()

        // ex-`invoke("get_all_relationships")` / `invoke("get_friend_moods")`.
        let rels = FriendMemory.getAllRelationships()
        let moods = FriendMemory.getAllMoods()

        let now = SimClock.nowMs()
        var inputs: [PairInput] = []
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                let (a, b) = jsLess(ids[i], ids[j]) ? (ids[i], ids[j]) : (ids[j], ids[i])
                let key = pairKey(a, b)
                let rec: DramaPairRecord
                if let existing = state.pairs[key] {
                    rec = existing
                } else {
                    rec = DramaPairRecord(state: .neutral, since: now)
                    state.pairs[key] = rec
                }
                // Symmetric affinity: average whichever directions exist
                // ("main" has no brain, so main-pairs use the friend's view only).
                let ab = rels[a]?.relationships[b]
                let ba = rels[b]?.relationships[a]
                let vals = [ab, ba].compactMap { $0 }.map(Double.init)
                let affinity = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
                let gap = abs(Double((state.pettingToday[a] ?? 0) - (state.pettingToday[b] ?? 0)))
                inputs.append(PairInput(
                    idA: a, idB: b,
                    affinity: affinity,
                    moodA: moods[a] ?? "happy",
                    moodB: moods[b] ?? "happy",
                    state: rec.state,
                    msInState: now - rec.since,
                    pettingGap: gap,
                    spark: SimRandom.next()))
            }
        }

        for t in evaluateDrama(inputs) {
            applyTransition(t)
        }
        runOngoingBehaviors(now, rels)
        persist()
    }

    private func applyTransition(_ t: DramaTransition) {
        let key = pairKey(t.idA, t.idB)
        state.pairs[key] = DramaPairRecord(state: t.to, since: SimClock.nowMs())
        state.log.append(DramaLogEntry(
            at: SimISO.timestamp(SimClock.nowMs()),
            text: "\(t.idA) & \(t.idB): \(t.from.rawValue) -> \(t.to.rawValue) (\(t.cause))"))
        if state.log.count > LOG_CAP {
            state.log.removeFirst(state.log.count - LOG_CAP)
        }
        bus.emit(.dramaStateChanged(
            idA: t.idA, idB: t.idB, from: t.from.rawValue, to: t.to.rawValue, cause: t.cause))
        Log.info("drama", "DRAMA: \(t.idA) & \(t.idB) \(t.from.rawValue) -> \(t.to.rawValue) (\(t.cause))")

        // Visible beat for the transition.
        if t.to == .feud {
            playScript(t.cause == "jealousy" ? .jealousy : .feudStart, t.idA, t.idB)
        } else if t.to == .warm && t.from == .reconciling {
            playScript(.reconciliation, t.idA, t.idB)
        } else if t.to == .inseparable {
            playScript(.inseparable, t.idA, t.idB)
        } else if t.to == .reconciling, let spectacle = onDramaTriggeredSpectacle {
            spectacle(.feast, (t.idA, t.idB))
        }

        maybeNarrate(t)
        persist()
    }

    /// 30% chance of an on-device AI beat about the transition (fire-and-forget).
    private func maybeNarrate(_ t: DramaTransition) {
        if SimRandom.next() >= AI_NARRATION_CHANCE { return }
        if SimClock.nowMs() < aiNarrationCooldownUntil { return }
        if t.idA == "main" || t.idB == "main" { return } // needs two friend personalities
        guard let a = flock.getCharacter(t.idA), let b = flock.getCharacter(t.idB),
              let personalityA = a.personality, let personalityB = b.personality else { return }
        aiNarrationCooldownUntil = SimClock.nowMs() + AI_NARRATION_COOLDOWN_MS

        // ex-`invoke("friend_ai_chat", …)`: Flock's seam (nil behaves as a failed call).
        let chat = flock.friendAIChat
        let nameA = a.sheep.name
        let topic = "their relationship just changed from \(t.from.rawValue) to \(t.to.rawValue) because of \(t.cause)"

        narrationTask = Task { [weak self] in
            do {
                guard let chat else { throw NarrationUnavailable() }
                let raw = try await chat(t.idA, nameA, personalityA, t.idB, b.sheep.name, personalityB, topic)
                guard let self else { return }
                do {
                    guard let script = try Flock.parseFriendChatScript(
                        raw, idA: t.idA, idB: t.idB, nameB: b.sheep.name) else { return }
                    self.flock.startScriptedConversation(script, [t.idA, t.idB])
                } catch {
                    Log.info("drama", "error: drama narration parse failed: \(error)")
                }
            } catch {
                Log.info("drama", "error: drama narration failed: \(error)")
            }
        }
    }

    /// Per-tick continuous behaviors for pairs in dramatic states.
    private func runOngoingBehaviors(_ now: Double, _ rels: RelationshipsSnapshot) {
        // `Object.entries` snapshot (a sorted file on disk loads in key order).
        for key in state.pairs.keys.sorted() {
            guard let rec = state.pairs[key] else { continue }
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let idA = String(parts[0]), idB = String(parts[1])
            guard let a = flock.getCharacter(idA), let b = flock.getCharacter(idB) else { continue }

            if rec.state == .feud {
                let dist = abs(a.sheep.x - b.sheep.x)
                if dist < DISPLAY_SIZE * 2 && flock.isCharacterCalm(idA) && flock.isCharacterCalm(idB) {
                    // Storm apart when too close.
                    let dir: Double = a.sheep.x < b.sheep.x ? -1 : 1
                    a.sheep.walkTarget = max(
                        0,
                        min(a.sheep.screenWidth - DISPLAY_SIZE, a.sheep.x + dir * DISPLAY_SIZE * 3))
                    a.sheep.playAnimation(.headshake)
                } else if SimRandom.next() < SNIPE_CHANCE {
                    playScript(.feudSnipe, idA, idB)
                }

                // Mediation: the best-connected calm third sheep intervenes.
                if SimRandom.next() < MEDIATION_CHANCE {
                    if let mediator = pickMediator(idA, idB, rels),
                       playScript(.mediation, idA, idB, mediator) {
                        if SimRandom.next() < MEDIATION_SUCCESS {
                            applyTransition(DramaTransition(
                                idA: idA, idB: idB, from: .feud, to: .reconciling, cause: "mediation"))
                            // applyTransition invalidates rec for this iteration; move to next pair
                            continue
                        }
                    }
                }

                // Long feuds may erupt into a high-noon showdown.
                if now - rec.since >= SHOWDOWN_MS && SimRandom.next() < SHOWDOWN_CHANCE,
                   let spectacle = onDramaTriggeredSpectacle {
                    spectacle(.showdown, (idA, idB))
                }
            }

            if rec.state == .inseparable {
                // Trail each other when separated.
                let dist = abs(a.sheep.x - b.sheep.x)
                if dist > DISPLAY_SIZE * 4 && flock.isCharacterCalm(idB) && b.sheep.walkTarget == nil {
                    b.sheep.walkTarget = a.sheep.x
                }
            }
        }
    }

    /// Calm third sheep with the highest combined affinity to both feuders.
    private func pickMediator(_ idA: String, _ idB: String, _ rels: RelationshipsSnapshot) -> String? {
        var best: String?
        var bestScore = -Double.infinity
        for id in flock.getCharacterIds() {
            if id == idA || id == idB || id == "main" { continue }
            if !flock.isCharacterCalm(id) { continue }
            let score = Double((rels[id]?.relationships[idA] ?? 0) + (rels[id]?.relationships[idB] ?? 0))
            if score > bestScore {
                bestScore = score
                best = id
            }
        }
        return best
    }

    @discardableResult
    private func playScript(_ kind: DramaScriptKind, _ idA: String, _ idB: String,
                            _ mediatorId: String? = nil) -> Bool {
        let script = pickDramaScript(kind, idA, idB, mediatorId)
        let participants = mediatorId.map { [idA, idB, $0] } ?? [idA, idB]
        return flock.startScriptedConversation(script, participants)
    }

    /// ex-`invoke("save_living_state", { name: "drama", value: this.state })`.
    private func persist() {
        guard let data = try? JSONFile.encoder().encode(state),
              let value = try? JSONFile.decoder().decode(JSONValue.self, from: data) else { return }
        LivingState.saveState("drama", value)
    }
}

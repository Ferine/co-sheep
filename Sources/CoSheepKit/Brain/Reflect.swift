import Foundation

// Ex-reflect.rs — memory consolidation, the sheep sleeps on it.
//
// A reflection pass feeds a day's journal plus the opinion list to the
// on-device model, which proposes explicit ops (merge/update/prune/add).
// We validate and apply them: model proposes, code disposes.

/// One model-proposed edit. Wire format is serde's internally tagged enum:
/// `{"op": "merge", "from": [...], "into": "...", "text": "..."}` (lowercase tags).
nonisolated enum ReflectOp: Equatable, Decodable {
    case merge(from: [String], into: String, text: String)
    case update(topic: String, text: String)
    case prune(topic: String)
    case add(topic: String, text: String, category: String?)

    private enum CodingKeys: String, CodingKey {
        case op, from, into, text, topic, category
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "merge":
            self = .merge(
                from: try c.decode([String].self, forKey: .from),
                into: try c.decode(String.self, forKey: .into),
                text: try c.decodeSerdeDefault(String.self, forKey: .text, default: ""))
        case "update":
            self = .update(
                topic: try c.decode(String.self, forKey: .topic),
                text: try c.decode(String.self, forKey: .text))
        case "prune":
            self = .prune(topic: try c.decode(String.self, forKey: .topic))
        case "add":
            self = .add(
                topic: try c.decode(String.self, forKey: .topic),
                text: try c.decode(String.self, forKey: .text),
                category: try c.decodeIfPresent(String.self, forKey: .category))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: c,
                debugDescription: "unknown variant `\(op)`, expected one of `merge`, `update`, `prune`, `add`")
        }
    }
}

nonisolated struct ReflectError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

nonisolated struct ReflectPolicy: Equatable {
    var allowPrune: Bool
    var maxPrunes: Int
    var maxAdds: Int
    var pruneMinIdleDays: Int
    var pruneMaxTimesSeen: Int
    var today: NaiveDate

    static func daily(_ today: NaiveDate) -> ReflectPolicy {
        ReflectPolicy(
            allowPrune: true, maxPrunes: 3, maxAdds: 5,
            pruneMinIdleDays: 21, pruneMaxTimesSeen: 2, today: today)
    }

    /// Months-old evidence must not delete current beliefs.
    static func backfill(_ today: NaiveDate) -> ReflectPolicy {
        var p = daily(today)
        p.allowPrune = false
        return p
    }
}

nonisolated struct ApplyStats: Equatable, CustomStringConvertible {
    var merged = 0
    var updated = 0
    var pruned = 0
    var added = 0
    var skipped = 0

    /// Rust `{:?}` shape, for the log line.
    var description: String {
        "ApplyStats { merged: \(merged), updated: \(updated), pruned: \(pruned), added: \(added), skipped: \(skipped) }"
    }
}

/// First-result-wins rendezvous for `Reflect.withTimeout`.
private final class TimeoutBox<T: Sendable> {
    var done = false
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    private var cont: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?   // finished before the continuation existed

    func install(_ c: CheckedContinuation<T, Error>) {
        if let early {
            done = true
            c.resume(with: early)
        } else {
            cont = c
        }
    }

    func finish(_ result: Result<T, Error>) {
        guard !done else { return }
        done = true
        work?.cancel()
        timer?.cancel()
        if let cont { cont.resume(with: result) } else { early = result }
    }
}

/// Namespace for the `reflect::*` functions.
enum Reflect {
    /// ~4k-token window: opinions and journal each get an explicit byte budget.
    private static let JOURNAL_BUDGET = 2500
    private static let MAX_PROMPT_OPINIONS = 60
    static let GENERATE_TIMEOUT_SECS = 120.0
    private static let REFLECT_SYSTEM = "You are the memory-consolidation process for a desktop sheep. You tidy the sheep's opinion list using its diary. Reply with ONLY valid JSON, no markdown."

    /// Loop timing: first pass 90 s after launch, then every 180 s.
    static let LOOP_INITIAL_DELAY_SECS = 90.0
    static let LOOP_INTERVAL_SECS = 180.0

    // MARK: Parsing

    /// Rust `trim_start_matches(pat)`: strip every leading repetition of `pat`.
    private static func trimStartMatches(_ s: String, _ pat: String) -> String {
        var r = Substring(s)
        while r.hasPrefix(pat) { r = r.dropFirst(pat.count) }
        return String(r)
    }

    private static func trimEndMatches(_ s: String, _ pat: String) -> String {
        var r = Substring(s)
        while r.hasSuffix(pat) { r = r.dropLast(pat.count) }
        return String(r)
    }

    private struct OpsEnvelope: Decodable {
        var ops: [ReflectOp]
    }

    static func parseOps(_ raw: String) throws -> [ReflectOp] {
        var trimmed = raw.rustTrimmed()
        trimmed = trimStartMatches(trimmed, "```json")
        trimmed = trimStartMatches(trimmed, "```")
        trimmed = trimEndMatches(trimmed, "```")
        trimmed = trimmed.rustTrimmed()
        do {
            return try JSONFile.decoder().decode(OpsEnvelope.self, from: Data(trimmed.utf8)).ops
        } catch {
            throw ReflectError("bad reflection ops: \(error) — raw: \(trimmed)")
        }
    }

    // MARK: Applying

    static func idleDays(_ op: Opinion, today: NaiveDate) -> Int? {
        Memory.stampDate(op.lastSeen).map { today.daysSince($0) }
    }

    static func pruneEligible(_ op: Opinion, policy: ReflectPolicy) -> Bool {
        op.timesSeen <= policy.pruneMaxTimesSeen
            || (idleDays(op, today: policy.today).map { $0 > policy.pruneMinIdleDays } ?? false)
    }

    /// Apply model-proposed ops under policy. Invalid ops are skipped, never fatal.
    static func applyOps(_ brain: inout SheepBrain, _ ops: [ReflectOp], _ policy: ReflectPolicy) -> ApplyStats {
        var stats = ApplyStats()
        for op in ops {
            switch op {
            case .merge(let from, let into, let text):
                let intoKey = Memory.canonicalizeTopic(into)
                var sources = from.map(Memory.canonicalizeTopic)
                if !sources.contains(intoKey) {
                    sources.append(intoKey)
                }
                let found = brain.opinions.filter { sources.contains($0.topic) }
                if found.count < 2 {
                    stats.skipped += 1
                    continue
                }
                let times = found.reduce(0) { $0 + $1.timesSeen }
                let first = found.map(\.firstSeen).min() ?? ""
                let last = found.map(\.lastSeen).max() ?? ""
                let mergedText = text.rustTrimmed().isEmpty ? found[0].opinion : text
                let category = found[0].category
                brain.opinions.removeAll { sources.contains($0.topic) }
                brain.opinions.append(Opinion(
                    topic: intoKey, opinion: mergedText, timesSeen: times,
                    firstSeen: first, lastSeen: last, category: category))
                stats.merged += 1

            case .update(let topic, let text):
                let key = Memory.canonicalizeTopic(topic)
                if text.rustTrimmed().isEmpty {
                    stats.skipped += 1
                    continue
                }
                if let i = brain.opinions.firstIndex(where: { $0.topic == key }) {
                    brain.opinions[i].opinion = text
                    stats.updated += 1
                } else {
                    stats.skipped += 1
                }

            case .prune(let topic):
                if !policy.allowPrune || stats.pruned >= policy.maxPrunes {
                    stats.skipped += 1
                    continue
                }
                let key = Memory.canonicalizeTopic(topic)
                guard let pos = brain.opinions.firstIndex(where: { $0.topic == key }) else {
                    stats.skipped += 1
                    continue
                }
                if !pruneEligible(brain.opinions[pos], policy: policy) {
                    stats.skipped += 1
                    continue
                }
                brain.opinions.remove(at: pos)
                stats.pruned += 1

            case .add(let topic, let text, let category):
                if stats.added >= policy.maxAdds {
                    stats.skipped += 1
                    continue
                }
                let key = Memory.canonicalizeTopic(topic)
                if key.isEmpty
                    || text.rustTrimmed().isEmpty
                    || brain.opinions.contains(where: { $0.topic == key }) {
                    stats.skipped += 1
                    continue
                }
                let today = policy.today.description
                brain.opinions.append(Opinion(
                    topic: key, opinion: text, timesSeen: 1,
                    firstSeen: today, lastSeen: "\(today) 00:00", category: category ?? "opinion"))
                stats.added += 1
            }
        }
        return stats
    }

    // MARK: Prompt

    static func buildReflectionPrompt(_ opinions: [Opinion], _ journal: String, _ journalLabel: String) -> String {
        let selected = Memory.selectOpinions(
            opinions, query: nil, today: BrainTime.todayNaive(), limit: MAX_PROMPT_OPINIONS)
        let opLines = selected.map {
            "- [\($0.topic)] \($0.opinion) (category: \($0.category), seen \($0.timesSeen)x, last: \($0.lastSeen))"
        }
        let journalTail = Memory.tailAtCharBoundary(journal, maxBytes: JOURNAL_BUDGET)

        return #"""
Current opinions:
\#(opLines.joined(separator: "\n"))

\#(journalLabel):
\#(journalTail)

Tidy the opinions:
- merge: topics that mean the same thing
- update: opinion text the diary shows is outdated
- prune: opinions that no longer matter
- add: a clear recurring pattern in the diary that has no opinion yet

Reply with JSON only:
{"ops": [
  {"op": "merge", "from": ["key_a", "key_b"], "into": "key_a", "text": "combined opinion"},
  {"op": "update", "topic": "key", "text": "new text"},
  {"op": "prune", "topic": "key"},
  {"op": "add", "topic": "new_key", "text": "opinion text", "category": "habit"}
]}
If nothing needs tidying: {"ops": []}
"""#
    }

    // MARK: Model round trip

    /// Race `op` against a timer. Like tokio's `timeout`, the loser is
    /// abandoned (cancelled, not awaited) — a model call that ignores
    /// cancellation cannot hold the caller past the deadline. Cancelling the
    /// caller cancels both and throws `CancellationError`.
    static func withTimeout<T: Sendable>(
        seconds: Double, onTimeout: any Error,
        _ op: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let box = TimeoutBox<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                box.install(cont)
                guard !box.done else { return }
                box.work = Task { @MainActor in
                    do { box.finish(.success(try await op())) } catch { box.finish(.failure(error)) }
                }
                box.timer = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    box.finish(.failure(onTimeout))
                }
            }
        } onCancel: {
            Task { @MainActor in box.finish(.failure(CancellationError())) }
        }
    }

    /// One generate → parse → snapshot → apply cycle over a day's journal.
    static func reflectOnce(
        model: any LanguageModel, opinions: [Opinion], journal: String, label: String,
        policy: ReflectPolicy, timeoutSecs: Double = GENERATE_TIMEOUT_SECS
    ) async throws -> ApplyStats {
        let prompt = buildReflectionPrompt(opinions, journal, label)
        let raw = try await withTimeout(
            seconds: timeoutSecs,
            onTimeout: ReflectError("reflection generate timed out after \(Int(timeoutSecs))s")
        ) {
            try await model.generate(system: REFLECT_SYSTEM, prompt: prompt)
        }
        let ops = try parseOps(raw)
        Memory.snapshotOpinions()
        var stats = ApplyStats()
        do {
            try Memory.updateBrain { b in
                stats = applyOps(&b, ops, policy)
            }
        } catch {
            throw ReflectError("\(error)")
        }
        return stats
    }

    // MARK: Scheduling

    /// Consolidate yesterday's journal into the opinion list. Runs once per
    /// calendar day; the date is marked *before* the model call so a garbage
    /// output retries tomorrow, never in a loop.
    static func runDailyReflection(model: any LanguageModel, timeoutSecs: Double = GENERATE_TIMEOUT_SECS) async {
        let today = BrainTime.todayNaive()
        let todayStr = today.description
        let brain = Memory.loadBrain()
        if brain.lastReflectionDate == todayStr { return }

        let yesterday = today.addingDays(-1).description
        let days = Memory.listJournalDays()
        do {
            try Memory.updateBrain { b in
                b.lastReflectionDate = todayStr
                if let c = advancedCursor(days, b.backfillCursor, yesterday) {
                    b.backfillCursor = c
                }
            }
        } catch {
            return
        }

        guard let journal = Memory.readJournalFor(yesterday) else {
            Log.info("reflect", "Reflection: no journal for \(yesterday), nothing to tidy")
            return
        }

        Log.info("reflect", "Reflection: consolidating \(yesterday)")
        let label = "Diary for \(yesterday)"
        do {
            let stats = try await reflectOnce(
                model: model, opinions: brain.opinions, journal: journal, label: label,
                policy: .daily(today), timeoutSecs: timeoutSecs)
            Log.info("reflect", "Reflection applied: \(stats)")
            try? Memory.appendJournal("*Slept on it. Tidied my thoughts.*")
        } catch {
            Log.info("reflect", "error: Reflection failed (retry tomorrow): \(error)")
        }
    }

    /// Oldest journal day after the cursor, strictly before `before` (exclusive
    /// upper bound — the daily reflection pass owns yesterday).
    static func pendingBackfillDay(_ days: [String], _ cursor: String, _ before: String) -> String? {
        days.first { cursor.utf8Precedes($0) && $0.utf8Precedes(before) }
    }

    /// Once the archive before yesterday is drained, the daily pass claims
    /// yesterday by advancing the cursor — backfill must never re-process a
    /// day the daily reflection already consolidated.
    static func advancedCursor(_ days: [String], _ cursor: String, _ yesterday: String) -> String? {
        if cursor.utf8Precedes(yesterday) && pendingBackfillDay(days, cursor, yesterday) == nil {
            return yesterday
        }
        return nil
    }

    /// Distill one archived journal day into opinions. Returns false when the
    /// archive is exhausted. The cursor advances even on failure — a garbage
    /// day is skipped, not retried forever.
    @discardableResult
    static func runBackfillStep(model: any LanguageModel, timeoutSecs: Double = GENERATE_TIMEOUT_SECS) async -> Bool {
        let today = BrainTime.todayNaive()
        let yesterdayStr = today.addingDays(-1).description
        let brain = Memory.loadBrain()
        let days = Memory.listJournalDays()
        guard let day = pendingBackfillDay(days, brain.backfillCursor, yesterdayStr) else {
            return false
        }

        do {
            try Memory.updateBrain { $0.backfillCursor = day }
        } catch {
            return false
        }

        guard let journal = Memory.readJournalFor(day) else {
            return true
        }
        Log.info("reflect", "Backfill: distilling journal \(day)")
        let label = "Diary for \(day)"
        do {
            let stats = try await reflectOnce(
                model: model, opinions: brain.opinions, journal: journal, label: label,
                policy: .backfill(today), timeoutSecs: timeoutSecs)
            Log.info("reflect", "Backfill \(day) applied: \(stats)")
        } catch {
            Log.info("reflect", "error: Backfill \(day) failed, skipped: \(error)")
        }
        return true
    }

    /// Background loop: daily reflection, then one backfill step per interval —
    /// only while the vision pipeline isn't mid-tick (`isVisionTickRunning`,
    /// ex-`VISION_TICK_RUNNING`). Runs until the surrounding task is cancelled.
    static func reflectionLoop(
        model: any LanguageModel,
        isVisionTickRunning: @MainActor () -> Bool,
        initialDelaySecs: Double = LOOP_INITIAL_DELAY_SECS,
        intervalSecs: Double = LOOP_INTERVAL_SECS
    ) async {
        do { try await Task.sleep(for: .seconds(initialDelaySecs)) } catch { return }
        while !Task.isCancelled {
            if !isVisionTickRunning() {
                await runDailyReflection(model: model)
                await runBackfillStep(model: model)
            }
            do { try await Task.sleep(for: .seconds(intervalSecs)) } catch { return }
        }
    }
}

/// The reflection loop as an object the app can start and stop
/// (ex-`tokio::spawn(reflect::reflection_loop())` in lib.rs `setup`).
final class ReflectionLoop {
    private let model: any LanguageModel
    private let isVisionTickRunning: @MainActor () -> Bool
    private let initialDelaySecs: Double
    private let intervalSecs: Double
    private var task: Task<Void, Never>?

    /// - Parameter isVisionTickRunning: true while a vision-pipeline tick is
    ///   in flight; reflection and backfill yield to it. Owned by the vision
    ///   pipeline (Rust: the `VISION_TICK_RUNNING` atomic).
    init(
        model: any LanguageModel,
        isVisionTickRunning: @escaping @MainActor () -> Bool,
        initialDelaySecs: Double = Reflect.LOOP_INITIAL_DELAY_SECS,
        intervalSecs: Double = Reflect.LOOP_INTERVAL_SECS
    ) {
        self.model = model
        self.isVisionTickRunning = isVisionTickRunning
        self.initialDelaySecs = initialDelaySecs
        self.intervalSecs = intervalSecs
    }

    var isRunning: Bool { task != nil }

    /// Idempotent.
    func start() {
        guard task == nil else { return }
        Log.info("app", "Spawning reflection loop")
        task = Task { [model, isVisionTickRunning, initialDelaySecs, intervalSecs] in
            await Reflect.reflectionLoop(
                model: model, isVisionTickRunning: isVisionTickRunning,
                initialDelaySecs: initialDelaySecs, intervalSecs: intervalSecs)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

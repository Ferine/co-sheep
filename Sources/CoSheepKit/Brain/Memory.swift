import Foundation

// Ex-memory.rs — the sheep's opinions (`opinions.json`) and daily journal
// (`journal/YYYY-MM-DD.md`), plus the context string fed to the model.

// MARK: - Model

nonisolated struct Opinion: Codable, Equatable, Identifiable {
    /// Short topic key for dedup (e.g. "twitter_usage", "dark_mode", "rust_project")
    var topic: String
    /// The sheep's opinion text, evolves over time
    var opinion: String
    /// How many times this pattern has been observed
    var timesSeen: Int
    /// First time noticed
    var firstSeen: String
    /// Most recent observation
    var lastSeen: String
    /// Category: "habit", "fact", "opinion", "pattern"
    var category: String

    var id: String { topic }

    enum CodingKeys: String, CodingKey {
        case topic, opinion
        case timesSeen = "times_seen"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case category
    }
}

/// `opinions.json`. Unlike the config, the fields before `last_reflection_date`
/// are required: a file missing one decodes as a fresh default brain (that is
/// what `unwrap_or_default()` did in Rust).
struct SheepBrain: Codable, Equatable {
    var opinions: [Opinion] = []
    /// Counts for today — reset daily. Tracks things like "twitter visits today"
    var todayCounts: [String: Int] = [:]
    /// Which date the today_counts belong to
    var countsDate: String = BrainTime.today()
    /// Total times the sheep has commented
    var totalComments: Int = 0
    /// Total user interactions (pets, double-clicks, file drops)
    var totalInteractions: Int = 0
    /// Date the daily reflection pass last ran (or was marked done)
    var lastReflectionDate: String = ""
    /// Last journal date processed by the historical backfill
    var backfillCursor: String = ""

    enum CodingKeys: String, CodingKey {
        case opinions
        case todayCounts = "today_counts"
        case countsDate = "counts_date"
        case totalComments = "total_comments"
        case totalInteractions = "total_interactions"
        case lastReflectionDate = "last_reflection_date"
        case backfillCursor = "backfill_cursor"
    }

    /// `SheepBrain::default()`.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opinions = try c.decode([Opinion].self, forKey: .opinions)
        todayCounts = try c.decode([String: Int].self, forKey: .todayCounts)
        countsDate = try c.decode(String.self, forKey: .countsDate)
        totalComments = try c.decode(Int.self, forKey: .totalComments)
        totalInteractions = try c.decode(Int.self, forKey: .totalInteractions)
        lastReflectionDate = try c.decodeSerdeDefault(String.self, forKey: .lastReflectionDate, default: "")
        backfillCursor = try c.decodeSerdeDefault(String.self, forKey: .backfillCursor, default: "")
    }
}

/// What the Brain window shows (`get_brain_for_display`'s JSON, typed).
nonisolated struct BrainDisplay: Codable, Equatable {
    var opinions: [Opinion]
    var todayCounts: [String: Int]
    var totalComments: Int
    var totalInteractions: Int
    var todayJournal: String

    enum CodingKeys: String, CodingKey {
        case opinions
        case todayCounts = "today_counts"
        case totalComments = "total_comments"
        case totalInteractions = "total_interactions"
        case todayJournal = "today_journal"
    }
}

// MARK: - Memory

/// Namespace for the `memory::*` functions.
enum Memory {
    // Opinion scoring — conviction × recency × relevance.
    // Selection for the prompt context; nothing here touches disk.
    private static let RECENCY_HALF_LIFE_DAYS = 14.0
    private static let RELEVANCE_CAP = 2.0
    static let MAX_CONTEXT_OPINIONS = 20
    private static let TOPIC_TOKEN_WEIGHT = 1.0
    private static let TEXT_TOKEN_WEIGHT = 0.5

    /// Last `maxBytes` of `s`, cut forward to a char boundary so slicing
    /// never splits multibyte UTF-8 (the journal is full of æ/ø/å).
    static func tailAtCharBoundary(_ s: String, maxBytes: Int) -> String {
        let bytes = Array(s.utf8)
        if bytes.count <= maxBytes { return s }
        var start = bytes.count - maxBytes
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    /// Rust `char::is_alphanumeric`: Alphabetic or Numeric (Nd/Nl/No).
    private static func isAlphanumeric(_ u: Unicode.Scalar) -> Bool {
        if u.properties.isAlphabetic { return true }
        switch u.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// Lowercased alphanumeric runs of at least 3 *bytes* (Rust `t.len() >= 3`).
    static func tokenize(_ s: String) -> Set<String> {
        var tokens = Set<String>()
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty {
                let t = String(current)
                if t.utf8.count >= 3 { tokens.insert(t) }
                current = String.UnicodeScalarView()
            }
        }
        for u in s.lowercased().unicodeScalars {
            if isAlphanumeric(u) { current.append(u) } else { flush() }
        }
        flush()
        return tokens
    }

    /// The `YYYY-MM-DD` date at the front of a `last_seen`/`first_seen` stamp
    /// (Rust `s.get(..10)` + `parse_from_str`); nil when it isn't one.
    static func stampDate(_ stamp: String) -> NaiveDate? {
        let bytes = Array(stamp.utf8)
        guard bytes.count >= 10,
              let head = String(bytes: bytes[0..<10], encoding: .utf8) else { return nil }
        return NaiveDate(parsing: head)
    }

    /// 0.5^(days_idle / half-life). Unparseable last_seen scores the midpoint —
    /// neither fresh nor ancient.
    static func recencyWeight(lastSeen: String, today: NaiveDate) -> Double {
        guard let date = stampDate(lastSeen) else { return 0.5 }
        let days = Double(max(0, today.daysSince(date)))
        return pow(0.5, days / RECENCY_HALF_LIFE_DAYS)
    }

    /// Token overlap between the query and the opinion; topic-key tokens weigh
    /// double text tokens. Capped so relevance can re-rank but not dominate.
    static func relevanceBoost(_ op: Opinion, queryTokens: Set<String>) -> Double {
        if queryTokens.isEmpty { return 0.0 }
        let topicHits = Double(tokenize(op.topic).intersection(queryTokens).count)
        let textHits = Double(tokenize(op.opinion).intersection(queryTokens).count)
        return min(topicHits * TOPIC_TOKEN_WEIGHT + textHits * TEXT_TOKEN_WEIGHT, RELEVANCE_CAP)
    }

    static func scoreOpinion(_ op: Opinion, queryTokens: Set<String>, today: NaiveDate) -> Double {
        Double(op.timesSeen)
            * recencyWeight(lastSeen: op.lastSeen, today: today)
            * (1.0 + relevanceBoost(op, queryTokens: queryTokens))
    }

    /// Top opinions for the prompt, best first (ties keep stored order).
    static func selectOpinions(
        _ opinions: [Opinion], query: String?, today: NaiveDate, limit: Int
    ) -> [Opinion] {
        let queryTokens = query.map(tokenize) ?? []
        let scored = opinions.enumerated().map { (i, o) in
            (score: scoreOpinion(o, queryTokens: queryTokens, today: today), index: i, op: o)
        }
        let sorted = scored.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.index < b.index
        }
        return sorted.prefix(limit).map(\.op)
    }

    /// Canonical topic key: lowercase, trimmed, whitespace runs become one `_`.
    /// Keeps model-invented variants like "Twitter Usage" from fragmenting
    /// conviction across duplicate opinions.
    static func canonicalizeTopic(_ topic: String) -> String {
        topic.lowercased()
            .split(whereSeparator: { $0.unicodeScalars.allSatisfy { $0.properties.isWhitespace } })
            .joined(separator: "_")
    }

    /// One-time in-memory migration: canonicalize stored topic keys and fold
    /// any duplicates that collapse to the same key. Legacy brains predate
    /// canonical keys; without this, saves and reflection merges can never
    /// match them.
    static func normalizeOpinions(_ opinions: inout [Opinion]) {
        var byKey: [String: Opinion] = [:]
        var order: [String] = []
        for var op in opinions {
            op.topic = canonicalizeTopic(op.topic)
            if var existing = byKey[op.topic] {
                existing.timesSeen += op.timesSeen
                if op.firstSeen < existing.firstSeen {
                    existing.firstSeen = op.firstSeen
                }
                if op.lastSeen > existing.lastSeen {
                    existing.lastSeen = op.lastSeen
                    existing.opinion = op.opinion
                    existing.category = op.category
                }
                byKey[op.topic] = existing
            } else {
                order.append(op.topic)
                byKey[op.topic] = op
            }
        }
        opinions = order.compactMap { byKey.removeValue(forKey: $0) }
    }

    // MARK: Persistence

    static func loadBrain() -> SheepBrain {
        guard FileManager.default.fileExists(atPath: Paths.opinions.path) else { return SheepBrain() }
        var brain = JSONFile.readOrQuarantine(SheepBrain.self, from: Paths.opinions) ?? SheepBrain()
        normalizeOpinions(&brain.opinions)

        // Reset daily counts if it's a new day
        let today = BrainTime.today()
        if brain.countsDate != today {
            brain.todayCounts.removeAll()
            brain.countsDate = today
        }
        return brain
    }

    private static func saveBrain(_ brain: SheepBrain) throws {
        try JSONFile.write(brain, to: Paths.opinions)
    }

    /// Load → mutate → save. The reflection pass uses this so its writes
    /// re-read the brain after the (slow) model call instead of clobbering a
    /// commentary tick's update.
    static func updateBrain(_ f: (inout SheepBrain) -> Void) throws {
        var brain = loadBrain()
        f(&brain)
        try saveBrain(brain)
    }

    /// One-generation backup (`opinions.json.bak`) before a reflection pass
    /// touches opinions.
    static func snapshotOpinions() {
        guard let data = try? Data(contentsOf: Paths.opinions) else { return }
        try? data.write(to: Paths.opinionsBackup, options: .atomic)
    }

    /// Called by the AI to save or update an opinion.
    /// If topic already exists, updates the opinion text and increments the count.
    /// If new, creates it.
    static func saveOpinion(topic rawTopic: String, opinion opinionText: String, category: String) throws {
        let topic = canonicalizeTopic(rawTopic)
        // A blank topic would become a "[]" opinion that ranks into every prompt
        guard !topic.isEmpty else { return }
        var brain = loadBrain()
        let now = BrainTime.nowStamp()
        let today = BrainTime.today()

        if let i = brain.opinions.firstIndex(where: { $0.topic == topic }) {
            brain.opinions[i].timesSeen += 1
            brain.opinions[i].lastSeen = now
            // Update opinion text if the AI has refined it
            if !opinionText.isEmpty {
                brain.opinions[i].opinion = opinionText
            }
            Log.info("memory", "Opinion updated: \(topic) (seen \(brain.opinions[i].timesSeen) times)")
        } else {
            brain.opinions.append(Opinion(
                topic: topic, opinion: opinionText, timesSeen: 1,
                firstSeen: today, lastSeen: now, category: category))
            Log.info("memory", "New opinion formed: \(topic)")
        }

        try saveBrain(brain)
    }

    /// Increment a daily counter (e.g. "twitter_visits") and return the new count.
    @discardableResult
    static func incrementToday(_ key: String) -> Int {
        var brain = loadBrain()
        let count = (brain.todayCounts[key] ?? 0) + 1
        brain.todayCounts[key] = count
        try? saveBrain(brain)
        return count
    }

    /// Record that the sheep made a comment
    static func recordComment() {
        var brain = loadBrain()
        brain.totalComments += 1
        try? saveBrain(brain)
    }

    /// Record a user interaction (pet, double-click, file drop, etc.)
    static func recordInteraction(_ interactionType: String) {
        var brain = loadBrain()
        brain.totalInteractions += 1
        try? saveBrain(brain)

        // Also log to today's journal
        try? appendJournal("*My human \(interactionType) me!*")
    }

    // MARK: Daily journal — raw timestamped observations

    private static func todayJournalPath() -> URL {
        Paths.journal.appendingPathComponent("\(BrainTime.today()).md")
    }

    static func appendJournal(_ entry: String) throws {
        try FileManager.default.createDirectory(at: Paths.journal, withIntermediateDirectories: true)

        let path = todayJournalPath()
        let time = BrainTime.format("hh:mm a")
        let exists = FileManager.default.fileExists(atPath: path.path)

        let formatted: String
        if exists {
            formatted = "\n## \(time)\n\(entry)\n"
        } else {
            let dateHeader = BrainTime.format("MMMM dd, yyyy")
            let name = Config.getSheepName() ?? "Sheep"
            formatted = "# \(dateHeader) — \(name)'s Diary\n\n## \(time)\n\(entry)\n"
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(formatted.utf8))
    }

    /// Recent journal entries from today (last ~2000 bytes).
    static func getTodayJournal() throws -> String {
        let path = todayJournalPath()
        guard FileManager.default.fileExists(atPath: path.path) else { return "" }
        let content = try String(contentsOf: path, encoding: .utf8)
        return tailAtCharBoundary(content, maxBytes: 2000)
    }

    /// Full journal text for a specific day, if that day has entries.
    static func readJournalFor(_ date: String) -> String? {
        try? String(contentsOf: Paths.journal.appendingPathComponent("\(date).md"), encoding: .utf8)
    }

    /// All journal dates on disk, oldest first.
    static func listJournalDays() -> [String] {
        listJournalDays(in: Paths.journal)
    }

    static func listJournalDays(in dir: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .map(rustFileStem)
            .filter { NaiveDate(parsing: $0) != nil }
            .sorted { $0.utf8Precedes($1) }
    }

    // MARK: Combined context — what gets fed to the model

    /// Build the full context for the AI: opinions + daily counts + recent journal.
    /// This is what lets the sheep feel like it *knows* you.
    /// `query` (screen text or chat message) steers which opinions surface.
    static func getRecentContext(query: String?) throws -> String {
        var parts: [String] = []
        let brain = loadBrain()

        // 1. Opinions — scored by conviction × recency × relevance, best first
        if !brain.opinions.isEmpty {
            let selected = selectOpinions(
                brain.opinions, query: query, today: BrainTime.todayNaive(), limit: MAX_CONTEXT_OPINIONS)
            let opinionLines = selected.map {
                "- [\($0.topic)] \($0.opinion) (seen \($0.timesSeen) times, last: \($0.lastSeen))"
            }
            parts.append("## Your opinions about your human (strongest first)\n\(opinionLines.joined(separator: "\n"))")
        }

        // 2. Today's pattern counts
        if !brain.todayCounts.isEmpty {
            let counts = brain.todayCounts
                .map { "- \($0.key): \($0.value) times today" }
                .sorted { $0.utf8Precedes($1) }
            parts.append("## Today's tallies\n\(counts.joined(separator: "\n"))")
        }

        // 3. Stats
        parts.append(
            "## Stats\nTotal comments made: \(brain.totalComments)\nTotal interactions with human: \(brain.totalInteractions)")

        // 4. Today's journal (recent observations)
        let journal = try getTodayJournal()
        if !journal.isEmpty {
            // Only the tail — the opinions carry the persistent knowledge
            let tail: String
            if journal.utf8.count > 1200 {
                let approx = tailAtCharBoundary(journal, maxBytes: 1200)
                // Start at the next full line if we cut mid-line
                if let nl = approx.utf8.firstIndex(of: 10) {
                    tail = String(approx[approx.utf8.index(after: nl)...])
                } else {
                    tail = approx
                }
            } else {
                tail = journal
            }
            parts.append("## Recent diary entries (today)\n\(tail)")
        }

        return parts.joined(separator: "\n\n")
    }

    /// For the memory viewer UI — opinions, tallies, stats and today's journal.
    static func getBrainForDisplay() -> BrainDisplay {
        let brain = loadBrain()
        let journal = (try? getTodayJournal()) ?? ""
        return BrainDisplay(
            opinions: brain.opinions, todayCounts: brain.todayCounts,
            totalComments: brain.totalComments, totalInteractions: brain.totalInteractions,
            todayJournal: journal)
    }
}

extension Paths {
    /// `opinions.json.bak` — one generation, written before a reflection pass.
    static var opinionsBackup: URL { file("opinions.json.bak") }
}

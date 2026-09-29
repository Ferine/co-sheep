import Foundation

// Ex-friend_memory.rs — one brain per friend (`friends/<id>.json`): mood,
// affinity toward every other sheep, the last 20 memories and running stats.

nonisolated struct FriendBrain: Codable, Equatable {
    var id: String
    var name: String
    var mood: String
    var relationships: [String: Int]
    var memories: [FriendMemoryEntry]
    var stats: FriendStats
    var lastMoodChange: String
    /// Last date `decayAffinities` ran for this brain — persisted so app
    /// restarts within the same day don't decay/age the brain again.
    var lastDecayDate: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, mood, relationships, memories, stats
        case lastMoodChange = "last_mood_change"
        case lastDecayDate = "last_decay_date"
    }

    init(
        id: String, name: String, mood: String, relationships: [String: Int],
        memories: [FriendMemoryEntry], stats: FriendStats, lastMoodChange: String,
        lastDecayDate: String = ""
    ) {
        self.id = id
        self.name = name
        self.mood = mood
        self.relationships = relationships
        self.memories = memories
        self.stats = stats
        self.lastMoodChange = lastMoodChange
        self.lastDecayDate = lastDecayDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        mood = try c.decode(String.self, forKey: .mood)
        relationships = try c.decode([String: Int].self, forKey: .relationships)
        memories = try c.decode([FriendMemoryEntry].self, forKey: .memories)
        stats = try c.decode(FriendStats.self, forKey: .stats)
        lastMoodChange = try c.decode(String.self, forKey: .lastMoodChange)
        lastDecayDate = try c.decodeSerdeDefault(String.self, forKey: .lastDecayDate, default: "")
    }
}

/// One remembered event. (Rust name `FriendMemory`; renamed because the
/// `FriendMemory` namespace below takes the module's name.)
nonisolated struct FriendMemoryEntry: Codable, Equatable {
    var text: String
    var kind: String
    var timestamp: String
    var with: String?

    enum CodingKeys: String, CodingKey { case text, kind, timestamp, with }

    init(text: String, kind: String, timestamp: String, with: String? = nil) {
        self.text = text
        self.kind = kind
        self.timestamp = timestamp
        self.with = with
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        kind = try c.decode(String.self, forKey: .kind)
        timestamp = try c.decode(String.self, forKey: .timestamp)
        with = try c.decodeIfPresent(String.self, forKey: .with)
    }

    /// serde writes `None` as `"with": null` (no skip_serializing_if), so
    /// do the same instead of omitting the key.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(kind, forKey: .kind)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(with, forKey: .with)
    }
}

nonisolated struct FriendStats: Codable, Equatable {
    var conversationsToday: Int = 0
    var conversationsTotal: Int = 0
    var timesPetted: Int = 0
    var groupActivities: Int = 0
    var daysAlive: Int = 0

    enum CodingKeys: String, CodingKey {
        case conversationsToday = "conversations_today"
        case conversationsTotal = "conversations_total"
        case timesPetted = "times_petted"
        case groupActivities = "group_activities"
        case daysAlive = "days_alive"
    }

    init(
        conversationsToday: Int = 0, conversationsTotal: Int = 0, timesPetted: Int = 0,
        groupActivities: Int = 0, daysAlive: Int = 0
    ) {
        self.conversationsToday = conversationsToday
        self.conversationsTotal = conversationsTotal
        self.timesPetted = timesPetted
        self.groupActivities = groupActivities
        self.daysAlive = daysAlive
    }

    /// All five counters are required on disk (no `#[serde(default)]`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationsToday = try c.decode(Int.self, forKey: .conversationsToday)
        conversationsTotal = try c.decode(Int.self, forKey: .conversationsTotal)
        timesPetted = try c.decode(Int.self, forKey: .timesPetted)
        groupActivities = try c.decode(Int.self, forKey: .groupActivities)
        daysAlive = try c.decode(Int.self, forKey: .daysAlive)
    }
}

/// One card of the Relationships window (`get_all_relationships`' JSON, typed).
nonisolated struct FriendRelationshipSummary: Codable, Equatable {
    struct Stats: Codable, Equatable {
        var conversationsTotal: Int
        var timesPetted: Int
        var groupActivities: Int

        enum CodingKeys: String, CodingKey {
            case conversationsTotal = "conversations_total"
            case timesPetted = "times_petted"
            case groupActivities = "group_activities"
        }
    }

    var name: String
    var mood: String
    var relationships: [String: Int]
    var stats: Stats
}

/// Namespace for the `friend_memory::*` functions. Brains are cached in
/// memory (the viewers read the cache, so only friends that were
/// `ensureBrain`ed or touched this session show up) and written through on
/// every change.
enum FriendMemory {
    private static var cache: [String: FriendBrain] = [:]
    private static var lastDecayDate = ""

    /// Forget every cached brain and the in-process decay guard. The Rust
    /// caches were process-global; tests (and a `Paths.root` swap) need this.
    static func resetCache() {
        cache.removeAll()
        lastDecayDate = ""
    }

    private static func friendPath(_ id: String) -> URL {
        Paths.friends.appendingPathComponent("\(id).json")
    }

    private static func nowISO() -> String { BrainTime.nowStamp() }

    private static func today() -> String { BrainTime.today() }

    /// Read a brain file; an unreadable/invalid file yields nil.
    private static func readBrain(_ id: String) -> FriendBrain? {
        let path = friendPath(id)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return JSONFile.readOrQuarantine(FriendBrain.self, from: path)
    }

    private static func loadBrain(_ id: String) -> FriendBrain {
        if let brain = cache[id] { return brain }
        let brain = readBrain(id) ?? newBrain(id, id)
        cache[id] = brain
        return brain
    }

    private static func writeBrainFile(_ brain: FriendBrain) {
        try? JSONFile.write(brain, to: friendPath(brain.id))
    }

    private static func saveBrain(_ brain: FriendBrain) {
        writeBrainFile(brain)
        cache[brain.id] = brain
    }

    static func newBrain(_ id: String, _ name: String) -> FriendBrain {
        let mood = id == "good_colleague" ? "grumpy" : "happy"
        var relationships: [String: Int] = [:]
        if id == "good_colleague" {
            relationships["main"] = 10
        }
        return FriendBrain(
            id: id, name: name, mood: mood, relationships: relationships,
            memories: [], stats: FriendStats(), lastMoodChange: nowISO(), lastDecayDate: today())
    }

    static func addMemory(_ brain: inout FriendBrain, _ text: String, _ kind: String, with: String?) {
        brain.memories.append(FriendMemoryEntry(text: text, kind: kind, timestamp: nowISO(), with: with))
        // Keep only the most recent 20
        if brain.memories.count > 20 {
            brain.memories.removeFirst(brain.memories.count - 20)
        }
    }

    static func adjustAffinity(_ brain: inout FriendBrain, _ otherId: String, _ delta: Int) {
        let current = brain.relationships[otherId] ?? 0
        brain.relationships[otherId] = min(max(current + delta, -10), 100)
    }

    // MARK: Public API

    /// Make sure a brain is loaded for `id` (from disk if a file exists —
    /// adopting `name` — else fresh). Does not write.
    static func ensureBrain(_ id: String, _ name: String) {
        if cache[id] != nil { return }
        var brain: FriendBrain
        if FileManager.default.fileExists(atPath: friendPath(id).path) {
            brain = readBrain(id) ?? newBrain(id, name)
            brain.name = name
        } else {
            brain = newBrain(id, name)
        }
        cache[id] = brain
    }

    static func recordConversation(_ idA: String, _ idB: String, _ topic: String) {
        let nameB = loadBrain(idB).name
        let nameA = loadBrain(idA).name

        var a = loadBrain(idA)
        adjustAffinity(&a, idB, 1)
        addMemory(&a, "Talked with \(nameB) about \(topic)", "conversation", with: idB)
        a.stats.conversationsTotal += 1
        a.stats.conversationsToday += 1
        saveBrain(a)

        var b = loadBrain(idB)
        adjustAffinity(&b, idA, 1)
        addMemory(&b, "Talked with \(nameA) about \(topic)", "conversation", with: idA)
        b.stats.conversationsTotal += 1
        b.stats.conversationsToday += 1
        saveBrain(b)
    }

    static func recordGroupActivity(_ participantIds: [String], _ activityType: String) {
        var names: [String: String] = [:]
        for id in participantIds { names[id] = loadBrain(id).name }

        for id in participantIds {
            var brain = loadBrain(id)
            let otherNames = participantIds
                .filter { $0 != id }
                .map { names[$0] ?? "someone" }
            let text = "Joined a \(activityType) with \(otherNames.joined(separator: ", "))"
            addMemory(&brain, text, "activity", with: nil)
            brain.stats.groupActivities += 1
            for otherId in participantIds where otherId != id {
                adjustAffinity(&brain, otherId, 2)
            }
            saveBrain(brain)
        }
    }

    static func recordPet(_ id: String) {
        var brain = loadBrain(id)
        adjustAffinity(&brain, "main", 1)
        addMemory(&brain, "Got petted by human!", "interaction", with: "main")
        brain.stats.timesPetted += 1
        brain.mood = "happy"
        brain.lastMoodChange = nowISO()
        saveBrain(brain)
    }

    /// A friend was removed: delete its brain, evict it from the cache (or the
    /// Relationships viewer shows a ghost until restart), and scrub its id from
    /// every remaining brain's relationships map. Memories that mention it are
    /// kept on purpose — the flock remembers the departed.
    static func removeBrain(_ id: String) {
        try? FileManager.default.removeItem(at: friendPath(id))
        cache.removeValue(forKey: id)

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: Paths.friends.path) else {
            return
        }
        // Only brain files — a stray .DS_Store or backup must not become a ghost friend.
        for name in names where name.hasSuffix(".json") {
            let otherId = rustFileStem(name)
            if otherId == id { continue }
            var brain = loadBrain(otherId)
            if brain.relationships.removeValue(forKey: id) != nil {
                saveBrain(brain)
            }
        }
    }

    static func getMood(_ id: String) -> String {
        loadBrain(id).mood
    }

    /// The full brain for the Friend Memory window.
    static func getFriendBrain(_ id: String) -> FriendBrain {
        loadBrain(id)
    }

    /// `get_friend_brain_json`: the brain as an arbitrary JSON value (same
    /// shape as the file on disk).
    static func getFriendBrainJSON(_ id: String) -> JSONValue {
        let brain = loadBrain(id)
        guard let data = try? JSONFile.encoder().encode(brain),
              let value = try? JSONFile.decoder().decode(JSONValue.self, from: data) else { return .null }
        return value
    }

    /// Cards for every cached brain, keyed by friend id.
    static func getAllRelationships() -> [String: FriendRelationshipSummary] {
        var result: [String: FriendRelationshipSummary] = [:]
        for (id, brain) in cache {
            result[id] = FriendRelationshipSummary(
                name: brain.name, mood: brain.mood, relationships: brain.relationships,
                stats: .init(
                    conversationsTotal: brain.stats.conversationsTotal,
                    timesPetted: brain.stats.timesPetted,
                    groupActivities: brain.stats.groupActivities))
        }
        return result
    }

    static func getAllMoods() -> [String: String] {
        cache.mapValues(\.mood)
    }

    static func decayAffinities() {
        let todayStr = today()
        // Cheap in-process fast path; the real once-per-day guard is the
        // persisted per-brain last_decay_date below.
        if lastDecayDate == todayStr { return }
        lastDecayDate = todayStr

        for id in Array(cache.keys) {
            guard var brain = cache[id], brain.lastDecayDate != todayStr else { continue }
            brain.lastDecayDate = todayStr
            // Reset daily conversation count
            brain.stats.conversationsToday = 0
            brain.stats.daysAlive += 1
            // Decay affinities by 1
            for (other, val) in brain.relationships {
                if val > 0 {
                    brain.relationships[other] = val - 1
                } else if val < -5 {
                    brain.relationships[other] = -5
                }
            }
            cache[id] = brain
            // Save to disk
            writeBrainFile(brain)
        }
    }

    static func updateMood(_ id: String) {
        var brain = loadBrain(id)
        let convos = brain.stats.conversationsToday
        let hour = BrainTime.hour()

        let newMood: String
        if convos >= 5 {
            newMood = "excited"
        } else if convos >= 2 {
            newMood = "happy"
        } else if hour >= 23 || hour <= 4 {
            newMood = "sleepy"
        } else if brain.stats.timesPetted > 0 && brain.mood == "happy" {
            newMood = "happy"
        } else if id == "good_colleague" {
            newMood = "grumpy" // GC defaults to grumpy
        } else {
            // Drift toward neutral
            newMood = "happy"
        }

        if brain.mood != newMood {
            brain.mood = newMood
            brain.lastMoodChange = nowISO()
            saveBrain(brain)
        }
    }

    /// Compact social context for friend-to-friend chat prompts, ≤ 300 bytes:
    /// mood, affinity toward the partner, and the last few memories.
    static func getChatContext(_ id: String, _ otherId: String) -> String {
        let brain = loadBrain(id)
        let otherName = loadBrain(otherId).name
        return formatChatContext(brain, otherId, otherName)
    }

    static func formatChatContext(_ brain: FriendBrain, _ otherId: String, _ otherName: String) -> String {
        let affinity = brain.relationships[otherId] ?? 0
        let label: String
        if affinity > 30 {
            label = "loves"
        } else if affinity > 10 {
            label = "likes"
        } else if affinity < 0 {
            label = "avoids"
        } else {
            label = "is neutral toward"
        }
        var s = "\(brain.name) is \(brain.mood) and \(label) \(otherName)."
        let recent = brain.memories.reversed().prefix(3).map(\.text)
        if !recent.isEmpty {
            s += " Remembers: \(recent.joined(separator: "; "))."
        }
        // Cap at 300 bytes, cut back to a char boundary.
        let bytes = Array(s.utf8)
        if bytes.count > 300 {
            var end = 300
            while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
            s = String(decoding: bytes[..<end], as: UTF8.self)
        }
        return s
    }
}

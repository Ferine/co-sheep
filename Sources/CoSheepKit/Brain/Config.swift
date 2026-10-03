import Foundation

// Ex-onboarding.rs — `~/.co-sheep/config.json`.
//
// Mirrors serde exactly: absent fields with `#[serde(default)]` fall back to
// their default, required fields (name, personality, interval_secs; a
// friend's id/name/color) must be present or the whole file is rejected,
// unknown fields (old api_key / ai_provider / lmstudio_*) are ignored and
// dropped on the next save.

nonisolated extension KeyedDecodingContainer {
    /// serde `#[serde(default)]` semantics: an absent key yields `fallback`,
    /// a present key must decode (so `null` for a non-Option field throws,
    /// exactly like serde).
    func decodeSerdeDefault<T: Decodable>(
        _ type: T.Type, forKey key: Key, default fallback: @autoclosure () -> T
    ) throws -> T {
        contains(key) ? try decode(type, forKey: key) : fallback()
    }
}

nonisolated struct FriendDef: Codable, Equatable {
    var id: String
    var name: String
    var color: String
    var personality: String = "wholesome"
    var accessories: [String] = []
    var scale: Double = 1.0

    enum CodingKeys: String, CodingKey {
        case id, name, color, personality, accessories, scale
    }

    init(
        id: String, name: String, color: String,
        personality: String = "wholesome", accessories: [String] = [], scale: Double = 1.0
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.personality = personality
        self.accessories = accessories
        self.scale = scale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decode(String.self, forKey: .color)
        personality = try c.decodeSerdeDefault(String.self, forKey: .personality, default: "wholesome")
        accessories = try c.decodeSerdeDefault([String].self, forKey: .accessories, default: [])
        scale = try c.decodeSerdeDefault(Double.self, forKey: .scale, default: 1.0)
    }
}

/// AI runs exclusively on-device (Apple Intelligence); old provider fields
/// (api_key, ai_provider, lmstudio_*) in existing config files are ignored.
nonisolated struct SheepConfig: Codable, Equatable {
    var name: String = "Sheep"
    var personality: String = "snarky"
    var intervalSecs: Int = 150
    var language: String = "nynorsk"
    var friends: [FriendDef] = []
    var breakReminders: Bool = true
    var easterMode: String = "auto"
    var summerMode: String = "auto"
    var weatherLocation: String = ""
    var accessories: [String] = []
    var mcpEnabled: Bool = true
    var mcpPort: UInt16 = 4917
    var mcpToken: String = ""
    /// Agent herd: every Claude Code session gets a lamb on the desktop.
    var herdEnabled: Bool = true
    /// Agent herd: lamb cap (clamped to `herdLambRange` where it is used).
    var herdMaxLambs: Int = 8
    /// Agent herd: the main sheep comments on the herd.
    var shepherdCommentary: Bool = true

    /// The range `herdMaxLambs` is clamped to at the use site.
    static let herdLambRange = 1...16

    /// `herdMaxLambs` clamped to `herdLambRange`.
    var effectiveMaxLambs: Int {
        min(max(herdMaxLambs, Self.herdLambRange.lowerBound), Self.herdLambRange.upperBound)
    }

    enum CodingKeys: String, CodingKey {
        case name, personality
        case intervalSecs = "interval_secs"
        case language, friends
        case breakReminders = "break_reminders"
        case easterMode = "easter_mode"
        case summerMode = "summer_mode"
        case weatherLocation = "weather_location"
        case accessories
        case mcpEnabled = "mcp_enabled"
        case mcpPort = "mcp_port"
        case mcpToken = "mcp_token"
        case herdEnabled = "herd_enabled"
        case herdMaxLambs = "herd_max_lambs"
        case shepherdCommentary = "shepherd_commentary"
    }

    /// `SheepConfig::default()`.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        personality = try c.decode(String.self, forKey: .personality)
        intervalSecs = try c.decode(Int.self, forKey: .intervalSecs)
        language = try c.decodeSerdeDefault(String.self, forKey: .language, default: "nynorsk")
        friends = try c.decodeSerdeDefault([FriendDef].self, forKey: .friends, default: [])
        breakReminders = try c.decodeSerdeDefault(Bool.self, forKey: .breakReminders, default: true)
        easterMode = try c.decodeSerdeDefault(String.self, forKey: .easterMode, default: "auto")
        summerMode = try c.decodeSerdeDefault(String.self, forKey: .summerMode, default: "auto")
        weatherLocation = try c.decodeSerdeDefault(String.self, forKey: .weatherLocation, default: "")
        accessories = try c.decodeSerdeDefault([String].self, forKey: .accessories, default: [])
        mcpEnabled = try c.decodeSerdeDefault(Bool.self, forKey: .mcpEnabled, default: true)
        mcpPort = try c.decodeSerdeDefault(UInt16.self, forKey: .mcpPort, default: 4917)
        mcpToken = try c.decodeSerdeDefault(String.self, forKey: .mcpToken, default: "")
        herdEnabled = try c.decodeSerdeDefault(Bool.self, forKey: .herdEnabled, default: true)
        herdMaxLambs = try c.decodeSerdeDefault(Int.self, forKey: .herdMaxLambs, default: 8)
        shepherdCommentary = try c.decodeSerdeDefault(Bool.self, forKey: .shepherdCommentary, default: true)
    }
}

/// Namespace for the `onboarding::*` functions. Reads and writes go straight
/// to `Paths.config`; everything is main-actor, so the Rust `CONFIG_LOCK`
/// (which only guarded concurrent commands) has nothing left to guard.
enum Config {
    /// True when no config file exists yet (`onboarding::needs_onboarding`).
    static func needsOnboarding() -> Bool {
        !FileManager.default.fileExists(atPath: Paths.config.path)
    }

    /// Preserve the existing config, just update the name.
    static func saveConfig(name: String) throws {
        try updateConfig { $0.name = name }
    }

    /// Load for a read-modify-write: a missing file yields defaults, but a
    /// corrupt file throws — otherwise the next save would silently replace
    /// the friends and settings with defaults.
    private static func loadConfigStrict() throws -> SheepConfig {
        guard FileManager.default.fileExists(atPath: Paths.config.path) else { return SheepConfig() }
        return try JSONFile.readStrict(SheepConfig.self, from: Paths.config)
    }

    /// Read-modify-write of the config. All mutations must go through here
    /// rather than `loadConfig()` + `writeConfig()`.
    @discardableResult
    static func updateConfig(_ mutate: (inout SheepConfig) -> Void) throws -> SheepConfig {
        var config = try loadConfigStrict()
        mutate(&config)
        try writeConfig(config)
        return config
    }

    /// nil when the file is missing or unparseable.
    static func loadConfig() -> SheepConfig? {
        guard FileManager.default.fileExists(atPath: Paths.config.path) else { return nil }
        return JSONFile.read(SheepConfig.self, from: Paths.config)
    }

    static func writeConfig(_ config: SheepConfig) throws {
        try JSONFile.write(config, to: Paths.config)
    }

    static func getSheepName() -> String? {
        loadConfig()?.name
    }

    static func getIntervalSecs() -> Int {
        loadConfig()?.intervalSecs ?? 150
    }

    static func getPersonality() -> String {
        loadConfig()?.personality ?? "snarky"
    }

    static func getLanguage() -> String {
        loadConfig()?.language ?? "nynorsk"
    }

    static func getBreakReminders() -> Bool {
        loadConfig()?.breakReminders ?? true
    }

    static func getWeatherLocation() -> String {
        loadConfig()?.weatherLocation ?? ""
    }

    static func getEasterMode() -> String {
        loadConfig()?.easterMode ?? "auto"
    }
}

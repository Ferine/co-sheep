import Foundation
import Testing
@testable import CoSheepKit

// Ex-onboarding.rs `mcp_config_tests` + Codable/serde-compat coverage.
extension BrainTests {
    @Suite("config")
    struct ConfigTests {
        // MARK: ported from onboarding.rs

        @Test func defaultsEnableMcpOn4917() {
            let c = SheepConfig()
            #expect(c.mcpEnabled)
            #expect(c.mcpPort == 4917)
            #expect(c.mcpToken == "")
        }

        @Test func configMissingMcpFieldsDeserializesWithDefaults() throws {
            let json = #"{"name":"S","personality":"snarky","interval_secs":150}"#
            let c = try JSONDecoder().decode(SheepConfig.self, from: Data(json.utf8))
            #expect(c.mcpEnabled)
            #expect(c.mcpPort == 4917)
        }

        // MARK: new

        @Test func otherDefaultsMatchRust() {
            let c = SheepConfig()
            #expect(c.name == "Sheep")
            #expect(c.personality == "snarky")
            #expect(c.intervalSecs == 150)
            #expect(c.language == "nynorsk")
            #expect(c.friends.isEmpty)
            #expect(c.breakReminders)
            #expect(c.easterMode == "auto")
            #expect(c.summerMode == "auto")
            #expect(c.weatherLocation == "")
            #expect(c.accessories.isEmpty)
        }

        @Test func missingOptionalFieldsTakeSerdeDefaults() throws {
            let json = #"""
            {"name":"S","personality":"chaotic","interval_secs":60,
             "friends":[{"id":"f1","name":"Pelle","color":"blue"}]}
            """#
            let c = try JSONDecoder().decode(SheepConfig.self, from: Data(json.utf8))
            #expect(c.language == "nynorsk")
            #expect(c.breakReminders)
            #expect(c.easterMode == "auto")
            #expect(c.summerMode == "auto")
            #expect(c.friends == [FriendDef(id: "f1", name: "Pelle", color: "blue")])
            #expect(c.friends[0].personality == "wholesome")
            #expect(c.friends[0].scale == 1.0)
            #expect(c.friends[0].accessories.isEmpty)
        }

        @Test func requiredFieldsAreRequired() {
            for json in [
                #"{"personality":"snarky","interval_secs":150}"#,
                #"{"name":"S","interval_secs":150}"#,
                #"{"name":"S","personality":"snarky"}"#,
                #"{"name":"S","personality":"snarky","interval_secs":150,"friends":[{"id":"a","name":"b"}]}"#,
            ] {
                #expect(throws: (any Error).self) {
                    try JSONDecoder().decode(SheepConfig.self, from: Data(json.utf8))
                }
            }
        }

        @Test func legacyProviderFieldsAreIgnoredAndDroppedOnSave() throws {
            try withBrainRoot { _ in
                try write(
                    #"{"name":"Dolly","personality":"snarky","interval_secs":90,"api_key":"sk-x","ai_provider":"lmstudio","lmstudio_url":"http://x"}"#,
                    to: Paths.config)
                #expect(Config.loadConfig()?.name == "Dolly")
                try Config.updateConfig { $0.language = "german" }
                guard case .object(let o) = try readJSON(Paths.config) else {
                    Issue.record("config.json is not an object")
                    return
                }
                #expect(o["api_key"] == nil)
                #expect(o["ai_provider"] == nil)
                #expect(o["language"] == .string("german"))
            }
        }

        @Test func savedShapeUsesTheSerdeKeys() throws {
            try withBrainRoot { _ in
                var c = SheepConfig()
                c.friends = [FriendDef(id: "f", name: "N", color: "pink", accessories: ["hat"], scale: 1.1)]
                try Config.writeConfig(c)
                let json = try #require(try readJSON(Paths.config).objectValue)
                #expect(Set(json.keys) == [
                    "name", "personality", "interval_secs", "language", "friends", "break_reminders",
                    "easter_mode", "summer_mode", "weather_location", "accessories",
                    "mcp_enabled", "mcp_port", "mcp_token",
                ])
                #expect(json["interval_secs"] == .number(150))
                #expect(json["mcp_port"] == .number(4917))
                #expect(Config.loadConfig() == c)
                let friend = try #require(json["friends"]?.arrayValue?.first?.objectValue)
                #expect(Set(friend.keys) == ["id", "name", "color", "personality", "accessories", "scale"])
                #expect(friend["scale"] == .number(1.1))
                #expect(friend["accessories"] == .array([.string("hat")]))
            }
        }

        @Test func needsOnboardingUntilConfigExists() throws {
            try withBrainRoot { _ in
                #expect(Config.needsOnboarding())
                #expect(Config.loadConfig() == nil)
                try Config.saveConfig(name: "Woolly")
                #expect(!Config.needsOnboarding())
                #expect(Config.getSheepName() == "Woolly")
            }
        }

        @Test func saveConfigKeepsEverythingButTheName() throws {
            try withBrainRoot { _ in
                var c = SheepConfig()
                c.name = "Old"
                c.personality = "wholesome"
                c.friends = [FriendDef(id: "f", name: "F", color: "gold")]
                c.mcpToken = "secret"
                try Config.writeConfig(c)
                try Config.saveConfig(name: "New")
                var expected = c
                expected.name = "New"
                #expect(Config.loadConfig() == expected)
            }
        }

        @Test func updateConfigRefusesToOverwriteACorruptFile() throws {
            try withBrainRoot { _ in
                try write("{ not json", to: Paths.config)
                #expect(throws: (any Error).self) { try Config.updateConfig { $0.name = "X" } }
                #expect(try String(contentsOf: Paths.config, encoding: .utf8) == "{ not json")
                #expect(Config.loadConfig() == nil)
            }
        }

        @Test func updateConfigOnMissingFileStartsFromDefaults() throws {
            try withBrainRoot { _ in
                let c = try Config.updateConfig { $0.weatherLocation = "Oslo" }
                #expect(c.weatherLocation == "Oslo")
                #expect(c.name == "Sheep")
                #expect(Config.getWeatherLocation() == "Oslo")
            }
        }

        @Test func gettersFallBackWhenThereIsNoConfig() {
            withBrainRoot { _ in
                #expect(Config.getSheepName() == nil)
                #expect(Config.getIntervalSecs() == 150)
                #expect(Config.getPersonality() == "snarky")
                #expect(Config.getLanguage() == "nynorsk")
                #expect(Config.getBreakReminders())
                #expect(Config.getWeatherLocation() == "")
                #expect(Config.getEasterMode() == "auto")
            }
        }

        @Test func gettersReadTheSavedValues() throws {
            try withBrainRoot { _ in
                try Config.updateConfig {
                    $0.intervalSecs = 42
                    $0.personality = "chaotic"
                    $0.language = "german"
                    $0.breakReminders = false
                    $0.easterMode = "on"
                }
                #expect(Config.getIntervalSecs() == 42)
                #expect(Config.getPersonality() == "chaotic")
                #expect(Config.getLanguage() == "german")
                #expect(!Config.getBreakReminders())
                #expect(Config.getEasterMode() == "on")
            }
        }
    }
}

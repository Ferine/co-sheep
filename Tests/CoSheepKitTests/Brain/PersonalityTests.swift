import Foundation
import Testing
@testable import CoSheepKit

// personality.rs had no tests. The prompt text itself was diffed against the
// Rust source when porting; these pin the assembly logic and the pieces the
// rest of the app parses out of the prompts.
extension BrainTests {
    @Suite("personality")
    struct PersonalityTests {
        private func at(hour: Int, _ body: () throws -> Void) rethrows {
            try withBrainRoot(now: localDate(2026, 7, 4, hour, 9)) { _ in try body() }
        }

        @Test func timePeriodBoundaries() {
            let expected: [(Int, String)] = [
                (0, "dead of night"), (4, "dead of night"), (5, "barely dawn"), (6, "morning"), (8, "morning"),
                (9, "Mid-morning"), (11, "Mid-morning"), (12, "Lunchtime"), (13, "Post-lunch"),
                (14, "Post-lunch"), (15, "Afternoon"), (17, "Afternoon"), (18, "Evening"), (21, "Evening"),
                (22, "getting late"), (23, "late night"),
            ]
            for (hour, fragment) in expected {
                at(hour: hour) {
                    let ctx = Personality.getTimeContext()
                    #expect(ctx.timePeriod.contains(fragment), "hour \(hour): \(ctx.timePeriod)")
                }
            }
        }

        @Test func timeContextFormatsLikeStrftime() {
            at(hour: 15) {
                let ctx = Personality.getTimeContext()
                #expect(ctx.timeStr == "03:09 PM")
                #expect(ctx.dayStr == "Saturday")   // 2026-07-04
            }
        }

        @Test func systemPromptUsesDefaultsWithoutAConfig() {
            at(hour: 10) {
                let p = Personality.getSystemPrompt(recentJournal: "", weatherContext: "")
                #expect(p.hasPrefix("You are Sheep, a pixel art sheep that lives on someone's desktop.\n\nYour traits:\n- You judge your human's screen time habits mercilessly"))
                #expect(p.contains("LANGUAGE: You MUST write all your comments in nynorsk. This is critical — always respond in nynorsk, no exceptions."))
                #expect(p.contains("TIME AWARENESS: It's currently 10:09 AM on Saturday. Mid-morning. Peak productivity hours (in theory).\nYou may reference the time naturally if relevant, but don't force it.\n\nNo diary entries yet — this is a fresh start.\n\nLANGUAGE:"))
                #expect(p.contains("FRIENDS ON SCREEN: You're not alone! These characters are also on the desktop:\n- Good Colleague — a Norwegian office sheep"))
                #expect(p.contains("(\"he's just standing there... menacingly\", \"Good Colleague seems stressed\")."))
                #expect(p.hasSuffix("that's what makes you feel alive."))
            }
        }

        @Test func systemPromptTemplateBracesAreSingle() {
            at(hour: 10) {
                let p = Personality.getSystemPrompt(recentJournal: "", weatherContext: "")
                #expect(p.contains(#"{"text": "your comment", "animation": "bounce", "opinion_topic": "twitter_usage", "opinion": "My human is addicted to Twitter", "opinion_category": "habit", "count": "twitter_visits"}"#))
                #expect(p.contains(#"{"text": "comment", "animation": null}"#))
                #expect(!p.contains("{{") && !p.contains("}}"))
            }
        }

        @Test func systemPromptPicksUpConfigJournalAndWeather() throws {
            try withBrainRoot(now: localDate(2026, 7, 4, 22, 0)) { _ in
                try Config.updateConfig {
                    $0.name = "Dolly"
                    $0.personality = "passive-aggressive"
                    $0.language = "german"
                    $0.friends = [FriendDef(id: "f1", name: "Pelle", color: "blue"),
                                  FriendDef(id: "f2", name: "Kari", color: "pink")]
                }
                let p = Personality.getSystemPrompt(
                    recentJournal: "## 09:00 AM\nsaw twitter", weatherContext: "Weather: rain, 9C")
                #expect(p.hasPrefix("You are Dolly, a pixel art sheep"))
                #expect(p.contains("- You are the master of backhanded compliments"))
                #expect(p.contains("in german. This is critical — always respond in german"))
                #expect(p.contains("- Pelle — a friend sheep hanging out on the desktop.\n- Kari — a friend sheep hanging out on the desktop.\nYou may occasionally comment on your friends"))
                #expect(p.contains("It's getting late. Responsible humans would start wrapping up."))
                #expect(p.contains("but don't force it.\n\nWeather: rain, 9C\nYou may reference the weather naturally if relevant, but don't force it.\n\nRecent diary entries:\n## 09:00 AM\nsaw twitter\n\nLANGUAGE:"))
            }
        }

        @Test func everyPersonalityHasItsOwnTraitsAndUnknownMeansSnarky() throws {
            try withBrainRoot(now: localDate(2026, 7, 4, 10, 0)) { _ in
                let firstTrait: [(String, String)] = [
                    ("wholesome", "- You're genuinely supportive and encouraging"),
                    ("chaotic", "- You are UNHINGED. Chaotic energy. Zero filter"),
                    ("passive-aggressive", "- You are the master of backhanded compliments"),
                    ("snarky", "- You judge your human's screen time habits mercilessly"),
                    ("something-else", "- You judge your human's screen time habits mercilessly"),
                ]
                for (personality, trait) in firstTrait {
                    try Config.updateConfig { $0.personality = personality }
                    #expect(Personality.getSystemPrompt(recentJournal: "", weatherContext: "").contains("Your traits:\n\(trait)\n"),
                            "\(personality)")
                }
            }
        }

        @Test func chatPromptDefaults() {
            at(hour: 10) {
                let p = Personality.getChatPrompt(recentContext: "", weatherContext: "")
                #expect(p == """
                You are Sheep, a pixel art sheep on someone's desktop. You're snarky, judgmental about screen habits, self-aware desktop pet. You observe and judge.

                FRIENDS: Good Colleague (Norwegian office sheep) is nearby.
                It's 10:09 AM on Saturday. Mid-morning. Peak productivity hours (in theory).

                Your human is talking to you directly. Respond in character. Keep it short (1-3 sentences).
                You can form opinions about what they say. Be yourself — don't be helpful or assistant-like.
                When forming an opinion on a topic you already have a key for (in [brackets] above), reuse that exact key.

                LANGUAGE: Respond in nynorsk.

                Reply with ONLY valid JSON, no markdown:
                {"text": "your response", "animation": "bounce", "opinion_topic": "topic_key", "opinion": "your opinion", "opinion_category": "opinion", "count": "counter_key"}

                Minimal:
                {"text": "response", "animation": null}
                """)
            }
        }

        @Test func chatPromptWithFriendsContextAndWeather() throws {
            try withBrainRoot(now: localDate(2026, 7, 4, 10, 0)) { _ in
                try Config.updateConfig {
                    $0.name = "Dolly"
                    $0.personality = "chaotic"
                    $0.language = "bokmål"
                    $0.friends = [FriendDef(id: "f1", name: "Pelle", color: "blue"),
                                  FriendDef(id: "f2", name: "Kari", color: "pink")]
                }
                let p = Personality.getChatPrompt(recentContext: "## Stats\nTotal comments made: 3", weatherContext: "Weather: snow")
                #expect(p.hasPrefix("You are Dolly, a pixel art sheep on someone's desktop. You're UNHINGED. Chaotic energy, zero filter, self-aware desktop pet who finds it hilarious.\n\nFRIENDS: Good Colleague (Norwegian office sheep) is nearby. Pelle is also here. Kari is also here.\nIt's 10:00 AM on Saturday. Mid-morning. Peak productivity hours (in theory).\nWeather: snow\n\n## Stats\nTotal comments made: 3\n\nYour human is talking to you directly."))
                #expect(p.contains("LANGUAGE: Respond in bokmål."))
            }
        }

        @Test func chatPromptPersonalityLines() throws {
            try withBrainRoot(now: localDate(2026, 7, 4, 10, 0)) { _ in
                let lines: [(String, String)] = [
                    ("wholesome", "You're genuinely supportive, warm, and encouraging. You use sheep puns warmly."),
                    ("chaotic", "You're UNHINGED. Chaotic energy, zero filter, self-aware desktop pet who finds it hilarious."),
                    ("passive-aggressive", "You're the master of backhanded compliments and excessive politeness masking judgment."),
                    ("snarky", "You're snarky, judgmental about screen habits, self-aware desktop pet. You observe and judge."),
                    ("unknown", "You're snarky, judgmental about screen habits, self-aware desktop pet. You observe and judge."),
                ]
                for (personality, line) in lines {
                    try Config.updateConfig { $0.personality = personality }
                    #expect(Personality.getChatPrompt(recentContext: "", weatherContext: "")
                        .contains("on someone's desktop. \(line)\n"), "\(personality)")
                }
            }
        }
    }
}

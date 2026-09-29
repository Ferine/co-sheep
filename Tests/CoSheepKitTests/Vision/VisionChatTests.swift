import Foundation
import Testing
@testable import CoSheepKit

// chat_with_sheep and friend_chat. New tests; vision.rs had none.
extension BrainTests {
    @Suite("vision chat")
    struct VisionChatTests {
        // MARK: chat with history

        @Test func chatReplaysHistoryWithSheepTurnsWrappedAsJSON() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                let history = [
                    HistoryTurn(role: "human", text: "hi"),
                    HistoryTurn(role: "sheep", text: "Baaa, hello."),
                    HistoryTurn(role: "human", text: "how are you"),
                    HistoryTurn(role: "sheep", text: "Han sa \"baaa\""),
                ]

                let event = try await rig.pipeline.chatWithSheep("what now?", history: history)

                #expect(event == CommentaryEvent(text: "Baaa.", animation: nil))
                let call = try #require(rig.model.chatCalls.first)
                #expect(call.prompt == "what now?")
                #expect(call.history == [
                    HistoryTurn(role: "human", text: "hi"),
                    HistoryTurn(role: "sheep", text: #"{"animation":null,"text":"Baaa, hello."}"#),
                    HistoryTurn(role: "human", text: "how are you"),
                    HistoryTurn(role: "sheep", text: #"{"animation":null,"text":"Han sa \"baaa\""}"#),
                ])
                // The plain generate path is not used for chat
                #expect(rig.model.generateCalls.isEmpty)
            }
        }

        @Test func chatWithoutHistorySendsAnEmptyTranscript() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                _ = try await rig.pipeline.chatWithSheep("hello", history: [])
                #expect(rig.model.chatCalls.first?.history == [])
            }
        }

        @Test func chatUsesTheChatPromptNotTheCommentaryOne() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                _ = try await rig.pipeline.chatWithSheep("hello", history: [])
                let system = try #require(rig.model.chatCalls.first?.system)
                #expect(system.hasPrefix("You are Sheep, a pixel art sheep on someone's desktop."))
                #expect(system.contains("Your human is talking to you directly. Respond in character. Keep it short (1-3 sentences)."))
            }
        }

        @Test func chatDoesNotEmitCommentary() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.chatReply = #"{"text": "Baaa.", "animation": "spin"}"#

                let event = try await rig.pipeline.chatWithSheep("hello", history: [])

                // The chat bubble owns display; the reply is only returned.
                #expect(event == CommentaryEvent(text: "Baaa.", animation: .spin))
                #expect(rig.commentary.lines.isEmpty)
            }
        }

        @Test func chatJournalsTheExchangeAndCountsAnInteractionButNotAComment() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.chatReply = #"{"text": "Baaa.", "animation": "bounce"}"#

                _ = try await rig.pipeline.chatWithSheep("what now?", history: [])

                let journal = todaysJournal()
                #expect(journal.contains("*My human chatted with me!*"))
                #expect(journal.contains("Human said: \"what now?\"\n**Reply**: Baaa. [animation: Some(\"bounce\")]"))
                let brain = Memory.loadBrain()
                #expect(brain.totalInteractions == 1)
                #expect(brain.totalComments == 0)
            }
        }

        @Test func chatSavesOpinionsAndTallies() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.chatReply = #"{"text": "Hm.", "animation": null, "opinion_topic": "Small Talk", "opinion": "tolerable", "count": "chats"}"#

                _ = try await rig.pipeline.chatWithSheep("hello", history: [])

                let brain = Memory.loadBrain()
                #expect(brain.opinions.map(\.topic) == ["small_talk"])
                #expect(brain.opinions.first?.category == "opinion")
                #expect(brain.todayCounts == ["chats": 1])
            }
        }

        @Test func chatContextSurfacesRelevantOpinions() async throws {
            try await withBrainRoot { _ in
                try Memory.saveOpinion(topic: "tabs", opinion: "way too many tabs", category: "habit")
                let rig = VisionRig()

                _ = try await rig.pipeline.chatWithSheep("tabs?", history: [])

                let system = try #require(rig.model.chatCalls.first?.system)
                #expect(system.contains("- [tabs] way too many tabs (seen 1 times"))
            }
        }

        @Test func chatWeatherContextIsIncluded() async throws {
            try await withBrainRoot { _ in
                let weather = Weather(
                    location: { "Oslo" },
                    fetch: { _ in WeatherInfo(condition: "Rain", description: "Rain, 8C (feels like 6C), 90% humidity", tempC: 8) })
                let rig = VisionRig(weather: weather)
                _ = try await rig.pipeline.chatWithSheep("hello", history: [])
                #expect(rig.model.chatCalls.first?.system.contains("WEATHER: Rain, 8C (feels like 6C), 90% humidity outside.") == true)
            }
        }

        @Test func longMessagesAreCutToTheByteBudget() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                // 1500 two-byte letters = 3000 bytes; the budget keeps 2000 bytes = 1000 letters
                let message = String(repeating: "æ", count: 1500)

                _ = try await rig.pipeline.chatWithSheep(message, history: [])

                #expect(rig.model.chatCalls.first?.prompt == String(repeating: "æ", count: 1000))
                // the journal quotes what the model saw
                #expect(todaysJournal().contains("Human said: \"\(String(repeating: "æ", count: 1000))\""))
            }
        }

        @Test func historyTurnsAreNotTruncated() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                let long = String(repeating: "x", count: 5000)
                _ = try await rig.pipeline.chatWithSheep("hi", history: [HistoryTurn(role: "human", text: long)])
                #expect(rig.model.chatCalls.first?.history.first?.text == long)
            }
        }

        @Test func garbageChatReplyFallsBackToRawText() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.chatReply = "Baaa, eg er berre ein sau."
                let event = try await rig.pipeline.chatWithSheep("hello", history: [])
                #expect(event == CommentaryEvent(text: "Baaa, eg er berre ein sau.", animation: nil))
            }
        }

        @Test func modelFailureThrowsBeforeAnythingIsRecorded() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.chatFailure = LanguageModelError("generate: model unavailable")

                await #expect(throws: LanguageModelError.self) {
                    try await rig.pipeline.chatWithSheep("hello", history: [])
                }

                #expect(Memory.loadBrain().totalInteractions == 0)
                #expect(todaysJournal().isEmpty)
            }
        }

        // MARK: friend chat

        @Test func friendChatPromptNamesBothFriendsTheirLanguageAndMemories() async throws {
            try await withBrainRoot { _ in
                FriendMemory.ensureBrain("friend_a", "Fluffy")
                FriendMemory.ensureBrain("friend_b", "Woolly")
                FriendMemory.recordConversation("friend_a", "friend_b", "grass")
                try Config.updateConfig { $0.language = "german" }
                let rig = VisionRig()
                rig.model.commentary = #"[{"speaker": "Fluffy", "text": "Baa", "animation": null}]"#

                let raw = try await rig.pipeline.friendChat(
                    friendAId: "friend_a", friendAName: "Fluffy", friendAPersonality: "wholesome",
                    friendBId: "friend_b", friendBName: "Woolly", friendBPersonality: "chaotic",
                    topic: nil)

                #expect(raw == #"[{"speaker": "Fluffy", "text": "Baa", "animation": null}]"#)
                let call = try #require(rig.model.generateCalls.first)
                #expect(call.system == """
                You are writing a short conversation between two desktop sheep friends.
                Fluffy is wholesome. Woolly is chaotic.
                Write a 2-4 line exchange. Keep it SHORT, funny, and in character. They are pixel sheep living on someone's desktop.

                LANGUAGE: Write in german.

                Reply with ONLY a JSON array, no markdown:
                [{"speaker": "Fluffy", "text": "...", "animation": "bounce"}, {"speaker": "Woolly", "text": "...", "animation": null}]

                Valid animations: "bounce", "spin", "headshake", "vibrate", "zoom", null

                WHAT THEY KNOW:
                Fluffy is happy and is neutral toward Woolly. Remembers: Talked with Woolly about grass.
                Woolly is happy and is neutral toward Fluffy. Remembers: Talked with Fluffy about grass.
                Let their history color the exchange subtly — a callback, a grudge, warmth. Don't recite it.
                """)
                #expect(call.prompt == "Generate a conversation between Fluffy and Woolly.")
                // friend chat is not a sheep comment
                #expect(rig.commentary.lines.isEmpty)
            }
        }

        @Test func friendChatWithATopicAddsItAsContext() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                _ = try await rig.pipeline.friendChat(
                    friendAId: "a", friendAName: "Fluffy", friendAPersonality: "snarky",
                    friendBId: "b", friendBName: "Woolly", friendBPersonality: "snarky",
                    topic: "a wolf appeared")
                #expect(rig.model.generateCalls.first?.prompt
                    == "Generate a conversation between Fluffy and Woolly. Context: a wolf appeared")
            }
        }

        @Test func friendChatFailurePropagates() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.generateFailure = LanguageModelError("generate: boom")
                await #expect(throws: LanguageModelError.self) {
                    try await rig.pipeline.friendChat(
                        friendAId: "a", friendAName: "A", friendAPersonality: "snarky",
                        friendBId: "b", friendBName: "B", friendBPersonality: "snarky", topic: nil)
                }
            }
        }
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

// run_vision_pipeline and generation, driven by a fake model and a fake
// screen. vision.rs had no tests for these; every one is new. They write the
// brain and journal, so they live under the serialized `BrainTests` root with
// a temp `Paths.root`.
extension BrainTests {
    @Suite("vision pipeline")
    struct VisionPipelineTests {
        private let summary = "Rust compile errors in a terminal"

        // MARK: an interesting screen

        @Test func interestingScreenGetsACommentAndAnimation() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.ocrText = "error[E0308]: mismatched types"
                rig.model.commentary = #"{"text": "Fancy router, mate.", "animation": "spin", "opinion_topic": "Router Talk", "opinion": "obsessed", "opinion_category": "habit", "count": "router_visits"}"#

                try await rig.pipeline.runVisionPipeline()

                #expect(rig.commentary.lines == [CommentaryEvent(text: "Fancy router, mate.", animation: .spin)])
                #expect(rig.screen.captureCount == 1)
                #expect(rig.model.ocrCalls == 1)

                // Brain side effects: opinion (topic canonicalized), tally, comment count
                let brain = Memory.loadBrain()
                #expect(brain.opinions.map(\.topic) == ["router_talk"])
                #expect(brain.opinions.first?.opinion == "obsessed")
                #expect(brain.opinions.first?.category == "habit")
                #expect(brain.todayCounts == ["router_visits": 1])
                #expect(brain.totalComments == 1)

                // The diary keeps the classification and the line, `{:?}`-style
                #expect(todaysJournal().contains(
                    "\(summary)\n**Comment**: Fancy router, mate. [animation: Some(\"spin\")]"))
            }
        }

        @Test func bothPassesGetTheirVerbatimPrompts() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.ocrText = "some screen text"

                try await rig.pipeline.runVisionPipeline()

                let calls = rig.model.generateCalls
                #expect(calls.count == 2)
                #expect(calls[0].system == VisionPipeline.CLASSIFY_SYSTEM)
                #expect(calls[0].prompt == "Screen text:\nsome screen text\n\n\(VisionPipeline.CLASSIFY_PROMPT)")
                #expect(calls[1].system.hasPrefix("You are Sheep, a pixel art sheep that lives on someone's desktop."))
                #expect(calls[1].prompt == "Context: \(summary)\n\nText visible on the screen (OCR):\nsome screen text\n\n\(VisionPipeline.COMMENTARY_PROMPT)")
            }
        }

        @Test func commentaryIsTheOnlyEmissionAndCarriesNoAnimationWhenNull() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.commentary = #"{"text": "Hmm.", "animation": null}"#
                try await rig.pipeline.runVisionPipeline()
                #expect(rig.commentary.lines == [CommentaryEvent(text: "Hmm.", animation: nil)])
                #expect(todaysJournal().contains("**Comment**: Hmm. [animation: None]"))
            }
        }

        @Test func opinionWithoutACategoryDefaultsToOpinion() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.commentary = #"{"text": "x", "opinion_topic": "tabs", "opinion": "too many"}"#
                try await rig.pipeline.runVisionPipeline()
                #expect(Memory.loadBrain().opinions.first?.category == "opinion")
            }
        }

        @Test func opinionNeedsBothTopicAndText() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.commentary = #"{"text": "x", "opinion_topic": "tabs"}"#
                try await rig.pipeline.runVisionPipeline()
                #expect(Memory.loadBrain().opinions.isEmpty)
            }
        }

        @Test func aNumericCountStillBumpsTheTally() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.commentary = #"{"text": "x", "count": 3}"#
                try await rig.pipeline.runVisionPipeline()
                #expect(Memory.loadBrain().todayCounts == ["3": 1])
            }
        }

        @Test func earlierOpinionsReachTheNextCommentaryPrompt() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.commentary = #"{"text": "x", "opinion_topic": "routers", "opinion": "too many routers"}"#
                try await rig.pipeline.runVisionPipeline()
                try await rig.pipeline.runVisionPipeline()

                let secondCommentarySystem = rig.model.generateCalls[3].system
                #expect(secondCommentarySystem.contains("Recent diary entries:"))
                #expect(secondCommentarySystem.contains("- [routers] too many routers (seen 1 times"))
            }
        }

        @Test func weatherContextReachesTheCommentaryPrompt() async throws {
            try await withBrainRoot { _ in
                let weather = Weather(
                    location: { "Oslo" },
                    fetch: { _ in WeatherInfo(condition: "Clear", description: "Clear, 15C (feels like 14C), 50% humidity", tempC: 15) })
                let rig = VisionRig(weather: weather)
                try await rig.pipeline.runVisionPipeline()
                #expect(rig.model.generateCalls[1].system.contains("WEATHER: Clear, 15C (feels like 14C), 50% humidity outside."))
            }
        }

        @Test func ocrTextIsCutToTheByteBudgetInBothPrompts() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                // 3000 two-byte letters = 6000 bytes; the budget keeps 4000 bytes = 2000 letters
                rig.model.ocrText = String(repeating: "å", count: 3000)
                try await rig.pipeline.runVisionPipeline()
                for call in rig.model.generateCalls {
                    #expect(call.prompt.filter { $0 == "å" }.count == 2000)
                }
            }
        }

        // MARK: a boring screen

        @Test func boringScreenGetsNoCommentButADiaryLine() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.classification = #"{"interesting": false, "category": "idle", "summary": "An idle desktop"}"#

                try await rig.pipeline.runVisionPipeline()

                #expect(rig.commentary.lines.isEmpty)
                #expect(rig.model.generateCalls.count == 1) // pass 2 never ran
                #expect(Memory.loadBrain().totalComments == 0)
                #expect(todaysJournal().contains("Glanced at screen. An idle desktop. Nothing worth commenting on."))
            }
        }

        // MARK: garbage and failures

        @Test func garbageClassificationThrowsAndEmitsNothing() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.classification = "I think it is a lovely desktop, truly"

                await #expect(throws: VisionError.self) { try await rig.pipeline.runVisionPipeline() }

                #expect(rig.commentary.lines.isEmpty)
                #expect(rig.model.generateCalls.count == 1)
                #expect(Memory.loadBrain().totalComments == 0)
            }
        }

        @Test func garbageCommentaryFallsBackToTheRawText() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.commentary = "  Baaa, eg er berre ein sau.\n"

                try await rig.pipeline.runVisionPipeline()

                #expect(rig.commentary.lines == [CommentaryEvent(text: "Baaa, eg er berre ein sau.", animation: nil)])
                #expect(Memory.loadBrain().totalComments == 1)
            }
        }

        @Test func truncatedCommentaryIsSalvaged() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.commentary = #"{"text": "Du har ein skikkeleg fancy rout"#
                try await rig.pipeline.runVisionPipeline()
                #expect(rig.commentary.texts == ["Du har ein skikkeleg fancy rout…"])
            }
        }

        @Test func fencedClassificationStillParses() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.classification = "```json\n{\"interesting\": false, \"category\": \"idle\", \"summary\": \"Desktop\"}\n```"
                try await rig.pipeline.runVisionPipeline()
                #expect(rig.commentary.lines.isEmpty)
                #expect(rig.model.generateCalls.count == 1)
            }
        }

        @Test func captureFailurePropagatesBeforeAnyModelCall() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig()
                rig.screen.captureHook = { _ in throw PlatformError("No monitor found") }

                await #expect(throws: PlatformError("No monitor found")) { try await rig.pipeline.runVisionPipeline() }

                #expect(rig.model.ocrCalls == 0)
                #expect(rig.model.generateCalls.isEmpty)
                #expect(!rig.pipeline.isTickRunning)
            }
        }

        @Test func ocrFailurePropagates() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.ocrFailure = LanguageModelError("ocr: boom")

                await #expect(throws: LanguageModelError.self) { try await rig.pipeline.runVisionPipeline() }

                #expect(rig.model.generateCalls.isEmpty)
                #expect(!rig.pipeline.isTickRunning)
            }
        }

        @Test func modelFailureInPassTwoPropagatesWithoutEmitting() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig()
                // Pass 1 answers, then the model goes away.
                let pipeline = VisionPipeline(
                    model: FailAfterFirstGenerate(inner: rig.model), screen: rig.screen.access,
                    events: rig.commentary.events, weather: Weather(location: { "" }))

                await #expect(throws: LanguageModelError.self) { try await pipeline.runVisionPipeline() }

                #expect(rig.model.generateCalls.count == 1)
                #expect(rig.commentary.lines.isEmpty)
                #expect(Memory.loadBrain().totalComments == 0)
                #expect(!pipeline.isTickRunning)
            }
        }

        @Test func missingPreflightPermissionStillCaptures() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                rig.screen.permitted = false
                try await rig.pipeline.runVisionPipeline()
                // Preflight is only logged; the real capture is the test. Only the
                // prerequisites check asks for the dialog.
                #expect(rig.screen.captureCount == 1)
                #expect(rig.screen.permissionRequests == 0)
                #expect(rig.commentary.lines.count == 1)
            }
        }

        // MARK: the tick flag

        @Test func tickFlagIsSetDuringARunAndClearedAfter() async throws {
            try await withBrainRoot { _ in
                let rig = VisionRig()
                var during: [Bool] = []
                rig.model.onOCR = { during.append(rig.pipeline.isTickRunning) }

                #expect(!rig.pipeline.isTickRunning)
                try await rig.pipeline.runVisionPipeline()

                #expect(during == [true])
                #expect(!rig.pipeline.isTickRunning)
            }
        }

        @Test func tickFlagIsClearedWhenARunThrows() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig()
                var during: [Bool] = []
                rig.model.onOCR = { during.append(rig.pipeline.isTickRunning) }
                rig.model.classification = "not json"

                await #expect(throws: VisionError.self) { try await rig.pipeline.runVisionPipeline() }

                #expect(during == [true])
                #expect(!rig.pipeline.isTickRunning)
            }
        }
    }
}

/// Answers the first `generate` from the inner model and throws on the rest.
private final class FailAfterFirstGenerate: LanguageModel {
    let inner: ScriptedModel
    private var calls = 0
    init(inner: ScriptedModel) { self.inner = inner }

    func unavailableReason() -> String? { inner.unavailableReason() }
    func generate(system: String, prompt: String) async throws -> String {
        calls += 1
        if calls > 1 { throw LanguageModelError("generate: model went away") }
        return try await inner.generate(system: system, prompt: prompt)
    }
    func generateChat(system: String, prompt: String, history: [HistoryTurn]) async throws -> String {
        try await inner.generateChat(system: system, prompt: prompt, history: history)
    }
    func ocr(_ image: CGImage) async throws -> String { try await inner.ocr(image) }
}

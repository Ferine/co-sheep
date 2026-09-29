import Foundation
import Testing
@testable import CoSheepKit

// vision_loop and check_prerequisites: startup delay, prerequisite retries,
// pause flag, error surfacing and pacing. The loop's waits are injected, so
// `run()` executes instantly and ends when the fake sleeper throws (what a
// cancelled `Task.sleep` does). New tests; vision.rs had none.
extension BrainTests {
    @Suite("vision loop")
    struct VisionLoopTests {
        // MARK: startup and pacing

        @Test func waitsForTheUIThenChecksThenPacesByTheConfiguredInterval() async throws {
            try await withBrainRoot { _ in
                try Config.updateConfig { $0.intervalSecs = 100 }
                let rig = VisionRig(sleepLimit: 2)

                await rig.pipeline.run()

                // 8 s for the UI, then the interval minus 20% (jitter nanos pinned to 0)
                #expect(rig.sleeps.calls == [8, 80])
                #expect(rig.commentary.texts == ["Baaa."])
                // one capture for the prerequisites check, one for the pipeline tick
                #expect(rig.screen.captureCount == 2)
            }
        }

        @Test func defaultIntervalIs150SecondsWithoutAConfig() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig(sleepLimit: 2)
                await rig.pipeline.run()
                #expect(rig.sleeps.calls == [8, 120])
            }
        }

        @Test func intervalIsRereadEveryIteration() async throws {
            try await withBrainRoot { _ in
                try Config.updateConfig { $0.intervalSecs = 100 }
                let rig = VisionRig(sleepLimit: 3)
                rig.sleeps.onCall = { n in
                    if n == 2 { _ = try? Config.updateConfig { $0.intervalSecs = 200 } }
                }
                await rig.pipeline.run()
                #expect(rig.sleeps.calls == [8, 80, 160])
            }
        }

        @Test func jitterComesFromTheInjectedNanos() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig(sleepLimit: 2, nanos: 60) // base 150: 120 + 60 % 61
                await rig.pipeline.run()
                #expect(rig.sleeps.calls == [8, 180])
            }
        }

        @Test func aNegativeIntervalClampsInsteadOfTrapping() async throws {
            try await withBrainRoot { _ in
                try Config.updateConfig { $0.intervalSecs = -5 }
                let rig = VisionRig(sleepLimit: 2)
                await rig.pipeline.run()
                #expect(rig.sleeps.calls == [8, 0])
            }
        }

        @Test func endsWhenTheStartupWaitIsCancelled() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig(sleepLimit: 1)
                await rig.pipeline.run()
                #expect(rig.sleeps.calls == [8])
                #expect(rig.screen.captureCount == 0)
                #expect(rig.commentary.lines.isEmpty)
            }
        }

        // MARK: prerequisites

        @Test func retriesEveryThirtySecondsUntilTheModelIsReady() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig(sleepLimit: 4)
                rig.model.reason = "modelNotReady"
                rig.sleeps.onCall = { n in
                    if n == 3 { rig.model.reason = nil }
                }

                await rig.pipeline.run()

                #expect(rig.sleeps.calls == [8, 30, 30, 120])
                let downloading = "Apple Intelligence is still downloading its model... I'll keep checking. Baa-tience."
                // Rust emitted the line on every failed check, then the first real comment
                #expect(rig.commentary.texts == [downloading, downloading, "Baaa."])
                #expect(rig.screen.captureCount == 2)
            }
        }

        @Test func retriesWhenTheTestCaptureFails() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig(sleepLimit: 3)
                // The first capture (the test capture) fails, the rest succeed.
                rig.screen.captureHook = { n in if n == 1 { throw PlatformError("no access") } }

                await rig.pipeline.run()

                #expect(rig.sleeps.calls == [8, 30, 120])
                #expect(rig.commentary.texts == [
                    "I can't capture your screen! Add me to System Settings > Privacy & Security > Screen Recording, then restart me.",
                    "Baaa.",
                ])
            }
        }

        @Test(arguments: [
            ("appleIntelligenceNotEnabled",
             "Apple Intelligence is turned off! Enable it in System Settings > Apple Intelligence & Siri, then I can think locally."),
            ("modelNotReady",
             "Apple Intelligence is still downloading its model... I'll keep checking. Baa-tience."),
            ("deviceNotEligible",
             "This Mac can't run Apple Intelligence — I need Apple Silicon and macOS 26 to think. Sorry!"),
            ("requiresMacOS26",
             "This Mac can't run Apple Intelligence — I need Apple Silicon and macOS 26 to think. Sorry!"),
            ("somethingNew",
             "I can't reach the on-device Apple Intelligence model. Check System Settings > Apple Intelligence & Siri."),
        ])
        func unavailableModelReasonsGetTheirOwnLine(reason: String, line: String) async throws {
            await withBrainRoot { _ in
                let rig = VisionRig()
                rig.model.reason = reason

                let failure = await rig.pipeline.checkPrerequisites()

                #expect(failure == "apple intelligence: \(reason)")
                #expect(rig.commentary.texts == [line])
                #expect(rig.commentary.lines.first?.animation == nil)
                // the model check comes first: no permission request, no capture
                #expect(rig.screen.captureCount == 0)
                #expect(rig.screen.permissionRequests == 0)
            }
        }

        @Test func failedTestCaptureReportsTheReasonAndTheScreenRecordingLine() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig()
                rig.screen.captureHook = { _ in throw PlatformError("no access") }

                let failure = await rig.pipeline.checkPrerequisites()

                #expect(failure == "capture: no access")
                #expect(rig.commentary.texts == [
                    "I can't capture your screen! Add me to System Settings > Privacy & Security > Screen Recording, then restart me.",
                ])
            }
        }

        @Test func missingPermissionIsRequestedButTheTestCaptureStillRuns() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig()
                rig.screen.permitted = false

                let failure = await rig.pipeline.checkPrerequisites()

                #expect(failure == nil)
                #expect(rig.screen.permissionRequests == 1)
                #expect(rig.screen.captureCount == 1)
                #expect(rig.commentary.lines.isEmpty)
            }
        }

        @Test func grantedPermissionIsNotRequested() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig()
                let failure = await rig.pipeline.checkPrerequisites()
                #expect(failure == nil)
                #expect(rig.screen.permissionRequests == 0)
            }
        }

        // MARK: the pause flag

        @Test func pausedLoopSkipsThePipeline() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig(sleepLimit: 3)
                rig.pipeline.isPaused = true

                await rig.pipeline.run()

                #expect(rig.sleeps.calls == [8, 120, 120])
                #expect(rig.model.ocrCalls == 0)
                #expect(rig.commentary.lines.isEmpty)
                // only the prerequisites' test capture happened
                #expect(rig.screen.captureCount == 1)
            }
        }

        @Test func unpausingResumesCommentary() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig(sleepLimit: 3)
                rig.pipeline.isPaused = true
                rig.sleeps.onCall = { n in
                    if n == 2 { rig.pipeline.isPaused = false }
                }

                await rig.pipeline.run()

                #expect(rig.model.ocrCalls == 1)
                #expect(rig.commentary.texts == ["Baaa."])
            }
        }

        // MARK: error surfacing

        @Test(arguments: [
            ("Failed to capture image", true),
            ("permission denied", true),
            ("the screen is gone", true),
            ("boom", false),
        ])
        func pipelineErrorsMentioningScreenCaptureOrPermissionAreSurfaced(message: String, surfaced: Bool) async throws {
            await withBrainRoot { _ in
                let rig = VisionRig(sleepLimit: 2)
                rig.model.ocrFailure = LanguageModelError(message)

                await rig.pipeline.run()

                #expect(rig.commentary.texts == (surfaced ? [VisionPipeline.SCREEN_ERROR_LINE] : []))
                #expect(!rig.pipeline.isTickRunning)
            }
        }

        @Test func surfacedLineIsTheVerbatimScreenRecordingHint() {
            #expect(VisionPipeline.SCREEN_ERROR_LINE
                == "I tried to look at your screen but something went wrong. Check that screen recording is enabled for co-sheep in System Settings > Privacy & Security > Screen Recording.")
        }

        @Test func theLoopSurvivesAFailedTick() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig(sleepLimit: 3)
                // capture #1 = prerequisites, #2 = first tick (fails), #3 = second tick
                rig.screen.captureHook = { n in if n == 2 { throw PlatformError("Failed to capture screen") } }

                await rig.pipeline.run()

                #expect(rig.sleeps.calls == [8, 120, 120])
                #expect(rig.commentary.texts == [VisionPipeline.SCREEN_ERROR_LINE, "Baaa."])
            }
        }

        @Test func aClassificationParseErrorEchoingTheWordScreenIsSurfacedToo() async throws {
            // Ported as-is: the parse error quotes the model's raw reply, and the
            // loop's substring check cannot tell that "screen" came from the model.
            await withBrainRoot { _ in
                let rig = VisionRig(sleepLimit: 2)
                rig.model.classification = "Nice screen you have there"

                await rig.pipeline.run()

                #expect(rig.commentary.texts == [VisionPipeline.SCREEN_ERROR_LINE])
            }
        }

        @Test func aGarbledClassificationWithoutTheKeywordsStaysQuiet() async throws {
            await withBrainRoot { _ in
                let rig = VisionRig(sleepLimit: 2)
                rig.model.classification = "Lovely desktop"
                await rig.pipeline.run()
                #expect(rig.commentary.lines.isEmpty)
            }
        }

        // MARK: the Task

        @Test func startIsIdempotentAndStopCancelsTheLoop() async throws {
            try await withBrainRoot { _ in
                let cancelled = CancelFlag()
                let pipeline = VisionPipeline(
                    model: ScriptedModel(), screen: ScreenRecorder().access, events: AppEvents(),
                    weather: Weather(location: { "" }),
                    sleep: { _ in
                        do { try await Task.sleep(for: .seconds(3600)) } catch {
                            cancelled.value = true
                            throw error
                        }
                    })
                #expect(!pipeline.isRunning)
                pipeline.start()
                pipeline.start()
                #expect(pipeline.isRunning)

                // let the loop reach its startup wait, then stop it
                try await Task.sleep(for: .milliseconds(20))
                pipeline.stop()
                #expect(!pipeline.isRunning)

                for _ in 0..<200 where !cancelled.value { try await Task.sleep(for: .milliseconds(10)) }
                #expect(cancelled.value)
            }
        }

        private final class CancelFlag {
            var value = false
        }
    }
}

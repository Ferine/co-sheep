import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CoSheepKit

// The overlay-facing commands and startup of lib.rs. lib.rs had no tests, so
// all of these are new. Everything runs against a temp `Paths.root` with the
// "Desktop" inside it, a fake model and a fake screen: nothing touches the real
// ~/.co-sheep, the real Desktop, ScreenCaptureKit or a permission dialog.

/// A controller wired to the fakes, with its Desktop at `<root>/Desktop`.
final class ControllerRig {
    let model = ScriptedModel()
    let screen = ScreenRecorder()
    let commentary = CommentaryLog()
    let desktop: URL
    let weather: Weather
    let pipeline: VisionPipeline
    let watch: AppWatch
    let mcp: MCPServer
    let controller: AppController

    init(root: URL, weather: Weather? = nil, createDesktop: Bool = true) {
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        if createDesktop { try? FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true) }
        self.desktop = desktop
        let weather = weather ?? Weather(location: { "" })
        self.weather = weather
        let events = commentary.events
        // The loop's first wait never ends before `stop()`, so `start()` in a test never captures.
        pipeline = VisionPipeline(
            model: model, screen: screen.access, events: events, weather: weather,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        watch = AppWatch(pollInterval: 3600, events: events, frontmostAppName: { _ in nil })
        mcp = MCPServer(store: SessionStore(events: events), events: events)
        controller = AppController(
            model: model, screen: screen.access, events: events, weather: weather,
            vision: pipeline, appWatch: watch, mcpServer: mcp, desktopDirectory: desktop)
    }
}

extension BrainTests {
    @Suite("app controller")
    struct AppControllerTests {
        // MARK: simple checks

        @Test func checkOnboardingFollowsTheConfigFile() throws {
            try withBrainRoot { root in
                let rig = ControllerRig(root: root)
                #expect(rig.controller.checkOnboarding() == true)
                try Config.updateConfig { $0.name = "Dolly" }
                #expect(rig.controller.checkOnboarding() == false)
            }
        }

        @Test func checkAiReadyMirrorsTheModelAvailability() {
            withBrainRoot { root in
                let rig = ControllerRig(root: root)
                #expect(rig.controller.checkAiReady() == true)
                rig.model.reason = "modelNotReady"
                #expect(rig.controller.checkAiReady() == false)
            }
        }

        @Test func checkScreenPermissionReadsThePreflight() {
            withBrainRoot { root in
                let rig = ControllerRig(root: root)
                #expect(rig.controller.checkScreenPermission() == true)
                rig.screen.permitted = false
                #expect(rig.controller.checkScreenPermission() == false)
                #expect(rig.screen.permissionRequests == 0) // checking never prompts
            }
        }

        // MARK: recording

        @Test func recordInteractionCountsAndJournals() {
            withBrainRoot { root in
                let rig = ControllerRig(root: root)
                rig.controller.recordInteraction("petted main")
                #expect(Memory.loadBrain().totalInteractions == 1)
                #expect(todaysJournal().contains("*My human petted main me!*"))
            }
        }

        @Test func recordAppUsageBumpsAPerCategoryTallyAndReturnsIt() {
            withBrainRoot { root in
                let rig = ControllerRig(root: root)
                #expect(rig.controller.recordAppUsage("coding") == 1)
                #expect(rig.controller.recordAppUsage("coding") == 2)
                #expect(rig.controller.recordAppUsage("social") == 1)
                #expect(Memory.loadBrain().todayCounts == ["app:coding": 2, "app:social": 1])
            }
        }

        @Test func livingStateRoundTripsAndRejectsBadNames() throws {
            withBrainRoot { root in
                let rig = ControllerRig(root: root)
                #expect(rig.controller.getLivingState("spectacles") == .null)

                let value = JSONValue.object(["next": .number(12), "kinds": .array([.string("wolf")])])
                rig.controller.saveLivingState("spectacles", value)
                #expect(rig.controller.getLivingState("spectacles") == value)
                #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("spectacles.json").path))

                rig.controller.saveLivingState("../evil", value)
                #expect(rig.controller.getLivingState("../evil") == .null)
                #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("evil.json").path))
            }
        }

        @Test func friendPetsAndMoods() {
            withBrainRoot { root in
                let rig = ControllerRig(root: root)
                FriendMemory.ensureBrain("good_colleague", "Good Colleague")
                #expect(rig.controller.getFriendMoods() == ["good_colleague": "grumpy"])

                rig.controller.recordFriendPet("good_colleague")

                #expect(rig.controller.getFriendMoods() == ["good_colleague": "happy"])
                #expect(FriendMemory.getFriendBrain("good_colleague").stats.timesPetted == 1)
            }
        }

        @Test func flockBookkeepingReachesFriendMemory() {
            withBrainRoot { root in
                let rig = ControllerRig(root: root)
                FriendMemory.ensureBrain("a", "Fluffy")
                FriendMemory.ensureBrain("b", "Woolly")

                rig.controller.recordFriendConversation(idA: "a", idB: "b", topic: "grass")
                #expect(FriendMemory.getFriendBrain("a").stats.conversationsTotal == 1)
                #expect(FriendMemory.getFriendBrain("b").relationships["a"] == 1)

                rig.controller.recordGroupActivity(participants: ["a", "b"], activityType: "campfire")
                #expect(FriendMemory.getFriendBrain("a").stats.groupActivities == 1)
                #expect(FriendMemory.getFriendBrain("a").memories.last?.text == "Joined a campfire with Woolly")
            }
        }

        @Test func recordSpectacleWritesMemoriesAndADiaryLine() {
            withBrainRoot { root in
                let rig = ControllerRig(root: root)
                FriendMemory.ensureBrain("a", "Fluffy")
                FriendMemory.ensureBrain("b", "Woolly")

                rig.controller.recordSpectacle(kind: "wolf attack", participants: ["a", "b"])

                #expect(FriendMemory.getFriendBrain("a").memories.last?.text == "Joined a wolf attack with Woolly")
                #expect(todaysJournal().contains("*A wolf attack happened on the desktop! The flock is still talking about it.*"))
            }
        }

        @Test func easterHuntsAccumulateInTheScoreboard() {
            withBrainRoot { root in
                let rig = ControllerRig(root: root)
                #expect(rig.controller.getEasterStats().huntsToday == 0)

                let stats = rig.controller.recordEasterHunt(EasterHuntResult(
                    totalEggs: 5, durationMs: 9000, allCollected: true, paintedEggsUsed: 1,
                    hunters: [
                        EasterHunterResult(id: "main", name: "Sheep", eggsFound: 3, goldenEggsFound: 1),
                        EasterHunterResult(id: "a", name: "Fluffy", eggsFound: 2),
                    ]))

                #expect(stats.eggsFoundTotal == 5)
                #expect(stats.huntsCompleted == 1)
                #expect(stats.topHunterId == "main")
                #expect(rig.controller.getEasterStats() == stats)
            }
        }

        // MARK: pause and comment now

        @Test func togglePauseFlipsTheFlagTheLoopReads() {
            withBrainRoot { root in
                let rig = ControllerRig(root: root)
                #expect(!rig.controller.isPaused)
                rig.controller.togglePause()
                #expect(rig.controller.isPaused)
                #expect(rig.pipeline.isPaused)
                rig.controller.togglePause()
                #expect(!rig.controller.isPaused)
                #expect(!rig.pipeline.isPaused)
            }
        }

        @Test func commentNowRunsThePipelineEvenWhilePaused() async throws {
            await withBrainRoot { root in
                let rig = ControllerRig(root: root)
                rig.controller.togglePause()

                rig.controller.commentNow()
                await rig.controller.commentNowTask?.value

                #expect(rig.commentary.lines == [CommentaryEvent(text: "Baaa.", animation: .bounce)])
                #expect(rig.screen.captureCount == 1)
            }
        }

        @Test func aFailedCommentNowIsLoggedNotShown() async throws {
            await withBrainRoot { root in
                let rig = ControllerRig(root: root)
                rig.screen.captureHook = { _ in throw PlatformError("Failed to capture screen") }

                rig.controller.commentNow()
                await rig.controller.commentNowTask?.value

                #expect(rig.commentary.lines.isEmpty)
                #expect(!rig.pipeline.isTickRunning)
            }
        }

        // MARK: chat

        @Test func chatWithSheepPassesTheReplyThrough() async throws {
            try await withBrainRoot { root in
                let rig = ControllerRig(root: root)
                rig.model.chatReply = #"{"text": "Baaa.", "animation": "headshake"}"#
                let history = [HistoryTurn(role: "human", text: "hi"), HistoryTurn(role: "sheep", text: "hello")]

                let event = try await rig.controller.chatWithSheep(message: "how goes", history: history)

                #expect(event == CommentaryEvent(text: "Baaa.", animation: .headshake))
                #expect(rig.model.chatCalls.first?.prompt == "how goes")
                #expect(rig.model.chatCalls.first?.history.count == 2)
                #expect(rig.commentary.lines.isEmpty)
            }
        }

        @Test(arguments: [
            ("nynorsk", "Bæææ... hjernen min verkar ikkje akkurat no. Prøv igjen?"),
            ("bokmål", "Bæææ... hjernen min virker ikke akkurat nå. Prøv igjen?"),
            ("swedish", "Bäää... min hjärna funkar inte just nu. Försök igen?"),
            ("danish", "Bæææ... min hjerne virker ikke lige nu. Prøv igen?"),
            ("german", "Määä... mein Gehirn funktioniert gerade nicht. Versuch's nochmal?"),
            ("french", "Bêêê... mon cerveau ne marche pas là. Réessaie ?"),
            ("spanish", "Beee... mi cerebro no funciona ahora. ¿Intentas de nuevo?"),
            ("japanese", "メェェ…今、頭が働かないの。もう一度試して？"),
            ("korean", "메에에... 지금 머리가 안 돌아가요. 다시 해볼래요?"),
            ("klingon", "Baaaa... my brain isn't working right now. Try again?"),
            ("English", "Baaaa... my brain isn't working right now. Try again?"),
        ])
        func aFailedChatSaysSoInTheSheepsLanguage(language: String, line: String) async throws {
            try await withBrainRoot { root in
                try Config.updateConfig { $0.language = language }
                let rig = ControllerRig(root: root)
                rig.model.chatFailure = LanguageModelError("generate: model unavailable")

                do {
                    _ = try await rig.controller.chatWithSheep(message: "hi", history: [])
                    Issue.record("expected a throw")
                } catch let error as AppControllerError {
                    #expect(error.message == line)
                    // the overlay shows localizedDescription
                    #expect(error.localizedDescription == line)
                }
            }
        }

        @Test func languageNamesMatchCaseInsensitively() {
            #expect(AppController.chatFailureLine(language: "Nynorsk") == AppController.chatFailureLine(language: "nynorsk"))
            #expect(AppController.chatFailureLine(language: "BOKMÅL").hasPrefix("Bæææ... hjernen min virker"))
            #expect(AppController.chatFailureLine(language: "") == "Baaaa... my brain isn't working right now. Try again?")
        }

        @Test func friendAIChatPassesTheRawReplyThrough() async throws {
            try await withBrainRoot { root in
                let rig = ControllerRig(root: root)
                rig.model.commentary = #"[{"speaker": "Fluffy", "text": "Baa", "animation": null}]"#

                let raw = try await rig.controller.friendAIChat(
                    "a", "Fluffy", "wholesome", "b", "Woolly", "chaotic", topic: "a wolf")

                #expect(raw == #"[{"speaker": "Fluffy", "text": "Baa", "animation": null}]"#)
                #expect(rig.model.generateCalls.first?.prompt
                    == "Generate a conversation between Fluffy and Woolly. Context: a wolf")
                #expect(rig.model.generateCalls.first?.system.contains("Fluffy is wholesome. Woolly is chaotic.") == true)
            }
        }

        @Test func friendAIChatErrorsCarryTheModelsMessage() async throws {
            try await withBrainRoot { root in
                let rig = ControllerRig(root: root)
                rig.model.generateFailure = LanguageModelError("generate: boom")

                do {
                    _ = try await rig.controller.friendAIChat("a", "A", "snarky", "b", "B", "snarky", topic: nil)
                    Issue.record("expected a throw")
                } catch let error as AppControllerError {
                    #expect(error.message == "generate: boom")
                }
            }
        }

        // MARK: save_moment

        @Test func saveMomentWritesAPNGToTheDesktopWithTheTimestampName() async throws {
            let now = localDate(2026, 9, 29, 14, 30)
            try await withBrainRoot(now: now) { root in
                let rig = ControllerRig(root: root)
                let image = visionTestImage(width: 12, height: 7)

                let path = try await rig.controller.saveMoment(image)

                let ts = Int(now.timeIntervalSince1970)
                let expected = rig.desktop.appendingPathComponent("co-sheep-moment-\(ts).png")
                #expect(path == expected.path)

                let data = try Data(contentsOf: expected)
                #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47]) // PNG signature
                let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
                let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                #expect(decoded.width == 12)
                #expect(decoded.height == 7)
            }
        }

        @Test func saveMomentFailureIsAWriteError() async throws {
            try await withBrainRoot { root in
                let rig = ControllerRig(root: root, createDesktop: false)
                do {
                    _ = try await rig.controller.saveMoment(visionTestImage())
                    Issue.record("expected a throw")
                } catch let error as AppControllerError {
                    #expect(error.message.hasPrefix("Write error: "))
                }
            }
        }

        // MARK: debug capture

        @Test func debugCaptureSavesToTheDesktopAndSaysSo() async throws {
            try await withBrainRoot { root in
                let rig = ControllerRig(root: root)
                rig.screen.debugResult = .success("/Users/x/Desktop/co-sheep-debug-capture.png")

                let path = try await rig.controller.debugCapture()

                #expect(path == "/Users/x/Desktop/co-sheep-debug-capture.png")
                #expect(rig.screen.debugDirectories == [rig.desktop])
                #expect(rig.commentary.lines == [CommentaryEvent(
                    text: "Saved what I see to your Desktop! Check co-sheep-debug-capture.png", animation: nil)])
            }
        }

        @Test func debugCaptureFailureIsShownAndThrown() async throws {
            try await withBrainRoot { root in
                let rig = ControllerRig(root: root)
                rig.screen.debugResult = .failure(PlatformError("No monitor found"))

                do {
                    _ = try await rig.controller.debugCapture()
                    Issue.record("expected a throw")
                } catch let error as AppControllerError {
                    #expect(error.message == "Capture failed: No monitor found")
                }
                #expect(rig.commentary.texts == ["Capture failed: No monitor found"])
            }
        }

        @Test func theMenuDebugCaptureSwallowsTheFailure() async throws {
            await withBrainRoot { root in
                let rig = ControllerRig(root: root)
                rig.screen.debugResult = .failure(PlatformError("boom"))

                rig.controller.debugCaptureFromMenu()
                await rig.controller.debugCaptureTask?.value

                #expect(rig.commentary.texts == ["Capture failed: boom"])
            }
        }

        // MARK: weather and windows

        @Test func weatherSnapshotComesFromTheInjectedWeather() async throws {
            await withBrainRoot { root in
                let weather = Weather(
                    location: { "Oslo" },
                    fetch: { _ in WeatherInfo(condition: "Light rain", description: "Light rain, 8C", tempC: 8) })
                let rig = ControllerRig(root: root, weather: weather)
                let snapshot = await rig.controller.getWeatherSnapshot()
                #expect(snapshot == WeatherSnapshot(condition: "rain", tempC: 8))
            }
        }

        @Test func weatherSnapshotIsNilWithoutALocation() async throws {
            await withBrainRoot { root in
                let rig = ControllerRig(root: root)
                #expect(await rig.controller.getWeatherSnapshot() == nil)
            }
        }

        @Test func windowPositionsAreFilteredPlatforms() async {
            await withBrainRoot { root in
                let rig = ControllerRig(root: root)
                let platforms = await rig.controller.getWindowPositions()
                // whatever is on this machine's screen, the platform filter holds
                for p in platforms {
                    #expect(p.w >= 200 && p.h >= 100)
                }
            }
        }

        // MARK: startup

        @Test func startBringsUpEveryLoopAndStopTearsThemDown() throws {
            try withBrainRoot { root in
                try Config.updateConfig { $0.mcpEnabled = false; $0.weatherLocation = "Bergen" }
                let rig = ControllerRig(root: root)
                rig.screen.permitted = false
                #expect(!rig.controller.isRunning)
                #expect(rig.weather.location() == "")

                rig.controller.start()

                #expect(rig.controller.isRunning)
                // preflight not granted -> the dialog is requested
                #expect(rig.screen.permissionRequests == 1)
                // weather reads the config's location from now on
                #expect(rig.weather.location() == "Bergen")
                #expect(rig.pipeline.isRunning)
                #expect(rig.controller.reflection?.isRunning == true)
                #expect(rig.watch.isRunning)
                // mcp_enabled = false: nothing spawned
                #expect(rig.controller.mcpStartTask == nil)
                #expect(!rig.mcp.isRunning)

                // idempotent: a second start neither re-requests permission nor restarts anything
                rig.controller.start()
                #expect(rig.screen.permissionRequests == 1)

                rig.controller.stop()
                #expect(!rig.controller.isRunning)
                #expect(!rig.pipeline.isRunning)
                #expect(rig.controller.reflection == nil)
                #expect(!rig.watch.isRunning)
            }
        }

        @Test func aGrantedPreflightIsNotRequested() {
            withBrainRoot { root in
                _ = try? Config.updateConfig { $0.mcpEnabled = false }
                let rig = ControllerRig(root: root)
                rig.controller.start()
                defer { rig.controller.stop() }
                #expect(rig.screen.permissionRequests == 0)
            }
        }

        @Test func startCanBeCalledAgainAfterStop() {
            withBrainRoot { root in
                _ = try? Config.updateConfig { $0.mcpEnabled = false }
                let rig = ControllerRig(root: root)
                rig.controller.start()
                rig.controller.stop()
                rig.controller.start()
                defer { rig.controller.stop() }
                #expect(rig.pipeline.isRunning)
                #expect(rig.watch.isRunning)
            }
        }

        @Test func startSpawnsTheMCPServerOnTheConfiguredPort() async throws {
            try await withBrainRoot { root in
                try Config.updateConfig { $0.mcpEnabled = true; $0.mcpPort = 0; $0.mcpToken = "s3cret" }
                let rig = ControllerRig(root: root)

                rig.controller.start()
                defer { rig.controller.stop() }
                await rig.controller.mcpStartTask?.value

                #expect(rig.mcp.isRunning)
                #expect(rig.mcp.port != nil && rig.mcp.port != 0)

                rig.controller.stop()
                #expect(!rig.mcp.isRunning)
            }
        }

        @Test func anUnparseableConfigDoesNotStartMCPWithoutItsToken() throws {
            try withBrainRoot { root in
                try JSONFile.writeData(Data("{ not json".utf8), to: Paths.config)
                let rig = ControllerRig(root: root)

                rig.controller.start()
                defer { rig.controller.stop() }

                #expect(rig.controller.mcpStartTask == nil)
                #expect(!rig.mcp.isRunning)
                #expect(rig.controller.isRunning)
            }
        }

        @Test func anMCPStartFailureIsLoggedAndTheAppKeepsGoing() async throws {
            try await withBrainRoot { root in
                try Config.updateConfig { $0.mcpEnabled = true; $0.mcpPort = 0 }
                let rig = ControllerRig(root: root)
                // A server that is already listening makes the controller's own start throw.
                let firstPort = try await rig.mcp.start(port: 0, token: "")

                rig.controller.start()
                defer { rig.controller.stop() }
                await rig.controller.mcpStartTask?.value

                #expect(rig.mcp.port == firstPort)
                #expect(rig.controller.isRunning)
                #expect(rig.pipeline.isRunning)
            }
        }
    }
}

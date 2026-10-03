import CoreGraphics
import Foundation

// Ex-lib.rs — the overlay-facing Tauri commands, the pause flag and the
// startup half of `setup()` (everything except windows and menus, which the
// glue owns). One main-actor object: the overlay calls these as plain methods,
// `await`ing where the Rust command did real async work.

/// The plain message a Rust command's `Err(String)` carried. The overlay shows
/// it as-is, so `localizedDescription` is exactly `message`.
nonisolated struct AppControllerError: Error, LocalizedError, CustomStringConvertible, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}

final class AppController {
    let vision: VisionPipeline

    private let model: any LanguageModel
    private let screen: ScreenAccess
    private let events: AppEvents
    private let weather: Weather
    private let appWatch: AppWatch
    private let mcp: MCPServer
    private let herd: HerdStore
    private let desktopDirectory: URL

    private(set) var reflection: ReflectionLoop?
    private var isStarted = false

    /// The in-flight MCP `start`, kept so `stop()` can cancel it and tests can await it.
    private(set) var mcpStartTask: Task<Void, Never>?
    /// The last "Comment Now" run (tests await it).
    private(set) var commentNowTask: Task<Void, Never>?
    /// The last menu-triggered debug capture (tests await it).
    private(set) var debugCaptureTask: Task<Void, Never>?

    /// - Parameters:
    ///   - model: `AppleAI` in production. Used for the vision pipeline, the
    ///     chat commands and the reflection loop.
    ///   - vision: override the pipeline (tests inject one with instant sleeps).
    ///   - appWatch: override the frontmost-app watcher.
    ///   - desktopDirectory: where `saveMoment` and the debug capture write
    ///     (`~/Desktop`). Tests point it at a temp directory.
    init(
        model: any LanguageModel = AppleAI(),
        screen: ScreenAccess = .live,
        events: AppEvents = .shared,
        weather: Weather = .shared,
        vision: VisionPipeline? = nil,
        appWatch: AppWatch? = nil,
        mcpServer: MCPServer = .shared,
        herdStore: HerdStore = .shared,
        desktopDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    ) {
        self.model = model
        self.screen = screen
        self.events = events
        self.weather = weather
        self.vision = vision ?? VisionPipeline(model: model, screen: screen, events: events, weather: weather)
        self.appWatch = appWatch ?? AppWatch(events: events)
        self.mcp = mcpServer
        self.herd = herdStore
        self.desktopDirectory = desktopDirectory
    }

    // MARK: - Startup (ex-`setup()`, minus windows and menus)

    var isRunning: Bool { isStarted }

    /// Everything `setup()` did after the window and tray were built, in the
    /// same order with the same log lines. Idempotent. Call it once the
    /// overlay is up, so "Setup complete" is the last line like it was in Rust.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Request screen capture permission early (just triggers the dialog)
        let preflight = screen.hasScreenCapturePermission()
        Log.info("app", "Screen capture preflight: \(preflight ? "granted" : "not granted (will try actual capture later)")")
        if !preflight {
            screen.requestScreenCapturePermission()
        }

        // ex-`onboarding::get_weather_location()` inside weather.rs
        weather.location = { Config.getWeatherLocation() }

        // Spawn vision loop
        Log.info("app", "Spawning vision loop")
        vision.start()

        // Spawn memory reflection loop (daily consolidation + backfill).
        // ReflectionLoop.start logs "Spawning reflection loop" itself.
        let loop = ReflectionLoop(model: model, isVisionTickRunning: { [vision] in vision.isTickRunning })
        reflection = loop
        loop.start()

        // Spawn frontmost-app watcher (feeds gossip & live reactions)
        Log.info("app", "Spawning app watch loop")
        appWatch.start()

        // MCP companion server — Claude Code drives the sheep over loopback.
        // A missing config means defaults (as Rust). A config that exists but
        // won't parse might hold an auth token — don't fail open without it.
        let configExists = FileManager.default.fileExists(atPath: Paths.config.path)
        let cfg = Config.loadConfig() ?? (configExists ? nil : SheepConfig())
        if cfg == nil {
            Log.info("mcp", "error: config.json could not be parsed — MCP server not started")
        }
        if let cfg, cfg.mcpEnabled {
            herd.start() // the hook shim reaches it through the MCP listener
            let port = cfg.mcpPort
            let token = cfg.mcpToken
            mcpStartTask = Task { [mcp] in
                do {
                    try await mcp.start(port: port, token: token)
                } catch {
                    Log.info("mcp", "error: server disabled: \(VisionPipeline.describe(error))")
                }
            }
        } else {
            Log.info("mcp", "disabled via config")
        }

        Log.info("app", "Setup complete")
    }

    /// Stops every loop and the MCP server. `start()` may be called again.
    func stop() {
        vision.stop()
        reflection?.stop()
        reflection = nil
        appWatch.stop()
        mcpStartTask?.cancel()
        mcpStartTask = nil
        mcp.stop()
        herd.stop()
        isStarted = false
    }

    // MARK: - Pause and manual commentary

    /// ex-`COMMENTARY_PAUSED`.
    var isPaused: Bool { vision.isPaused }

    /// The tray/app-menu "Pause Commentary" item: flips the flag.
    func togglePause() {
        vision.isPaused.toggle()
    }

    /// The menu's "Comment Now": one pipeline run in the background, ignoring
    /// the pause flag. Failures are logged, never shown.
    func commentNow() {
        commentNowTask = Task { [vision] in
            Log.info("app", "Manual commentary triggered")
            do {
                try await vision.runVisionPipeline()
            } catch {
                Log.info("app", "error: Manual commentary failed: \(VisionPipeline.describe(error))")
            }
        }
    }

    // MARK: - Commands

    /// ex-`check_onboarding`.
    func checkOnboarding() -> Bool {
        let needs = Config.needsOnboarding()
        Log.info("app", "Onboarding needed: \(needs)")
        return needs
    }

    /// ex-`check_ai_ready`: whether the on-device model is ready to use.
    func checkAiReady() -> Bool {
        model.unavailableReason() == nil
    }

    /// ex-`check_screen_permission`.
    func checkScreenPermission() -> Bool {
        screen.hasScreenCapturePermission()
    }

    /// ex-`record_interaction`.
    func recordInteraction(_ interaction: String) {
        Memory.recordInteraction(interaction)
    }

    /// ex-`record_app_usage`: bump the daily usage tally for an app category
    /// (feeds the AI's "Today's tallies"). Returns the new count.
    @discardableResult
    func recordAppUsage(_ category: String) -> Int {
        Memory.incrementToday("app:\(category)")
    }

    /// ex-`debug_capture`: saves what the sheep sees to the Desktop and says so.
    func debugCapture() async throws -> String {
        Log.info("app", "Debug capture requested")
        do {
            let path = try await screen.saveDebugScreenshot(desktopDirectory)
            events.sheepCommentary.emit(CommentaryEvent(
                text: "Saved what I see to your Desktop! Check co-sheep-debug-capture.png", animation: nil))
            return path
        } catch {
            let msg = "Capture failed: \(VisionPipeline.describe(error))"
            events.sheepCommentary.emit(CommentaryEvent(text: msg, animation: nil))
            throw AppControllerError(msg)
        }
    }

    /// The app menu's "Debug Capture...": `debugCapture()` in the background,
    /// with the failure logged like the Rust menu handler did.
    func debugCaptureFromMenu() {
        debugCaptureTask = Task { [self] in
            do {
                _ = try await debugCapture()
            } catch {
                Log.info("app", "error: Debug capture failed: \(VisionPipeline.describe(error))")
            }
        }
    }

    /// ex-`chat_with_sheep`. On failure throws a canned line in the sheep's
    /// language; the overlay shows `localizedDescription` in the chat bubble.
    func chatWithSheep(message: String, history: [HistoryTurn]) async throws -> CommentaryEvent {
        Log.info("app", "Chat request: \(message)")
        do {
            return try await vision.chatWithSheep(message, history: history)
        } catch {
            Log.info("app", "error: Chat failed: \(VisionPipeline.describe(error))")
            throw AppControllerError(Self.chatFailureLine(language: Config.getLanguage()))
        }
    }

    /// One entry per settings.html language option.
    static func chatFailureLine(language: String) -> String {
        switch language.lowercased() {
        case "nynorsk": "Bæææ... hjernen min verkar ikkje akkurat no. Prøv igjen?"
        case "bokmål": "Bæææ... hjernen min virker ikke akkurat nå. Prøv igjen?"
        case "swedish": "Bäää... min hjärna funkar inte just nu. Försök igen?"
        case "danish": "Bæææ... min hjerne virker ikke lige nu. Prøv igen?"
        case "german": "Määä... mein Gehirn funktioniert gerade nicht. Versuch's nochmal?"
        case "french": "Bêêê... mon cerveau ne marche pas là. Réessaie ?"
        case "spanish": "Beee... mi cerebro no funciona ahora. ¿Intentas de nuevo?"
        case "japanese": "メェェ…今、頭が働かないの。もう一度試して？"
        case "korean": "메에에... 지금 머리가 안 돌아가요. 다시 해볼래요?"
        default: "Baaaa... my brain isn't working right now. Try again?"
        }
    }

    /// ex-`friend_ai_chat`: the friends' raw AI conversation (a JSON array the
    /// flock parses). Wired into Flock as its `friendAIChat` closure.
    func friendAIChat(
        _ aId: String, _ aName: String, _ aPersonality: String,
        _ bId: String, _ bName: String, _ bPersonality: String,
        topic: String?
    ) async throws -> String {
        Log.info("app", "Friend AI chat: \(aName) (\(aPersonality)) <-> \(bName) (\(bPersonality))")
        do {
            return try await vision.friendChat(
                friendAId: aId, friendAName: aName, friendAPersonality: aPersonality,
                friendBId: bId, friendBName: bName, friendBPersonality: bPersonality,
                topic: topic)
        } catch {
            throw AppControllerError(VisionPipeline.describe(error))
        }
    }

    /// ex-`save_moment`: writes the sheep's portrait as `co-sheep-moment-<unix
    /// seconds>.png` in the Desktop directory and returns the path.
    func saveMoment(_ image: CGImage) async throws -> String {
        let ts = Int(SimClock.nowMs() / 1000)
        let url = desktopDirectory.appendingPathComponent("co-sheep-moment-\(ts).png")
        do {
            try await Capture.writePNG(image, to: url)
        } catch {
            throw AppControllerError("Write error: \(VisionPipeline.describe(error))")
        }
        let p = url.path
        Log.info("app", "Moment saved to \(p)")
        return p
    }

    /// ex-`get_weather_snapshot`.
    func getWeatherSnapshot() async -> WeatherSnapshot? {
        await weather.getWeatherSnapshot()
    }

    /// ex-`get_window_positions`: window platforms for the sheep, from a
    /// blocking CoreGraphics call that runs off the main thread.
    func getWindowPositions() async -> [WindowPlatform] {
        await Self.visibleWindowRects(ownPid: ProcessInfo.processInfo.processIdentifier)
    }

    @concurrent
    private static func visibleWindowRects(ownPid: Int32) async -> [WindowPlatform] {
        WindowList.getVisibleWindowRects(ownPid: ownPid)
    }

    // MARK: - Living state, friends, easter

    /// ex-`get_living_state`: `.null` when missing or the name is invalid.
    func getLivingState(_ name: String) -> JSONValue {
        LivingState.loadState(name)
    }

    /// ex-`save_living_state`.
    func saveLivingState(_ name: String, _ value: JSONValue) {
        LivingState.saveState(name, value)
    }

    /// ex-`record_friend_pet`.
    func recordFriendPet(_ id: String) {
        FriendMemory.recordPet(id)
    }

    /// ex-`get_friend_moods`.
    func getFriendMoods() -> [String: String] {
        FriendMemory.getAllMoods()
    }

    /// ex-`get_easter_stats`.
    func getEasterStats() -> EasterStats {
        EasterMemory.getStats()
    }

    /// ex-`record_easter_hunt`.
    @discardableResult
    func recordEasterHunt(_ result: EasterHuntResult) -> EasterStats {
        EasterMemory.recordHunt(result)
    }

    // MARK: - Flock bookkeeping (thin lib.rs commands the flock calls)

    /// ex-`record_friend_conversation`.
    func recordFriendConversation(idA: String, idB: String, topic: String) {
        FriendMemory.recordConversation(idA, idB, topic)
    }

    /// ex-`record_group_activity`.
    func recordGroupActivity(participants: [String], activityType: String) {
        FriendMemory.recordGroupActivity(participants, activityType)
    }

    /// ex-`record_spectacle`: friend memories + affinity boost + diary entry.
    func recordSpectacle(kind: String, participants: [String]) {
        FriendMemory.recordGroupActivity(participants, kind)
        try? Memory.appendJournal("*A \(kind) happened on the desktop! The flock is still talking about it.*")
    }
}

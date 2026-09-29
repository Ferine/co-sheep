import AppKit

/// Ex-main.ts: owns the flock and its managers, drives the frame loop, and
/// turns mouse / file-drop / backend events into sheep behavior.
final class OverlayController: OverlayDriver {
    private let host: OverlayHost
    private let app: AppController
    let flock: Flock
    private let dramaManager: DramaManager
    private let gossipManager: GossipManager
    private let mcpCompanion: McpCompanion
    private let breakReminder = BreakReminder()
    private var personality = "snarky"

    // Drag state
    private var isDragging = false
    private var dragTarget: Sheep?
    private var dragOffsetX: Double = 0
    private var dragOffsetY: Double = 0

    // Petting state
    private var hoverTarget: Sheep?
    private var hoverTimer: Double = 0
    private static let PET_THRESHOLD: Double = 2000 // ms of hovering before petting starts

    // Chat input bubble
    private var chatBubble: InputBubble?
    private static let CHAT_SLOW_MS: Double = 30_000

    // Stampede detection
    private var stampede = StampedeDetector()

    private var timers: [TimerToken] = []
    private var unsubscribers: [() -> Void] = []

    init(host: OverlayHost, app: AppController) {
        self.host = host
        self.app = app
        let size = host.screenSize
        SpeechBubble.viewport = size
        flock = Flock(size.width, size.height)
        Log.info("app", "Flock created with main sheep + Good Colleague")
        flock.attach(to: host.scene)
        flock.friendAIChat = { [weak app] aId, aName, aPers, bId, bName, bPers, topic in
            guard let app else { throw AppControllerError("app gone") }
            return try await app.friendAIChat(aId, aName, aPers, bId, bName, bPers, topic: topic)
        }
        flock.saveMainAccessories = { ids in
            do { try WindowCommands.saveAccessories(ids) } catch {
                Log.info("app", "error: Failed to save accessories: \(error)")
            }
        }

        dramaManager = DramaManager(flock)
        gossipManager = GossipManager(flock)
        mcpCompanion = McpCompanion(flock)
    }

    // MARK: - Startup (ex-init)

    func start() {
        dramaManager.start()
        dramaManager.onDramaTriggeredSpectacle = { [weak self] kind, pair in
            self?.flock.startSpectacle(kind, pair)
        }
        flock.onShowdownResolved = { [weak self] pair, reconciled in
            self?.dramaManager.resolveShowdown(pair, reconciled)
        }
        gossipManager.start()
        mcpCompanion.start()
        Log.info("app", "MCP companion listening for sheep-session events")

        let events = AppEvents.shared

        // Bridge the app watcher onto the flock bus.
        unsubscribers.append(events.appSwitched.on { [weak self] s in
            bus.emit(.appSwitched(s))
            self?.breakReminder.currentApp = s.app
        })

        // Settings (personality, break reminders, seasons, accessories)
        applySettings(WindowCommands.getSettings())
        let accessories = WindowCommands.getAccessories()
        if !accessories.isEmpty {
            flock.main.drawOverlay = createCompositeOverlay(accessories)
        }

        flock.applyEasterStats(app.getEasterStats())

        // Saved friends
        for def in WindowCommands.getFriends() {
            flock.addFriend(Self.friendConfig(def))
        }

        // Weather every 5 min, window platforms every 2 s.
        pollWeather()
        timers.append(SimTimers.every(5 * 60 * 1000) { [weak self] in self?.pollWeather() })
        pollWindows()
        timers.append(SimTimers.every(2000) { [weak self] in self?.pollWindows() })

        host.view.onFileDrop = { [weak self] url, x, y in self?.fileDropped(url, x, y) }

        unsubscribers.append(events.openChat.on { [weak self] in self?.openChat() })
        unsubscribers.append(events.namingComplete.on { [weak self] name in
            guard let self else { return }
            Log.info("app", "Naming complete: \(name)")
            if self.app.checkAiReady() {
                self.flock.mainBubble.show(
                    "Nice! I'm \(name) now. I can see everything. This is going to be fun. For me.", duration: 6000)
            } else {
                self.flock.mainBubble.show(
                    "I'm \(name)! But my brain isn't working yet — enable Apple Intelligence in System Settings so I can think.",
                    duration: 8000)
            }
        })
        unsubscribers.append(events.addFriend.on { [weak self] cfg in self?.flock.addFriend(cfg) })
        unsubscribers.append(events.removeFriend.on { [weak self] id in
            self?.flock.removeFriend(id)
            self?.dramaManager.onFriendRemoved(id)
        })
        unsubscribers.append(events.settingsChanged.on { [weak self] cfg in self?.applySettings(cfg) })
        unsubscribers.append(events.captureMoment.on { [weak self] in
            Task { await self?.captureMoment() }
        })
        unsubscribers.append(events.debugCommand.on { [weak self] cmd in self?.debugCommand(cmd) })
        unsubscribers.append(events.accessoriesChanged.on { [weak self] ids in
            self?.flock.main.drawOverlay = createCompositeOverlay(ids)
        })
        unsubscribers.append(events.friendAccessoriesChanged.on { [weak self] change in
            self?.flock.getFriendEntry(change.id)?.sheep.drawOverlay = createCompositeOverlay(change.accessories)
        })

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }

        // Onboarding
        let needsOnboarding = app.checkOnboarding()
        Log.info("app", "Needs onboarding: \(needsOnboarding)")
        if needsOnboarding {
            Log.info("app", "Will open naming window in 4s...")
            timers.append(SimTimers.after(4000) {
                Log.info("app", "Opening naming window")
                WindowManager.shared.open(.naming)
            })
        }

        host.scene.driver = self
        Log.info("app", "Starting animation loop")
    }

    private func applySettings(_ cfg: SheepConfig) {
        personality = cfg.personality.isEmpty ? "snarky" : cfg.personality
        breakReminder.setEnabled(cfg.breakReminders)
        flock.setEasterMode(EasterMode(rawValue: cfg.easterMode) ?? .auto)
        flock.setSummerMode(SummerMode(rawValue: cfg.summerMode) ?? .auto)
    }

    private func screenChanged() {
        guard host.refit() else { return }
        let size = host.screenSize
        SpeechBubble.viewport = size
        flock.updateScreenSize(size.width, size.height)
    }

    // MARK: - Frame loop (ex-gameLoop)

    func update(dt: Double) {
        flock.update(dt)
        // Break reminder check
        breakReminder.update(dt, flock.main.state, flock.mainBubble, personality) { [weak self] anim in
            self?.flock.main.playAnimation(anim)
            self?.flock.echoBreakReminder()
        }
        if let chatBubble {
            chatBubble.updatePosition(flock.main.x, flock.main.y, flock.main.displaySize)
        }
        // Click-through from all character bounds (ex-update_sheep_bounds_multi + cursor loop).
        let bounds = flock.getAllBounds().map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
        host.updateClickThrough(bounds: bounds, forceInteractive: isDragging || chatBubble != nil)
    }

    func draw(_ ctx: Canvas) {
        ctx.imageSmoothingEnabled = false
        flock.draw(ctx)
    }

    // MARK: - Polling

    private func pollWeather() {
        Task { [weak self] in
            guard let self else { return }
            let snap = await self.app.getWeatherSnapshot()
            self.flock.setWeatherCondition(snap?.condition, snap?.tempC)
        }
    }

    private func pollWindows() {
        Task { [weak self] in
            guard let self else { return }
            let platforms = await self.app.getWindowPositions()
            self.flock.setWindowPlatforms(platforms)
        }
    }

    // MARK: - Mouse (ex-document listeners)

    func mouseDown(x: Double, y: Double, clickCount: Int) {
        // Click anywhere outside the chat bubble ends the conversation
        chatBubble?.handleMouseDown(x: x, y: y)

        guard let target = flock.hitTest(x, y) else { return }
        Log.debug("app", "Grab \(target.id) at \(Int(x)), \(Int(y))")
        isDragging = true
        dragTarget = target
        dragOffsetX = x - target.x
        dragOffsetY = y - target.y
        // Clear petting state so hearts don't resume after release
        if let hoverTarget, hoverTarget !== target { hoverTarget.stopPetting() }
        hoverTarget = nil
        hoverTimer = 0
        target.grab()
        NSCursor.closedHand.set()
    }

    func mouseDragged(x: Double, y: Double) {
        if isDragging, let dragTarget {
            dragTarget.x = x - dragOffsetX
            dragTarget.y = y - dragOffsetY
        }
    }

    func mouseUp(x: Double, y: Double, clickCount: Int) {
        if isDragging, let target = dragTarget {
            Log.debug("app", "Release \(target.id)!")
            isDragging = false

            // Check for stacking first
            if let stackTarget = flock.tryStack(target) {
                target.stackOn(stackTarget)
                flock.onSheepStacked(target, stackTarget)
            } else {
                target.release()
                // Check if trampoline was triggered
                if target.state == .trampoline {
                    flock.onTrampolineStarted(target)
                }
            }
            dragTarget = nil
            NSCursor.openHand.set()
        }
        // DOM `dblclick` fires after the second mouseup.
        if clickCount == 2 { doubleClick(x: x, y: y) }
    }

    private func doubleClick(x: Double, y: Double) {
        guard let target = flock.hitTest(x, y), !isDragging else { return }
        Log.debug("app", "Double-click \(target.id)!")
        target.resetActivity()
        let quip = flock.getQuip(target)
        let bubble = flock.getBubble(target)
        bubble.show(quip, duration: 4000)
        let anims: [SheepAnimation] = [.bounce, .spin, .headshake, .vibrate]
        target.playAnimation(anims[SimRandom.int(anims.count)])
        app.recordInteraction("poked \(target.id)")
    }

    func mouseMoved(x: Double, y: Double) {
        guard !isDragging else { return }
        pettingMove(x, y)
        stampedeMove(x, y)
    }

    // Petting: track hover time over any sheep
    private func pettingMove(_ x: Double, _ y: Double) {
        if let target = flock.hitTest(x, y) {
            if hoverTarget !== target {
                // Started hovering a new target — release the old one, or it
                // stays in "petting" forever (that state has no timeout)
                hoverTarget?.stopPetting()
                hoverTarget = target
                hoverTimer = SimClock.perfMs()
            } else if SimClock.perfMs() - hoverTimer > Self.PET_THRESHOLD,
                      target.state != .petting,
                      // No petting the main sheep mid-conversation — it's listening
                      !(target.id == "main" && chatBubble != nil) {
                target.startPetting()
                flock.getBubble(target).show("Zzzz... don't stop...", duration: 3000)
                app.recordInteraction("petted \(target.id)")
                bus.emit(.sheepPetted(id: target.id))
                if target.id != "main" {
                    app.recordFriendPet(target.id)
                }
            }
        } else if let hoverTarget {
            hoverTarget.stopPetting()
            self.hoverTarget = nil
        }
    }

    // Stampede detection: track rapid mouse shaking
    private func stampedeMove(_ x: Double, _ y: Double) {
        if let center = stampede.sample(x: x, y: y, now: SimClock.perfMs()) {
            flock.triggerStampede(center.x, center.y)
        }
    }

    // Right-click: open chat with main sheep
    func rightMouseDown(x: Double, y: Double) {
        if let target = flock.hitTest(x, y), target.id == "main" {
            openChat()
        }
    }

    // File drop: any character can "eat" the file
    private func fileDropped(_ url: URL, _ x: Double, _ y: Double) {
        // Check if dropped on a specific character, default to main sheep
        let target = flock.hitTest(x, y) ?? flock.main
        let bubble = flock.getBubble(target)
        Log.debug("app", "File dropped on \(target.id): \(url.lastPathComponent)")
        target.resetActivity()
        bubble.show(FileComments.comment(forFileName: url.lastPathComponent), duration: 5000)
        target.playAnimation(.bounce)
        app.recordInteraction("fed a file to \(target.id)")
    }

    // MARK: - Debug menu

    private func debugCommand(_ cmd: String) {
        Log.info("app", "debug-command: \(cmd)")
        if cmd == "force-feud" {
            let key = dramaManager.forceFeud()
            flock.mainBubble.show(key.map { "Feud forced: \($0)" } ?? "No pair available to feud.", duration: 4000)
        } else if cmd.hasPrefix("spectacle:"), let type = SpectacleType(rawValue: String(cmd.dropFirst("spectacle:".count))) {
            if type == .showdown || type == .feast {
                let ids = flock.getCharacterIds().filter { $0 != "main" }
                if ids.count >= 2 { flock.startSpectacle(type, (ids[0], ids[1])) }
            } else {
                flock.startSpectacle(type)
            }
        } else if cmd == "app-switch" {
            // >1h so gossip fires too
            bus.emit(.appSwitched(AppSwitch(app: "Xcode", previousApp: "Safari", previousDurationMs: 3_700_000)))
        }
    }

    // MARK: - Capture Moment

    private func captureMoment() async {
        let sheep = flock.main
        let size = sheep.displaySize
        let padding: Double = 20
        let bubbleText = flock.mainBubble.currentText
        let bubbleHeight: Double = bubbleText.isEmpty ? 0 : 60
        let totalW = size + padding * 2
        let totalH = size + padding * 2 + bubbleHeight

        let off = Canvas()
        off.beginFrame()
        off.imageSmoothingEnabled = false
        // Draw sheep centered on the offscreen canvas
        let origX = sheep.x, origY = sheep.y
        sheep.x = padding
        sheep.y = padding + bubbleHeight
        off.group("moment") {
            sheep.draw(off)
            if !bubbleText.isEmpty {
                drawBubbleShape(off, totalW / 2, padding + bubbleHeight - 5, bubbleText)
            }
        }
        sheep.x = origX
        sheep.y = origY

        // The web canvas was 1 px per CSS px; keep the same pixel size.
        guard let image = CGReplay.image(off.groups.flatMap(\.ops),
                                         rect: CGRect(x: 0, y: 0, width: totalW, height: totalH), scale: 1) else {
            flock.mainBubble.show("Capture failed... baaad luck.", duration: 4000)
            return
        }
        do {
            _ = try await app.saveMoment(image)
            flock.mainBubble.show("Moment captured! Saved to your Desktop.", duration: 5000)
        } catch {
            Log.info("app", "error: Capture failed: \(error)")
            flock.mainBubble.show("Capture failed... baaad luck.", duration: 4000)
        }
    }

    // MARK: - Chat (ex-openChat)

    private func openChat() {
        if chatBubble != nil { return } // already open

        var transcript: [ChatTurn] = []
        var sendSeq = 0 // a reply only renders if no newer message superseded it
        var closed = false
        flock.main.startListening()
        // A sheep mid-petting when chat opens would loop hearts forever — end it
        if hoverTarget === flock.main {
            hoverTarget?.stopPetting()
            hoverTarget = nil
        }

        var bubbleRef: InputBubble?
        let bubble = InputBubble(config: InputBubbleConfig(
            promptText: "Talk to me...",
            placeholder: "Say something...",
            buttonText: "Send",
            onSubmit: { [weak self] text in
                guard let self, let bubble = bubbleRef, !closed else { return }
                sendSeq += 1
                let seq = sendSeq
                bubble.setLoading(true)
                let history = capTranscript(transcript).map { HistoryTurn(role: $0.role.rawValue, text: $0.text) }
                transcript.append(ChatTurn(role: .human, text: text))
                // Soft timeout: the model call can't be cancelled, so warn and
                // hand the input back — but keep waiting for the reply.
                let slowTimer = SimTimers.after(Self.CHAT_SLOW_MS) {
                    if seq == sendSeq && !closed { bubble.showReply("Zzz...", isError: true) }
                }
                do {
                    let event = try await self.app.chatWithSheep(message: text, history: history)
                    slowTimer.cancel()
                    if seq != sendSeq { return } // superseded by a newer message
                    if closed {
                        // Chat dismissed while thinking — deliver on the floating bubble
                        self.flock.mainBubble.show(event.text, duration: 8000)
                    } else {
                        transcript.append(ChatTurn(role: .sheep, text: event.text))
                        bubble.showReply(event.text)
                    }
                    self.flock.onChatReply(event.animation)
                } catch {
                    slowTimer.cancel()
                    Log.info("app", "error: Chat error: \(error)")
                    if seq != sendSeq || closed { return }
                    // The model never answered — drop the turn so a retry isn't doubled
                    if transcript.last?.role == .human { transcript.removeLast() }
                    let message = (error as? AppControllerError)?.localizedDescription ?? "Baaaa... something broke."
                    bubble.showReply(message, isError: true)
                }
            },
            onClose: { [weak self] in
                guard let self, let bubble = bubbleRef else { return }
                closed = true
                self.flock.main.stopListening()
                bubble.destroy()
                if self.chatBubble === bubble { self.chatBubble = nil }
                bubbleRef = nil // break config-closure → bubble cycle
            },
            // A mousedown on a sheep is a grab, not a dismissal — dragging the
            // sheep mid-conversation must not wipe the transcript
            shouldIgnoreClickAway: { [weak self] x, y in self?.flock.hitTest(x, y) != nil }
        ), host: host)
        bubbleRef = bubble
        chatBubble = bubble
        bubble.show()
        bubble.updatePosition(flock.main.x, flock.main.y, flock.main.displaySize)
    }

    // MARK: - Conversions

    static func friendConfig(_ def: FriendDef) -> FriendConfig {
        FriendConfig(id: def.id, name: def.name, color: FriendColor(rawValue: def.color) ?? .pink,
                     personality: FriendPersonality(rawValue: def.personality),
                     accessories: def.accessories, scale: def.scale)
    }
}

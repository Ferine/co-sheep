import Foundation

// Ex-flock.ts: the orchestrator. Owns the main sheep, the friends and every
// piece of flock-wide state (conversations, group activities, spectacles,
// stampede, notifications, themes, night/weather ambience), steps them per
// frame and draws them in z-order.
//
// Rendering (see plan: z-order bands): `draw(_:)` routes each layer into a
// Canvas group (= one GPU tile), in the original TS draw order:
//
//     easter:bg, summer:bg, easter:mid, summer:mid,
//     sheep:main, sheep:<friendId>… (map order),
//     spectacle (only while one runs; shearing adds spectacle:shorn:<id> tiles),
//     easter:fg, summer:fg                      — all `.world` layer
//     bubble:<id> (visible bubbles only)         — `.overlay` layer
//
// Night ambience and weather are SpriteKit-native: `attach(to:)` parents them
// into the scene once, `draw` only syncs their nodes (no Canvas group).

/// ex-`{ x, y, w, h }` literal of `getAllBounds()`.
struct FlockBounds: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// Insertion-ordered id → value map (JS `Map` iteration order, which decides
/// draw order and "friends first" hit testing).
private struct OrderedMap<Value> {
    private(set) var keys: [String] = []
    private var storage: [String: Value] = [:]

    var count: Int { keys.count }

    subscript(key: String) -> Value? { storage[key] }

    func has(_ key: String) -> Bool { storage[key] != nil }

    /// `Map.set`: an existing key keeps its position.
    mutating func set(_ key: String, _ value: Value) {
        if storage[key] == nil { keys.append(key) }
        storage[key] = value
    }

    mutating func delete(_ key: String) {
        guard storage[key] != nil else { return }
        storage[key] = nil
        keys.removeAll { $0 == key }
    }

    var values: [Value] { keys.compactMap { storage[$0] } }

    var entries: [(key: String, value: Value)] { keys.compactMap { k in storage[k].map { (k, $0) } } }
}

final class Flock {
    // MARK: Constants (file-level in flock.ts; scoped here)

    static let DISPLAY_SIZE: Double = 96 // 32 * 3

    static let GOOD_COLLEAGUE_QUIPS = [
        "No blir det liv rai rai",
        "Fakyou",
        "Langt oppi b\u{00F8}ttebaletten",
        "N\u{00E5} blir det godt med medda",
        "N\u{00E5} er det tomt alts\u{00E5}",
        "Tai tai tai tai",
        "N\u{00E5} er det bare pausemusikk",
        "N\u{00E5} er hodet tygd og spytta p\u{00E5}",
        "Hjernen alene hjemme",
        "Kan du sette opp en kjapp apostel",
        "Tidenes forundringspakke er ikke forbi",
        "De setter opp artium hus p\u{00E5} skorpa",
        "Alle kluter til",
        "Hvis vi kan kalle inn ham og hans undersl\u{00E5}tte, s\u{00E5} ville det v\u{00E6}rt fint",
        "Viktig \u{00E5} tenke gjennom dette s\u{00E5} vi ikke lager slike dirty fries",
        "Da er det bare \u{00E5} stride til verket",
        "Da greip \u{00E6} mitt snitt \u{00E6}",
        "Kontrolert brud",
    ]

    static let EASTER_IDLE_QUIPS = [
        "I can smell fresh paint.",
        "Spring logistics are underway.",
        "This meadow is suspiciously egg-shaped.",
    ]
    static let EASTER_POST_HUNT_QUIPS = [
        "I should've hidden them better.",
        "We absolutely crushed that hunt.",
        "I am still thinking about the golden egg.",
    ]

    /// Personality-keyed pools (TS `Record<FriendPersonality, string[]>`), all
    /// falling back to `wholesome` like the TS `?? X.wholesome`.
    typealias PersonalityPools = [FriendPersonality: [String]]

    static let TRAMPOLINE_REACTIONS: PersonalityPools = [
        .wholesome: ["WOAH! Are you okay?!", "Impressive!", "Do it again!"],
        .chaotic: ["YESSS! HIGHER! HIGHER!", "10/10! DO A FLIP!", "I WANT A TURN!"],
        .snarky: ["Show off.", "Physics isn't your strong suit.", "Gravity always wins."],
        .passiveAggressive: ["Must be nice to fly...", "Oh, so YOU get to have fun.", "I'm fine down here."],
    ]

    static let ECHO_MESSAGES: PersonalityPools = [
        .wholesome: ["They're right! Take care of yourself!", "Please stretch! For me?"],
        .chaotic: ["YEAH! STAND UP! DO A FLIP!", "BREAK TIME BREAK TIME!"],
        .snarky: ["They have a point, for once.", "Even I agree. Take a break."],
        .passiveAggressive: ["I mean, if you WANT to ruin your health...", "Sure, keep sitting. See what happens."],
    ]

    static let GREETINGS: PersonalityPools = [
        .wholesome: ["Good to be here! Ready for a great day!", "Hello everyone!"],
        .chaotic: ["I'M ALIVE AGAIN! WHAT DID I MISS?!", "LET'S GOOOOO"],
        .snarky: ["Oh. We're doing this again.", "Back to the grind."],
        .passiveAggressive: ["Oh, you remembered I exist. How nice.", "I guess I'm here now."],
    ]

    static let NIGHT_MESSAGES: PersonalityPools = [
        .wholesome: ["Getting dark! Cozy time!", "Stars are coming out!"],
        .chaotic: ["THE SUN DIED! WE'RE NEXT!", "DARKNESS FALLS!"],
        .snarky: ["Still working? Bold.", "Another late night, huh."],
        .passiveAggressive: ["I'm sure working late is FINE.", "Don't mind the time. I won't."],
    ]

    static let REACTION_MESSAGES: PersonalityPools = [
        .wholesome: ["Oh!", "Yay!", "*looks over excitedly*", "How nice!"],
        .chaotic: ["WHAT", "DID YOU SEE THAT", "!!!", "WHOA"],
        .snarky: ["...", "*glances over*", "Hmm.", "Interesting."],
        .passiveAggressive: ["*pretends not to notice*", "That's... something.", "Cool, I guess."],
    ]

    static let REACTION_ANIMS: [FriendPersonality: SheepAnimation?] = [
        .wholesome: .bounce,
        .chaotic: .spin,
        .snarky: .headshake,
        .passiveAggressive: nil,
    ]

    static let STAMPEDE_QUIPS_A = [
        "What was THAT?!",
        "I thought I was going to die!",
        "MY HEART IS STILL RACING!",
        "EARTHQUAKE?! PREDATOR?! WHAT?!",
        "I saw my life flash before my eyes!",
    ]
    static let STAMPEDE_QUIPS_B = [
        "...I think it was the cursor.",
        "We really need to stop panicking.",
        "That was the cursor. Again.",
        "I'm going to need therapy.",
        "Same time tomorrow, probably.",
    ]

    static let STACK_TOP_QUIPS = [
        "I can see everything from up here!",
        "The view is amazing!",
        "Don't move!",
        "I'm the king of the sheep!",
        "Higher! HIGHER!",
    ]
    static let STACK_BOTTOM_QUIPS = [
        "HEY! Get off me!",
        "I'm NOT a chair!",
        "This is NOT okay.",
        "My back... my poor back...",
        "I didn't sign up for this.",
    ]

    static let SPECTACLE_KIND_LABELS: [SpectacleType: String] = [
        .wolf: "wolf scare", .ufo: "UFO encounter", .merchant: "merchant visit",
        .balloon: "balloon flyover", .shearing: "shearing day",
        .showdown: "high-noon showdown", .feast: "reconciliation feast",
    ]

    static let HEX_BY_COLOR: [FriendColor: String] = [
        .pink: "#e94560", .blue: "#4a90d9", .green: "#4ecca3",
        .gold: "#d4a520", .purple: "#9b59b6", .orange: "#e67e22",
    ]

    private static func pick(_ pools: PersonalityPools, _ personality: FriendPersonality) -> [String] {
        pools[personality] ?? pools[.wholesome] ?? []
    }

    /// `arr[Math.floor(Math.random() * arr.length)]`.
    private static func pickOne(_ items: [String]) -> String {
        items[SimRandom.int(items.count)]
    }

    // MARK: Types

    struct PendingReaction {
        var text: String
        var animation: SheepAnimation?
        var delay: Double
    }

    /// A friend: its sheep, speech bubble, quip pool and pending reaction.
    /// A class because main.ts / the managers hold and mutate it by reference.
    final class FriendEntry {
        let sheep: Sheep
        let bubble: SpeechBubble
        let quips: [String]
        var nextQuipTime: Double
        let personality: FriendPersonality
        var pendingReaction: PendingReaction?

        init(sheep: Sheep, bubble: SpeechBubble, quips: [String], nextQuipTime: Double,
             personality: FriendPersonality) {
            self.sheep = sheep
            self.bubble = bubble
            self.quips = quips
            self.nextQuipTime = nextQuipTime
            self.personality = personality
        }
    }

    struct ActiveConversation {
        var lines: ConversationScript
        var currentIndex: Int
        var timer: Double
        /// Insertion-ordered and de-duplicated (TS `Set<string>`).
        var participants: [String]
    }

    private struct FriendChatUnavailable: Error {}

    /// One line of the model's friend-chat JSON.
    private nonisolated struct AIChatLine: Decodable {
        var speaker: String
        var text: String
        var animation: String?

        private enum CodingKeys: String, CodingKey { case speaker, text, animation }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            speaker = (try? c.decode(String.self, forKey: .speaker)) ?? ""
            text = try c.decode(String.self, forKey: .text)
            animation = try? c.decodeIfPresent(String.self, forKey: .animation)
        }
    }

    // MARK: Properties

    let main: Sheep
    let mainBubble: SpeechBubble
    private var friends = OrderedMap<FriendEntry>()
    private var screenWidth: Double
    private var screenHeight: Double
    private var socialTimer: Double = 0
    /// Internal (not private) so tests can inspect / seed it.
    var activeConversation: ActiveConversation?
    private var conversationCooldown: Double = 0
    private let nightAmbience: NightAmbience
    private let weatherEffects: WeatherEffects
    /// Internal (not private) so tests can reach the hunt's eggs.
    let easterTheme: EasterTheme
    let summerTheme: SummerTheme
    private var reactiveCooldown: Double = 0
    private var currentWeatherCondition: String?
    private var lastNotificationHour: Int = -1
    private var notificationCooldown: Double = 0
    private var hasGreetedOnLaunch = false
    private var launchTimer: Double = 0
    /// Internal so tests can inspect / seed it.
    var groupActivity: GroupActivity?
    private var groupActivityCooldown: Double = 0
    private(set) var aiChatPending = false
    private var aiChatCooldown: Double = 0
    /// The in-flight `friendAIChat` request (tests await it).
    private(set) var aiChatTask: Task<Void, Never>?
    /// Internal so tests can inspect it.
    private(set) var spectacle: SpectacleScene?
    private var spectacleSchedulerState = SpectacleSchedulerState(lastFiredMs: 0, lastByType: [:])
    private var spectacleCheckTimer: Double = 0
    private var spectacleStateLoaded = false
    private var goodColleagueTimer: TimerToken?

    /// main.ts points this at dramaManager.resolveShowdown.
    var onShowdownResolved: ((_ pair: (String, String), _ reconciled: Bool) -> Void)?

    // Stampede
    private var stampedeCooldown: Double = 0
    private var stampedeActive = false
    private var stampedeDialogueTimer: Double = 0

    /// Callback set by main.ts when break reminder fires
    var onBreakReminderFired: (() -> Void)?

    /// Installed by DramaManager: filters group-activity participant lists (drops feuders).
    var participantFilter: ((_ ids: [String]) -> [String])?

    // MARK: Seams (Tauri commands owned by other tasks)

    /// ex-`invoke("friend_ai_chat", …)`: the app wires this to
    /// `Vision.friendChat`. nil behaves as if the call failed (10-minute
    /// back-off, no conversation).
    var friendAIChat: ((_ aId: String, _ aName: String, _ aPersonality: String,
                        _ bId: String, _ bName: String, _ bPersonality: String,
                        _ topic: String?) async throws -> String)?

    /// ex-`invoke("save_accessories", …)` (merchant gift): the app wires this
    /// to persist the main sheep's accessory list and emit accessoriesChanged.
    var saveMainAccessories: (([String]) -> Void)?

    // MARK: Init

    init(_ screenWidth: Double, _ screenHeight: Double) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        SpeechBubble.viewport = ScreenSize(width: screenWidth, height: screenHeight)

        nightAmbience = NightAmbience(screenWidth, screenHeight)
        weatherEffects = WeatherEffects()
        easterTheme = EasterTheme(screenWidth, screenHeight)
        summerTheme = SummerTheme(screenWidth, screenHeight)

        // Create main sheep
        main = Sheep(screenWidth, screenHeight, "main")
        main.setEasterTheme(easterTheme)
        mainBubble = SpeechBubble(listenToCommentary: true)
        attachSeasonalOverlay(main)

        // Wire AI commentary animations to main sheep
        mainBubble.onAnimation = { [weak self] anim in
            Log.info("flock", "Triggering animation from AI: \(anim.rawValue)")
            self?.onChatReply(anim)
        }

        // Spawn Good Colleague after a short delay
        goodColleagueTimer = SimTimers.after(3000) { [weak self] in
            self?.spawnGoodColleague()
        }

        // ex-`invoke("get_living_state", { name: "spectacles" })` — the file is
        // tiny, so it is read inline instead of on a promise.
        loadSpectacleState()
    }

    /// Parent the SpriteKit-native effects (night sky, fireflies, rain/snow)
    /// into the scene's z-bands. The app calls this once after construction;
    /// construction itself stays scene-free so the sim runs headless.
    func attach(to scene: OverlayScene) {
        nightAmbience.attach(to: scene)
        weatherEffects.attach(to: scene)
    }

    private func loadSpectacleState() {
        let value = LivingState.loadState("spectacles")
        if value.objectValue != nil, value["lastFiredMs"]?.doubleValue != nil,
           let data = try? JSONFile.encoder().encode(value),
           let state = try? JSONFile.decoder().decode(SpectacleSchedulerState.self, from: data) {
            spectacleSchedulerState = state
        }
        spectacleStateLoaded = true
    }

    private func saveSpectacleState() {
        // Bridge the Codable state through JSONValue (ex-`value: this.spectacleSchedulerState`).
        guard let data = try? JSONFile.encoder().encode(spectacleSchedulerState),
              let value = try? JSONFile.decoder().decode(JSONValue.self, from: data) else { return }
        LivingState.saveState("spectacles", value)
    }

    /// Internal (not private) so tests can spawn the colleague without waiting
    /// for the 3s timer; spawning cancels that timer, so it can't double up.
    func spawnGoodColleague() {
        goodColleagueTimer?.cancel()
        goodColleagueTimer = nil

        let tint = FRIEND_TINTS[.blue]
        let startX = SimRandom.next() * (screenWidth - Self.DISPLAY_SIZE * 2) + Self.DISPLAY_SIZE / 2
        let sheep = Sheep(screenWidth, screenHeight, "good_colleague", tint, startX)
        sheep.setEasterTheme(easterTheme)
        attachSeasonalOverlay(sheep)
        sheep.name = "Good Colleague"
        sheep.drawOverlay = Self.drawGoodColleagueOverlay

        let bubble = SpeechBubble(listenToCommentary: false, borderColor: "#4a90d9")

        let entry = FriendEntry(
            sheep: sheep,
            bubble: bubble,
            quips: Self.GOOD_COLLEAGUE_QUIPS,
            nextQuipTime: SimClock.nowMs() + 15000 + SimRandom.next() * 30000,
            personality: .snarky
        )
        friends.set("good_colleague", entry)
    }

    func addFriend(_ config: FriendConfig) {
        if friends.has(config.id) { return }
        if friends.count >= 5 { return }

        let tint = FRIEND_TINTS[config.color] ?? FRIEND_TINTS[.pink]
        let scale = config.scale ?? (0.85 + SimRandom.next() * 0.3) // 0.85–1.15
        let startX = SimRandom.next() * (screenWidth - Self.DISPLAY_SIZE * 2) + Self.DISPLAY_SIZE / 2
        let sheep = Sheep(screenWidth, screenHeight, config.id, tint, startX, scale)
        sheep.setEasterTheme(easterTheme)
        attachSeasonalOverlay(sheep)
        sheep.name = config.name

        let personality: FriendPersonality = config.personality ?? .wholesome
        sheep.personality = personality

        // Apply accessories if provided
        if let accessories = config.accessories, !accessories.isEmpty {
            sheep.drawOverlay = createCompositeOverlay(accessories)
        }

        let bubble = SpeechBubble(listenToCommentary: false,
                                  borderColor: Self.HEX_BY_COLOR[config.color] ?? "#e94560")

        let quips = getPersonalityQuips(personality)

        friends.set(config.id, FriendEntry(
            sheep: sheep,
            bubble: bubble,
            quips: quips,
            nextQuipTime: SimClock.nowMs() + 30000 + SimRandom.next() * 60000,
            personality: personality
        ))
    }

    func getFriendEntry(_ id: String) -> FriendEntry? {
        friends[id]
    }

    func removeFriend(_ id: String) {
        if id == "good_colleague" { return } // can't remove the colleague
        if let entry = friends[id] {
            // Detach from any stack, or a sheep riding the removed friend keeps
            // tracking its ghost forever (and vice versa)
            entry.sheep.detachFromStack()
            entry.bubble.destroy()
            friends.delete(id)
        }
    }

    /// Hit test all characters, friends first (drawn on top). Returns nil if none hit.
    func hitTest(_ px: Double, _ py: Double) -> Sheep? {
        // Check friends in reverse order (last drawn = on top)
        for entry in friends.values.reversed() {
            if entry.sheep.hitTest(px, py) { return entry.sheep }
        }
        if main.hitTest(px, py) { return main }
        return nil
    }

    /// Get the speech bubble for a specific sheep
    func getBubble(_ sheep: Sheep) -> SpeechBubble {
        if sheep.id == "main" { return mainBubble }
        return friends[sheep.id]?.bubble ?? mainBubble
    }

    /// Get the quip pool for a specific sheep
    func getQuip(_ sheep: Sheep) -> String {
        if sheep.id == "main" { return sheep.getRandomQuip() }
        if let entry = friends[sheep.id] {
            return entry.quips[SimRandom.int(entry.quips.count)]
        }
        return sheep.getRandomQuip()
    }

    /// All character ids: "main" + every friend (incl. good_colleague).
    func getCharacterIds() -> [String] {
        ["main"] + friends.keys
    }

    /// Public lookup for other systems (drama, spectacles, gossip).
    func getCharacter(_ id: String) -> FlockCharacter? {
        getSheepById(id)
    }

    func isCharacterCalm(_ id: String) -> Bool {
        if let c = getSheepById(id) { return isCalm(c.sheep) }
        return false
    }

    /// Play a prepared script through the normal conversation machinery.
    /// Refuses (returns false) if the stage is already busy.
    @discardableResult
    func startScriptedConversation(_ script: ConversationScript, _ participants: [String]) -> Bool {
        if activeConversation != nil || groupActivity != nil || script.isEmpty { return false }
        for id in participants {
            guard let c = getSheepById(id), isCalm(c.sheep), !c.bubble.visible else { return false }
        }
        var unique: [String] = []
        for id in participants where !unique.contains(id) { unique.append(id) }
        activeConversation = ActiveConversation(lines: script, currentIndex: 0, timer: 0, participants: unique)
        return true
    }

    /// Begin a spectacle. Refuses while another scene is running.
    @discardableResult
    func startSpectacle(_ type: SpectacleType, _ pair: (String, String)? = nil) -> Bool {
        if spectacle != nil { return false }
        cancelConversation()
        let calmIds = getCharacterIds().filter { isCharacterCalm($0) }
        if type != .balloon && calmIds.isEmpty { return false }
        spectacle = createSpectacleScene(type, screenWidth, screenHeight, calmIds, pair)
        spectacleSchedulerState = markFired(spectacleSchedulerState, type, SimClock.nowMs())
        saveSpectacleState()
        bus.emit(.spectacleStarted(type: type.rawValue))
        Log.info("flock", "SPECTACLE: \(type.rawValue)")
        return true
    }

    /// Trigger stampede — all sheep scatter in panic
    func triggerStampede(_ mouseX: Double, _ mouseY: Double) {
        if stampedeCooldown > 0 || stampedeActive { return }

        stampedeCooldown = 15000
        cancelConversation()

        main.startStampede(mouseX)
        for entry in friends.values {
            entry.sheep.startStampede(mouseX)
        }

        // Only queue post-stampede dialogue if someone actually stampeded
        // (everyone could be parachuting/stacked and thus exempt)
        let anyStampeding = main.state == .stampede || friends.values.contains { $0.sheep.state == .stampede }
        if anyStampeding {
            stampedeActive = true
            stampedeDialogueTimer = 2500 // dialogue 2.5s after stampede starts
            Log.info("flock", "STAMPEDE triggered!")
        }
    }

    /// Check if a dropped sheep should stack on another
    func tryStack(_ droppedSheep: Sheep) -> Sheep? {
        let dropBottom = droppedSheep.y + droppedSheep.displaySize
        let dropCenterX = droppedSheep.x + droppedSheep.displaySize / 2

        func check(_ target: Sheep) -> Bool {
            if target === droppedSheep { return false }
            if target.stackedBy != nil { return false } // already has something on top
            let badStates: [SheepState] = [.grabbed, .parachute, .fall, .stampede, .trampoline, .stacked]
            if badStates.contains(target.state) { return false }

            let targetCenterX = target.x + target.displaySize / 2
            let xDist = abs(dropCenterX - targetCenterX)
            let yDist = dropBottom - target.y

            return xDist < target.displaySize * 0.7 && yDist > -target.displaySize * 0.3
                && yDist < target.displaySize * 0.6
        }

        for entry in friends.values.reversed() {
            if check(entry.sheep) { return entry.sheep }
        }
        if check(main) { return main }

        return nil
    }

    /// Called when a sheep is stacked on another — triggers dialogue
    func onSheepStacked(_ top: Sheep, _ bottom: Sheep) {
        let topBubble = getBubble(top)
        let bottomBubble = getBubble(bottom)

        bottomBubble.show(Self.pickOne(Self.STACK_BOTTOM_QUIPS), duration: 4000)
        SimTimers.after(1500) {
            if top.state == .stacked {
                topBubble.show(Self.pickOne(Self.STACK_TOP_QUIPS), duration: 4000)
            }
        }

        bottom.playAnimation(.headshake)
        Memory.recordInteraction("stacked \(top.id) on \(bottom.id)")
    }

    /// Called when a sheep starts trampolining — triggers reactions
    func onTrampolineStarted(_ sheep: Sheep) {
        var count = 0
        for entry in friends.values {
            if count >= 2 { break }
            if !isCalm(entry.sheep) || entry.bubble.visible { continue }
            if entry.sheep === sheep { continue }

            let pool = Self.pick(Self.TRAMPOLINE_REACTIONS, entry.personality)
            let text = Self.pickOne(pool)
            entry.pendingReaction = PendingReaction(
                text: text,
                animation: .bounce,
                delay: 800 + SimRandom.next() * 1500
            )
            count += 1
        }

        Memory.recordInteraction("trampoline by \(sheep.id)")
    }

    /// Update window platforms and check validity
    func setWindowPlatforms(_ platforms: [WindowPlatform]) {
        main.platforms = platforms
        for entry in friends.values {
            entry.sheep.platforms = platforms
        }
    }

    /// Get all bounding boxes for cursor detection
    func getAllBounds() -> [FlockBounds] {
        let pad: Double = 12
        var bounds: [FlockBounds] = []
        bounds.append(FlockBounds(
            x: main.x - pad,
            y: main.y - pad,
            w: main.displaySize + pad * 2,
            h: main.displaySize + pad * 2
        ))
        for entry in friends.values {
            bounds.append(FlockBounds(
                x: entry.sheep.x - pad,
                y: entry.sheep.y - pad,
                w: entry.sheep.displaySize + pad * 2,
                h: entry.sheep.displaySize + pad * 2
            ))
        }
        return bounds
    }

    func updateScreenSize(_ w: Double, _ h: Double) {
        screenWidth = w
        screenHeight = h
        SpeechBubble.viewport = ScreenSize(width: w, height: h)
        main.screenWidth = w
        main.screenHeight = h
        main.reground()
        for entry in friends.values {
            entry.sheep.screenWidth = w
            entry.sheep.screenHeight = h
            entry.sheep.reground()
        }
        nightAmbience.updateScreenSize(w, h)
        easterTheme.updateScreenSize(w, h)
        summerTheme.updateScreenSize(w, h)
    }

    func setSummerMode(_ mode: SummerMode) {
        summerTheme.setModeOverride(mode)
    }

    func setEasterMode(_ mode: EasterMode) {
        easterTheme.setModeOverride(mode)
        if mode == .off && groupActivity?.type == .easterEggHunt {
            clearGroupActivity(true)
        }
    }

    func applyEasterStats(_ stats: EasterStatsSnapshot?) {
        easterTheme.applyStats(stats)
    }

    /// Convenience for callers holding the Brain's full `EasterStats` (the
    /// Tauri IPC did this conversion by serializing it to the snapshot's JSON).
    func applyEasterStats(_ stats: EasterStats) {
        easterTheme.applyStats(Self.snapshot(of: stats))
    }

    /// EasterStats → the snapshot the theme's HUD reads (the JSON bridge the Tauri IPC did).
    static func snapshot(of stats: EasterStats) -> EasterStatsSnapshot? {
        guard let data = try? JSONFile.encoder().encode(stats) else { return nil }
        return try? JSONFile.decoder().decode(EasterStatsSnapshot.self, from: data)
    }

    func setWeatherCondition(_ c: String?, _ tempC: Double? = nil) {
        let prev = weatherEffects.condition
        currentWeatherCondition = c
        weatherEffects.setCondition(c)
        summerTheme.setWeather(c, tempC)
        if let c, !c.isEmpty, c != prev {
            triggerFriendReactions("weather")
            bus.emit(.weatherChanged(condition: c))
        }
    }

    // MARK: Update

    private func sheepPositions() -> [SheepPosition] {
        var positions = [SheepPosition(x: main.x, y: main.y, state: main.state)]
        for entry in friends.values {
            positions.append(SheepPosition(x: entry.sheep.x, y: entry.sheep.y, state: entry.sheep.state))
        }
        return positions
    }

    func update(_ dt: Double) {
        main.update(dt)
        for entry in friends.values {
            entry.sheep.update(dt)
        }

        // Build sheep positions for night ambience
        let positions = sheepPositions()
        nightAmbience.update(dt, positions)
        weatherEffects.update(dt, screenWidth, screenHeight)
        easterTheme.update(dt, positions)
        summerTheme.update(dt, positions)

        // Update speech bubble positions
        mainBubble.updatePosition(main.x, main.y, main.displaySize)
        for entry in friends.values {
            entry.bubble.updatePosition(entry.sheep.x, entry.sheep.y, entry.sheep.displaySize)
        }

        // Process pending friend reactions
        updatePendingReactions(dt)

        // Social tick — probability rolls that assume a 500ms cadence run
        // only on these ticks, not every frame
        socialTimer += dt
        let socialTick = socialTimer > 500
        if socialTick { socialTimer = 0 }

        // Conversations
        updateConversations(dt, socialTick)

        // Reactive emote cooldown
        if reactiveCooldown > 0 { reactiveCooldown -= dt }
        if aiChatCooldown > 0 { aiChatCooldown -= dt }
        if stampedeCooldown > 0 { stampedeCooldown -= dt }

        // Stampede post-dialogue
        if stampedeActive {
            stampedeDialogueTimer -= dt
            // Check if all sheep have stopped stampeding
            let anyStampeding = main.state == .stampede || friends.values.contains { $0.sheep.state == .stampede }
            if !anyStampeding && stampedeDialogueTimer <= 0 {
                stampedeActive = false
                triggerStampedeDialogue()
            }
        }

        // Friend notifications
        checkFriendNotifications(dt)

        // Group activities
        updateGroupActivityLoop(dt, socialTick)

        // Spectacles: run the active scene, else roll the scheduler every 5 min.
        if let scene = spectacle {
            let alive = updateSpectacleScene(scene, dt, spectacleWorld())
            if !alive {
                spectacle = nil
                bus.emit(.spectacleEnded(type: scene.type.rawValue))
                if scene.type == .showdown, let pairIds = scene.pairIds, let resolved = onShowdownResolved {
                    resolved(pairIds, scene.data["reconciled"] == 1)
                }
                // "main" has no friend brain — never pass it to record_spectacle
                // or friend_memory would mint a brain file for it.
                let who: [String]
                if scene.type == .showdown, let pairIds = scene.pairIds {
                    who = [pairIds.0, pairIds.1]
                } else if scene.type == .ufo, let targetId = scene.targetId {
                    who = [targetId]
                } else {
                    who = scene.participants
                }
                recordSpectacle(kind: Self.SPECTACLE_KIND_LABELS[scene.type] ?? scene.type.rawValue,
                                participants: who.filter { $0 != "main" })
            }
        } else if spectacleStateLoaded {
            spectacleCheckTimer += dt
            if spectacleCheckTimer >= SPECTACLE.CHECK_INTERVAL_MS {
                spectacleCheckTimer = 0
                let hour = SimClock.hour()
                let type = pickRandomSpectacle(SchedulerInput(
                    state: spectacleSchedulerState,
                    nowMs: SimClock.nowMs(),
                    isNight: hour >= 20 || hour < 6,
                    rand: SimRandom.next()
                ))
                if let type { startSpectacle(type) }
            }
        }

        // Social behaviors + periodic quips
        if socialTick {
            if groupActivity == nil {
                updateSocialBehaviors()
            }
            updatePeriodicQuips()
        }
    }

    /// ex-`invoke("record_spectacle", …)` (lib.rs): friend memories + affinity
    /// boost + diary entry.
    /// Ids that still exist. A friend removed mid-conversation/activity/
    /// spectacle must not be written back — that would recreate its brain file.
    private func stillPresent(_ ids: [String]) -> [String] {
        ids.filter { $0 == "main" || friends[$0] != nil }
    }

    private func recordSpectacle(kind: String, participants: [String]) {
        let participants = stillPresent(participants)
        guard !participants.isEmpty else { return }
        FriendMemory.recordGroupActivity(participants, kind)
        try? Memory.appendJournal("*A \(kind) happened on the desktop! The flock is still talking about it.*")
    }

    /// Cancel any active conversation — called when AI commentary fires
    func cancelConversation() {
        if activeConversation != nil {
            activeConversation = nil
        }
        clearGroupActivity(true)
    }

    /// A direct chat reply arrived — animate the main sheep and let friends react.
    func onChatReply(_ anim: SheepAnimation?) {
        cancelConversation()
        main.resetActivity()
        if let anim { main.playAnimation(anim) }
        triggerFriendReactions("commentary")
        bus.emit(.aiCommentary(animation: anim))
    }

    // MARK: Draw

    /// Tile anchor that moves 1:1 with a bubble's content: CSS `left`, and
    /// the canvas y of its `bottom` edge (CSS bottom runs opposite to y).
    static func bubbleAnchor(_ b: SpeechBubble) -> CGPoint {
        CGPoint(x: b.left ?? 0, y: SpeechBubble.viewport.height - (b.bottom ?? 0))
    }

    func draw(_ ctx: Canvas) {
        let w = screenWidth
        let h = screenHeight

        // (Night ambience background — stars, moonlight — is SpriteKit-native
        // at z -1000; see `nightAmbience.render` below.)

        // Easter theme background (flowers) — behind sheep
        ctx.group("easter:bg") { easterTheme.drawBackground(ctx, w, h) }

        // Summer sun and glow — behind sheep
        ctx.group("summer:bg") { summerTheme.drawBackground(ctx, w, h) }

        // Easter eggs and grass detail — beneath the flock
        ctx.group("easter:mid") { easterTheme.drawMidground(ctx, w, h) }

        // Sunflowers — beneath the flock
        ctx.group("summer:mid") { summerTheme.drawMidground(ctx, w, h) }

        // Main sheep first (behind friends)
        ctx.group("sheep:main", anchor: CGPoint(x: main.x, y: main.y)) { main.draw(ctx) }
        // Friends on top
        for (id, entry) in friends.entries {
            ctx.group("sheep:\(id)", anchor: CGPoint(x: entry.sheep.x, y: entry.sheep.y)) { entry.sheep.draw(ctx) }
        }

        if let scene = spectacle {
            ctx.group("spectacle") { drawSpectacleScene(scene, ctx, spectacleWorld()) }
        }

        // Easter theme foreground (petals, eggs) — on top of sheep
        ctx.group("easter:fg") { easterTheme.drawForeground(ctx, w, h) }

        // Summer butterflies and drifting seeds — on top of sheep
        ctx.group("summer:fg") { summerTheme.drawForeground(ctx, w, h) }

        // Night ambience (stars/moonlight z -1000, fireflies/campfire glow
        // z 1100) and weather particles (z 1000) are SpriteKit-native: they
        // sync their own nodes instead of drawing into the canvas.
        nightAmbience.render(w, h, sheepPositions())
        weatherEffects.render()

        // Speech bubbles were DOM elements above the canvas; they draw last,
        // in the overlay band above weather and night effects.
        if mainBubble.visible {
            ctx.group("bubble:main", layer: .overlay, anchor: Self.bubbleAnchor(mainBubble)) { mainBubble.draw(ctx) }
        }
        for (id, entry) in friends.entries where entry.bubble.visible {
            ctx.group("bubble:\(id)", layer: .overlay, anchor: Self.bubbleAnchor(entry.bubble)) { entry.bubble.draw(ctx) }
        }
    }

    // MARK: Group activities

    private func updateGroupActivityLoop(_ dt: Double, _ socialTick: Bool) {
        if groupActivityCooldown > 0 {
            groupActivityCooldown -= dt
        }

        if let activity = groupActivity {
            let alive = updateGroupActivity(activity, dt, { self.getSheepById($0) }, easterTheme)
            if !alive {
                clearGroupActivity()
            }
            return
        }

        // Try to start a group activity (only on 500ms social ticks, very rare)
        if !socialTick { return }
        if groupActivityCooldown > 0 { return }
        if activeConversation != nil { return }
        if spectacle != nil { return }
        if friends.count < 2 { return } // need at least 3 total (main + 2 friends)
        if SimRandom.next() > 0.001 { return } // 0.1% per tick

        var sheepList: [(id: String, x: Double, calm: Bool)] = [
            (id: "main", x: main.x, calm: isCalm(main)),
        ]
        for (id, entry) in friends.entries {
            sheepList.append((id: id, x: entry.sheep.x, calm: isCalm(entry.sheep)))
        }

        guard var participants = canStartGroupActivity(sheepList) else { return }
        if let participantFilter {
            participants = participantFilter(participants)
            if participants.count < 3 { return } // feud thinned the group below viability
        }

        // Calculate center of participants
        var sumX: Double = 0
        for id in participants {
            let s = id == "main" ? main : friends[id]?.sheep
            if let s { sumX += s.x }
        }
        let centerX = sumX / Double(participants.count)

        let type = pickActivityType(easterTheme, summerTheme)
        groupActivity = createGroupActivity(type, participants, centerX)
        Log.info("flock", "Group activity started: \(type.rawValue) with \(participants.count) participants")
    }

    /// Called by main.ts when break reminder fires on main sheep
    func echoBreakReminder() {
        if notificationCooldown > 0 { return }
        // Find a calm friend to echo after 5s
        for entry in friends.values {
            if !isCalm(entry.sheep) || entry.bubble.visible { continue }
            let pool = Self.pick(Self.ECHO_MESSAGES, entry.personality)
            let text = Self.pickOne(pool)
            entry.pendingReaction = PendingReaction(text: text, animation: nil, delay: 5000)
            notificationCooldown = 120000
            break
        }
    }

    private func checkFriendNotifications(_ dt: Double) {
        if notificationCooldown > 0 { notificationCooldown -= dt }
        launchTimer += dt

        // Launch greeting — 8s after start, once someone has actually landed
        // (don't burn the one-shot flag while everyone is still parachuting)
        if !hasGreetedOnLaunch && launchTimer > 8000 && friends.count > 0 {
            for entry in friends.values {
                if entry.sheep.state == .parachute { continue } // still landing
                if entry.bubble.visible { continue }
                let pool = Self.pick(Self.GREETINGS, entry.personality)
                let text = Self.pickOne(pool)
                entry.pendingReaction = PendingReaction(
                    text: text,
                    animation: nil,
                    delay: 1000 + SimRandom.next() * 3000
                )
                hasGreetedOnLaunch = true
                notificationCooldown = 120000
                break // only one friend greets
            }
        }

        // Nightfall notifications — when hour crosses 20 or 22
        let hour = SimClock.hour()
        if hour != lastNotificationHour && (hour == 20 || hour == 22 || hour == 0) {
            lastNotificationHour = hour
            if notificationCooldown <= 0 {
                for entry in friends.values {
                    if !isCalm(entry.sheep) || entry.bubble.visible { continue }
                    let pool = Self.pick(Self.NIGHT_MESSAGES, entry.personality)
                    entry.bubble.show(Self.pickOne(pool), duration: 5000)
                    notificationCooldown = 120000
                    break
                }
            }
        }
        if hour != lastNotificationHour && lastNotificationHour != -1 {
            lastNotificationHour = hour
        }
    }

    private func triggerFriendReactions(_ cause: String) {
        if reactiveCooldown > 0 { return }

        // Pick 1-2 calm friends near main sheep
        var count = 0
        for entry in friends.values {
            if count >= 2 { break }
            if !isCalm(entry.sheep) { continue }
            if entry.bubble.visible { continue }
            let dist = abs(entry.sheep.x - main.x)
            if dist > Self.DISPLAY_SIZE * 3 { continue }

            let pool = Self.pick(Self.REACTION_MESSAGES, entry.personality)
            let text = Self.pickOne(pool)
            let anim = Self.REACTION_ANIMS[entry.personality] ?? nil
            entry.pendingReaction = PendingReaction(
                text: text,
                animation: anim,
                delay: 1000 + SimRandom.next() * 2000 // 1-3s delay
            )
            count += 1
        }
        // Only burn the cooldown if someone actually reacted
        if count > 0 { reactiveCooldown = 30000 }
    }

    private func updatePendingReactions(_ dt: Double) {
        for entry in friends.values {
            guard entry.pendingReaction != nil else { continue }
            entry.pendingReaction!.delay -= dt
            if entry.pendingReaction!.delay <= 0 {
                let r = entry.pendingReaction!
                entry.pendingReaction = nil
                if !entry.bubble.visible && isCalm(entry.sheep) {
                    entry.bubble.show(r.text, duration: 3000)
                    if let animation = r.animation {
                        entry.sheep.playAnimation(animation)
                    }
                }
            }
        }
    }

    private func spectacleWorld() -> SpectacleWorld {
        SpectacleWorld(
            getCharacter: { [weak self] id in self?.getSheepById(id) },
            characterIds: { [weak self] in self?.getCharacterIds() ?? [] },
            screenW: screenWidth,
            screenH: screenHeight,
            saveAccessories: saveMainAccessories
        )
    }

    private func getSheepById(_ id: String) -> FlockCharacter? {
        if id == "main" { return FlockCharacter(sheep: main, bubble: mainBubble, personality: nil) }
        if let entry = friends[id] {
            return FlockCharacter(sheep: entry.sheep, bubble: entry.bubble, personality: entry.personality.rawValue)
        }
        return nil
    }

    private func isCalm(_ sheep: Sheep) -> Bool {
        // A listening sheep is parked in "sit" but is busy with the human —
        // conversations, gossip, and group activities must leave it alone
        if sheep.isListening { return false }
        return sheep.state == .idle || sheep.state == .sit || sheep.state == .walk
    }

    private func clearGroupActivity(_ cancelledEarly: Bool = false) {
        guard let activity = groupActivity else { return }

        if activity.type == .easterEggHunt {
            if let huntSummary = activity.huntSummary, huntSummary.finders.contains(where: { $0.eggsFound > 0 }) {
                recordEasterHunt(huntSummary)
            }
            easterTheme.resetEggs()
        }

        if !cancelledEarly {
            let present = stillPresent(activity.participants)
            if !present.isEmpty { FriendMemory.recordGroupActivity(present, activity.type.rawValue) }
            bus.emit(.groupActivity(type: activity.type.rawValue, participants: activity.participants))
        }

        // Release participants from activity-driven states so they don't keep walking toward stale targets
        if cancelledEarly {
            for id in activity.participants {
                if let entry = getSheepById(id) {
                    entry.sheep.walkTarget = nil
                    entry.sheep.state = .idle
                    entry.sheep.stateTimer = 0
                    entry.sheep.stateDuration = 1000 + SimRandom.next() * 2000
                }
            }
        }

        groupActivity = nil
        groupActivityCooldown = 300000 + SimRandom.next() * 300000
    }

    // MARK: Conversations

    private func updateConversations(_ dt: Double, _ socialTick: Bool) {
        if activeConversation != nil {
            activeConversation!.timer -= dt
            if activeConversation!.timer <= 0 {
                let conv = activeConversation!
                if conv.currentIndex >= conv.lines.count {
                    // Conversation finished — record in friend memory
                    let pIds = conv.participants
                    let topic = conv.lines.first.map { Self.prefix30($0.text) } ?? "something"
                    if pIds.count == 2 {
                        if stillPresent([pIds[0], pIds[1]]).count == 2 {
                            FriendMemory.recordConversation(pIds[0], pIds[1], topic)
                        }
                        bus.emit(.conversationHappened(idA: pIds[0], idB: pIds[1], topic: topic))
                    }
                    activeConversation = nil
                    conversationCooldown = 180000 + SimRandom.next() * 120000
                    return
                }
                let line = conv.lines[conv.currentIndex]
                if let target = getSheepById(line.speakerId) {
                    target.bubble.show(line.text, duration: line.duration)
                    if let animation = line.animation {
                        target.sheep.playAnimation(animation)
                    }
                }
                activeConversation?.currentIndex += 1
                // Timer = this line's duration + next line's delay (or 0 if last)
                let next = conv.currentIndex + 1
                let nextDelay = next < conv.lines.count ? conv.lines[next].delay : 0
                activeConversation?.timer = line.duration + nextDelay
            }
            return
        }

        // Cooldown
        if conversationCooldown > 0 {
            conversationCooldown -= dt
            return
        }

        // Try to start a conversation on social ticks (every 500ms)
        // ~2% chance per pair per social tick
        if !socialTick { return }
        var allSheep: [(id: String, sheep: Sheep, bubble: SpeechBubble)] = [
            (id: "main", sheep: main, bubble: mainBubble),
        ]
        for (id, entry) in friends.entries {
            allSheep.append((id: id, sheep: entry.sheep, bubble: entry.bubble))
        }

        for i in 0..<allSheep.count {
            for j in (i + 1)..<allSheep.count {
                let a = allSheep[i]
                let b = allSheep[j]
                if !isCalm(a.sheep) || !isCalm(b.sheep) { continue }
                let dist = abs(a.sheep.x - b.sheep.x)
                if dist > Self.DISPLAY_SIZE * 2 { continue }
                if a.bubble.visible || b.bubble.visible { continue }
                if SimRandom.next() > 0.02 { continue }

                let aEntry = friends[a.id]
                let bEntry = friends[b.id]

                // 30% chance to use AI chat when both friends have personalities and cooldown allows
                if let aEntry, let bEntry, !aiChatPending, aiChatCooldown <= 0,
                   a.id != "main", b.id != "main", SimRandom.next() < 0.3 {
                    startAIConversation(a.id, aEntry, b.id, bEntry)
                    return
                }

                let ctx = ConversationContext(
                    personalityA: aEntry?.personality,
                    personalityB: bEntry?.personality,
                    weather: currentWeatherCondition,
                    hour: SimClock.hour(),
                    easterTheme: easterTheme,
                    recentEasterHunt: easterTheme.hasRecentHuntBuzz(),
                    eggPaintingActive: a.sheep.state == .idleEggPainting || b.sheep.state == .idleEggPainting,
                    summerActive: summerTheme.active
                )
                guard let script = pickConversation(a.id, b.id, ctx) else { continue }

                activeConversation = ActiveConversation(
                    lines: script,
                    currentIndex: 0,
                    timer: 0, // start immediately
                    participants: [a.id, b.id]
                )
                return
            }
        }
    }

    /// JS `text.slice(0, 30)` (UTF-16 units; never leaves half a surrogate pair).
    private static func prefix30(_ text: String) -> String {
        var units = Array(text.utf16.prefix(30))
        if let last = units.last, UTF16.isLeadSurrogate(last), text.utf16.count > units.count {
            units.removeLast()
        }
        return String(decoding: units, as: UTF16.self)
    }

    private func startAIConversation(_ idA: String, _ entryA: FriendEntry, _ idB: String, _ entryB: FriendEntry) {
        aiChatPending = true
        conversationCooldown = 60000 // prevent template convos while waiting

        let chat = friendAIChat
        let nameA = entryA.sheep.name
        let nameB = entryB.sheep.name
        let personalityA = entryA.personality.rawValue
        let personalityB = entryB.personality.rawValue

        aiChatTask = Task { [weak self] in
            do {
                guard let chat else { throw FriendChatUnavailable() }
                let raw = try await chat(idA, nameA, personalityA, idB, nameB, personalityB, nil)
                guard let self else { return }
                self.aiChatPending = false
                self.aiChatCooldown = 600000 // 10 min cooldown for AI chat

                do {
                    guard let script = try Self.parseFriendChatScript(raw, idA: idA, idB: idB, nameB: nameB) else {
                        return
                    }
                    self.activeConversation = ActiveConversation(
                        lines: script,
                        currentIndex: 0,
                        timer: 0,
                        participants: [idA, idB]
                    )
                    Log.info("flock", "AI friend conversation started")
                } catch {
                    Log.info("flock", "error: Failed to parse AI friend chat: \(error)")
                }
            } catch {
                guard let self else { return }
                self.aiChatPending = false
                // Back off on failure too, or a broken backend (offline, no API
                // key) gets re-invoked every time the conversation cooldown lapses
                self.aiChatCooldown = 600000
                Log.info("flock", "error: AI friend chat failed: \(error)")
            }
        }
    }

    /// Turn the model's friend-chat reply (a JSON array of
    /// `{speaker, text, animation?}`, possibly fenced in ```json) into a
    /// script: speaker name → id (B if the name matches, else A), 3.5s lines,
    /// 800ms gaps, only the six valid animations. Returns nil for an empty
    /// array; throws when the text isn't a JSON array of lines. drama-manager's
    /// narration parses the same shape, so it can reuse this.
    static func parseFriendChatScript(_ raw: String, idA: String, idB: String, nameB: String) throws
        -> ConversationScript? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^```json\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "```\\s*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = try JSONDecoder().decode([AIChatLine].self, from: Data(cleaned.utf8))
        if lines.isEmpty { return nil }

        let validAnims = ["bounce", "spin", "backflip", "headshake", "zoom", "vibrate"]
        return lines.enumerated().map { i, line in
            // Map speaker name to ID
            let speakerId = line.speaker == nameB ? idB : idA
            let animation: SheepAnimation? = if let a = line.animation, !a.isEmpty, validAnims.contains(a) {
                SheepAnimation(rawValue: a)
            } else {
                nil
            }
            return ConversationLine(speakerId: speakerId, text: line.text, duration: 3500,
                                    delay: i == 0 ? 0 : 800, animation: animation)
        }
    }

    private func updateSocialBehaviors() {
        for entry in friends.values {
            let friend = entry.sheep
            if friend.state != .idle || friend.walkTarget != nil { continue }

            // Small chance to walk toward another character
            if SimRandom.next() < 0.005 {
                // Pick nearest other character
                var nearestX = main.x
                var nearestDist = abs(friend.x - main.x)

                for other in friends.values {
                    if other.sheep.id == friend.id { continue }
                    let dist = abs(friend.x - other.sheep.x)
                    if dist < nearestDist {
                        nearestDist = dist
                        nearestX = other.sheep.x
                    }
                }

                // Only walk toward if far enough away
                if nearestDist > Self.DISPLAY_SIZE * 3 {
                    friend.walkTarget = nearestX
                }
            }
        }
    }

    private func updatePeriodicQuips() {
        let now = SimClock.nowMs()
        for entry in friends.values {
            if now < entry.nextQuipTime { continue }

            let s = entry.sheep.state
            // Only blurt quips during calm states
            if s == .idle || s == .walk || s == .sit {
                var pool = entry.quips
                if easterTheme.active && easterTheme.hasRecentHuntBuzz() {
                    pool = Self.EASTER_POST_HUNT_QUIPS
                } else if easterTheme.active && SimRandom.next() < 0.35 {
                    pool = Self.EASTER_IDLE_QUIPS
                } else if summerTheme.active && SimRandom.next() < 0.35 {
                    pool = SUMMER_IDLE_QUIPS
                }
                let quip = pool[SimRandom.int(pool.count)]
                entry.bubble.show(quip, duration: 5000)
                // Personality-biased animation to accompany the quip
                let anims = getPersonalityAnimBias(entry.personality)
                if SimRandom.next() < 0.3 {
                    entry.sheep.playAnimation(anims[SimRandom.int(anims.count)])
                }
            }

            // Schedule next quip 45-90s from now
            entry.nextQuipTime = now + 45000 + SimRandom.next() * 45000
        }
    }

    private func attachSeasonalOverlay(_ sheep: Sheep) {
        // Weak on both ends: the sheep owns this closure, and Flock owns the sheep.
        sheep.seasonalOverlay = { [weak self, weak sheep] ctx, x, y, size, facingRight, state in
            guard let self, let sheep else { return }
            if !self.easterTheme.shouldShowBasket(sheep.id) { return }
            let eggCount = max(1, self.easterTheme.getBasketEggCount(sheep.id))
            drawEasterBasket(ctx, x, y, size, facingRight, state,
                             EasterBasketOptions(eggCount: eggCount, allowMoving: true))
        }
    }

    /// ex-`invoke("record_easter_hunt", …).then(applyStats)`.
    private func recordEasterHunt(_ summary: EasterHuntSummary) {
        let hunters = summary.finders.map { finder -> EasterHunterResult in
            let name = getSheepById(finder.id)?.sheep.name
            return EasterHunterResult(
                id: finder.id,
                name: (name?.isEmpty ?? true) ? finder.id : name!,
                eggsFound: finder.eggsFound,
                goldenEggsFound: finder.goldenEggsFound
            )
        }

        let stats = EasterMemory.recordHunt(EasterHuntResult(
            totalEggs: summary.totalEggs,
            durationMs: Int(max(0, summary.durationMs)),
            allCollected: summary.allCollected,
            paintedEggsUsed: summary.paintedEggsUsed,
            hunters: hunters
        ))
        applyEasterStats(stats)
    }

    private func triggerStampedeDialogue() {
        // Find two calm sheep for a post-stampede conversation
        var calmSheep: [(id: String, sheep: Sheep, bubble: SpeechBubble)] = []
        if isCalm(main) && !mainBubble.visible {
            calmSheep.append((id: "main", sheep: main, bubble: mainBubble))
        }
        for (id, entry) in friends.entries {
            if isCalm(entry.sheep) && !entry.bubble.visible {
                calmSheep.append((id: id, sheep: entry.sheep, bubble: entry.bubble))
            }
        }

        if calmSheep.count < 1 { return }

        let first = calmSheep[0]
        first.bubble.show(Self.pickOne(Self.STAMPEDE_QUIPS_A), duration: 4000)
        first.sheep.playAnimation(.vibrate)

        if calmSheep.count >= 2 {
            let second = calmSheep[1]
            second.sheep.resetActivity()
            SimTimers.after(2000) { [weak self] in
                guard let self else { return }
                if self.isCalm(second.sheep) {
                    second.bubble.show(Self.pickOne(Self.STAMPEDE_QUIPS_B), duration: 4000)
                    second.sheep.playAnimation(.headshake)
                }
            }
        }

        conversationCooldown = 30000
    }

    // MARK: Good Colleague's accessories

    /// Draw Good Colleague's accessories: glasses, tie, and coffee mug
    static let drawGoodColleagueOverlay: DrawOverlay = { ctx, x, y, size, facingRight, state in
        let s = size / 32 // scale factor (3)

        // Head position varies with facing direction
        let headX = facingRight ? x + size * 0.65 : x + size * 0.15
        let headY = y + size * 0.3

        // --- Tiny round glasses ---
        ctx.save()
        ctx.strokeStyle = "#2a2a3a"
        ctx.lineWidth = 1.5
        let glassR = 3 * s
        let glassGap = 2.5 * s
        let glassY = headY + 2 * s
        let gl = headX - glassGap / 2 - glassR
        let gr = headX + glassGap / 2 + glassR
        // Left lens
        ctx.beginPath()
        ctx.arc(gl, glassY, glassR, 0, Double.pi * 2)
        ctx.stroke()
        // Right lens
        ctx.beginPath()
        ctx.arc(gr, glassY, glassR, 0, Double.pi * 2)
        ctx.stroke()
        // Bridge
        ctx.beginPath()
        ctx.moveTo(gl + glassR, glassY)
        ctx.lineTo(gr - glassR, glassY)
        ctx.stroke()
        // Lens shine
        ctx.fillStyle = "rgba(180, 220, 255, 0.25)"
        ctx.beginPath()
        ctx.arc(gl, glassY, glassR - 1, 0, Double.pi * 2)
        ctx.fill()
        ctx.beginPath()
        ctx.arc(gr, glassY, glassR - 1, 0, Double.pi * 2)
        ctx.fill()
        ctx.restore()

        // --- Tiny tie ---
        let tieX = facingRight ? x + size * 0.48 : x + size * 0.42
        let tieY = y + size * 0.55
        ctx.save()
        ctx.fillStyle = "#c0392b"
        // Knot
        ctx.fillRect(tieX - 1.5 * s, tieY, 3 * s, 2 * s)
        // Triangle body
        ctx.beginPath()
        ctx.moveTo(tieX - 1.5 * s, tieY + 2 * s)
        ctx.lineTo(tieX + 1.5 * s, tieY + 2 * s)
        ctx.lineTo(tieX, tieY + 7 * s)
        ctx.closePath()
        ctx.fill()
        ctx.restore()

        // --- Coffee mug (only when idle/sitting) ---
        let restingStates: [SheepState] = [.idle, .sit, .idleSleep, .idleCampfire, .idleCounting, .idleEggPainting]
        if restingStates.contains(state) {
            let mugX = facingRight ? x + size * 0.82 : x + size * 0.02
            let mugY = y + size * 0.6
            ctx.save()
            // Mug body
            ctx.fillStyle = "#f5f5f0"
            ctx.fillRect(mugX, mugY, 5 * s, 6 * s)
            // Coffee
            ctx.fillStyle = "#6F4E37"
            ctx.fillRect(mugX + 0.5 * s, mugY + 1 * s, 4 * s, 3 * s)
            // Handle
            ctx.strokeStyle = "#f5f5f0"
            ctx.lineWidth = 1.5
            let handleX = facingRight ? mugX + 5 * s : mugX
            let handleDir: Double = facingRight ? 1 : -1
            ctx.beginPath()
            ctx.arc(handleX, mugY + 3 * s, 2 * s, -Double.pi / 2 * handleDir, Double.pi / 2 * handleDir)
            ctx.stroke()
            // Steam wisps
            let st = SimClock.nowMs() / 800
            ctx.strokeStyle = "rgba(200, 200, 200, 0.4)"
            ctx.lineWidth = 1
            for i in 0..<2 {
                let sx = mugX + (1.5 + Double(i) * 2) * s
                let sy = mugY - 1 * s
                ctx.beginPath()
                ctx.moveTo(sx, sy)
                ctx.quadraticCurveTo(
                    sx + sin(st + Double(i)) * 2 * s,
                    sy - 3 * s,
                    sx + sin(st + Double(i) + 1) * 1.5 * s,
                    sy - 5 * s
                )
                ctx.stroke()
            }
            ctx.restore()
        }
    }
}

import Foundation

// Ex-types.ts. String unions → String-raw enums whose raw values are the
// original strings, so JSON and log output are unchanged.

nonisolated struct ScreenSize: Equatable {
    var width: Double
    var height: Double
}

nonisolated enum SheepState: String, CaseIterable, Codable {
    case parachute, idle, walk, sit, sleep, fall, grabbed, petting
    case bounce, spin, backflip, headshake, zoom, vibrate
    case idleSleep = "idle_sleep"
    case idleCampfire = "idle_campfire"
    case idleCounting = "idle_counting"
    case idleJudging = "idle_judging"
    case idleHearts = "idle_hearts"
    case idleZooming = "idle_zooming"
    case idleSighing = "idle_sighing"
    case stampede, trampoline, stacked
    case idleEggPainting = "idle_egg_painting"
    /// Agent-herd lambs only: trot toward `Sheep.exitDirection`, off-screen.
    case leaving
}

nonisolated enum SheepAnimation: String, CaseIterable, Codable {
    case bounce, spin, backflip, headshake, zoom, vibrate
}

nonisolated let ANIMATIONS: [SheepAnimation] = SheepAnimation.allCases

nonisolated struct CommentaryEvent: Equatable, Codable {
    var text: String
    var animation: SheepAnimation?
}

/// MCP session snapshot pushed to the companion (ex-SessionEvent).
nonisolated struct SessionEvent: Equatable, Codable {
    var kind: String          // begin | task | progress | milestone | end
    var task: String?
    var progress: Double?     // 0..1
    var milestone: String?    // done | failed | blocked | waiting_on_you
    var detail: String?
    var health: String        // good | degraded | failing
}

nonisolated enum FriendColor: String, CaseIterable, Codable {
    case pink, blue, green, gold, purple, orange
}

nonisolated enum FriendPersonality: String, CaseIterable, Codable {
    case snarky, wholesome, chaotic
    case passiveAggressive = "passive-aggressive"
}

nonisolated struct FriendConfig: Equatable, Codable {
    var id: String
    var name: String
    var color: FriendColor
    var personality: FriendPersonality?
    var accessories: [String]?
    var scale: Double?
}

nonisolated struct ConversationLine: Equatable {
    var speakerId: String   // "main", "good_colleague", or a friend id
    var text: String
    var duration: Double    // ms to show
    var delay: Double       // ms to wait before showing (after previous line ends)
    var animation: SheepAnimation?

    init(speakerId: String, text: String, duration: Double, delay: Double, animation: SheepAnimation? = nil) {
        self.speakerId = speakerId
        self.text = text
        self.duration = duration
        self.delay = delay
        self.animation = animation
    }
}

typealias ConversationScript = [ConversationLine]

nonisolated struct WindowPlatform: Equatable, Codable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

nonisolated let FRIEND_TINTS: [FriendColor: String] = [
    .pink: "hsla(330, 70%, 70%, 0.35)",
    .blue: "hsla(210, 70%, 65%, 0.35)",
    .green: "hsla(140, 60%, 55%, 0.35)",
    .gold: "hsla(45, 90%, 60%, 0.35)",
    .purple: "hsla(270, 60%, 65%, 0.35)",
    .orange: "hsla(25, 90%, 60%, 0.35)",
]

/// The slice of `EasterTheme` a `Sheep` needs (sheep.ts: `easterTheme?.active`,
/// `registerPaintedEgg`). Declared here so Sheep and EasterTheme compile
/// independently; `EasterTheme` conforms.
protocol EasterThemeHooks: AnyObject {
    var active: Bool { get }
    func registerPaintedEgg(_ sheepId: String, _ sheepName: String)
}

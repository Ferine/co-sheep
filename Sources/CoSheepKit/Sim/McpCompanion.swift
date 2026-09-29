import Foundation

// Ex-mcp-companion.ts.
// Listens for the backend's `sheep-session` facts (Claude Code narrating its
// work over MCP) and renders them as the main sheep's tsundere reactions.

private enum POOLS {
    // Static tsundere pools — deterministic, testable. One consistent voice.
    static let clock_in = [
        "Oh. We're working now, are we?",
        "Tch. Fine. I was watching anyway.",
        "Back at it. Don't expect applause.",
    ]
    static let new_task = [
        "This again? Predictable.",
        "Hm. Watching you wrestle with this.",
        "Go on then. I'm observing.",
    ]
    static let new_task_labeled: [(String) -> String] = [
        { label in "Watching you wrestle with \"\(label)\" again, hm?" },
        { label in "\"\(label)\". Predictable choice." },
        { label in "So it's \"\(label)\" today. Riveting." },
    ]
    static let progress_mid = [
        "Halfway. Don't get comfortable.",
        "Still going. Barely.",
        "Adequate pace. For you.",
    ]
    static let progress_high = [
        "Almost there. I counted.",
        "Nearly done. Try not to break it now.",
        "So close. Don't fumble it.",
    ]
    static let done = [
        "...Fine. That worked. Don't read into it.",
        "Hmph. Not terrible. For a human.",
        "It's done. I'm as surprised as you.",
    ]
    static let failed = [
        "Tch. Predictable.",
        "Saw that coming three commits ago.",
        "That's the third time. I'm keeping count.",
    ]
    static let blocked = [
        "Your move, sorcerer.",
        "Stuck? Obviously.",
        "I'll wait. Not that I mind.",
    ]
    static let waiting = [
        "*taps foot* Any day now.",
        "Waiting on you. As usual.",
        "Well? I'm right here.",
    ]
    static let clock_out = [
        "Done already? Hmph.",
        "Off you go. I'll be here.",
        "That's a wrap. Don't miss me.",
    ]
}

/// `pool[Math.min(pool.length - 1, Math.floor(rng() * pool.length))]`.
private func pick<T>(_ pool: [T], _ rng: () -> Double) -> T {
    pool[min(pool.count - 1, Int((rng() * Double(pool.count)).rounded(.down)))]
}

private func withDetail(_ text: String, _ detail: String?) -> String {
    if let detail, !detail.isEmpty { return "\(text) (\(detail))" }
    return text
}

func pickReaction(_ ev: SessionEvent, rng: () -> Double = { SimRandom.next() })
    -> (text: String, animation: SheepAnimation?) {
    if ev.kind == "milestone" {
        switch ev.milestone {
        case "failed":
            return (withDetail(pick(POOLS.failed, rng), ev.detail), .headshake)
        case "done":
            return (withDetail(pick(POOLS.done, rng), ev.detail), .bounce)
        case "blocked":
            return (withDetail(pick(POOLS.blocked, rng), ev.detail), .vibrate)
        case "waiting_on_you":
            return (withDetail(pick(POOLS.waiting, rng), ev.detail), .vibrate)
        default:
            break // unknown / missing milestone: falls through like the TS switch
        }
    }
    if ev.kind == "begin" { return (pick(POOLS.clock_in, rng), .bounce) }
    if ev.kind == "end" { return (pick(POOLS.clock_out, rng), nil) }
    if ev.kind == "task" {
        if let task = ev.task, !task.isEmpty {
            return (pick(POOLS.new_task_labeled, rng)(task), nil)
        }
        return (pick(POOLS.new_task, rng), nil)
    }
    if ev.kind == "progress" {
        let p = ev.progress ?? 0
        return (pick(p >= 0.9 ? POOLS.progress_high : POOLS.progress_mid, rng), nil)
    }
    return (pick(POOLS.new_task, rng), nil)
}

/// Listens for backend `sheep-session` facts and renders them through the flock.
final class McpCompanion {
    private let flock: Flock
    private let events: AppEvents
    private var unlisten: (() -> Void)?

    init(_ flock: Flock, events: AppEvents = .shared) {
        self.flock = flock
        self.events = events
    }

    func start() {
        stop()
        // ex-`listen("sheep-session", …)`.
        unlisten = events.sheepSession.on { [weak self] event in
            self?.render(event)
        }
    }

    func stop() {
        unlisten?()
        unlisten = nil
    }

    /// The `sheep-session` handler. Internal so tests can drive it directly.
    func render(_ event: SessionEvent) {
        let (text, animation) = pickReaction(event)
        flock.mainBubble.show(text, duration: 6000)
        flock.onChatReply(animation) // animates main sheep + friend reactions
    }
}

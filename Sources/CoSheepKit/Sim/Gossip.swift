import Foundation

// Ex-gossip.ts.
// Categorizes the frontmost app, tallies the day's time per category, lets a
// calm friend quip when the human switches INTO a category, and has two calm
// friends gossip about it after every full hour spent in one.

nonisolated enum AppCategory: String, CaseIterable, Codable {
    case dev, terminal, social, browser, meetings, music, mail, notes, other
}

/// `CATEGORY_APPS` in declaration order (pass 2 of `categorizeApp` returns the
/// first category with a substring hit, so the order is part of the behavior).
private let CATEGORY_APPS: [(category: AppCategory, names: [String])] = [
    (.dev, ["Code", "Visual Studio Code", "Xcode", "IntelliJ IDEA", "WebStorm", "Zed", "Cursor", "Sublime Text"]),
    (.terminal, ["Terminal", "iTerm2", "Warp", "Ghostty", "kitty", "Alacritty"]),
    (.social, ["Twitter", "X", "Discord", "Slack", "Telegram", "Messages", "WhatsApp", "Signal"]),
    (.browser, ["Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser", "Microsoft Edge"]),
    (.meetings, ["zoom.us", "Microsoft Teams", "FaceTime", "Google Meet", "Webex"]),
    (.music, ["Music", "Spotify", "Tidal"]),
    (.mail, ["Mail", "Microsoft Outlook", "Superhuman", "Mimestream"]),
    (.notes, ["Notes", "Obsidian", "Notion", "Bear"]),
]

func categorizeApp(_ appName: String) -> AppCategory {
    let lower = appName.lowercased()

    // Pass 1: exact match (case-insensitive) across ALL categories first.
    for (category, names) in CATEGORY_APPS {
        if names.contains(where: { lower == $0.lowercased() }) {
            return category
        }
    }

    // Pass 2: substring match, but only for names with length >= 4 to avoid
    // short names (like "X") false-positive matching unrelated apps.
    for (category, names) in CATEGORY_APPS {
        // `.literal`: a plain code-unit search, like JS `String.includes`.
        if names.contains(where: { $0.utf16.count >= 4 && lower.range(of: $0.lowercased(), options: .literal) != nil }) {
            return category
        }
    }

    return .other
}

/// Instant one-liners on switching INTO a category. Personality-neutral.
private let INSTANT_BITS: [AppCategory: [String]] = [
    .dev: ["Ah, the code mines.", "Xcode again? Bold.", "*peers at the syntax*", "May the compiler be gentle."],
    .terminal: ["Back to the green glow.", "*watches the cursor blink*", "Type faster. It's judging you. I'm judging you."],
    .social: ["Ooh, are we procrastinating?", "Say hi from me.", "*leans in to read the drama*"],
    .browser: ["Down the rabbit hole we go.", "How many tabs is that now?", "*pretends not to count the tabs*"],
    .meetings: ["Say baa if you need rescuing.", "*sits very quietly*", "You're muted. Probably."],
    .music: ["*bobs head*", "DJ human, volume up.", "Finally, some culture."],
    .mail: ["Inbox zero is a myth.", "*watches you type 'per my last email'*"],
    .notes: ["Writing things down. Growth.", "*peeks at the notes*"],
    .other: ["What IS that app?", "*squints at the unfamiliar window*"],
]

/// Gossip templates about measured habits. $A/$B placeholders; {hours}/{app} filled.
private let GOSSIP_TEMPLATES: [ConversationScript] = [
    [
        ConversationLine(speakerId: "$A", text: "Hour {hours} in {app}.", duration: 3500, delay: 0),
        ConversationLine(speakerId: "$B", text: "Blink twice if you need help, human.", duration: 4000, delay: 700,
                         animation: .headshake),
    ],
    [
        ConversationLine(speakerId: "$A", text: "{app}. Again. That's hour {hours}.", duration: 4000, delay: 0),
        ConversationLine(speakerId: "$B", text: "We should stage an intervention.", duration: 3500, delay: 700),
        ConversationLine(speakerId: "$A", text: "We ARE the intervention.", duration: 3000, delay: 600,
                         animation: .bounce),
    ],
    [
        ConversationLine(speakerId: "$A", text: "Psst. {hours} hours of {app} today.", duration: 4000, delay: 0),
        ConversationLine(speakerId: "$B", text: "I heard. The whole flock heard.", duration: 3500, delay: 700,
                         animation: .headshake),
    ],
]

private let CATEGORY_LABELS: [AppCategory: String] = [
    .dev: "the editor", .terminal: "the terminal", .social: "the group chats",
    .browser: "the browser", .meetings: "meetings", .music: "the music app",
    .mail: "the inbox", .notes: "the notes app", .other: "that app",
]

private let INSTANT_BIT_COOLDOWN_MS: Double = 10 * 60 * 1000
private let GOSSIP_HOUR_MS: Double = 3600 * 1000
private let CHECK_INTERVAL_MS: Double = 5 * 60 * 1000

/// JS `str.replace(pattern, replacement)` with a string pattern: first hit only.
private func replacingFirst(_ text: String, _ pattern: String, with replacement: String) -> String {
    guard let range = text.range(of: pattern, options: .literal) else { return text }
    var out = text
    out.replaceSubrange(range, with: replacement)
    return out
}

final class GossipManager {
    private let flock: Flock
    /// Internal (not private) so tests can inspect the bookkeeping.
    private(set) var categoryMsToday: [AppCategory: Double] = [:]
    private(set) var gossipedHours: [AppCategory: Int] = [:]
    private(set) var day = SimISO.day(SimClock.nowMs())
    private(set) var lastInstantBit: Double = 0
    private(set) var currentCategory: AppCategory?
    private(set) var lastCreditAt = SimClock.nowMs()
    private var unsubscribeSwitch: (() -> Void)?
    private var checkTimer: TimerToken?

    init(_ flock: Flock) {
        self.flock = flock
    }

    func start() {
        stop()

        unsubscribeSwitch = bus.on(.appSwitched) { [weak self] event in
            guard let self, case .appSwitched(let appSwitch) = event else { return }
            self.onAppSwitched(appSwitch.app)
        }

        checkTimer = SimTimers.every(CHECK_INTERVAL_MS) { [weak self] in
            self?.periodicCheck()
        }
    }

    /// Cancel the 5-minute check and unsubscribe from the bus.
    func stop() {
        checkTimer?.cancel()
        checkTimer = nil
        unsubscribeSwitch?()
        unsubscribeSwitch = nil
    }

    /// The `app-switched` handler. Internal (not private) so tests can drive it.
    func onAppSwitched(_ app: String) {
        rollDay()
        creditElapsed()

        let cat = categorizeApp(app)
        let isNewCategory = cat != currentCategory
        currentCategory = cat

        if isNewCategory {
            // Daily tally (lands in opinions.json → feeds AI "Today's tallies").
            // ex-`invoke("record_app_usage", { category })`.
            Memory.incrementToday("app:\(cat.rawValue)")
            maybeInstantBit(cat)
        }
        maybeGossip(cat)
    }

    /// The 5-minute interval body. Internal so tests can run it directly.
    func periodicCheck() {
        rollDay()
        creditElapsed()
        if let currentCategory { maybeGossip(currentCategory) }
    }

    /// Credit elapsed time since the last credit to the current category.
    private func creditElapsed() {
        let now = SimClock.nowMs()
        if let currentCategory {
            categoryMsToday[currentCategory, default: 0] += now - lastCreditAt
        }
        lastCreditAt = now
    }

    private func rollDay() {
        let today = SimISO.day(SimClock.nowMs())
        if today != day {
            day = today
            categoryMsToday = [:]
            gossipedHours = [:]
        }
    }

    private func maybeInstantBit(_ cat: AppCategory) {
        let now = SimClock.nowMs()
        if now - lastInstantBit < INSTANT_BIT_COOLDOWN_MS { return }

        // A random calm friend delivers the bit.
        let candidates = flock.getCharacterIds().filter { $0 != "main" && flock.isCharacterCalm($0) }
        if candidates.isEmpty { return }
        guard let speaker = flock.getCharacter(candidates[SimRandom.int(candidates.count)]),
              !speaker.bubble.visible else { return }

        let pool = INSTANT_BITS[cat]!
        speaker.bubble.show(pool[SimRandom.int(pool.count)], duration: 4000)
        lastInstantBit = now
    }

    private func maybeGossip(_ cat: AppCategory) {
        let ms = categoryMsToday[cat] ?? 0
        let hours = Int((ms / GOSSIP_HOUR_MS).rounded(.down))
        if hours < 1 { return }
        if (gossipedHours[cat] ?? 0) >= hours { return } // one gossip per hour milestone

        let friends = flock.getCharacterIds().filter { $0 != "main" && flock.isCharacterCalm($0) }
        if friends.count < 2 { return }
        let i = SimRandom.int(friends.count)
        var j = SimRandom.int(friends.count - 1)
        if j >= i { j += 1 }
        let a = friends[i]
        let b = friends[j]

        let appLabel = CATEGORY_LABELS[cat]!
        let template = GOSSIP_TEMPLATES[SimRandom.int(GOSSIP_TEMPLATES.count)]
        let script: ConversationScript = template.map { line in
            var out = line
            out.speakerId = line.speakerId == "$A" ? a : line.speakerId == "$B" ? b : line.speakerId
            out.text = replacingFirst(
                replacingFirst(line.text, "{hours}", with: String(hours)), "{app}", with: appLabel)
            return out
        }

        if flock.startScriptedConversation(script, [a, b]) {
            gossipedHours[cat] = hours
            // Gossip becomes a shared memory + affinity bump via the existing command.
            // ex-`invoke("record_friend_conversation", …)`.
            FriendMemory.recordConversation(a, b, "the human's \(hours)h of \(cat.rawValue)")
        }
    }
}

import Foundation

// The agent herd's shepherd: the main sheep comments on the lambs (one per
// running Claude Code session) now and then, in its own voice, using the
// on-device model. Four pure pieces plus one MainActor driver:
//
//   ShepherdTrigger    what is worth a remark
//   ShepherdScheduler  when (cooldown, dedupe, priority); fed by the herd
//   ShepherdPrompt     the prompt the model gets
//   ShepherdLine       cleaning model output, and static fallback pools
//   Shepherd           glue: scheduler -> model (or fallback) -> speak
//
// Spec: docs/superpowers/specs/2026-10-03-agent-herd-design.md ("Shepherd").

// MARK: - Trigger

/// Something the shepherd could remark on. Names are the lambs' display names
/// (the repo folder).
nonisolated enum ShepherdTrigger: Equatable, Sendable {
    /// A new lamb parachuted in (first arrival in a window).
    case arrival(name: String)
    /// A lamb has been waiting on the human for `minutes`.
    case longWait(name: String, minutes: Int, waitingFor: String?)
    /// A lamb's failure count crossed 3, 6, 10, 15, ...
    case failureStreak(name: String, failures: Int)
    /// A lamb finished a turn after `minutes` of continuous work.
    case longRunFinished(name: String, minutes: Int)
    /// A substantial lamb (long-lived or token-hungry) left the pasture.
    case departed(name: String, tokens: Int, minutes: Int)
    /// The periodic look at the whole herd.
    case herdReview

    /// Short stable label for logs.
    var kind: String {
        switch self {
        case .arrival: "arrival"
        case .longWait: "longWait"
        case .failureStreak: "failureStreak"
        case .longRunFinished: "longRunFinished"
        case .departed: "departed"
        case .herdReview: "herdReview"
        }
    }
}

// MARK: - Scheduler

/// Decides *when* the shepherd speaks. Pure: the caller feeds it every
/// `HerdChange` and a periodic tick with the current sessions and the clock,
/// and it answers with at most one trigger.
///
/// - At most one trigger per `cooldownMs`, globally.
/// - Level triggers (`longWait`, `failureStreak`, `herdReview`) are derived
///   from session state and only consumed when they fire, so the cooldown
///   merely defers them. Edge triggers (`arrival`, `longRunFinished`,
///   `departed`) belong to one change and are dropped when blocked: a comment
///   about a lamb that arrived three minutes ago is stale.
/// - Priority when several are due: longWait > failureStreak > arrival >
///   longRunFinished > departed > herdReview.
nonisolated struct ShepherdScheduler: Equatable, Sendable {
    nonisolated struct Rules: Equatable, Sendable {
        /// Global gap between two lines.
        var cooldownMs: Double = 3 * 60_000
        /// Only the first arrival inside this window gets a line.
        var arrivalWindowMs: Double = 3 * 60_000
        /// A waiting lamb is worth a remark after this long.
        var longWaitMs: Double = 2 * 60_000
        /// A turn that ran this long without a break is worth a remark.
        var longRunMs: Double = 20 * 60_000
        /// A departing lamb is worth a remark after living this long ...
        var departedMinLifeMs: Double = 10 * 60_000
        /// ... or after burning this many tokens.
        var departedMinTokens: Int = 2_000_000
        /// Gap between herd reviews while enough lambs are present.
        var reviewEveryMs: Double = 12 * 60_000
        var reviewMinLambs: Int = 2

        static let standard = Rules()
    }

    private struct WaitKey: Hashable, Sendable {
        var id: String
        var sinceMs: Double
    }

    let rules: Rules

    /// When the last trigger fired (any kind).
    private var lastFiredMs: Double?
    /// When the current arrival window opened.
    private var arrivalWindowStartMs: Double?
    /// The herd has been ≥ `reviewMinLambs` since / was last reviewed at.
    private var reviewAnchorMs: Double?
    /// Live (non-ended) sessions as last seen.
    private var known: [String: AgentSession] = [:]
    /// Wait episodes already announced (session id + phaseSinceMs).
    private var announcedWaits: Set<WaitKey> = []
    /// Highest failure threshold already announced, per session.
    private var failureMark: [String: Int] = [:]
    /// When the current continuous run of work began, per session.
    private var workStartMs: [String: Double] = [:]

    init(rules: Rules = .standard) {
        self.rules = rules
    }

    /// The failure counts that earn a remark: 3, 6, 10, 15, 21, ... (triangular
    /// numbers from 3). Returns the largest one ≤ `n`, nil below 3.
    static func failureThreshold(atMost n: Int) -> Int? {
        guard n >= 3 else { return nil }
        var k = 2
        while (k + 1) * (k + 2) / 2 <= n { k += 1 }
        return k * (k + 1) / 2
    }

    // MARK: Feeding

    /// Fold one change from the herd. Call for every change, even when the
    /// shepherd is muted, so the scheduler's bookkeeping stays right.
    mutating func observe(_ change: HerdChange, nowMs: Double) -> ShepherdTrigger? {
        let s = change.session
        if let old = change.previousId, old != s.id { rekey(old, to: s.id) }

        // Continuous work: opens on the first working/waiting change, closes
        // when the lamb goes idle (turn done, interrupt, stale guard) or ends.
        let runMs = workStartMs[s.id].map { nowMs - $0 }
        switch s.phase {
        case .working, .waiting:
            if workStartMs[s.id] == nil { workStartMs[s.id] = nowMs }
        case .idle, .ended:
            workStartMs[s.id] = nil
        }

        var edge: ShepherdTrigger?
        switch change.beat {
        case .arrived:
            let first = arrivalWindowStartMs.map { nowMs < $0 || nowMs - $0 >= rules.arrivalWindowMs } ?? true
            if first {
                arrivalWindowStartMs = nowMs
                edge = .arrival(name: s.displayName)
            }
        case .turnDone:
            if let runMs, runMs >= rules.longRunMs {
                edge = .longRunFinished(name: s.displayName, minutes: Int(runMs / 60_000))
            }
        case .departed:
            let livedMs = max(0, nowMs - s.startedMs)
            if livedMs >= rules.departedMinLifeMs || s.tokens >= rules.departedMinTokens {
                edge = .departed(name: s.displayName, tokens: s.tokens, minutes: Int(livedMs / 60_000))
            }
        default:
            break
        }

        if s.phase == .ended {
            forget(s.id)
        } else {
            known[s.id] = s
        }
        return decide(edge: edge, nowMs: nowMs)
    }

    /// The periodic look. `sessions` is the herd's current truth (ended
    /// sessions are ignored). Cheap enough for every ~5 s.
    mutating func tick(sessions: [AgentSession], nowMs: Double) -> ShepherdTrigger? {
        known = [:]
        for s in sessions where s.phase != .ended { known[s.id] = s }

        for s in known.values {
            switch s.phase {
            case .working, .waiting: if workStartMs[s.id] == nil { workStartMs[s.id] = nowMs }
            case .idle, .ended: workStartMs[s.id] = nil
            }
        }
        // Forget bookkeeping for sessions that are gone.
        workStartMs = workStartMs.filter { known[$0.key] != nil }
        failureMark = failureMark.filter { known[$0.key] != nil }
        announcedWaits = announcedWaits.filter { known[$0.id] != nil }

        return decide(edge: nil, nowMs: nowMs)
    }

    // MARK: Deciding

    private mutating func decide(edge: ShepherdTrigger?, nowMs: Double) -> ShepherdTrigger? {
        let live = known.values.sorted { $0.id < $1.id }

        // Review clock: runs while enough lambs are present, whether or not
        // anything may fire right now.
        if live.count < rules.reviewMinLambs {
            reviewAnchorMs = nil
        } else if reviewAnchorMs == nil || nowMs < reviewAnchorMs! {
            reviewAnchorMs = nowMs
        }

        if let last = lastFiredMs, nowMs >= last, nowMs - last < rules.cooldownMs { return nil }

        // 1. longWait: the longest-waiting lamb whose episode is unannounced.
        var longest: (session: AgentSession, waitedMs: Double)?
        for s in live where s.phase == .waiting {
            let waitedMs = nowMs - s.phaseSinceMs
            guard waitedMs >= rules.longWaitMs,
                  !announcedWaits.contains(WaitKey(id: s.id, sinceMs: s.phaseSinceMs)) else { continue }
            if longest == nil || waitedMs > longest!.waitedMs { longest = (s, waitedMs) }
        }
        if let (s, waitedMs) = longest {
            announcedWaits.insert(WaitKey(id: s.id, sinceMs: s.phaseSinceMs))
            return fire(.longWait(name: s.displayName, minutes: Int(waitedMs / 60_000), waitingFor: s.waitingFor), nowMs)
        }

        // 2. failureStreak: the worst lamb with an unannounced threshold.
        var worst: (session: AgentSession, threshold: Int)?
        for s in live {
            guard let t = Self.failureThreshold(atMost: s.failures), t > (failureMark[s.id] ?? 0) else { continue }
            if worst == nil || s.failures > worst!.session.failures { worst = (s, t) }
        }
        if let (s, threshold) = worst {
            failureMark[s.id] = threshold
            return fire(.failureStreak(name: s.displayName, failures: s.failures), nowMs)
        }

        // 3-5. arrival / longRunFinished / departed: one change's edge.
        if let edge { return fire(edge, nowMs) }

        // 6. herdReview.
        if let anchor = reviewAnchorMs, nowMs - anchor >= rules.reviewEveryMs {
            reviewAnchorMs = nowMs
            return fire(.herdReview, nowMs)
        }
        return nil
    }

    private mutating func fire(_ trigger: ShepherdTrigger, _ nowMs: Double) -> ShepherdTrigger {
        lastFiredMs = nowMs
        return trigger
    }

    // MARK: Bookkeeping

    /// /clear re-keyed a lamb: its history follows the new id.
    private mutating func rekey(_ old: String, to new: String) {
        known[old] = nil
        if let v = failureMark.removeValue(forKey: old) { failureMark[new] = v }
        if let v = workStartMs.removeValue(forKey: old) { workStartMs[new] = v }
        announcedWaits = Set(announcedWaits.map { $0.id == old ? WaitKey(id: new, sinceMs: $0.sinceMs) : $0 })
    }

    private mutating func forget(_ id: String) {
        known[id] = nil
        failureMark[id] = nil
        workStartMs[id] = nil
        announcedWaits = announcedWaits.filter { $0.id != id }
    }
}

// MARK: - Prompt

nonisolated enum ShepherdPrompt {
    /// Rows in the herd table; the rest are summarised ("+N more").
    static let MAX_ROWS = 10
    /// Names and tool/notification texts are user-controlled: keep them short
    /// and single-line before they reach the model.
    static let FIELD_LIMIT = 40

    static func system(name: String, personality: String, language: String) -> String {
        let name = clean(name).isEmpty ? "Sheep" : clean(name)
        return #"""
You are \#(name), a pixel art sheep who lives on someone's desktop. You are also the shepherd of a small herd of worker lambs. Each lamb is a running Claude Code coding session and is named after the repository it works in. You watch the herd from your corner of the pasture and now and then say a remark about it.

\#(traits(for: personality))

You are told what just happened and shown a table of the herd. Reply with ONE sentence of at most 20 words, spoken out loud, in character.
- Refer to a lamb by its name (exactly as written) when the moment is about one lamb.
- Use only facts from the event and the table. Never invent numbers, files, errors or causes.
- Add a touch of sheep and pasture flavour (wool, grass, fences, flock, bleating), but keep it natural.
- You are not an assistant. Observe and react, in your own voice.
- Plain text only: no markdown, no quotation marks, no hashtags, no labels like "Shepherd:", no JSON. At most one emoji.

LANGUAGE: You MUST write the sentence in \#(language). This is critical — always respond in \#(language), no exceptions.
"""#
    }

    /// One-line voice per personality, in the spirit of the main prompts. The
    /// default snarky voice leans tsundere, like the MCP narration.
    static func traits(for personality: String) -> String {
        switch personality {
        case "wholesome":
            "You're genuinely supportive, warm, and encouraging, and fond of your lambs like a proud shepherd. You use sheep puns warmly."
        case "chaotic":
            "You're UNHINGED. Chaotic energy, zero filter, self-aware desktop pet who finds it hilarious. Your lambs are your beloved little chaos engines."
        case "passive-aggressive":
            "You're the master of backhanded compliments and excessive politeness masking judgment. You keep a mental tally of every lamb."
        default:
            "You're snarky and judgmental, a self-aware desktop pet, and a little tsundere: you pretend not to care about your lambs, but you obviously keep count of every one."
        }
    }

    /// The compact herd table plus what just happened.
    static func user(trigger: ShepherdTrigger, sessions: [AgentSession], nowMs: Double) -> String {
        let live = sessions.filter { $0.phase != .ended }
            .sorted { a, b in
                let (ra, rb) = (rank(a.phase), rank(b.phase))
                if ra != rb { return ra < rb }
                if a.startedMs != b.startedMs { return a.startedMs < b.startedMs }
                return a.id < b.id
            }

        var lines: [String] = []
        if live.isEmpty {
            lines.append("HERD: no lambs in the pasture.")
        } else {
            lines.append("HERD (\(live.count) lamb\(live.count == 1 ? "" : "s"); columns: name | phase | tool | time in phase | age | tokens | failures | waiting for):")
            for s in live.prefix(MAX_ROWS) {
                lines.append(row(s, nowMs: nowMs))
            }
            if live.count > MAX_ROWS { lines.append("(+\(live.count - MAX_ROWS) more lambs further out in the pasture)") }
        }

        return """
\(lines.joined(separator: "\n"))

JUST HAPPENED: \(describe(trigger))

Say your one sentence now.
"""
    }

    private static func rank(_ phase: AgentPhase) -> Int {
        switch phase {
        case .waiting: 0
        case .working: 1
        case .idle: 2
        case .ended: 3
        }
    }

    private static func row(_ s: AgentSession, nowMs: Double) -> String {
        let tool = s.phase == .working ? clean(s.toolName ?? "") : ""
        let toolText = tool.isEmpty ? (s.phase == .working ? s.tool.rawValue : "-") : tool
        let waiting = s.phase == .waiting ? clean(s.waitingFor ?? "") : ""
        return [
            clean(s.displayName),
            s.phase.rawValue,
            toolText,
            duration(ms: nowMs - s.phaseSinceMs),
            duration(ms: nowMs - s.startedMs),
            humanTokens(s.tokens),
            "\(s.failures)",
            waiting.isEmpty ? "-" : waiting,
        ].joined(separator: " | ")
    }

    private static func describe(_ trigger: ShepherdTrigger) -> String {
        switch trigger {
        case .arrival(let name):
            return "A new lamb named \(clean(name)) just parachuted into the pasture."
        case .longWait(let name, let minutes, let waitingFor):
            let on = clean(waitingFor ?? "")
            return "The lamb named \(clean(name)) has been waiting on the human for \(minutesText(minutes))"
                + (on.isEmpty ? "." : " (waiting for: \(on)).")
        case .failureStreak(let name, let failures):
            return "The lamb named \(clean(name)) has now failed \(failures) times."
        case .longRunFinished(let name, let minutes):
            return "The lamb named \(clean(name)) just finished a run of \(minutesText(minutes)) of continuous work and is resting."
        case .departed(let name, let tokens, let minutes):
            return "The lamb named \(clean(name)) has left the pasture after \(minutesText(minutes)), having burned \(humanTokens(tokens)) tokens."
        case .herdReview:
            return "Nothing in particular; it is time for your regular look over the whole herd."
        }
    }

    // MARK: Formatting

    /// Single line, no table separators, collapsed spaces, capped.
    static func clean(_ s: String, limit: Int = FIELD_LIMIT) -> String {
        let flat = s.map { $0.isNewline || $0 == "|" || $0 == "\t" ? " " : $0 }
        let words = String(flat).split(separator: " ", omittingEmptySubsequences: true)
        let joined = words.joined(separator: " ")
        return joined.count > limit ? String(joined.prefix(limit)) : joined
    }

    /// 842, 9.5K, 250K, 1.3M, 16M.
    static func humanTokens(_ n: Int) -> String {
        if n < 1_000 { return "\(max(0, n))" }
        func fmt(_ v: Double) -> String {
            if v >= 10 { return "\(Int(v.rounded()))" }
            let tenths = Int((v * 10).rounded())
            return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
        }
        let k = Double(n) / 1_000
        if k < 999.5 { return fmt(k) + "K" }
        let m = Double(n) / 1_000_000
        if m < 999.5 { return fmt(m) + "M" }
        return fmt(m / 1_000) + "B"
    }

    /// "1 minute", "5 minutes" (never "0 minutes").
    static func minutesText(_ n: Int) -> String {
        n <= 1 ? "1 minute" : "\(n) minutes"
    }

    /// <1m, 4m, 52m, 1h, 1h05m.
    static func duration(ms: Double) -> String {
        let minutes = Int(max(0, ms) / 60_000)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? "\(h)h" : "\(h)h" + (m < 10 ? "0\(m)" : "\(m)") + "m"
    }
}

// MARK: - Line (cleanup + fallbacks)

nonisolated enum ShepherdLine {
    /// Longest line the bubble gets, ellipsis included.
    static let MAX_CHARS = 140

    // MARK: Sanitize

    /// Turn raw model output into one speakable line, or nil when it isn't
    /// one (empty, JSON, a refusal).
    static func sanitize(_ raw: String) -> String? {
        // Fences: drop fence lines (with or without a language tag), keep
        // anything inline.
        var lines: [String] = []
        for original in raw.split(whereSeparator: \.isNewline) {
            var line = String(original).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") {
                line = String(line.drop(while: { $0 == "`" }))
                let tag = line.trimmingCharacters(in: .whitespaces)
                if tag.isEmpty || (!tag.contains(" ") && tag.allSatisfy(\.isLetter) && tag.count <= 12 && tag == tag.lowercased()) {
                    continue
                }
            }
            line = line.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
        }

        let body = lines.joined(separator: "\n")
        if looksLikeJSON(body) { return nil }
        if isRefusal(body) { return nil }

        for line in lines {
            let text = stripQuotes(stripMarkdown(line))
            if text.isEmpty || isPreamble(text) { continue }
            return cap(text)
        }
        return nil
    }

    private static func looksLikeJSON(_ body: String) -> Bool {
        if body.hasPrefix("{") { return true }
        if body.hasPrefix("["), body.hasSuffix("]") { return true }
        return body.contains("\"text\":") || body.contains("\"text\" :")
    }

    /// Phrases that only a refusal or an assistant-ism contains.
    private static let refusalAnywhere = [
        "i'm sorry", "i am sorry", "i apologize", "i apologise", "as an ai", "as a language model",
        "language model", "my guidelines", "content policy", "i'm just an ai",
    ]
    /// Openings that signal a refusal (a legitimate "I can't believe..." that
    /// trips these merely falls back to a static line).
    private static let refusalStarts = [
        "i cannot", "i can't", "i won't", "i'm unable", "i am unable", "i'm not able", "i am not able",
        "sorry", "unfortunately, i", "apologies",
        "beklager", "beklagar", "eg kan ikkje", "jeg kan ikke",
    ]

    private static func isRefusal(_ text: String) -> Bool {
        let norm = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if refusalAnywhere.contains(where: { norm.contains($0) }) { return true }
        return refusalStarts.contains(where: { norm.hasPrefix($0) })
    }

    /// "Sure! Here's a line:" style lead-ins; the real line follows.
    private static func isPreamble(_ text: String) -> Bool {
        let norm = text.lowercased()
        guard norm.hasSuffix(":") else { return false }
        return ["sure", "certainly", "okay", "ok", "here", "of course"].contains { norm.hasPrefix($0) }
    }

    private static func stripMarkdown(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        // Heading / quote / bullet / numbered-list markers.
        if s.hasPrefix("#") {
            let rest = s.drop(while: { $0 == "#" })
            if rest.first == " " { s = String(rest).trimmingCharacters(in: .whitespaces) }
        }
        if s.hasPrefix(">") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        for bullet in ["- ", "* ", "• ", "+ "] where s.hasPrefix(bullet) {
            s = String(s.dropFirst(bullet.count))
            break
        }
        if let dot = s.firstIndex(of: "."), dot != s.startIndex, s[..<dot].count <= 2, s[..<dot].allSatisfy(\.isNumber),
           s[s.index(after: dot)...].hasPrefix(" ") {
            s = String(s[s.index(after: dot)...])
        }
        // Emphasis, strike, code marks.
        for mark in ["**", "__", "~~", "*", "`"] { s = s.replacingOccurrences(of: mark, with: "") }
        // Hashtags.
        let words = s.split(separator: " ", omittingEmptySubsequences: true)
            .filter { !($0.hasPrefix("#") && $0.dropFirst().first?.isLetter == true) }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static let doubleQuotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "\u{201E}", "\u{00AB}", "\u{00BB}"]
    private static let singleQuotes: Set<Character> = ["'", "\u{2018}", "\u{2019}"]

    private static func stripQuotes(_ text: String) -> String {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        var changed = true
        while changed {
            changed = false
            if let f = s.first, doubleQuotes.contains(f) { s = s.dropFirst(); changed = true }
            if let l = s.last, doubleQuotes.contains(l) { s = s.dropLast(); changed = true }
            if s.count >= 2, let f = s.first, let l = s.last, singleQuotes.contains(f), singleQuotes.contains(l) {
                s = s.dropFirst().dropLast()
                changed = true
            }
            s = Substring(s.trimmingCharacters(in: .whitespaces))
        }
        return String(s)
    }

    /// At most `MAX_CHARS` characters including the ellipsis, cut at a word
    /// boundary when there is one.
    static func cap(_ text: String) -> String {
        guard text.count > MAX_CHARS else { return text }
        let chars = Array(text)
        let head = chars[..<(MAX_CHARS - 1)]
        var end = head.count
        if !chars[MAX_CHARS - 1].isWhitespace, let ws = head.lastIndex(where: \.isWhitespace), ws > 0 {
            end = ws
        }
        var out = String(chars[..<end]).trimmingCharacters(in: .whitespaces)
        while let l = out.last, ",;:-–—(".contains(l) { out.removeLast() }
        return out.trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Fallbacks

    /// A static line for `trigger`. Nynorsk gets Nynorsk pools; every other
    /// language gets English. `rng` is [0, 1).
    static func fallback(_ trigger: ShepherdTrigger, language: String, rng: () -> Double) -> String {
        let pools = isNynorsk(language) ? NYNORSK : ENGLISH
        let pool: [String]
        var name = "", minutes = 0, failures = 0, tokens = "", waitingFor = ""
        switch trigger {
        case .arrival(let n):
            pool = pools.arrival; name = n
        case .longWait(let n, let m, let w):
            pool = pools.longWait; name = n; minutes = m
            let cleaned = ShepherdPrompt.clean(w ?? "")
            waitingFor = cleaned.isEmpty ? pools.defaultWaitingFor : cleaned
        case .failureStreak(let n, let f):
            pool = pools.failureStreak; name = n; failures = f
        case .longRunFinished(let n, let m):
            pool = pools.longRunFinished; name = n; minutes = m
        case .departed(let n, let t, let m):
            pool = pools.departed; name = n; tokens = ShepherdPrompt.humanTokens(t); minutes = m
        case .herdReview:
            pool = pools.herdReview
        }
        let template = pool[min(pool.count - 1, max(0, Int((rng() * Double(pool.count)).rounded(.down))))]
        return template
            .replacingOccurrences(of: "{name}", with: ShepherdPrompt.clean(name))
            .replacingOccurrences(of: "{minutes} minutes", with: ShepherdPrompt.minutesText(minutes))
            .replacingOccurrences(of: "{minutes}", with: "\(max(1, minutes))")
            .replacingOccurrences(of: "{failures}", with: "\(failures)")
            .replacingOccurrences(of: "{tokens}", with: tokens)
            .replacingOccurrences(of: "{waitingFor}", with: waitingFor)
    }

    static func isNynorsk(_ language: String) -> Bool {
        language.lowercased().contains("nynorsk")
    }

    nonisolated struct Pools: Sendable {
        var arrival: [String]
        var longWait: [String]
        var failureStreak: [String]
        var longRunFinished: [String]
        var departed: [String]
        var herdReview: [String]
        /// Stands in for `{waitingFor}` when the lamb didn't say.
        var defaultWaitingFor: String
    }

    /// The main sheep's tsundere voice, as in the MCP narration.
    static let ENGLISH = Pools(
        arrival: [
            "A new lamb, {name}. Tch. Stay off my grass.",
            "Oh, {name} showed up. Fine. Don't trample anything.",
            "{name} joined the flock. It's not like I was counting.",
            "{name} just parachuted in. Hmph. Try not to make a mess.",
        ],
        longWait: [
            "{name} has been waiting on you for {minutes} minutes. Not that I care. Go look.",
            "Tch. {name} is stuck at the fence, waiting on you. {minutes} minutes now.",
            "{minutes} minutes, and {name} is still bleating at you. Hello?",
            "{name} is stuck on {waitingFor}, {minutes} minutes and counting. Somebody's slow.",
        ],
        failureStreak: [
            "{name} has failed {failures} times now. I'm not saying I told you so. I am.",
            "That's {failures} failures for {name}. Tch. Predictable.",
            "{name} keeps tripping over the same fence. {failures} falls so far.",
            "{failures} failures on {name}. Do I have to supervise this too?",
        ],
        longRunFinished: [
            "{name} finally stopped after {minutes} minutes. Impressive. Don't tell it I said that.",
            "{minutes} minutes of work, and {name} is done. ...Fine. Good lamb.",
            "{name} is asleep after {minutes} minutes straight. Hmph. Earned it, I suppose.",
        ],
        departed: [
            "{name} left after {minutes} minutes and chewed through {tokens} tokens. Good riddance. ...Mostly.",
            "There goes {name}, sheared and gone. {tokens} tokens of wool. I won't miss it. Much.",
            "{name} trotted off after {minutes} minutes. The pasture's quieter now. Fine.",
        ],
        herdReview: [
            "Look at this flock, all hard at work. Don't think I'm proud.",
            "Another day in the pasture. Keep the lambs fed, human.",
            "Still counting lambs. Everyone's here. Annoyingly.",
            "The herd's doing fine. Not that you were watching.",
        ],
        defaultWaitingFor: "your answer")

    /// Nynorsk: eg / ikkje / berre / noko, a-endingar in the past tense, "lam"
    /// is neuter.
    static let NYNORSK = Pools(
        arrival: [
            "Eit nytt lam, {name}. Tsk. Hald deg unna graset mitt.",
            "Å, {name} dukka opp. Greitt nok. Ikkje tråkk ned noko.",
            "{name} har slutta seg til flokken. Ikkje det at eg tel.",
            "{name} landa i beitet. Hmf. Prøv å ikkje rote det til.",
        ],
        longWait: [
            "{name} har venta på deg i {minutes} minutt. Ikkje det at eg bryr meg. Gå og sjå.",
            "Tsk. {name} står fast ved gjerdet og ventar på deg. {minutes} minutt no.",
            "{minutes} minutt, og {name} ropar framleis på deg. Hallo?",
            "{name} sit fast på {waitingFor}, {minutes} minutt og tel framleis. Nokon er treg.",
        ],
        failureStreak: [
            "{name} har feila {failures} gonger no. Eg seier ikkje at eg sa det. Men eg sa det.",
            "{failures} feil på {name}. Tsk. Heilt føreseieleg.",
            "{name} snublar i same gjerde igjen. {failures} fall så langt.",
            "{failures} feil, {name}? Skal eg passe på dette òg?",
        ],
        longRunFinished: [
            "{name} stoppa endeleg etter {minutes} minutt. Imponerande. Ikkje fortel det vidare.",
            "{minutes} minutt arbeid, og {name} er ferdig. ...Greitt. Flinkt lam.",
            "{name} søv etter {minutes} minutt utan pause. Hmf. Fortent, ser eg.",
        ],
        departed: [
            "{name} drog etter {minutes} minutt og tygde gjennom {tokens} token. Godt å bli kvitt. ...Stort sett.",
            "No trava {name} av garde, klipt og ferdig. {tokens} token med ull. Eg saknar det ikkje. Berre litt.",
            "{name} tuslar av garde etter {minutes} minutt. Det vert stillare på beitet. Greitt nok.",
        ],
        herdReview: [
            "Flokken min jobbar som maur. Ikkje tru eg er stolt.",
            "Ein vanleg dag på beitet. Hald lamma mette, menneske.",
            "Eg tel lam. Alle er her. Irriterande nok.",
            "Flokken har det fint. Ikkje at du følgde med.",
        ],
        defaultWaitingFor: "svaret ditt")
}

// MARK: - Shepherd

/// Drives the commentary: the integrator calls `observe` for every
/// `HerdChange` and `tick` every ~5 s; the shepherd decides, asks the model
/// (or falls back to a static line) and speaks through `speak`.
final class Shepherd {
    /// A hung model call must not wedge the shepherd.
    static let GENERATE_TIMEOUT_SECS = 20.0
    /// A line that took longer than this to arrive is about a moment long gone.
    static let STALE_AFTER_MS = 60_000.0

    private var scheduler: ShepherdScheduler
    private let generate: (_ system: String, _ prompt: String) async throws -> String
    private let speak: (String) -> Void
    private let canSpeak: () -> Bool
    private let isEnabled: () -> Bool
    private let isModelAvailable: () -> Bool
    private let name: () -> String
    private let personality: () -> String
    private let language: () -> String
    private let now: () -> Double
    private let rng: () -> Double
    private let timeoutSecs: Double
    private let staleAfterMs: Double

    /// The generation in flight, kept for tests (`await shepherd.lastTask?.value`).
    private(set) var lastTask: Task<Void, Never>?
    private var generating = false

    /// - Parameters:
    ///   - generate: (system, prompt) -> raw model text.
    ///   - speak: shows the line in the main sheep's bubble.
    ///   - canSpeak: true when the main bubble is free and no chat is open.
    ///   - isEnabled: the `shepherd_commentary` setting.
    ///   - isModelAvailable: false sends every trigger straight to a static line.
    init(
        generate: @escaping (String, String) async throws -> String,
        speak: @escaping (String) -> Void,
        canSpeak: @escaping () -> Bool,
        isEnabled: @escaping () -> Bool,
        isModelAvailable: @escaping () -> Bool,
        name: @escaping () -> String = { Config.getSheepName() ?? "Sheep" },
        personality: @escaping () -> String = { Config.getPersonality() },
        language: @escaping () -> String = { Config.getLanguage() },
        scheduler: ShepherdScheduler = ShepherdScheduler(),
        now: @escaping () -> Double = { SimClock.nowMs() },
        rng: @escaping () -> Double = { SimRandom.next() },
        timeoutSecs: Double = Shepherd.GENERATE_TIMEOUT_SECS,
        staleAfterMs: Double = Shepherd.STALE_AFTER_MS
    ) {
        self.generate = generate
        self.speak = speak
        self.canSpeak = canSpeak
        self.isEnabled = isEnabled
        self.isModelAvailable = isModelAvailable
        self.name = name
        self.personality = personality
        self.language = language
        self.scheduler = scheduler
        self.now = now
        self.rng = rng
        self.timeoutSecs = timeoutSecs
        self.staleAfterMs = staleAfterMs
    }

    /// The production wiring over a `LanguageModel` (`AppleAI`).
    convenience init(
        model: any LanguageModel,
        speak: @escaping (String) -> Void,
        canSpeak: @escaping () -> Bool,
        isEnabled: @escaping () -> Bool
    ) {
        self.init(
            generate: { system, prompt in try await model.generate(system: system, prompt: prompt) },
            speak: speak, canSpeak: canSpeak, isEnabled: isEnabled,
            isModelAvailable: { model.unavailableReason() == nil })
    }

    /// True while a generation is in flight.
    var isGenerating: Bool { generating }

    // MARK: Feeding

    /// One change from the herd. `sessions` is the herd after the change.
    func observe(_ change: HerdChange, sessions: [AgentSession]) {
        let nowMs = now()
        // Always fold the change (even when muted) so the scheduler's
        // bookkeeping stays right; a muted shepherd just drops the trigger.
        guard let trigger = scheduler.observe(change, nowMs: nowMs), isEnabled() else { return }
        var herd = sessions.filter { $0.id != change.session.id }
        herd.append(change.session)
        begin(trigger, sessions: herd, nowMs: nowMs)
    }

    /// The periodic look (~5 s). Skipped while muted, busy or mid-generation:
    /// state-derived triggers aren't consumed then, they fire once it clears.
    func tick(sessions: [AgentSession]) {
        guard isEnabled(), !generating, canSpeak() else { return }
        let nowMs = now()
        guard let trigger = scheduler.tick(sessions: sessions, nowMs: nowMs) else { return }
        begin(trigger, sessions: sessions, nowMs: nowMs)
    }

    // MARK: Generating

    private func begin(_ trigger: ShepherdTrigger, sessions: [AgentSession], nowMs: Double) {
        guard !generating else {
            Log.debug("shepherd", "\(trigger.kind) dropped: a line is already being generated")
            return
        }
        generating = true

        let language = self.language()
        var request: (system: String, prompt: String)?
        if isModelAvailable() {
            request = (
                ShepherdPrompt.system(name: name(), personality: personality(), language: language),
                ShepherdPrompt.user(trigger: trigger, sessions: sessions, nowMs: nowMs))
        }
        lastTask = Task { [self] in
            await run(trigger, request: request, language: language, triggeredAtMs: nowMs)
        }
    }

    private func run(
        _ trigger: ShepherdTrigger, request: (system: String, prompt: String)?, language: String,
        triggeredAtMs: Double
    ) async {
        defer { generating = false }

        var line: String?
        var failure = request == nil ? "model unavailable" : "unusable output"
        if let request {
            let generate = self.generate
            let timeout = timeoutSecs
            do {
                let raw = try await Reflect.withTimeout(
                    seconds: timeout,
                    onTimeout: LanguageModelError("shepherd generate timed out after \(timeout)s")
                ) {
                    try await generate(request.system, request.prompt)
                }
                line = ShepherdLine.sanitize(raw)
            } catch is CancellationError {
                return
            } catch {
                failure = Log.truncateForLog(String(describing: error), maxBytes: 120)
            }
        }
        if Task.isCancelled { return }

        if now() - triggeredAtMs > staleAfterMs {
            Log.debug("shepherd", "\(trigger.kind) dropped: stale")
            return
        }
        guard canSpeak() else {
            Log.debug("shepherd", "\(trigger.kind) dropped: main bubble busy")
            return
        }

        let spoken: String
        let source: String
        if let line {
            spoken = line
            source = "ai"
        } else {
            Log.debug("shepherd", "\(trigger.kind): falling back (\(failure))")
            spoken = ShepherdLine.fallback(trigger, language: language, rng: rng)
            source = "fallback"
        }
        Log.info("shepherd", "\(trigger.kind) [\(source)]: \(spoken)")
        speak(spoken)
    }
}

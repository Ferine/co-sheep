import Foundation

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

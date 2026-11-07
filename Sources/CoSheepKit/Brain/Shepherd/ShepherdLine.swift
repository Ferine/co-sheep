import Foundation

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

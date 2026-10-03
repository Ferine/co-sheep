import CoreGraphics
import Foundation

// Ex-vision.rs — the AI commentary pipeline: capture -> OCR -> classify ->
// (if interesting) comment, the loop that paces it, the chat and friend-chat
// generation, and the response parsing. Prompts, thresholds and timings are
// verbatim; only the plumbing changed: the sidecar is `any LanguageModel`
// (`AppleAI` in production), `app.emit` is `AppEvents`, and the screenshot
// arrives as a `CGImage` instead of a base64 JPEG.

/// A pipeline failure with the plain message the Rust `Box<dyn Error>` carried.
nonisolated struct VisionError: Error, CustomStringConvertible, Equatable {
    var description: String
    init(_ description: String) { self.description = description }
}

/// ex-`ScreenClassification`. serde required all three fields, so a missing
/// `category` fails the parse even though nothing reads it.
nonisolated struct ScreenClassification: Decodable, Equatable {
    var interesting: Bool
    var category: String
    var summary: String
}

/// ex-`ParsedResponse`: the sheep's line plus the optional brain updates.
nonisolated struct ParsedResponse: Equatable {
    var event: CommentaryEvent
    var opinionTopic: String?
    var opinion: String?
    var opinionCategory: String?
    var count: String?
}

/// The platform calls the pipeline makes: screen capture and the screen-recording
/// permission. A seam so tests never touch ScreenCaptureKit or pop the system
/// permission dialog.
struct ScreenAccess {
    /// ex-`capture::capture_screen`.
    var captureScreen: () async throws -> CGImage
    /// ex-`capture::save_debug_screenshot`: writes into the given directory.
    var saveDebugScreenshot: (URL) async throws -> String
    /// ex-`permissions::has_screen_capture_permission`.
    var hasScreenCapturePermission: () -> Bool
    /// ex-`permissions::request_screen_capture_permission`.
    var requestScreenCapturePermission: () -> Void

    static let live = ScreenAccess(
        captureScreen: { try await Capture.captureScreen() },
        saveDebugScreenshot: { try await Capture.saveDebugScreenshot(directory: $0) },
        hasScreenCapturePermission: { Permissions.hasScreenCapturePermission() },
        requestScreenCapturePermission: { Permissions.requestScreenCapturePermission() })
}

final class VisionPipeline {
    /// The Rust loop waited 8 s for the UI before its first check.
    static let STARTUP_DELAY_SECS = 8.0
    /// ... and retried the prerequisites every 30 s.
    static let PREREQUISITE_RETRY_SECS = 30.0

    /// The on-device model has a small (~4k token) context window — keep the
    /// OCR dump well under it so the system prompt and journal still fit.
    static let OCR_BUDGET = 4000
    /// A pasted wall of text would blow the ~4k-token window — same guard the
    /// OCR path has via OCR_BUDGET.
    static let CHAT_MSG_BUDGET = 2000

    static let CLASSIFY_SYSTEM = "You classify screen content for a desktop pet app. Reply only with the requested JSON."
    static let CLASSIFY_PROMPT = "Below is text extracted (OCR) from a screenshot of the user's screen. Guess what app/website is active and whether anything notable is happening (errors, code bugs, social media doom-scrolling, idle desktop, interesting content).\n\nReply ONLY with JSON, no markdown: {\"interesting\": true/false, \"category\": \"string\", \"summary\": \"brief description\"}\n\nMark as interesting if: code with errors, social media scrolling, gaming, unusual content, embarrassing tabs. Mark as NOT interesting if: normal coding, idle desktop, standard productivity work."
    static let COMMENTARY_PROMPT = "Give a short snarky comment (1-2 sentences max) about what you see on this screen. Stay in character. Reference past observations if relevant. Reply with JSON: {\"text\": \"your comment\", \"animation\": \"name_or_null\"}"

    /// Shown when the loop's pipeline error mentions the screen, capture or permission.
    static let SCREEN_ERROR_LINE = "I tried to look at your screen but something went wrong. Check that screen recording is enabled for co-sheep in System Settings > Privacy & Security > Screen Recording."

    private let model: any LanguageModel
    private let screen: ScreenAccess
    private let events: AppEvents
    private let weather: Weather
    private let sleep: (Double) async throws -> Void
    private let nanos: () -> UInt64
    private var loop: Task<Void, Never>?

    /// ex-`COMMENTARY_PAUSED`: the loop skips its pipeline run while set.
    /// "Comment now" ignores it, like the Rust menu handlers did.
    var isPaused = false

    /// ex-`VISION_TICK_RUNNING`: true while a pipeline run is in flight.
    /// Reflection and backfill yield to it.
    /// ex-VISION_TICK_RUNNING. A counter, not a Bool: a "Comment Now" run
    /// overlapping a loop tick must not clear the flag while the other runs.
    private var activeTicks = 0
    var isTickRunning: Bool { activeTicks > 0 }
    /// Last prerequisite failure announced in a bubble (announce on change only).
    private var lastAnnouncedFailure: String?

    /// - Parameters:
    ///   - model: `AppleAI` in production; a fake in tests.
    ///   - sleep: the loop's waits, in seconds. Throwing ends the loop (real
    ///     `Task.sleep` throws on cancel). Injected in tests.
    ///   - nanos: source of the sub-second nanoseconds that seed the interval
    ///     jitter (`SystemTime::now().subsec_nanos()`).
    init(
        model: any LanguageModel,
        screen: ScreenAccess = .live,
        events: AppEvents = .shared,
        weather: Weather = .shared,
        sleep: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        nanos: @escaping () -> UInt64 = { VisionPipeline.subsecNanos() }
    ) {
        self.model = model
        self.screen = screen
        self.events = events
        self.weather = weather
        self.sleep = sleep
        self.nanos = nanos
    }

    // MARK: - Loop (ex-`vision_loop`)

    var isRunning: Bool { loop != nil }

    /// Idempotent. The loop is a `Task` and ends on `stop()`.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// ex-`vision_loop`. Returns only when the loop is cancelled (or the
    /// injected `sleep` throws).
    func run() async {
        Log.info("vision", "loop started, waiting 8s for UI...")
        do { try await sleep(Self.STARTUP_DELAY_SECS) } catch { return }

        var lastFailure: String?
        while true {
            guard let reason = await checkPrerequisites() else { break }
            if lastFailure != reason {
                Log.info("vision", "prerequisites not met: \(reason) (retrying every 30s)")
                lastFailure = reason
            } else {
                Log.debug("vision", "retry: still \(reason)")
            }
            do { try await sleep(Self.PREREQUISITE_RETRY_SECS) } catch { return }
        }
        Log.info("vision", "prerequisites met — entering main vision loop")

        // --- Main vision loop ---
        while true {
            if !isPaused {
                do {
                    try await runVisionPipeline()
                } catch {
                    if Task.isCancelled { return }
                    let msg = Self.describe(error)
                    Log.info("vision", "error: pipeline: \(msg)")

                    // Surface capture/permission errors to the user. A VisionError is
                    // a model-output parse failure whose message quotes the model's
                    // raw reply, which may well mention "the screen".
                    if Self.isCaptureError(error, msg) {
                        events.sheepCommentary.emit(CommentaryEvent(text: Self.SCREEN_ERROR_LINE, animation: nil))
                    }
                }
            }

            // Wait based on configured interval (with ±20% randomization). The
            // Rust interval was a u64; a negative one cannot come from a valid
            // config there, so it clamps to 0 here rather than trapping.
            let base = UInt64(max(0, Config.getIntervalSecs()))
            let delay = Self.nextDelaySecs(base: base, nanos: nanos())
            Log.debug("vision", "next check in \(delay)s (base: \(base)s)")
            do { try await sleep(Double(delay)) } catch { return }
        }
    }

    /// `base - jitter + nanos % (jitter * 2 + 1)` with `jitter = base * 0.2`
    /// truncated: uniformly in `base ± 20%`.
    nonisolated static func nextDelaySecs(base: UInt64, nanos: UInt64) -> UInt64 {
        let jitter = UInt64(Double(base) * 0.2)
        return base - jitter + nanos % (jitter * 2 + 1)
    }

    /// `SystemTime::now().duration_since(UNIX_EPOCH).subsec_nanos()`.
    nonisolated static func subsecNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return UInt64(ts.tv_nsec)
    }

    /// Checks the on-device model, screen permission, and does a test capture.
    /// Emits user-facing messages via speech bubble for each failure.
    /// Returns nil if everything is ready, else the failure reason.
    func checkPrerequisites() async -> String? {
        // 1. Check the on-device Apple Intelligence model
        if let reason = model.unavailableReason() {
            Log.debug("vision", "Apple Intelligence unavailable: \(reason)")
            let msg = switch reason {
            case "appleIntelligenceNotEnabled":
                "Apple Intelligence is turned off! Enable it in System Settings > Apple Intelligence & Siri, then I can think locally."
            case "modelNotReady":
                "Apple Intelligence is still downloading its model... I'll keep checking. Baa-tience."
            case "deviceNotEligible", "requiresMacOS26":
                "This Mac can't run Apple Intelligence — I need Apple Silicon and macOS 26 to think. Sorry!"
            default:
                "I can't reach the on-device Apple Intelligence model. Check System Settings > Apple Intelligence & Siri."
            }
            announceFailure("apple intelligence: \(reason)", msg)
            return "apple intelligence: \(reason)"
        }
        Log.debug("vision", "Apple Intelligence is available")

        // 2. Check screen capture permission by actually trying a capture.
        if !screen.hasScreenCapturePermission() {
            Log.debug("vision", "CGPreflight says no permission — requesting dialog")
            screen.requestScreenCapturePermission()
        }

        // 3. Test capture — the real permission check
        do {
            _ = try await screen.captureScreen()
            Log.debug("vision", "Test capture succeeded — vision pipeline ready")
        } catch {
            let msg = Self.describe(error)
            Log.debug("vision", "Test capture failed: \(msg)")
            announceFailure("capture",
                "I can't capture your screen! Add me to System Settings > Privacy & Security > Screen Recording, then restart me.")
            return "capture: \(msg)"
        }

        lastAnnouncedFailure = nil
        return nil
    }

    /// The Rust loop re-emitted the bubble on every 30s retry, forever (e.g.
    /// on a Mac that can't run Apple Intelligence). Say it once per reason.
    private func announceFailure(_ reason: String, _ text: String) {
        guard lastAnnouncedFailure != reason else { return }
        lastAnnouncedFailure = reason
        events.sheepCommentary.emit(CommentaryEvent(text: text, animation: nil))
    }

    /// Model calls in the pipeline and friend chat get the same deadline as
    /// reflection: a hung call must not stall the loop, pin the tick flag
    /// (blocking reflection) or leave the flock's AI-chat flag set.
    static let MODEL_TIMEOUT_SECS = 120.0

    private func generateWithTimeout(_ what: String, system: String, prompt: String) async throws -> String {
        let model = self.model
        return try await Reflect.withTimeout(
            seconds: Self.MODEL_TIMEOUT_SECS,
            onTimeout: LanguageModelError("\(what) timed out after \(Int(Self.MODEL_TIMEOUT_SECS))s")
        ) {
            try await model.generate(system: system, prompt: prompt)
        }
    }

    // MARK: - Pipeline (ex-`run_vision_pipeline`)

    /// One tick: capture, OCR, classify and, when interesting, comment. Sets
    /// the tick flag for the whole run, including when it throws.
    func runVisionPipeline() async throws {
        activeTicks += 1
        defer { activeTicks -= 1 }

        Log.info("vision", "tick: capturing")

        // Log preflight status but don't block — actual capture is the real test
        if !screen.hasScreenCapturePermission() {
            Log.debug("vision", "Preflight says no permission, attempting capture anyway...")
        }

        let screenshot = try await screen.captureScreen()

        // The on-device model is text-only — OCR the screenshot once and feed
        // the recognized text to both passes instead of the image
        Log.debug("vision", "OCR-ing screen...")
        let screenText = try await model.ocr(screenshot)
        Log.debug("vision", "OCR: \(screenText.utf8.count) chars")

        // Pass 1: Classification
        Log.debug("vision", "Pass 1: Classifying screen...")
        let classification = try await classifyScreen(screenText)
        Log.info(
            "vision",
            "classified: \(classification.summary) (\(classification.interesting ? "interesting" : "boring"))")

        if !classification.interesting {
            Log.debug("vision", "Not interesting, skipping commentary")
            try? Memory.appendJournal("Glanced at screen. \(classification.summary). Nothing worth commenting on.")
            return
        }

        // Pass 2: Commentary (only when interesting)
        Log.debug("vision", "Pass 2: Generating commentary...")
        let recentContext = (try? Memory.getRecentContext(query: screenText)) ?? ""
        let rawResponse = try await generateCommentary(
            screenText, context: classification.summary, recentJournal: recentContext)
        Log.info("vision", "raw: \(Log.rawForLog(rawResponse))")

        // Parse structured response
        let parsed = Self.parseCommentaryResponse(rawResponse)
        Log.info("vision", "💬 \"\(parsed.event.text)\" [\(parsed.event.animation?.rawValue ?? "-")]")
        if let topic = parsed.opinionTopic, parsed.opinion != nil {
            Log.info("vision", "opinion: [\(topic)]")
        }

        // Save/update opinion if the sheep formed one
        saveOpinionAndCount(parsed, logCount: true)

        // Record that a comment was made
        Memory.recordComment()

        // Emit structured commentary to frontend
        events.sheepCommentary.emit(parsed.event)
        Log.debug("vision", "Commentary emitted to frontend")

        // Log to daily journal
        try? Memory.appendJournal(
            "\(classification.summary)\n**Comment**: \(parsed.event.text) [animation: \(Self.debugAnimation(parsed.event.animation))]")
    }

    /// Opinion + daily counter side effects shared by the screen pipeline and chat.
    private func saveOpinionAndCount(_ parsed: ParsedResponse, logCount: Bool) {
        if let topic = parsed.opinionTopic, let opinion = parsed.opinion {
            let category = parsed.opinionCategory ?? "opinion"
            try? Memory.saveOpinion(topic: topic, opinion: opinion, category: category)
        }

        // Increment daily counter if the sheep is tracking something
        if let key = parsed.count {
            let n = Memory.incrementToday(key)
            if logCount { Log.info("vision", "count: \(key) = \(n) today") }
        }
    }

    /// Rust `{:?}` of the `Option<String>` animation, as journalled.
    nonisolated static func debugAnimation(_ animation: SheepAnimation?) -> String {
        animation.map { "Some(\"\($0.rawValue)\")" } ?? "None"
    }

    // MARK: - On-device generation

    func classifyScreen(_ screenText: String) async throws -> ScreenClassification {
        let screenText = truncateUTF8(screenText, maxBytes: Self.OCR_BUDGET)
        let prompt = "Screen text:\n\(screenText)\n\n\(Self.CLASSIFY_PROMPT)"
        let raw = try await generateWithTimeout("classify", system: Self.CLASSIFY_SYSTEM, prompt: prompt)
        return try Self.parseClassification(raw)
    }

    func generateCommentary(_ screenText: String, context: String, recentJournal: String) async throws -> String {
        let weatherCtx = await weather.getWeatherContext()
        let systemPrompt = Personality.getSystemPrompt(recentJournal: recentJournal, weatherContext: weatherCtx)
        let screenText = truncateUTF8(screenText, maxBytes: Self.OCR_BUDGET)
        let prompt = "Context: \(context)\n\nText visible on the screen (OCR):\n\(screenText)\n\n\(Self.COMMENTARY_PROMPT)"
        return try await generateWithTimeout("commentary", system: systemPrompt, prompt: prompt)
    }

    // MARK: - Chat (text-only, for conversation mode)

    /// ex-`chat_with_sheep`. The reply is returned, not emitted: the chat
    /// bubble owns display.
    func chatWithSheep(_ userMessage: String, history: [HistoryTurn]) async throws -> CommentaryEvent {
        let userMessage = truncateUTF8(userMessage, maxBytes: Self.CHAT_MSG_BUDGET)
        let recentContext = (try? Memory.getRecentContext(query: userMessage)) ?? ""
        let weatherCtx = await weather.getWeatherContext()
        let systemPrompt = Personality.getChatPrompt(recentContext: recentContext, weatherContext: weatherCtx)

        // Replay the (frontend-capped) session transcript as a native Transcript
        // in the model. Sheep turns go in as the JSON shape the model is asked
        // to produce — it imitates its own prior replies, so plain-text history
        // collapses JSON compliance (0/6 plain vs 6/6 wrapped; folding history
        // into the prompt instead made it parrot old lines. Measured 2026-07-03).
        let historyPayload = history.map { turn in
            HistoryTurn(
                role: turn.role,
                text: turn.role == "sheep" ? Self.sheepTurnJSON(turn.text) : turn.text)
        }

        let rawResponse = try await model.generateChat(
            system: systemPrompt, prompt: userMessage, history: historyPayload)

        Log.info("vision", "chat raw: \(Log.rawForLog(rawResponse))")
        let parsed = Self.parseCommentaryResponse(rawResponse)

        // Save opinion if formed
        saveOpinionAndCount(parsed, logCount: false)

        Memory.recordInteraction("chatted with")
        try? Memory.appendJournal(
            "Human said: \"\(userMessage)\"\n**Reply**: \(parsed.event.text) [animation: \(Self.debugAnimation(parsed.event.animation))]")

        // The chat bubble owns display now — no sheep-commentary emit
        return parsed.event
    }

    /// `serde_json::json!({ "text": text, "animation": null }).to_string()`:
    /// compact, and with serde_json's default sorted keys, `animation` first.
    nonisolated static func sheepTurnJSON(_ text: String) -> String {
        let value = JSONValue.object(["text": .string(text), "animation": .null])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Friend-to-friend AI chat

    /// ex-`friend_chat`: returns the model's raw text (a JSON array the
    /// overlay parses).
    func friendChat(
        friendAId: String,
        friendAName: String,
        friendAPersonality: String,
        friendBId: String,
        friendBName: String,
        friendBPersonality: String,
        topic: String?
    ) async throws -> String {
        let systemPrompt = Self.friendChatSystemPrompt(
            friendAId: friendAId, friendAName: friendAName, friendAPersonality: friendAPersonality,
            friendBId: friendBId, friendBName: friendBName, friendBPersonality: friendBPersonality)

        let userMsg = if let topic {
            "Generate a conversation between \(friendAName) and \(friendBName). Context: \(topic)"
        } else {
            "Generate a conversation between \(friendAName) and \(friendBName)."
        }

        let raw = try await generateWithTimeout("friend chat", system: systemPrompt, prompt: userMsg)

        Log.info("vision", "friend chat raw: \(Log.rawForLog(raw))")
        return raw
    }

    static func friendChatSystemPrompt(
        friendAId: String, friendAName: String, friendAPersonality: String,
        friendBId: String, friendBName: String, friendBPersonality: String
    ) -> String {
        let language = Config.getLanguage()
        let memorySection = "\(FriendMemory.getChatContext(friendAId, friendBId))\n\(FriendMemory.getChatContext(friendBId, friendAId))"

        // The template sits at column 0 on purpose (indentation is content).
        return #"""
You are writing a short conversation between two desktop sheep friends.
\#(friendAName) is \#(friendAPersonality). \#(friendBName) is \#(friendBPersonality).
Write a 2-4 line exchange. Keep it SHORT, funny, and in character. They are pixel sheep living on someone's desktop.

LANGUAGE: Write in \#(language).

Reply with ONLY a JSON array, no markdown:
[{"speaker": "\#(friendAName)", "text": "...", "animation": "bounce"}, {"speaker": "\#(friendBName)", "text": "...", "animation": null}]

Valid animations: "bounce", "spin", "headshake", "vibrate", "zoom", null

WHAT THEY KNOW:
\#(memorySection)
Let their history color the exchange subtly — a callback, a grudge, warmth. Don't recite it.
"""#
    }

    // MARK: - Parsing

    /// Rust `trim().trim_start_matches("```json").trim_start_matches("```")
    /// .trim_end_matches("```").trim()`.
    nonisolated static func stripMarkdownFences(_ raw: String) -> String {
        var s = raw.rustTrimmed()
        s = trimStartMatches(s, "```json")
        s = trimStartMatches(s, "```")
        s = trimEndMatches(s, "```")
        return s.rustTrimmed()
    }

    /// Rust `trim_start_matches(pat)`: strips every leading repetition of `pat`.
    private nonisolated static func trimStartMatches(_ s: String, _ pat: String) -> String {
        var scalars = Substring(s).unicodeScalars
        let p = Array(pat.unicodeScalars)
        while scalars.starts(with: p) { scalars = scalars.dropFirst(p.count) }
        return String(scalars)
    }

    private nonisolated static func trimEndMatches(_ s: String, _ pat: String) -> String {
        var scalars = Substring(s).unicodeScalars
        let p = Array(pat.unicodeScalars)
        while scalars.suffix(p.count).elementsEqual(p) { scalars = scalars.dropLast(p.count) }
        return String(scalars)
    }

    /// Parse the response as JSON {text, animation, ...}, falling back to plain text.
    nonisolated static func parseCommentaryResponse(_ raw: String) -> ParsedResponse {
        let trimmed = stripMarkdownFences(raw)

        // The on-device model bends types (count as a number, animation as a
        // bool) — parse into a Value and coerce per field, so one bent field
        // doesn't dump raw JSON into the speech bubble
        if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
           let text = v["text"]?.stringValue
        {
            func strField(_ key: String) -> String? {
                switch v[key] {
                case .string(let s) where !s.isEmpty: s
                case .number(let n): numberString(n)
                default: nil
                }
            }
            let animation = strField("animation").flatMap(SheepAnimation.init(rawValue:))
            return ParsedResponse(
                event: CommentaryEvent(text: text, animation: animation),
                opinionTopic: strField("opinion_topic"),
                opinion: strField("opinion"),
                opinionCategory: strField("opinion_category"),
                count: strField("count"))
        }

        // Truncated mid-generation: salvage the text field so the bubble shows
        // the sheep's words, not a JSON fragment
        if let text = extractTextField(trimmed) {
            Log.info("vision", "salvaged text from truncated JSON")
            return ParsedResponse(event: CommentaryEvent(text: text, animation: nil))
        }

        Log.info("vision", "error: unparseable response, using raw text")
        return ParsedResponse(event: CommentaryEvent(text: raw.rustTrimmed(), animation: nil))
    }

    /// serde_json's `Number::to_string()`: integers without a fraction.
    private nonisolated static func numberString(_ n: Double) -> String {
        if n.rounded() == n, abs(n) < 9.0e15 { return String(Int64(n)) }
        return String(n)
    }

    /// Pull the value of `"text"` out of malformed or truncated JSON. Returns
    /// the full string if its closing quote survived, a `…`-suffixed prefix if
    /// the string itself was cut off, and nil if there's nothing usable.
    nonisolated static func extractTextField(_ s: String) -> String? {
        let scalars = s.unicodeScalars
        let key = Array("\"text\"".unicodeScalars)
        guard let keyRange = scalars.firstRange(of: key) else { return nil }
        let afterKey = scalars[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        var rest = afterKey[afterKey.index(after: colon)...]
        while let f = rest.first, f.properties.isWhitespace { rest = rest.dropFirst() }
        guard rest.first == "\"" else { return nil }
        rest = rest.dropFirst()

        var out = String.UnicodeScalarView()
        var it = rest.makeIterator()
        while let c = it.next() {
            switch c {
            case "\"":
                return out.isEmpty ? nil : String(out)
            case "\\":
                guard let next = it.next() else { return unterminated(out) }
                switch next {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "u": if let s = Self.unicodeEscape(&it) { out.append(s) }
                default: out.append(next)
                }
            default:
                out.append(c)
            }
        }
        return unterminated(out)
    }

    /// The model was cut off mid-sentence. A trailing fragment still beats raw
    /// JSON if there's enough of it.
    private nonisolated static func unterminated(_ out: String.UnicodeScalarView) -> String? {
        guard out.count > 10 else { return nil }
        var s = out
        s.append("…")
        return String(s)
    }

    nonisolated static func parseClassification(_ text: String) throws -> ScreenClassification {
        let jsonStr = stripMarkdownFences(text)
        do {
            return try JSONDecoder().decode(ScreenClassification.self, from: Data(jsonStr.utf8))
        } catch {
            throw VisionError("Failed to parse classification: \(serdeStyle(error)) — raw: \(jsonStr)")
        }
    }

    /// The reason part of a serde error, as close as Foundation's errors allow.
    private nonisolated static func serdeStyle(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return describe(error) }
        return switch e {
        case .keyNotFound(let key, _): "missing field `\(key.stringValue)`"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx): ctx.debugDescription
        @unknown default: "\(e)"
        }
    }

    /// The scalar of a JSON `\uXXXX` escape (the `\u` already consumed),
    /// joining a `\uD83D\uDE00` surrogate pair. nil when malformed/truncated.
    nonisolated static func unicodeEscape(_ it: inout some IteratorProtocol<Unicode.Scalar>) -> Unicode.Scalar? {
        func hex4() -> UInt32? {
            var hex = String.UnicodeScalarView()
            while hex.count < 4, let h = it.next() { hex.append(h) }
            return hex.count == 4 ? UInt32(String(hex), radix: 16) : nil
        }
        guard let code = hex4() else { return nil }
        guard (0xD800..<0xDC00).contains(code) else { return Unicode.Scalar(code) }
        guard it.next() == "\\", it.next() == "u", let low = hex4(), (0xDC00..<0xE000).contains(low) else { return nil }
        return Unicode.Scalar(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00))
    }

    // MARK: - Errors

    /// Whether a pipeline error means we couldn't look at the screen.
    nonisolated static func isCaptureError(_ error: any Error, _ msg: String) -> Bool {
        if error is VisionError { return false }
        return msg.contains("screen") || msg.contains("capture") || msg.contains("permission")
    }

    /// The Rust `e.to_string()`: our own error types carry their message;
    /// system errors (ScreenCaptureKit, URLSession, ...) use their localized text.
    nonisolated static func describe(_ error: any Error) -> String {
        if type(of: error) is NSError.Type { return error.localizedDescription }
        return String(describing: error)
    }
}

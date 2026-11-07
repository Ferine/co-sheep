import Foundation

// The agent herd's shepherd: the main sheep comments on the lambs (one per
// running Claude Code session) now and then, in its own voice, using the
// on-device model. Four pure pieces plus one MainActor driver, one file each:
//
//   ShepherdTrigger    what is worth a remark
//   ShepherdScheduler  when (cooldown, dedupe, priority); fed by the herd
//   ShepherdPrompt     the prompt the model gets
//   ShepherdLine       cleaning model output, and static fallback pools
//   Shepherd           glue: scheduler -> model (or fallback) -> speak
//
// Spec: docs/superpowers/specs/2026-10-03-agent-herd-design.md ("Shepherd").

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
        // bookkeeping stays right. A trigger that can't be spoken right now
        // (muted, mid-generation, bubble busy) is released untried: a level
        // trigger stays due and fires once it clears, like `tick`'s.
        guard let trigger = scheduler.observe(change, nowMs: nowMs) else { return }
        let claim = scheduler.lastClaim
        guard isEnabled() else {
            scheduler.release(claim, keepCooldown: false)
            return
        }
        guard !generating, canSpeak() else {
            Log.debug("shepherd", "\(trigger.kind) deferred: \(generating ? "a line is already being generated" : "main bubble busy")")
            scheduler.release(claim, keepCooldown: false)
            return
        }
        var herd = sessions.filter { $0.id != change.session.id }
        herd.append(change.session)
        begin(trigger, claim, sessions: herd, nowMs: nowMs)
    }

    /// The periodic look (~5 s). Skipped while muted, busy or mid-generation:
    /// state-derived triggers aren't consumed then, they fire once it clears.
    func tick(sessions: [AgentSession]) {
        guard isEnabled(), !generating, canSpeak() else { return }
        let nowMs = now()
        guard let trigger = scheduler.tick(sessions: sessions, nowMs: nowMs) else { return }
        begin(trigger, scheduler.lastClaim, sessions: sessions, nowMs: nowMs)
    }

    // MARK: Generating

    private func begin(
        _ trigger: ShepherdTrigger, _ claim: ShepherdScheduler.Claim?, sessions: [AgentSession], nowMs: Double
    ) {
        guard !generating else {
            Log.debug("shepherd", "\(trigger.kind) dropped: a line is already being generated")
            scheduler.release(claim, keepCooldown: false)
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
            await run(trigger, claim, request: request, language: language, triggeredAtMs: nowMs)
        }
    }

    private func run(
        _ trigger: ShepherdTrigger, _ claim: ShepherdScheduler.Claim?,
        request: (system: String, prompt: String)?, language: String, triggeredAtMs: Double
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
                scheduler.release(claim, keepCooldown: false)
                return
            } catch {
                failure = Log.truncateForLog(String(describing: error), maxBytes: 120)
            }
        }
        if Task.isCancelled {
            scheduler.release(claim, keepCooldown: false)
            return
        }

        // Dropped after a line was attempted: the trigger is handed back, but
        // the cooldown stands.
        if now() - triggeredAtMs > staleAfterMs {
            Log.debug("shepherd", "\(trigger.kind) dropped: stale")
            scheduler.release(claim, keepCooldown: true)
            return
        }
        guard canSpeak() else {
            Log.debug("shepherd", "\(trigger.kind) dropped: main bubble busy")
            scheduler.release(claim, keepCooldown: true)
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
        scheduler.commit(claim)
        speak(spoken)
    }
}

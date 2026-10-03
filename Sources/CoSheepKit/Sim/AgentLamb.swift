import Foundation

// One Claude Code session on the desktop: a lamb. It owns a `Sheep` (so it
// drags, stacks, trampolines and stampedes like any other sheep), a speech
// bubble, the folded `AgentSession`, and the visual state `LambDraw.swift`
// paints: wool, props, shearing particles, lamblets. Behaviour is driven by
// the session's phase through `sheep.idleOverride`. Spec:
// docs/superpowers/specs/2026-10-03-agent-herd-design.md ("Lambs").
//
// Time. Everything here runs on `animMs`, the lamb's own clock (the sum of
// the `dt`s it was updated with), not on wall time: it is deterministic in
// tests and it pauses with the sim. Wall time (`SimClock`) is only used for
// the age on the hover card, because sessions carry epoch timestamps.

/// Wool tiers: the pixtuoid token thresholds. `level` is the tier (0...3);
/// `amount` adds continuous growth inside the tier (log-scaled, every tier is
/// 8x the previous one) so the wool never jumps.
nonisolated enum WoolMeter {
    static let tiers: [Int] = [250_000, 2_000_000, 16_000_000]
    static let maxAmount: Double = 4

    static func level(forTokens tokens: Int) -> Int {
        tiers.filter { tokens >= $0 }.count
    }

    /// 0 ..< 1 below the first tier, then `level + progress through the tier`,
    /// capped at 4 (8x past the last tier).
    static func amount(forTokens tokens: Int) -> Double {
        let t = Double(max(0, tokens))
        let level = level(forTokens: tokens)
        if level == 0 { return t / Double(tiers[0]) }
        let lo = Double(tiers[level - 1])
        let progress = log(t / lo) / log(8)
        return min(maxAmount, Double(level) + min(1, max(0, progress)))
    }
}

/// The wool a lamb currently shows: eased toward the target so growth is a
/// slow swell, and zeroed by shearing.
nonisolated struct WoolState: Equatable {
    /// Eased display amount, 0...4.
    private(set) var shown: Double = 0
    /// Tokens already shorn off: wool grows from the tokens spent since.
    private(set) var baseline = 0

    /// Display amount in 1/16 steps: identical display lists between steps.
    var quantized: Double { (shown * 16).rounded(.down) / 16 }
    var level: Int { Int(shown.rounded(.down)) }

    mutating func ease(_ dt: Double, tokens: Int) {
        if tokens < baseline { baseline = tokens } // the store restarted its count
        let target = WoolMeter.amount(forTokens: tokens - baseline)
        shown += (target - shown) * (1 - exp(-dt / 700))
        if abs(target - shown) < 0.002 { shown = target }
    }

    /// Wool pops off: nothing left, and the tokens so far stop counting.
    mutating func shear(atTokens tokens: Int) {
        shown = 0
        baseline = tokens
    }

    /// Effective tokens (after shearing) for the level readout.
    func effectiveTokens(_ tokens: Int) -> Int { max(0, tokens - baseline) }
}

/// A tuft of wool flying off during shearing. Position is analytic in age so
/// the draw can quantize time to the 8 fps step.
nonisolated struct WoolParticle: Equatable {
    var x0: Double
    var y0: Double
    var vx: Double // pt/s
    var vy: Double // pt/s
    var birthMs: Double
    /// Radius of the puff in art pixels (1 or 2).
    var size: Double
    var shade: Bool
    /// Where the ground is under it: wool settles there instead of falling through.
    var floorY: Double

    static let LIFE_MS: Double = 1500
    static let GRAVITY: Double = 320 // pt/s^2
}

final class AgentLamb {
    // MARK: Constants

    static let SCALE: Double = 0.72
    /// Non-urgent bubbles wait this long after any previous bubble.
    static let BUBBLE_COOLDOWN_MS: Double = 8000
    /// A waiting lamb bleats again this often.
    static let REBLEAT_MS: Double = 45_000
    /// Shearing burst to the start of the exit trot.
    static let SHEAR_TO_LEAVE_MS: Double = 1500
    /// A departing lamb that never makes it off-screen (held, stuck) is dropped.
    static let DEPARTURE_TIMEOUT_MS: Double = 90_000
    /// Animation time is quantized to 8 fps: pixel-art cadence, and equal
    /// display lists between steps let the tile cache skip the raster.
    static let STEP_MS: Double = 125
    /// Speech bubbles and the hover card sit this far above the sprite top,
    /// clear of the marks (?, thought cloud, notes) that rise over the head.
    static let BUBBLE_LIFT: Double = 20
    static let SHORN_FADE_MS: Double = 20_000
    static let MAX_LAMBLETS = 3

    // MARK: State

    let sheep: Sheep
    let bubble: SpeechBubble
    private(set) var session: AgentSession
    /// Wool/bubble colour key. Fixed at creation: `Sheep.tint` is immutable.
    let colorKey: String
    let colors: LambColors
    /// 1 for the first lamb of a repo, 2 for the next, ... (set by `Herd`).
    private(set) var ordinal = 1
    private(set) var sharesRepo = false
    /// The repo name the current label was built from (nil until labelled).
    private(set) var labelBase: String?

    private(set) var animMs: Double = 0
    private(set) var isDeparting = false
    private var departedAtMs: Double = 0
    /// Open once the shearing beat is over: the lamb may start trotting off.
    private(set) var canLeave = false
    private var leaveAtMs: Double = 0

    private var lastBubbleMs: Double = -.infinity
    private var nextBleatMs: Double?
    var pendingReaction: (text: String, delayMs: Double)?

    // Visual state read by LambDraw
    private(set) var wool = WoolState()
    private(set) var particles: [WoolParticle] = []
    private(set) var shornAtMs: Double?
    private(set) var exclaimUntil: Double = 0
    private(set) var startledUntil: Double = 0
    private(set) var dizzyUntil: Double = 0
    private(set) var chewUntil: Double = 0
    /// Screen-space x offset (art pixels, from the sprite's left edge) of each
    /// trailing lamblet. Moves on 8 fps steps only.
    var lamblets: [Double] = []
    private var lastStep = 0

    // MARK: Init

    /// `sheepId` is "lamb:<session id>" unless the herd needs it unique (a
    /// session demoted and promoted again while its old lamb is still leaving).
    init(session: AgentSession, screenWidth: Double, screenHeight: Double, startX: Double,
         platforms: [WindowPlatform] = [], sheepId: String? = nil) {
        self.session = session
        colorKey = session.repoKey ?? session.cwd ?? session.id
        colors = LambColors(hue: HerdPalette.hue(forRepoKey: colorKey), solid: HerdPalette.solid(forRepoKey: colorKey))
        sheep = Sheep(screenWidth, screenHeight, sheepId ?? "lamb:\(session.id)",
                      HerdPalette.tint(forRepoKey: colorKey), startX, Self.SCALE)
        bubble = SpeechBubble(listenToCommentary: false, borderColor: HerdPalette.solid(forRepoKey: colorKey))
        sheep.name = session.displayName
        sheep.platforms = platforms
        sheep.idleOverride = { [weak self] in self?.nextBehavior() }
        sheep.drawOverlay = { [weak self] ctx, x, y, size, facingRight, state in
            self?.drawLamb(ctx, x, y, size, facingRight, state)
        }
        if session.phase == .waiting { nextBleatMs = Self.REBLEAT_MS }
    }

    var id: String { session.id }
    var phase: AgentPhase { session.phase }

    /// `repoName`, with " #2", " #3" when several lambs share a repo (the
    /// first lamb of a repo keeps the plain name).
    func setLabel(ordinal: Int, shared: Bool) {
        self.ordinal = ordinal
        sharesRepo = shared
        let base = session.displayName
        labelBase = base
        sheep.name = (shared && ordinal > 1) ? "\(base) #\(ordinal)" : base
    }

    var woolLevel: Int { WoolMeter.level(forTokens: wool.effectiveTokens(session.tokens)) }

    /// Time since the departure began (0 while not departing).
    var departingForMs: Double { isDeparting ? animMs - departedAtMs : 0 }

    /// True once the lamb should be removed from the herd.
    var isGone: Bool {
        sheep.hasLeft || (isDeparting && departingForMs > Self.DEPARTURE_TIMEOUT_MS)
    }

    // MARK: Phase -> behaviour

    /// `sheep.idleOverride`: what the lamb does next when an idle period ends.
    private func nextBehavior() -> (state: SheepState, duration: Double)? {
        if isDeparting {
            if canLeave {
                sheep.detachFromStack()
                return (.leaving, 0)
            }
            return (.idle, max(250, leaveAtMs - animMs))
        }
        switch session.phase {
        case .working:
            // Mostly sits with its prop; now and then wanders a few steps.
            if SimRandom.next() < 0.2 {
                sheep.facingRight = SimRandom.next() > 0.5
                return (.walk, 2000 + SimRandom.next() * 2000)
            }
            return (.sit, 6000 + SimRandom.next() * 6000)
        case .waiting:
            return (.idle, 3000 + SimRandom.next() * 2000)
        case .idle:
            return (.sleep, 20000 + SimRandom.next() * 20000)
        case .ended:
            sheep.detachFromStack()
            return (.leaving, 0)
        }
    }

    /// The state a phase change redirects a calm lamb into right away.
    func behavior(for phase: AgentPhase) -> (state: SheepState, duration: Double)? {
        switch phase {
        case .working: (.sit, 6000 + SimRandom.next() * 6000)
        case .waiting: (.idle, 3000 + SimRandom.next() * 2000)
        case .idle: (.sleep, 20000 + SimRandom.next() * 20000)
        case .ended: nil
        }
    }

    // MARK: Changes

    /// A brand-new lamb has just parachuted into the herd.
    func arrive(announce: Bool) {
        if session.phase == .waiting {
            bleat()
        } else if announce {
            say(Self.pick(LambLines.arrival).replacingOccurrences(of: "%@", with: sheep.name))
        }
    }

    /// Fold a change for this session into the lamb: phase redirect first,
    /// then the one-shot beat (so a beat's animation wins over the redirect).
    func apply(_ change: HerdChange) {
        let old = session
        session = change.session
        guard !isDeparting else { return }

        if session.phase != old.phase {
            phaseChanged(from: old.phase)
        }
        if let beat = change.beat { react(to: beat) }
        if session.phase == .ended, !isDeparting { depart(sheared: false) }
    }

    private func phaseChanged(from old: AgentPhase) {
        if session.phase == .waiting {
            nextBleatMs = animMs + Self.REBLEAT_MS
            bleat()
        } else if old == .waiting {
            nextBleatMs = nil
        }
        if let next = behavior(for: session.phase) {
            sheep.redirect(next.state, next.duration)
        }
    }

    private func react(to beat: HerdBeat) {
        switch beat {
        case .arrived:
            break // announced by `arrive` when the lamb is created
        case .turnDone:
            play(.bounce)
            if SimRandom.next() < 0.4 { say(Self.pick(LambLines.turnDone)) }
        case .toolFailed:
            play(.headshake)
            exclaimUntil = animMs + 1400
        case .permissionDenied:
            play(.headshake)
            say("Fine. No \(session.toolName ?? "that").")
        case .apiError:
            play(.spin)
            dizzyUntil = animMs + 3000
            say("Baa?? (\(Self.friendlyError(session.lastError)))")
        case .interrupted:
            play(.bounce)
            startledUntil = animMs + 1200
        case .compacted:
            chewUntil = animMs + 9000
            say(Self.pick(LambLines.compacted))
        case .cleared:
            shear()
            say("Fresh start. Cold, though.")
        case .departed:
            depart(sheared: true)
        }
    }

    private func play(_ animation: SheepAnimation) {
        guard !isDeparting else { return }
        sheep.playAnimation(animation)
    }

    // MARK: Bubbles

    /// Show a bubble. Non-urgent lines respect the lamb's own cooldown;
    /// urgent ones (waiting, departed) always go through.
    @discardableResult
    func say(_ text: String, urgent: Bool = false, duration: Double = 4500) -> Bool {
        if !urgent && animMs - lastBubbleMs < Self.BUBBLE_COOLDOWN_MS { return false }
        bubble.show(text, duration: duration)
        lastBubbleMs = animMs
        return true
    }

    /// "Baa? Need you: Bash" + a vibrate. Urgent.
    func bleat() {
        let what = Self.shorten(session.waitingFor ?? session.toolName, 32)
        let line = Self.pick(LambLines.waiting)
        say(what.isEmpty ? "Baa? Need you." : line.replacingOccurrences(of: "%@", with: what),
            urgent: true, duration: 5000)
        play(.vibrate)
    }

    // MARK: Shearing and leaving

    /// Wool bursts off as particles and the meter restarts from nothing.
    func shear() {
        let px = Sheep.SCALE * Self.SCALE
        let flip = !sheep.facingRight
        func world(_ gx: Double, _ gy: Double) -> (Double, Double) {
            ((sheep.x + (flip ? 32 - gx : gx) * px), (sheep.y + gy * px))
        }
        let centre = world(15, 17)
        var sources: [(Double, Double)] = []
        for puff in LambDraw.puffLayout(amount: wool.quantized) {
            for k in 0..<3 {
                let jitter = Double(k) - 1
                sources.append(world(Double(puff.cx) + jitter * puff.radius * 0.5, Double(puff.cy) - jitter * puff.radius * 0.3))
            }
        }
        // The body wool pops too, even on a lamb with no extra fluff.
        for _ in 0..<10 {
            sources.append(world(6 + SimRandom.next() * 16, 11 + SimRandom.next() * 11))
        }
        for (x, y) in sources {
            var dx = x - centre.0
            var dy = y - centre.1
            let len = max(1, (dx * dx + dy * dy).squareRoot())
            dx /= len
            dy /= len
            let speed = 50 + SimRandom.next() * 80
            particles.append(WoolParticle(
                x0: x, y0: y,
                vx: dx * speed + (SimRandom.next() - 0.5) * 30,
                vy: dy * speed * 0.6 - (60 + SimRandom.next() * 70),
                birthMs: animMs,
                size: SimRandom.next() < 0.5 ? 1 : 2,
                shade: SimRandom.next() < 0.3,
                floorY: sheep.y + sheep.displaySize - 3 * px - 2 * px * SimRandom.next()))
        }
        wool.shear(atTokens: session.tokens)
        shornAtMs = animMs
    }

    /// The session is over. Shearing departures burst first and trot off
    /// 1.5 s later; quiet ones (herd switched off, lamb demoted) just go.
    func depart(sheared: Bool) {
        guard !isDeparting else { return }
        isDeparting = true
        departedAtMs = animMs
        nextBleatMs = nil
        pendingReaction = nil
        if sheared {
            shear()
            if session.tokens >= 1000 {
                say("Sheared: \(Self.formatTokens(session.tokens)) tokens of wool!", urgent: true, duration: 5000)
            }
            leaveAtMs = animMs + Self.SHEAR_TO_LEAVE_MS
        } else {
            bubble.hide()
            leaveAtMs = animMs
            canLeave = true
            attemptLeave()
        }
    }

    /// Start the exit trot if the lamb is in a state that can. Airborne,
    /// grabbed and mid-animation lambs leave once they've landed (the idle
    /// override takes over); stacked and petted ones are pulled out directly.
    private func attemptLeave() {
        guard canLeave, sheep.state != .leaving, !sheep.hasLeft else { return }
        switch sheep.state {
        case .stacked, .petting:
            sheep.detachFromStack()
            sheep.startLeaving()
        default:
            if sheep.redirect(.leaving, 0) { sheep.detachFromStack() }
        }
    }

    // MARK: Update

    func update(_ dt: Double) {
        animMs += dt
        sheep.update(dt)
        wool.ease(dt, tokens: session.tokens)

        // Waiting lambs bleat again every 45 s.
        if session.phase == .waiting, !isDeparting, let next = nextBleatMs, animMs >= next {
            nextBleatMs = animMs + Self.REBLEAT_MS
            bleat()
        }

        if isDeparting {
            if !canLeave, animMs >= leaveAtMs { canLeave = true }
            attemptLeave()
        }

        if var reaction = pendingReaction {
            reaction.delayMs -= dt
            if reaction.delayMs <= 0 {
                pendingReaction = nil
                if !isDeparting {
                    if say(reaction.text) { play(.bounce) }
                }
            } else {
                pendingReaction = reaction
            }
        }

        particles.removeAll { animMs - $0.birthMs >= WoolParticle.LIFE_MS }

        let step = Int((animMs / Self.STEP_MS).rounded(.down))
        if step != lastStep {
            lastStep = step
            stepLamblets()
        }
        bubble.updatePosition(sheep.x, sheep.y - Self.BUBBLE_LIFT, sheep.displaySize)
    }

    /// Lamblets trail the lamb: each step they close in on their spot behind
    /// it, so a walking lamb drags a little line of followers.
    private func stepLamblets() {
        let count = isDeparting ? 0 : min(Self.MAX_LAMBLETS, session.subagents)
        if lamblets.count > count { lamblets.removeLast(lamblets.count - count) }
        let dir: Double = sheep.facingRight ? 1 : -1
        for i in 0..<count {
            let target = (sheep.facingRight ? 4.0 : 28.0) - dir * (10 + 12 * Double(i))
            if i >= lamblets.count {
                lamblets.append(target)
            } else {
                let delta = target - lamblets[i]
                lamblets[i] += max(-3, min(3, delta))
            }
        }
    }

    /// The 8 fps animation step everything in LambDraw is a function of.
    var animStep: Int { Int((animMs / Self.STEP_MS).rounded(.down)) }

    // MARK: Interaction

    func randomQuip() -> String {
        Self.pick(LambLines.quips)
    }

    /// Petting: a content line, ignoring the bubble cooldown (the human asked).
    func pettedLine() {
        say(Self.pick(LambLines.petted), urgent: true, duration: 3000)
    }

    /// A trampoline show nearby: cheer after a beat.
    func reactToTrampoline() {
        guard !isDeparting, pendingReaction == nil else { return }
        pendingReaction = (Self.pick(LambLines.trampoline), 800 + SimRandom.next() * 1500)
    }

    /// Is this lamb calm enough to react to the neighbourhood?
    var isCalm: Bool {
        !isDeparting && (sheep.state == .idle || sheep.state == .sit || sheep.state == .walk || sheep.state == .sleep)
    }

    func teardown() {
        sheep.detachFromStack()
        sheep.idleOverride = nil
        sheep.drawOverlay = nil
        bubble.destroy()
    }

    // MARK: Hover card text

    /// The three lines of the hover card.
    func cardLines(nowMs: Double = SimClock.nowMs()) -> [String] {
        let title = Self.shorten(session.title, 34)
        let line1 = title.isEmpty ? session.displayName : title
        let line2 = "\u{03A3} \(Self.formatTokens(session.tokens)) \u{00B7} \(session.toolCalls) tools \u{00B7} "
            + Self.formatAge(nowMs - session.startedMs)
        return [line1, line2, phaseLine]
    }

    var phaseLine: String {
        switch session.phase {
        case .working:
            return "working: \(session.toolName ?? Self.kindWord(session.tool))"
        case .waiting:
            let what = Self.shorten(session.waitingFor ?? session.toolName, 30)
            return "waiting: \(what.isEmpty ? "you" : what)"
        case .idle:
            return "asleep"
        case .ended:
            return "leaving"
        }
    }

    // MARK: Pure helpers

    static func pick(_ items: [String]) -> String {
        items[SimRandom.int(items.count)]
    }

    /// `950`, `12.3K`, `2.4M`.
    nonisolated static func formatTokens(_ n: Int) -> String {
        if n < 1000 { return "\(max(0, n))" }
        let v = Double(n)
        if v < 999_950 { return String(format: "%.1fK", v / 1000) }
        if v < 999_950_000 { return String(format: "%.1fM", v / 1_000_000) }
        return String(format: "%.1fB", v / 1_000_000_000)
    }

    /// `<1m`, `14m`, `1h05m`.
    nonisolated static func formatAge(_ ms: Double) -> String {
        let minutes = Int(max(0, ms) / 60_000)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh%02dm", minutes / 60, minutes % 60)
    }

    /// Trim to `limit` characters with an ellipsis; nil/blank becomes "".
    nonisolated static func shorten(_ text: String?, _ limit: Int) -> String {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard t.count > limit else { return t }
        return String(t.prefix(max(1, limit - 1))) + "\u{2026}"
    }

    /// StopFailure error types (and a few neighbours) in plain words.
    nonisolated static func friendlyError(_ raw: String?) -> String {
        let e = (raw ?? "").lowercased()
        if e.isEmpty || e == "unknown" { return "something broke" }
        if e.contains("rate_limit") || e.contains("rate limit") || e.contains("429") { return "rate limited" }
        if e.contains("overloaded") || e.contains("529") { return "servers overloaded" }
        if e.contains("server_error") || e.contains("server error") || e.contains("500") { return "server hiccup" }
        if e.contains("authentication") || e.contains("auth") || e.contains("401") { return "login trouble" }
        if e.contains("billing") || e.contains("402") { return "billing trouble" }
        if e.contains("invalid_request") || e.contains("invalid request") { return "bad request" }
        if e.contains("max_output") || e.contains("max output") { return "ran out of room" }
        if e.contains("timeout") || e.contains("network") || e.contains("connection") { return "connection trouble" }
        return shorten(e.replacingOccurrences(of: "_", with: " "), 24)
    }

    nonisolated static func kindWord(_ kind: ToolKind) -> String {
        switch kind {
        case .thinking: "thinking"
        case .edit: "editing"
        case .bash: "running a command"
        case .read: "reading"
        case .web: "browsing"
        case .subagent: "calling a subagent"
        case .plan: "planning"
        case .mcp: "calling a tool"
        case .ask: "asking"
        case .compacting: "compacting"
        case .other: "tinkering"
        }
    }
}

/// The lamb's lines. Short and whimsical; `%@` is filled in by the caller.
nonisolated enum LambLines {
    static let arrival = [
        "Baa! %@ reporting for duty.",
        "%@ has landed. Baa.",
        "Parachute out. %@ is here.",
        "Baa-rrived! %@ on the job.",
    ]
    static let waiting = [
        "Baa? Need you: %@",
        "Baa-hello? Need you: %@",
        "Psst, human. Need you: %@",
    ]
    static let turnDone = [
        "Done! Your move.",
        "Turn finished. Baa-rilliant.",
        "Over to you, human.",
        "That's a wrap. Nap time.",
    ]
    static let compacted = [
        "*chew chew* Tidying up the context.",
        "Chewing it over. Context, that is.",
        "Munch. Making room to think.",
    ]
    static let petted = [
        "Baa... scritches accepted.",
        "Mmm. Warm hooves, cold wool.",
        "Keep going. The agent can wait.",
        "...that's the spot.",
    ]
    static let trampoline = [
        "Baa! Did that sheep just fly?",
        "Whoa. Do I get a turn?",
        "Higher! HIGHER!",
        "10/10 form. Baa.",
    ]
    static let quips = [
        "Baa! I'm mid-thought. Literally.",
        "Careful, that's my agent's desk.",
        "Tokens don't count themselves. Well, they do.",
        "I'm just here for the wool.",
        "Poking a working lamb. Bold.",
        "Baa-sically I'm a build server with legs.",
        "The agent is cooking. I'm supervising.",
        "Click me to jump to my terminal!",
        "Wool level: concerning.",
        "If I shut my eyes, do the tests pass?",
        "Don't mind me. Counting tool calls.",
        "Is it lunch? My context is full.",
    ]
}

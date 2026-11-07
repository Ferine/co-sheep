import Foundation

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
/// - A fired trigger is a claim the driver settles: `commit` once the line was
///   spoken, `release` when it was dropped (muted, busy, stale), which hands
///   back what firing consumed so a level trigger is due again instead of
///   silently marked as announced.
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

    /// Handle for one fired trigger, settled with `commit` or `release`.
    nonisolated struct Claim: Hashable, Sendable {
        fileprivate let serial: Int
    }

    /// What firing one trigger consumed, so `release` can hand it back.
    private struct Outstanding: Equatable, Sendable {
        var firedMs: Double = 0
        var previousFiredMs: Double?
        var wait: WaitKey?
        var failureId: String?
        var previousFailureMark: Int?
        var reviewed = false
        var previousReviewAnchorMs: Double?
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
    /// Fired triggers the driver hasn't settled yet.
    private var outstanding: [Claim: Outstanding] = [:]
    private var nextClaimSerial = 0
    /// The claim for the trigger `observe` / `tick` returned last.
    private(set) var lastClaim: Claim?

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
            let key = WaitKey(id: s.id, sinceMs: s.phaseSinceMs)
            announcedWaits.insert(key)
            return fire(.longWait(name: s.displayName, minutes: Int(waitedMs / 60_000), waitingFor: s.waitingFor),
                        nowMs, Outstanding(wait: key))
        }

        // 2. failureStreak: the worst lamb with an unannounced threshold.
        var worst: (session: AgentSession, threshold: Int)?
        for s in live {
            guard let t = Self.failureThreshold(atMost: s.failures), t > (failureMark[s.id] ?? 0) else { continue }
            if worst == nil || s.failures > worst!.session.failures { worst = (s, t) }
        }
        if let (s, threshold) = worst {
            let previous = failureMark[s.id]
            failureMark[s.id] = threshold
            return fire(.failureStreak(name: s.displayName, failures: s.failures),
                        nowMs, Outstanding(failureId: s.id, previousFailureMark: previous))
        }

        // 3-5. arrival / longRunFinished / departed: one change's edge.
        if let edge { return fire(edge, nowMs, Outstanding()) }

        // 6. herdReview.
        if let anchor = reviewAnchorMs, nowMs - anchor >= rules.reviewEveryMs {
            reviewAnchorMs = nowMs
            return fire(.herdReview, nowMs, Outstanding(reviewed: true, previousReviewAnchorMs: anchor))
        }
        return nil
    }

    private mutating func fire(_ trigger: ShepherdTrigger, _ nowMs: Double, _ undo: Outstanding) -> ShepherdTrigger {
        var undo = undo
        undo.firedMs = nowMs
        undo.previousFiredMs = lastFiredMs
        let claim = Claim(serial: nextClaimSerial)
        nextClaimSerial += 1
        outstanding[claim] = undo
        lastClaim = claim
        lastFiredMs = nowMs
        return trigger
    }

    // MARK: Settling

    /// The claimed trigger was spoken: what it consumed stays consumed.
    mutating func commit(_ claim: Claim?) {
        guard let claim else { return }
        outstanding[claim] = nil
    }

    /// The claimed trigger was never spoken. Hand back what firing it
    /// consumed: a level trigger (longWait, failureStreak, herdReview) is due
    /// again; an edge trigger is one change's news and stays dropped.
    /// `keepCooldown` keeps the global gap when a line was actually attempted
    /// (the model ran), so a slow or contended moment isn't retried every tick;
    /// without it the gap is handed back too, since nothing was said.
    mutating func release(_ claim: Claim?, keepCooldown: Bool) {
        guard let claim, let o = outstanding.removeValue(forKey: claim) else { return }
        // Only the newest fire owns the cooldown clock.
        if !keepCooldown, lastFiredMs == o.firedMs { lastFiredMs = o.previousFiredMs }
        if let wait = o.wait { announcedWaits.remove(wait) }
        if let id = o.failureId, known[id] != nil { failureMark[id] = o.previousFailureMark }
        if o.reviewed, reviewAnchorMs != nil { reviewAnchorMs = o.previousReviewAnchorMs }
    }

    // MARK: Bookkeeping

    /// /clear re-keyed a lamb: its history follows the new id.
    private mutating func rekey(_ old: String, to new: String) {
        known[old] = nil
        if let v = failureMark.removeValue(forKey: old) { failureMark[new] = v }
        if let v = workStartMs.removeValue(forKey: old) { workStartMs[new] = v }
        announcedWaits = Set(announcedWaits.map { $0.id == old ? WaitKey(id: new, sinceMs: $0.sinceMs) : $0 })
        for (claim, var o) in outstanding {
            if o.wait?.id == old { o.wait?.id = new }
            if o.failureId == old { o.failureId = new }
            outstanding[claim] = o
        }
    }

    private mutating func forget(_ id: String) {
        known[id] = nil
        failureMark[id] = nil
        workStartMs[id] = nil
        announcedWaits = announcedWaits.filter { $0.id != id }
    }
}

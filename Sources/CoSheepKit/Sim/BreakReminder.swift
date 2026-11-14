import CoreGraphics
import Foundation

// Ex-break-reminder.ts. Messages are verbatim.

final class BreakReminder {
    static let MESSAGES: [String: [String]] = [
        "snarky": [
            "You've been staring at that screen for 45 minutes. Your eyes are not invincible.",
            "Break time. Even I need to rest my judgmental gaze sometimes.",
            "Your posture right now is a crime against spines everywhere. Get up.",
            "45 minutes of uninterrupted work? Suspicious. Take a break.",
            "Stand up. Stretch. Touch grass. I'll wait.",
        ],
        "wholesome": [
            "Hey friend! You've been working hard for 45 minutes. Time for a little break!",
            "Your dedication is amazing! But please stretch those legs for me?",
            "Break time! Even the best sheep need to rest. You do too!",
            "You've earned a breather! Go get some water, I'll guard the screen.",
            "45 minutes of great work! Time to rest those eyes. I believe in you!",
        ],
        "chaotic": [
            "45 MINUTES?! Your eyeballs are going to MELT. STAND UP. NOW.",
            "BREAK TIME BREAK TIME BREAK TIME! *air horn noises*",
            "Fun fact: sitting for 45 minutes straight increases your chance of becoming a desk. GET UP!",
            "I've been counting. 45 minutes. That's 2700 seconds of SITTING. Unacceptable!",
            "Your chair is becoming sentient from absorbing you. MOVE!",
        ],
        "passive-aggressive": [
            "Oh, 45 minutes already? No no, don't mind me. I'm sure your back is FINE.",
            "I'm not saying you SHOULD take a break, but your posture is making ME uncomfortable.",
            "Some people take breaks. But I'm sure YOU know better than centuries of health advice.",
            "45 minutes straight. How... dedicated of you. Your spine sends its regards.",
            "Oh don't worry about stretching. I'm sure rigor mortis is very fashionable.",
        ],
    ]

    /// Seconds since the human last touched the keyboard or mouse.
    private let idleSeconds: () -> Double
    /// When the current stretch of work began.
    private var workStart = SimClock.nowMs()
    private var lastCheck = SimClock.nowMs()
    private var reminderShown = false
    private var enabled = true
    private let WORK_THRESHOLD: Double = 45 * 60 * 1000
    private let CHECK_INTERVAL: Double = 30_000
    private var checkAccum: Double = 0

    /// No input for this long is a break: the work clock starts over.
    static let BREAK_IDLE_SECS: Double = 5 * 60

    /// Set from app-switched events; names the culprit app in reminders.
    var currentApp: String?

    /// - Parameter idleSeconds: the input-idle clock (tests pass a fake).
    init(idleSeconds: @escaping () -> Double = BreakReminder.systemIdleSeconds) {
        self.idleSeconds = idleSeconds
    }

    /// Seconds since the last keyboard or mouse event in this login session.
    /// Needs no permission (it reads a counter, not the events).
    nonisolated static func systemIdleSeconds() -> Double {
        // `kCGAnyInputEventType`
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// "Continuous work" is the human at the keyboard or mouse without a
    /// five-minute pause. (It used to be read off the main sheep: the clock
    /// reset whenever the sheep was dozing, which follows how long the sheep
    /// was left alone, not whether anyone was working, so with the default
    /// commentary interval it reset nearly every check.)
    func update(
        _ dt: Double,
        _ bubble: SpeechBubble,
        _ personality: String,
        _ onAnimation: ((SheepAnimation) -> Void)? = nil
    ) {
        if !enabled { return }

        checkAccum += dt
        if checkAccum < CHECK_INTERVAL { return }
        checkAccum = 0

        // The human stepped away, or nothing ran for a while (the Mac slept,
        // the screen was locked): that was the break.
        let now = SimClock.nowMs()
        let sinceLastCheck = now - lastCheck
        lastCheck = now
        let breakMs = Self.BREAK_IDLE_SECS * 1000
        if sinceLastCheck >= breakMs || idleSeconds() >= Self.BREAK_IDLE_SECS {
            workStart = now
            reminderShown = false
            return
        }

        if !reminderShown && now - workStart > WORK_THRESHOLD {
            let pool = Self.MESSAGES[personality] ?? Self.MESSAGES["snarky"]!
            var msg = pool[SimRandom.int(pool.count)]
            // JS truthiness: an empty app name is falsy.
            if let app = currentApp, !app.isEmpty {
                msg += " (\(app), specifically.)"
            }
            bubble.show(msg, duration: 10000)
            onAnimation?(.headshake)
            reminderShown = true
        }
    }

    /// Re-enabling restarts the work clock: `update` doesn't run while
    /// disabled, so the time spent off must not count as one long work
    /// session (the TS fired on the very next check). Re-asserting the current
    /// value — every settings reload does — changes nothing.
    func setEnabled(_ on: Bool) {
        if on && !enabled {
            workStart = SimClock.nowMs()
            lastCheck = workStart
            reminderShown = false
            checkAccum = 0
        }
        enabled = on
    }
}

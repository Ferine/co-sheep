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

    private var lastBoredTime = SimClock.nowMs()
    private var reminderShown = false
    private var enabled = true
    private let WORK_THRESHOLD: Double = 45 * 60 * 1000
    private let CHECK_INTERVAL: Double = 30_000
    private var checkAccum: Double = 0

    /// Set from app-switched events; names the culprit app in reminders.
    var currentApp: String?

    func update(
        _ dt: Double,
        _ sheepState: SheepState,
        _ bubble: SpeechBubble,
        _ personality: String,
        _ onAnimation: ((SheepAnimation) -> Void)? = nil
    ) {
        if !enabled { return }

        checkAccum += dt
        if checkAccum < CHECK_INTERVAL { return }
        checkAccum = 0

        // Reset timer if sheep is in a "bored" state (meaning user is idle)
        let boredStates: [SheepState] = [.idleSleep, .idleCampfire, .idleCounting]
        if boredStates.contains(sheepState) {
            lastBoredTime = SimClock.nowMs()
            reminderShown = false
            return
        }

        if !reminderShown && SimClock.nowMs() - lastBoredTime > WORK_THRESHOLD {
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

    func setEnabled(_ on: Bool) {
        enabled = on
    }
}

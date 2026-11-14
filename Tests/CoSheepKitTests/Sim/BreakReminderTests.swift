import Foundation
import Testing
@testable import CoSheepKit

@Suite("break reminder", .serialized)
struct BreakReminderTests {
    private final class Clock {
        var ms = 1_000_000.0
        /// What the input-idle clock reads.
        var idleSecs = 0.0
    }

    /// Runs `body` with a controllable clock, input-idle clock and a constant
    /// random source.
    private func run(random: Double = 0, _ body: (Clock, BreakReminder, SpeechBubble) -> Void) {
        let savedNow = SimClock.nowSource
        let savedRandom = SimRandom.source
        defer {
            SimClock.nowSource = savedNow
            SimRandom.source = savedRandom
        }
        let clock = Clock()
        SimClock.nowSource = { clock.ms }
        SimRandom.source = { random }
        let reminder = BreakReminder(idleSeconds: { clock.idleSecs })
        let bubble = SpeechBubble(listenToCommentary: false)
        body(clock, reminder, bubble)
        bubble.destroy()
    }

    /// `minutes` at the desk: one 30-second check after another.
    private func work(
        _ minutes: Double, _ clock: Clock, _ reminder: BreakReminder, _ bubble: SpeechBubble,
        personality: String = "snarky", onAnimation: ((SheepAnimation) -> Void)? = nil
    ) {
        for _ in 0..<Int(minutes * 2) {
            clock.ms += 30_000
            reminder.update(30_000, bubble, personality, onAnimation)
        }
    }

    @Test func staysQuietBeforeTheWorkThreshold() {
        run { clock, reminder, bubble in
            work(45, clock, reminder, bubble)
            #expect(!bubble.visible)
        }
    }

    @Test func remindsAfter45MinutesOfWorkAndOnlyOnce() {
        run(random: 0) { clock, reminder, bubble in
            var animations: [SheepAnimation] = []
            work(45.5, clock, reminder, bubble) { animations.append($0) }
            #expect(bubble.visible)
            #expect(bubble.currentText == BreakReminder.MESSAGES["snarky"]![0])
            #expect(animations == [.headshake])

            bubble.hide()
            work(60, clock, reminder, bubble) { animations.append($0) }
            #expect(!bubble.visible)
            #expect(animations == [.headshake])
        }
    }

    @Test func checksOnlyEvery30Seconds() {
        run { clock, reminder, bubble in
            work(45, clock, reminder, bubble)
            clock.ms += 30_000
            reminder.update(29_999, bubble, "snarky")
            #expect(!bubble.visible)
            reminder.update(1, bubble, "snarky")
            #expect(bubble.visible)
        }
    }

    @Test func fiveIdleMinutesAreABreak() {
        run { clock, reminder, bubble in
            work(44, clock, reminder, bubble)
            clock.idleSecs = BreakReminder.BREAK_IDLE_SECS // hands off the keyboard
            work(0.5, clock, reminder, bubble)
            clock.idleSecs = 0
            // The clock started over: 45 more minutes pass quietly...
            work(45, clock, reminder, bubble)
            #expect(!bubble.visible)
            // ...and then the next stretch earns its own reminder.
            work(0.5, clock, reminder, bubble)
            #expect(bubble.visible)
        }
    }

    @Test func aShortPauseIsNotABreak() {
        run { clock, reminder, bubble in
            work(44, clock, reminder, bubble)
            clock.idleSecs = BreakReminder.BREAK_IDLE_SECS - 1 // reading, not resting
            work(1.5, clock, reminder, bubble)
            #expect(bubble.visible)
        }
    }

    @Test func aBreakEarnsAnotherReminderLater() {
        run { clock, reminder, bubble in
            work(45.5, clock, reminder, bubble)
            #expect(bubble.visible)
            bubble.hide()
            clock.idleSecs = 600
            work(0.5, clock, reminder, bubble)
            clock.idleSecs = 0
            work(45.5, clock, reminder, bubble)
            #expect(bubble.visible)
        }
    }

    @Test func timeAsleepIsABreakNotWork() {
        run { clock, reminder, bubble in
            work(44, clock, reminder, bubble)
            // The lid was shut for an hour: no checks ran, and the wake-up
            // keystroke means the idle clock reads zero.
            clock.ms += 60 * 60 * 1000
            reminder.update(30_000, bubble, "snarky")
            #expect(!bubble.visible)
            work(45, clock, reminder, bubble)
            #expect(!bubble.visible)
            work(0.5, clock, reminder, bubble)
            #expect(bubble.visible)
        }
    }

    @Test func disabledRemindersNeverFire() {
        run { clock, reminder, bubble in
            reminder.setEnabled(false)
            work(46, clock, reminder, bubble)
            #expect(!bubble.visible)
        }
    }

    @Test func reEnablingRestartsTheWorkClock() {
        run { clock, reminder, bubble in
            reminder.setEnabled(false)
            work(46, clock, reminder, bubble)
            reminder.setEnabled(true)
            // The disabled stretch isn't one long work session.
            work(45, clock, reminder, bubble)
            #expect(!bubble.visible)
            work(0.5, clock, reminder, bubble)
            #expect(bubble.visible)
        }
    }

    @Test func reassertingEnabledKeepsTheWorkClock() {
        run { clock, reminder, bubble in
            work(45, clock, reminder, bubble)
            reminder.setEnabled(true) // a settings reload while already on
            work(0.5, clock, reminder, bubble)
            #expect(bubble.visible)
        }
    }

    @Test func namesTheCulpritApp() {
        run { clock, reminder, bubble in
            reminder.currentApp = "Xcode"
            work(45.5, clock, reminder, bubble, personality: "wholesome")
            #expect(bubble.currentText == BreakReminder.MESSAGES["wholesome"]![0] + " (Xcode, specifically.)")
        }
    }

    @Test func emptyAppNameIsIgnoredLikeAFalsyJSString() {
        run { clock, reminder, bubble in
            reminder.currentApp = ""
            work(45.5, clock, reminder, bubble, personality: "chaotic")
            #expect(bubble.currentText == BreakReminder.MESSAGES["chaotic"]![0])
        }
    }

    @Test func unknownPersonalitiesFallBackToSnarky() {
        run(random: 0.99) { clock, reminder, bubble in
            work(45.5, clock, reminder, bubble, personality: "good_colleague")
            #expect(bubble.currentText == BreakReminder.MESSAGES["snarky"]![4])
        }
    }

    @Test func theSystemIdleClockIsReadable() {
        #expect(BreakReminder.systemIdleSeconds() >= 0)
    }

    @Test func everyPersonalityHasFiveMessages() {
        for key in ["snarky", "wholesome", "chaotic", "passive-aggressive"] {
            #expect(BreakReminder.MESSAGES[key]?.count == 5, "\(key)")
        }
        #expect(BreakReminder.MESSAGES["passive-aggressive"]![4]
            == "Oh don't worry about stretching. I'm sure rigor mortis is very fashionable.")
    }
}

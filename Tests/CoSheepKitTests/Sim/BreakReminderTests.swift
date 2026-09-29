import Foundation
import Testing
@testable import CoSheepKit

@Suite("break reminder", .serialized)
struct BreakReminderTests {
    private final class Clock {
        var ms = 1_000_000.0
    }

    /// Runs `body` with a controllable clock and a constant random source.
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
        let reminder = BreakReminder()
        let bubble = SpeechBubble(listenToCommentary: false)
        body(clock, reminder, bubble)
        bubble.destroy()
    }

    private let minutes46 = 46.0 * 60 * 1000

    @Test func staysQuietBeforeTheWorkThreshold() {
        run { clock, reminder, bubble in
            clock.ms += 44 * 60 * 1000
            reminder.update(30_000, .idle, bubble, "snarky")
            #expect(!bubble.visible)
        }
    }

    @Test func remindsAfter45MinutesOfWorkAndOnlyOnce() {
        run(random: 0) { clock, reminder, bubble in
            var animations: [SheepAnimation] = []
            clock.ms += minutes46
            reminder.update(30_000, .idle, bubble, "snarky") { animations.append($0) }
            #expect(bubble.visible)
            #expect(bubble.currentText == BreakReminder.MESSAGES["snarky"]![0])
            #expect(animations == [.headshake])

            bubble.hide()
            reminder.update(30_000, .idle, bubble, "snarky") { animations.append($0) }
            #expect(!bubble.visible)
            #expect(animations == [.headshake])
        }
    }

    @Test func checksOnlyEvery30Seconds() {
        run { clock, reminder, bubble in
            clock.ms += minutes46
            reminder.update(29_999, .idle, bubble, "snarky")
            #expect(!bubble.visible)
            reminder.update(1, .idle, bubble, "snarky")
            #expect(bubble.visible)
        }
    }

    @Test func boredStatesResetTheTimer() {
        run { clock, reminder, bubble in
            clock.ms += minutes46
            reminder.update(30_000, .idleCampfire, bubble, "snarky") // user is away
            #expect(!bubble.visible)
            clock.ms += 44 * 60 * 1000
            reminder.update(30_000, .idle, bubble, "snarky")
            #expect(!bubble.visible)
            clock.ms += 2 * 60 * 1000
            reminder.update(30_000, .idle, bubble, "snarky")
            #expect(bubble.visible)
        }
    }

    @Test func disabledRemindersNeverFire() {
        run { clock, reminder, bubble in
            reminder.setEnabled(false)
            clock.ms += minutes46
            reminder.update(30_000, .idle, bubble, "snarky")
            #expect(!bubble.visible)
            reminder.setEnabled(true)
            reminder.update(30_000, .idle, bubble, "snarky")
            #expect(bubble.visible)
        }
    }

    @Test func namesTheCulpritApp() {
        run { clock, reminder, bubble in
            reminder.currentApp = "Xcode"
            clock.ms += minutes46
            reminder.update(30_000, .idle, bubble, "wholesome")
            #expect(bubble.currentText == BreakReminder.MESSAGES["wholesome"]![0] + " (Xcode, specifically.)")
        }
    }

    @Test func emptyAppNameIsIgnoredLikeAFalsyJSString() {
        run { clock, reminder, bubble in
            reminder.currentApp = ""
            clock.ms += minutes46
            reminder.update(30_000, .idle, bubble, "chaotic")
            #expect(bubble.currentText == BreakReminder.MESSAGES["chaotic"]![0])
        }
    }

    @Test func unknownPersonalitiesFallBackToSnarky() {
        run(random: 0.99) { clock, reminder, bubble in
            clock.ms += minutes46
            reminder.update(30_000, .idle, bubble, "good_colleague")
            #expect(bubble.currentText == BreakReminder.MESSAGES["snarky"]![4])
        }
    }

    @Test func everyPersonalityHasFiveMessages() {
        for key in ["snarky", "wholesome", "chaotic", "passive-aggressive"] {
            #expect(BreakReminder.MESSAGES[key]?.count == 5, "\(key)")
        }
        #expect(BreakReminder.MESSAGES["passive-aggressive"]![4]
            == "Oh don't worry about stretching. I'm sure rigor mortis is very fashionable.")
    }
}

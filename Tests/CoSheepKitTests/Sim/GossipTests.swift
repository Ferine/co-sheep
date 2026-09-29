import Foundation
import Testing
@testable import CoSheepKit

// The first three tests are gossip.test.ts (categorizeApp); the rest pin the
// ported GossipManager against a real (headless) Flock, a temp `Paths.root`,
// a virtual clock and scripted dice. Handlers are driven directly
// (`onAppSwitched` / `periodicCheck`) and through the bus; the 5-minute timer
// is only started, never waited on.

private let W = 1512.0
private let H = 982.0
private let HOUR = 3_600_000.0
private let MINUTE = 60_000.0
/// 2026-09-29T12:00:00Z.
private let NOW = 1_790_683_200_000.0

private final class Dice {
    var script: [Double] = []
    var tail = 0.99

    func next() -> Double { script.isEmpty ? tail : script.removeFirst() }
}

private final class Ticker {
    var now = NOW
}

/// A flock (main + friends parked calm 270px apart), a gossip manager over it
/// and the swapped globals. Must be `close()`d.
private final class Stage {
    let clock = Ticker()
    let dice = Dice()
    let flock: Flock
    let gossip: GossipManager
    private let savedRandom: () -> Double

    init(friends: [String] = ["a", "b"]) {
        savedRandom = SimRandom.source
        let c = clock, d = dice
        SimClock.nowSource = { c.now }
        SimRandom.source = { d.next() }

        flock = Flock(W, H)
        for id in friends {
            flock.addFriend(FriendConfig(id: id, name: id.uppercased(), color: .blue,
                                         personality: .wholesome, accessories: nil, scale: 1))
        }
        for (i, id) in flock.getCharacterIds().enumerated() {
            Self.park(flock.getCharacter(id)!.sheep, x: 40 + Double(i) * 270)
        }
        gossip = GossipManager(flock)
    }

    func close() {
        gossip.stop()
        SimRandom.source = savedRandom
    }

    var now: Double {
        get { clock.now }
        set { clock.now = newValue }
    }

    static func park(_ sheep: Sheep, x: Double) {
        sheep.x = x
        sheep.y = sheep.groundY
        sheep.state = .idle
        sheep.stateTimer = 0
        sheep.stateDuration = 1e12
        sheep.walkTarget = nil
    }

    func bubble(_ id: String) -> SpeechBubble { flock.getCharacter(id)!.bubble }

    func switchTo(_ app: String) {
        bus.emit(.appSwitched(AppSwitch(app: app, previousApp: nil, previousDurationMs: 0)))
    }

    /// Hide every friend bubble (the sim can't fire bubble timers on a virtual clock).
    func hideBubbles() {
        for id in flock.getCharacterIds() { bubble(id).hide() }
    }
}

extension BrainTests {
    @Suite("gossip")
    struct GossipTests {
        // MARK: categorizeApp (gossip.test.ts)

        @Test func exactMatchesWinAcrossCategories() {
            #expect(categorizeApp("Webex") == .meetings)
            #expect(categorizeApp("X") == .social)
            #expect(categorizeApp("Music") == .music)
        }

        @Test func substringMatchingRequiresLengthAtLeast4Names() {
            #expect(categorizeApp("Final Cut Pro X") == .other)
            #expect(categorizeApp("Microsoft Excel") == .other)
            #expect(categorizeApp("Google Chrome Beta") == .browser)
            #expect(categorizeApp("Gmail") == .mail)
        }

        @Test func unknownAppsFallToOther() {
            #expect(categorizeApp("Blender") == .other)
        }

        // MARK: categorizeApp (extra)

        @Test func matchingIsCaseInsensitive() {
            #expect(categorizeApp("XCODE") == .dev)
            #expect(categorizeApp("iterm2") == .terminal)
            #expect(categorizeApp("ZOOM.US") == .meetings)
            #expect(categorizeApp("x") == .social)
        }

        @Test func substringPassTakesTheFirstCategoryInDeclarationOrder() {
            // "terminal" (terminal) and "mail" (mail) both hit; terminal is declared first.
            #expect(categorizeApp("Terminal Mail Helper") == .terminal)
            // "code" (dev) beats "notes" (notes).
            #expect(categorizeApp("Code Notes") == .dev)
            #expect(categorizeApp("Visual Studio Code - Insiders") == .dev)
        }

        @Test func exactNamesResolveToTheirOwnCategory() {
            #expect(categorizeApp("Notes") == .notes)
            #expect(categorizeApp("Mail") == .mail)
            #expect(categorizeApp("Messages") == .social)
            #expect(categorizeApp("Zed") == .dev)
            #expect(categorizeApp("Arc") == .browser)
            #expect(categorizeApp("Bear") == .notes)
            #expect(categorizeApp("Warp") == .terminal)
            #expect(categorizeApp("Tidal") == .music)
        }

        @Test func shortNamesNeverMatchBySubstring() {
            #expect(categorizeApp("Zedd Player") == .other)       // "zed" is < 4 chars
            #expect(categorizeApp("Arcade") == .other)            // "arc" is < 4 chars
            #expect(categorizeApp("Xylophone") == .other)         // "x" is < 4 chars
        }

        // MARK: instant bits

        @Test func switchingIntoACategoryTalliesItAndAFriendQuips() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()

                s.dice.script = [0.0, 0.99] // speaker "a", 4th dev bit
                s.switchTo("Xcode")

                #expect(s.gossip.currentCategory == .dev)
                #expect(Memory.loadBrain().todayCounts["app:dev"] == 1)
                #expect(s.bubble("a").visible)
                #expect(s.bubble("a").currentText == "May the compiler be gentle.")
                #expect(!s.bubble("b").visible)
                #expect(!s.bubble("main").visible) // main never delivers the bit
                #expect(s.gossip.lastInstantBit == NOW)
            }
        }

        @Test func stayingInTheSameCategoryDoesNotTallyOrQuipAgain() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.switchTo("Xcode")
                s.hideBubbles()
                s.now += 30 * MINUTE
                s.switchTo("Visual Studio Code") // still dev

                #expect(Memory.loadBrain().todayCounts["app:dev"] == 1)
                #expect(!s.bubble("a").visible && !s.bubble("b").visible)
            }
        }

        @Test func switchingCategoriesTalliesEachOne() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.switchTo("Xcode")
                s.switchTo("Safari")
                s.switchTo("Xcode")
                #expect(Memory.loadBrain().todayCounts == ["app:dev": 2, "app:browser": 1])
            }
        }

        @Test func instantBitsHaveATenMinuteCooldown() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()

                s.switchTo("Xcode")
                #expect(s.bubble("a").visible || s.bubble("b").visible)
                s.hideBubbles()

                s.now += 5 * MINUTE
                s.switchTo("Safari") // new category, but too soon
                #expect(!s.bubble("a").visible && !s.bubble("b").visible)

                s.now += 6 * MINUTE // 11 minutes since the bit
                s.dice.script = [0.0, 0.0]
                s.switchTo("Slack")
                #expect(s.bubble("a").currentText == "Ooh, are we procrastinating?")
                #expect(s.gossip.lastInstantBit == NOW + 11 * MINUTE)
            }
        }

        @Test func noBitWhenNoCalmFriendIsAround() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.flock.getCharacter("a")!.sheep.state = .bounce
                s.flock.getCharacter("b")!.sheep.state = .spin
                s.switchTo("Xcode")
                #expect(!s.bubble("a").visible && !s.bubble("b").visible)
                #expect(s.gossip.lastInstantBit == 0) // didn't burn the cooldown
            }
        }

        @Test func aSpeakerAlreadyTalkingIsSkippedWithoutBurningTheCooldown() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.bubble("a").show("busy", duration: 4000)
                s.dice.script = [0.0, 0.0] // picks "a", who is mid-sentence
                s.switchTo("Xcode")
                #expect(s.bubble("a").currentText == "busy")
                #expect(s.gossip.lastInstantBit == 0)
            }
        }

        // MARK: hourly gossip

        @Test func anHourInACategoryMakesTwoCalmFriendsGossip() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.switchTo("Xcode")
                s.hideBubbles()

                s.now += 61 * MINUTE
                s.dice.script = [0.0, 0.0, 0.0] // i = a, j -> b, first template
                s.gossip.periodicCheck()

                let convo = s.flock.activeConversation
                #expect(convo?.participants == ["a", "b"])
                #expect(convo?.lines.map(\.text) == ["Hour 1 in the editor.", "Blink twice if you need help, human."])
                #expect(convo?.lines.map(\.speakerId) == ["a", "b"])
                #expect(convo?.lines.map(\.animation) == [nil, .headshake])
                #expect(s.gossip.gossipedHours[.dev] == 1)

                // The gossip is a shared memory + affinity bump.
                #expect(FriendMemory.getFriendBrain("a").stats.conversationsTotal == 1)
                #expect(FriendMemory.getFriendBrain("b").stats.conversationsTotal == 1)
                #expect(FriendMemory.getFriendBrain("a").memories.last?.text.contains("the human's 1h of dev") == true)
            }
        }

        @Test func onlyOneGossipPerHourMilestone() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.switchTo("Xcode")
                s.hideBubbles()

                s.now += 61 * MINUTE
                s.dice.script = [0.0, 0.0, 0.0]
                s.gossip.periodicCheck()
                #expect(s.gossip.gossipedHours[.dev] == 1)
                s.flock.cancelConversation()

                s.now += 5 * MINUTE
                s.gossip.periodicCheck()
                #expect(s.flock.activeConversation == nil) // hour 1 already gossiped

                s.now += 56 * MINUTE // 2h02 in total
                s.dice.script = [0.99, 0.99, 0.99] // i = b, j -> a, last template
                s.gossip.periodicCheck()
                let convo = s.flock.activeConversation
                #expect(convo?.participants == ["b", "a"])
                #expect(convo?.lines.first?.text == "Psst. 2 hours of the editor today.")
                #expect(s.gossip.gossipedHours[.dev] == 2)
            }
        }

        @Test func gossipTemplatesFillHoursAndAppOnce() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.switchTo("Safari")
                s.hideBubbles()

                s.now += 3 * HOUR + MINUTE
                s.dice.script = [0.0, 0.0, 0.5] // second template
                s.gossip.periodicCheck()
                #expect(s.flock.activeConversation?.lines.map(\.text) == [
                    "the browser. Again. That's hour 3.",
                    "We should stage an intervention.",
                    "We ARE the intervention.",
                ])
                #expect(s.flock.activeConversation?.lines.last?.animation == .bounce)
                #expect(s.flock.activeConversation?.lines.map(\.speakerId) == ["a", "b", "a"])
            }
        }

        @Test func switchingBackIntoACategoryPastAnHourCanGossipImmediately() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.switchTo("Xcode")
                s.hideBubbles()
                s.now += 90 * MINUTE
                s.switchTo("Safari") // credits 90 min to dev, and a bit for the new category
                s.hideBubbles()
                s.now += 5 * MINUTE
                s.dice.script = [0.0, 0.0, 0.0] // the instant bit is on cooldown, so these are the gossip's
                s.switchTo("Xcode") // credits 5 min to browser; dev has 1h30 banked
                #expect(s.flock.activeConversation?.lines.first?.text == "Hour 1 in the editor.")
            }
        }

        @Test func timeIsCreditedToTheCategoryItWasSpentIn() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.switchTo("Xcode")
                s.now += 30 * MINUTE
                s.switchTo("Safari")
                s.now += 45 * MINUTE
                s.gossip.periodicCheck()
                #expect(s.gossip.categoryMsToday[.dev] == 30 * MINUTE)
                #expect(s.gossip.categoryMsToday[.browser] == 45 * MINUTE)
                #expect(s.gossip.gossipedHours.isEmpty)
            }
        }

        @Test func gossipNeedsTwoCalmFriendsAndRetriesLater() {
            withBrainRoot { _ in
                let s = Stage(friends: ["a"])
                defer { s.close() }
                s.gossip.start()
                s.switchTo("Xcode")
                s.hideBubbles()
                s.now += 2 * HOUR
                s.gossip.periodicCheck()
                #expect(s.flock.activeConversation == nil)
                #expect(s.gossip.gossipedHours.isEmpty)

                s.flock.addFriend(FriendConfig(id: "b", name: "B", color: .blue, personality: .wholesome,
                                               accessories: nil, scale: 1))
                Stage.park(s.flock.getCharacter("b")!.sheep, x: 900)
                s.dice.script = [0.0, 0.0, 0.0]
                s.gossip.periodicCheck()
                #expect(s.gossip.gossipedHours[.dev] == 2)
                #expect(s.flock.activeConversation?.lines.first?.text == "Hour 2 in the editor.")
            }
        }

        @Test func aBusyStageDefersTheGossipWithoutRecordingIt() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.switchTo("Xcode")
                s.hideBubbles()
                s.now += 61 * MINUTE

                s.flock.activeConversation = Flock.ActiveConversation(
                    lines: [ConversationLine(speakerId: "a", text: "busy", duration: 1, delay: 0)],
                    currentIndex: 0, timer: 0, participants: ["a", "b"])
                s.dice.script = [0.0, 0.0, 0.0]
                s.gossip.periodicCheck()

                #expect(s.gossip.gossipedHours.isEmpty)
                #expect(FriendMemory.getFriendBrain("a").stats.conversationsTotal == 0)
                #expect(s.flock.activeConversation?.lines.first?.text == "busy")
            }
        }

        @Test func theIntervalDoesNothingBeforeAnyAppWasSeen() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.now += 5 * HOUR
                s.gossip.periodicCheck()
                #expect(s.gossip.currentCategory == nil)
                #expect(s.gossip.categoryMsToday.isEmpty)
                #expect(s.flock.activeConversation == nil)
            }
        }

        // MARK: day roll

        @Test func aNewUtcDayResetsTheTalliesAndGossipMilestones() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                #expect(s.gossip.day == "2026-09-29")
                s.now = NOW + 10 * HOUR // 22:00Z
                s.switchTo("Xcode")
                s.hideBubbles()
                s.now += 61 * MINUTE
                s.dice.script = [0.0, 0.0, 0.0]
                s.gossip.periodicCheck()
                #expect(s.gossip.gossipedHours[.dev] == 1)
                s.flock.cancelConversation()

                s.now = NOW + 12 * HOUR + 30_000 // 2026-09-30 00:00:30Z
                s.gossip.periodicCheck()
                #expect(s.gossip.day == "2026-09-30")
                #expect(s.gossip.gossipedHours.isEmpty)
                // rollDay clears, then the gap since the last credit lands in the new day.
                #expect(s.gossip.categoryMsToday[.dev] == 59 * MINUTE + 30_000)
                #expect(s.flock.activeConversation == nil) // under an hour again
            }
        }

        @Test func aGapAcrossMidnightIsCreditedEntirelyToTheNewDay() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.switchTo("Xcode")
                s.hideBubbles()

                // Laptop asleep from noon to 1am: TS order is rollDay() then creditElapsed(),
                // so all 13 hours count as "today" and the milestone gossip fires for hour 13.
                s.now = NOW + 13 * HOUR
                s.dice.script = [0.0, 0.0, 0.0]
                s.gossip.periodicCheck()
                #expect(s.gossip.day == "2026-09-30")
                #expect(s.gossip.categoryMsToday[.dev] == 13 * HOUR)
                #expect(s.gossip.gossipedHours[.dev] == 13)
                #expect(s.flock.activeConversation?.lines.first?.text == "Hour 13 in the editor.")
            }
        }

        // MARK: lifecycle

        @Test func stopUnsubscribesFromAppSwitches() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.gossip.stop()
                s.switchTo("Xcode")
                #expect(s.gossip.currentCategory == nil)
                #expect(Memory.loadBrain().todayCounts.isEmpty)
            }
        }

        @Test func startingTwiceDoesNotDoubleTally() {
            withBrainRoot { _ in
                let s = Stage()
                defer { s.close() }
                s.gossip.start()
                s.gossip.start()
                s.switchTo("Xcode")
                #expect(Memory.loadBrain().todayCounts["app:dev"] == 1)
            }
        }
    }
}

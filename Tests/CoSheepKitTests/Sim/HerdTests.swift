import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

@Suite("herd lambs", .serialized)
struct HerdTests {
    // MARK: Arrival and phases

    @Test func anArrivingSessionParachutesInAsALamb() throws {
        try withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            herd.apply(herdChange(lambSession(phase: .idle), beat: .arrived))
            let lamb = try #require(herd.lambs.first)
            #expect(herd.lambs.count == 1)
            #expect(lamb.sheep.id == "lamb:s1")
            #expect(lamb.sheep.state == .parachute)
            #expect(lamb.sheep.y < 0)
            #expect(lamb.sheep.scaleMultiplier == AgentLamb.SCALE)
            #expect(lamb.sheep.tint == HerdPalette.tint(forRepoKey: "/demo/co-sheep"))
            #expect(lamb.sheep.name == "co-sheep")
            #expect(lamb.bubble.visible)
            #expect(lamb.bubble.currentText.contains("co-sheep"))
            land(herd)
            #expect(lamb.sheep.state == .idle)
            #expect(lamb.sheep.y == lamb.sheep.groundY)
        }
    }

    @Test func eachPhaseMapsToItsIdleOverride() throws {
        try withHerdWorld { world in
            let herd = Herd(herdW, herdH)
            let lamb = landedLamb(herd, lambSession(phase: .idle))
            let override = try #require(lamb.sheep.idleOverride)

            // idle: sleep for 20-40 s
            var next = try #require(override())
            #expect(next.state == .sleep)
            #expect((20_000...40_000).contains(next.duration))

            // working: mostly sit with the prop (6-12 s), the odd short walk (2-4 s)
            herd.apply(herdChange(lambSession(phase: .working, tool: .edit), from: .idle))
            world.forced = 0.9
            next = try #require(override())
            #expect(next.state == .sit)
            #expect((6000...12_000).contains(next.duration))
            world.forced = 0.05
            next = try #require(override())
            #expect(next.state == .walk)
            #expect((2000...4000).contains(next.duration))
            world.forced = nil

            // waiting: stay put, 3-5 s
            herd.apply(herdChange(lambSession(phase: .waiting, tool: .bash, waitingFor: "Bash"), from: .working))
            next = try #require(override())
            #expect(next.state == .idle)
            #expect((3000...5000).contains(next.duration))

            // ended: leave (once the shearing beat is over)
            var ended = lambSession(phase: .ended)
            ended.tokens = 0
            herd.apply(herdChange(ended, from: .waiting, beat: .departed))
            next = try #require(override())
            #expect(next.state == .idle, "held until the shearing beat is over")
            run(herd, ms: 1700)
            #expect(lamb.sheep.state == .leaving)
        }
    }

    @Test func aPhaseChangeRedirectsACalmLambAtOnce() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = landedLamb(herd, lambSession(phase: .idle))
            stand(lamb)

            herd.apply(herdChange(lambSession(phase: .working, tool: .edit), from: .idle))
            #expect(lamb.sheep.state == .sit)
            #expect((6000...12_000).contains(lamb.sheep.stateDuration))

            herd.apply(herdChange(lambSession(phase: .waiting, tool: .bash, waitingFor: "Bash"), from: .working))
            #expect(lamb.sheep.state == .vibrate, "the bleat plays out first")
            lamb.sheep.state = .idle
            herd.apply(herdChange(lambSession(phase: .working, tool: .edit), from: .waiting))
            #expect(lamb.sheep.state == .sit)

            herd.apply(herdChange(lambSession(phase: .idle), from: .working))
            #expect(lamb.sheep.state == .sleep)
            #expect((20_000...40_000).contains(lamb.sheep.stateDuration))

            // Waking a sleeper for work
            herd.apply(herdChange(lambSession(phase: .working, tool: .read), from: .idle))
            #expect(lamb.sheep.state == .sit)
        }
    }

    @Test func aParachutingLambIsNotRedirectedMidAir() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            herd.apply(herdChange(lambSession(phase: .idle), beat: .arrived))
            let lamb = herd.lambs[0]
            herd.apply(herdChange(lambSession(phase: .working, tool: .edit), from: .idle))
            #expect(lamb.sheep.state == .parachute)
            land(herd)
            // ...and once down, the next idle ends in the working behaviour
            lamb.sheep.state = .idle
            lamb.sheep.stateTimer = 1e6
            run(herd, ms: 32)
            #expect([SheepState.sit, .walk].contains(lamb.sheep.state))
        }
    }

    // MARK: Waiting

    @Test func aWaitingLambBleatsOnEntryThenEvery45Seconds() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = landedLamb(herd, lambSession(phase: .working, tool: .bash, toolName: "Bash"))
            lamb.bubble.hide()
            run(herd, ms: 9000) // well past the non-urgent cooldown; irrelevant for urgent lines

            herd.apply(herdChange(lambSession(phase: .waiting, tool: .bash, toolName: "Bash", waitingFor: "Bash"),
                                  from: .working))
            #expect(lamb.bubble.visible)
            #expect(lamb.bubble.currentText.contains("Need you: Bash"))
            #expect(lamb.sheep.state == .vibrate)

            lamb.bubble.hide()
            run(herd, ms: 44_000)
            #expect(!lamb.bubble.visible, "nothing before 45 s")
            run(herd, ms: 1500)
            #expect(lamb.bubble.visible)
            #expect(lamb.bubble.currentText.contains("Need you: Bash"))

            lamb.bubble.hide()
            run(herd, ms: 43_000)
            #expect(!lamb.bubble.visible)
            run(herd, ms: 3000)
            #expect(lamb.bubble.visible, "and again 45 s later")

            // Once the permission is answered the bleating stops
            herd.apply(herdChange(lambSession(phase: .working, tool: .bash, toolName: "Bash"), from: .waiting))
            lamb.bubble.hide()
            run(herd, ms: 100_000)
            #expect(!lamb.bubble.visible)
        }
    }

    @Test func aWaitingBleatNamesWhatItIsWaitingOn() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = landedLamb(herd, lambSession(phase: .working))
            herd.apply(herdChange(
                lambSession(phase: .waiting, waitingFor: "Claude needs your permission to use a very long tool name"),
                from: .working))
            let text = lamb.bubble.currentText
            #expect(text.contains("Need you: Claude needs your permission"))
            #expect(text.contains("\u{2026}"))
            #expect(lamb.phaseLine.hasPrefix("waiting: Claude needs"))
        }
    }

    // MARK: Departure

    @Test func departedShearsThenTrotsOffThenIsRemoved() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = landedLamb(herd, lambSession(phase: .idle, tokens: 2_400_000))
            lamb.sheep.x = 100
            herd.apply(herdChange(lambSession(phase: .ended, tokens: 2_400_000), from: .idle, beat: .departed))

            #expect(lamb.isDeparting)
            #expect(!lamb.particles.isEmpty, "shearing burst")
            #expect(lamb.shornAtMs != nil)
            #expect(lamb.wool.shown == 0)
            #expect(lamb.bubble.visible)
            #expect(lamb.bubble.currentText == "Sheared: 2.4M tokens of wool!")

            run(herd, ms: 1400)
            #expect(lamb.sheep.state != .leaving)
            run(herd, ms: 300)
            #expect(lamb.sheep.state == .leaving, "about 1.5 s after the burst")
            #expect(herd.lambs.contains { $0 === lamb })

            var frames = 0
            while !herd.lambs.isEmpty && frames < 4000 {
                herd.update(16)
                frames += 1
            }
            #expect(herd.lambs.isEmpty, "removed once off-screen")
            #expect(herd.sessions.isEmpty)
        }
    }

    @Test func aLightLambLeavesWithoutABragAboutItsWool() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = landedLamb(herd, lambSession(phase: .idle, tokens: 900))
            lamb.bubble.hide()
            herd.apply(herdChange(lambSession(phase: .ended, tokens: 900), from: .idle, beat: .departed))
            #expect(!lamb.bubble.visible, "under 1K tokens: no bubble")
            #expect(!lamb.particles.isEmpty, "but still sheared")
        }
    }

    @Test func aLambThatDepartsMidAirLeavesAfterLanding() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            herd.apply(herdChange(lambSession(phase: .idle), beat: .arrived))
            let lamb = herd.lambs[0]
            herd.apply(herdChange(lambSession(phase: .ended), from: .idle, beat: .departed))
            run(herd, ms: 1700)
            #expect(lamb.sheep.state == .parachute, "still on its way down")
            land(herd)
            run(herd, ms: 50)
            #expect(lamb.sheep.state == .leaving)
        }
    }

    @Test func aDepartedLambIsPulledOutOfAStack() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let bottom = landedLamb(herd, lambSession("a"))
            let top = landedLamb(herd, lambSession("b", repo: "other"))
            stand(bottom, x: 300)
            stand(top, x: 300)
            top.sheep.stackOn(bottom.sheep)
            #expect(top.sheep.state == .stacked)
            herd.apply(herdChange(lambSession("b", repo: "other", phase: .ended), from: .idle))
            #expect(top.sheep.state == .leaving)
            #expect(top.sheep.stackedOn == nil)
            #expect(bottom.sheep.stackedBy == nil)
        }
    }

    @Test func aLeavingLambDoesNotCarryItsRiderOffScreen() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let bottom = landedLamb(herd, lambSession("a"))
            let rider = Sheep(herdW, herdH, "friend", nil, 300)
            stand(bottom, x: 300)
            rider.stackOn(bottom.sheep)
            herd.apply(herdChange(lambSession("a", phase: .ended), from: .idle))
            #expect(bottom.sheep.state == .leaving)
            #expect(bottom.sheep.stackedBy == nil)
            #expect(rider.stackedOn == nil)
            #expect(rider.state == .fall)
        }
    }

    // MARK: Clearing and re-keying

    @Test func clearedKeepsTheLambAndResetsItsWool() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = landedLamb(herd, lambSession("s1", phase: .idle, tokens: 3_000_000))
            run(herd, ms: 6000)
            #expect(lamb.wool.shown > 2)
            let before = lamb.sheep.x

            herd.apply(herdChange(lambSession("s2", phase: .idle, tokens: 0), from: .idle,
                                  beat: .cleared, previousId: "s1"))
            #expect(herd.lambs.count == 1)
            #expect(herd.lambs[0] === lamb, "re-keyed, not respawned")
            #expect(lamb.id == "s2")
            #expect(herd.lamb(id: "s2") === lamb)
            #expect(herd.lamb(id: "s1") == nil)
            #expect(!lamb.isDeparting)
            #expect(lamb.wool.shown == 0)
            #expect(!lamb.particles.isEmpty)
            #expect(lamb.bubble.currentText == "Fresh start. Cold, though.")
            #expect(lamb.sheep.x == before)
            #expect(herd.sessions.map(\.id) == ["s2"])

            // The wool grows again from the new session's tokens
            herd.apply(herdChange(lambSession("s2", phase: .working, tool: .edit, tokens: 1_000_000),
                                  from: .idle))
            run(herd, ms: 6000)
            #expect(lamb.wool.shown > 1)
        }
    }

    @Test func aClearThatKeepsTheTokenCountStillStartsFromBare() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = landedLamb(herd, lambSession("s1", phase: .idle, tokens: 3_000_000))
            run(herd, ms: 6000)
            herd.apply(herdChange(lambSession("s2", phase: .idle, tokens: 3_000_000), from: .idle,
                                  beat: .cleared, previousId: "s1"))
            run(herd, ms: 6000)
            #expect(lamb.wool.shown == 0, "the shorn tokens no longer count")
            #expect(lamb.woolLevel == 0)
        }
    }

    @Test func previousIdReKeysAnOverflowSessionToo() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            herd.maxLambs = 1
            _ = landedLamb(herd, lambSession("a"))
            herd.apply(herdChange(lambSession("b", repo: "other"), beat: .arrived))
            #expect(herd.overflow.keys.sorted() == ["b"])
            herd.apply(herdChange(lambSession("b2", repo: "other"), from: .idle, beat: .cleared, previousId: "b"))
            #expect(herd.overflow.keys.sorted() == ["b2"])
            #expect(herd.lambs.count == 1)
        }
    }

    // MARK: Cap, overflow, enabled

    @Test func extraSessionsOverflowAndAreAdoptedWhenASlotFrees() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            #expect(herd.maxLambs == 8)
            herd.maxLambs = 2
            for id in ["a", "b", "c"] {
                herd.apply(herdChange(lambSession(id, repo: id), beat: .arrived))
            }
            land(herd)
            #expect(herd.lambs.map(\.id) == ["a", "b"])
            #expect(herd.overflow.keys.sorted() == ["c"])
            #expect(herd.sessions.map(\.id) == ["a", "b", "c"])

            // "a" ends: "c" takes its slot straight away, "a" trots off
            herd.apply(herdChange(lambSession("a", repo: "a", phase: .ended), from: .idle, beat: .departed))
            #expect(herd.overflow.isEmpty)
            #expect(herd.lamb(id: "c") != nil)
            #expect(herd.activeLambs.map(\.id) == ["b", "c"])
            #expect(herd.sessions.map(\.id) == ["b", "c"])
            run(herd, ms: 60_000)
            #expect(herd.lambs.map(\.id) == ["b", "c"])
        }
    }

    @Test func anOverflowSessionThatEndsIsDropped() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            herd.maxLambs = 1
            _ = landedLamb(herd, lambSession("a"))
            herd.apply(herdChange(lambSession("b", repo: "other"), beat: .arrived))
            herd.apply(herdChange(lambSession("b", repo: "other", phase: .working, tool: .edit), from: .idle))
            #expect(herd.overflow["b"]?.phase == .working, "tracked while waiting its turn")
            herd.apply(herdChange(lambSession("b", repo: "other", phase: .ended), from: .working, beat: .departed))
            #expect(herd.overflow.isEmpty)
            herd.apply(herdChange(lambSession("a", phase: .ended), from: .idle, beat: .departed))
            run(herd, ms: 60_000)
            #expect(herd.lambs.isEmpty)
        }
    }

    @Test func overflowIsPromotedOldestFirst() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            herd.maxLambs = 1
            _ = landedLamb(herd, lambSession("a"))
            var young = lambSession("young", repo: "y")
            young.startedMs += 5 * 60_000
            herd.apply(herdChange(young, beat: .arrived))
            herd.apply(herdChange(lambSession("old", repo: "o"), beat: .arrived))
            herd.maxLambs = 2
            #expect(herd.activeLambs.map(\.id) == ["a", "old"])
            #expect(herd.overflow.keys.sorted() == ["young"])
        }
    }

    @Test func loweringTheCapRetiresTheNewestLambsIntoOverflow() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            for id in ["a", "b", "c"] { _ = landedLamb(herd, lambSession(id, repo: id)) }
            herd.maxLambs = 1
            #expect(herd.activeLambs.map(\.id) == ["a"])
            #expect(herd.overflow.keys.sorted() == ["b", "c"])
            #expect(herd.sessions.count == 3)
            herd.maxLambs = 3
            #expect(herd.activeLambs.count == 3)
            #expect(herd.overflow.isEmpty)
        }
    }

    @Test func switchingTheHerdOffSendsEveryLambAwayQuietly() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let a = landedLamb(herd, lambSession("a", phase: .waiting, waitingFor: "Bash"))
            let b = landedLamb(herd, lambSession("b", repo: "other", tokens: 5_000_000))
            #expect(a.bubble.visible)
            herd.isEnabled = false
            for lamb in [a, b] {
                #expect(lamb.isDeparting)
                #expect(!lamb.bubble.visible, "no bubbles")
                #expect(lamb.particles.isEmpty, "no shearing show either")
            }
            run(herd, ms: 100)
            #expect(a.sheep.state == .leaving)
            #expect(b.sheep.state == .leaving)
            run(herd, ms: 60_000)
            #expect(herd.lambs.isEmpty)

            // Sessions are still tracked, but nobody parachutes in
            herd.apply(herdChange(lambSession("c", repo: "c"), beat: .arrived))
            #expect(herd.lambs.isEmpty)
            #expect(herd.sessions.map(\.id).sorted() == ["a", "b", "c"])

            herd.isEnabled = true
            #expect(herd.activeLambs.count == 3)
        }
    }

    // MARK: Names

    @Test func lambsSharingARepoGetNumberedNames() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let a = landedLamb(herd, lambSession("a", repo: "co-sheep"))
            let other = landedLamb(herd, lambSession("x", repo: "neas"))
            #expect(a.sheep.name == "co-sheep")
            let b = landedLamb(herd, lambSession("b", repo: "co-sheep"))
            let c = landedLamb(herd, lambSession("c", repo: "co-sheep"))
            #expect([a, b, c].map(\.sheep.name) == ["co-sheep", "co-sheep #2", "co-sheep #3"])
            #expect(other.sheep.name == "neas")

            // The first one leaves; the others keep their numbers while shared
            herd.apply(herdChange(lambSession("a", repo: "co-sheep", phase: .ended), from: .idle))
            #expect([b, c].map(\.sheep.name) == ["co-sheep #2", "co-sheep #3"])
            // ...and a newcomer takes the free number 1
            let d = landedLamb(herd, lambSession("d", repo: "co-sheep"))
            #expect(d.sheep.name == "co-sheep")
            herd.apply(herdChange(lambSession("c", repo: "co-sheep", phase: .ended), from: .idle))
            herd.apply(herdChange(lambSession("d", repo: "co-sheep", phase: .ended), from: .idle))
            #expect(b.sheep.name == "co-sheep", "alone again: no number")
        }
    }

    @Test func aSessionWithoutARepoIsJustALamb() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = landedLamb(herd, lambSession("zz", repo: nil))
            #expect(lamb.sheep.name == "lamb")
        }
    }

    // MARK: Events and seams

    @Test func theHerdListensToItsEventSignalUntilStopped() {
        withHerdWorld { _ in
            let events = AppEvents()
            let herd = Herd(herdW, herdH)
            herd.start(events: events)
            events.herd.emit(herdChange(lambSession("a"), beat: .arrived))
            #expect(herd.lambs.count == 1)
            herd.stop()
            events.herd.emit(herdChange(lambSession("b", repo: "x"), beat: .arrived))
            #expect(herd.lambs.count == 1)
        }
    }

    @Test func onChangeSeesEveryAppliedChange() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            #expect(herd.focusTerminal == nil)
            #expect(herd.onChange == nil)
            var seen: [String] = []
            herd.onChange = { seen.append("\($0.session.id):\($0.beat?.rawValue ?? "-")") }
            herd.apply(herdChange(lambSession("a"), beat: .arrived))
            herd.apply(herdChange(lambSession("a", phase: .working, tool: .edit), from: .idle))
            #expect(seen == ["a:arrived", "a:-"])
        }
    }

    @Test func clickingALambFocusesItsTerminalAndBounces() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = landedLamb(herd, lambSession("a", phase: .working, tool: .edit))
            stand(lamb)
            var focused: [String] = []
            herd.focusTerminal = { focused.append($0.id) }
            herd.clicked(lamb)
            #expect(focused == ["a"])
            #expect(lamb.sheep.state == .bounce)
        }
    }

    @Test func hoverTracksOnlyLambs() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = landedLamb(herd, lambSession("a"))
            herd.setHover(lamb.sheep)
            #expect(herd.hovered === lamb)
            herd.setHover(Sheep(herdW, herdH))
            #expect(herd.hovered == nil)
            herd.setHover(lamb.sheep)
            herd.setHover(nil)
            #expect(herd.hovered == nil)
            herd.setHover(lamb.sheep)
            herd.apply(herdChange(lambSession("a", phase: .ended), from: .idle, beat: .departed))
            run(herd, ms: 60_000)
            #expect(herd.hovered == nil, "a lamb that left stops being hovered")
        }
    }

    @Test func theDemoSpawnsFiveLambsAndCanBeCleared() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            herd.startDemo()
            defer { herd.clearDemo() }
            #expect(herd.lambs.count == 5)
            #expect(herd.lambs.map(\.id) == ["demo-1", "demo-2", "demo-3", "demo-4", "demo-5"])
            #expect(Set(herd.lambs.map { $0.session.repoKey ?? "" }).count == 5)
            let byId = Dictionary(uniqueKeysWithValues: herd.lambs.map { ($0.id, $0.session) })
            #expect(byId["demo-1"]?.tool == .edit && byId["demo-1"]?.tokens == 300_000)
            #expect(byId["demo-2"]?.tool == .bash && byId["demo-2"]?.tokens == 3_000_000)
            #expect(byId["demo-3"]?.phase == .waiting && byId["demo-3"]?.waitingFor == "Bash")
            #expect(byId["demo-4"]?.phase == .idle && byId["demo-4"]?.tokens == 20_000_000)
            #expect(byId["demo-5"]?.tool == .web && byId["demo-5"]?.subagents == 2)

            herd.clearDemo()
            #expect(herd.lambs.allSatisfy { $0.isDeparting })
            run(herd, ms: 60_000)
            #expect(herd.lambs.isEmpty)
        }
    }
}

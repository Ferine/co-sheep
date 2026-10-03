import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

@Suite("lamb beats", .serialized)
struct LambBeatTests {
    /// A landed, calm, working lamb whose arrival bubble is long past.
    private func calmLamb(_ herd: Herd, _ s: AgentSession? = nil) -> AgentLamb {
        let lamb = landedLamb(herd, s ?? lambSession(phase: .working, tool: .edit, toolName: "Edit"))
        run(herd, ms: 9000)
        lamb.bubble.hide()
        stand(lamb)
        return lamb
    }

    @Test func aFinishedTurnBouncesAndSometimesSpeaks() {
        withHerdWorld { world in
            let herd = Herd(herdW, herdH)
            let lamb = calmLamb(herd)
            world.forced = 0.1 // under 40%: speaks
            herd.apply(herdChange(lambSession(phase: .idle), from: .working, beat: .turnDone))
            #expect(lamb.sheep.state == .bounce)
            #expect(lamb.bubble.visible)
            #expect(LambLines.turnDone.contains(lamb.bubble.currentText))

            let quiet = calmLamb(herd, lambSession("q", repo: "other", phase: .working, tool: .edit))
            world.forced = 0.7 // over 40%: just the bounce
            herd.apply(herdChange(lambSession("q", repo: "other", phase: .idle), from: .working, beat: .turnDone))
            #expect(quiet.sheep.state == .bounce)
            #expect(!quiet.bubble.visible)
        }
    }

    @Test func aFailedToolShakesItsHeadAndPuffsABangWithoutTalking() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = calmLamb(herd, lambSession(phase: .idle))
            herd.apply(herdChange(lambSession(phase: .idle), from: .idle, beat: .toolFailed))
            #expect(lamb.sheep.state == .headshake)
            #expect(lamb.exclaimUntil > lamb.animMs)
            #expect(!lamb.bubble.visible)
            lamb.sheep.state = .idle
            let bare = opCount(lamb, overlay: false)
            #expect(opCount(lamb) > bare, "the red ! is up")
            run(herd, ms: 2000)
            lamb.sheep.state = .idle
            #expect(lamb.exclaimUntil < lamb.animMs)
            #expect(opCount(lamb) == bare, "and gone again")
        }
    }

    @Test func aDeniedPermissionNamesTheTool() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = calmLamb(herd)
            herd.apply(herdChange(lambSession(phase: .working, tool: .bash, toolName: "Bash"), from: .working,
                                  beat: .permissionDenied))
            #expect(lamb.sheep.state == .headshake)
            #expect(lamb.bubble.currentText == "Fine. No Bash.")
        }
    }

    @Test func anApiErrorMakesItDizzyAndSaysWhatHappenedInWords() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = calmLamb(herd)
            var s = lambSession(phase: .idle)
            s.lastError = "rate_limit"
            herd.apply(herdChange(s, from: .working, beat: .apiError))
            #expect(lamb.sheep.state == .spin)
            #expect(lamb.dizzyUntil > lamb.animMs)
            #expect(lamb.bubble.currentText == "Baa?? (rate limited)")
        }
    }

    @Test func friendlyErrorWordsCoverTheStopFailureTypes() {
        #expect(AgentLamb.friendlyError("rate_limit") == "rate limited")
        #expect(AgentLamb.friendlyError("overloaded_error") == "servers overloaded")
        #expect(AgentLamb.friendlyError("server_error") == "server hiccup")
        #expect(AgentLamb.friendlyError("authentication_failed") == "login trouble")
        #expect(AgentLamb.friendlyError("billing_error") == "billing trouble")
        #expect(AgentLamb.friendlyError("invalid_request") == "bad request")
        #expect(AgentLamb.friendlyError("max_output_tokens") == "ran out of room")
        #expect(AgentLamb.friendlyError("unknown") == "something broke")
        #expect(AgentLamb.friendlyError(nil) == "something broke")
        #expect(AgentLamb.friendlyError("") == "something broke")
        #expect(AgentLamb.friendlyError("weird_new_thing") == "weird new thing")
        #expect(AgentLamb.friendlyError(String(repeating: "x", count: 80)).count <= 24)
    }

    @Test func aHumanInterruptStartlesIt() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = calmLamb(herd)
            herd.apply(herdChange(lambSession(phase: .idle), from: .working, beat: .interrupted))
            #expect(lamb.sheep.state == .bounce)
            #expect(lamb.startledUntil > lamb.animMs)
        }
    }

    @Test func compactionHasItChewingCudForAWhile() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = calmLamb(herd)
            herd.apply(herdChange(lambSession(phase: .working, tool: .compacting), from: .working, beat: .compacted))
            #expect(lamb.chewUntil > lamb.animMs + 5000)
            #expect(lamb.bubble.visible)
            lamb.sheep.state = .sit
            #expect(opCount(lamb) > opCount(lamb, overlay: false), "jaw and munch while the tool is compacting")

            // Once the session moves on (no prop at all), the beat's chewing carries on a while longer
            herd.apply(herdChange(lambSession(phase: .idle), from: .working))
            lamb.sheep.state = .sit
            #expect(opCount(lamb) > opCount(lamb, overlay: false))
            run(herd, ms: 10_000)
            lamb.sheep.state = .sit
            #expect(lamb.animMs > lamb.chewUntil)
            #expect(opCount(lamb) == opCount(lamb, overlay: false))
        }
    }

    @Test func nonUrgentBubblesWaitOutAnEightSecondCooldown() {
        withHerdWorld { world in
            let herd = Herd(herdW, herdH)
            let lamb = calmLamb(herd)
            #expect(lamb.say("first"))
            #expect(lamb.bubble.currentText == "first")
            run(herd, ms: 7000)
            #expect(!lamb.say("too soon"))
            #expect(lamb.bubble.currentText == "first")
            // Urgent lines ignore it...
            #expect(lamb.say("now!", urgent: true))
            #expect(lamb.bubble.currentText == "now!")
            // ...and restart it
            run(herd, ms: 7000)
            #expect(!lamb.say("still too soon"))
            run(herd, ms: 1500)
            #expect(lamb.say("fine"))

            // The same rule applies to beats
            world.forced = 0.1
            lamb.bubble.hide()
            herd.apply(herdChange(lambSession(phase: .working, tool: .bash, toolName: "Bash"), from: .working,
                                  beat: .permissionDenied))
            #expect(!lamb.bubble.visible, "the cooldown suppressed the beat's bubble")
        }
    }

    @Test func eachLambHasItsOwnCooldown() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let a = calmLamb(herd, lambSession("a", repo: "a", phase: .working, tool: .edit))
            let b = calmLamb(herd, lambSession("b", repo: "b", phase: .working, tool: .edit))
            #expect(a.say("a"))
            #expect(b.say("b"))
        }
    }

    @Test func shearingParticlesFlyAndFadeWithinAboutAnAndAHalfSeconds() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = calmLamb(herd, lambSession(phase: .working, tool: .edit, tokens: 20_000_000))
            run(herd, ms: 6000)
            let puffs = LambDraw.puffLayout(amount: lamb.wool.quantized).count
            #expect(puffs >= 10)
            lamb.shear()
            #expect(lamb.particles.count >= puffs * 3 + 10)
            // Outward and up: nothing starts out heading down
            #expect(lamb.particles.allSatisfy { $0.vy < 20 })
            #expect(lamb.wool.shown == 0)
            #expect(lamb.woolLevel == 0)
            run(herd, ms: 1000)
            #expect(!lamb.particles.isEmpty)
            run(herd, ms: 600)
            #expect(lamb.particles.isEmpty)
            #expect(lamb.shornAtMs != nil)
        }
    }

    @Test func theShornPatchFadesOutOverTwentySeconds() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = calmLamb(herd, lambSession(phase: .idle))
            lamb.sheep.state = .sit
            let bare = opCount(lamb)
            lamb.shear()
            run(herd, ms: 2000)
            lamb.sheep.state = .sit
            #expect(opCount(lamb) > bare, "pink patch drawn")
            run(herd, ms: 19_000)
            lamb.sheep.state = .sit
            #expect(opCount(lamb) == bare, "gone after 20 s")
        }
    }

    @Test func lambletsTrailTheLambWhileSubagentsRun() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = calmLamb(herd, lambSession(phase: .working, tool: .subagent, subagents: 2))
            run(herd, ms: 500)
            #expect(lamb.lamblets.count == 2)
            // Behind the lamb (it faces right: they're to its left)
            lamb.sheep.facingRight = true
            run(herd, ms: 1000)
            #expect(lamb.lamblets.allSatisfy { $0 < 4 })
            herd.apply(herdChange(lambSession(phase: .working, tool: .subagent, subagents: 5), from: .working))
            run(herd, ms: 1000)
            #expect(lamb.lamblets.count == AgentLamb.MAX_LAMBLETS)
            herd.apply(herdChange(lambSession(phase: .working, tool: .subagent, subagents: 0), from: .working))
            run(herd, ms: 500)
            #expect(lamb.lamblets.isEmpty)
        }
    }

    @Test func lambletsFollowWhenTheLambTurnsAround() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            let lamb = calmLamb(herd, lambSession(phase: .working, tool: .subagent, subagents: 1))
            lamb.sheep.facingRight = true
            run(herd, ms: 1000)
            let behindRight = lamb.lamblets[0]
            lamb.sheep.facingRight = false
            run(herd, ms: 3000)
            #expect(lamb.lamblets[0] > behindRight + 10, "now trailing on the other side")
        }
    }
}

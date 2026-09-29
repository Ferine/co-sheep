import Foundation
import Testing
@testable import CoSheepKit

// The first block is mcp-companion.test.ts, test for test; the rest pin the
// exact pool lines and the McpCompanion listener against a real (headless)
// Flock and an injected `AppEvents`.

private func ev(_ patch: (inout SessionEvent) -> Void = { _ in }) -> SessionEvent {
    var e = SessionEvent(kind: "milestone", task: nil, progress: nil, milestone: nil, detail: nil,
                         health: "good")
    patch(&e)
    return e
}

private let first: () -> Double = { 0 } // deterministic: always the first pool entry

extension BrainTests {
    @Suite("mcp companion")
    struct McpCompanionTests {
        // MARK: pickReaction (mcp-companion.test.ts)

        @Test func failedMilestoneGivesHeadshakeAndASnarkyFailureLine() {
            let r = pickReaction(ev { $0.milestone = "failed"; $0.health = "failing" }, rng: first)
            #expect(r.animation == .headshake)
            #expect(r.text.count > 0)
        }

        @Test func doneMilestoneBounces() {
            let r = pickReaction(ev { $0.milestone = "done"; $0.health = "good" }, rng: first)
            #expect(r.animation == .bounce)
        }

        @Test func blockedMilestoneVibrates() {
            let r = pickReaction(ev { $0.milestone = "blocked"; $0.health = "degraded" }, rng: first)
            #expect(r.animation == .vibrate)
        }

        @Test func beginGivesAGreetingLineNoCrash() {
            let r = pickReaction(ev { $0.kind = "begin"; $0.milestone = nil }, rng: first)
            #expect(r.text.count > 0)
        }

        @Test func highProgressAnnouncesNearDone() {
            let r = pickReaction(ev { $0.kind = "progress"; $0.progress = 0.95; $0.milestone = nil }, rng: first)
            #expect(r.text.count > 0)
        }

        @Test func rngSelectsWithinThePoolDeterministically() {
            let a = pickReaction(ev { $0.milestone = "failed" }, rng: { 0 })
            let b = pickReaction(ev { $0.milestone = "failed" }, rng: { 0.999 })
            #expect(a.text != b.text) // different indices -> different lines
        }

        @Test func milestoneWithDetailAppendsItToTheLine() {
            let r = pickReaction(ev { $0.milestone = "failed"; $0.detail = "3 tests failed" }, rng: first)
            #expect(r.text.contains("3 tests failed"))
        }

        @Test func milestoneWithNullDetailHasNoParenthetical() {
            let r = pickReaction(ev { $0.milestone = "done"; $0.detail = nil }, rng: first)
            #expect(!r.text.contains("("))
        }

        @Test func milestoneWithEmptyStringDetailHasNoParenthetical() {
            let r = pickReaction(ev { $0.milestone = "blocked"; $0.detail = "" }, rng: first)
            #expect(!r.text.contains("("))
        }

        @Test func setTaskWithATaskLabelIncludesTheLabel() {
            let r = pickReaction(ev { $0.kind = "task"; $0.milestone = nil; $0.task = "wire LDP" }, rng: first)
            #expect(r.text.contains("wire LDP"))
            #expect(r.animation == nil)
        }

        @Test func setTaskWithNullTaskFallsBackToAGenericNonEmptyLine() {
            let r = pickReaction(ev { $0.kind = "task"; $0.milestone = nil; $0.task = nil }, rng: first)
            #expect(r.text.count > 0)
            #expect(r.animation == nil)
        }

        @Test func setTaskLabelSelectionIsDeterministicViaRngAndVaries() {
            let a = pickReaction(ev { $0.kind = "task"; $0.milestone = nil; $0.task = "wire LDP" }, rng: { 0 })
            let b = pickReaction(ev { $0.kind = "task"; $0.milestone = nil; $0.task = "wire LDP" }, rng: { 0.999 })
            #expect(a.text.contains("wire LDP"))
            #expect(b.text.contains("wire LDP"))
            #expect(a.text != b.text)
        }

        @Test func waitingOnYouMilestoneVibrates() {
            let r = pickReaction(ev { $0.milestone = "waiting_on_you" }, rng: first)
            #expect(r.animation == .vibrate)
        }

        @Test func endHasNoAnimation() {
            let r = pickReaction(ev { $0.kind = "end"; $0.milestone = nil }, rng: first)
            #expect(r.animation == nil)
            #expect(r.text.count > 0)
        }

        @Test func lowMidProgressIsNonEmptyTextWithNoAnimation() {
            let r = pickReaction(ev { $0.kind = "progress"; $0.progress = 0.3; $0.milestone = nil }, rng: first)
            #expect(r.text.count > 0)
            #expect(r.animation == nil)
        }

        @Test func unknownMilestoneValueFallsThroughWithoutThrowing() {
            let r = pickReaction(ev { $0.milestone = "weird" }, rng: first)
            #expect(r.text.count > 0)
        }

        // MARK: pickReaction (exact lines)

        @Test func theFirstAndLastLinesOfEveryPoolAreVerbatim() {
            func line(_ patch: (inout SessionEvent) -> Void, _ rng: Double) -> (text: String, animation: SheepAnimation?) {
                pickReaction(ev(patch), rng: { rng })
            }
            #expect(line({ $0.milestone = "failed" }, 0).text == "Tch. Predictable.")
            #expect(line({ $0.milestone = "failed" }, 0.999).text == "That's the third time. I'm keeping count.")
            #expect(line({ $0.milestone = "done" }, 0).text == "...Fine. That worked. Don't read into it.")
            #expect(line({ $0.milestone = "done" }, 0.999).text == "It's done. I'm as surprised as you.")
            #expect(line({ $0.milestone = "blocked" }, 0).text == "Your move, sorcerer.")
            #expect(line({ $0.milestone = "blocked" }, 0.999).text == "I'll wait. Not that I mind.")
            #expect(line({ $0.milestone = "waiting_on_you" }, 0).text == "*taps foot* Any day now.")
            #expect(line({ $0.milestone = "waiting_on_you" }, 0.999).text == "Well? I'm right here.")
            #expect(line({ $0.kind = "begin" }, 0).text == "Oh. We're working now, are we?")
            #expect(line({ $0.kind = "begin" }, 0).animation == .bounce)
            #expect(line({ $0.kind = "begin" }, 0.999).text == "Back at it. Don't expect applause.")
            #expect(line({ $0.kind = "end" }, 0).text == "Done already? Hmph.")
            #expect(line({ $0.kind = "end" }, 0.999).text == "That's a wrap. Don't miss me.")
            #expect(line({ $0.kind = "task" }, 0).text == "This again? Predictable.")
            #expect(line({ $0.kind = "task" }, 0.999).text == "Go on then. I'm observing.")
        }

        @Test func labeledTaskLinesQuoteTheLabel() {
            func line(_ rng: Double) -> String {
                pickReaction(ev { $0.kind = "task"; $0.task = "wire LDP" }, rng: { rng }).text
            }
            #expect(line(0) == #"Watching you wrestle with "wire LDP" again, hm?"#)
            #expect(line(0.5) == #""wire LDP". Predictable choice."#)
            #expect(line(0.999) == #"So it's "wire LDP" today. Riveting."#)
        }

        @Test func anEmptyTaskLabelUsesTheGenericPool() {
            let r = pickReaction(ev { $0.kind = "task"; $0.task = "" }, rng: first)
            #expect(r.text == "This again? Predictable.")
        }

        @Test func detailIsAppendedInParentheses() {
            let r = pickReaction(ev { $0.milestone = "failed"; $0.detail = "3 tests failing" }, rng: first)
            #expect(r.text == "Tch. Predictable. (3 tests failing)")
        }

        @Test func progressSwitchesToTheHighPoolAtNinetyPercent() {
            func line(_ progress: Double?) -> String {
                pickReaction(ev { $0.kind = "progress"; $0.progress = progress }, rng: first).text
            }
            #expect(line(0.89) == "Halfway. Don't get comfortable.")
            #expect(line(0.9) == "Almost there. I counted.")
            #expect(line(1) == "Almost there. I counted.")
            #expect(line(nil) == "Halfway. Don't get comfortable.")
        }

        @Test func aMilestoneKindWithoutAMilestoneFallsBackToTheTaskPool() {
            #expect(pickReaction(ev { $0.milestone = nil }, rng: first).text == "This again? Predictable.")
            #expect(pickReaction(ev { $0.milestone = "weird" }, rng: first).animation == nil)
            #expect(pickReaction(ev { $0.kind = "mystery" }, rng: first).text == "This again? Predictable.")
        }

        @Test func theDefaultRngIsTheSimRandomSource() {
            let saved = SimRandom.source
            defer { SimRandom.source = saved }
            SimRandom.source = { 0.999 }
            #expect(pickReaction(ev { $0.milestone = "done" }).text == "It's done. I'm as surprised as you.")
        }

        // MARK: the companion

        /// A flock with its main sheep parked (a parachuting sheep ignores animations).
        private func makeFlock() -> Flock {
            let flock = Flock(1512, 982)
            let main = flock.main
            main.y = main.groundY
            main.state = .idle
            main.stateTimer = 0
            main.stateDuration = 1e12
            return flock
        }

        @Test func aSessionEventShowsTheReactionAndAnimatesTheMainSheep() {
            withBrainRoot { _ in
                let saved = SimRandom.source
                defer { SimRandom.source = saved }
                SimRandom.source = { 0 }

                let events = AppEvents()
                let flock = makeFlock()
                var commentary: [SheepAnimation?] = []
                let unsubscribe = bus.on(.aiCommentary) { event in
                    if case .aiCommentary(let animation) = event { commentary.append(animation) }
                }
                defer { unsubscribe() }
                let companion = McpCompanion(flock, events: events)
                companion.start()
                defer { companion.stop() }

                events.sheepSession.emit(ev { $0.milestone = "done"; $0.detail = "all green" })

                #expect(flock.mainBubble.visible)
                #expect(flock.mainBubble.currentText == "...Fine. That worked. Don't read into it. (all green)")
                #expect(flock.main.state == .bounce)
                #expect(commentary == [.bounce])
            }
        }

        @Test func aReactionWithoutAnAnimationStillSpeaks() {
            withBrainRoot { _ in
                let saved = SimRandom.source
                defer { SimRandom.source = saved }
                SimRandom.source = { 0 }

                let events = AppEvents()
                let flock = makeFlock()
                let companion = McpCompanion(flock, events: events)
                companion.start()
                defer { companion.stop() }

                events.sheepSession.emit(ev { $0.kind = "task"; $0.task = "port managers" })
                #expect(flock.mainBubble.currentText == #"Watching you wrestle with "port managers" again, hm?"#)
                #expect(flock.main.state == .idle)
            }
        }

        @Test func stopUnsubscribesFromSessionEvents() {
            withBrainRoot { _ in
                let events = AppEvents()
                let flock = makeFlock()
                let companion = McpCompanion(flock, events: events)
                companion.start()
                companion.stop()
                events.sheepSession.emit(ev { $0.milestone = "failed" })
                #expect(!flock.mainBubble.visible)
            }
        }

        @Test func startingTwiceRendersEachEventOnce() {
            withBrainRoot { _ in
                let events = AppEvents()
                let flock = makeFlock()
                var renders = 0
                let unsubscribe = bus.on(.aiCommentary) { _ in renders += 1 }
                defer { unsubscribe() }
                let companion = McpCompanion(flock, events: events)
                companion.start()
                companion.start()
                defer { companion.stop() }
                events.sheepSession.emit(ev { $0.kind = "begin" })
                #expect(renders == 1)
            }
        }

        @Test func eventsOnAnotherAppEventsHubAreIgnored() {
            withBrainRoot { _ in
                let mine = AppEvents(), other = AppEvents()
                let flock = makeFlock()
                let companion = McpCompanion(flock, events: mine)
                companion.start()
                defer { companion.stop() }
                other.sheepSession.emit(ev { $0.kind = "begin" })
                #expect(!flock.mainBubble.visible)
            }
        }
    }
}

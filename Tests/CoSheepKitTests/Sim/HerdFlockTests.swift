import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

// The herd inside a real (headless) flock: lambs are physical sheep, but
// invisible to every friend system.

@Suite("herd in the flock", .serialized)
struct HerdFlockTests {
    private func makeFlock(colleague: Bool = false, friends: [FriendConfig] = []) -> Flock {
        let flock = Flock(herdW, herdH)
        if colleague { flock.spawnGoodColleague() }
        for f in friends { flock.addFriend(f) }
        return flock
    }

    private func friend(_ id: String, personality: FriendPersonality = .wholesome) -> FriendConfig {
        FriendConfig(id: id, name: id.capitalized, color: .pink, personality: personality, accessories: nil, scale: 1)
    }

    @discardableResult
    private func addLamb(_ flock: Flock, _ id: String = "s1", repo: String = "co-sheep",
                         phase: AgentPhase = .idle) -> AgentLamb {
        let lamb = landedLamb(flock.herd, lambSession(id, repo: repo, phase: phase))
        run(flock.herd, ms: 9000)
        lamb.bubble.hide()
        stand(lamb)
        return lamb
    }

    @Test func theFlockOwnsTheHerd() {
        withHerdWorld { _ in
            let flock = makeFlock()
            #expect(flock.herd.lambs.isEmpty)
            flock.herd.apply(herdChange(lambSession(), beat: .arrived))
            run(flock, ms: 200)
            #expect(flock.herd.lambs.count == 1)
        }
    }

    @Test func lambsStayOutOfEveryFriendSystem() {
        withHerdWorld { world in
            let flock = makeFlock(colleague: true, friends: [friend("bob"), friend("amy", personality: .chaotic)])
            let a = addLamb(flock, "a")
            let b = addLamb(flock, "b", repo: "other")
            // Everyone in earshot of everyone: the lambs stand right among the friends
            let cluster = ["main", "good_colleague", "bob", "amy"].map { flock.getCharacter($0)!.sheep }
            for (i, sheep) in cluster.enumerated() { stand(sheep, x: 100 + Double(i) * 90) }
            stand(a, x: 460)
            stand(b, x: 550)

            let ids = ["main", "good_colleague", "bob", "amy"]
            #expect(flock.getCharacterIds() == ids)
            #expect(flock.getCharacter("lamb:a") == nil)
            #expect(flock.getFriendEntry("lamb:a") == nil)
            #expect(!flock.isCharacterCalm("lamb:a"))

            // Three minutes of flock life with every social roll possible: nobody
            // converses with, gathers, or remembers a lamb.
            var sawConversation = false
            for round in 0..<2 {
                world.forced = round == 0 ? nil : 0.0
                for _ in 0..<(round == 0 ? 11_000 : 1500) {
                    flock.update(16)
                    if let c = flock.activeConversation {
                        sawConversation = true
                        #expect(c.participants.allSatisfy { ids.contains($0) })
                    }
                    if let g = flock.groupActivity {
                        #expect(g.participants.allSatisfy { ids.contains($0) })
                    }
                    if let s = flock.spectacle {
                        #expect(s.participants.allSatisfy { ids.contains($0) })
                    }
                }
            }
            world.forced = nil
            #expect(sawConversation, "the audit isn't vacuous: friends did talk")
            #expect(flock.getCharacterIds() == ids)

            let files = FileManager.default.enumerator(atPath: Paths.root.path)?.allObjects as? [String] ?? []
            #expect(files.allSatisfy { !$0.contains("lamb") }, "no brain, memory or journal entry for a lamb: \(files)")
        }
    }

    @Test func aLambIsHitBeforeAnyFriendUnderIt() {
        withHerdWorld { _ in
            let flock = makeFlock(friends: [friend("bob")])
            let lamb = addLamb(flock)
            let bob = flock.getCharacter("bob")!.sheep
            stand(bob, x: 400)
            stand(lamb, x: 410)
            flock.main.x = 5
            let px = 430.0, py = lamb.sheep.y + 20
            #expect(bob.hitTest(px, py) && lamb.sheep.hitTest(px, py))
            #expect(flock.hitTest(px, py) === lamb.sheep)

            // A lamb on its way out can't be grabbed any more
            lamb.depart(sheared: false)
            #expect(flock.hitTest(px, py) === bob)
        }
    }

    @Test func lambsHaveTheirOwnBubbleAndQuips() {
        withHerdWorld { _ in
            let flock = makeFlock(friends: [friend("bob")])
            let lamb = addLamb(flock)
            #expect(flock.getBubble(lamb.sheep) === lamb.bubble)
            #expect(flock.getBubble(flock.main) === flock.mainBubble)
            for _ in 0..<40 { #expect(LambLines.quips.contains(flock.getQuip(lamb.sheep))) }
            #expect(flock.herd.lamb(for: flock.main) == nil)
        }
    }

    @Test func anythingStacksOnALambAndALambOnAnything() {
        withHerdWorld { _ in
            let flock = makeFlock(friends: [friend("bob")])
            let lamb = addLamb(flock)
            let bob = flock.getCharacter("bob")!.sheep
            stand(lamb, x: 400)
            stand(bob, x: 1000)
            flock.main.x = 5

            // bob dropped on the lamb
            bob.x = 410
            bob.y = lamb.sheep.y - bob.displaySize * 0.6
            #expect(flock.tryStack(bob) === lamb.sheep)
            // the lamb dropped on bob
            stand(bob, x: 1000)
            lamb.sheep.x = 1005
            lamb.sheep.y = bob.y - lamb.sheep.displaySize * 0.6
            #expect(flock.tryStack(lamb.sheep) === bob)
            // a lamb never stacks on itself, or on one that's leaving
            lamb.sheep.x = 400
            lamb.sheep.y = lamb.sheep.groundY
            #expect(flock.tryStack(lamb.sheep) == nil)
        }
    }

    @Test func stackingOnALambLeavesNoTraceInTheJournal() {
        withHerdWorld { _ in
            let flock = makeFlock(friends: [friend("bob")])
            let lamb = addLamb(flock)
            let bob = flock.getCharacter("bob")!.sheep
            stand(lamb, x: 400)
            stand(bob, x: 405)
            bob.stackOn(lamb.sheep)
            flock.onSheepStacked(bob, lamb.sheep)
            #expect(lamb.bubble.visible, "the lamb has a view on being a chair")
            let text = (try? String(contentsOf: Paths.root.appendingPathComponent("memory.json"), encoding: .utf8)) ?? ""
            #expect(!text.contains("lamb:"))
        }
    }

    @Test func aStampedeScattersLambsToo() {
        withHerdWorld { _ in
            let flock = makeFlock()
            let calm = addLamb(flock, "a")
            let leaving = addLamb(flock, "b", repo: "other")
            leaving.depart(sheared: false)
            run(flock, ms: 100)
            #expect(leaving.sheep.state == .leaving)
            calm.sheep.x = 700
            flock.triggerStampede(300, 300)
            #expect(calm.sheep.state == .stampede)
            #expect(calm.sheep.facingRight, "running away from the mouse")
            #expect(leaving.sheep.state == .leaving, "a leaving lamb keeps going")
        }
    }

    @Test func calmLambsCheerAtATrampolineWhenThereIsRoom() {
        withHerdWorld { _ in
            let flock = makeFlock()
            let lamb = addLamb(flock)
            flock.onTrampolineStarted(flock.main)
            #expect(lamb.pendingReaction != nil)
            run(flock, ms: 3000)
            #expect(lamb.bubble.visible)
            #expect(LambLines.trampoline.contains(lamb.bubble.currentText))
            #expect(lamb.sheep.state == .bounce || lamb.sheep.state == .idle)
        }
    }

    @Test func aLambThatTrampolinesIsNotRecordedInTheJournal() {
        withHerdWorld { _ in
            let flock = makeFlock()
            let lamb = addLamb(flock)
            flock.onTrampolineStarted(lamb.sheep)
            let text = (try? String(contentsOf: Paths.root.appendingPathComponent("memory.json"), encoding: .utf8)) ?? ""
            #expect(!text.contains("lamb:"))
            #expect(lamb.pendingReaction == nil, "it doesn't cheer for itself")
        }
    }

    @Test func boundsPlatformsAndScreenSizeIncludeLambs() {
        withHerdWorld { _ in
            let flock = makeFlock(friends: [friend("bob")])
            let before = flock.getAllBounds().count
            let lamb = addLamb(flock)
            #expect(flock.getAllBounds().count == before + 1)
            let b = flock.getAllBounds().last!
            #expect(b.x == lamb.sheep.x - 12 && b.w == lamb.sheep.displaySize + 24)

            let platform = WindowPlatform(x: 100, y: 300, w: 500, h: 400)
            flock.setWindowPlatforms([platform])
            #expect(lamb.sheep.platforms == [platform])
            // ...and lambs that arrive later pick them up
            let late = landedLamb(flock.herd, lambSession("late", repo: "late"))
            #expect(late.sheep.platforms == [platform])

            flock.updateScreenSize(900, 700)
            #expect(lamb.sheep.screenWidth == 900 && lamb.sheep.screenHeight == 700)
            #expect(flock.herd.screenWidth == 900)
            #expect(lamb.sheep.y == lamb.sheep.groundY)
        }
    }

    @Test func aLambCanLandOnAWindow() {
        withHerdWorld { _ in
            let flock = makeFlock()
            flock.setWindowPlatforms([WindowPlatform(x: 0, y: 400, w: 3000, h: 400)])
            flock.herd.apply(herdChange(lambSession(), beat: .arrived))
            let lamb = flock.herd.lambs[0]
            land(flock.herd)
            #expect(lamb.sheep.currentPlatform != nil)
            #expect(lamb.sheep.y < lamb.sheep.groundY)
        }
    }

    @Test func lambsDrawAfterTheFriendsWithBubblesInTheOverlay() {
        withHerdWorld { _ in
            let flock = makeFlock(friends: [friend("bob")])
            let lamb = addLamb(flock)
            lamb.say("hello", urgent: true)
            flock.herd.setHover(lamb.sheep)
            flock.update(16)
            let canvas = Canvas()
            canvas.beginFrame()
            flock.draw(canvas)
            let keys = canvas.groups.map(\.key)
            let world = canvas.groups.filter { $0.layer == .world }.map(\.key)
            #expect(world.firstIndex(of: "sheep:bob")! < world.firstIndex(of: "lamb:s1")!)
            let lambGroup = canvas.groups.first { $0.key == "lamb:s1" }
            #expect(lambGroup?.anchor == CGPoint(x: lamb.sheep.x, y: lamb.sheep.y))
            #expect(lambGroup?.layer == .world)
            #expect(keys.contains("bubble:lamb:s1"))
            #expect(canvas.groups.first { $0.key == "bubble:lamb:s1" }?.layer == .overlay)
            #expect(canvas.groups.first { $0.key == "lamb:s1:card" }?.layer == .overlay)
            #expect(canvas.groups.first { $0.key == "lamb:s1:card" }?.ops.isEmpty == false)

            flock.herd.setHover(nil)
            canvas.beginFrame()
            flock.draw(canvas)
            #expect(!canvas.groups.map(\.key).contains("lamb:s1:card"))
        }
    }

    @Test func flyingWoolGetsItsOwnTile() {
        withHerdWorld { _ in
            let flock = makeFlock()
            let lamb = addLamb(flock)
            lamb.shear()
            let canvas = Canvas()
            canvas.beginFrame()
            flock.draw(canvas)
            let fx = canvas.groups.first { $0.key == "lamb:s1:fx" }
            #expect(fx != nil)
            #expect(fx?.anchor == nil)
            #expect(fx?.ops.isEmpty == false)
        }
    }

    @Test func aReKeyedLambKeepsItsTile() {
        withHerdWorld { _ in
            let flock = makeFlock()
            let lamb = addLamb(flock, "s1")
            flock.herd.apply(herdChange(lambSession("s2"), from: .idle, beat: .cleared, previousId: "s1"))
            let canvas = Canvas()
            canvas.beginFrame()
            flock.draw(canvas)
            #expect(canvas.groups.contains { $0.key == "lamb:s1" })
            #expect(lamb.id == "s2")
        }
    }

    @Test func aSessionDemotedAndPromotedAgainGetsAFreshTile() {
        withHerdWorld { _ in
            let herd = Herd(herdW, herdH)
            for id in ["a", "b"] { _ = landedLamb(herd, lambSession(id, repo: id)) }
            herd.maxLambs = 1
            herd.maxLambs = 2 // "b" is promoted while its old lamb is still trotting off
            let keys = herd.lambs.map(\.sheep.id)
            #expect(Set(keys).count == keys.count, "\(keys)")
        }
    }
}

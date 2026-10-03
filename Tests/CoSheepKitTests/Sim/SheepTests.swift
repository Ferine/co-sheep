import Foundation
import Testing
@testable import CoSheepKit

/// Run the update loop until the parachute descent settles
private func settle(_ sheep: Sheep) {
    var i = 0
    while i < 5000 && sheep.state == .parachute {
        sheep.update(16)
        i += 1
    }
}

// Ex-sheep.test.ts
@Suite("parachute landing on window platforms")
struct ParachuteLandingTests {
    @Test func skipsPlatformsThatWouldPlaceTheSheepAboveTheScreenTop() {
        let sheep = Sheep(1512, 982)
        // Maximized window: top edge just below the macOS menu bar
        sheep.platforms = [WindowPlatform(x: 0, y: 25, w: 1512, h: 957)]

        settle(sheep)

        #expect(sheep.state == .idle)
        #expect(sheep.y >= 0)
        #expect(sheep.currentPlatform == nil)
    }

    @Test func stillLandsOnPlatformsLowEnoughToStandOn() {
        let sheep = Sheep(1512, 982)
        sheep.platforms = [WindowPlatform(x: 400, y: 400, w: 700, h: 500)]

        settle(sheep)

        #expect(sheep.state == .idle)
        #expect(sheep.y == 400 - sheep.displaySize)
        #expect(sheep.currentPlatform != nil)
    }
}

// MARK: - New tests (adapted / Swift-specific)

/// A random source that replays `values`, then repeats the last one.
private func scripted(_ values: [Double]) -> () -> Double {
    var i = 0
    return {
        defer { i += 1 }
        return values[min(i, values.count - 1)]
    }
}

private func localMs(hour: Int) -> Double {
    Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour, minute: 30))!
        .timeIntervalSince1970 * 1000
}

private final class FakeEasterTheme: EasterThemeHooks {
    var active = true
    var painted: [(id: String, name: String)] = []
    func registerPaintedEgg(_ sheepId: String, _ sheepName: String) {
        painted.append((sheepId, sheepName))
    }
}

@Suite("sheep state machine", .serialized)
struct SheepStateMachineTests {
    private func withSim(now: Double, random: [Double], _ body: () -> Void) {
        let savedRandom = SimRandom.source
        let savedNow = SimClock.nowSource
        SimClock.nowSource = { now }
        SimRandom.source = scripted(random)
        body()
        SimRandom.source = savedRandom
        SimClock.nowSource = savedNow
    }

    private func idleSheep(id: String = "main", x: Double = 300) -> Sheep {
        let sheep = Sheep(1512, 982, id, nil, x)
        sheep.state = .idle
        sheep.y = sheep.groundY
        sheep.stateTimer = 0
        sheep.stateDuration = 0
        return sheep
    }

    @Test func geometry() {
        let s = Sheep(1000, 800)
        #expect(s.displaySize == 96)
        #expect(s.groundY == 800 - 96 - 80)
        #expect(s.x == 1000 / 2 - 48)
        #expect(s.y == -96)
        #expect(s.state == .parachute)
        let big = Sheep(1000, 800, "f", nil, 10, 1.15)
        #expect(big.displaySize == 110) // round(110.4)
        #expect(big.x == 10)
        #expect(big.name == "Sheep")
    }

    @Test func hitTestUsesAGenerousHitbox() {
        let s = Sheep(1000, 800, "main", nil, 100)
        s.y = 200
        #expect(s.hitTest(100 - 12, 200 - 12))
        #expect(s.hitTest(100 + 96 + 12, 200 + 96 + 12))
        #expect(!s.hitTest(100 - 13, 250))
        #expect(!s.hitTest(150, 200 + 96 + 13))
    }

    @Test func idleAtMorningRollsWalk() {
        let now = localMs(hour: 7)
        withSim(now: now, random: [0.5, 0.25]) {
            let s = idleSheep()
            s.update(16)
            #expect(s.state == .walk)
            #expect(s.facingRight == false) // 0.25 > 0.5 is false
            #expect(s.stateDuration == 3000 + 0.25 * 7000)
        }
    }

    @Test func idleAtNightCanSleep() {
        withSim(now: localMs(hour: 3), random: [0.55, 0.5]) {
            let s = idleSheep()
            s.update(16)
            // hour 3: walk 0.2, sit 0.3, sleep 0.3 → 0.55 lands in sleep
            #expect(s.state == .sleep)
            #expect(s.stateDuration == 8000 + 0.5 * 12000)
        }
    }

    @Test func idleInTheMiddayFallsThroughToIdle() {
        withSim(now: localMs(hour: 10), random: [0.95, 0.5]) {
            let s = idleSheep()
            s.update(16)
            // default weights walk 0.7 + sit 0.2 + sleep 0 = 0.9 < 0.95
            #expect(s.state == .idle)
            #expect(s.stateDuration == 2000 + 0.5 * 6000)
        }
    }

    @Test func idleWithWalkTargetWalksTowardIt() {
        withSim(now: localMs(hour: 10), random: [0.5]) {
            let s = idleSheep(x: 100)
            s.walkTarget = 700
            s.update(16)
            #expect(s.state == .walk)
            #expect(s.facingRight)
            #expect(s.stateDuration == max(3000, (600 / 60) * 1000 + 2000))
        }
    }

    @Test func walkingSheepArrivesAtTarget() {
        withSim(now: localMs(hour: 10), random: [0.25, 0.5]) {
            let s = idleSheep(x: 300)
            s.state = .walk
            s.stateDuration = 60000
            s.walkTarget = 300 + 96 // within 1.5 * displaySize
            s.update(16)
            #expect(s.walkTarget == nil)
            #expect(s.state == .sit) // 0.25 < 0.5
            #expect(s.stateDuration == 5000 + 0.5 * 8000)
        }
    }

    @Test func walkBouncesOffTheScreenEdge() {
        let s = idleSheep(x: 0.5)
        s.state = .walk
        s.facingRight = false
        s.stateDuration = 60000
        s.update(1000)
        #expect(s.x == 0)
        #expect(s.facingRight)
    }

    @Test func boredSheepPicksBoredBehaviours() {
        let start = localMs(hour: 12)
        func run(roll: Double) -> Sheep {
            var s: Sheep!
            withSim(now: start, random: [roll, 0.5]) {
                s = idleSheep()
                // Advance past the 2 minute boredom threshold
                SimClock.nowSource = { start + 130_000 }
                s.update(16)
            }
            return s
        }
        let sleep = run(roll: 0.1)
        #expect(sleep.state == .idleSleep)
        #expect(sleep.stateDuration == 15000 + 0.5 * 15000)
        let fire = run(roll: 0.5)
        #expect(fire.state == .idleCampfire)
        #expect(fire.stateDuration == 15000 + 0.5 * 10000)
        let count = run(roll: 0.9)
        #expect(count.state == .idleCounting)
        #expect(count.stateDuration == 10000 + 0.5 * 5000)
    }

    @Test func boredFriendsUseTheirPersonality() {
        let start = localMs(hour: 12)
        func run(_ p: FriendPersonality, roll: Double) -> SheepState {
            var state = SheepState.idle
            withSim(now: start, random: [roll, 0.5]) {
                let s = idleSheep(id: "friend")
                s.personality = p
                SimClock.nowSource = { start + 130_000 }
                s.update(16)
                state = s.state
            }
            return state
        }
        #expect(run(.chaotic, roll: 0.1) == .idleZooming)
        #expect(run(.chaotic, roll: 0.5) == .idleCampfire)
        #expect(run(.chaotic, roll: 0.8) == .idleCounting)
        #expect(run(.chaotic, roll: 0.95) == .idleSleep)
        #expect(run(.wholesome, roll: 0.1) == .idleHearts)
        #expect(run(.wholesome, roll: 0.5) == .idleSleep)
        #expect(run(.snarky, roll: 0.1) == .idleJudging)
        #expect(run(.snarky, roll: 0.5) == .idleCounting)
        #expect(run(.passiveAggressive, roll: 0.1) == .idleSighing)
        #expect(run(.passiveAggressive, roll: 0.95) == .idleCounting)
    }

    @Test func easterSeasonSheepPaintEggsAndRegisterThemOnce() {
        let start = localMs(hour: 12)
        withSim(now: start, random: [0.1, 0.1]) {
            let easter = FakeEasterTheme()
            let s = idleSheep(id: "main")
            s.setEasterTheme(easter)
            s.name = "Sheep"
            SimClock.nowSource = { start + 130_000 }
            s.update(16)
            #expect(s.state == .idleEggPainting)
            #expect(s.stateDuration == 12000 + 0.1 * 8000)

            SimRandom.source = { 0.9 }
            s.stateTimer = s.stateDuration - 1800 - 16
            s.update(16)
            #expect(easter.painted.count == 1)
            #expect(easter.painted.first?.id == "main")
            s.update(16)
            #expect(easter.painted.count == 1)
        }
    }

    @Test func inactiveEasterThemeDoesNotPaint() {
        let start = localMs(hour: 12)
        withSim(now: start, random: [0.1, 0.1]) {
            let easter = FakeEasterTheme()
            easter.active = false
            let s = idleSheep()
            s.easterTheme = easter
            SimClock.nowSource = { start + 130_000 }
            s.update(16)
            #expect(s.state == .idleSleep) // roll 0.1 → sleep, not egg painting
        }
    }

    @Test func resetActivityBreaksOutOfBoredStates() {
        withSim(now: localMs(hour: 12), random: [0.5]) {
            for state in [SheepState.idleSleep, .idleCampfire, .idleCounting, .idleJudging,
                          .idleHearts, .idleZooming, .idleSighing, .idleEggPainting] {
                let s = idleSheep()
                s.state = state
                s.resetActivity()
                #expect(s.state == .idle)
                #expect(s.stateDuration == 1000 + 0.5 * 2000)
            }
            let walking = idleSheep()
            walking.state = .walk
            walking.resetActivity()
            #expect(walking.state == .walk)
        }
    }

    @Test func listeningParksTheSheepInSit() {
        withSim(now: localMs(hour: 12), random: [0.5]) {
            let s = idleSheep()
            s.state = .walk
            s.stateDuration = 60000
            s.startListening()
            #expect(s.isListening)
            s.update(16)
            #expect(s.state == .sit)
            // A listening sheep stays put even past its (zero) duration
            s.update(16)
            s.update(16)
            #expect(s.state == .sit)
            s.stopListening()
            #expect(!s.isListening)
            #expect(s.state == .idle)
        }
    }

    @Test func physicsStatesAreNotParkedWhileListening() {
        let s = idleSheep()
        s.state = .fall
        s.y = 100
        s.startListening()
        s.update(16)
        #expect(s.state == .fall)
    }

    @Test func playAnimationSetsUpTheAnimationState() {
        withSim(now: localMs(hour: 12), random: [0.9]) {
            let s = idleSheep()
            s.playAnimation(.bounce)
            #expect(s.state == .bounce && s.vy == -300 && s.stateDuration == 1200)
            s.playAnimation(.spin)
            #expect(s.state == .spin && s.stateDuration == 800)
            s.playAnimation(.backflip)
            #expect(s.state == .backflip && s.vy == -200 && s.stateDuration == 600)
            s.playAnimation(.headshake)
            #expect(s.state == .headshake && s.stateDuration == 800)
            s.playAnimation(.zoom)
            #expect(s.state == .zoom && s.stateDuration == 1500 && s.facingRight) // 0.9 > 0.5
            s.playAnimation(.vibrate)
            #expect(s.state == .vibrate && s.stateDuration == 1000)
        }
    }

    @Test func animationsDoNotInterruptGrabbedOrParachuting() {
        let s = Sheep(1000, 800)
        s.playAnimation(.spin)
        #expect(s.state == .parachute)
        s.grab()
        s.playAnimation(.spin)
        #expect(s.state == .grabbed)
    }

    @Test func spinFinishesBackToIdle() {
        withSim(now: localMs(hour: 12), random: [0.5]) {
            let s = idleSheep()
            s.playAnimation(.spin)
            s.update(800)
            #expect(s.state == .idle)
            #expect(s.y == s.groundY)
        }
    }

    @Test func releaseChoosesTrampolineParachuteOrIdle() {
        withSim(now: localMs(hour: 12), random: [0.5]) {
            let high = Sheep(1000, 1000)
            high.grab()
            high.y = 100 // < 35% of the screen
            high.release()
            #expect(high.state == .trampoline)
            #expect(high.stateDuration == 12000)

            let mid = Sheep(1000, 1000)
            mid.grab()
            mid.y = 500
            mid.release()
            #expect(mid.state == .parachute)

            let low = Sheep(1000, 1000)
            low.grab()
            low.y = low.groundY - 5
            low.release()
            #expect(low.state == .idle)
            #expect(low.y == low.groundY)
            #expect(low.stateDuration == 1000 + 0.5 * 2000)
        }
    }

    @Test func trampolineBouncesAndSettles() {
        withSim(now: localMs(hour: 12), random: [0.5]) {
            let s = Sheep(1000, 1000)
            s.grab()
            s.y = 100
            s.release()
            var frames = 0
            while s.state == .trampoline && frames < 2000 {
                s.update(16)
                frames += 1
            }
            #expect(s.state == .idle)
            #expect(s.trampolineBounces >= 1 && s.trampolineBounces <= 5)
            #expect(s.y == s.groundY)
        }
    }

    @Test func stampedeRunsAwayFromTheMouse() {
        withSim(now: localMs(hour: 12), random: [0.5]) {
            let s = idleSheep(x: 500)
            s.startStampede(400)
            #expect(s.state == .stampede)
            #expect(s.facingRight)
            #expect(s.stateDuration == 1200 + 0.5 * 800)

            let edge = idleSheep(x: 50)
            edge.startStampede(400) // would run left, but too close to the edge
            #expect(edge.facingRight)
            let edgeR = idleSheep(x: 1450)
            edgeR.startStampede(1300) // would run right, but too close to the edge
            #expect(!edgeR.facingRight)
        }
    }

    @Test func stampedeEndsAtTheEdge() {
        withSim(now: localMs(hour: 12), random: [0.5]) {
            let s = idleSheep(x: 1300)
            s.startStampede(0)
            s.update(1000)
            #expect(s.state == .idle)
            #expect(s.x == 1512 - 96)
        }
    }

    @Test func stampedeOffAPlatformFalls() {
        let s = idleSheep(x: 500)
        s.y = 200
        s.startStampede(0)
        s.stateTimer = s.stateDuration
        s.update(16)
        #expect(s.state == .fall)
    }

    @Test func stackingAndUnstacking() {
        let bottom = idleSheep(id: "a", x: 300)
        let top = Sheep(1512, 982, "b", nil, 500)
        top.stackOn(bottom)
        #expect(top.state == .stacked)
        #expect(bottom.stackedBy === top)
        #expect(top.stackedOn === bottom)
        #expect(top.x == 300)
        #expect(top.y == bottom.y - 96 * 0.7)

        // The stacked sheep tracks its base
        bottom.x = 320
        top.update(16)
        #expect(top.x == 320)

        // Base goes wild → the top falls
        bottom.state = .zoom
        top.update(16)
        #expect(top.state == .fall)
        #expect(top.stackedOn == nil)
        #expect(top.vy == -200)
    }

    @Test func grabbingTheBaseDropsTheSheepOnTop() {
        let bottom = idleSheep(id: "a", x: 300)
        let top = Sheep(1512, 982, "b", nil, 500)
        top.stackOn(bottom)
        bottom.grab()
        #expect(bottom.state == .grabbed)
        #expect(bottom.stackedBy == nil)
        #expect(top.stackedOn == nil)
        #expect(top.state == .fall)
        #expect(top.vy == -150)
    }

    @Test func detachFromStackWorksInBothDirections() {
        let bottom = idleSheep(id: "a", x: 300)
        let mid = Sheep(1512, 982, "b", nil, 500)
        let top = Sheep(1512, 982, "c", nil, 700)
        mid.stackOn(bottom)
        top.stackOn(mid)
        mid.detachFromStack()
        #expect(bottom.stackedBy == nil)
        #expect(mid.stackedOn == nil)
        #expect(mid.stackedBy == nil)
        #expect(top.stackedOn == nil)
        #expect(top.state == .fall)
    }

    @Test func animationLeavesTheStack() {
        let bottom = idleSheep(id: "a", x: 300)
        let top = Sheep(1512, 982, "b", nil, 500)
        top.stackOn(bottom)
        top.playAnimation(.headshake)
        #expect(bottom.stackedBy == nil)
        #expect(top.stackedOn == nil)
    }

    @Test func regroundKeepsAirborneSheepAndSnapsGroundedOnes() {
        let grounded = idleSheep(x: 1400)
        grounded.screenWidth = 800
        grounded.screenHeight = 600
        grounded.reground()
        #expect(grounded.x == 800 - 96)
        #expect(grounded.y == 600 - 96 - 80)

        let airborne = idleSheep()
        airborne.state = .fall
        airborne.y = 123
        airborne.reground()
        #expect(airborne.y == 123)
    }

    @Test func losingThePlatformParachutes() {
        let s = idleSheep()
        s.y = 300
        s.stateDuration = 60000
        s.currentPlatform = WindowPlatform(x: 100, y: 396, w: 500, h: 300)
        s.platforms = [WindowPlatform(x: 100, y: 396, w: 500, h: 300)]
        s.update(16)
        #expect(s.state == .idle && s.currentPlatform != nil)
        // The window moved by less than the tolerance: still found
        s.platforms = [WindowPlatform(x: 120, y: 410, w: 490, h: 300)]
        s.update(16)
        #expect(s.state == .idle)
        // The window is gone
        s.platforms = []
        s.update(16)
        #expect(s.state == .parachute)
        #expect(s.currentPlatform == nil)
    }

    @Test func walkingOffAPlatformEdgeParachutes() {
        let s = idleSheep(x: 100)
        let p = WindowPlatform(x: 100, y: 400, w: 200, h: 300)
        s.y = 400 - 96
        s.currentPlatform = p
        s.platforms = [p]
        s.state = .walk
        s.facingRight = true
        s.stateDuration = 60000
        s.x = 100 + 200 - 96 + 96 * 0.3 // right at the overhang limit
        s.update(100)
        #expect(s.state == .parachute)
        #expect(s.currentPlatform == nil)
    }

    @Test func campfireSparksSpawnAndDie() {
        withSim(now: localMs(hour: 12), random: [0.01, 0.5]) {
            let s = idleSheep()
            s.state = .idleCampfire
            s.stateDuration = 60000
            s.update(16)
            #expect(s.campfireSparks.count == 1)
            #expect(s.campfireSparks[0].life < 1)
            SimRandom.source = { 0.9 } // no new sparks
            for _ in 0..<80 { s.update(16) }
            #expect(s.campfireSparks.isEmpty)
        }
    }

    @Test func randomQuipPicksFromAllFourteen() {
        var seen = Set<String>()
        let savedRandom = SimRandom.source
        defer { SimRandom.source = savedRandom }
        for i in 0..<14 {
            SimRandom.source = { (Double(i) + 0.5) / 14 }
            seen.insert(Sheep(100, 100).getRandomQuip())
        }
        #expect(seen.count == 14)
        SimRandom.source = { 0 }
        #expect(Sheep(100, 100).getRandomQuip() == "Hey! Hooves are sensitive!")
        SimRandom.source = { 0.999 }
        #expect(Sheep(100, 100).getRandomQuip() == "Ow! Just kidding, I'm made of pixels.")
    }

    @Test func pettingStartsAndStops() {
        withSim(now: localMs(hour: 12), random: [0.5]) {
            let s = idleSheep()
            s.startPetting()
            #expect(s.state == .petting)
            s.stopPetting()
            #expect(s.state == .idle)
            #expect(s.stateDuration == 2000 + 0.5 * 3000)
            s.stopPetting() // not petting: no-op
            #expect(s.state == .idle)
            s.grab()
            s.startPetting()
            #expect(s.state == .grabbed)
        }
    }
}

@Suite("sheep long-run simulation", .serialized)
struct SheepSimulationTests {
    /// Runs every personality for ~6 simulated minutes (bored behaviours kick
    /// in after 2) drawing along the way: no crashes, sheep stay on screen.
    @Test func longRunStaysSaneForEveryPersonality() {
        let savedRandom = SimRandom.source
        let savedNow = SimClock.nowSource
        defer {
            SimRandom.source = savedRandom
            SimClock.nowSource = savedNow
        }
        final class Clock { var ms = 1_800_000_000_000.0 }
        let clock = Clock()
        SimClock.nowSource = { clock.ms }
        SimRandom.source = SimRandom.seeded(42)

        let personalities: [FriendPersonality?] = [nil, .snarky, .wholesome, .chaotic, .passiveAggressive]
        let sheep = personalities.enumerated().map { i, p -> Sheep in
            let s = Sheep(1512, 982, "friend_\(i)", FRIEND_TINTS[.blue], Double(200 + i * 250), 0.9 + Double(i) * 0.05)
            s.name = "Friend \(i)"
            s.personality = p
            s.platforms = [WindowPlatform(x: 300, y: 500, w: 600, h: 400)]
            return s
        }
        let canvas = Canvas()
        var seenStates = Set<SheepState>()
        for frame in 0..<22_000 {
            clock.ms += 16
            for s in sheep {
                s.update(16)
                seenStates.insert(s.state)
                #expect(s.x.isFinite && s.y.isFinite)
                #expect(s.x >= -1 && s.x <= 1512)
            }
            if frame % 7 == 0 {
                canvas.beginFrame()
                for s in sheep { canvas.group(s.id) { s.draw(canvas) } }
            }
        }
        // Bored behaviours, walking and sitting all showed up
        for state in [SheepState.walk, .sit, .idleCampfire, .idleCounting, .idleSleep] {
            #expect(seenStates.contains(state), "never entered \(state.rawValue)")
        }
    }
}

@Suite("sheep drawing")
struct SheepDrawingTests {
    private func frame(_ sheep: Sheep, key: String = "s") -> (canvas: Canvas, ops: Int) {
        let canvas = Canvas()
        canvas.beginFrame()
        canvas.group(key) { sheep.draw(canvas) }
        return (canvas, canvas.groups.first { $0.key == key }?.ops.count ?? 0)
    }

    @Test func everyStateRecordsOpsWithoutCrashing() {
        for state in SheepState.allCases {
            let sheep = Sheep(1512, 982, "friend_1", FRIEND_TINTS[.pink], 300, 1.1)
            sheep.name = "Friend"
            sheep.drawOverlay = createCompositeOverlay(getAccessoryDefs().map(\.id))
            sheep.state = state
            sheep.y = sheep.groundY
            sheep.stateTimer = 1234
            sheep.stateDuration = 20000
            sheep.vy = -300
            let (canvas, ops) = frame(sheep)
            #expect(ops > 0, "state \(state.rawValue) recorded no ops")
            #expect(!canvas.groups.isEmpty)
        }
    }

    @Test func everyStateDrawsFacingBothWays() {
        for state in SheepState.allCases {
            for facing in [true, false] {
                let sheep = Sheep(1512, 982, "main", nil, 300)
                sheep.state = state
                sheep.facingRight = facing
                sheep.y = sheep.groundY
                sheep.stateTimer = 777
                sheep.stateDuration = 15000
                sheep.vy = 200
                #expect(frame(sheep).ops > 0)
            }
        }
    }

    @Test func nameTagIsDrawnForCalmNamedFriendsOnly() {
        func sheep(_ id: String, name: String, state: SheepState) -> Sheep {
            let s = Sheep(1512, 982, id, nil, 300)
            s.name = name
            s.state = state
            s.y = s.groundY
            return s
        }
        // A tag is one rounded-rect fill plus one text op.
        let plain = frame(sheep("friend_1", name: "Sheep", state: .idle)).ops
        #expect(frame(sheep("friend_1", name: "Barry", state: .idle)).ops == plain + 2)
        // The main sheep never gets a tag
        #expect(frame(sheep("main", name: "Gary", state: .idle)).ops == plain)
        // Not calm (headshake): the tag stays invisible
        let shaking = frame(sheep("friend_1", name: "Sheep", state: .headshake)).ops
        #expect(frame(sheep("friend_1", name: "Barry", state: .headshake)).ops == shaking)
    }

    @Test func nameTagFadesOutWhenTheSheepStopsBeingCalm() {
        let s = Sheep(1512, 982, "friend_1", nil, 300)
        s.name = "Barry"
        s.state = .idle
        for _ in 0..<30 { _ = frame(s) } // fully faded in
        s.state = .headshake
        s.stateDuration = 1000

        let reference = Sheep(1512, 982, "friend_1", nil, 300)
        reference.state = .headshake
        reference.stateDuration = 1000
        let without = frame(reference).ops

        // Alpha decays 0.05 per drawn frame: still visible right after...
        #expect(frame(s).ops == without + 2)
        // ...and gone after 20 more frames
        for _ in 0..<25 { _ = frame(s) }
        #expect(frame(s).ops == without)
    }

    @Test func campfireAwayFromTheSheepGetsItsOwnTile() {
        let onGround = Sheep(1512, 982, "main", nil, 300)
        onGround.state = .idleCampfire
        onGround.y = onGround.groundY
        #expect(frame(onGround).canvas.groups.map(\.key) == ["s"])

        let onWindow = Sheep(1512, 982, "main", nil, 300)
        onWindow.state = .idleCampfire
        onWindow.y = 200
        let canvas = frame(onWindow).canvas
        #expect(canvas.groups.map(\.key) == ["s", "sheep:main:ground"])
        // The sheep's own tile stays near the sheep
        let sheepTile = canvas.groups[0].bounds
        #expect(sheepTile.maxY < onWindow.groundY)
    }

    @Test func drawWithoutAnOverlayIsJustTheSprite() {
        let sheep = Sheep(1512, 982, "main", nil, 300)
        sheep.state = .idle
        sheep.y = sheep.groundY
        #expect(frame(sheep).ops == 1)
    }

    @Test func seasonalOverlayIsDrawnAfterTheAccessories() {
        let sheep = Sheep(1512, 982, "main", nil, 300)
        sheep.state = .idle
        var order: [String] = []
        sheep.drawOverlay = { _, _, _, _, _, _ in order.append("overlay") }
        sheep.seasonalOverlay = { _, _, _, _, _, _ in order.append("seasonal") }
        _ = frame(sheep)
        #expect(order == ["overlay", "seasonal"])
    }
}

@Suite("no hovering in gravity-free states")
struct NoHoverTests {
    @Test func aSheepPutInSitMidAirFallsInsteadOfHovering() {
        let sheep = Sheep(1512, 982)
        settle(sheep)
        let ground = sheep.y
        // What a group-activity poke or an early cancel does to an airborne sheep
        sheep.y = ground - 300
        sheep.state = .sit
        sheep.stateDuration = 5000
        sheep.update(16)
        #expect(sheep.state == .parachute)
        settle(sheep)
        #expect(sheep.y == ground)
    }

    @Test func pettingIsRefusedWhileFallingOrStacked() {
        let sheep = Sheep(1512, 982)
        sheep.state = .fall
        sheep.startPetting()
        #expect(sheep.state == .fall)
        sheep.state = .stacked
        sheep.startPetting()
        #expect(sheep.state == .stacked)
    }

    @Test func zoomingOffAWindowEdgeFalls() {
        let sheep = Sheep(1512, 982)
        let window = WindowPlatform(x: 400, y: 400, w: 300, h: 500)
        sheep.platforms = [window]
        sheep.currentPlatform = window
        sheep.state = .idle
        sheep.y = 400 - sheep.displaySize
        sheep.x = 600
        sheep.playAnimation(.zoom)
        sheep.facingRight = true
        for _ in 0..<20 { sheep.update(16) }
        #expect(sheep.currentPlatform == nil)
        #expect(sheep.state == .parachute)
    }

    @Test func groupActivitiesLeaveAListeningSheepAlone() {
        let sheep = Sheep(1512, 982)
        settle(sheep)
        sheep.startListening()
        #expect(!sheep.canBeDirected)
        sheep.stopListening()
        #expect(sheep.canBeDirected)
        sheep.state = .grabbed
        #expect(!sheep.canBeDirected)
    }
}

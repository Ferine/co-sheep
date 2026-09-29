import Foundation
import Testing
@testable import CoSheepKit

// No TS tests exist for group-activities.ts: these pin the ported behavior.

private let W = 1512.0
private let H = 982.0
private let DS = 96.0

/// A little stage of sheep + bubbles (ids → characters) for driving the
/// activity functions directly.
private final class Stage {
    var characters: [String: FlockCharacter] = [:]
    let ids: [String]

    init(_ xs: [(String, Double)], personalities: [String: String] = [:]) {
        ids = xs.map { $0.0 }
        for (id, x) in xs {
            let sheep = Sheep(W, H, id, nil, x)
            sheep.state = .idle
            sheep.y = sheep.groundY
            sheep.stateDuration = 1e12
            let bubble = SpeechBubble(listenToCommentary: false)
            characters[id] = FlockCharacter(sheep: sheep, bubble: bubble, personality: personalities[id])
        }
    }

    func lookup(_ id: String) -> FlockCharacter? { characters[id] }
    func sheep(_ id: String) -> Sheep { characters[id]!.sheep }
    func bubble(_ id: String) -> SpeechBubble { characters[id]!.bubble }

    isolated deinit {
        // Bubbles own real timers; cancel them so a later run-loop spin is quiet.
        for c in characters.values { c.bubble.hide() }
    }
}

@discardableResult
private func withSeed<T>(_ seed: UInt64, _ body: () throws -> T) rethrows -> T {
    let saved = SimRandom.source
    SimRandom.source = SimRandom.seeded(seed)
    defer { SimRandom.source = saved }
    return try body()
}

@discardableResult
private func withRandom<T>(_ values: [Double], _ body: () throws -> T) rethrows -> T {
    let saved = SimRandom.source
    var i = 0
    SimRandom.source = {
        defer { i += 1 }
        return values[min(i, values.count - 1)]
    }
    defer { SimRandom.source = saved }
    return try body()
}

/// Step an activity in 16ms frames until it reports done (or `maxFrames`).
@discardableResult
private func run(_ activity: GroupActivity, _ stage: Stage, _ theme: EasterTheme? = nil,
                 maxFrames: Int = 6000, _ perFrame: (() -> Void)? = nil) -> Int {
    for frame in 1...maxFrames {
        perFrame?()
        if !updateGroupActivity(activity, 16, stage.lookup, theme) { return frame }
    }
    return -1
}

@Suite("canStartGroupActivity", .serialized)
struct CanStartGroupActivityTests {
    @Test func needsThreeCalmSheep() {
        #expect(canStartGroupActivity([("a", 100, true), ("b", 150, true)]) == nil)
        #expect(canStartGroupActivity([("a", 100, true), ("b", 150, true), ("c", 200, false)]) == nil)
    }

    @Test func clustersCalmSheepWithinFiveDisplayWidths() {
        let ids = canStartGroupActivity([("a", 100, true), ("b", 300, true), ("c", 500, true)])
        #expect(ids == ["a", "b", "c"])
    }

    @Test func farApartSheepDoNotCluster() {
        // Every pair is > 480px apart.
        let ids = canStartGroupActivity([("a", 0, true), ("b", 600, true), ("c", 1200, true)])
        #expect(ids == nil)
    }

    @Test func excludesNonCalmSheepFromTheCluster() {
        let ids = canStartGroupActivity([
            ("a", 100, true), ("busy", 120, false), ("b", 200, true), ("c", 300, true),
        ])
        #expect(ids == ["a", "b", "c"])
    }

    @Test func theClusterIsAnchoredOnTheFirstSheepThatHasTwoNeighbours() {
        // a has only b in range (a-c is 500 apart), so the cluster is anchored on b.
        let ids = canStartGroupActivity([("a", 0, true), ("b", 300, true), ("c", 500, true)])
        #expect(ids == ["b", "a", "c"])
    }

    @Test func rangeIsExclusiveAtFiveDisplayWidths() {
        #expect(canStartGroupActivity([("a", 0, true), ("b", 480, true), ("c", 481, true)]) == nil)
    }
}

@Suite("createGroupActivity / pickActivityType", .serialized)
struct CreateGroupActivityTests {
    @Test func durationsSpanTheirRanges() {
        let ids = ["a", "b", "c"]
        let expected: [(GroupActivityType, ClosedRange<Double>)] = [
            (.campfireCircle, 15000...25000),
            (.followLeader, 10000...15000),
            (.syncBounce, 6000...6000),
            (.huddle, 10000...15000),
            (.easterEggHunt, 20000...30000),
            (.sunbathe, 14000...22000),
        ]
        for (type, range) in expected {
            let low = withRandom([0]) { createGroupActivity(type, ids, 500) }
            let high = withRandom([0.999999]) { createGroupActivity(type, ids, 500) }
            #expect(low.duration == range.lowerBound, "\(type)")
            #expect(abs(high.duration - range.upperBound) < 0.02, "\(type)")
        }
    }

    @Test func startsInGatheringWithPerTypeState() {
        let ids = ["a", "b", "c"]
        let campfire = withSeed(1) { createGroupActivity(.campfireCircle, ids, 320) }
        #expect(campfire.phase == .gathering)
        #expect(campfire.timer == 0)
        #expect(campfire.centerX == 320)
        #expect(campfire.participants == ids)
        #expect(campfire.leaderId == nil)
        #expect(campfire.bounceCount == nil)
        #expect(campfire.eggAssignments == nil)
        #expect(campfire.quipTimer == nil)

        let follow = withSeed(2) { createGroupActivity(.followLeader, ids, 0) }
        #expect(ids.contains(follow.leaderId ?? ""))

        let bounce = withSeed(3) { createGroupActivity(.syncBounce, ids, 0) }
        #expect(bounce.bounceCount == 0)

        let hunt = withSeed(4) { createGroupActivity(.easterEggHunt, ids, 0) }
        #expect(hunt.eggAssignments == [:])
        #expect(hunt.collectedEggs == [])
        #expect(hunt.eggFinders == [:])
        #expect(hunt.eggReactionTimer == 0)

        let sun = withSeed(5) { createGroupActivity(.sunbathe, ids, 0) }
        #expect(sun.quipTimer == 3000)
    }

    @Test func consumesTheSameRandomRollsAsTheTS() {
        // The TS builds the whole durations record (5 rolls) and then, for
        // follow_leader only, rolls the leader.
        for (type, rolls) in [(GroupActivityType.campfireCircle, 5), (.followLeader, 6), (.huddle, 5)] {
            var count = 0
            let saved = SimRandom.source
            SimRandom.source = { count += 1; return 0.5 }
            _ = createGroupActivity(type, ["a", "b", "c"], 0)
            SimRandom.source = saved
            #expect(count == rolls, "\(type)")
        }
    }

    @Test func leaderIsPickedByTheRoll() {
        let a = withRandom([0, 0, 0, 0, 0, 0]) { createGroupActivity(.followLeader, ["a", "b", "c"], 0) }
        let c = withRandom([0, 0, 0, 0, 0, 0.99]) { createGroupActivity(.followLeader, ["a", "b", "c"], 0) }
        #expect(a.leaderId == "a")
        #expect(c.leaderId == "c")
    }

    @Test func pickActivityTypeFollowsTheSeasonThemes() {
        let easter = EasterTheme(W, H)
        easter.setModeOverride(.on)
        let summer = SummerTheme(W, H)
        summer.setModeOverride(.on)

        withRandom([0.39]) { #expect(pickActivityType(easter, summer) == .easterEggHunt) }
        // Easter roll fails (0.4 is not < 0.4), summer roll succeeds.
        withRandom([0.4, 0.39]) { #expect(pickActivityType(easter, summer) == .sunbathe) }
        // Both rolls fail: a uniform pick among the four standard types.
        withRandom([0.5, 0.5, 0.0]) { #expect(pickActivityType(easter, summer) == .campfireCircle) }
        withRandom([0.5, 0.5, 0.99]) { #expect(pickActivityType(easter, summer) == .huddle) }

        easter.setModeOverride(.off)
        summer.setModeOverride(.off)
        // Inactive themes don't even consume a roll: the first roll picks the type.
        withRandom([0.0]) { #expect(pickActivityType(easter, summer) == .campfireCircle) }
        withRandom([0.3]) { #expect(pickActivityType(nil, nil) == .followLeader) }
        withRandom([0.6]) { #expect(pickActivityType() == .syncBounce) }
    }
}

@Suite("group activity phases", .serialized)
struct GroupActivityPhaseTests {
    @Test func gatheringSendsFarSheepTowardTheCenterSpreadByIndex() {
        let stage = Stage([("a", 100), ("b", 600), ("c", 1300)])
        let activity = withSeed(1) { createGroupActivity(.huddle, stage.ids, 700) }
        _ = updateGroupActivity(activity, 16, stage.lookup)

        #expect(activity.phase == .gathering)
        // walkTarget = centerX + (index - 1) * 0.8 * DS
        #expect(stage.sheep("a").walkTarget == 700 - 0.8 * DS)
        #expect(stage.sheep("b").walkTarget == nil) // within 1.5 DS of the center already
        #expect(stage.sheep("c").walkTarget == 700 + 0.8 * DS)
    }

    @Test func gatheringDoesNotRetargetASheepThatAlreadyHasATarget() {
        let stage = Stage([("a", 100), ("b", 200), ("c", 300)])
        stage.sheep("a").walkTarget = 42
        let activity = withSeed(1) { createGroupActivity(.huddle, stage.ids, 700) }
        _ = updateGroupActivity(activity, 16, stage.lookup)
        #expect(stage.sheep("a").walkTarget == 42)
    }

    @Test func performingStartsWhenEveryoneIsWithinTwoDisplayWidths() {
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withSeed(1) { createGroupActivity(.huddle, stage.ids, 700) }
        _ = updateGroupActivity(activity, 16, stage.lookup)
        #expect(activity.phase == .performing)
        #expect(activity.timer == 0)
        #expect(stage.bubble("a").visible)
        #expect(stage.bubble("a").currentText == "Group meeting!")
    }

    @Test func gatheringTimesOutAfterEightSecondsAndPerformsAnyway() {
        let stage = Stage([("a", 0), ("b", 60), ("c", 1400)])
        let activity = withSeed(1) { createGroupActivity(.campfireCircle, stage.ids, 700) }
        for _ in 0..<499 { _ = updateGroupActivity(activity, 16, stage.lookup) }
        #expect(activity.phase == .gathering) // 7984ms
        _ = updateGroupActivity(activity, 16, stage.lookup) // 8000: not yet (> 8000)
        #expect(activity.phase == .gathering)
        _ = updateGroupActivity(activity, 16, stage.lookup)
        #expect(activity.phase == .performing)
        #expect(stage.bubble("a").currentText == "Campfire time!")
    }

    @Test func announcementsPerType() {
        let expected: [(GroupActivityType, String?)] = [
            (.huddle, "Group meeting!"), (.campfireCircle, "Campfire time!"),
            (.sunbathe, "Sunbathing time!"), (.followLeader, nil), (.syncBounce, nil),
        ]
        for (type, text) in expected {
            let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
            let activity = withSeed(1) { createGroupActivity(type, stage.ids, 700) }
            _ = updateGroupActivity(activity, 16, stage.lookup)
            #expect(activity.phase == .performing, "\(type)")
            if let text {
                #expect(stage.bubble("a").currentText == text, "\(type)")
            } else {
                #expect(!stage.bubble("a").visible, "\(type)")
            }
        }
    }

    @Test func aMissingParticipantIsSkipped() {
        let stage = Stage([("a", 640), ("b", 700)])
        let activity = withSeed(1) { createGroupActivity(.huddle, ["a", "ghost", "b"], 700) }
        let frames = run(activity, stage)
        #expect(frames > 0)
    }

    @Test func dispersalSendsEveryoneOffAndLastsThreeSeconds() throws {
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withSeed(7) { createGroupActivity(.huddle, stage.ids, 700) }
        var dispersedAt: Int?
        for frame in 1...6000 {
            let wasDispersing = activity.phase == .dispersing
            let alive = updateGroupActivity(activity, 16, stage.lookup)
            if !wasDispersing && activity.phase == .dispersing {
                dispersedAt = frame
                for id in stage.ids {
                    let start = stage.sheep(id).x
                    let target = try #require(stage.sheep(id).walkTarget)
                    let dist = abs(target - start)
                    #expect(dist >= 2 * DS && dist <= 5 * DS, "walk \(dist)")
                }
                #expect(activity.timer == 0)
            }
            if !alive {
                // 3000ms / 16 = 187.5 → the 188th dispersing frame ends it.
                #expect(frame - dispersedAt! == 188)
                return
            }
        }
        Issue.record("activity never ended")
    }

    @Test func performingRunsExactlyItsDuration() {
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withRandom([0]) { createGroupActivity(.huddle, stage.ids, 700) } // 10000ms
        _ = updateGroupActivity(activity, 16, stage.lookup) // gathering → performing
        #expect(activity.phase == .performing)
        var frames = 0
        while activity.phase == .performing {
            _ = updateGroupActivity(activity, 16, stage.lookup)
            frames += 1
        }
        // timer += 16 each frame; the phase flips once timer >= 10000 (625 frames).
        #expect(frames == 625)
        #expect(activity.phase == .dispersing)
    }
}

@Suite("group activity types", .serialized)
struct GroupActivityTypeTests {
    @Test func campfireCircleLeaderLightsTheFireOthersSit() {
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withSeed(1) { createGroupActivity(.campfireCircle, stage.ids, 700) }
        _ = updateGroupActivity(activity, 16, stage.lookup) // → performing
        _ = updateGroupActivity(activity, 16, stage.lookup) // first performing frame

        #expect(stage.sheep("a").state == .idleCampfire)
        #expect(stage.sheep("a").stateDuration == activity.duration)
        #expect(stage.sheep("a").campfireSparks.isEmpty)
        #expect(stage.sheep("b").state == .sit)
        #expect(stage.sheep("c").state == .sit)
        #expect(stage.sheep("b").stateDuration == activity.duration)

        let frames = run(activity, stage)
        #expect(frames > 0)
    }

    @Test func followLeaderLeaderWalksFollowersTrackIt() {
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withRandom([0, 0, 0, 0, 0, 0.5]) { createGroupActivity(.followLeader, stage.ids, 700) }
        #expect(activity.leaderId == "b")
        _ = updateGroupActivity(activity, 16, stage.lookup) // → performing
        _ = updateGroupActivity(activity, 16, stage.lookup)

        let leader = stage.sheep("b")
        #expect(leader.state == .walk)
        #expect(leader.stateDuration == activity.duration)
        // Followers aim at wherever the leader currently is.
        leader.x = 900
        _ = updateGroupActivity(activity, 16, stage.lookup)
        #expect(stage.sheep("a").walkTarget == 900)
        #expect(stage.sheep("c").walkTarget == 900)
        #expect(leader.walkTarget == nil)

        #expect(run(activity, stage) > 0)
    }

    @Test func followLeaderWithAMissingLeaderJustWaits() {
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withSeed(1) { createGroupActivity(.followLeader, ["a", "b", "ghost"], 700) }
        activity.leaderId = "ghost"
        #expect(run(activity, stage) > 0)
        #expect(stage.sheep("a").walkTarget != nil) // only the dispersal target
    }

    @Test func syncBounceBouncesFourTimesEveryOneAndAHalfSecondsStaggered() {
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withSeed(1) { createGroupActivity(.syncBounce, stage.ids, 700) }
        _ = updateGroupActivity(activity, 16, stage.lookup) // → performing
        var counts: [Int] = []
        while activity.phase == .performing {
            _ = updateGroupActivity(activity, 16, stage.lookup)
            if counts.last != activity.bounceCount { counts.append(activity.bounceCount ?? -1) }
        }
        #expect(counts == [0, 1, 2, 3, 4])
        // The staggered playAnimation calls are setTimeouts at 0/150/300ms.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        for id in stage.ids {
            #expect(stage.sheep(id).state == .bounce, "\(id)")
        }
    }

    @Test func huddleSitsEveryoneExceptIdleSheepAlreadyResting() {
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        stage.sheep("b").state = .walk
        let activity = withSeed(1) { createGroupActivity(.huddle, stage.ids, 700) }
        _ = updateGroupActivity(activity, 16, stage.lookup)
        _ = updateGroupActivity(activity, 16, stage.lookup)
        #expect(stage.sheep("a").state == .idle) // idle is left alone
        #expect(stage.sheep("b").state == .sit)
        #expect(stage.sheep("b").stateDuration == activity.duration)
        #expect(stage.sheep("c").state == .idle)
    }

    @Test func sunbatheSitsEveryoneAndBlurtsLazyQuips() throws {
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withSeed(1) { createGroupActivity(.sunbathe, stage.ids, 700) }
        _ = updateGroupActivity(activity, 16, stage.lookup) // → performing
        #expect(stage.bubble("a").currentText == "Sunbathing time!")
        stage.bubble("a").hide()

        _ = updateGroupActivity(activity, 16, stage.lookup)
        for id in stage.ids { #expect(stage.sheep(id).state == .sit) }
        #expect(activity.quipTimer == 2984.0)

        // Run until the first quip lands (3000ms) — some sunbather says a SUNBATHE quip.
        var quip: String?
        for _ in 0..<400 {
            _ = updateGroupActivity(activity, 16, stage.lookup)
            if let c = stage.characters.values.first(where: { $0.bubble.visible }) {
                quip = c.bubble.currentText
                break
            }
        }
        #expect(SUNBATHE_QUIPS.contains(quip ?? ""))
        // ...and re-armed the timer 4.5–8.5s out.
        let next = try #require(activity.quipTimer)
        #expect(next >= 4500 - 16 && next <= 8500)
    }

    @Test func sunbatheQuipsSkipASunbatherThatIsAlreadyTalking() {
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withRandom([0]) { createGroupActivity(.sunbathe, stage.ids, 700) }
        _ = updateGroupActivity(activity, 16, stage.lookup) // → performing
        stage.bubble("a").hide()
        stage.bubble("a").show("busy talking", duration: 60_000)
        activity.quipTimer = 1
        withRandom([0]) { // picks participant 0 = a
            _ = updateGroupActivity(activity, 16, stage.lookup)
        }
        #expect(stage.bubble("a").currentText == "busy talking")
        #expect(activity.quipTimer! >= 4500)
    }

    @Test func everyStandardTypeRunsToCompletion() {
        for type in [GroupActivityType.campfireCircle, .followLeader, .syncBounce, .huddle, .sunbathe] {
            let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
            let activity = withSeed(11) { createGroupActivity(type, stage.ids, 700) }
            let frames = run(activity, stage)
            #expect(frames > 0, "\(type) never finished")
            // gathering (1 frame) + duration + 3s dispersal, all at 16ms per frame.
            let expected = (activity.duration + 3000) / 16
            #expect(Double(frames) >= expected - 2 && Double(frames) <= expected + 4, "\(type) \(frames) vs \(expected)")
            #expect(activity.phase == .dispersing)
        }
    }
}

@Suite("easter egg hunt", .serialized)
struct EasterEggHuntTests {
    private func theme() -> EasterTheme {
        let t = EasterTheme(W, H)
        t.setModeOverride(.on)
        return t
    }

    /// Teleport every participant onto its assigned egg so it is collected
    /// on the next update (sheep walk at 60px/s — too slow for a test).
    private func snapToEggs(_ activity: GroupActivity, _ stage: Stage, _ theme: EasterTheme) {
        let eggs = theme.getEggPositions()
        for id in activity.participants {
            if let idx = activity.eggAssignments?[id] {
                let sheep = stage.sheep(id)
                sheep.x = eggs[idx].x - sheep.displaySize / 2
            }
        }
    }

    /// Nudge every sheep (in place) until its center is at least 50px from every egg, so no
    /// egg is collected by accident (the eggs land wherever the RNG puts them).
    private func keepClear(_ stage: Stage, _ theme: EasterTheme) {
        let eggs = theme.getEggPositions().map(\.x)
        for id in stage.ids {
            let sheep = stage.sheep(id)
            let half = sheep.displaySize / 2
            var offset = 0.0
            for step in 0..<400 {
                offset = Double((step + 1) / 2) * 5 * (step % 2 == 0 ? 1 : -1)
                let center = sheep.x + offset + half
                if eggs.allSatisfy({ abs($0 - center) >= 50 }) && sheep.x + offset >= 0
                    && sheep.x + offset <= W - sheep.displaySize { break }
            }
            sheep.x += offset
        }
    }

    /// A hunt that has just entered its performing phase with everyone clear of the eggs.
    private func performingHunt(seed: UInt64, _ stage: Stage, _ easter: EasterTheme) -> GroupActivity {
        let activity = withSeed(seed) { createGroupActivity(.easterEggHunt, stage.ids, 700) }
        withSeed(seed) { _ = updateGroupActivity(activity, 16, stage.lookup, easter) } // gathering → performing (reseeds the eggs)
        keepClear(stage, easter)
        return activity
    }

    @Test func gatheringPreparesTheHuntAndSeedsTheSummary() throws {
        let easter = theme()
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withSeed(1) { createGroupActivity(.easterEggHunt, stage.ids, 700) }
        _ = updateGroupActivity(activity, 16, stage.lookup, easter)

        #expect(activity.phase == .performing)
        #expect(stage.bubble("a").currentText == "Easter egg hunt!")
        let summary = try #require(activity.huntSummary)
        #expect(summary.totalEggs == easter.getEggPositions().count)
        #expect(summary.totalEggs > 0)
        #expect(summary.durationMs == 0)
        #expect(!summary.allCollected)
        #expect(summary.finders.isEmpty)
        // Baskets appear for the hunters.
        for id in stage.ids { #expect(easter.shouldShowBasket(id)) }
    }

    @Test func withoutAThemeTheHuntIsAnEmptyPerformance() throws {
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withSeed(1) { createGroupActivity(.easterEggHunt, stage.ids, 700) }
        #expect(run(activity, stage, nil) > 0)
        // No theme: nothing seeded the summary while gathering, so the one
        // finalized at hunt end has no eggs — and, unlike the themed hunt, it
        // does capture the elapsed duration (`nil ?? activity.timer`).
        let summary = try #require(activity.huntSummary)
        #expect(summary.totalEggs == 0)
        #expect(!summary.allCollected)
        #expect(summary.winnerId == nil)
        #expect(summary.durationMs >= activity.duration)
    }

    @Test func participantsWalkTowardTheirNearestEggByFacing() throws {
        let easter = theme()
        let stage = Stage([("a", 100), ("b", 700), ("c", 1400)])
        let activity = withSeed(1) { createGroupActivity(.easterEggHunt, stage.ids, 700) }
        activity.timer = 8100 // gathering times out (a and c are too far away to gather)
        withSeed(1) { _ = updateGroupActivity(activity, 16, stage.lookup, easter) } // → performing
        keepClear(stage, easter)
        _ = updateGroupActivity(activity, 16, stage.lookup, easter) // assign + steer

        let eggs = easter.getEggPositions()
        let assignments = try #require(activity.eggAssignments)
        #expect(assignments.count == 3)
        // Nobody shares an egg on the first pass.
        #expect(Set(assignments.values).count == 3)
        for id in stage.ids {
            let sheep = stage.sheep(id)
            let egg = eggs[assignments[id]!]
            #expect(sheep.walkTarget == nil)
            #expect(sheep.state == .walk)
            #expect(sheep.stateDuration == 15000)
            #expect(sheep.facingRight == (egg.x > sheep.x + sheep.displaySize / 2))
        }
        // The leftmost sheep is nearest to some egg no farther than any other sheep-egg pairing
        // it could have made: its egg is the closest one to it.
        let a = stage.sheep("a")
        let nearest = eggs.enumerated().min { abs($0.element.x - (a.x + 48)) < abs($1.element.x - (a.x + 48)) }!.offset
        #expect(assignments["a"] == nearest)
    }

    @Test func collectingAnEggRecordsTheFinderAndReacts() throws {
        let easter = theme()
        let stage = Stage(
            [("a", 640), ("b", 700), ("good_colleague", 760)],
            personalities: ["a": "chaotic", "b": "snarky", "good_colleague": "snarky"]
        )
        let activity = performingHunt(seed: 1, stage, easter)
        _ = updateGroupActivity(activity, 16, stage.lookup, easter) // assign
        for id in stage.ids { stage.bubble(id).hide() }
        snapToEggs(activity, stage, easter)
        _ = updateGroupActivity(activity, 16, stage.lookup, easter) // collect

        let collected = try #require(activity.collectedEggs)
        #expect(collected.count == 3)
        for id in stage.ids {
            #expect(activity.eggFinders?[id]?.eggsFound == 1)
            #expect(stage.sheep(id).state == .bounce)
            #expect(stage.bubble(id).visible)
        }
        let chaotic = GroupActivityData.EGG_HUNT_PERSONALITY_QUIPS["chaotic"]!
        let snarky = GroupActivityData.EGG_HUNT_PERSONALITY_QUIPS["snarky"]!
        let colleague = GroupActivityData.EGG_HUNT_PERSONALITY_QUIPS["good_colleague"]!
        #expect(chaotic.contains(stage.bubble("a").currentText))
        // Good Colleague keeps its own pool even though it is also "snarky".
        #expect(colleague.contains(stage.bubble("good_colleague").currentText))
        #expect(snarky.contains(stage.bubble("b").currentText))
        // The theme saw the pickups (baskets fill).
        #expect(easter.getBasketEggCount("a") >= 1)
    }

    @Test func aSheepWithoutAPersonalityUsesTheGenericQuips() {
        let easter = theme()
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = performingHunt(seed: 2, stage, easter)
        _ = updateGroupActivity(activity, 16, stage.lookup, easter)
        for id in stage.ids { stage.bubble(id).hide() }
        snapToEggs(activity, stage, easter)
        _ = updateGroupActivity(activity, 16, stage.lookup, easter)
        #expect(GroupActivityData.EGG_HUNT_QUIPS.contains(stage.bubble("a").currentText))
    }

    @Test func collectingEveryEggCelebratesThenDispersesAndSummarises() throws {
        let easter = theme()
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withSeed(3) { createGroupActivity(.easterEggHunt, stage.ids, 700) }
        var sawCelebrating = false
        let frames = run(activity, stage, easter) {
            snapToEggs(activity, stage, easter)
            if activity.phase == .celebrating { sawCelebrating = true }
        }
        #expect(frames > 0)
        #expect(sawCelebrating)

        let summary = try #require(activity.huntSummary)
        #expect(summary.allCollected)
        #expect(summary.totalEggs == easter.getEggPositions().count)
        #expect(summary.finders.count == 3)
        #expect(summary.finders.reduce(0) { $0 + $1.eggsFound } == summary.totalEggs)
        // Sorted by eggs found, descending; the winner is the first finder.
        let counts = summary.finders.map(\.eggsFound)
        #expect(counts == counts.sorted(by: >))
        #expect(summary.winnerId == summary.finders.first?.id)
        #expect(activity.collectedEggs?.count == summary.totalEggs)
        // The celebration is over and the theme released the hunt (`finishHunt` starts the buzz timer).
        #expect(activity.phase == .dispersing)
        #expect(easter.hasRecentHuntBuzz())
        #expect(!easter.shouldShowBasket("zzz"))
    }

    @Test func celebrationShoutsAVictoryLineThenTheWinnerBrags() throws {
        let easter = theme()
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withSeed(3) { createGroupActivity(.easterEggHunt, stage.ids, 700) }
        _ = updateGroupActivity(activity, 16, stage.lookup, easter)
        // Get to the celebration.
        var guardFrames = 0
        while activity.phase != .celebrating && guardFrames < 6000 {
            snapToEggs(activity, stage, easter)
            _ = updateGroupActivity(activity, 16, stage.lookup, easter)
            guardFrames += 1
        }
        #expect(activity.phase == .celebrating)
        #expect(activity.eggReactionTimer == 850)
        #expect(activity.timer == 0)

        let winnerId = try #require(activity.huntSummary?.winnerId)
        #expect(GroupActivityData.EGG_HUNT_VICTORY_LINES.contains(stage.bubble(winnerId).currentText))
        for id in stage.ids { #expect(stage.sheep(id).state == .bounce) }

        // 850ms later the winner brags (once their victory bubble is gone).
        stage.bubble(winnerId).hide()
        for _ in 0..<54 { _ = updateGroupActivity(activity, 16, stage.lookup, easter) } // 864ms
        #expect(activity.eggReactionTimer == 0)
        #expect(GroupActivityData.EGG_HUNT_WINNER_LINES.contains(stage.bubble(winnerId).currentText))

        // 2200ms after the celebration began, everyone disperses.
        for _ in 0..<90 { _ = updateGroupActivity(activity, 16, stage.lookup, easter) }
        #expect(activity.phase == .dispersing)
    }

    @Test func aHuntNobodyFinishesEndsByTimeoutWithoutAWinner() throws {
        let easter = theme()
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        // Sheep never reach an egg (they aren't updated and sit far from every egg).
        for id in stage.ids { stage.sheep(id).x = 5000 }
        let activity = withRandom([0]) { createGroupActivity(.easterEggHunt, stage.ids, 5000) }
        #expect(run(activity, stage, easter) > 0)

        let summary = try #require(activity.huntSummary)
        #expect(!summary.allCollected)
        #expect(summary.winnerId == nil)
        #expect(summary.finders.allSatisfy { $0.eggsFound == 0 })
        #expect(activity.phase == .dispersing)
    }

    @Test func partialHuntSummaryRanksFindersAndBreaksTiesStablyByGoldenEggs() throws {
        let easter = theme()
        let stage = Stage([("a", 640), ("b", 700), ("c", 760), ("d", 820)])
        keepClear(stage, easter)
        let activity = withRandom([0]) { createGroupActivity(.easterEggHunt, stage.ids, 700) }
        activity.phase = .performing
        activity.eggFinders = [
            "a": EasterHuntFinder(eggsFound: 1, goldenEggsFound: 0),
            "b": EasterHuntFinder(eggsFound: 1, goldenEggsFound: 1),
            "c": EasterHuntFinder(eggsFound: 1, goldenEggsFound: 0),
            "d": EasterHuntFinder(eggsFound: 0, goldenEggsFound: 0),
        ]
        activity.timer = activity.duration // performing ends on this update
        _ = updateGroupActivity(activity, 16, stage.lookup, easter)

        let summary = try #require(activity.huntSummary)
        #expect(summary.finders.map(\.id) == ["b", "a", "c", "d"]) // golden first, then stable order
        #expect(summary.winnerId == "b")
        #expect(!summary.allCollected)
        #expect(activity.phase == .dispersing)
    }

    @Test func durationIsNeverCapturedAtHuntEnd() {
        // Ported as-is: the TS seeds `durationMs: 0` at the gathering →
        // performing switch, and `0 ?? activity.timer` is 0 (not nullish), so
        // the "duration captured at hunt end" comment never takes effect.
        let easter = theme()
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = withSeed(3) { createGroupActivity(.easterEggHunt, stage.ids, 700) }
        #expect(run(activity, stage, easter) { snapToEggs(activity, stage, easter) } > 0)
        #expect(activity.huntSummary?.durationMs == 0)
    }

    @Test func aParticipantAlreadyAssignedToACollectedEggGetsANewOne() throws {
        let easter = theme()
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = performingHunt(seed: 1, stage, easter)
        _ = updateGroupActivity(activity, 16, stage.lookup, easter)
        let before = try #require(activity.eggAssignments?["a"])
        // Someone else grabbed a's egg.
        activity.collectedEggs?.insert(before)
        _ = updateGroupActivity(activity, 16, stage.lookup, easter)
        let after = try #require(activity.eggAssignments?["a"])
        #expect(after != before)
    }

    @Test func aSheepWithNoEggsLeftSitsHappily() {
        let easter = theme()
        let stage = Stage([("a", 640), ("b", 700), ("c", 760)])
        let activity = performingHunt(seed: 1, stage, easter)
        // Every egg but one is already collected.
        activity.collectedEggs = Set(1..<easter.getEggPositions().count)
        activity.eggAssignments = [:]
        _ = updateGroupActivity(activity, 16, stage.lookup, easter)
        // Exactly one egg is left, so exactly one sheep gets it and the other two have none.
        let unassigned = stage.ids.filter { activity.eggAssignments?[$0] == nil }
        #expect(unassigned.count == 2)
        for id in unassigned {
            // Idle sheep are left alone; anything else is sat down.
            #expect(stage.sheep(id).state == .idle || stage.sheep(id).state == .sit)
        }
        let hunter = stage.ids.first { activity.eggAssignments?[$0] != nil }!
        #expect(stage.sheep(hunter).state == .walk)
    }
}

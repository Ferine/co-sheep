import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

// No TS tests exist for spectacle-render.ts: these pin the ported behavior.

private let W = 1512.0
private let H = 982.0
private let SIZE = 96.0

/// Characters + a `SpectacleWorld` over them.
private final class Arena {
    var characters: [String: FlockCharacter] = [:]
    let order: [String]
    var saved: [[String]] = []
    var saveWired = true

    init(_ xs: [(String, Double)]) {
        order = xs.map { $0.0 }
        for (id, x) in xs {
            let sheep = Sheep(W, H, id, nil, x)
            sheep.state = .idle
            sheep.y = sheep.groundY
            sheep.stateDuration = 1e12
            characters[id] = FlockCharacter(sheep: sheep, bubble: SpeechBubble(listenToCommentary: false),
                                            personality: nil)
        }
    }

    static func standard() -> Arena {
        Arena([("main", 300), ("good_colleague", 500), ("f1", 700), ("f2", 900)])
    }

    var world: SpectacleWorld {
        SpectacleWorld(
            getCharacter: { [unowned self] id in self.characters[id] },
            characterIds: { [unowned self] in self.order },
            screenW: W,
            screenH: H,
            saveAccessories: saveWired ? { [unowned self] in self.saved.append($0) } : nil
        )
    }

    func sheep(_ id: String) -> Sheep { characters[id]!.sheep }
    func bubble(_ id: String) -> SpeechBubble { characters[id]!.bubble }

    isolated deinit {
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

@discardableResult
private func withClock<T>(_ ms: Double, _ body: () throws -> T) rethrows -> T {
    let saved = SimClock.nowSource
    SimClock.nowSource = { ms }
    defer { SimClock.nowSource = saved }
    return try body()
}

/// Config on disk under a throwaway `Paths.root` (the merchant reads its
/// owned accessories from config.json).
@discardableResult
private func withRoot<T>(accessories: [String]?, _ body: () throws -> T) rethrows -> T {
    let saved = Paths.root
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("co-sheep-spectacle-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    Paths.root = dir
    if let accessories {
        var config = SheepConfig()
        config.accessories = accessories
        try? Config.writeConfig(config)
    }
    defer {
        Paths.root = saved
        try? FileManager.default.removeItem(at: dir)
    }
    return try body()
}

/// Step a scene in 16ms frames until it reports done; returns the frame it
/// finished on (-1 if it never did).
@discardableResult
private func run(_ scene: SpectacleScene, _ arena: Arena, maxFrames: Int = 6000,
                 _ perFrame: ((Int) -> Void)? = nil) -> Int {
    let world = arena.world
    for frame in 1...maxFrames {
        perFrame?(frame)
        if !updateSpectacleScene(scene, 16, world) { return frame }
    }
    return -1
}

/// Spin the main run loop (real time) until `condition` holds or `timeout` passes.
/// The sim's `setTimeout`s (`SimTimers`) are real timers.
private func pump(timeout: Double = 3, until condition: () -> Bool) {
    let end = Date(timeIntervalSinceNow: timeout)
    while !condition() && Date() < end {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
}

private func draw(_ scene: SpectacleScene, _ arena: Arena) -> Canvas {
    let canvas = Canvas()
    canvas.beginFrame()
    canvas.group("spectacle") { drawSpectacleScene(scene, canvas, arena.world) }
    return canvas
}

private func group(_ canvas: Canvas, _ key: String) -> CanvasGroup? {
    canvas.groups.first { $0.key == key }
}

@Suite("createSpectacleScene", .serialized)
struct CreateSpectacleSceneTests {
    @Test func startingPositionsAndPhasesPerType() {
        let calm = ["main", "f1"]
        let wolf = createSpectacleScene(.wolf, W, H, calm)
        #expect(wolf.phase == .enter)
        #expect(wolf.actorX == -SIZE)
        #expect(wolf.actorY == H - (SIZE + 10))
        #expect(wolf.facingRight)
        #expect(wolf.participants == calm)
        #expect(wolf.pairIds == nil)
        #expect(wolf.data.isEmpty)

        let merchant = createSpectacleScene(.merchant, W, H, calm)
        #expect(merchant.actorX == W + SIZE)
        #expect(!merchant.facingRight)

        let balloon = createSpectacleScene(.balloon, W, H, calm)
        #expect(balloon.actorY == H * 0.15)
        #expect(balloon.phase == .enter)

        let shearing = createSpectacleScene(.shearing, W, H, calm)
        #expect(shearing.phase == .perform)

        let showdown = createSpectacleScene(.showdown, W, H, calm, ("f1", "f2"))
        #expect(showdown.pairIds?.0 == "f1")
        #expect(showdown.pairIds?.1 == "f2")
        #expect(showdown.phase == .enter)

        let feast = createSpectacleScene(.feast, W, H, calm, ("f1", "f2"))
        #expect(feast.actorY == H - (SIZE + 10))
    }

    @Test func ufoPicksItsTargetFromTheCalmSheep() {
        let low = withRandom([0]) { createSpectacleScene(.ufo, W, H, ["a", "b", "c"]) }
        let high = withRandom([0.99]) { createSpectacleScene(.ufo, W, H, ["a", "b", "c"]) }
        #expect(low.targetId == "a")
        #expect(high.targetId == "c")
        #expect(low.actorY == -SIZE)
        // Nobody calm: the main sheep gets abducted by default.
        #expect(createSpectacleScene(.ufo, W, H, []).targetId == "main")
        // Only the UFO has a target.
        #expect(createSpectacleScene(.wolf, W, H, ["a"]).targetId == nil)
    }

    @Test func flagTreatsMissingAndZeroAsFalse() {
        let scene = createSpectacleScene(.wolf, W, H, [])
        #expect(!scene.flag("x"))
        scene.data["x"] = 0
        #expect(!scene.flag("x"))
        scene.data["x"] = 1
        #expect(scene.flag("x"))
    }
}

@Suite("wolf scare", .serialized)
struct WolfTests {
    @Test func wolfRunsInPausesAndLeavesInMatchingPhases() {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.wolf, W, H, arena.order)
        var phases: [SpectaclePhase] = [scene.phase]
        let frames = run(scene, arena) { _ in
            if phases.last != scene.phase { phases.append(scene.phase) }
        }
        #expect(phases == [.enter, .perform, .exit])
        // enter: 0.35px/ms from -96 to 0.3*W (453.6) ≈ 1570ms; perform 6000ms;
        // exit: 0.49px/ms back to -96 ≈ 1120ms.
        let expected = (1570.0 + 6000 + 1120) / 16
        #expect(abs(Double(frames) - expected) <= 4, "\(frames) vs \(expected)")
        #expect(!scene.facingRight)
    }

    @Test func theFlockFleesTheWolfInZoomMode() {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.wolf, W, H, arena.order)
        var fled = false
        run(scene, arena) { _ in
            if !fled && scene.phase == .perform {
                fled = true
                let wolfX = scene.actorX
                for id in arena.order {
                    let sheep = arena.sheep(id)
                    // Sheep left of the wolf run to x=0, the rest to the right edge.
                    #expect(sheep.walkTarget == (sheep.x < wolfX ? 0 : W - SIZE), "\(id)")
                    #expect(sheep.state == .zoom, "\(id)")
                }
            }
        }
        #expect(fled)
    }

    @Test func goodColleagueDeniesBeingScaredThreeSecondsIn() {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.wolf, W, H, arena.order)
        var quipAt: Double?
        run(scene, arena) { _ in
            if quipAt == nil, arena.bubble("good_colleague").visible {
                quipAt = scene.timer
                #expect(arena.bubble("good_colleague").currentText == "Jeg var IKKE redd.")
            }
        }
        let at = quipAt ?? 0
        #expect(at > 3000 && at < 3100)
        #expect(scene.flag("gcQuip"))
    }

    @Test func goodColleagueStaysQuietIfAlreadyTalking() {
        let arena = Arena.standard()
        arena.bubble("good_colleague").show("busy", duration: 600_000)
        let scene = createSpectacleScene(.wolf, W, H, arena.order)
        run(scene, arena)
        #expect(arena.bubble("good_colleague").currentText == "busy")
        #expect(scene.flag("gcQuip"))
    }

    @Test func atMostTwoSurvivorsSighWithReliefWhenTheWolfLeaves() {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.wolf, W, H, arena.order)
        run(scene, arena)
        let relief = ["That was TOO close.", "Wolves. WHY wolves.", "Never speak of this."]
        let talking = arena.order.filter { arena.bubble($0).visible }
        // good_colleague already has its "IKKE redd" bubble, so main and f1 get the relief lines.
        #expect(talking.contains("good_colleague"))
        let reliefs = arena.order.filter { relief.contains(arena.bubble($0).currentText) }
        #expect(reliefs.count == 2)
        #expect(reliefs == ["main", "f1"])
    }

    @Test func drawsAMirroredWolfInsideItsBox() throws {
        let scene = createSpectacleScene(.wolf, W, H, [])
        scene.actorX = 400
        scene.actorY = 700
        let right = try #require(group(draw(scene, Arena.standard()), "spectacle"))
        #expect(right.ops.count == 10)
        // Local x 12...90 (tail to snout), y 18...81 (ear to hooves) inside the 96px box.
        #expect(right.bounds.minX == 400 + 12 && right.bounds.maxX == 400 + 90)
        #expect(right.bounds.minY == 700 + 18 && right.bounds.maxY == 700 + 81)

        scene.facingRight = false
        let left = try #require(group(draw(scene, Arena.standard()), "spectacle"))
        #expect(left.ops.count == 10)
        // Mirrored about the box center: local u → 96 - u.
        #expect(left.bounds.minX == 400 + 6 && left.bounds.maxX == 400 + 84)
        #expect(left.bounds.minY == 700 + 18 && left.bounds.maxY == 700 + 81)
    }
}

@Suite("ufo", .serialized)
struct UfoTests {
    @Test func abductsHoldsAndDropsItsTarget() {
        let arena = Arena.standard()
        let scene = withRandom([0.6]) { createSpectacleScene(.ufo, W, H, arena.order) } // index 2 → f1
        #expect(scene.targetId == "f1")
        let target = arena.sheep("f1")
        var phases: [SpectaclePhase] = [scene.phase]
        var maxBeamY = target.y
        var minY = target.y
        let frames = run(scene, arena) { _ in
            if phases.last != scene.phase { phases.append(scene.phase) }
            if scene.phase == .enter && scene.timer > 0 {
                // The saucer follows its target's x.
                #expect(scene.actorX == target.x + SIZE / 2 - 40)
            }
            if scene.phase == .perform {
                #expect(target.state == .grabbed)
                #expect(target.stateDuration == 8000)
            }
            minY = min(minY, target.y)
            maxBeamY = max(maxBeamY, target.y)
        }
        #expect(phases == [.enter, .perform, .exit])
        // enter ≈ 1139ms (0.3px/ms to 25% of the screen height), perform 8s, exit ≈ 914ms.
        let expected = (1139.0 + 8000 + 914) / 16
        #expect(abs(Double(frames) - expected) <= 6, "\(frames) vs \(expected)")
        // The target was beamed up to just under the saucer (hoverY + 90) and released to fall.
        #expect(abs(minY - (H * 0.25 + 90)) < 0.15 * 16 + 0.001)
        #expect(target.state == .spin) // playAnimation("spin") at the end
        #expect(arena.bubble("f1").currentText == "I have SEEN things.")
    }

    @Test func releasedTargetFallsWithFourSecondBudgetWhileTheSaucerLeaves() {
        let arena = Arena.standard()
        let scene = withRandom([0]) { createSpectacleScene(.ufo, W, H, arena.order) }
        var sawFall = false
        run(scene, arena) { _ in
            if scene.phase == .exit && !sawFall {
                sawFall = true
                #expect(arena.sheep("main").state == .fall)
                #expect(arena.sheep("main").stateDuration == 4000)
            }
        }
        #expect(sawFall)
    }

    @Test func aSpeakingTargetKeepsItsBubble() {
        let arena = Arena.standard()
        let scene = withRandom([0]) { createSpectacleScene(.ufo, W, H, arena.order) }
        arena.bubble("main").show("chatting", duration: 600_000)
        run(scene, arena)
        #expect(arena.bubble("main").currentText == "chatting")
    }

    @Test func endsAtOnceWhenTheTargetIsGone() {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.ufo, W, H, ["ghost"])
        #expect(run(scene, arena) == 1)
    }

    @Test func fallsBackToTheMainSheepWhenNoTargetIsSet() {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.ufo, W, H, [])
        scene.targetId = nil
        #expect(run(scene, arena) > 1)
        #expect(arena.bubble("main").visible)
    }

    @Test func drawsABeamOnlyWhilePerforming() throws {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.ufo, W, H, arena.order)
        scene.actorX = 300
        scene.actorY = 200
        scene.phase = .enter
        let noBeam = try #require(group(withClock(0) { draw(scene, arena) }, "spectacle"))
        // saucer, dome and three window lights
        #expect(noBeam.ops.count == 5)

        scene.phase = .perform
        let beam = try #require(group(withClock(0) { draw(scene, arena) }, "spectacle"))
        #expect(beam.ops.count == 6)
        #expect(beam.bounds.maxY >= 200 + 399)
        #expect(beam.bounds.height > noBeam.bounds.height + 300)
    }

    @Test func theRunningLightChasesEvery300ms() throws {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.ufo, W, H, arena.order)
        scene.phase = .enter
        for (ms, lit) in [(0.0, 0), (300.0, 1), (650.0, 2), (900.0, 0)] {
            let canvas = withClock(ms) { draw(scene, arena) }
            let ops = try #require(group(canvas, "spectacle")).ops
            let lights = ops.suffix(3).map(\.alpha)
            for i in 0..<3 {
                #expect(lights[i] == (i == lit ? 1 : 0.35), "t=\(ms) light \(i)")
            }
        }
    }
}

@Suite("merchant", .serialized)
struct MerchantTests {
    @Test func merchantWalksInTradesAndLeaves() {
        withRoot(accessories: []) {
            let arena = Arena.standard()
            let scene = createSpectacleScene(.merchant, W, H, arena.order)
            var phases: [SpectaclePhase] = [scene.phase]
            var announced = false
            let frames = run(scene, arena) { _ in
                if phases.last != scene.phase { phases.append(scene.phase) }
                if scene.phase == .perform && !announced {
                    announced = true
                    #expect(arena.bubble("main").currentText == "A traveling merchant!")
                    // The main sheep walks out to meet the cart.
                    #expect(arena.sheep("main").walkTarget == scene.actorX - SIZE)
                }
            }
            #expect(phases == [.enter, .perform, .exit])
            // enter ≈ 3506ms (0.2px/ms from W+96 to 0.6W), perform 6s, exit ≈ 2337ms (0.3px/ms to W+96).
            let expected = (3506.0 + 6000 + 2337) / 16
            #expect(abs(Double(frames) - expected) <= 4, "\(frames) vs \(expected)")
            #expect(scene.facingRight)
        }
    }

    @Test func merchantGiftsAnAccessoryTheMainSheepDoesNotOwn() throws {
        try withRoot(accessories: ["crown", "cape"]) {
            let arena = Arena.standard()
            let scene = createSpectacleScene(.merchant, W, H, arena.order)
            _ = withSeed(5) { run(scene, arena) }
            let saved = try #require(arena.saved.first)
            #expect(arena.saved.count == 1)
            #expect(Array(saved.prefix(2)) == ["crown", "cape"])
            #expect(saved.count == 3)
            let gift = saved[2]
            #expect(SpectacleRenderData.GIFT_POOL.contains(gift))
            #expect(gift != "crown" && gift != "cape")
            #expect(arena.sheep("main").state == .bounce)
        }
    }

    @Test func giftReactionShowsABubbleUnlessMainIsAlreadyTalking() {
        withRoot(accessories: []) {
            let arena = Arena.standard()
            let scene = createSpectacleScene(.merchant, W, H, arena.order)
            scene.phase = .perform
            scene.timer = 6001
            _ = updateSpectacleScene(scene, 16, arena.world)
            #expect(scene.phase == .exit)
            #expect(arena.bubble("main").currentText == "Ooh, a gift!")

            let arena2 = Arena.standard()
            arena2.bubble("main").show("busy", duration: 600_000)
            let scene2 = createSpectacleScene(.merchant, W, H, arena2.order)
            scene2.phase = .perform
            scene2.timer = 6001
            _ = updateSpectacleScene(scene2, 16, arena2.world)
            #expect(arena2.bubble("main").currentText == "busy")
            #expect(arena2.sheep("main").state == .bounce)
            #expect(arena2.saved.count == 1)
        }
    }

    @Test func nothingIsGiftedWhenEverythingIsOwned() {
        withRoot(accessories: SpectacleRenderData.GIFT_POOL) {
            let arena = Arena.standard()
            let scene = createSpectacleScene(.merchant, W, H, arena.order)
            run(scene, arena)
            #expect(arena.saved.isEmpty)
            #expect(arena.sheep("main").state != .bounce)
        }
    }

    @Test func aMissingConfigMeansNothingIsOwned() throws {
        try withRoot(accessories: nil) {
            let arena = Arena.standard()
            let scene = createSpectacleScene(.merchant, W, H, arena.order)
            run(scene, arena)
            let saved = try #require(arena.saved.first)
            #expect(saved.count == 1)
        }
    }

    @Test func anUnwiredSaveSeamSkipsTheGiftLikeAFailedCommand() {
        withRoot(accessories: []) {
            let arena = Arena.standard()
            arena.saveWired = false
            let scene = createSpectacleScene(.merchant, W, H, arena.order)
            scene.phase = .perform
            scene.timer = 6001
            _ = updateSpectacleScene(scene, 16, arena.world)
            #expect(scene.phase == .exit)
            #expect(!arena.bubble("main").visible) // no "Ooh, a gift!"
            #expect(arena.sheep("main").state == .idle)
        }
    }

    @Test func drawsAMirroredMerchantInsideItsBox() {
        let scene = createSpectacleScene(.merchant, W, H, [])
        scene.actorX = 900
        scene.actorY = 700
        scene.facingRight = false
        let g = group(draw(scene, Arena.standard()), "spectacle")!
        #expect(g.ops.count >= 8)
        #expect(g.bounds.minX >= 900 - 1 && g.bounds.maxX <= 900 + SIZE + 1)
        #expect(g.bounds.minY >= 700 - 1 && g.bounds.maxY <= 700 + SIZE)
    }
}

@Suite("balloon", .serialized)
struct BalloonTests {
    @Test func balloonDriftsAcrossInTwentySecondsWhileTheFlockWatches() {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.balloon, W, H, arena.order)
        // First update: enter → perform, everyone sits for 20s.
        _ = updateSpectacleScene(scene, 16, arena.world)
        #expect(scene.phase == .perform)
        #expect(scene.actorX == -60)
        for id in arena.order {
            #expect(arena.sheep(id).state == .sit)
            #expect(arena.sheep(id).stateDuration == 20000)
        }

        var oohAt: Double?
        let frames = run(scene, arena) { _ in
            if oohAt == nil, arena.bubble("main").visible { oohAt = scene.timer }
        }
        // (W + 120) / 20000 px per ms ⇒ x goes from -60 to W + 60 in 20 s.
        #expect(abs(Double(frames) - 20000.0 / 16) <= 3, "\(frames)")
        #expect(arena.bubble("main").currentText == "Ooooh.")
        #expect((oohAt ?? 0) > 5000 && (oohAt ?? 0) < 5100)
        for id in arena.order { #expect(arena.sheep(id).facingRight, "\(id)") }
    }

    @Test func balloonWithNoCalmSheepStillFliesOver() {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.balloon, W, H, [])
        let frames = run(scene, arena)
        #expect(frames > 0)
        #expect(!arena.bubble("main").visible)
    }

    @Test func drawsABobbingBalloonAtItsPosition() throws {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.balloon, W, H, [])
        scene.actorX = 700
        scene.actorY = 200
        let up = try #require(group(withClock(900 * Double.pi / 2) { draw(scene, arena) }, "spectacle"))
        let flat = try #require(group(withClock(0) { draw(scene, arena) }, "spectacle"))
        // envelope, gold panel, ropes, basket
        #expect(flat.ops.count == 4)
        // sin(t/900)*6 bobs the whole balloon by up to 6px.
        #expect(abs(up.bounds.minY - flat.bounds.minY - 6) < 0.5)
        #expect(flat.bounds.minX >= 700 - 40 && flat.bounds.maxX <= 700 + 40)
    }
}

@Suite("shearing day", .serialized)
struct ShearingTests {
    @Test func shearingRunsSixtySecondsAndEveryoneVibratesOnce() {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.shearing, W, H, arena.order)
        _ = updateSpectacleScene(scene, 16, arena.world)
        for id in arena.order { #expect(arena.sheep(id).state == .vibrate, "\(id)") }
        #expect(scene.flag("started"))
        // Change one sheep's state: the vibrate isn't re-issued.
        arena.sheep("main").state = .idle
        _ = updateSpectacleScene(scene, 16, arena.world)
        #expect(arena.sheep("main").state == .idle)

        let arena2 = Arena.standard()
        let scene2 = createSpectacleScene(.shearing, W, H, arena2.order)
        #expect(run(scene2, arena2) == 3750) // timer < 60000 fails on the 3750th frame
    }

    @Test func fourComplaintsAtTwoSecondIntervalsFromDifferentSheep() {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.shearing, W, H, arena.order)
        var seen: [(ms: Double, id: String, text: String)] = []
        var lastText: [String: String] = [:]
        run(scene, arena, maxFrames: 500) { _ in
            for id in arena.order where arena.bubble(id).visible && lastText[id] != arena.bubble(id).currentText {
                lastText[id] = arena.bubble(id).currentText
                seen.append((scene.timer, id, arena.bubble(id).currentText))
            }
        }
        #expect(seen.map(\.id) == ["main", "good_colleague", "f1", "f2"])
        #expect(seen.map(\.text) == ["MY WOOL!", "Don't look at me.", "This is a violation.", "Cold. So cold."])
        // Bubbles land right after 0, 2, 4 and 6 seconds.
        for (i, s) in seen.enumerated() {
            #expect(s.ms > Double(i) * 2000 && s.ms <= Double(i) * 2000 + 40, "\(i): \(s.ms)")
        }
    }

    @Test func aSheepThatIsAlreadyTalkingSkipsItsComplaint() {
        let arena = Arena.standard()
        arena.bubble("good_colleague").show("still talking", duration: 600_000)
        let scene = createSpectacleScene(.shearing, W, H, arena.order)
        run(scene, arena, maxFrames: 500)
        #expect(arena.bubble("good_colleague").currentText == "still talking")
        #expect(scene.flag("bubble1")) // marked done anyway
    }

    @Test func shearingWithNoParticipantsJustWaitsItOut() {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.shearing, W, H, [])
        #expect(run(scene, arena) == 3750)
    }

    @Test func overlayIsOnePinkEllipsePerSheepInItsOwnTileFadingOverTheLastTenSeconds() throws {
        let arena = Arena.standard()
        arena.sheep("main").x = 100
        arena.sheep("f2").x = 1300 // a screen apart
        let scene = createSpectacleScene(.shearing, W, H, arena.order)

        scene.timer = 30_000
        let full = draw(scene, arena)
        for id in arena.order {
            let g = try #require(group(full, "spectacle:shorn:\(id)"), "\(id)")
            #expect(g.ops.count == 1)
            #expect(g.ops[0].alpha == 0.65)
            // A sheep-sized tile, not a screen-wide one.
            #expect(g.bounds.width < SIZE && g.bounds.height < SIZE)
        }
        #expect(full.groups.map(\.key) == ["spectacle"] + arena.order.map { "spectacle:shorn:\($0)" })

        scene.timer = 55_000
        let fading = draw(scene, arena)
        #expect(abs(try #require(group(fading, "spectacle:shorn:main")).ops[0].alpha - 0.325) < 1e-9)

        scene.timer = 60_000
        let gone = draw(scene, arena)
        #expect(gone.groups.allSatisfy { $0.ops.isEmpty })
    }

    @Test func overlaySitsOnTheSheepsWool() throws {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.shearing, W, H, ["main"])
        scene.timer = 1000
        let s = arena.sheep("main")
        let g = try #require(group(draw(scene, arena), "spectacle:shorn:main"))
        let b = g.bounds
        // Ellipse centred at (x + 0.45 sz, y + 0.55 sz) with radii (0.32 sz, 0.24 sz).
        #expect(abs(b.midX - (s.x + s.displaySize * 0.45)) < 0.5)
        #expect(abs(b.midY - (s.y + s.displaySize * 0.55)) < 0.5)
        #expect(abs(b.width - s.displaySize * 0.64) < 1)
        #expect(abs(b.height - s.displaySize * 0.48) < 1)
    }
}

@Suite("showdown", .serialized)
struct ShowdownTests {
    private func setup() -> (Arena, SpectacleScene) {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.showdown, W, H, arena.order, ("f1", "f2"))
        return (arena, scene)
    }

    @Test func summonsTheDuelistsAndSeatsTheSpectators() {
        let (arena, scene) = setup()
        _ = updateSpectacleScene(scene, 16, arena.world)
        #expect(arena.sheep("f1").walkTarget == W / 2 - 60 - SIZE / 2)
        #expect(arena.sheep("f2").walkTarget == W / 2 + 60 - SIZE / 2)
        for id in ["main", "good_colleague"] {
            #expect(arena.sheep(id).state == .sit)
            #expect(arena.sheep(id).stateDuration == 15000)
        }
        #expect(arena.sheep("f1").state == .idle) // duelists aren't seated
        #expect(scene.phase == .enter)
    }

    @Test func performBeginsOnceBothAreWithinADisplayWidthOfTheirSpotsOrAfterFiveSeconds() {
        let (arena, scene) = setup()
        arena.sheep("f1").x = W / 2 - 60 - SIZE / 2
        arena.sheep("f2").x = W / 2 + 60 - SIZE / 2 + 50
        _ = updateSpectacleScene(scene, 16, arena.world)
        #expect(scene.phase == .perform)
        #expect(scene.timer == 0)

        let (arena2, scene2) = setup()
        arena2.sheep("f1").x = 0
        arena2.sheep("f2").x = W - SIZE
        var frames = 0
        while scene2.phase == .enter {
            _ = updateSpectacleScene(scene2, 16, arena2.world)
            frames += 1
        }
        #expect(frames == 313) // 5008ms > 5000
    }

    @Test func duelistsFaceEachOtherAndVibrateAtStartAndAtFourSeconds() {
        let (arena, scene) = setup()
        arena.sheep("f1").x = W / 2 - 60 - SIZE / 2
        arena.sheep("f2").x = W / 2 + 60 - SIZE / 2
        _ = updateSpectacleScene(scene, 16, arena.world) // enter → perform
        _ = updateSpectacleScene(scene, 16, arena.world) // first perform frame
        #expect(arena.sheep("f1").facingRight)
        #expect(!arena.sheep("f2").facingRight)
        #expect(arena.sheep("f1").state == .vibrate)
        #expect(arena.sheep("f2").state == .vibrate)
        #expect(scene.flag("vibe0"))

        arena.sheep("f1").state = .idle
        arena.sheep("f2").state = .idle
        while scene.timer <= 4000 { _ = updateSpectacleScene(scene, 16, arena.world) }
        #expect(scene.flag("vibe4"))
        #expect(arena.sheep("f1").state == .vibrate)
        #expect(arena.sheep("f2").state == .vibrate)
    }

    @Test func aTruceEndsTheShowdown() {
        let (arena, scene) = setup()
        arena.sheep("f1").x = W / 2 - 60 - SIZE / 2
        arena.sheep("f2").x = W / 2 + 60 - SIZE / 2
        withRandom([0.1]) { run(scene, arena) }
        #expect(scene.data["reconciled"] == 1)
        #expect(arena.bubble("f1").currentText == "...truce?")
        #expect(arena.bubble("f2").currentText == "...fine. Truce.")
        #expect(scene.phase == .exit)
    }

    @Test func aGrudgeEndsTheShowdown() {
        let (arena, scene) = setup()
        arena.sheep("f1").x = W / 2 - 60 - SIZE / 2
        arena.sheep("f2").x = W / 2 + 60 - SIZE / 2
        withRandom([0.9]) { run(scene, arena) }
        #expect(scene.data["reconciled"] == 0)
        #expect(arena.bubble("f1").currentText == "This isn't over.")
        #expect(arena.bubble("f2").currentText == "Not even CLOSE to over.")
    }

    @Test func lastsGatherPlusEightSecondsPlusTwoSecondsOfAftermath() {
        let (arena, scene) = setup()
        arena.sheep("f1").x = W / 2 - 60 - SIZE / 2
        arena.sheep("f2").x = W / 2 + 60 - SIZE / 2
        let frames = withRandom([0.1]) { run(scene, arena) }
        // 1 (gathered instantly) + 8000/16 (+1) + 2000/16 (+1)
        #expect(abs(frames - (1 + 500 + 125 + 2)) <= 2, "\(frames)")
    }

    @Test func bubblesAreLeftAloneWhenAlreadyTalking() {
        let (arena, scene) = setup()
        arena.sheep("f1").x = W / 2 - 60 - SIZE / 2
        arena.sheep("f2").x = W / 2 + 60 - SIZE / 2
        arena.bubble("f1").show("mid-sentence", duration: 600_000)
        withRandom([0.1]) { run(scene, arena) }
        #expect(arena.bubble("f1").currentText == "mid-sentence")
        #expect(arena.bubble("f2").currentText == "...fine. Truce.")
    }

    @Test func endsAtOnceWithoutAPairOrWithAMissingDuelist() {
        let arena = Arena.standard()
        let noPair = createSpectacleScene(.showdown, W, H, arena.order)
        #expect(run(noPair, arena) == 1)
        let ghost = createSpectacleScene(.showdown, W, H, arena.order, ("f1", "ghost"))
        #expect(run(ghost, arena) == 1)
    }

    @Test func tumbleweedRollsOnlyWhilePerformingAndAdvancesFourPixelsPerDraw() throws {
        let (arena, scene) = setup()
        scene.phase = .enter
        #expect(group(draw(scene, arena), "spectacle")?.ops.isEmpty == true)
        #expect(scene.data["tumbleX"] == nil)

        scene.phase = .perform
        let first = try #require(group(draw(scene, arena), "spectacle"))
        #expect(scene.data["tumbleX"] == -16)
        #expect(first.ops.count == 1) // one stroked path
        _ = draw(scene, arena)
        _ = draw(scene, arena)
        #expect(scene.data["tumbleX"] == -8)

        scene.phase = .exit
        _ = draw(scene, arena)
        #expect(scene.data["tumbleX"] == -8)
    }
}

@Suite("reconciliation feast", .serialized)
struct FeastTests {
    private func setup() -> (Arena, SpectacleScene) {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.feast, W, H, arena.order, ("f1", "f2"))
        return (arena, scene)
    }

    @Test func everyoneWalksToASlotAroundTheScreenCenter() {
        let (arena, scene) = setup()
        _ = updateSpectacleScene(scene, 16, arena.world)
        for (slot, id) in arena.order.enumerated() {
            let expected = W / 2 + (Double(slot) - Double(arena.order.count) / 2) * SIZE * 0.9
            #expect(arena.sheep(id).walkTarget == expected, "\(id)")
        }
        // Slots are only handed out once.
        arena.sheep("main").walkTarget = nil
        _ = updateSpectacleScene(scene, 16, arena.world)
        #expect(arena.sheep("main").walkTarget == nil)
    }

    @Test func afterSixSecondsTheHostLightsTheFireAndTheOthersSit() {
        let (arena, scene) = setup()
        while scene.phase == .enter { _ = updateSpectacleScene(scene, 16, arena.world) }
        #expect(scene.timer == 0)
        let host = arena.sheep("f1")
        #expect(host.state == .idleCampfire)
        #expect(host.stateDuration == 15000)
        for id in ["main", "good_colleague", "f2"] {
            #expect(arena.sheep(id).state == .sit, "\(id)")
            #expect(arena.sheep(id).stateDuration == 15000)
        }
    }

    @Test func withoutAPairTheFirstParticipantHosts() {
        let arena = Arena.standard()
        let scene = createSpectacleScene(.feast, W, H, arena.order)
        while scene.phase == .enter { _ = updateSpectacleScene(scene, 16, arena.world) }
        #expect(arena.sheep("main").state == .idleCampfire)
        // ...and no toast.
        while scene.phase == .perform { _ = updateSpectacleScene(scene, 16, arena.world) }
        #expect(!scene.flag("toasted"))
    }

    @Test func thePairToastsTwoSecondsIn() {
        let (arena, scene) = setup()
        while scene.phase == .enter { _ = updateSpectacleScene(scene, 16, arena.world) }
        while scene.timer <= 2000 { _ = updateSpectacleScene(scene, 16, arena.world) }
        #expect(scene.flag("toasted"))
        #expect(arena.bubble("f1").currentText == "To making up!")
        #expect(!arena.bubble("f2").visible)
        // f2 chimes in 1.2s later (a setTimeout).
        pump { arena.bubble("f2").visible }
        #expect(arena.bubble("f2").currentText == "To wool and friendship!")
    }

    @Test func afterFifteenSecondsEveryoneWandersOffAndTheFeastEndsThreeSecondsLater() {
        let (arena, scene) = setup()
        while scene.phase != .exit { _ = updateSpectacleScene(scene, 16, arena.world) }
        for id in arena.order {
            let sheep = arena.sheep(id)
            let target = sheep.walkTarget
            #expect(target != nil, "\(id)")
            let dist = abs((target ?? 0) - sheep.x)
            #expect(dist >= 2 * SIZE && dist <= 5 * SIZE, "\(id) \(dist)")
        }
        var frames = 0
        while updateSpectacleScene(scene, 16, arena.world) { frames += 1 }
        #expect(abs(frames - 187) <= 2)
    }

    @Test func aFullFeastLastsSixPlusFifteenPlusThreeSeconds() {
        let (arena, scene) = setup()
        let frames = run(scene, arena)
        #expect(abs(Double(frames) - 24000.0 / 16) <= 4, "\(frames)")
    }

    @Test func aFeastDrawsNothingItself() {
        let (arena, scene) = setup()
        #expect(group(draw(scene, arena), "spectacle")?.ops.isEmpty == true)
    }
}

@Suite("every spectacle type", .serialized)
struct EverySpectacleTests {
    @Test func eachTypeRunsToItsEndAndDrawsEveryFrameWithoutIncident() {
        withRoot(accessories: []) {
            for type in SpectacleType.allCases {
                let arena = Arena.standard()
                let pair: (String, String)? = (type == .showdown || type == .feast) ? ("f1", "f2") : nil
                let scene = withSeed(21) { createSpectacleScene(type, W, H, arena.order, pair) }
                var drawnOps = 0
                let frames = withSeed(22) {
                    run(scene, arena, maxFrames: 5000) { _ in
                        let canvas = draw(scene, arena)
                        drawnOps += canvas.groups.reduce(0) { $0 + $1.ops.count }
                    }
                }
                #expect(frames > 0, "\(type) never ended")
                if type == .feast {
                    #expect(drawnOps == 0)
                } else {
                    #expect(drawnOps > 0, "\(type) drew nothing")
                }
            }
        }
    }
}

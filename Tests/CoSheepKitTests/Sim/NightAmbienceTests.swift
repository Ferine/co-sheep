import CoreGraphics
import Foundation
import SpriteKit
import Testing
@testable import CoSheepKit

/// RGBA8 sampler over a CGImage, y from the top (alpha is what the ambience tests check).
func ambiencePixels(_ img: CGImage) -> (Int, Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let w = img.width, h = img.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGReplay.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return { x, y in
        let i = (y * w + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }
}

/// SpriteKit stores node transforms as 32-bit floats: compare with a tolerance.
func near(_ a: CGPoint, _ b: CGPoint, _ tol: Double = 1e-3) -> Bool {
    abs(Double(a.x) - Double(b.x)) < tol && abs(Double(a.y) - Double(b.y)) < tol
}

private let night = localMs(2026, 9, 29, hour: 23)
private let day = localMs(2026, 9, 29, hour: 12)

/// Scenes made by the tests below (the effects only hold theirs weakly).
private var sceneKeepAlive: [OverlayScene] = []

private func makeScene(_ w: Double = 1000, _ h: Double = 800) -> OverlayScene {
    let s = OverlayScene(size: CGSize(width: w, height: h))
    s.backingScale = 2
    sceneKeepAlive.append(s) // the effects only hold their scene weakly
    return s
}

private let calm = [SheepPosition(x: 100, y: 100, state: .idle)]

@Suite("night alpha")
struct NightAlphaTests {
    @Test func followsTheNightHoursRule() {
        let f = NightAmbience.nightAlpha(atHour:)
        #expect(f(0) == 1)
        #expect(f(3.99) == 1)
        #expect(f(4) == 1)                   // ramp down starts at 1
        #expect(abs(f(5) - 0.5) < 1e-12)
        #expect(abs(f(5.5) - 0.25) < 1e-12)
        #expect(f(6) == 0)                   // daytime
        #expect(f(12) == 0)
        #expect(f(19.99) == 0)
        #expect(f(20) == 0)                  // ramp up starts at 0
        #expect(abs(f(21) - 0.5) < 1e-12)
        #expect(abs(f(21.5) - 0.75) < 1e-12)
        #expect(f(22) == 1)
        #expect(f(23.99) == 1)
    }

    @Test func readsTheHourAndMinutesFromTheSimClock() {
        let amb = NightAmbience(1000, 800)
        withSim(now: localMs(2026, 9, 29, hour: 21, minute: 0)) { #expect(abs(amb.getNightAlpha() - 0.5) < 1e-9) }
        withSim(now: localMs(2026, 9, 29, hour: 21, minute: 30)) { #expect(abs(amb.getNightAlpha() - 0.75) < 1e-9) }
        withSim(now: localMs(2026, 9, 29, hour: 5, minute: 0)) { #expect(abs(amb.getNightAlpha() - 0.5) < 1e-9) }
        withSim(now: localMs(2026, 9, 29, hour: 2, minute: 15)) { #expect(amb.getNightAlpha() == 1) }
        withSim(now: day) { #expect(amb.getNightAlpha() == 0) }
    }
}

@Suite("night ambience simulation", .serialized)
struct NightAmbienceSimTests {
    @Test func seedsThirtyFiveStarsInTheUpperSixtyPercent() {
        withSim(random: SimRandom.seeded(1)) {
            let amb = NightAmbience(1000, 800)
            #expect(amb.stars.count == 35)
            for s in amb.stars {
                #expect(s.x >= 0 && s.x < 1 && s.y >= 0 && s.y < 0.6)
                #expect(s.twinkleSpeed >= 0.5 && s.twinkleSpeed < 2.5)
            }
            let before = amb.stars.map(\.x)
            amb.updateScreenSize(2000, 1000)
            #expect(amb.stars.count == 35 && amb.stars.map(\.x) != before) // reseeded
        }
    }

    @Test func daytimeClearsFirefliesAndNeverSpawns() {
        withSim(now: night, random: { 0 }) {
            let amb = NightAmbience(1000, 800)
            amb.update(16, calm)
            #expect(amb.fireflies.count == 1)
            SimClock.nowSource = { day }
            amb.update(16, calm)
            #expect(amb.fireflies.isEmpty)
            #expect(amb.time == 32)
        }
    }

    @Test func spawnsNearCalmSheepOnAOnePercentTwoRoll() {
        // Constant 0: the 2% roll passes, the offsets are -0.5*range, phase 0.
        withSim(now: night, random: { 0 }) {
            let amb = NightAmbience(1000, 800)
            amb.update(16, calm)
            let f = amb.fireflies[0]
            // spawn (60, 70), v (-10, -7.5), then one 16ms random-walk step
            let vx = (-10 + (0 - 0.5) * 40 * 0.016) * 0.95
            let vy = (-7.5 + (0 - 0.5) * 30 * 0.016) * 0.95
            #expect(abs(f.vx - vx) < 1e-9 && abs(f.vy - vy) < 1e-9)
            #expect(abs(f.x - (60 + vx * 0.016)) < 1e-9 && abs(f.y - (70 + vy * 0.016)) < 1e-9)
            #expect(abs(f.phase - 16.0 / 400) < 1e-12)
        }
        // the roll fails at 0.02 and above
        withSim(now: night, random: { 0.02 }) {
            let amb = NightAmbience(1000, 800)
            amb.update(16, calm)
            #expect(amb.fireflies.isEmpty)
        }
    }

    @Test func onlyCalmStatesAttractFireflies() {
        let calmStates: [SheepState] = [.idle, .sit, .sleep, .idleSleep, .idleCampfire, .idleCounting]
        for state in SheepState.allCases {
            withSim(now: night, random: { 0 }) {
                let amb = NightAmbience(1000, 800)
                amb.update(16, [SheepPosition(x: 100, y: 100, state: state)])
                #expect((amb.fireflies.count == 1) == calmStates.contains(state), "\(state)")
            }
        }
        withSim(now: night, random: { 0 }) {
            let amb = NightAmbience(1000, 800)
            amb.update(16, [])
            #expect(amb.fireflies.isEmpty)
        }
    }

    @Test func atMostSixFireflies() {
        withSim(now: night, random: { 0 }) {
            let amb = NightAmbience(1000, 800)
            for _ in 0..<30 { amb.update(16, calm) }
            #expect(amb.fireflies.count == 6)
        }
    }

    @Test func firefliesThatLeaveTheScreenAreDropped() {
        withSim(now: night, random: { 0 }) {
            let amb = NightAmbience(1000, 800)
            amb.update(16, [SheepPosition(x: -200, y: 100, state: .idle)]) // spawns at x = -240 (< -20)
            #expect(amb.fireflies.isEmpty)
            amb.update(16, [SheepPosition(x: 100, y: 1000, state: .idle)]) // spawns at y = 970 (> 820)
            #expect(amb.fireflies.isEmpty)
            amb.update(16, calm) // on screen: kept
            #expect(amb.fireflies.count == 1)
        }
    }

    @Test func fireflyWalkStaysBoundedAndTimeAccumulates() {
        withSim(now: night, random: SimRandom.seeded(5)) {
            let amb = NightAmbience(300, 200)
            for _ in 0..<2000 { amb.update(16, calm) }
            #expect(amb.time == 2000 * 16)
            for f in amb.fireflies { #expect(f.x > -20 && f.x < 320 && f.y > -20 && f.y < 220) }
            #expect(amb.fireflies.count <= 6)
        }
    }
}

@Suite("night ambience rendering", .serialized)
struct NightAmbienceRenderTests {
    @Test func renderBeforeAttachIsANoOp() {
        withSim(now: night) {
            let amb = NightAmbience(1000, 800)
            amb.render(1000, 800, calm)
            #expect(amb.starNodes.isEmpty && amb.moonNode == nil)
        }
    }

    @Test func attachParentsTheContainersUnderTheNightLayers() {
        let amb = NightAmbience(1000, 800)
        let scene = makeScene()
        amb.attach(to: scene)
        #expect(amb.backRoot.parent === scene.nightBackLayer)
        #expect(amb.frontRoot.parent === scene.nightFrontLayer)
        #expect(amb.backRoot.isHidden && amb.frontRoot.isHidden) // nothing shown until rendered
        amb.attach(to: scene) // idempotent
        #expect(scene.nightBackLayer.children.count == 1 && scene.nightFrontLayer.children.count == 1)
        amb.detach()
        #expect(scene.nightBackLayer.children.isEmpty && scene.nightFrontLayer.children.isEmpty)
        amb.render(1000, 800, calm) // detached: no-op, no crash
    }

    @Test func starsMapToTwinklingSpritesInSceneCoordinates() {
        withSim(now: night, random: SimRandom.seeded(1)) {
            let amb = NightAmbience(1000, 800)
            let scene = makeScene()
            amb.attach(to: scene)
            amb.update(1000, []) // t = 1s
            amb.render(1000, 800)
            #expect(!amb.backRoot.isHidden)
            #expect(amb.starNodes.count == 35)
            for (i, star) in amb.stars.enumerated() {
                let node = amb.starNodes[i]
                let size: Double = 1 + (star.twinkleSpeed > 1.5 ? 1 : 0)
                let alpha = 1 * (0.3 + 0.7 * abs(sin(1 * star.twinkleSpeed)))
                #expect(abs(Double(node.alpha) - alpha) < 1e-5)
                #expect(near(node.position, scene.scenePoint(star.x * 1000 + size / 2, star.y * 800 + size / 2)))
                #expect(!node.isHidden && node.texture != nil)
                #expect(abs(Double(node.size.width) - (size + 2)) < 1e-6)
            }
        }
    }

    @Test func nightIntensityScalesTheStarAlpha() {
        withSim(now: localMs(2026, 9, 29, hour: 21, minute: 0), random: SimRandom.seeded(1)) {
            let amb = NightAmbience(1000, 800)
            amb.attach(to: makeScene())
            amb.render(1000, 800)
            for (i, star) in amb.stars.enumerated() {
                let alpha = 0.5 * (0.3 + 0.7 * abs(sin(0 * star.twinkleSpeed)))
                #expect(abs(Double(amb.starNodes[i].alpha) - alpha) < 1e-5)
            }
            #expect(abs(Double(amb.moonNode!.alpha) - 0.04 * 0.5) < 1e-5)
        }
    }

    @Test func moonlightIsOneBigSoftSprite() throws {
        try withSim(now: night, random: SimRandom.seeded(1)) {
            let amb = NightAmbience(1000, 800)
            let scene = makeScene()
            amb.attach(to: scene)
            amb.render(1000, 800)
            let moon = try #require(amb.moonNode)
            #expect(abs(moon.size.width - 800) < 1e-3 && abs(moon.size.height - 800) < 1e-3) // radius w * 0.4
            let target = scene.scenePoint(850, 64) // (w * 0.85, h * 0.08)
            #expect(near(moon.position, target))
            #expect(abs(Double(moon.alpha) - 0.04) < 1e-5)
            let img = try #require(moon.texture?.cgImage())
            #expect(img.width <= 520 && img.width >= 500 && img.width == img.height)
            let px = ambiencePixels(img)
            let c = img.width / 2
            #expect(px(c, c).a >= 250)                       // inside the 10pt inner radius: full first stop
            #expect(px(0, 0).a == 0)                         // outside the radius: fully transparent
            let mid = px(c + img.width / 4, c).a             // ~halfway out: about half strength
            #expect(mid > 90 && mid < 170)

            // Re-baked (and resized) when the screen width changes.
            let old = moon.texture
            amb.render(2000, 800)
            #expect(abs(moon.size.width - 1600) < 1e-3)
            #expect(moon.texture !== old)
        }
    }

    @Test func starTexturesAreBakedWhiteSquares() throws {
        try withSim(now: night, random: SimRandom.seeded(1)) {
            let amb = NightAmbience(1000, 800)
            amb.attach(to: makeScene())
            amb.render(1000, 800)
            let small = try #require(amb.stars.firstIndex { $0.twinkleSpeed <= 1.5 })
            let large = try #require(amb.stars.firstIndex { $0.twinkleSpeed > 1.5 })
            // 1pt star + 1pt padding each side at 2x → 6x6px; the star is the middle 2x2.
            let a = try #require(amb.starNodes[small].texture?.cgImage())
            #expect(a.width == 6 && a.height == 6)
            let pa = ambiencePixels(a)
            #expect(pa(2, 2) == (255, 255, 255, 255) && pa(3, 3) == (255, 255, 255, 255))
            #expect(pa(0, 0).a == 0 && pa(5, 5).a == 0 && pa(1, 2).a == 0)
            // 2pt star → 8x8px with the middle 4x4 filled.
            let b = try #require(amb.starNodes[large].texture?.cgImage())
            #expect(b.width == 8 && b.height == 8)
            let pb = ambiencePixels(b)
            #expect(pb(2, 2).a == 255 && pb(5, 5).a == 255 && pb(1, 1).a == 0 && pb(6, 6).a == 0)
        }
    }

    @Test func daylightHidesEverything() {
        withSim(now: night, random: { 0 }) {
            let amb = NightAmbience(1000, 800)
            amb.attach(to: makeScene())
            amb.update(16, calm)
            amb.render(1000, 800, calm)
            #expect(!amb.backRoot.isHidden && !amb.frontRoot.isHidden)
            SimClock.nowSource = { day }
            amb.update(16, calm)
            amb.render(1000, 800, calm)
            #expect(amb.backRoot.isHidden && amb.frontRoot.isHidden)
        }
    }

    @Test func firefliesUseAGlowAndACoreSpriteAtThePulseAlpha() throws {
        try withSim(now: night, random: { 0 }) {
            let amb = NightAmbience(1000, 800)
            let scene = makeScene()
            amb.attach(to: scene)
            for _ in 0..<3 { amb.update(16, calm) }
            #expect(amb.fireflies.count == 3)
            amb.render(1000, 800, calm)
            #expect(amb.fireflyGlowNodes.count == 3 && amb.fireflyCoreNodes.count == 3)
            for (i, f) in amb.fireflies.enumerated() {
                let pulse = 0.4 + 0.6 * abs(sin(f.phase))
                let p = scene.scenePoint(f.x, f.y)
                for node in [amb.fireflyGlowNodes[i], amb.fireflyCoreNodes[i]] {
                    #expect(abs(Double(node.alpha) - pulse) < 1e-5) // nightAlpha 1
                    #expect(near(node.position, p))
                    #expect(!node.isHidden)
                }
                #expect(amb.fireflyGlowNodes[i].zPosition < amb.fireflyCoreNodes[i].zPosition)
            }

            // Baked looks: radial glow (r 6) and bright center (r 1.5).
            let glow = try #require(amb.fireflyGlowNodes[0].texture?.cgImage())
            #expect(glow.width == 28 && glow.height == 28)
            let pg = ambiencePixels(glow)
            #expect(pg(14, 14).a > 220 && pg(14, 14).a > pg(14, 18).a && pg(14, 18).a > pg(14, 23).a)
            #expect(pg(0, 0).a == 0 && pg(27, 27).a == 0)
            let core = try #require(amb.fireflyCoreNodes[0].texture?.cgImage())
            #expect(core.width == 10 && core.height == 10)
            let pc = ambiencePixels(core)
            #expect(pc(5, 5).a == 255 && pc(4, 4).a == 255 && pc(0, 0).a == 0)
            #expect(abs(pc(5, 5).r - 220) <= 1 && abs(pc(5, 5).g - 255) <= 1 && abs(pc(5, 5).b - 150) <= 1)

            // Fewer fireflies than pooled nodes: the extras are hidden, not deleted.
            SimClock.nowSource = { day }
            amb.update(16, calm)
            SimClock.nowSource = { night }
            amb.render(1000, 800, calm)
            #expect(amb.fireflies.isEmpty)
            #expect(amb.fireflyGlowNodes.allSatisfy { $0.isHidden } && amb.fireflyCoreNodes.allSatisfy { $0.isHidden })
            #expect(amb.fireflyGlowNodes.count == 3)
        }
    }

    @Test func campfireGlowFollowsCampfireSheepAndFlickers() throws {
        try withSim(now: night, random: { 0.99 }) {
            let amb = NightAmbience(1000, 800)
            let scene = makeScene()
            amb.attach(to: scene)
            let sheep = [
                SheepPosition(x: 100, y: 200, state: .idleCampfire),
                SheepPosition(x: 400, y: 200, state: .idle),
            ]
            amb.update(1000, sheep) // t = 1s
            amb.render(1000, 800, sheep)
            #expect(amb.campfireNodes.count == 1)
            let node = amb.campfireNodes[0]
            #expect(near(node.position, scene.scenePoint(100 + 96 + 10, 200 + 76)))
            let flicker = 0.8 + 0.2 * sin(1 * 3)
            #expect(abs(Double(node.alpha) - 0.08 * flicker) < 1e-5)
            #expect(!node.isHidden)
            #expect(node.size == CGSize(width: 160, height: 160))

            let img = try #require(node.texture?.cgImage())
            #expect(img.width == 320)
            let px = ambiencePixels(img)
            #expect(px(160, 160).a >= 250 && abs(px(160, 160).r - 255) <= 1 && abs(px(160, 160).g - 150) <= 2
                    && abs(px(160, 160).b - 50) <= 2)
            #expect(px(0, 0).a == 0)
            #expect(px(160 + 80, 160).a < px(160 + 20, 160).a)

            // Two campfires → two sprites; none (or no positions) → hidden.
            let two = sheep + [SheepPosition(x: 600, y: 300, state: .idleCampfire)]
            amb.render(1000, 800, two)
            #expect(amb.campfireNodes.count == 2 && amb.campfireNodes.allSatisfy { !$0.isHidden })
            amb.renderForeground(1000, 800, nil)
            #expect(amb.campfireNodes.allSatisfy { $0.isHidden })
        }
    }

    @Test func backgroundAndForegroundCanBeRenderedSeparately() {
        withSim(now: night, random: { 0 }) {
            let amb = NightAmbience(1000, 800)
            amb.attach(to: makeScene())
            amb.update(16, calm)
            amb.renderBackground(1000, 800)
            #expect(!amb.backRoot.isHidden && amb.frontRoot.isHidden)
            amb.renderForeground(1000, 800, calm)
            #expect(!amb.frontRoot.isHidden && amb.fireflyGlowNodes.count == 1)
        }
    }
}

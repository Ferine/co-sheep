import CoreGraphics
import Foundation
import SpriteKit
import Testing
@testable import CoSheepKit

private var sceneKeepAlive: [OverlayScene] = []

private func makeScene(_ w: Double = 1000, _ h: Double = 800) -> OverlayScene {
    let s = OverlayScene(size: CGSize(width: w, height: h))
    s.backingScale = 2
    sceneKeepAlive.append(s) // the effects only hold their scene weakly
    return s
}

@Suite("weather effects simulation", .serialized)
struct WeatherEffectsSimTests {
    @Test func conditionStartsNilAndSetConditionClearsParticlesOnlyOnChange() {
        withSim(random: SimRandom.seeded(1)) {
            let w = WeatherEffects()
            #expect(w.condition == nil && w.particles.isEmpty)
            w.setCondition("rain")
            #expect(w.condition == "rain")
            w.update(16, 1000, 800)
            #expect(w.particles.count == 50)
            w.setCondition("rain") // same condition: particles survive
            #expect(w.particles.count == 50)
            w.setCondition("snow")
            #expect(w.particles.isEmpty)
            w.update(16, 1000, 800)
            #expect(w.particles.count == 30)
            w.setCondition(nil)
            #expect(w.condition == nil && w.particles.isEmpty)
        }
    }

    @Test func rainSpawnsFiftyDropsWithTheOriginalRanges() {
        withSim(random: SimRandom.seeded(2)) {
            let w = WeatherEffects()
            w.setCondition("rain")
            w.update(0, 1000, 800) // dt 0: positions are exactly as spawned
            #expect(w.particles.count == 50)
            for p in w.particles {
                #expect(p.x >= 0 && p.x < 1000)
                #expect(p.y > -60 && p.y <= -10)
                #expect(p.vx >= -20 && p.vx < -10) // slight wind
                #expect(p.vy >= 300 && p.vy < 500)
                #expect(p.life >= 0 && p.life < Double.pi * 2)
            }
        }
    }

    @Test func snowSpawnsThirtyFlakesWithSineDrift() {
        withSim(random: SimRandom.seeded(3)) {
            let w = WeatherEffects()
            w.setCondition("snow")
            w.update(0, 1000, 800)
            #expect(w.particles.count == 30)
            for p in w.particles {
                #expect(p.x >= 0 && p.x < 1000)
                #expect(p.y > -40 && p.y <= -10)
                #expect(p.vy >= 20 && p.vy < 60)
                #expect(abs(p.vx - sin(p.y / 60 + p.life * 10) * 15) < 1e-12)
            }
        }
    }

    @Test func particlesFallAndAgeWithDt() {
        withSim(random: SimRandom.seeded(4)) {
            let w = WeatherEffects()
            w.setCondition("rain")
            w.update(0, 1000, 800)
            let before = w.particles
            w.update(100, 1000, 800) // 0.1s
            for (a, b) in zip(before, w.particles) {
                #expect(abs(b.x - (a.x + a.vx * 0.1)) < 1e-9)
                #expect(abs(b.y - (a.y + a.vy * 0.1)) < 1e-9)
                #expect(abs(b.life - (a.life + 0.1)) < 1e-12)
            }
        }
    }

    @Test func clearCloudyAndUnsetSkiesDoNothing() {
        withSim(random: SimRandom.seeded(5)) {
            let w = WeatherEffects()
            w.update(16, 1000, 800)
            #expect(w.particles.isEmpty)
            for c in ["clear", "cloudy", "", "fog"] {
                w.setCondition(c)
                w.update(16, 1000, 800)
                #expect(w.particles.isEmpty, "\(c)")
            }
        }
    }

    @Test func dropsLeavingTheBottomRecycleToTheTop() {
        withSim(random: SimRandom.seeded(6)) {
            let w = WeatherEffects()
            w.setCondition("rain")
            w.update(10_000, 1000, 800) // 10s: every drop is far below 810
            #expect(w.particles.count == 50)
            #expect(w.particles.allSatisfy { $0.y == -10 && $0.x >= 0 && $0.x < 1000 })
        }
    }

    @Test func dropsBlownOffTheSideRespawnAtTheTop() {
        withSim(random: SimRandom.seeded(7)) {
            let w = WeatherEffects()
            w.setCondition("rain")
            // Tall, narrow screen: the wind (-10…-20 px/s) carries drops out the left in 5s, long before the floor.
            w.update(5000, 100, 1_000_000)
            #expect(w.particles.allSatisfy { $0.x >= -20 && $0.x <= 120 })
            #expect(w.particles.contains { $0.y == -10 }) // recycled ones restart at y = -10
        }
    }

    @Test func snowKeepsSwayingAsItFalls() {
        withSim(random: SimRandom.seeded(8)) {
            let w = WeatherEffects()
            w.setCondition("snow")
            w.update(0, 1000, 800)
            for _ in 0..<50 { w.update(16, 1000, 800) }
            #expect(w.particles.count == 30)
            for p in w.particles {
                if p.y < 810 && p.y != -10 { #expect(abs(p.vx) <= 15) }
            }
        }
    }
}

@Suite("weather effects rendering", .serialized)
struct WeatherEffectsRenderTests {
    @Test func renderBeforeAttachIsANoOp() {
        withSim(random: SimRandom.seeded(1)) {
            let w = WeatherEffects()
            w.setCondition("rain")
            w.update(16, 1000, 800)
            w.render()
            #expect(w.rainNodes.isEmpty)
        }
    }

    @Test func attachAndDetachManageTheWeatherLayer() {
        let w = WeatherEffects()
        let scene = makeScene()
        w.attach(to: scene)
        #expect(w.root.parent === scene.weatherLayer && w.root.isHidden)
        w.attach(to: scene)
        #expect(scene.weatherLayer.children.count == 1)
        w.detach()
        #expect(scene.weatherLayer.children.isEmpty)
    }

    @Test func rainMapsEveryDropToATiltedSprite() throws {
        try withSim(random: SimRandom.seeded(9)) {
            let w = WeatherEffects()
            let scene = makeScene()
            w.attach(to: scene)
            w.render() // nothing spawned yet
            #expect(w.root.isHidden)

            w.setCondition("rain")
            w.update(16, 1000, 800)
            w.render()
            #expect(!w.root.isHidden)
            #expect(w.rainNodes.count == 50 && w.snowNodes.isEmpty)
            for (i, p) in w.particles.enumerated() {
                let node = w.rainNodes[i]
                #expect(near(node.position, scene.scenePoint(p.x, p.y)))
                #expect(abs(Double(node.zRotation) - atan2(p.vx * 0.01, 6)) < 1e-6)
                #expect(!node.isHidden && node.texture != nil)
                #expect(node.anchorPoint == CGPoint(x: 0.5, y: 0.875))
            }

            // Baked stroke: 1pt wide, 6pt long, rgba(130,170,255,0.4), padded for AA.
            let img = try #require(w.rainNodes[0].texture?.cgImage())
            #expect(img.width == 8 && img.height == 16)
            let px = ambiencePixels(img)
            for x in [3, 4] {
                let a = px(x, 8).a
                #expect(abs(a - 102) <= 3, "alpha \(a)") // 0.4 * 255
                #expect(px(x, 2).a > 0 && px(x, 13).a > 0)  // stroke spans y = 0…6 (px 2…13)
                #expect(px(x, 1).a == 0 && px(x, 14).a == 0)
            }
            #expect(px(0, 8).a == 0 && px(7, 8).a == 0 && px(2, 8).a == 0 && px(5, 8).a == 0)
            #expect(px(3, 8).b > px(3, 8).r) // blue-ish
        }
    }

    @Test func snowMapsEveryFlakeToAScaledSprite() throws {
        try withSim(random: SimRandom.seeded(10)) {
            let w = WeatherEffects()
            let scene = makeScene()
            w.attach(to: scene)
            w.setCondition("snow")
            w.update(16, 1000, 800)
            w.render()
            #expect(!w.root.isHidden)
            #expect(w.snowNodes.count == 30 && w.rainNodes.isEmpty)
            for (i, p) in w.particles.enumerated() {
                let node = w.snowNodes[i]
                let size = 1.5 + sin(p.life * 5) * 0.5
                #expect(near(node.position, scene.scenePoint(p.x, p.y)))
                #expect(abs(Double(node.xScale) - size / 2) < 1e-6 && abs(Double(node.yScale) - size / 2) < 1e-6)
                #expect(size >= 1 && size <= 2)
                #expect(!node.isHidden && node.texture != nil)
            }

            // Baked flake: white disc, r 2pt, alpha 0.7.
            let img = try #require(w.snowNodes[0].texture?.cgImage())
            #expect(img.width == 12 && img.height == 12)
            let px = ambiencePixels(img)
            #expect(abs(px(5, 5).a - 178) <= 3 && abs(px(6, 6).a - 178) <= 3) // 0.7 * 255
            #expect(px(5, 5).r >= 175) // premultiplied white
            #expect(px(0, 0).a == 0 && px(11, 11).a == 0 && px(0, 6).a == 0)
        }
    }

    @Test func switchingConditionsSwapsPoolsAndHidesTheOldOne() {
        withSim(random: SimRandom.seeded(11)) {
            let w = WeatherEffects()
            w.attach(to: makeScene())
            w.setCondition("rain")
            w.update(16, 1000, 800)
            w.render()
            #expect(w.rainNodes.allSatisfy { !$0.isHidden })

            w.setCondition("snow") // particles cleared
            w.render()
            #expect(w.root.isHidden)
            w.update(16, 1000, 800)
            w.render()
            #expect(!w.root.isHidden)
            #expect(w.rainNodes.count == 50 && w.rainNodes.allSatisfy { $0.isHidden })
            #expect(w.snowNodes.count == 30 && w.snowNodes.allSatisfy { !$0.isHidden })

            w.setCondition("clear")
            w.update(16, 1000, 800)
            w.render()
            #expect(w.root.isHidden)
            w.setCondition(nil)
            w.render()
            #expect(w.root.isHidden)
        }
    }

    @Test func conditionsWithoutADrawBranchStayHidden() {
        withSim(random: SimRandom.seeded(12)) {
            let w = WeatherEffects()
            w.attach(to: makeScene())
            w.setCondition("fog")
            w.update(16, 1000, 800)
            w.render()
            #expect(w.root.isHidden && w.rainNodes.isEmpty && w.snowNodes.isEmpty)
        }
    }

    @Test func spritesFollowTheParticlesEachFrame() {
        withSim(random: SimRandom.seeded(13)) {
            let w = WeatherEffects()
            let scene = makeScene()
            w.attach(to: scene)
            w.setCondition("rain")
            w.update(16, 1000, 800)
            w.render()
            let firstY = w.rainNodes[0].position.y
            w.update(100, 1000, 800)
            w.render()
            let p = w.particles[0]
            #expect(near(w.rainNodes[0].position, scene.scenePoint(p.x, p.y)))
            #expect(w.rainNodes[0].position.y < firstY) // falling on screen = decreasing scene y
            #expect(w.rainNodes.count == 50) // pool reused, not regrown
        }
    }
}

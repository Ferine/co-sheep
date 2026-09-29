import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

private let july = localMs(2026, 7, 15)
private let december = localMs(2026, 12, 15)

@Suite("summer season")
struct SummerSeasonTests {
    @Test func juneThroughAugustOnly() {
        func season(_ m: Int, _ d: Int = 15) -> Bool {
            isSummerSeason(Date(timeIntervalSince1970: localMs(2026, m, d) / 1000))
        }
        #expect(season(5, 31) == false)
        #expect(season(6, 1) == true)
        #expect(season(7) == true)
        #expect(season(8, 31) == true)
        #expect(season(9, 1) == false)
        #expect(season(1) == false)
        #expect(season(12) == false)
    }

    @Test func seasonDefaultsToTheSimClock() {
        withSim(now: july) { #expect(isSummerSeason() == true) }
        withSim(now: december) { #expect(isSummerSeason() == false) }
    }

    @Test func quipsAreVerbatim() {
        #expect(SUMMER_IDLE_QUIPS == [
            "Sun's out, wool's out.",
            "This is prime grazing weather.",
            "I could nap in this sun forever.",
            "Anyone else smell sunscreen?",
            "A butterfly landed on me. I'm chosen.",
            "Too hot for a wool coat. Can't take it off though.",
        ])
        #expect(SUNBATHE_QUIPS == [
            "Ahhh... sol.",
            "Someone flip me in ten minutes.",
            "I'm working on my wool tan.",
            "This is the life.",
            "Wake me when it's autumn.",
            "SPF? Never heard of her.",
        ])
    }
}

@Suite("summer theme", .serialized)
struct SummerThemeTests {
    @Test func activatesInSummerWithNoWeatherConfigured() {
        withSim(now: july) {
            let theme = SummerTheme(1920, 1080)
            #expect(theme.active)
            #expect(theme.sunflowers.count == 8)
            #expect(theme.butterflies.count == 4)
            #expect(theme.seeds.count == 10)
        }
        withSim(now: december) {
            let theme = SummerTheme(1920, 1080)
            #expect(!theme.active)
            #expect(theme.sunflowers.isEmpty && theme.butterflies.isEmpty && theme.seeds.isEmpty)
        }
    }

    @Test func weatherDecidesDuringTheSeason() {
        withSim(now: july) {
            let theme = SummerTheme(1920, 1080)
            #expect(theme.active) // no weather → the season decides

            theme.setWeather("rain", 20)
            #expect(!theme.active)
            #expect(theme.sunflowers.isEmpty && theme.butterflies.isEmpty && theme.seeds.isEmpty)

            theme.setWeather("clear", 17.9)
            #expect(!theme.active) // clear but below 18°C

            theme.setWeather("clear", 18)
            #expect(theme.active)
            #expect(theme.sunflowers.count == 8)

            theme.setWeather("clear", nil) // clear, temperature unknown
            #expect(theme.active)

            theme.setWeather("cloudy", nil)
            #expect(!theme.active)

            theme.setWeather(nil, nil)
            #expect(theme.active)
        }
    }

    @Test func weatherNeverActivatesOutsideTheSeason() {
        withSim(now: december) {
            let theme = SummerTheme(1920, 1080)
            theme.setWeather("clear", 30)
            #expect(!theme.active)
        }
    }

    @Test func modeOverrideBeatsSeasonAndWeather() {
        withSim(now: december) {
            let theme = SummerTheme(1920, 1080)
            theme.setModeOverride(.on)
            #expect(theme.active && theme.sunflowers.count == 8)
            theme.setWeather("rain", 5)
            #expect(theme.active) // still forced on
            theme.setModeOverride(.off)
            #expect(!theme.active && theme.sunflowers.isEmpty)
            theme.setModeOverride() // .auto → winter → off
            #expect(!theme.active)
        }
        withSim(now: july) {
            let theme = SummerTheme(1920, 1080)
            theme.setModeOverride(.off)
            #expect(!theme.active)
            theme.setModeOverride(.auto)
            #expect(theme.active)
        }
        #expect(SummerMode.allCases.map(\.rawValue) == ["auto", "on", "off"])
    }

    @Test func decorationsRespawnOnResizeWhileActive() {
        withSim(now: july, random: SimRandom.seeded(1)) {
            let theme = SummerTheme(1000, 500)
            let before = theme.butterflies.map(\.x)
            theme.updateScreenSize(2000, 1000)
            #expect(theme.butterflies.count == 4 && theme.butterflies.map(\.x) != before)
            #expect(theme.butterflies.allSatisfy { $0.x < 2000 && $0.y >= 400 && $0.y < 1000 * 0.85 })
        }
        withSim(now: december) {
            let theme = SummerTheme(1000, 500)
            theme.updateScreenSize(2000, 1000)
            #expect(theme.sunflowers.isEmpty)
        }
    }

    @Test func spawnedDecorationsStayInTheirRanges() {
        withSim(now: july, random: SimRandom.seeded(12)) {
            let theme = SummerTheme(1000, 800)
            for f in theme.sunflowers {
                #expect(f.size >= 26 && f.size < 40)
                #expect(f.swaySpeed >= 0.4 && f.swaySpeed < 0.9)
            }
            for b in theme.butterflies {
                #expect(b.retargetTimer >= 1000 && b.retargetTimer < 5000)
                #expect(["#FF8C42", "#FFD23F", "#F26CA7", "#7FB5FF", "#B8E986"].contains(b.color))
            }
            for s in theme.seeds {
                #expect(s.vx >= 8 && s.vx < 22 && s.vy <= -2 && s.vy > -8)
                #expect(s.size >= 2 && s.size < 4)
            }
        }
    }

    @Test func butterfliesVisitCalmSheepWhenRetargeting() {
        // Constant 0.1: sheep pick index 0, "visit" roll (0.1 < 0.45) passes.
        withSim(now: july, random: { 0.1 }) {
            let theme = SummerTheme(1000, 800)
            let sheep = [
                SheepPosition(x: 500, y: 600, state: .walk),      // not calm
                SheepPosition(x: 200, y: 700, state: .sit),       // calm
            ]
            theme.update(6000, sheep) // every retarget timer (<= 5000ms) has expired
            for b in theme.butterflies {
                #expect(abs(b.targetX - (200 + 30 + 0.1 * 40)) < 1e-9)
                #expect(abs(b.targetY - (700 - 20 - 0.1 * 30)) < 1e-9)
                #expect(b.retargetTimer >= 2000 - 1e-9 && b.retargetTimer < 7000)
            }
        }
    }

    @Test func butterfliesWanderWhenNoOneIsCalm() {
        withSim(now: july, random: { 0.5 }) {
            let theme = SummerTheme(1000, 800)
            theme.update(6000, [SheepPosition(x: 200, y: 700, state: .walk)])
            for b in theme.butterflies {
                #expect(abs(b.targetX - 500) < 1e-9)
                #expect(abs(b.targetY - 800 * (0.35 + 0.5 * 0.5)) < 1e-9)
            }
        }
    }

    @Test func butterfliesFlutterAndEaseTowardTheirTarget() {
        withSim(now: july, random: SimRandom.seeded(77)) {
            let theme = SummerTheme(1000, 800)
            let b0 = theme.butterflies[0]
            theme.update(16, [])
            let b1 = theme.butterflies[0]
            #expect(abs(b1.wingPhase - (b0.wingPhase + 0.016 * 14)) < 1e-9)
            #expect(b1.x != b0.x || b1.y != b0.y)
            #expect(abs(b1.retargetTimer - (b0.retargetTimer - 16)) < 1e-9)
        }
    }

    @Test func seedsDriftRightAndRespawnAtTheLeftEdge() {
        withSim(now: july, random: SimRandom.seeded(5)) {
            let theme = SummerTheme(1000, 800)
            theme.update(1_000_000, []) // 1000s: every seed is far past 1015px (vx >= 8) or above -15px
            // ...so each one respawned just off the left edge.
            #expect(theme.seeds.allSatisfy { $0.x == -10 })
            #expect(theme.seeds.allSatisfy { $0.y >= 800 * 0.3 && $0.y < 800 * 0.8 })
        }
    }

    @Test func updateDoesNothingWhileInactive() {
        withSim(now: december) {
            let theme = SummerTheme(1000, 800)
            theme.update(1000, [SheepPosition(x: 1, y: 2, state: .sit)])
            #expect(theme.butterflies.isEmpty && theme.seeds.isEmpty)
        }
    }

    @Test func seasonAndWeatherAreRecheckedEveryMinute() {
        let saved = SimClock.nowSource
        defer { SimClock.nowSource = saved }
        SimClock.nowSource = { december }
        let theme = SummerTheme(1000, 800)
        #expect(!theme.active)
        SimClock.nowSource = { july }
        theme.update(59_999, [])
        #expect(!theme.active)
        theme.update(1, []) // 60_000 → refresh
        #expect(theme.active && theme.sunflowers.count == 8)
        SimClock.nowSource = { december }
        theme.update(60_000, [])
        #expect(!theme.active && theme.butterflies.isEmpty)
    }

    // MARK: drawing

    @Test func inactiveThemeDrawsNothing() {
        withSim(now: december) {
            let theme = SummerTheme(1000, 800)
            let c = Canvas()
            c.beginFrame()
            theme.drawBackground(c, 1000, 800)
            theme.drawMidground(c, 1000, 800)
            theme.drawForeground(c, 1000, 800)
            #expect(drawnOpCount(c) == 0)
        }
    }

    @Test func drawsSunSunflowersButterfliesAndSeeds() {
        withSim(now: july, random: SimRandom.seeded(3)) {
            let theme = SummerTheme(1000, 800)
            theme.update(16, [])
            let c = Canvas()

            c.beginFrame()
            theme.drawBackground(c, 1000, 800)
            // halo + 12 rays + core
            #expect(drawnOpCount(c) == 1 + 12 + 1)
            let halo = c.groups[0].ops[0]
            #expect(abs(halo.bounds.midX - 880) < 0.01 && abs(halo.bounds.midY - 90) < 0.01)
            #expect(abs(halo.bounds.width - 34 * 8) < 0.01)

            c.beginFrame()
            theme.drawMidground(c, 1000, 800)
            // per sunflower: stem + leaf + 10 petals + center
            #expect(drawnOpCount(c) == 8 * 13)

            c.beginFrame()
            theme.drawForeground(c, 1000, 800)
            // per seed: puff + 4 spokes; per butterfly: 2 wings + body
            #expect(drawnOpCount(c) == 10 * 5 + 4 * 3)
        }
    }

    @Test func sunPositionFollowsTheScreenWidth() {
        withSim(now: july, random: SimRandom.seeded(3)) {
            let theme = SummerTheme(2000, 800)
            let c = Canvas()
            c.beginFrame()
            theme.drawBackground(c, 2000, 800)
            let core = c.groups[0].ops.last!
            #expect(abs(core.bounds.midX - 2000 * 0.88) < 0.01 && abs(core.bounds.midY - 90) < 0.01)
        }
    }
}

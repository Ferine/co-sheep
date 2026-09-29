import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

/// A local date-time as epoch ms (for `SimClock.nowSource`).
func localMs(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12, minute: Int = 0) -> Double {
    Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
        .timeIntervalSince1970 * 1000
}

/// Runs `body` with `SimClock`/`SimRandom` overridden, restoring them afterwards.
@MainActor
func withSim<T>(now: Double? = nil, random: (() -> Double)? = nil, _ body: @MainActor () throws -> T) rethrows -> T {
    let savedNow = SimClock.nowSource
    let savedRandom = SimRandom.source
    defer {
        SimClock.nowSource = savedNow
        SimRandom.source = savedRandom
    }
    if let now { SimClock.nowSource = { now } }
    if let random { SimRandom.source = random }
    return try body()
}

/// Every text string drawn into a canvas frame.
func drawnTexts(_ c: Canvas) -> [String] {
    c.groups.flatMap(\.ops).compactMap { op in
        if case .text(let s, _, _, _, _, _, _) = op.kind { return s }
        return nil
    }
}

func drawnOpCount(_ c: Canvas) -> Int {
    c.groups.reduce(0) { $0 + $1.ops.count }
}

private let outOfSeason = localMs(2026, 9, 29) // today's date in the plan; far from Easter
private let easterDay2026 = localMs(2026, 4, 5)

private func drawAll(_ theme: EasterTheme, _ c: Canvas, w: Double = 1920, h: Double = 1080) {
    c.beginFrame()
    theme.drawBackground(c, w, h)
    theme.drawMidground(c, w, h)
    theme.drawForeground(c, w, h)
}

@Suite("easter calendar")
struct EasterCalendarTests {
    @Test func computesEasterSunday() {
        func ymd(_ y: Int) -> (Int, Int, Int) {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: computeEasterSunday(y))
            return (c.year!, c.month!, c.day!)
        }
        #expect(ymd(2024) == (2024, 3, 31))
        #expect(ymd(2025) == (2025, 4, 20))
        #expect(ymd(2026) == (2026, 4, 5))
        #expect(ymd(2027) == (2027, 3, 28))
        #expect(ymd(2019) == (2019, 4, 21))
        #expect(ymd(2000) == (2000, 4, 23))
        #expect(ymd(1961) == (1961, 4, 2))
        #expect(ymd(2038) == (2038, 4, 25))
    }

    @Test func seasonIsFiveDaysBeforeToTwoDaysAfter() {
        func season(_ m: Int, _ d: Int, hour: Int = 12, minute: Int = 0) -> Bool {
            isEasterSeason(Date(timeIntervalSince1970: localMs(2026, m, d, hour: hour, minute: minute) / 1000))
        }
        #expect(season(3, 30) == false)
        #expect(season(3, 31, hour: 0, minute: 0) == true) // Easter - 5, first instant
        #expect(season(4, 5) == true)
        #expect(season(4, 7, hour: 23, minute: 59) == true) // Easter + 2, last minute
        #expect(season(4, 8, hour: 0, minute: 0) == false)
        #expect(season(9, 29) == false)
    }

    @Test func seasonDefaultsToTheSimClock() {
        withSim(now: easterDay2026) { #expect(isEasterSeason() == true) }
        withSim(now: outOfSeason) { #expect(isEasterSeason() == false) }
    }
}

@Suite("easter theme", .serialized)
struct EasterThemeTests {
    @Test func inactiveOutsideTheSeasonAndDrawsNothing() {
        withSim(now: outOfSeason) {
            let theme = EasterTheme(1920, 1080)
            #expect(theme.active == false)
            #expect(theme.flowers.isEmpty && theme.eggs.isEmpty)
            let c = Canvas()
            drawAll(theme, c)
            #expect(drawnOpCount(c) == 0)
            #expect(theme.getEggPositions().isEmpty)
        }
    }

    @Test func activatesInSeasonAndSeedsFlowersAndEggs() {
        withSim(now: easterDay2026) {
            let theme = EasterTheme(1920, 1080)
            #expect(theme.active == true)
            #expect(theme.flowers.count == 16)
            #expect(theme.eggs.count == 6 || theme.eggs.count == 7)
            #expect(theme.getModeOverride() == .auto)
        }
    }

    @Test func modeOverrideForcesOnAndOff() {
        withSim(now: outOfSeason) {
            let theme = EasterTheme(1920, 1080)
            theme.setModeOverride(.on)
            #expect(theme.active && theme.flowers.count == 16 && !theme.eggs.isEmpty)
            theme.setModeOverride(.off)
            #expect(!theme.active && theme.flowers.isEmpty && theme.eggs.isEmpty)
            theme.setModeOverride(.auto)
            #expect(!theme.active)
        }
        withSim(now: easterDay2026) {
            let theme = EasterTheme(1920, 1080)
            theme.setModeOverride(.off)
            #expect(!theme.active)
            theme.setModeOverride()
            #expect(theme.getModeOverride() == .auto && theme.active)
        }
    }

    @Test func modeRawValuesMatchTheReference() {
        #expect(EasterMode.allCases.map(\.rawValue) == ["auto", "on", "off"])
        #expect(EasterMode(rawValue: "on") == .on)
    }

    @Test func refreshActiveStateReportsChanges() {
        withSim(now: outOfSeason) {
            let theme = EasterTheme(800, 600)
            #expect(theme.refreshActiveState() == false)
            #expect(theme.refreshActiveState(true) == true) // force always reseeds
        }
    }

    @Test func eggsAreSpreadOutSortedAndAtMostOneGolden() {
        for seed in 1...40 {
            withSim(now: easterDay2026, random: SimRandom.seeded(UInt64(seed))) {
                let theme = EasterTheme(1000, 500)
                let xs = theme.eggs.map(\.x)
                #expect(xs == xs.sorted())
                for (a, b) in zip(xs, xs.dropFirst()) {
                    #expect(b - a > 0.07 - 0.011) // spawn points are >= 0.07 apart, each jittered +-0.005
                }
                #expect(theme.eggs.filter(\.isGolden).count <= 1)
                for egg in theme.eggs {
                    #expect(egg.y > 0.86 && egg.y < 0.97)
                    if egg.isGolden {
                        #expect(egg.hiddenness == 0.12)
                        #expect(egg.baseColor == "#FFE07B" && egg.stripeColor == "#F2B705" && egg.accentColor == "#FFF7CC")
                    } else {
                        #expect(egg.hiddenness >= 0.18 && egg.hiddenness < 0.56)
                    }
                    #expect(egg.shadowScale >= 0.8 && egg.shadowScale < 1.2)
                    #expect(!egg.found && egg.sparkleTimer == 0)
                }
            }
        }
    }

    @Test func eggPositionsScaleWithTheScreen() {
        withSim(now: easterDay2026, random: SimRandom.seeded(7)) {
            let theme = EasterTheme(1000, 500)
            let small = theme.getEggPositions()
            theme.updateScreenSize(2000, 1000)
            let big = theme.getEggPositions()
            #expect(small.count == big.count)
            for (s, b) in zip(small, big) {
                #expect(abs(b.x - s.x * 2) < 1e-9 && abs(b.y - s.y * 2) < 1e-9)
                #expect(s.painted == false && s.painterName == nil)
            }
        }
    }

    @Test func collectingEggsFillsTheBasketAndStartsTheBuzz() {
        withSim(now: easterDay2026, random: SimRandom.seeded(3)) {
            let theme = EasterTheme(1000, 500)
            theme.prepareHunt(["main", "friend_1"])
            #expect(theme.shouldShowBasket("main") && theme.shouldShowBasket("friend_1"))
            #expect(!theme.shouldShowBasket("friend_2"))
            #expect(theme.hasRecentHuntBuzz() == false)

            theme.collectEgg(0, "main")
            let golden = theme.eggs[0].isGolden
            #expect(theme.eggs[0].found)
            #expect(theme.eggs[0].sparkleTimer == (golden ? 3.4 : 2.2))
            #expect(theme.getBasketEggCount("main") == (golden ? 2 : 1))
            #expect(theme.hasRecentHuntBuzz())
            #expect(theme.getEggPositions()[0].found)

            // collecting again, out-of-range and empty finder ids are ignored
            let before = theme.getBasketEggCount("main")
            theme.collectEgg(0, "main")
            theme.collectEgg(-1, "main")
            theme.collectEgg(999, "main")
            #expect(theme.getBasketEggCount("main") == before)
            theme.collectEgg(1, "")
            #expect(theme.eggs[1].found && theme.getBasketEggCount("") == 0)
            theme.collectEgg(2)
            #expect(theme.eggs[2].found)

            // a finished hunt keeps baskets visible for whoever holds eggs
            theme.finishHunt()
            #expect(theme.shouldShowBasket("main"))
            #expect(!theme.shouldShowBasket("friend_1"))
            #expect(theme.getBasketFillRatio("main") == min(1, Double(theme.getBasketEggCount("main")) / 3))
        }
    }

    @Test func basketFillRatioClampsAtOne() {
        withSim(now: easterDay2026, random: SimRandom.seeded(11)) {
            let theme = EasterTheme(1000, 500)
            theme.prepareHunt(["main"])
            for i in 0..<theme.eggs.count { theme.collectEgg(i, "main") }
            #expect(theme.getBasketEggCount("main") >= 6)
            #expect(theme.getBasketFillRatio("main") == 1)
            #expect(theme.getBasketFillRatio("nobody") == 0)
        }
    }

    @Test func huntsAndResetsNeedTheThemeToBeActive() {
        withSim(now: outOfSeason) {
            let theme = EasterTheme(1000, 500)
            theme.prepareHunt(["main"])
            #expect(!theme.shouldShowBasket("main"))
            theme.resetEggs()
            #expect(theme.eggs.isEmpty)
            theme.registerPaintedEgg("main", "Sheepy")
            #expect(theme.paintedEggDesigns.isEmpty)
        }
    }

    @Test func prepareHuntAndResetEggsReseed() {
        withSim(now: easterDay2026, random: SimRandom.seeded(5)) {
            let theme = EasterTheme(1000, 500)
            theme.collectEgg(0, "main")
            #expect(theme.getBasketEggCount("main") > 0)
            theme.prepareHunt(["main"])
            #expect(theme.getBasketEggCount("main") == 0)
            #expect(theme.eggs.allSatisfy { !$0.found })
            theme.collectEgg(0, "main")
            theme.resetEggs()
            #expect(theme.getBasketEggCount("main") == 0)
            #expect(!theme.shouldShowBasket("main"))
            #expect(theme.eggs.allSatisfy { !$0.found })
        }
    }

    @Test func paintedEggsAreRememberedNewestFirstAndCappedAtSix() {
        withSim(now: easterDay2026, random: SimRandom.seeded(9)) {
            let theme = EasterTheme(1000, 500)
            for i in 0..<8 { theme.registerPaintedEgg("id_\(i)", "Name \(i)") }
            #expect(theme.paintedEggDesigns.count == 6)
            #expect(theme.paintedEggDesigns.map(\.painterId) == ["id_7", "id_6", "id_5", "id_4", "id_3", "id_2"])
            #expect(theme.paintedEggDesigns[0].painterName == "Name 7")
        }
    }

    @Test func paintedDesignsAppearOnNewlySeededEggs() {
        // Constant 0.3: every egg rolls "use a painted design" (0.3 < 0.45) until the pool runs dry.
        withSim(now: easterDay2026, random: { 0.3 }) {
            let theme = EasterTheme(1000, 500)
            theme.registerPaintedEgg("id_a", "Alpha")
            theme.registerPaintedEgg("id_b", "Beta")
            theme.prepareHunt(["main"])
            let painted = theme.getEggPositions().filter(\.painted)
            #expect(painted.count == 2)
            #expect(theme.getPaintedEggsUsedCount() == 2)
            #expect(Set(painted.compactMap(\.painterName)) == ["Alpha", "Beta"])
            // designs keep their pattern/colors on the egg
            for egg in theme.eggs {
                if let d = egg.paintedBy {
                    #expect(egg.baseColor == d.baseColor && egg.pattern == d.pattern)
                }
            }
        }
    }

    @Test func updateFillsAndRecyclesPetals() {
        withSim(now: easterDay2026, random: SimRandom.seeded(21)) {
            let theme = EasterTheme(1000, 500)
            #expect(theme.petals.isEmpty)
            theme.update(16, [])
            #expect(theme.petals.count == 18)
            for _ in 0..<600 { theme.update(16, [SheepPosition(x: 300, y: 400, state: .idle)]) }
            #expect(theme.petals.count == 18)
            for p in theme.petals {
                #expect(p.x >= -20 && p.x <= 1020 && p.y >= -20)
                #expect(p.size >= 3 && p.size < 7)
            }
        }
    }

    @Test func petalsAreNudgedAwayFromNearbySheep() {
        // Same seed twice: one run with a sheep right on top of the petals, one without.
        func run(_ sheep: [SheepPosition]) -> [Double] {
            withSim(now: easterDay2026, random: SimRandom.seeded(33)) {
                let theme = EasterTheme(400, 300)
                theme.update(16, [])
                theme.update(1000, sheep)
                return theme.petals.map(\.x)
            }
        }
        let free = run([])
        let pushed = run([SheepPosition(x: 200 - 48, y: 300 - 56, state: .idle)])
        #expect(free != pushed)
    }

    @Test func sparklesCountDownAfterCollection() {
        withSim(now: easterDay2026, random: SimRandom.seeded(4)) {
            let theme = EasterTheme(1000, 500)
            theme.collectEgg(0, "main")
            let start = theme.eggs[0].sparkleTimer
            theme.update(1000, [])
            #expect(abs(theme.eggs[0].sparkleTimer - (start - 1)) < 1e-9)
        }
    }

    @Test func seasonIsRecheckedEveryMinute() {
        let saved = SimClock.nowSource
        defer { SimClock.nowSource = saved }
        SimClock.nowSource = { outOfSeason }
        let theme = EasterTheme(1000, 500)
        #expect(!theme.active)
        SimClock.nowSource = { easterDay2026 }
        theme.update(59_999, [])
        #expect(!theme.active)
        theme.update(2, []) // crosses 60s
        #expect(theme.active)
        #expect(theme.flowers.count == 16)
        SimClock.nowSource = { outOfSeason }
        theme.update(60_000, [])
        #expect(!theme.active && theme.eggs.isEmpty)
    }

    @Test func sheepHooksProtocolIsImplemented() {
        withSim(now: easterDay2026) {
            let theme = EasterTheme(1000, 500)
            let hooks: any EasterThemeHooks = theme
            #expect(hooks.active)
            hooks.registerPaintedEgg("main", "Sheepy")
            #expect(theme.paintedEggDesigns.count == 1)
            #expect(theme.paintedEggDesigns[0].painterName == "Sheepy")
        }
    }

    // MARK: drawing

    @Test func drawsBackgroundMidgroundAndForegroundThroughTheCanvas() {
        withSim(now: easterDay2026, random: SimRandom.seeded(2)) {
            let theme = EasterTheme(1920, 1080)
            theme.update(16, [])
            let c = Canvas()
            c.beginFrame()
            theme.drawBackground(c, 1920, 1080)
            let bg = drawnOpCount(c)
            #expect(bg > 16 * 3) // ground wash + per-flower stem/petals/center
            theme.drawMidground(c, 1920, 1080)
            let mid = drawnOpCount(c)
            #expect(mid > bg)
            theme.drawForeground(c, 1920, 1080)
            #expect(drawnOpCount(c) > mid)
            // the ground wash is the first op and spans the lower 30% of the screen
            let wash = c.groups[0].ops[0]
            #expect(abs(wash.bounds.minY - 1080 * 0.7) < 0.01 && abs(wash.bounds.height - 1080 * 0.3) < 0.01)
        }
    }

    @Test func everyEggPatternDraws() {
        for seed in 1...30 {
            withSim(now: easterDay2026, random: SimRandom.seeded(UInt64(seed))) {
                let theme = EasterTheme(1000, 500)
                let c = Canvas()
                c.beginFrame()
                theme.drawMidground(c, 1000, 500)
                #expect(drawnOpCount(c) > 0)
            }
        }
        #expect(EasterTheme.PATTERNS.map(\.rawValue) == ["stripe", "zigzag", "dots", "bands", "cross"])
    }

    @Test func foundEggsAreNotDrawnButSparkle() {
        withSim(now: easterDay2026, random: SimRandom.seeded(8)) {
            let theme = EasterTheme(1000, 500)
            theme.update(16, [])
            let c = Canvas()
            c.beginFrame()
            theme.drawMidground(c, 1000, 500)
            let all = drawnOpCount(c)
            theme.collectEgg(0, "main")
            c.beginFrame()
            theme.drawMidground(c, 1000, 500)
            #expect(drawnOpCount(c) < all)
            c.beginFrame()
            theme.drawForeground(c, 1000, 500)
            let withSparkle = drawnOpCount(c)
            for i in theme.eggs.indices { theme.collectEgg(i) }
            theme.update(3_000_000, []) // burn every sparkle timer out
            c.beginFrame()
            theme.drawForeground(c, 1000, 500)
            #expect(drawnOpCount(c) < withSparkle)
        }
    }

    @Test func hudShowsStatsWhileVisible() {
        withSim(now: easterDay2026, random: SimRandom.seeded(6)) {
            let theme = EasterTheme(1000, 500)
            theme.applyStats(EasterStatsSnapshot(
                eggsFoundToday: 3, goldenEggsToday: 1, huntsCompleted: 4, currentStreak: 2, flockScore: 55,
                topHunterName: "Shaun", lastWinnerName: "Timmy"))
            let c = Canvas()
            c.beginFrame()
            theme.drawForeground(c, 1000, 500)
            let texts = drawnTexts(c)
            #expect(texts == ["SPRING LEDGER", "Eggs today 3", "Golden 1", "Streak 2  Hunts 4", "Score 55",
                              "Shaun", "Seasonal"])
        }
    }

    @Test func hudFallsBackToLastWinnerThenNobody() {
        withSim(now: easterDay2026, random: SimRandom.seeded(6)) {
            let theme = EasterTheme(1000, 500)
            @MainActor func topLine(_ s: EasterStatsSnapshot?) -> String {
                theme.applyStats(s)
                let c = Canvas()
                c.beginFrame()
                theme.drawForeground(c, 1000, 500)
                return drawnTexts(c)[5]
            }
            #expect(topLine(EasterStatsSnapshot(topHunterName: "", lastWinnerName: "Timmy")) == "Timmy")
            #expect(topLine(EasterStatsSnapshot(topHunterName: "", lastWinnerName: "")) == "Nobody yet")
            #expect(topLine(EasterStatsSnapshot()) == "Nobody yet")
            #expect(topLine(nil) == "Nobody yet")
        }
    }

    @Test func hudDefaultsToZerosAndShowsForcedMode() {
        withSim(now: easterDay2026, random: SimRandom.seeded(6)) {
            let theme = EasterTheme(1000, 500)
            theme.setModeOverride(.on)
            let c = Canvas()
            c.beginFrame()
            theme.drawForeground(c, 1000, 500)
            #expect(drawnTexts(c) == ["SPRING LEDGER", "Eggs today 0", "Golden 0", "Streak 0  Hunts 0", "Score 0",
                                      "Nobody yet", "Forced on"])
        }
    }

    @Test func hudHidesAfterItsTimerRunsOut() {
        withSim(now: easterDay2026, random: SimRandom.seeded(6)) {
            let theme = EasterTheme(1000, 500)
            let c = Canvas()
            c.beginFrame()
            theme.drawForeground(c, 1000, 500)
            #expect(drawnTexts(c).contains("SPRING LEDGER")) // shown on activation (18s)
            theme.update(18_001, [])
            c.beginFrame()
            theme.drawForeground(c, 1000, 500)
            #expect(!drawnTexts(c).contains("SPRING LEDGER"))
            // a collected egg re-shows it
            theme.collectEgg(0, "main")
            c.beginFrame()
            theme.drawForeground(c, 1000, 500)
            #expect(drawnTexts(c).contains("SPRING LEDGER"))
        }
    }

    @Test func hudIsAnchoredTopRight() throws {
        withSim(now: easterDay2026, random: SimRandom.seeded(6)) {
            let theme = EasterTheme(1000, 500)
            let c = Canvas()
            c.beginFrame()
            theme.drawForeground(c, 1000, 500)
            let textOps = c.groups.flatMap(\.ops).compactMap { op -> (String, Double, Double, TextAlign)? in
                if case .text(let s, _, let x, let y, let align, _, _) = op.kind { return (s, x, y, align) }
                return nil
            }
            let title = textOps.first { $0.0 == "SPRING LEDGER" }
            #expect(title?.1 == 1000 - 188 - 18 + 14 && title?.2 == 18 + 18)
            #expect(textOps.first { $0.0 == "Seasonal" }?.3 == .right)
            #expect(textOps.first { $0.0 == "Score 0" }?.3 == .start) // alignment resets
        }
    }
}

@Suite("easter stats json")
struct EasterStatsJSONTests {
    @Test func decodesTheRustSnakeCaseShapeIgnoringExtras() throws {
        let json = """
        {"last_reset_date": "2026-04-05", "eggs_found_total": 40, "eggs_found_today": 5,
         "golden_eggs_total": 2, "golden_eggs_today": 1, "hunts_completed": 9, "hunts_today": 2,
         "current_streak": 3, "best_streak": 7, "painted_eggs_used_total": 4, "flock_score": 123,
         "top_hunter_id": "friend_1", "top_hunter_name": "Shaun", "last_winner_id": "main",
         "last_winner_name": "Sheepy", "hunters": {"main": {"sheep_id": "main"}}}
        """
        let s = try JSONDecoder().decode(EasterStatsSnapshot.self, from: Data(json.utf8))
        #expect(s == EasterStatsSnapshot(
            eggsFoundTotal: 40, eggsFoundToday: 5, goldenEggsTotal: 2, goldenEggsToday: 1, huntsCompleted: 9,
            huntsToday: 2, currentStreak: 3, bestStreak: 7, paintedEggsUsedTotal: 4, flockScore: 123,
            topHunterName: "Shaun", lastWinnerName: "Sheepy"))
    }

    @Test func missingFieldsAreNil() throws {
        let s = try JSONDecoder().decode(EasterStatsSnapshot.self, from: Data("{}".utf8))
        #expect(s == EasterStatsSnapshot())
        #expect(s.eggsFoundToday == nil && s.topHunterName == nil)
    }
}

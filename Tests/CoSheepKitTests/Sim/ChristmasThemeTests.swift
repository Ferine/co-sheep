import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

private let december = localMs(2026, 12, 13)
private let july = localMs(2026, 7, 15)

private func drawAll(_ theme: ChristmasTheme, _ c: Canvas, w: Double = 1920, h: Double = 1080) {
    c.beginFrame()
    theme.drawBackground(c, w, h)
    theme.drawMidground(c, w, h)
    theme.drawForeground(c, w, h)
}

private func group(_ c: Canvas, _ key: String) -> CanvasGroup? {
    c.groups.first { $0.key == key }
}

@Suite("julekalender doors")
struct JulekalenderDoorTests {
    @Test func thereAreTwentyFourDoorsEachWithALine() {
        #expect(JULEKALENDER_DOORS.count == ChristmasSeason.doorCount)
        #expect(JULEKALENDER_DOORS.allSatisfy { !$0.line.isEmpty })
        #expect(Set(JULEKALENDER_DOORS.map(\.line)).count == 24)
    }

    @Test func theBigDaysHaveTheirOwnDoors() {
        #expect(JULEKALENDER_DOORS[0].effect == .animation(.bounce))
        #expect(JULEKALENDER_DOORS[5].effect == .juletregang)
        #expect(JULEKALENDER_DOORS[7].effect == .giftExchange)
        #expect(JULEKALENDER_DOORS[12].line == "Lucia! Where are my lussekatter?")
        #expect(JULEKALENDER_DOORS[12].effect == .lightShow)
        #expect(JULEKALENDER_DOORS[22].line == "lille julaften. Same procedure as every year.")
        #expect(JULEKALENDER_DOORS[23] == JulekalenderDoor(line: "God jul! Now look up.", effect: .sleigh))
    }

    @Test func everyKindOfSurpriseIsBehindSomeDoor() {
        let effects = JULEKALENDER_DOORS.map(\.effect)
        #expect(effects.contains(.quip))
        #expect(effects.contains(.juletregang))
        #expect(effects.contains(.giftExchange))
        #expect(effects.contains(.flurry))
        #expect(effects.contains(.lightShow))
        #expect(effects.filter { $0 == .sleigh }.count == 1)
        #expect(effects.contains { if case .animation = $0 { true } else { false } })
    }

    @Test func idleQuipsAreVerbatim() {
        #expect(CHRISTMAS_IDLE_QUIPS == [
            "This hat is non-negotiable, apparently.",
            "I've been good this year. Mostly. Define good.",
            "Is that pine? I smell pine.",
            "Somebody plug in the tree. Oh. It is.",
            "Wool: nature's Christmas sweater.",
            "If one more bulb blinks at me...",
            "Snow again. Free wool wash.",
        ])
    }
}

@Suite("christmas theme", .serialized)
struct ChristmasThemeTests {
    @Test func activatesInSeasonAndWrapsThePresents() {
        withSim(now: december) {
            let theme = ChristmasTheme(1920, 1080)
            #expect(theme.active)
            #expect(theme.presents.count == 6)
            #expect(theme.presents.allSatisfy { !$0.opened && $0.sparkleTimer == 0 })
            #expect(theme.notes.isEmpty)
            #expect(theme.hudVisible)
        }
        withSim(now: july) {
            let theme = ChristmasTheme(1920, 1080)
            #expect(!theme.active)
            #expect(theme.presents.isEmpty)
            #expect(!theme.hudVisible)
        }
    }

    @Test func modeOverrideBeatsTheCalendar() {
        withSim(now: july) {
            let theme = ChristmasTheme(1920, 1080)
            theme.setModeOverride(.on)
            #expect(theme.active && theme.presents.count == 6)
            #expect(theme.getModeOverride() == .on)
            theme.setModeOverride(.off)
            #expect(!theme.active && theme.presents.isEmpty)
            theme.setModeOverride() // .auto → July → off
            #expect(!theme.active)
        }
        withSim(now: december) {
            let theme = ChristmasTheme(1920, 1080)
            theme.setModeOverride(.off)
            #expect(!theme.active)
            theme.setModeOverride(.auto)
            #expect(theme.active)
        }
    }

    @Test func theCalendarIsRecheckedEveryMinute() {
        let saved = SimClock.nowSource
        defer { SimClock.nowSource = saved }
        SimClock.nowSource = { localMs(2026, 11, 30, hour: 23, minute: 59) }
        let theme = ChristmasTheme(1000, 800)
        #expect(!theme.active)
        SimClock.nowSource = { localMs(2026, 12, 1, hour: 0, minute: 0) }
        theme.update(59_999)
        #expect(!theme.active)
        theme.update(1) // 60_000 → refresh
        #expect(theme.active && theme.presents.count == 6)
        SimClock.nowSource = { localMs(2027, 1, 7, hour: 0, minute: 0) }
        theme.update(60_000)
        #expect(!theme.active && theme.presents.isEmpty)
    }

    @Test func reapplyingTheModeDoesNotRewrapThePresents() {
        withSim(now: december) {
            let theme = ChristmasTheme(1920, 1080)
            theme.openPresent(2)
            theme.setModeOverride(.auto) // every settings save re-applies the mode
            theme.setModeOverride(.on)
            #expect(theme.presents[2].opened)
            theme.resetPresents()
            #expect(theme.presents.allSatisfy { !$0.opened })
        }
    }

    @Test func geometryFollowsTheScreen() {
        withSim(now: december) {
            let theme = ChristmasTheme(1920, 1080)
            #expect(theme.treeX == 1344)
            #expect(theme.groundY == 1080 - 80 - 3)
            theme.updateScreenSize(1000, 800)
            #expect(theme.treeX == 700)
            #expect(theme.groundY == 717)
            let xs = theme.getPresentPositions().map(\.x)
            #expect(xs == [610, 634, 658, 744, 768, 792])
        }
    }

    @Test func theTreeIsFiveOverhangingTiers() {
        #expect(ChristmasTheme.treeHalfWidth(3) == nil) // trunk
        #expect(ChristmasTheme.treeHalfWidth(4) == 20)
        #expect(ChristmasTheme.treeHalfWidth(12) == 12)
        #expect(ChristmasTheme.treeHalfWidth(13) == 17) // the next tier's skirt juts out
        #expect(ChristmasTheme.treeHalfWidth(40) == 8)
        #expect(ChristmasTheme.treeHalfWidth(48) == 0) // the tip
        #expect(ChristmasTheme.treeHalfWidth(49) == nil)
        #expect(ChristmasTheme.TREE_ROWS == 53)
    }

    @Test func openingAPresentSparklesForAWhile() {
        withSim(now: december) {
            let theme = ChristmasTheme(1920, 1080)
            theme.openPresent(1)
            #expect(theme.presents[1].opened)
            #expect(theme.presents[1].sparkleTimer == 2.2)
            #expect(theme.getPresentPositions().map(\.opened) == [false, true, false, false, false, false])

            theme.update(1000)
            #expect(abs(theme.presents[1].sparkleTimer - 1.2) < 1e-9)
            theme.openPresent(1) // already open: the sparkle isn't restarted
            #expect(abs(theme.presents[1].sparkleTimer - 1.2) < 1e-9)
            theme.update(5000)
            #expect(theme.presents[1].sparkleTimer == 0)

            theme.openPresent(-1)
            theme.openPresent(6)
            #expect(theme.presents.filter(\.opened).count == 1)
        }
    }

    @Test func notesDriftUpAndFadeOut() {
        withSim(now: december, random: SimRandom.seeded(4)) {
            let theme = ChristmasTheme(1920, 1080)
            theme.emitNote(500, 600)
            #expect(theme.notes.count == 1)
            let note = theme.notes[0]
            #expect(note.x == 500 && note.y == 600 && note.life == 0)
            #expect(note.vy <= -22 && note.vy > -36)
            #expect(abs(note.vx) <= 8)
            #expect(["\u{266A}", "\u{266B}"].contains(note.glyph))
            #expect(ChristmasTheme.BULB_COLORS.contains(note.color))

            theme.update(1000)
            #expect(theme.notes[0].y < 600 - 21)
            #expect(abs(theme.notes[0].life - 1) < 1e-9)
            theme.update(1400) // 2.4s: gone
            #expect(theme.notes.isEmpty)
        }
    }

    @Test func notesAreCappedAndNeedTheThemeOn() {
        withSim(now: december, random: SimRandom.seeded(4)) {
            let theme = ChristmasTheme(1920, 1080)
            for _ in 0..<40 { theme.emitNote(10, 10) }
            #expect(theme.notes.count == ChristmasTheme.MAX_NOTES)
            theme.setModeOverride(.off)
            #expect(theme.notes.isEmpty)
            theme.emitNote(10, 10)
            #expect(theme.notes.isEmpty)
        }
    }

    @Test func theLightShowRunsForTwentySeconds() {
        withSim(now: december) {
            let theme = ChristmasTheme(1920, 1080)
            #expect(!theme.lightShowRunning)
            theme.startLightShow()
            #expect(theme.lightShowRunning)
            theme.update(19_999)
            #expect(theme.lightShowRunning)
            theme.update(1)
            #expect(!theme.lightShowRunning)
        }
        withSim(now: july) {
            let theme = ChristmasTheme(1920, 1080)
            theme.startLightShow()
            #expect(!theme.lightShowRunning) // nothing to light up
        }
    }

    // MARK: drawing

    @Test func inactiveThemeDrawsNothing() {
        withSim(now: july) {
            let theme = ChristmasTheme(1920, 1080)
            let c = Canvas()
            drawAll(theme, c)
            #expect(drawnOpCount(c) == 0)
        }
    }

    @Test func theGarlandHangsInSwagsBelowTheMenuBar() {
        #expect(ChristmasTheme.swagCount(1920) == 10)
        #expect(ChristmasTheme.swagCount(1512) == 8)
        #expect(ChristmasTheme.swagCount(60) == 1)

        withSim(now: december) {
            let theme = ChristmasTheme(1920, 1080)
            theme.topInset = 30
            let c = Canvas()
            c.beginFrame()
            theme.drawBackground(c, 1920, 1080)
            let swags = c.groups.filter { $0.key.hasPrefix("christmas:bg:garland:") }
            #expect(swags.count == 10)
            // Each swag is anchored where its wire starts
            #expect(swags[0].anchor == CGPoint(x: 0, y: 33))
            #expect(swags[3].anchor == CGPoint(x: 576, y: 33))
            // 50 bulbs, every third one lit: wire + (glow, socket, bulb, shine) or (socket, bulb)
            #expect(swags[0].ops.count == 1 + 2 * 4 + 3 * 2)
            #expect(drawnOpCount(c) == 10 + 17 * 4 + 33 * 2)
            // Nothing reaches above the menu bar or far below the sag
            let bounds = swags.reduce(CGRect.null) { rect, g in
                rect.union(g.bounds.offsetBy(dx: g.anchor!.x, dy: g.anchor!.y))
            }
            #expect(bounds.minY >= 30 && bounds.maxY <= 30 + 3 + 14 + 7 + 11 + 1)
            #expect(bounds.minX >= -12 && bounds.maxX <= 1932)
        }
    }

    @Test func theGlowWalksAlongTheWire() {
        withSim(now: december) {
            let theme = ChristmasTheme(1920, 1080)
            let c = Canvas()
            @MainActor func swagOps() -> Int {
                c.beginFrame()
                theme.drawBackground(c, 1920, 1080)
                return group(c, "christmas:bg:garland:0")!.ops.count
            }
            #expect(swagOps() == 15) // bulbs 0 and 3 lit
            theme.update(549)
            #expect(swagOps() == 15) // same step: the tile is untouched
            theme.update(1)
            #expect(swagOps() == 1 + 4 + 4 * 2) // step 1: only bulb 2
            theme.startLightShow()
            #expect(swagOps() == 1 + 5 * 4) // everything is lit
        }
    }

    @Test func drawsTheDriftsTheTreeAndThePresents() {
        withSim(now: december) {
            let theme = ChristmasTheme(1920, 1080)
            let c = Canvas()
            c.beginFrame()
            theme.drawMidground(c, 1920, 1080)

            #expect(c.groups.filter { $0.key.hasPrefix("christmas:mid:drift:") }.count == 7)
            let tree = group(c, "christmas:mid:tree")!
            #expect(tree.anchor == CGPoint(x: 1344, y: 997))
            // snow at the foot (2), trunk, four foliage colors, 12 baubles (2 each), star (2)
            #expect(tree.ops.count == 2 + 1 + 4 + 12 * 2 + 2)
            // 53 rows of 3pt pixels standing on the ground, 41 columns wide
            #expect(abs(tree.bounds.minY + 53 * 3) < 0.01)
            #expect(abs(tree.bounds.maxY) < 0.01)
            #expect(group(c, "christmas:mid:star") != nil)
            #expect(c.groups.filter { $0.key.hasPrefix("christmas:mid:treelight:") }.count == 11)

            let presents = c.groups.filter { $0.key.hasPrefix("christmas:mid:present:") }
            #expect(presents.count == 6)
            #expect(presents[0].anchor == CGPoint(x: 1344 - 90, y: 997))
            #expect(presents[0].ops.count == 7) // box, lid, shadow, ribbon, bow (3)

            theme.openPresent(0)
            c.beginFrame()
            theme.drawMidground(c, 1920, 1080)
            #expect(c.groups.filter { $0.key.hasPrefix("christmas:mid:present:") }.count == 5)
            c.beginFrame()
            theme.drawForeground(c, 1920, 1080)
            #expect(group(c, "christmas:fg:sparkle:0")?.ops.count == 6)
        }
    }

    @Test func aStillSceneRedrawsTheSameTiles() {
        withSim(now: december) {
            let theme = ChristmasTheme(1920, 1080)
            let c = Canvas()
            drawAll(theme, c)
            let before = c.groups.map(\.ops)
            theme.update(16)
            drawAll(theme, c)
            // One frame later nothing looks different, so nothing is re-rasterized
            #expect(c.groups.map(\.ops) == before)
        }
    }

    @Test func notesAreDrawnAsFadingGlyphs() {
        withSim(now: december, random: SimRandom.seeded(9)) {
            let theme = ChristmasTheme(1920, 1080)
            theme.emitNote(400, 500)
            theme.update(1200) // half its life
            let c = Canvas()
            c.beginFrame()
            theme.drawForeground(c, 1920, 1080)
            let note = group(c, "christmas:fg:note:0")!
            #expect(note.ops.count == 1)
            #expect(note.ops[0].alpha == 0.5)
            #expect(drawnTexts(c).contains(theme.notes[0].glyph))
        }
    }

    // MARK: HUD

    @Test func theHudShowsTheCalendarForAWhile() {
        withSim(now: december) {
            let theme = ChristmasTheme(1920, 1080)
            var stats = ChristmasStats()
            stats.doorsOpened = [1, 2, 3]
            stats.giftsOpenedTotal = 4
            stats.carolsSungTotal = 2
            stats.sleighsSeenTotal = 1
            theme.applyStats(stats)

            let c = Canvas()
            c.beginFrame()
            theme.drawForeground(c, 1920, 1080)
            #expect(drawnTexts(c) == [
                "JULEKALENDER", "3/24", "11 days to julaften", "Gifts 4  Carols 2", "Sleighs 1", "Seasonal",
            ])
            // box (fill + stroke), six lines of text, 24 doors
            #expect(group(c, "christmas:fg:hud")?.ops.count == 2 + 6 + 24)

            theme.update(17_999)
            #expect(theme.hudVisible)
            theme.update(1)
            #expect(!theme.hudVisible)
            c.beginFrame()
            theme.drawForeground(c, 1920, 1080)
            #expect(drawnTexts(c).isEmpty)

            theme.showHud()
            #expect(theme.hudVisible)
        }
    }

    @Test func theHudSaysWhenTheSeasonIsForced() {
        withSim(now: july) {
            let theme = ChristmasTheme(1920, 1080)
            theme.showHud()
            #expect(!theme.hudVisible) // off: nothing to show
            theme.setModeOverride(.on)
            let c = Canvas()
            c.beginFrame()
            theme.drawForeground(c, 1920, 1080)
            #expect(drawnTexts(c).contains("Out of season"))
            #expect(drawnTexts(c).contains("Forced on"))
        }
    }

    @Test func theHudSitsBelowTheGarland() {
        withSim(now: december) {
            let theme = ChristmasTheme(1920, 1080)
            let c = Canvas()
            c.beginFrame()
            theme.drawForeground(c, 1920, 1080)
            let box = group(c, "christmas:fg:hud")!.ops[0].bounds
            #expect(abs(box.minX - (1920 - 188 - 18)) < 1 && abs(box.minY - 110) < 1)

            theme.topInset = 100 // a very tall menu bar pushes it down
            c.beginFrame()
            theme.drawForeground(c, 1920, 1080)
            #expect(abs(group(c, "christmas:fg:hud")!.ops[0].bounds.minY - 144) < 1)
        }
    }

    @Test func seasonLines() {
        #expect(ChristmasTheme.seasonLine(.advent(day: 1, daysLeft: 23)) == "23 days to julaften")
        #expect(ChristmasTheme.seasonLine(.advent(day: 23, daysLeft: 1)) == "1 day to julaften")
        #expect(ChristmasTheme.seasonLine(.christmasEve) == "Julaften. God jul!")
        #expect(ChristmasTheme.seasonLine(.christmasDay) == "First day of Christmas")
        #expect(ChristmasTheme.seasonLine(.romjul) == "Romjul. Do nothing.")
        #expect(ChristmasTheme.seasonLine(.newYearsEve) == "Nyttårsaften")
        #expect(ChristmasTheme.seasonLine(.newYearsDay) == "Godt nytt år!")
        #expect(ChristmasTheme.seasonLine(.windingDown) == "Tree's still up")
        #expect(ChristmasTheme.seasonLine(.outOfSeason) == "Out of season")
    }

    @Test func colorHelper() {
        #expect(ChristmasTheme.withAlpha("#FF4D4D", 0.5) == "rgba(255, 77, 77, 0.5)")
        #expect(ChristmasTheme.withAlpha("#000000", 0) == "rgba(0, 0, 0, 0.0)")
        #expect(ChristmasTheme.withAlpha("red", 0.5) == "red") // not a #RRGGBB: left alone
    }
}

@Suite("santa hat")
struct SantaHatTests {
    private func hat(_ spriteKey: String, facingRight: Bool = true, bob: Int = 0) -> CGRect {
        let c = Canvas()
        c.beginFrame()
        c.group("hat") { drawSantaHat(c, 100, 200, 96, facingRight, spriteKey: spriteKey, bob: bob) }
        #expect(c.groups[0].ops.count == 4) // cap, drooping tip, fur, fur shadow
        return c.groups[0].bounds
    }

    @Test func sitsOnTheHeadOfTheStandingSprite() {
        // Brim at sprite pixel (21, 8), 3pt pixels: pompom 7px behind it,
        // brim 8px wide, cap 5px above, fur 2px tall.
        let b = hat("idle")
        #expect(b == CGRect(x: 100 + 14 * 3, y: 200 + 3 * 3, width: 15 * 3, height: 7 * 3))
        #expect(hat("walk") == b)
        #expect(hat("no such sprite") == b)
    }

    @Test func followsTheHeadOnEverySpriteSheet() {
        let idle = hat("idle")
        #expect(hat("sit") == idle.offsetBy(dx: 0, dy: 6))
        #expect(hat("sleep") == idle.offsetBy(dx: 0, dy: 18))
        #expect(hat("fall") == idle.offsetBy(dx: 0, dy: -12))
        #expect(hat("parachute") == idle.offsetBy(dx: -6, dy: 12))
    }

    @Test func mirrorsWithTheSheep() {
        let right = hat("idle")
        let left = hat("idle", facingRight: false)
        // Mirrored inside the 96pt frame
        #expect(left.minX == 100 + 96 - (right.maxX - 100))
        #expect(left.width == right.width && left.minY == right.minY)
    }

    @Test func thePompomBobsOnePixel() {
        #expect(hat("walk", bob: 1).maxY == hat("walk").maxY + 3)
        #expect(hat("walk", bob: 1).minY == hat("walk").minY)
    }

    @Test func scalesWithTheSheep() {
        let c = Canvas()
        c.beginFrame()
        c.group("hat") { drawSantaHat(c, 0, 0, 48, true, spriteKey: "idle") }
        #expect(c.groups[0].bounds == CGRect(x: 14 * 1.5, y: 3 * 1.5, width: 15 * 1.5, height: 7 * 1.5))
    }
}

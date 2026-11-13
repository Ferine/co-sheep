import CoreGraphics
import Foundation

// The Christmas event: a garland of lights under the menu bar, a decorated
// tree with presents, snow drifts, carol notes, the julekalender HUD and the
// nisselue every sheep wears. Runs December 1 – January 6, or via the
// settings override.
//
// Tiles follow EasterTheme / SummerTheme: every element is its own small
// anchored group. Nothing here animates continuously: lights step, glows are
// quantized, so a tile is only re-rasterized when it actually looks different.

/// What a julekalender door does besides the line the main sheep reads out.
nonisolated enum DoorEffect: Equatable {
    case quip
    case animation(SheepAnimation)
    case juletregang
    case giftExchange
    case sleigh
    case flurry
    case lightShow
}

nonisolated struct JulekalenderDoor: Equatable {
    var line: String
    var effect: DoorEffect
}

/// Door 1 is index 0. Each line is read out as "Luke <n>: <line>".
nonisolated let JULEKALENDER_DOORS: [JulekalenderDoor] = [
    JulekalenderDoor(line: "a chocolate. Shaped like a sheep. I feel seen. And eaten.", effect: .animation(.bounce)),
    JulekalenderDoor(line: "lights, camera, twinkle.", effect: .lightShow),
    JulekalenderDoor(line: "one snowflake. Oh. Oh no, it brought friends.", effect: .flurry),
    JulekalenderDoor(line: "a voucher for one (1) nap. Redeeming it shortly.", effect: .quip),
    JulekalenderDoor(line: "pepperkake. Slightly burnt. Like my patience.", effect: .animation(.headshake)),
    JulekalenderDoor(line: "sheet music. Everyone to the tree. Now.", effect: .juletregang),
    JulekalenderDoor(line: "a clementine. Peak December technology.", effect: .animation(.bounce)),
    JulekalenderDoor(line: "a tiny present. Which means there are more. To the tree!", effect: .giftExchange),
    JulekalenderDoor(line: "a gløgg recipe. Step one: be an adult. Skipping.", effect: .quip),
    JulekalenderDoor(line: "more lights. The power bill is your problem.", effect: .lightShow),
    JulekalenderDoor(line: "a wool sweater. I have questions about the supply chain.", effect: .animation(.vibrate)),
    JulekalenderDoor(line: "halfway. Statistically the best chocolate is behind us.", effect: .quip),
    JulekalenderDoor(line: "Lucia! Where are my lussekatter?", effect: .lightShow),
    JulekalenderDoor(line: "a snow globe. Somebody shook it.", effect: .flurry),
    JulekalenderDoor(line: "julebrus. The red one. This is not up for debate.", effect: .animation(.spin)),
    JulekalenderDoor(line: "a song stuck in my head. Sharing the pain.", effect: .juletregang),
    JulekalenderDoor(line: "a marzipan pig. Finally, someone else is the snack.", effect: .animation(.bounce)),
    JulekalenderDoor(line: "wrapping paper. No present. Just paper. Bold. Check the tree.", effect: .giftExchange),
    JulekalenderDoor(line: "a candle. LED. The barn has rules.", effect: .quip),
    JulekalenderDoor(line: "risgrøt. The almond is mine. I checked.", effect: .animation(.backflip)),
    JulekalenderDoor(line: "the darkest day. It only gets brighter from here. Allegedly.", effect: .flurry),
    JulekalenderDoor(line: "a last-minute shopping list. It just says 'panic'.", effect: .animation(.zoom)),
    JulekalenderDoor(line: "lille julaften. Same procedure as every year.", effect: .juletregang),
    JulekalenderDoor(line: "God jul! Now look up.", effect: .sleigh),
]

let CHRISTMAS_IDLE_QUIPS = [
    "This hat is non-negotiable, apparently.",
    "I've been good this year. Mostly. Define good.",
    "Is that pine? I smell pine.",
    "Somebody plug in the tree. Oh. It is.",
    "Wool: nature's Christmas sweater.",
    "If one more bulb blinks at me...",
    "Snow again. Free wool wash.",
]

/// Where the nisselue's brim starts (top-left, sprite pixels, facing right)
/// on each sprite sheet: the head sits at a different height when the sheep
/// sits, sleeps, falls or hangs from its parachute.
private let SANTA_HAT_ANCHORS: [String: (x: Double, y: Double)] = [
    "idle": (21, 8),
    "walk": (21, 8),
    "sit": (21, 10),
    "sleep": (21, 14),
    "parachute": (19, 12),
    "fall": (21, 4),
]

/// The nisselue: a floppy red cap with a white brim and a pompom hanging off
/// the back. Pixel art on the sprite's own grid, so it flips and scales with
/// the sheep. `bob` (0 or 1) drops the pompom one pixel, for a walking sheep.
func drawSantaHat(_ ctx: Canvas, _ x: Double, _ y: Double, _ size: Double, _ facingRight: Bool,
                  spriteKey: String, bob: Int = 0) {
    let anchor = SANTA_HAT_ANCHORS[spriteKey] ?? SANTA_HAT_ANCHORS["idle"]!
    let bx = anchor.x
    let by = anchor.y
    let pen = PixelPen(ctx: ctx, ox: x, oy: y, px: size / 32, flip: !facingRight)
    let drop = Double(bob)

    // Cap, leaning back toward the tail
    pen.fill("#D62B2B", [
        (bx + 1, by - 1, 6, 1),
        (bx, by - 2, 6, 1),
        (bx - 1, by - 3, 6, 1),
        (bx - 2, by - 4, 5, 1),
        (bx - 3, by - 5, 4, 1),
    ])
    // The tip droops over the back, in shadow
    pen.fill("#A81E1E", [
        (bx - 4, by - 4, 2, 1),
        (bx - 5, by - 3, 2, 1),
        (bx - 6, by - 2 + drop, 2, 1),
    ])
    // Fur brim and pompom
    pen.fill("#FFFFFF", [
        (bx, by, 8, 1),
        (bx - 7, by - 1 + drop, 3, 2),
    ])
    pen.fill("#DCE3EE", [
        (bx, by + 1, 8, 1),
        (bx - 7, by + 1 + drop, 3, 1),
    ])
}

/// Christmas event: string lights across the top, a tree with twinkling
/// lights and presents under it, snow drifts along the ground, and a
/// julekalender HUD. The group activities (walking around the tree, the gift
/// exchange) steer the sheep; the theme only owns what they act on.
final class ChristmasTheme {
    struct Present: Equatable {
        /// Center x, relative to the tree trunk.
        var dx: Double
        var w: Double
        var h: Double
        var box: String
        var ribbon: String
        var opened: Bool
        /// Seconds of sparkle left after it was opened.
        var sparkleTimer: Double
    }

    struct Note: Equatable {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var life: Double
        var glyph: String
        var color: String
    }

    static let BULB_COLORS = ["#FF4D4D", "#FFD23F", "#3DDC84", "#4DA3FF", "#FFF1C1"]

    // Garland
    static let SWAG_WIDTH: Double = 190
    static let BULBS_PER_SWAG = 5
    static let SWAG_SAG: Double = 14
    static let CHASE_STEP_MS: Double = 550
    static let LIGHT_SHOW_STEP_MS: Double = 110
    static let LIGHT_SHOW_MS: Double = 20000

    // Tree (grid of 3pt pixels; `b` counts rows up from the ground)
    static let TREE_PX: Double = 3
    static let TREE_ROWS = 53
    static let TREE_HALF_COLS = 20
    /// (first row, row count, half-width of the first row); each tier's skirt
    /// overhangs the top of the one below.
    private static let TIERS: [(bottom: Int, rows: Int, halfWidth: Int)] = [
        (4, 11, 20), (13, 11, 17), (22, 11, 14), (31, 11, 11), (40, 9, 8),
    ]
    /// (column offset from the trunk, row, color index)
    private static let BAUBLES: [(gx: Int, b: Int, color: Int)] = [
        (-12, 6, 0), (-3, 8, 1), (9, 7, 3), (15, 6, 4), (-9, 15, 1), (2, 16, 0),
        (11, 15, 3), (-6, 24, 3), (5, 25, 0), (-3, 33, 1), (4, 34, 0), (0, 42, 3),
    ]
    private static let TREE_LIGHTS: [(gx: Int, b: Int)] = [
        (-16, 5), (-9, 10), (0, 11), (8, 11), (-7, 19), (5, 20),
        (-5, 28), (3, 29), (-2, 37), (2, 38), (0, 45),
    ]
    static let TREE_LIGHT_STEP_MS: Double = 600

    // Snow drifts: fraction of the screen width (clear of the tree at 0.7)
    private static let DRIFT_SPOTS: [Double] = [0.04, 0.17, 0.31, 0.44, 0.57, 0.86, 0.96]

    // Presents: offset from the trunk, size, box and ribbon colors
    private static let PRESENT_DEFS: [(dx: Double, w: Double, h: Double, box: String, ribbon: String)] = [
        (-90, 18, 15, "#D62B2B", "#FFD54A"),
        (-66, 15, 18, "#2E8B57", "#F4F8FF"),
        (-42, 20, 13, "#3A6EA5", "#FFD54A"),
        (44, 16, 16, "#FFD54A", "#D62B2B"),
        (68, 19, 14, "#8E44AD", "#F4F8FF"),
        (92, 14, 17, "#F4F8FF", "#D62B2B"),
    ]

    static let ACTIVE_REFRESH_INTERVAL_MS: Double = 60000
    static let HUD_DISPLAY_TIME_MS: Double = 18000
    static let MAX_NOTES = 24
    static let NOTE_LIFE: Double = 2.4

    private(set) var presents: [Present] = []
    private(set) var notes: [Note] = []
    private(set) var active = false
    private var modeOverride: ChristmasMode = .auto
    private var stats = ChristmasStats()
    private var moment: ChristmasSeason.Moment = .outOfSeason
    private var dueDoor: Int?
    private var screenWidth: Double
    private var screenHeight: Double
    /// Height of the menu bar: the garland hangs just below it.
    var topInset: Double = 28
    /// Milliseconds since the theme was last switched on.
    private var time: Double = 0
    private var activeRefreshTimer: Double = 0
    private var hudTimer: Double = 0
    private var lightShowTimer: Double = 0

    init(_ screenWidth: Double, _ screenHeight: Double) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        refreshActiveState()
    }

    // MARK: State

    func setModeOverride(_ mode: ChristmasMode = .auto) {
        modeOverride = mode
        refreshActiveState()
    }

    func getModeOverride() -> ChristmasMode { modeOverride }

    func updateScreenSize(_ w: Double, _ h: Double) {
        screenWidth = w
        screenHeight = h
    }

    /// The julekalender and the tallies the HUD shows.
    func applyStats(_ stats: ChristmasStats) {
        self.stats = stats
    }

    /// Bring the julekalender HUD up for a while (a door opened, a carol ended).
    func showHud() {
        if active { hudTimer = Self.HUD_DISPLAY_TIME_MS }
    }

    var hudVisible: Bool { active && hudTimer > 0 }

    /// Run the garland and the tree as a fast rainbow chase for a while.
    func startLightShow(_ ms: Double = ChristmasTheme.LIGHT_SHOW_MS) {
        if active { lightShowTimer = max(lightShowTimer, ms) }
    }

    var lightShowRunning: Bool { lightShowTimer > 0 }

    /// Only an actual on/off flip (re)wraps the presents: every settings save
    /// re-applies the mode, and a running gift exchange indexes into them.
    private func refreshActiveState() {
        let wasActive = active
        active = ChristmasSeason.isActive(mode: modeOverride)
        moment = ChristmasSeason.moment()
        dueDoor = ChristmasSeason.dueDoor()

        if active && !wasActive {
            time = 0
            lightShowTimer = 0
            wrapPresents()
            hudTimer = Self.HUD_DISPLAY_TIME_MS
            Log.info("christmas", "Christmas event activated")
        } else if !active && wasActive {
            presents = []
            notes = []
            hudTimer = 0
            lightShowTimer = 0
            Log.info("christmas", "Christmas event deactivated")
        }
    }

    func update(_ dt: Double) {
        // The calendar can flip mid-session (midnight on December 1, January 7)
        activeRefreshTimer += dt
        if activeRefreshTimer >= Self.ACTIVE_REFRESH_INTERVAL_MS {
            activeRefreshTimer = activeRefreshTimer.truncatingRemainder(dividingBy: Self.ACTIVE_REFRESH_INTERVAL_MS)
            refreshActiveState()
        }

        if !active { return }
        time += dt
        hudTimer = max(0, hudTimer - dt)
        lightShowTimer = max(0, lightShowTimer - dt)

        let dtSec = dt / 1000
        for i in presents.indices where presents[i].sparkleTimer > 0 {
            presents[i].sparkleTimer = max(0, presents[i].sparkleTimer - dtSec)
        }
        updateNotes(dtSec)
    }

    // MARK: Geometry

    /// The trunk's x: where the flock gathers for the tree activities.
    var treeX: Double { (screenWidth * 0.7).rounded() }

    /// The line the decorations stand on: the sheep's feet.
    var groundY: Double { screenHeight - Sheep.DOCK_MARGIN - 3 }

    /// Half-width (in tree pixels) of the foliage at row `b`, nil above and below it.
    static func treeHalfWidth(_ b: Int) -> Int? {
        var best: Int?
        for tier in TIERS where b >= tier.bottom && b < tier.bottom + tier.rows {
            let hw = tier.halfWidth - (b - tier.bottom)
            if hw >= 0 { best = max(best ?? 0, hw) }
        }
        return best
    }

    // MARK: Presents

    private func wrapPresents() {
        presents = Self.PRESENT_DEFS.map {
            Present(dx: $0.dx, w: $0.w, h: $0.h, box: $0.box, ribbon: $0.ribbon, opened: false, sparkleTimer: 0)
        }
    }

    /// Wrap every present again (a new gift exchange, or the last one ended).
    func resetPresents() {
        if active { wrapPresents() }
    }

    /// Canvas x of each present's center, and whether it was opened.
    func getPresentPositions() -> [(x: Double, opened: Bool)] {
        presents.map { (treeX + $0.dx, $0.opened) }
    }

    func openPresent(_ index: Int) {
        guard presents.indices.contains(index), !presents[index].opened else { return }
        presents[index].opened = true
        presents[index].sparkleTimer = 2.2
    }

    // MARK: Carol notes

    /// A note drifts up from (x, y): the flock is singing.
    func emitNote(_ x: Double, _ y: Double) {
        guard active, notes.count < Self.MAX_NOTES else { return }
        let vx = (SimRandom.next() - 0.5) * 16
        let vy = -(22 + SimRandom.next() * 14)
        let glyph = SimRandom.next() < 0.5 ? "\u{266A}" : "\u{266B}"
        let color = Self.BULB_COLORS[SimRandom.int(Self.BULB_COLORS.count)]
        notes.append(Note(x: x, y: y, vx: vx, vy: vy, life: 0, glyph: glyph, color: color))
    }

    private func updateNotes(_ dtSec: Double) {
        if notes.isEmpty { return }
        for i in notes.indices {
            notes[i].life += dtSec
            notes[i].x += (notes[i].vx + sin(notes[i].life * 4) * 10) * dtSec
            notes[i].y += notes[i].vy * dtSec
        }
        notes.removeAll { $0.life >= Self.NOTE_LIFE }
    }

    // MARK: Draw

    /// Garland — behind everything, so a parachuting sheep passes in front
    func drawBackground(_ ctx: Canvas, _ w: Double, _ h: Double) {
        if !active { return }
        drawGarland(ctx, w)
    }

    /// Snow drifts, the tree and its presents — behind the flock
    func drawMidground(_ ctx: Canvas, _ w: Double, _ h: Double) {
        if !active { return }
        drawDrifts(ctx, w)
        drawTree(ctx)
        drawPresents(ctx)
    }

    /// Sparkles, carol notes and the julekalender — on top of the flock
    func drawForeground(_ ctx: Canvas, _ w: Double, _ h: Double) {
        if !active { return }
        drawSparkles(ctx)
        drawNotes(ctx)
        ctx.group("christmas:fg:hud") { drawHud(ctx, w) }
    }

    // MARK: Garland

    static func swagCount(_ w: Double) -> Int {
        max(1, Int((w / SWAG_WIDTH).rounded()))
    }

    /// Which chase step a swag is on. Swags are staggered by 40ms so they
    /// don't all re-rasterize in the same frame.
    private func chaseStep(_ swag: Int) -> Int {
        let stepMs = lightShowRunning ? Self.LIGHT_SHOW_STEP_MS : Self.CHASE_STEP_MS
        return Int(((time + Double(swag) * 40) / stepMs).rounded(.down))
    }

    private func drawGarland(_ ctx: Canvas, _ w: Double) {
        let count = Self.swagCount(w)
        let span = w / Double(count)
        let top = topInset + 3
        let show = lightShowRunning

        ctx.save()
        // Round joins: a mitered stroke reserves ten line widths of tile around the wire
        ctx.lineJoin = "round"
        for swag in 0..<count {
            let x0 = Double(swag) * span
            let x1 = x0 + span
            let step = chaseStep(swag)
            ctx.group("christmas:bg:garland:\(swag)", anchor: CGPoint(x: x0, y: top)) {
                // Wire
                ctx.strokeStyle = "rgba(31, 92, 58, 0.9)"
                ctx.lineWidth = 1.5
                ctx.beginPath()
                ctx.moveTo(x0, top)
                ctx.quadraticCurveTo((x0 + x1) / 2, top + Self.SWAG_SAG * 2, x1, top)
                ctx.stroke()

                for j in 0..<Self.BULBS_PER_SWAG {
                    let t = (Double(j) + 0.5) / Double(Self.BULBS_PER_SWAG)
                    let bx = x0 + span * t
                    let wireY = top + 4 * Self.SWAG_SAG * t * (1 - t)
                    let g = swag * Self.BULBS_PER_SWAG + j
                    // Normal: every third bulb glows, the glow walks along
                    // the wire. Light show: everything is lit and the colors run.
                    let lit = show || (g + step) % 3 == 0
                    let colors = Self.BULB_COLORS
                    let color = colors[(show ? g + step : g) % colors.count]
                    drawBulb(ctx, bx, wireY, color, lit)
                }
            }
        }
        ctx.restore()
    }

    private func drawBulb(_ ctx: Canvas, _ x: Double, _ wireY: Double, _ color: String, _ lit: Bool) {
        let cy = wireY + 7
        if lit {
            let glow = ctx.createRadialGradient(x, cy, 1, x, cy, 11)
            glow.addColorStop(0, Self.withAlpha(color, 0.5))
            glow.addColorStop(1, Self.withAlpha(color, 0))
            ctx.fillStyle = glow
            ctx.fillRect(x - 11, cy - 11, 22, 22)
        }
        // Socket
        ctx.fillStyle = "#1F5C3A"
        ctx.fillRect(x - 1.5, wireY - 0.5, 3, 3)
        // Bulb
        ctx.globalAlpha = lit ? 1 : 0.5
        ctx.fillStyle = color
        ctx.beginPath()
        ctx.ellipse(x, cy, 3.5, 5, 0, 0, Double.pi * 2)
        ctx.fill()
        if lit {
            ctx.fillStyle = "rgba(255, 255, 255, 0.7)"
            ctx.beginPath()
            ctx.ellipse(x - 1, cy - 1.5, 1, 1.5, 0, 0, Double.pi * 2)
            ctx.fill()
        }
        ctx.globalAlpha = 1
    }

    /// "#RRGGBB" → "rgba(r, g, b, a)".
    static func withAlpha(_ hex: String, _ alpha: Double) -> String {
        guard hex.count == 7, hex.hasPrefix("#"), let v = Int(hex.dropFirst(), radix: 16) else { return hex }
        return "rgba(\((v >> 16) & 0xFF), \((v >> 8) & 0xFF), \(v & 0xFF), \(alpha))"
    }

    // MARK: Snow drifts

    private func drawDrifts(_ ctx: Canvas, _ w: Double) {
        let base = groundY
        ctx.save()
        for (index, spot) in Self.DRIFT_SPOTS.enumerated() {
            let i = Double(index)
            let cx = spot * w
            let halfW = 70 + sin(i * 2.3) * 22
            let height = 9 + sin(i * 4.1) * 2
            ctx.group("christmas:mid:drift:\(index)", anchor: CGPoint(x: cx, y: base)) {
                drawMound(ctx, cx, base, halfW, height)
            }
        }
        ctx.restore()
    }

    /// A flattened heap of snow resting on `base`, with a blue-grey underside.
    private func drawMound(_ ctx: Canvas, _ cx: Double, _ base: Double, _ halfW: Double, _ height: Double) {
        ctx.fillStyle = "rgba(176, 198, 226, 0.9)"
        ctx.beginPath()
        ctx.ellipse(cx, base, halfW, height, 0, Double.pi, Double.pi * 2)
        ctx.fill()
        ctx.fillStyle = "rgba(255, 255, 255, 0.96)"
        ctx.beginPath()
        ctx.ellipse(cx - 2, base - 2, halfW - 3, height - 2, 0, Double.pi, Double.pi * 2)
        ctx.fill()
    }

    // MARK: Tree

    private func drawTree(_ ctx: Canvas) {
        let px = Self.TREE_PX
        let base = groundY
        let cx = treeX
        let rows = Self.TREE_ROWS
        let cols = Self.TREE_HALF_COLS * 2 + 1
        // Grid origin: top-left of the tree's box, so the trunk's middle
        // column is centered on `cx` and row b = 0 rests on the ground.
        let ox = cx - Double(cols) * px / 2
        let oy = base - Double(rows) * px
        let pen = PixelPen(ctx: ctx, ox: ox, oy: oy, px: px, flip: false)
        let mid = Double(Self.TREE_HALF_COLS)
        func row(_ b: Int) -> Double { Double(rows - 1 - b) }

        ctx.save()
        ctx.group("christmas:mid:tree", anchor: CGPoint(x: cx, y: base)) {
            // Snow piled around the foot
            drawMound(ctx, cx, base, 84, 9)

            pen.fill("#6B4423", [(mid - 1, row(3), 3, 4)])

            var green: [PixelPen.Rect] = []
            var dark: [PixelPen.Rect] = []
            var light: [PixelPen.Rect] = []
            var snow: [PixelPen.Rect] = []
            for b in 4..<(rows - 4) {
                guard let hw = Self.treeHalfWidth(b) else { continue }
                let h = Double(hw)
                let y = row(b)
                green.append((mid - h, y, h * 2 + 1, 1))
                let isSkirt = Self.TIERS.contains { $0.bottom == b }
                if isSkirt {
                    // The underside of each tier is in shadow
                    dark.append((mid - h, y, h * 2 + 1, 1))
                    continue
                }
                // Shade the right third, catch the light on the left
                let shade = (h * 0.4).rounded(.down)
                if h >= 2 { dark.append((mid + h - shade, y, shade + 1, 1)) }
                if h >= 4 { light.append((mid - h + 2, y, 2, 1)) }
                // Snow lies along the upper slope of every tier
                let top = Self.treeHalfWidth(b + 1) ?? -1
                let onLedge = top >= hw // the tier above overhangs: no sky above this row
                if !onLedge {
                    snow.append((mid - h, y, min(2, h * 2 + 1), 1))
                    if h >= 3 { snow.append((mid + h, y, 1, 1)) }
                }
            }
            pen.fill("#2E7D4F", green)
            pen.fill("#1F5C3A", dark)
            pen.fill("#44A36A", light)
            pen.fill("#F4F8FF", snow)

            // Baubles: a 2x2 ball with a highlight pixel
            let colors = Self.BULB_COLORS
            for bauble in Self.BAUBLES {
                let gx = mid + Double(bauble.gx)
                let gy = row(bauble.b)
                pen.block(colors[bauble.color], gx, gy - 1, 2, 2)
                pen.block("rgba(255, 255, 255, 0.75)", gx, gy - 1, 1, 1)
            }

            // Star
            pen.fill("#FFD54A", [
                (mid, row(rows - 1), 1, 1),
                (mid - 1, row(rows - 2), 3, 1),
                (mid - 2, row(rows - 3), 5, 1),
                (mid - 1, row(rows - 4), 3, 1),
                (mid, row(rows - 5), 1, 1),
            ])
            pen.block("#FFF3B0", mid, row(rows - 3), 1, 1)
        }

        drawStarGlow(ctx, cx, oy + 2.5 * px)
        drawTreeLights(ctx, pen, mid, row)
        ctx.restore()
    }

    /// Soft halo around the star, breathing in 16 steps over two seconds.
    private func drawStarGlow(_ ctx: Canvas, _ x: Double, _ y: Double) {
        let phase = Double(Int(time / 125) % 16) / 16
        let alpha = lightShowRunning ? 0.6 : 0.28 + sin(phase * Double.pi * 2) * 0.12
        ctx.group("christmas:mid:star", anchor: CGPoint(x: x, y: y)) {
            let glow = ctx.createRadialGradient(x, y, 2, x, y, 22)
            glow.addColorStop(0, "rgba(255, 224, 120, \(alpha))")
            glow.addColorStop(1, "rgba(255, 224, 120, 0)")
            ctx.fillStyle = glow
            ctx.fillRect(x - 22, y - 22, 44, 44)
        }
    }

    private func drawTreeLights(_ ctx: Canvas, _ pen: PixelPen, _ mid: Double, _ row: (Int) -> Double) {
        let show = lightShowRunning
        let stepMs = show ? Self.LIGHT_SHOW_STEP_MS : Self.TREE_LIGHT_STEP_MS
        let step = Int((time / stepMs).rounded(.down))
        let colors = Self.BULB_COLORS
        let px = Self.TREE_PX
        for (index, light) in Self.TREE_LIGHTS.enumerated() {
            let gx = mid + Double(light.gx)
            let gy = row(light.b)
            let x = pen.ox + gx * px
            let y = pen.oy + gy * px
            let lit = (step + index * 2) % 3 != 0
            let color = colors[(show ? index + step : index) % colors.count]
            ctx.group("christmas:mid:treelight:\(index)", anchor: CGPoint(x: x, y: y)) {
                if lit {
                    ctx.fillStyle = Self.withAlpha(color, 0.3)
                    ctx.fillRect(x - px, y - px, px * 3, px * 3)
                    pen.block(color, gx, gy)
                } else {
                    pen.block(Self.withAlpha(color, 0.35), gx, gy)
                }
            }
        }
    }

    // MARK: Presents

    private func drawPresents(_ ctx: Canvas) {
        let base = groundY
        ctx.save()
        for (index, p) in presents.enumerated() where !p.opened {
            let cx = treeX + p.dx
            ctx.group("christmas:mid:present:\(index)", anchor: CGPoint(x: cx, y: base)) {
                Self.drawPresent(ctx, cx, base, p.w, p.h, p.box, p.ribbon)
            }
        }
        ctx.restore()
    }

    /// A wrapped box standing on `base`, centered on `cx`: lid, ribbon, bow.
    static func drawPresent(_ ctx: Canvas, _ cx: Double, _ base: Double, _ w: Double, _ h: Double,
                            _ box: String, _ ribbon: String) {
        let left = cx - w / 2
        let top = base - h
        ctx.fillStyle = box
        ctx.fillRect(left, top, w, h)
        // Lid: a touch wider, with a shadow line under it
        ctx.fillRect(left - 1, top, w + 2, 4)
        ctx.fillStyle = "rgba(0, 0, 0, 0.18)"
        ctx.fillRect(left, top + 4, w, 1)
        // Ribbon and bow
        ctx.fillStyle = ribbon
        ctx.fillRect(cx - 1.5, top, 3, h)
        ctx.fillRect(cx - 5, top - 3, 4, 3)
        ctx.fillRect(cx + 1, top - 3, 4, 3)
        ctx.fillRect(cx - 1, top - 2, 2, 2)
    }

    private func drawSparkles(_ ctx: Canvas) {
        let base = groundY
        for (index, p) in presents.enumerated() where p.opened && p.sparkleTimer > 0 {
            let cx = treeX + p.dx
            let cy = base - p.h / 2
            ctx.group("christmas:fg:sparkle:\(index)", anchor: CGPoint(x: cx, y: cy)) {
                Self.drawSparkle(ctx, cx, cy, p.sparkleTimer, time / 1000)
            }
        }
    }

    /// A ring of gold dots that spreads and fades as `timer` (seconds) runs out.
    static func drawSparkle(_ ctx: Canvas, _ x: Double, _ y: Double, _ timer: Double, _ spin: Double) {
        let spread = 15 * (3 - timer * 0.8)
        ctx.save()
        ctx.globalAlpha = min(1, timer)
        ctx.fillStyle = "#FFD54A"
        for n in 0..<6 {
            let angle = (Double(n) / 6) * Double.pi * 2 + spin * 3
            ctx.beginPath()
            ctx.arc(x + cos(angle) * spread * 0.35, y + sin(angle) * spread * 0.25, 2, 0, Double.pi * 2)
            ctx.fill()
        }
        ctx.restore()
    }

    // MARK: Notes

    private func drawNotes(_ ctx: Canvas) {
        if notes.isEmpty { return }
        ctx.save()
        ctx.font = "15px serif"
        for (index, note) in notes.enumerated() {
            // Fade in tenths, so a drifting note is a node move, not a re-raster
            let fade = 1 - note.life / Self.NOTE_LIFE
            let alpha = max(0.1, (fade * 10).rounded(.up) / 10)
            ctx.group("christmas:fg:note:\(index)", anchor: CGPoint(x: note.x, y: note.y)) {
                ctx.globalAlpha = alpha
                ctx.fillStyle = note.color
                ctx.fillText(note.glyph, note.x, note.y)
            }
        }
        ctx.restore()
    }

    // MARK: HUD

    /// The line under the door count: how far along the season is.
    static func seasonLine(_ moment: ChristmasSeason.Moment) -> String {
        switch moment {
        case .advent(_, let daysLeft): daysLeft == 1 ? "1 day to julaften" : "\(daysLeft) days to julaften"
        case .christmasEve: "Julaften. God jul!"
        case .christmasDay: "First day of Christmas"
        case .romjul: "Romjul. Do nothing."
        case .newYearsEve: "Nyttårsaften"
        case .newYearsDay: "Godt nytt år!"
        case .windingDown: "Tree's still up"
        case .outOfSeason: "Out of season"
        }
    }

    private func drawHud(_ ctx: Canvas, _ w: Double) {
        if hudTimer <= 0 { return }

        let opened = stats.doorsOpened
        let boxW: Double = 188
        let boxH: Double = 100
        let x = w - boxW - 18
        // Below the garland, and clear of the Easter ledger's corner
        let y = max(topInset + 44, 110)

        ctx.save()
        ctx.fillStyle = "rgba(26, 26, 46, 0.72)"
        ctx.strokeStyle = "rgba(255, 120, 120, 0.4)"
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.roundRect(x, y, boxW, boxH, 12)
        ctx.fill()
        ctx.stroke()

        ctx.fillStyle = "#FFF5CE"
        ctx.font = "bold 11px monospace"
        ctx.fillText("JULEKALENDER", x + 14, y + 18)

        ctx.fillStyle = "#A6BEDA"
        ctx.font = "10px monospace"
        ctx.textAlign = "right"
        ctx.fillText("\(opened.count)/\(ChristmasSeason.doorCount)", x + boxW - 14, y + 18)
        ctx.textAlign = "start"

        // 24 doors in two rows: opened, due but still shut, not yet
        let due = dueDoor ?? 0
        for door in 1...ChristmasSeason.doorCount {
            let col = Double((door - 1) % 12)
            let rowY = y + 26 + Double((door - 1) / 12) * 12
            ctx.fillStyle = opened.contains(door)
                ? "#FFD54A"
                : door <= due ? "#D62B2B" : "rgba(255, 255, 255, 0.16)"
            ctx.fillRect(x + 14 + col * 13.5, rowY, 10, 8)
        }

        ctx.fillStyle = "#F7DA7D"
        ctx.fillText(Self.seasonLine(moment), x + 14, y + 64)
        ctx.fillText("Gifts \(stats.giftsOpenedTotal)  Carols \(stats.carolsSungTotal)", x + 14, y + 78)
        ctx.fillText("Sleighs \(stats.sleighsSeenTotal)", x + 14, y + 92)

        ctx.fillStyle = "#A6BEDA"
        ctx.textAlign = "right"
        ctx.fillText(modeOverride == .auto ? "Seasonal" : "Forced \(modeOverride.rawValue)", x + boxW - 14, y + 92)
        ctx.textAlign = "start"
        ctx.restore()
    }
}

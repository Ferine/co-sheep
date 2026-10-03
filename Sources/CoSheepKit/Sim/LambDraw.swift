import Foundation

// Everything a lamb paints on top of its sprite, in the sprite's own pixel
// grid: wool puffs, the shorn patch, the tool prop, status marks, lamblets,
// shearing particles and the hover card. Props are authored facing right
// (head on the right, like the 32x32 sheets) and mirrored by `PixelPen`.
//
// Animation time is quantized to 8 fps (`AgentLamb.animStep`), so between
// steps the display list is identical and the tile cache skips the raster.

// MARK: - Colours

/// A lamb's palette: the sprite's wool greys tinted the way `Sheep.tint`
/// tints the sprite (35% of hsl(hue, 70%, 62%)), so puffs match the body.
nonisolated struct LambColors: Equatable {
    let hue: Double
    /// Solid repo colour: bubble border, card accent.
    let solid: String
    let wool: String
    let woolShade: String
    let woolOutline: String
    /// The sprite's dark head/legs under the same wash.
    let dark: String
    let yarn: String
    let yarnDark: String

    init(hue: Double, solid: String) {
        self.hue = hue
        self.solid = solid
        wool = Self.tinted(240, hue)
        woolShade = Self.tinted(208, hue)
        woolOutline = Self.tinted(150, hue)
        dark = Self.tinted(51, hue)
        yarn = "hsl(\(Int(hue)), 70%, 58%)"
        yarnDark = "hsl(\(Int(hue)), 62%, 38%)"
    }

    /// `base` grey (0...255) under a 35% hsl(hue, 70%, 62%) wash, as hex.
    static func tinted(_ base: Double, _ hue: Double) -> String {
        let (tr, tg, tb) = CSSColor.hslToRGB(h: hue, s: 0.7, l: 0.62)
        func channel(_ t: Double) -> Int {
            Int(((base / 255) * 0.65 + t * 0.35) * 255 + 0.5)
        }
        return String(format: "#%02x%02x%02x", channel(tr), channel(tg), channel(tb))
    }
}

// MARK: - Pixel pen

/// Draws on the sprite's 32x32 art-pixel grid, mirrored when the lamb faces
/// left. Edges snap to half points (device pixels on Retina), so adjacent art
/// pixels never show a seam and the blocks line up with the sprite's own.
struct PixelPen {
    typealias Rect = (x: Double, y: Double, w: Double, h: Double)

    let ctx: Canvas
    let ox: Double
    let oy: Double
    /// One art pixel in points: `Sheep.SCALE * lamb scale`.
    let px: Double
    let flip: Bool

    private func edge(_ g: Double) -> Double { (g * px * 2).rounded() / 2 }

    /// Add one grid rect to the current path (mirrored, snapped).
    func add(_ gx: Double, _ gy: Double, _ w: Double, _ h: Double) {
        let gm = flip ? 32 - gx - w : gx
        let x0 = ox + edge(gm)
        let x1 = ox + edge(gm + w)
        let y0 = oy + edge(gy)
        let y1 = oy + edge(gy + h)
        ctx.rect(x0, y0, x1 - x0, y1 - y0)
    }

    /// Fill all `rects` with one colour in a single op.
    func fill(_ color: String, _ rects: [Rect]) {
        guard !rects.isEmpty else { return }
        ctx.fillStyle = color
        ctx.beginPath()
        for r in rects { add(r.x, r.y, r.w, r.h) }
        ctx.fill()
    }

    func block(_ color: String, _ gx: Double, _ gy: Double, _ w: Double = 1, _ h: Double = 1) {
        fill(color, [(gx, gy, w, h)])
    }

    /// ASCII pixel art: each character maps to a colour (`.` and space are
    /// clear). Horizontal runs merge; one fill op per colour.
    func sprite(_ rows: [String], _ gx: Double, _ gy: Double, _ palette: [Character: String]) {
        var order: [Character] = []
        var rects: [Character: [Rect]] = [:]
        for (j, row) in rows.enumerated() {
            let cells = Array(row)
            var i = 0
            while i < cells.count {
                let c = cells[i]
                var run = 1
                while i + run < cells.count, cells[i + run] == c { run += 1 }
                if c != ".", c != " ", palette[c] != nil {
                    if rects[c] == nil { order.append(c) }
                    rects[c, default: []].append((gx + Double(i), gy + Double(j), Double(run), 1))
                }
                i += run
            }
        }
        for c in order { fill(palette[c]!, rects[c] ?? []) }
    }

    /// A one-colour glyph (`#` = pixel) with a 1px outline and/or drop
    /// shadow. Glyphs are letters and symbols: only their anchor mirrors, the
    /// shape never does.
    func glyph(_ rows: [String], _ gx: Double, _ gy: Double, fill color: String, outline: String? = nil,
               shadow: String? = nil) {
        let w = rows.map(\.count).max() ?? 0
        if flip {
            PixelPen(ctx: ctx, ox: ox, oy: oy, px: px, flip: false)
                .glyph(rows, 32 - gx - Double(w), gy, fill: color, outline: outline, shadow: shadow)
            return
        }
        var on = Set<Int>()
        var body: [Rect] = []
        for (j, row) in rows.enumerated() {
            for (i, c) in row.enumerated() where c == "#" {
                on.insert(j * 1000 + i)
                body.append((gx + Double(i), gy + Double(j), 1, 1))
            }
        }
        if let outline {
            var ring: [Rect] = []
            for j in -1...(rows.count) {
                for i in -1...w where !on.contains(j * 1000 + i) {
                    let touches = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { on.contains((j + $0.1) * 1000 + i + $0.0) }
                    if touches { ring.append((gx + Double(i), gy + Double(j), 1, 1)) }
                }
            }
            fill(outline, ring)
        }
        if let shadow { fill(shadow, body.map { ($0.x + 1, $0.y + 1, $0.w, $0.h) }) }
        fill(color, body)
    }

    /// Pixel line (Bresenham) of `thick`x`thick` blocks.
    func line(_ color: String, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, thick: Double = 1) {
        fill(color, Self.linePoints(x0, y0, x1, y1).map { (Double($0.0), Double($0.1), thick, thick) })
    }

    static func linePoints(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> [(Int, Int)] {
        var pts: [(Int, Int)] = []
        var x = x0, y = y0
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            pts.append((x, y))
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
        return pts
    }

    /// Filled pixel disc (see `LambDraw.discSpans`).
    func disc(_ color: String, _ cx: Int, _ cy: Int, _ radius: Double) {
        fill(color, LambDraw.discSpans(radius).map { (Double(cx - $0.half), Double(cy + $0.dy), Double($0.half * 2 + 1), 1) })
    }

    /// Text at a grid point. Text is never mirrored; only its anchor is.
    func text(_ s: String, _ gx: Double, _ gy: Double, font: String, color: String, shadow: String? = nil) {
        let gm = flip ? 32 - gx : gx
        let x = ox + edge(gm)
        let y = oy + edge(gy)
        ctx.font = font
        ctx.textAlign = "center"
        ctx.textBaseline = "alphabetic"
        if let shadow {
            ctx.fillStyle = shadow
            ctx.fillText(s, x + 1, y + 1)
        }
        ctx.fillStyle = color
        ctx.fillText(s, x, y)
    }
}

// MARK: - Layout

nonisolated struct Puff: Equatable {
    var index: Int
    var cx: Int
    var cy: Int
    var radius: Double
}

nonisolated enum LambDraw {
    /// Wool slots on the back and top of the body (sprite px, facing right),
    /// innermost first. The head sits at x 20...29, so nothing reaches it.
    static let puffSlots: [(cx: Int, cy: Int, r: Double)] = [
        (7, 11, 3), (13, 9, 3), (4, 16, 3), (16, 8, 2.5),
        (5, 21, 2.5), (10, 6, 3), (2, 12, 2.5), (15, 5, 3),
        (6, 24, 2.5), (0, 17, 2.5), (11, 2, 3), (4, 7, 3),
        (18, 3, 2.5), (14, 12, 3), (8, 15, 3), (-1, 11, 2.5),
    ]

    /// The puffs for a wool `amount` (0...4): four per level, each one
    /// swelling in as the amount crosses its threshold, all growing with
    /// the level.
    static func puffLayout(amount: Double) -> [Puff] {
        let count = amount * 4
        var out: [Puff] = []
        for (i, slot) in puffSlots.enumerated() {
            let growth = min(1, count - Double(i))
            if growth <= 0 { break }
            let scale = (0.55 + 0.45 * growth) * (0.85 + 0.13 * amount)
            let r = max(1, ((slot.r * scale) * 2).rounded() / 2)
            out.append(Puff(index: i, cx: slot.cx, cy: slot.cy, radius: r))
        }
        return out
    }

    /// Row spans of a pixel disc: row offset and half-width (width = 2*half+1).
    static func discSpans(_ radius: Double) -> [(dy: Int, half: Int)] {
        let lim = radius * radius + 0.5 * radius
        var spans: [(Int, Int)] = []
        let reach = Int(radius.rounded(.up))
        for j in -reach...reach {
            let rem = lim - Double(j * j)
            if rem < 0 { continue }
            spans.append((j, Int(rem.squareRoot().rounded(.down))))
        }
        return spans
    }

    /// Pixel ellipse rows (half-width per row offset).
    static func ellipseSpans(rx: Double, ry: Double) -> [(dy: Int, half: Int)] {
        var spans: [(Int, Int)] = []
        let reach = Int(ry.rounded(.up))
        for j in -reach...reach {
            let k = 1 - pow(Double(j) / (ry + 0.5), 2)
            if k <= 0 { continue }
            spans.append((j, Int((rx * k.squareRoot()).rounded(.down))))
        }
        return spans
    }

    // MARK: Palette shared by the props

    static let palette: [Character: String] = [
        "k": "#2b2b3b", "K": "#4a4a5e", "g": "#9a9ab0", "G": "#c8c8d8", "w": "#f8f8f8",
        "b": "#b07a44", "B": "#6b4423", "m": "#d3dbe4", "M": "#7d8a99",
        "o": "#ffd24a", "O": "#c9921a", "r": "#e94560", "R": "#a82a40",
        "n": "#4ecca3", "N": "#2a8f6e", "u": "#4a90d9", "p": "#f6ecd0", "P": "#d8c8a0",
        "d": "#8a5a32", "D": "#4f321b", "l": "#bfe6ff", "s": "#d9c9a0",
    ]

    static let questionGlyph = [
        ".###.",
        "#...#",
        "....#",
        "..##.",
        "..#..",
        ".....",
        "..#..",
    ]
    /// The waiting "?": chunkier, 2px strokes.
    static let waitGlyph = [
        ".####.",
        "##..##",
        "....##",
        "...##.",
        "..##..",
        "..##..",
        "......",
        "..##..",
        "..##..",
    ]
    static let exclaimGlyph = [
        "##",
        "##",
        "##",
        "##",
        "..",
        "##",
    ]
    static let noteGlyph = [
        "..#...",
        "..##..",
        "..#.#.",
        "..#..#",
        "..#...",
        ".##...",
        "###...",
        ".##...",
    ]
    static let zGlyphSmall = ["###", "..#", ".#.", "#..", "###"]
    static let zGlyphBig = ["####", "...#", "..#.", ".#..", "#...", "####"]
}

// MARK: - Lamb drawing

extension AgentLamb {
    /// The `sheep.drawOverlay` hook: everything except the hover card (which
    /// the herd draws in the overlay layer) and the flying wool (own tile).
    func drawLamb(_ ctx: Canvas, _ x: Double, _ y: Double, _ size: Double, _ facingRight: Bool, _ state: SheepState) {
        let px = Sheep.SCALE * Self.SCALE
        let step = animStep
        let pen = PixelPen(ctx: ctx, ox: x, oy: y, px: px, flip: !facingRight)

        ctx.save()
        applyPose(ctx, x, y, size, facingRight, state)
        drawShornPatch(pen)
        drawWool(pen, step)
        if state != .leaving {
            drawMarks(pen, step, state)
            drawProp(pen, step, state)
        }
        ctx.restore()

        drawLamblets(ctx, x, y, px, step, facingRight)
    }

    /// Re-apply the pose transform `Sheep.draw` puts on its sprite, so wool
    /// and props squash, spin and wiggle with the body.
    private func applyPose(_ ctx: Canvas, _ x: Double, _ y: Double, _ ds: Double, _ facingRight: Bool,
                           _ state: SheepState) {
        let cx = x + ds / 2
        let cy = y + ds / 2
        let t = sheep.stateTimer
        func rotateAbout(_ angle: Double) {
            ctx.translate(cx, cy)
            ctx.rotate(angle)
            ctx.translate(-cx, -cy)
        }
        switch state {
        case .grabbed: rotateAbout(sin(t / 60) * 0.18)
        case .petting: rotateAbout(sin(t / 300) * 0.05)
        case .bounce:
            let squash = 1 + abs(sheep.vy) * 0.001
            ctx.translate(cx, y + ds)
            ctx.scale(1 / squash, squash)
            ctx.translate(-cx, -(y + ds))
        case .spin:
            rotateAbout((t / max(1, sheep.stateDuration)) * .pi * 2)
        case .backflip:
            let progress = t / max(1, sheep.stateDuration)
            let arc = sin(progress * .pi) * 80
            ctx.translate(0, -arc)
            ctx.translate(cx, cy)
            ctx.rotate(-progress * .pi * 2)
            ctx.translate(-cx, -cy)
        case .headshake: ctx.translate(sin(t / 30) * 8, 0)
        case .zoom:
            ctx.translate(cx, cy)
            ctx.rotate(facingRight ? -0.2 : 0.2)
            ctx.scale(1.15, 0.9)
            ctx.translate(-cx, -cy)
        case .stampede:
            ctx.translate(cx, cy)
            ctx.rotate(facingRight ? -0.25 : 0.25)
            ctx.scale(1.2, 0.85)
            ctx.translate(-cx, -cy)
        case .stacked: rotateAbout(sin(t / 300) * 0.08)
        default: break
        }
    }

    // MARK: Wool

    /// Pink skin where the wool was, fading out over ~20 s (the shearing
    /// spectacle's look, as pixel rows).
    private func drawShornPatch(_ pen: PixelPen) {
        guard let shorn = shornAtMs else { return }
        let age = Double(animStep) * Self.STEP_MS - shorn
        let alpha = ((0.65 * (1 - age / Self.SHORN_FADE_MS)) * 20).rounded() / 20
        guard alpha > 0 else { return }
        pen.ctx.save()
        pen.ctx.globalAlpha = alpha
        pen.fill("#f2b9c4", LambDraw.ellipseSpans(rx: 8, ry: 6).map { (13.5 - Double($0.half), 17.5 + Double($0.dy), Double($0.half * 2 + 1), 1) })
        pen.ctx.restore()
    }

    /// The extra wool: pixel discs with an outline, back to front, the odd
    /// puff bobbing a pixel so a fluffball breathes.
    private func drawWool(_ pen: PixelPen, _ step: Int) {
        let puffs = LambDraw.puffLayout(amount: wool.quantized)
        guard !puffs.isEmpty else { return }
        for puff in puffs.reversed() {
            let bob = (step + 3 * puff.index) % 12 < 2 ? -1 : 0
            let cy = puff.cy + bob
            let r = puff.radius
            pen.disc(colors.woolOutline, puff.cx, cy, r + 1)
            pen.disc(colors.wool, puff.cx, cy, r)
            // Shade on the lower right, highlight on the upper left.
            let spans = LambDraw.discSpans(r)
            var shade: [PixelPen.Rect] = []
            for s in spans where s.dy >= Int((r * 0.4).rounded(.up)) {
                shade.append((Double(puff.cx + s.half - (s.dy == spans.last?.dy ? s.half : 1)),
                              Double(cy + s.dy), s.dy == spans.last?.dy ? Double(s.half + 1) : 2, 1))
            }
            pen.fill(colors.woolShade, shade)
            if r >= 2 {
                pen.block("#ffffff", Double(puff.cx) - (r * 0.55).rounded(), Double(cy) - (r * 0.55).rounded(),
                          r >= 3 ? 2 : 1, 1)
            }
        }
    }

    // MARK: Marks

    /// Pixel offset of the head, which sits lower when the sheep sits or lies.
    private func headDY(_ state: SheepState) -> Double {
        switch state {
        case .sit: 2
        case .sleep: 6
        default: 0
        }
    }

    private func drawMarks(_ pen: PixelPen, _ step: Int, _ state: SheepState) {
        let hd = headDY(state)
        let now = animMs
        let waiting = session.phase == .waiting && !(session.tool == .ask)

        if waiting {
            let bob = [0, -1, -2, -1][step % 4]
            pen.glyph(LambDraw.waitGlyph, 23, -8 + hd + Double(bob), fill: "#ffd24a", outline: "#5a3d00")
        }
        if state == .sleep {
            drawZ(pen, step, hd)
        }
        if now < exclaimUntil {
            let life = 1 - (exclaimUntil - now) / 1400
            let rise = min(6, (life * 1400 / 200).rounded(.down))
            let y = 0 + hd - rise
            if (exclaimUntil - now) > 300 || step % 2 == 0 {
                pen.glyph(LambDraw.exclaimGlyph, 26, y - 6, fill: "#e94560", outline: "#4a0f1c")
            }
            if life < 0.35 {
                // a little puff of smoke either side of the mark
                let spread = (life * 14).rounded()
                pen.disc("#e8e8f0", Int(23 - spread), Int(y - 2), 1)
                pen.disc("#e8e8f0", Int(29 + spread), Int(y - 3), 1)
            }
        }
        if now < startledUntil, step % 2 == 0 {
            pen.line("#ffd24a", 22, 4 + Int(hd), 20, 2 + Int(hd))
            pen.line("#ffd24a", 26, 2 + Int(hd), 26, -1 + Int(hd))
            pen.line("#ffd24a", 30, 4 + Int(hd), 32, 2 + Int(hd))
        }
        if now < dizzyUntil {
            for i in 0..<3 {
                let a = Double(step) * 0.9 + Double(i) * 2 * .pi / 3
                let sx = 25 + (cos(a) * 8).rounded()
                let sy = 3 + hd + (sin(a) * 2.5).rounded()
                let front = sin(a) > 0
                pen.fill("#2b2b3b", [(sx - 2, sy - 1, 5, 3), (sx - 1, sy - 2, 3, 5)])
                pen.fill(front ? "#ffd24a" : "#d9a21f", [(sx - 1, sy, 3, 1), (sx, sy - 1, 1, 3)])
                pen.block("#ffffff", sx, sy)
            }
        }
    }

    /// Three Zs drifting up from a sleeping lamb.
    private func drawZ(_ pen: PixelPen, _ step: Int, _ hd: Double) {
        for i in 0..<3 {
            let phase = (step + i * 5) % 16
            let rise = Double(phase)
            let big = i == 2
            let rows = big ? LambDraw.zGlyphBig : LambDraw.zGlyphSmall
            let x = 26 + Double(i) * 3 + (phase % 4 < 2 ? 0 : 1)
            let y = hd + 3 - rise - Double(i) * 1.5
            pen.ctx.save()
            pen.ctx.globalAlpha = phase > 11 ? 0.45 : (phase > 7 ? 0.75 : 1)
            pen.glyph(rows, x.rounded(), y.rounded(), fill: "#e6edff", shadow: "#44527d")
            pen.ctx.restore()
        }
    }

    // MARK: Props

    private var chewing: Bool {
        (session.tool == .compacting && session.phase == .working) || animMs < chewUntil
    }

    private func drawProp(_ pen: PixelPen, _ step: Int, _ state: SheepState) {
        let calm = state == .idle || state == .walk || state == .sit
        guard calm else { return }
        let d: Double = state == .sit ? 3 : 0     // body rows
        let hd: Double = state == .sit ? 2 : 0    // head rows

        if chewing { drawChewing(pen, step, hd) }

        let active = session.phase == .working || (session.phase == .waiting && session.tool == .ask)
        guard active else { return }
        switch session.tool {
        case .edit: drawKnitting(pen, step, d)
        case .bash: drawShovel(pen, step, d)
        case .read: drawBook(pen, step, d)
        case .web: drawTelescope(pen, step, hd)
        case .subagent: drawWhistle(pen, step, hd)
        case .plan: drawClipboard(pen, step, d)
        case .mcp: drawTinCanPhone(pen, step, hd)
        case .ask: drawPlacard(pen, step)
        case .compacting: break // chewing draws it
        case .thinking: drawThoughtCloud(pen, step, hd)
        case .other: drawWand(pen, step, d)
        }
    }

    /// Wooden knitting needles tapping, a strip growing under them, and a
    /// yarn ball in the repo colour with a thread to the work.
    private func drawKnitting(_ pen: PixelPen, _ step: Int, _ d: Double) {
        let p = LambDraw.palette
        let tap = step % 2
        let y0 = Int(d)
        // yarn ball on the ground in front, with a couple of wound stripes
        pen.disc(colors.yarnDark, 41, 27, 3)
        pen.disc(colors.yarn, 41, 27, 2.5)
        pen.fill(colors.yarnDark, [(39, 26, 4, 1), (39, 28, 3, 1), (41, 25, 1, 1)])
        pen.block("#ffffff", 39, 25)
        // thread, sagging between ball and needles
        var thread: [PixelPen.Rect] = []
        for k in 0...8 {
            let t = Double(k) / 8
            let tx = 38 - t * 6
            let ty = 25 - t * 3 + sin(t * .pi) * 2.5 + Double(y0)
            thread.append((tx.rounded(), ty.rounded(), 1, 1))
        }
        pen.fill(colors.yarn, thread)
        // the strip: rows of stitches hanging from the crossing, restarting
        // when it's long enough
        let rows = 2 + (step / 6) % 4
        for r in 0..<rows {
            pen.fill(r % 2 == 0 ? colors.yarn : colors.yarnDark, [(32, 23 + Double(r) + Double(y0), 3, 1)])
        }
        // needles in an X, tips tapping
        pen.line(p["B"]!, 29, 28 + y0, 37, 19 + y0 - tap)
        pen.line(p["b"]!, 29, 27 + y0, 37, 18 + y0 - tap)
        pen.line(p["B"]!, 36, 28 + y0, 29, 19 + y0 - (1 - tap))
        pen.line(p["b"]!, 36, 27 + y0, 29, 18 + y0 - (1 - tap))
        pen.fill(p["o"]!, [(37, 16 + Double(y0) - Double(tap), 2, 2), (28, 16 + Double(y0) - Double(1 - tap), 2, 2)])
    }

    /// Shovel digging at the ground, throwing dirt clods.
    private func drawShovel(_ pen: PixelPen, _ step: Int, _ d: Double) {
        let p = LambDraw.palette
        let cycle = step % 8
        let dy = [0, 1, 2, 3, 1, -1, -2, -1][cycle]
        // handle from the lamb's side down to the blade
        pen.line(p["B"]!, 30, 16 + dy, 34, 26 + dy)
        pen.line(p["b"]!, 31, 16 + dy, 35, 26 + dy)
        pen.fill(p["B"]!, [(28, 14 + Double(dy), 5, 1), (28, 15 + Double(dy), 1, 1), (32, 15 + Double(dy), 1, 1)])
        // blade
        pen.sprite([
            "kkkk",
            "kmMk",
            "kmMk",
            ".kMk",
            "..k.",
        ], 33, 25 + Double(dy), p)
        // dirt mound
        pen.sprite([
            "...DDDD...",
            ".DddddddD.",
            "DddddddddD",
        ], 33, 28, p)
        // clods fly while the shovel comes up
        if cycle >= 4 {
            let t = Double(cycle - 4)
            for j in 0..<3 {
                let x = 36 + 2 * t + Double(j) * 2.5
                let y = 27 - (4 * t - t * t) * 1.4 - Double(j)
                pen.fill(p["D"]!, [(x.rounded(), y.rounded(), 2, 2)])
                pen.block(p["d"]!, x.rounded(), y.rounded())
            }
        }
    }

    /// A tiny open book; a page flips every second or so.
    private func drawBook(_ pen: PixelPen, _ step: Int, _ d: Double) {
        let p = LambDraw.palette
        let bob = (step % 8 < 4) ? 0.0 : 1.0
        let y = 17 + d + bob
        pen.sprite([
            "BBBBBBBBBBBB",
            "BppppPPppppB",
            "BpggpPPpggpB",
            "BppppPPppppB",
            "BpgppPPpgppB",
            "BppppPPppppB",
            "BpggpPPpggpB",
            "BBBBBBBBBBBB",
        ], 28, y, p)
        switch step % 10 {
        case 5: pen.fill(p["w"]!, [(35, y - 1, 2, 7)]); pen.fill(p["P"]!, [(34, y - 1, 1, 7)])
        case 6: pen.fill(p["w"]!, [(33, y - 2, 2, 8)]); pen.fill(p["P"]!, [(35, y - 1, 1, 7)])
        case 7: pen.fill(p["w"]!, [(31, y - 1, 2, 7)]); pen.fill(p["P"]!, [(33, y, 1, 6)])
        default: break
        }
    }

    /// A brass telescope at the eye with a twinkling glint on the lens.
    private func drawTelescope(_ pen: PixelPen, _ step: Int, _ hd: Double) {
        let p = LambDraw.palette
        let h = Int(hd)
        pen.line(p["K"]!, 28, 13 + h, 31, 10 + h, thick: 2)
        pen.line(p["k"]!, 32, 11 + h, 37, 6 + h, thick: 3)
        pen.line(p["O"]!, 32, 10 + h, 36, 6 + h, thick: 3)
        pen.line(p["o"]!, 32, 10 + h, 36, 6 + h, thick: 1)
        pen.line(p["M"]!, 37, 5 + h, 39, 3 + h, thick: 3)
        pen.line(p["m"]!, 37, 5 + h, 39, 3 + h, thick: 1)
        pen.sprite([
            "kkkkk",
            "klllk",
            "klllk",
            "klllk",
            "kkkkk",
        ], 39, -2 + hd, p)
        let cx = 41.0, cy = 0.0 + hd
        switch step % 10 {
        case 1, 5: pen.block("#ffffff", cx, cy)
        case 2, 4: pen.fill("#ffffff", [(cx - 1, cy, 3, 1), (cx, cy - 1, 1, 3)])
        case 3:
            pen.fill("#bfe6ff", [(cx - 3, cy, 7, 1), (cx, cy - 3, 1, 7)])
            pen.fill("#ffffff", [(cx - 1, cy, 3, 1), (cx, cy - 1, 1, 3)])
        default: break
        }
    }

    /// A shepherd's whistle on a red cord, sending out notes.
    private func drawWhistle(_ pen: PixelPen, _ step: Int, _ hd: Double) {
        let p = LambDraw.palette
        let h = Int(hd)
        pen.line(p["r"]!, 23, 21 + h, 30, 17 + h)
        pen.sprite([
            "..kkkkkk.",
            ".kooooook",
            "kooooKoOk",
            ".kOOOOOk.",
            "..kkkkk..",
        ], 29, 14 + hd, p)
        // two notes, offset in time, drifting up and away
        for n in 0..<2 {
            let phase = (step + n * 4) % 8
            let nx = 36 + Double(phase) * 0.8 + Double(n) * 4
            let ny = 11 + hd - Double(phase) * 1.6 - Double(n) * 3
            pen.ctx.save()
            pen.ctx.globalAlpha = phase > 5 ? 0.55 : 1
            pen.glyph(LambDraw.noteGlyph, nx.rounded(), ny.rounded(), fill: "#ffe27a", outline: "#2b2b3b")
            pen.ctx.restore()
        }
    }

    /// A clipboard whose ticks appear one by one.
    private func drawClipboard(_ pen: PixelPen, _ step: Int, _ d: Double) {
        let p = LambDraw.palette
        let y = 14 + d
        pen.sprite([
            "..kmmk..",
            "bbkMMkbb",
            "bppppppb",
            "bkkpggpb",
            "bppppppb",
            "bkkpgggb",
            "bppppppb",
            "bkkpggpb",
            "bppppppb",
            "bbbbbbbb",
        ], 30, y, p)
        let ticks = min(3, (step / 5) % 5)
        for i in 0..<ticks {
            pen.fill(p["n"]!, [(31, y + 4 + Double(i) * 2, 1, 1)])
            pen.fill(p["N"]!, [(32, y + 3 + Double(i) * 2, 1, 1)])
        }
    }

    /// A tin-can phone: can at the mouth, string running off to the right.
    private func drawTinCanPhone(_ pen: PixelPen, _ step: Int, _ hd: Double) {
        let p = LambDraw.palette
        pen.sprite([
            "kkkkkkkk",
            "kwmMmMmk",
            "kmMmMmMk",
            "kmMmMmMk",
            "kmMmMmMk",
            "kkkkkkkk",
        ], 28, 14 + hd, p)
        pen.block(p["k"]!, 36, 17 + hd, 2, 1)
        // the string: sagging, fading with distance, a pulse travelling out
        for i in 0..<20 {
            let sx = 38.0 + Double(i)
            let sy = 17 + hd + (sin(Double(i) / 19 * .pi) * 2.0).rounded()
            let pulse = (step * 2) % 20
            pen.ctx.save()
            pen.ctx.globalAlpha = max(0.15, 1 - Double(i) / 22)
            pen.block(i == pulse ? "#ffffff" : p["s"]!, sx, sy)
            pen.ctx.restore()
        }
    }

    /// A big "?" placard on a pole: the agent is asking you something.
    private func drawPlacard(_ pen: PixelPen, _ step: Int) {
        let p = LambDraw.palette
        let sway = [0, -1, 0, 1][step % 4]
        let flash = step % 12 == 0
        pen.fill(p["B"]!, [(34, 11, 2, 19)])
        pen.fill(p["b"]!, [(34, 11, 1, 19)])
        let top = -2.0 + Double(sway)
        pen.sprite([
            "kkkkkkkkkkkk",
            "koooooooooOk",
            "koooooooooOk",
            "koooooooooOk",
            "koooooooooOk",
            "koooooooooOk",
            "koooooooooOk",
            "koooooooooOk",
            "koooooooooOk",
            "koooooooooOk",
            "kOOOOOOOOOOk",
            "kkkkkkkkkkkk",
        ], 29, top, p)
        pen.glyph(LambDraw.questionGlyph, 32, top + 2, fill: flash ? "#ffffff" : "#b0182f")
    }

    /// A cloud with cycling dots, and two little thought bubbles to the head.
    private func drawThoughtCloud(_ pen: PixelPen, _ step: Int, _ hd: Double) {
        let p = LambDraw.palette
        let bob = (step % 8 < 4) ? 0.0 : 1.0
        pen.fill(p["k"]!, [(27, 6 + hd, 2, 2)])
        pen.block("#ffffff", 27, 6 + hd)
        pen.fill(p["k"]!, [(29, 3 + hd, 3, 3)])
        pen.fill("#ffffff", [(29.5, 3.5 + hd, 2, 2)])
        pen.sprite([
            "....kkkkk......",
            "..kkwwwwwkkk...",
            ".kwwwwwwwwwwk..",
            "kwwwwwwwwwwwwk.",
            "kwwwwwwwwwwwwk.",
            ".kwwwwwwwwwwk..",
            "..kkkkkkkkkk...",
        ], 29, -6 + hd + bob, p)
        let dots = (step / 3) % 4
        for i in 0..<dots {
            pen.block(p["K"]!, 33 + Double(i) * 3, -3 + hd + bob, 2, 2)
        }
    }

    /// A magic wand with a twinkling star and orbiting sparkles.
    private func drawWand(_ pen: PixelPen, _ step: Int, _ d: Double) {
        let p = LambDraw.palette
        let y = Int(d)
        pen.line(p["k"]!, 29, 25 + y, 37, 17 + y)
        pen.line(p["w"]!, 30, 25 + y, 36, 19 + y)
        let yd = Double(y)
        pen.fill(p["o"]!, [(35, 15 + yd, 5, 1), (37, 13 + yd, 1, 5), (36, 14 + yd, 3, 3)])
        pen.fill(p["O"]!, [(36, 16 + yd, 1, 1), (38, 16 + yd, 1, 1)])
        pen.block("#ffffff", 37, 15 + yd)
        let tones = ["#ffe27a", "#ffffff", "#ff9ecb", "#9ee8ff"]
        let spots: [(Double, Double)] = [(33, 10), (41, 14), (39, 21), (34, 17), (42, 9), (31, 14)]
        for i in 0..<4 {
            let on = (step + i * 3) % 8
            let (sx, sy) = spots[(step / 8 + i) % spots.count]
            let cx = sx, cy = sy + yd
            switch on {
            case 0, 4: pen.block(tones[i], cx, cy)
            case 1, 3: pen.fill(tones[i], [(cx - 1, cy, 3, 1), (cx, cy - 1, 1, 3)])
            case 2:
                pen.fill(tones[i], [(cx - 2, cy, 5, 1), (cx, cy - 2, 1, 5)])
                pen.block("#ffffff", cx, cy)
            default: break
            }
        }
    }

    /// Chewing cud: the jaw works, a green wad in the mouth, "munch".
    private func drawChewing(_ pen: PixelPen, _ step: Int, _ hd: Double) {
        let open = step % 2 == 0
        if open {
            pen.fill("#4a1624", [(25, 15 + hd, 4, 3)])
            pen.fill("#e8788c", [(26, 17 + hd, 2, 1)])
            pen.fill("#4ecca3", [(27, 15 + hd, 2, 1)])
        } else {
            pen.fill("#17171f", [(25, 16 + hd, 4, 1)])
            pen.block("#4ecca3", 28, 15 + hd)
        }
        let bob = (step / 2) % 2 == 0 ? 0.0 : -1.0
        pen.text("munch", 28, 1 + hd + bob, font: "bold 9px monospace", color: "#f0f0f8", shadow: "#2b2b3b")
    }

    // MARK: Lamblets

    /// Up to three tiny wool blobs trailing the lamb, hopping.
    private func drawLamblets(_ ctx: Canvas, _ x: Double, _ y: Double, _ px: Double, _ step: Int, _ facingRight: Bool) {
        guard !lamblets.isEmpty else { return }
        let pen = PixelPen(ctx: ctx, ox: x, oy: y, px: px, flip: false)
        let pal: [Character: String] = [
            "k": colors.woolOutline, "W": colors.wool, "S": colors.woolShade, "D": colors.dark, "E": "#ffffff",
            "w": "#ffffff",
        ]
        let rowsRight = [
            "..kkkkk....",
            ".kWWWWWkkk.",
            "kWwWWWWkDDk",
            "kWWWWWWkDEk",
            "kWWWWWSkDDk",
            ".kSSSSSSkkk",
            "..DD..DD...",
            "..DD..DD...",
        ]
        let rows = facingRight ? rowsRight : rowsRight.map { String($0.reversed()) }
        for (i, off) in lamblets.enumerated() {
            let hop = [0, 1, 2, 1, 0, 0][(step + i * 2) % 6]
            let gx = off.rounded() - 5
            let gy = 23.0 - Double(hop)
            // shadow on the ground while it's in the air
            if hop > 0 {
                pen.ctx.save()
                pen.ctx.globalAlpha = 0.3
                pen.fill("#000000", [(gx + 2, 31, 7, 1)])
                pen.ctx.restore()
            }
            pen.sprite(rows, gx, gy, pal)
        }
    }

    // MARK: Particles

    /// Flying wool, in world space (its own tile: it leaves the lamb behind).
    func drawParticles(_ ctx: Canvas) {
        let px = Sheep.SCALE * Self.SCALE
        let now = Double(animStep) * Self.STEP_MS
        func snap(_ v: Double) -> Double { (v * 2).rounded() / 2 }
        func puff(_ cx: Double, _ cy: Double, _ radius: Double, _ color: String) {
            ctx.fillStyle = color
            ctx.beginPath()
            for span in LambDraw.discSpans(radius) {
                ctx.rect(cx - Double(span.half) * px, cy + Double(span.dy) * px,
                         Double(span.half * 2 + 1) * px, px)
            }
            ctx.fill()
        }
        for p in particles {
            let age = max(0, min(WoolParticle.LIFE_MS, now - p.birthMs))
            let t = age / 1000
            let alpha = ((1 - pow(age / WoolParticle.LIFE_MS, 2)) * 8).rounded() / 8
            guard alpha > 0 else { continue }
            let x = snap(p.x0 + p.vx * t)
            let y = snap(min(p.y0 + p.vy * t + 0.5 * WoolParticle.GRAVITY * t * t, p.floorY))
            ctx.globalAlpha = alpha
            puff(x, y, p.size + 1, colors.woolOutline)
            puff(x, y, p.size, p.shade ? colors.woolShade : colors.wool)
        }
        ctx.globalAlpha = 1
    }

    // MARK: Hover card

    /// The name-tag-style card above a hovered lamb. `lift` raises it clear
    /// of a visible bubble.
    func drawCard(_ ctx: Canvas, screenWidth: Double, lift: Double) {
        let lines = cardLines()
        ctx.save()
        ctx.font = "10px monospace"
        let widths = lines.map { ctx.measureText($0).width }
        let w = (widths.max() ?? 40) + 14
        let lineH = 13.0
        let h = Double(lines.count) * lineH + 8
        let cx = sheep.x + sheep.displaySize / 2
        let x = max(4, min(cx - w / 2, screenWidth - w - 4))
        let y = max(4, sheep.y - h - 8 - lift)

        ctx.fillStyle = colors.solid
        ctx.beginPath()
        ctx.roundRect(x - 1, y - 1, w + 2, h + 2, 5)
        ctx.fill()
        ctx.fillStyle = "rgba(26, 26, 46, 0.95)"
        ctx.beginPath()
        ctx.roundRect(x, y, w, h, 4)
        ctx.fill()

        ctx.textAlign = "left"
        ctx.textBaseline = "alphabetic"
        for (i, line) in lines.enumerated() {
            let baseline = y + 4 + lineH * Double(i + 1) - 3
            switch i {
            case 0:
                ctx.font = "bold 10px monospace"
                ctx.fillStyle = "#eeeeee"
            case 1:
                ctx.font = "10px monospace"
                ctx.fillStyle = "#b8b8c8"
            default:
                ctx.font = "10px monospace"
                ctx.fillStyle = session.phase == .waiting ? "#ffd24a" : (session.phase == .working ? colors.solid : "#8a9bb5")
            }
            ctx.fillText(line, x + 7, baseline)
        }
        ctx.restore()
    }
}

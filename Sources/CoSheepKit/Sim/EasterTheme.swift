import Foundation

// Ex-easter-theme.ts.

enum EasterMode: String, CaseIterable, Codable {
    case auto, on, off
}

nonisolated struct EasterEggPosition: Equatable {
    var x: Double
    var y: Double
    var found: Bool
    var golden: Bool
    var hiddenness: Double
    var painted: Bool
    var painterName: String?
}

/// Ex-`EasterStatsSnapshot` (the subset of the Rust `EasterStats` the HUD
/// reads). Decodes straight from the backend's snake_case JSON; every field
/// is optional, unknown keys (top_hunter_id, hunters, …) are ignored.
nonisolated struct EasterStatsSnapshot: Equatable, Codable {
    var eggsFoundTotal: Int?
    var eggsFoundToday: Int?
    var goldenEggsTotal: Int?
    var goldenEggsToday: Int?
    var huntsCompleted: Int?
    var huntsToday: Int?
    var currentStreak: Int?
    var bestStreak: Int?
    var paintedEggsUsedTotal: Int?
    var flockScore: Int?
    var topHunterName: String?
    var lastWinnerName: String?

    init(eggsFoundTotal: Int? = nil, eggsFoundToday: Int? = nil, goldenEggsTotal: Int? = nil,
         goldenEggsToday: Int? = nil, huntsCompleted: Int? = nil, huntsToday: Int? = nil,
         currentStreak: Int? = nil, bestStreak: Int? = nil, paintedEggsUsedTotal: Int? = nil,
         flockScore: Int? = nil, topHunterName: String? = nil, lastWinnerName: String? = nil) {
        self.eggsFoundTotal = eggsFoundTotal
        self.eggsFoundToday = eggsFoundToday
        self.goldenEggsTotal = goldenEggsTotal
        self.goldenEggsToday = goldenEggsToday
        self.huntsCompleted = huntsCompleted
        self.huntsToday = huntsToday
        self.currentStreak = currentStreak
        self.bestStreak = bestStreak
        self.paintedEggsUsedTotal = paintedEggsUsedTotal
        self.flockScore = flockScore
        self.topHunterName = topHunterName
        self.lastWinnerName = lastWinnerName
    }

    private enum CodingKeys: String, CodingKey {
        case eggsFoundTotal = "eggs_found_total"
        case eggsFoundToday = "eggs_found_today"
        case goldenEggsTotal = "golden_eggs_total"
        case goldenEggsToday = "golden_eggs_today"
        case huntsCompleted = "hunts_completed"
        case huntsToday = "hunts_today"
        case currentStreak = "current_streak"
        case bestStreak = "best_streak"
        case paintedEggsUsedTotal = "painted_eggs_used_total"
        case flockScore = "flock_score"
        case topHunterName = "top_hunter_name"
        case lastWinnerName = "last_winner_name"
    }
}

private let PASTEL_COLORS = [
    "rgba(255, 182, 193, 0.72)",
    "rgba(176, 226, 172, 0.72)",
    "rgba(200, 180, 230, 0.72)",
    "rgba(255, 239, 170, 0.72)",
    "rgba(180, 220, 255, 0.72)",
]

private let FLOWER_PALETTES: [(petal: String, center: String)] = [
    ("#FFB6C1", "#FFD700"),
    ("#DDA0DD", "#FFF8DC"),
    ("#FFFACD", "#FFA07A"),
    ("#E6E6FA", "#FFD700"),
    ("#98FB98", "#FF69B4"),
]

private let EGG_PALETTES: [(base: String, stripe: String, accent: String)] = [
    ("#FFB6C1", "#FF69B4", "#FFF4FA"),
    ("#B0E2AC", "#4CAF50", "#ECFFF0"),
    ("#C8B4E6", "#7B68EE", "#F2ECFF"),
    ("#FFEFAA", "#E8B400", "#FFFBE0"),
    ("#B4DCFF", "#6495ED", "#ECF6FF"),
    ("#FFDAB9", "#FF8C00", "#FFF0E2"),
]

private let ACTIVE_REFRESH_INTERVAL_MS: Double = 60000
private let HUD_DISPLAY_TIME_MS: Double = 18000
private let MAX_PAINTED_DESIGNS = 6

private let EGG_SPAWN_POINTS: [(x: Double, y: Double)] = [
    (0.06, 0.91),
    (0.13, 0.875),
    (0.21, 0.94),
    (0.28, 0.895),
    (0.36, 0.955),
    (0.43, 0.905),
    (0.52, 0.94),
    (0.6, 0.965),
    (0.68, 0.915),
    (0.76, 0.945),
    (0.84, 0.89),
    (0.92, 0.93),
]

/// Compute Easter Sunday for a given year using the Anonymous Gregorian algorithm
func computeEasterSunday(_ year: Int) -> Date {
    let a = year % 19
    let b = year / 100
    let c = year % 100
    let d = b / 4
    let e = b % 4
    let f = (b + 8) / 25
    let g = (b - f + 1) / 3
    let h = (19 * a + b - d - g + 15) % 30
    let i = c / 4
    let k = c % 4
    let l = (32 + 2 * e + 2 * i - h - k) % 7
    let m = (a + 11 * h + 22 * l) / 451
    let month = (h + l - 7 * m + 114) / 31
    let day = ((h + l - 7 * m + 114) % 31) + 1
    return gregorian.date(from: DateComponents(year: year, month: month, day: day))!
}

/// JS `Date` is always Gregorian in the local zone — never the user's
/// system calendar (Buddhist, Japanese…), which would shift years/months.
nonisolated let gregorian: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .current
    return c
}()

/// Check if today falls within the Easter season window (5 days before to 2 days after).
/// `now` defaults to `SimClock` (tests can pass a date instead of overriding the clock).
func isEasterSeason(_ now: Date = Date(timeIntervalSince1970: SimClock.nowMs() / 1000)) -> Bool {
    let cal = gregorian
    let easter = computeEasterSunday(cal.component(.year, from: now))
    let start = cal.date(byAdding: .day, value: -5, to: easter)!
    let end = cal.date(byAdding: .day, value: 2, to: easter)!
    let today = cal.startOfDay(for: now)
    return today >= start && today <= end
}

final class EasterTheme: EasterThemeHooks {
    enum EggPattern: String, CaseIterable {
        case stripe, zigzag, dots, bands, cross
    }

    struct Flower {
        var x: Double
        var y: Double
        var color: String
        var petalColor: String
        var swaySpeed: Double
        var swayOffset: Double
        var size: Double
    }

    struct Petal {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var color: String
        var rotation: Double
        var rotationSpeed: Double
        var size: Double
    }

    struct PaintedEggDesign {
        var painterId: String
        var painterName: String
        var baseColor: String
        var stripeColor: String
        var accentColor: String
        var pattern: EggPattern
    }

    struct EasterEgg {
        var x: Double
        var y: Double
        var baseColor: String
        var stripeColor: String
        var accentColor: String
        var found: Bool
        var sparkleTimer: Double
        var hiddenness: Double
        var isGolden: Bool
        var pattern: EggPattern
        var shadowScale: Double
        var paintedBy: PaintedEggDesign?
    }

    static let PATTERNS: [EggPattern] = [.stripe, .zigzag, .dots, .bands, .cross]

    private static func chooseRandom<T>(_ items: [T]) -> T {
        items[SimRandom.int(items.count)]
    }

    private static func pickDistinctSpawnPoints(_ count: Int) -> [(x: Double, y: Double)] {
        var pool = EGG_SPAWN_POINTS
        var chosen: [(x: Double, y: Double)] = []

        while !pool.isEmpty && chosen.count < count {
            let index = SimRandom.int(pool.count)
            let point = pool.remove(at: index)
            chosen.append(point)
            var i = pool.count - 1
            while i >= 0 {
                if abs(pool[i].x - point.x) < 0.07 {
                    pool.remove(at: i)
                }
                i -= 1
            }
        }

        return chosen.sorted { $0.x < $1.x }
    }

    private(set) var flowers: [Flower] = []
    private(set) var petals: [Petal] = []
    private(set) var eggs: [EasterEgg] = []
    private(set) var paintedEggDesigns: [PaintedEggDesign] = []
    private var basketLoads: [String: Int] = [:]
    private var huntParticipants: Set<String> = []
    private var sheepPositions: [SheepPosition] = []
    private var stats = EasterStatsSnapshot()
    private var screenWidth: Double
    private var screenHeight: Double
    private var time: Double = 0
    private var activeRefreshTimer: Double = 0
    private var hudTimer: Double = 0
    private var recentHuntTimer: Double = 0
    private var modeOverride: EasterMode = .auto
    private var huntActive = false
    private var currentPaintedEggsUsed = 0
    private(set) var active = false

    init(_ screenWidth: Double, _ screenHeight: Double) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        refreshActiveState(true)
    }

    func setModeOverride(_ mode: EasterMode = .auto) {
        modeOverride = mode
        refreshActiveState(true)
    }

    func getModeOverride() -> EasterMode {
        modeOverride
    }

    func applyStats(_ stats: EasterStatsSnapshot?) {
        self.stats = stats ?? EasterStatsSnapshot()
    }

    func hasRecentHuntBuzz() -> Bool {
        recentHuntTimer > 0
    }

    func shouldShowBasket(_ id: String) -> Bool {
        if !active { return false }
        return (huntActive && huntParticipants.contains(id)) || (basketLoads[id] ?? 0) > 0
    }

    func getBasketFillRatio(_ id: String) -> Double {
        max(0, min(1, Double(basketLoads[id] ?? 0) / 3))
    }

    func getBasketEggCount(_ id: String) -> Int {
        basketLoads[id] ?? 0
    }

    func getPaintedEggsUsedCount() -> Int {
        currentPaintedEggsUsed
    }

    func registerPaintedEgg(_ painterId: String, _ painterName: String) {
        if !active { return }
        let palette = Self.chooseRandom(EGG_PALETTES)
        let design = PaintedEggDesign(
            painterId: painterId,
            painterName: painterName,
            baseColor: palette.base,
            stripeColor: palette.stripe,
            accentColor: palette.accent,
            pattern: Self.chooseRandom(Self.PATTERNS)
        )
        paintedEggDesigns.insert(design, at: 0)
        if paintedEggDesigns.count > MAX_PAINTED_DESIGNS {
            paintedEggDesigns.removeSubrange(MAX_PAINTED_DESIGNS...)
        }
        hudTimer = HUD_DISPLAY_TIME_MS
    }

    @discardableResult
    func refreshActiveState(_ force: Bool = false) -> Bool {
        let seasonActive = isEasterSeason()
        let nextActive: Bool = modeOverride == .on
            ? true
            : modeOverride == .off
                ? false
                : seasonActive

        if !force && nextActive == active {
            return false
        }

        active = nextActive
        petals = []
        time = 0
        huntActive = false
        huntParticipants.removeAll()
        basketLoads.removeAll()
        currentPaintedEggsUsed = 0

        if active {
            seedFlowers()
            seedEggs()
            hudTimer = HUD_DISPLAY_TIME_MS
        } else {
            flowers = []
            eggs = []
        }

        return true
    }

    private func seedFlowers() {
        flowers = []
        for n in 0..<16 {
            let i = Double(n)
            let palette = FLOWER_PALETTES[n % FLOWER_PALETTES.count]
            flowers.append(Flower(
                x: 0.04 + (i / 15) * 0.92 + sin(i * 4.7) * 0.02,
                y: 0.84 + sin(i * 3.1) * 0.06,
                color: palette.center,
                petalColor: palette.petal,
                swaySpeed: 0.45 + sin(i * 2.1) * 0.2,
                swayOffset: i * 1.17,
                size: 0.9 + sin(i * 2.9) * 0.3
            ))
        }
    }

    private func createEgg(_ point: (x: Double, y: Double), _ design: PaintedEggDesign? = nil,
                           _ isGolden: Bool = false) -> EasterEgg {
        let fallbackPalette = Self.chooseRandom(EGG_PALETTES)
        let palette = design.map { (base: $0.baseColor, stripe: $0.stripeColor, accent: $0.accentColor) }
            ?? fallbackPalette
        let x = point.x + (SimRandom.next() - 0.5) * 0.01
        let y = point.y + (SimRandom.next() - 0.5) * 0.01
        let hiddenness = isGolden ? 0.12 : 0.18 + SimRandom.next() * 0.38
        let pattern = design?.pattern ?? Self.chooseRandom(Self.PATTERNS)
        let shadowScale = 0.8 + SimRandom.next() * 0.4
        return EasterEgg(
            x: x,
            y: y,
            baseColor: isGolden ? "#FFE07B" : palette.base,
            stripeColor: isGolden ? "#F2B705" : palette.stripe,
            accentColor: isGolden ? "#FFF7CC" : palette.accent,
            found: false,
            sparkleTimer: 0,
            hiddenness: hiddenness,
            isGolden: isGolden,
            pattern: pattern,
            shadowScale: shadowScale,
            paintedBy: design
        )
    }

    private func seedEggs() {
        eggs = []
        let eggCount = 6 + (SimRandom.next() < 0.35 ? 1 : 0)
        let points = Self.pickDistinctSpawnPoints(eggCount)
        let goldenIndex = SimRandom.next() < 0.2 ? SimRandom.int(points.count) : -1
        var paintedPool = paintedEggDesigns
        currentPaintedEggsUsed = 0

        for i in 0..<points.count {
            let shouldUsePainted = !paintedPool.isEmpty && SimRandom.next() < 0.45
            let design: PaintedEggDesign? = shouldUsePainted
                ? paintedPool.remove(at: SimRandom.int(paintedPool.count))
                : nil
            if design != nil {
                currentPaintedEggsUsed += 1
            }
            eggs.append(createEgg(points[i], design, i == goldenIndex))
        }
    }

    func getEggPositions() -> [EasterEggPosition] {
        eggs.map { egg in
            EasterEggPosition(
                x: egg.x * screenWidth,
                y: egg.y * screenHeight,
                found: egg.found,
                golden: egg.isGolden,
                hiddenness: egg.hiddenness,
                painted: egg.paintedBy != nil,
                painterName: egg.paintedBy?.painterName
            )
        }
    }

    func prepareHunt(_ participants: [String]) {
        if !active { return }
        huntActive = true
        huntParticipants = Set(participants)
        basketLoads.removeAll()
        seedEggs()
        hudTimer = HUD_DISPLAY_TIME_MS
    }

    func collectEgg(_ index: Int, _ finderId: String? = nil) {
        if index < 0 || index >= eggs.count { return }
        if eggs[index].found { return }

        eggs[index].found = true
        eggs[index].sparkleTimer = eggs[index].isGolden ? 3.4 : 2.2
        // `if (finderId)` — the empty string is falsy in JS.
        if let finderId, !finderId.isEmpty {
            basketLoads[finderId] = (basketLoads[finderId] ?? 0) + (eggs[index].isGolden ? 2 : 1)
        }
        hudTimer = HUD_DISPLAY_TIME_MS
        recentHuntTimer = max(recentHuntTimer, 10000)
    }

    func finishHunt() {
        huntActive = false
        recentHuntTimer = max(recentHuntTimer, 15000)
        huntParticipants.removeAll()
    }

    /// Reset eggs for a new egg hunt round
    func resetEggs() {
        if !active { return }
        huntActive = false
        huntParticipants.removeAll()
        basketLoads.removeAll()
        seedEggs()
    }

    func updateScreenSize(_ w: Double, _ h: Double) {
        screenWidth = w
        screenHeight = h
    }

    func update(_ dt: Double, _ sheepPositions: [SheepPosition]) {
        self.sheepPositions = sheepPositions
        activeRefreshTimer += dt
        if activeRefreshTimer >= ACTIVE_REFRESH_INTERVAL_MS {
            activeRefreshTimer = activeRefreshTimer.truncatingRemainder(dividingBy: ACTIVE_REFRESH_INTERVAL_MS)
            refreshActiveState()
        }

        if !active { return }
        time += dt / 1000
        hudTimer = max(0, hudTimer - dt)
        recentHuntTimer = max(0, recentHuntTimer - dt)

        updatePetals(dt / 1000)

        for i in eggs.indices where eggs[i].sparkleTimer > 0 {
            eggs[i].sparkleTimer -= dt / 1000
        }
    }

    private func updatePetals(_ dt: Double) {
        while petals.count < 18 {
            petals.append(spawnPetal())
        }

        for i in petals.indices {
            var petal = petals[i]
            petal.x += petal.vx * dt
            petal.y += petal.vy * dt
            petal.rotation += petal.rotationSpeed * dt
            petal.x += sin(petal.y * 0.035 + petal.rotation) * 10 * dt

            for sheep in sheepPositions {
                let dx = petal.x - (sheep.x + 48)
                let dy = petal.y - (sheep.y + 56)
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance < 130 {
                    let push = (130 - distance) / 130
                    petal.x += (dx >= 0 ? 1 : -1) * push * 16 * dt
                    petal.rotation += push * 1.8 * dt
                }
            }
            petals[i] = petal
        }

        // Respawn petals that drifted off-screen (pushing into the array
        // being filtered would be discarded by the filter's return value)
        petals = petals.map { petal in
            petal.y < -20 || petal.x < -20 || petal.x > screenWidth + 20
                ? spawnPetal()
                : petal
        }
    }

    private func spawnPetal() -> Petal {
        let x = SimRandom.next() * screenWidth
        let y = screenHeight + SimRandom.next() * 40
        let vx = (SimRandom.next() - 0.5) * 10
        let vy = -(15 + SimRandom.next() * 25)
        let color = Self.chooseRandom(PASTEL_COLORS)
        let rotation = SimRandom.next() * Double.pi * 2
        let rotationSpeed = (SimRandom.next() - 0.5) * 2.2
        let size = 3 + SimRandom.next() * 4
        return Petal(x: x, y: y, vx: vx, vy: vy, color: color, rotation: rotation,
                     rotationSpeed: rotationSpeed, size: size)
    }

    func drawBackground(_ ctx: Canvas, _ w: Double, _ h: Double) {
        if !active { return }
        drawGroundWash(ctx, w, h)
        drawFlowers(ctx, w, h)
    }

    func drawMidground(_ ctx: Canvas, _ w: Double, _ h: Double) {
        if !active { return }
        drawEggs(ctx, w, h)
    }

    func drawForeground(_ ctx: Canvas, _ w: Double, _ h: Double) {
        if !active { return }
        drawSparkles(ctx, w, h)
        drawPetals(ctx)
        drawHud(ctx, w, h)
    }

    private func drawGroundWash(_ ctx: Canvas, _ w: Double, _ h: Double) {
        ctx.save()
        let gradient = ctx.createLinearGradient(0, h * 0.7, 0, h)
        gradient.addColorStop(0, "rgba(255, 240, 204, 0)")
        gradient.addColorStop(1, "rgba(200, 236, 170, 0.08)")
        ctx.fillStyle = gradient
        ctx.fillRect(0, h * 0.7, w, h * 0.3)
        ctx.restore()
    }

    private func drawFlowers(_ ctx: Canvas, _ w: Double, _ h: Double) {
        ctx.save()
        for flower in flowers {
            let fx = flower.x * w
            let fy = flower.y * h
            let sway = sin(time * flower.swaySpeed + flower.swayOffset) * 3
            let scale = flower.size * 3

            ctx.strokeStyle = "rgba(80, 160, 80, 0.6)"
            ctx.lineWidth = 1.5
            ctx.beginPath()
            ctx.moveTo(fx + sway, fy)
            ctx.lineTo(fx, fy + (12 * scale) / 3)
            ctx.stroke()

            ctx.fillStyle = flower.petalColor
            for n in 0..<5 {
                let i = Double(n)
                let angle = (i / 5) * Double.pi * 2 + time * 0.1
                let px = fx + sway + (cos(angle) * 3 * scale) / 3
                let py = fy + (sin(angle) * 3 * scale) / 3
                ctx.beginPath()
                ctx.arc(px, py, (2.5 * scale) / 3, 0, Double.pi * 2)
                ctx.fill()
            }

            ctx.fillStyle = flower.color
            ctx.beginPath()
            ctx.arc(fx + sway, fy, (2 * scale) / 3, 0, Double.pi * 2)
            ctx.fill()
        }
        ctx.restore()
    }

    private func drawEggs(_ ctx: Canvas, _ w: Double, _ h: Double) {
        ctx.save()
        for egg in eggs {
            if egg.found { continue }

            let ex = egg.x * w
            let ey = egg.y * h
            let eggW: Double = egg.isGolden ? 7 : 6
            let eggH: Double = egg.isGolden ? 9 : 8

            ctx.fillStyle = "rgba(40, 50, 35, 0.14)"
            ctx.beginPath()
            ctx.ellipse(ex, ey + 8, eggW * 1.3 * egg.shadowScale, 2.4, 0, 0, Double.pi * 2)
            ctx.fill()

            ctx.fillStyle = egg.baseColor
            ctx.beginPath()
            ctx.ellipse(ex, ey, eggW, eggH, 0, 0, Double.pi * 2)
            ctx.fill()

            drawEggPattern(ctx, ex, ey, eggW, eggH, egg)

            ctx.fillStyle = egg.accentColor
            ctx.beginPath()
            ctx.ellipse(ex - 2, ey - 3, 1.5, 2, -0.3, 0, Double.pi * 2)
            ctx.fill()

            drawGrassTufts(ctx, ex, ey, egg.hiddenness)
        }
        ctx.restore()
    }

    private func drawEggPattern(_ ctx: Canvas, _ ex: Double, _ ey: Double, _ eggW: Double, _ eggH: Double,
                                _ egg: EasterEgg) {
        ctx.save()
        ctx.strokeStyle = egg.stripeColor
        ctx.fillStyle = egg.stripeColor
        ctx.lineWidth = egg.isGolden ? 1.2 : 1

        switch egg.pattern {
        case .stripe:
            ctx.fillRect(ex - eggW, ey - 1.5, eggW * 2, 3)
        case .bands:
            ctx.fillRect(ex - eggW + 0.5, ey - 5, eggW * 2 - 1, 2)
            ctx.fillRect(ex - eggW + 0.5, ey + 2, eggW * 2 - 1, 2)
        case .dots:
            for i in -1...1 {
                ctx.beginPath()
                ctx.arc(ex + Double(i) * 3, ey + (i % 2 == 0 ? -1 : 2), 1.2, 0, Double.pi * 2)
                ctx.fill()
            }
        case .cross:
            ctx.fillRect(ex - 1, ey - eggH + 2, 2, eggH * 2 - 4)
            ctx.fillRect(ex - eggW + 1, ey - 1, eggW * 2 - 2, 2)
        case .zigzag:
            ctx.beginPath()
            for i in 0..<5 {
                let zx = ex - eggW + 1 + (Double(i) * (eggW * 2 - 2)) / 4
                let zy = ey + 1 + (i % 2 == 0 ? -2 : 2)
                if i == 0 { ctx.moveTo(zx, zy) }
                else { ctx.lineTo(zx, zy) }
            }
            ctx.stroke()
        }

        if egg.paintedBy != nil {
            ctx.fillStyle = "rgba(255, 255, 255, 0.65)"
            ctx.beginPath()
            ctx.arc(ex, ey - 5, 1.1, 0, Double.pi * 2)
            ctx.fill()
        }
        ctx.restore()
    }

    private func drawGrassTufts(_ ctx: Canvas, _ ex: Double, _ ey: Double, _ hiddenness: Double) {
        let tuftCount = 2 + Int((hiddenness * 4).rounded(.toNearestOrAwayFromZero))
        let height = 3 + hiddenness * 4
        ctx.save()
        ctx.strokeStyle = "rgba(109, 168, 93, 0.9)"
        ctx.lineWidth = 1
        for i in 0..<tuftCount {
            let gx = ex - 6 + Double(i) * 3
            let sway = sin(time * 1.4 + gx) * 0.8
            ctx.beginPath()
            ctx.moveTo(gx, ey + 7)
            ctx.lineTo(gx - 1 + sway, ey + 7 - height)
            ctx.moveTo(gx, ey + 7)
            ctx.lineTo(gx + 1 + sway, ey + 7 - height * 0.85)
            ctx.stroke()
        }
        ctx.restore()
    }

    private func drawSparkles(_ ctx: Canvas, _ w: Double, _ h: Double) {
        for egg in eggs {
            if !egg.found || egg.sparkleTimer <= 0 { continue }
            drawSparkle(ctx, egg.x * w, egg.y * h, egg.sparkleTimer, egg.isGolden)
        }
    }

    private func drawSparkle(_ ctx: Canvas, _ x: Double, _ y: Double, _ timer: Double, _ golden: Bool) {
        let alpha = min(1, timer)
        let spread = (golden ? 20 : 15) * (golden ? 1.4 : 1) * (3 - timer * 0.8)
        ctx.save()
        ctx.globalAlpha = alpha
        ctx.fillStyle = golden ? "#FFE07B" : "#FFD700"
        let count = golden ? 8 : 6
        for n in 0..<count {
            let i = Double(n)
            let angle = (i / Double(count)) * Double.pi * 2 + time * (golden ? 4 : 3)
            let sx = x + cos(angle) * spread * 0.35
            let sy = y + sin(angle) * spread * 0.25
            ctx.beginPath()
            ctx.arc(sx, sy, golden ? 2.4 : 2, 0, Double.pi * 2)
            ctx.fill()
        }
        ctx.restore()
    }

    private func drawPetals(_ ctx: Canvas) {
        ctx.save()
        for petal in petals {
            ctx.fillStyle = petal.color
            ctx.save()
            ctx.translate(petal.x, petal.y)
            ctx.rotate(petal.rotation)
            ctx.beginPath()
            ctx.ellipse(0, 0, petal.size * 0.5, petal.size, 0, 0, Double.pi * 2)
            ctx.fill()
            ctx.restore()
        }
        ctx.restore()
    }

    private func drawHud(_ ctx: Canvas, _ w: Double, _ _h: Double) {
        let shouldShow = hudTimer > 0 || recentHuntTimer > 0 || huntActive || modeOverride != .auto
        if !shouldShow { return }

        let eggsToday = stats.eggsFoundToday ?? 0
        let streak = stats.currentStreak ?? 0
        let score = stats.flockScore ?? 0
        let hunts = stats.huntsCompleted ?? 0
        // `a || b || "Nobody yet"` — empty strings fall through, like in JS.
        let topHunter = [stats.topHunterName, stats.lastWinnerName]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? "Nobody yet"
        let goldenToday = stats.goldenEggsToday ?? 0

        let boxW: Double = 188
        let boxH: Double = 82
        let x = w - boxW - 18
        let y: Double = 18

        ctx.save()
        ctx.fillStyle = "rgba(26, 26, 46, 0.72)"
        ctx.strokeStyle = "rgba(255, 233, 163, 0.35)"
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.roundRect(x, y, boxW, boxH, 12)
        ctx.fill()
        ctx.stroke()

        ctx.fillStyle = "#FFF5CE"
        ctx.font = "bold 11px monospace"
        ctx.fillText("SPRING LEDGER", x + 14, y + 18)

        ctx.fillStyle = "#F7DA7D"
        ctx.font = "10px monospace"
        ctx.fillText("Eggs today \(eggsToday)", x + 14, y + 36)
        ctx.fillText("Golden \(goldenToday)", x + 14, y + 50)
        ctx.fillText("Streak \(streak)  Hunts \(hunts)", x + 14, y + 64)
        ctx.fillText("Score \(score)", x + 14, y + 78)

        ctx.fillStyle = "#BFE4A8"
        ctx.textAlign = "right"
        ctx.fillText(topHunter, x + boxW - 14, y + 36)
        ctx.fillStyle = "#A6BEDA"
        ctx.fillText(modeOverride == .auto ? "Seasonal" : "Forced \(modeOverride.rawValue)", x + boxW - 14, y + 78)
        ctx.textAlign = "start"
        ctx.restore()
    }
}

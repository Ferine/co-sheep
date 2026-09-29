import Foundation

// Ex-summer-theme.ts.

enum SummerMode: String, CaseIterable, Codable {
    case auto, on, off
}

private let BUTTERFLY_COLORS = ["#FF8C42", "#FFD23F", "#F26CA7", "#7FB5FF", "#B8E986"]

private let SUNFLOWER_SPOTS: [(x: Double, y: Double)] = [
    (0.04, 0.965),
    (0.115, 0.975),
    (0.24, 0.96),
    (0.41, 0.975),
    (0.58, 0.962),
    (0.72, 0.975),
    (0.86, 0.958),
    (0.955, 0.972),
]

private let BUTTERFLY_COUNT = 4
private let SEED_COUNT = 10

/// Temperatures at/above this (°C) count as summer weather
private let SUMMER_TEMP_THRESHOLD: Double = 18
private let SUMMER_ACTIVE_REFRESH_INTERVAL_MS: Double = 60000

/// June through August (northern hemisphere).
/// `now` defaults to `SimClock` (tests can pass a date instead of overriding the clock).
func isSummerSeason(_ now: Date = Date(timeIntervalSince1970: SimClock.nowMs() / 1000)) -> Bool {
    let month = Calendar.current.component(.month, from: now) - 1 // 0-based, like getMonth()
    return month >= 5 && month <= 7
}

/// Summer event: a sun with slowly turning rays, sunflowers along the
/// bottom, butterflies that drift toward calm sheep, and floating seeds.
/// Activates automatically during summer months when the weather is
/// actually summery (clear and warm), or via the settings override.
final class SummerTheme {
    struct Sunflower {
        var x: Double // fraction of screen width
        var y: Double // fraction of screen height
        var size: Double
        var swaySpeed: Double
        var swayOffset: Double
    }

    struct Butterfly {
        var x: Double
        var y: Double
        var targetX: Double
        var targetY: Double
        var wingPhase: Double
        var color: String
        var retargetTimer: Double
    }

    struct Seed {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var size: Double
        var swayOffset: Double
    }

    private(set) var sunflowers: [Sunflower] = []
    private(set) var butterflies: [Butterfly] = []
    private(set) var seeds: [Seed] = []
    private var sheepPositions: [SheepPosition] = []
    private var screenWidth: Double
    private var screenHeight: Double
    private var time: Double = 0
    private var activeRefreshTimer: Double = 0
    private var modeOverride: SummerMode = .auto
    private var weatherCondition: String?
    private var weatherTempC: Double?
    private(set) var active = false

    init(_ screenWidth: Double, _ screenHeight: Double) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        refreshActiveState()
    }

    func setModeOverride(_ mode: SummerMode = .auto) {
        modeOverride = mode
        refreshActiveState()
    }

    /// Feed the latest weather poll — this is what triggers the event
    func setWeather(_ condition: String?, _ tempC: Double?) {
        weatherCondition = condition
        weatherTempC = tempC
        refreshActiveState()
    }

    func updateScreenSize(_ w: Double, _ h: Double) {
        screenWidth = w
        screenHeight = h
        if active { spawnDecorations() }
    }

    /// Clear skies and warm enough — or no weather configured, season decides
    private func weatherLooksSummery() -> Bool {
        guard let condition = weatherCondition else { return true }
        if condition != "clear" { return false }
        guard let tempC = weatherTempC else { return true }
        return tempC >= SUMMER_TEMP_THRESHOLD
    }

    private func refreshActiveState() {
        let wasActive = active
        if modeOverride == .on {
            active = true
        } else if modeOverride == .off {
            active = false
        } else {
            active = isSummerSeason() && weatherLooksSummery()
        }

        if active && !wasActive {
            spawnDecorations()
            Log.info("summer", "Summer event activated ☀")
        } else if !active && wasActive {
            sunflowers = []
            butterflies = []
            seeds = []
            Log.info("summer", "Summer event deactivated")
        }
    }

    private func spawnDecorations() {
        sunflowers = SUNFLOWER_SPOTS.map { spot in
            let size = 26 + SimRandom.next() * 14
            let swaySpeed = 0.4 + SimRandom.next() * 0.5
            let swayOffset = SimRandom.next() * Double.pi * 2
            return Sunflower(x: spot.x, y: spot.y, size: size, swaySpeed: swaySpeed, swayOffset: swayOffset)
        }

        butterflies = []
        for _ in 0..<BUTTERFLY_COUNT {
            butterflies.append(spawnButterfly())
        }

        seeds = []
        for _ in 0..<SEED_COUNT {
            seeds.append(spawnSeed(true))
        }
    }

    private func spawnButterfly() -> Butterfly {
        let x = SimRandom.next() * screenWidth
        let y = screenHeight * (0.4 + SimRandom.next() * 0.45)
        let targetX = SimRandom.next() * screenWidth
        let targetY = screenHeight * (0.4 + SimRandom.next() * 0.45)
        let wingPhase = SimRandom.next() * Double.pi * 2
        let color = BUTTERFLY_COLORS[SimRandom.int(BUTTERFLY_COLORS.count)]
        let retargetTimer = 1000 + SimRandom.next() * 4000
        return Butterfly(x: x, y: y, targetX: targetX, targetY: targetY, wingPhase: wingPhase,
                         color: color, retargetTimer: retargetTimer)
    }

    private func spawnSeed(_ anywhere: Bool) -> Seed {
        let x = anywhere ? SimRandom.next() * screenWidth : -10
        let y = anywhere
            ? SimRandom.next() * screenHeight * 0.8
            : screenHeight * (0.3 + SimRandom.next() * 0.5)
        let vx = 8 + SimRandom.next() * 14
        let vy = -(2 + SimRandom.next() * 6)
        let size = 2 + SimRandom.next() * 2
        let swayOffset = SimRandom.next() * Double.pi * 2
        return Seed(x: x, y: y, vx: vx, vy: vy, size: size, swayOffset: swayOffset)
    }

    func update(_ dt: Double, _ sheepPositions: [SheepPosition]) {
        time += dt
        self.sheepPositions = sheepPositions

        // Season/weather can flip mid-session (sunset poll, month rollover)
        activeRefreshTimer += dt
        if activeRefreshTimer >= SUMMER_ACTIVE_REFRESH_INTERVAL_MS {
            activeRefreshTimer = 0
            refreshActiveState()
        }

        if !active { return }

        updateButterflies(dt)
        updateSeeds(dt)
    }

    private func updateButterflies(_ dt: Double) {
        let dtSec = dt / 1000
        for i in butterflies.indices {
            var b = butterflies[i]
            b.wingPhase += dtSec * 14
            b.retargetTimer -= dt

            if b.retargetTimer <= 0 {
                b.retargetTimer = 2000 + SimRandom.next() * 5000
                // Sometimes visit a resting sheep, otherwise wander
                let calm = sheepPositions.filter {
                    $0.state == .sit || $0.state == .idle || $0.state == .idleSleep || $0.state == .sleep
                }
                if !calm.isEmpty && SimRandom.next() < 0.45 {
                    let sheep = calm[SimRandom.int(calm.count)]
                    b.targetX = sheep.x + 30 + SimRandom.next() * 40
                    b.targetY = sheep.y - 20 - SimRandom.next() * 30
                } else {
                    b.targetX = SimRandom.next() * screenWidth
                    b.targetY = screenHeight * (0.35 + SimRandom.next() * 0.5)
                }
            }

            // Ease toward target with a flutter wobble
            let dx = b.targetX - b.x
            let dy = b.targetY - b.y
            b.x += dx * dtSec * 0.9 + sin(b.wingPhase * 0.7) * 22 * dtSec
            b.y += dy * dtSec * 0.9 + cos(b.wingPhase * 0.5) * 16 * dtSec
            butterflies[i] = b
        }
    }

    private func updateSeeds(_ dt: Double) {
        let dtSec = dt / 1000
        for i in seeds.indices {
            var s = seeds[i]
            s.x += (s.vx + sin(time / 900 + s.swayOffset) * 6) * dtSec
            s.y += s.vy * dtSec
            if s.x > screenWidth + 15 || s.y < -15 {
                seeds[i] = spawnSeed(false)
            } else {
                seeds[i] = s
            }
        }
    }

    /// Sun and warm glow — drawn behind everything
    func drawBackground(_ ctx: Canvas, _ w: Double, _ _h: Double) {
        if !active { return }

        let sunX = w * 0.88
        let sunY: Double = 90
        let sunR: Double = 34

        ctx.save()

        // Soft warm halo
        let glow = ctx.createRadialGradient(sunX, sunY, sunR * 0.5, sunX, sunY, sunR * 4)
        glow.addColorStop(0, "rgba(255, 214, 90, 0.30)")
        glow.addColorStop(1, "rgba(255, 214, 90, 0)")
        ctx.fillStyle = glow
        ctx.fillRect(sunX - sunR * 4, sunY - sunR * 4, sunR * 8, sunR * 8)

        // Slowly turning rays
        let rotation = time / 14000
        ctx.strokeStyle = "rgba(255, 205, 66, 0.55)"
        ctx.lineWidth = 4
        ctx.lineCap = "round"
        for n in 0..<12 {
            let i = Double(n)
            let angle = rotation + (i / 12) * Double.pi * 2
            let inner = sunR + 8 + sin(time / 600 + i) * 2
            let outer = inner + 14
            ctx.beginPath()
            ctx.moveTo(sunX + cos(angle) * inner, sunY + sin(angle) * inner)
            ctx.lineTo(sunX + cos(angle) * outer, sunY + sin(angle) * outer)
            ctx.stroke()
        }

        // Sun core
        let core = ctx.createRadialGradient(sunX - 8, sunY - 8, 4, sunX, sunY, sunR)
        core.addColorStop(0, "#FFF3B0")
        core.addColorStop(1, "#FFC53D")
        ctx.fillStyle = core
        ctx.beginPath()
        ctx.arc(sunX, sunY, sunR, 0, Double.pi * 2)
        ctx.fill()

        ctx.restore()
    }

    /// Sunflowers along the bottom — drawn behind the sheep
    func drawMidground(_ ctx: Canvas, _ w: Double, _ h: Double) {
        if !active { return }

        ctx.save()
        for f in sunflowers {
            let x = f.x * w
            let baseY = f.y * h
            let sway = sin((time / 1000) * f.swaySpeed + f.swayOffset) * 3
            let headX = x + sway
            let headY = baseY - f.size

            // Stem
            ctx.strokeStyle = "#4E7C31"
            ctx.lineWidth = 3
            ctx.beginPath()
            ctx.moveTo(x, baseY)
            ctx.quadraticCurveTo(x + sway * 0.5, baseY - f.size * 0.6, headX, headY)
            ctx.stroke()

            // Leaf
            ctx.fillStyle = "#5C9440"
            ctx.beginPath()
            ctx.ellipse(x + 6, baseY - f.size * 0.45, 7, 3.5, 0.6, 0, Double.pi * 2)
            ctx.fill()

            // Petals
            ctx.fillStyle = "#FFC53D"
            let petalR = f.size * 0.34
            for n in 0..<10 {
                let i = Double(n)
                let angle = (i / 10) * Double.pi * 2
                ctx.beginPath()
                ctx.ellipse(
                    headX + cos(angle) * petalR,
                    headY + sin(angle) * petalR,
                    petalR * 0.6,
                    petalR * 0.3,
                    angle,
                    0,
                    Double.pi * 2
                )
                ctx.fill()
            }

            // Center
            ctx.fillStyle = "#6B4423"
            ctx.beginPath()
            ctx.arc(headX, headY, petalR * 0.55, 0, Double.pi * 2)
            ctx.fill()
        }
        ctx.restore()
    }

    /// Butterflies and drifting seeds — drawn on top of the sheep
    func drawForeground(_ ctx: Canvas, _ _w: Double, _ _h: Double) {
        if !active { return }

        ctx.save()

        // Seeds: tiny white tufts drifting on the breeze
        ctx.fillStyle = "rgba(255, 255, 255, 0.85)"
        ctx.strokeStyle = "rgba(255, 255, 255, 0.5)"
        ctx.lineWidth = 1
        for s in seeds {
            ctx.beginPath()
            ctx.arc(s.x, s.y, s.size * 0.6, 0, Double.pi * 2)
            ctx.fill()
            for n in 0..<4 {
                let i = Double(n)
                let angle = (i / 4) * Double.pi * 2 + s.swayOffset
                ctx.beginPath()
                ctx.moveTo(s.x, s.y)
                ctx.lineTo(s.x + cos(angle) * s.size * 2, s.y + sin(angle) * s.size * 2)
                ctx.stroke()
            }
        }

        // Butterflies: two flapping wings and a body
        for b in butterflies {
            let flap = abs(sin(b.wingPhase))
            let wingW = 6 * (0.35 + flap * 0.65)
            ctx.fillStyle = b.color
            ctx.beginPath()
            ctx.ellipse(b.x - wingW * 0.7, b.y, wingW, 5, -0.4, 0, Double.pi * 2)
            ctx.fill()
            ctx.beginPath()
            ctx.ellipse(b.x + wingW * 0.7, b.y, wingW, 5, 0.4, 0, Double.pi * 2)
            ctx.fill()
            ctx.fillStyle = "#3A2E20"
            ctx.beginPath()
            ctx.ellipse(b.x, b.y, 1.4, 4.5, 0, 0, Double.pi * 2)
            ctx.fill()
        }

        ctx.restore()
    }
}

let SUMMER_IDLE_QUIPS = [
    "Sun's out, wool's out.",
    "This is prime grazing weather.",
    "I could nap in this sun forever.",
    "Anyone else smell sunscreen?",
    "A butterfly landed on me. I'm chosen.",
    "Too hot for a wool coat. Can't take it off though.",
]

let SUNBATHE_QUIPS = [
    "Ahhh... sol.",
    "Someone flip me in ten minutes.",
    "I'm working on my wool tan.",
    "This is the life.",
    "Wake me when it's autumn.",
    "SPF? Never heard of her.",
]

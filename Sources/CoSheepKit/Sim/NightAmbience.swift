import CoreGraphics
import Foundation
import SpriteKit

// Ex-night-ambience.ts.
//
// Simulation (stars, fireflies, night-hours rule) is a straight port. Drawing
// is SpriteKit-native: the effect covers the whole screen every frame, which
// would force full-screen Canvas rasters. Instead each particle look is baked
// once into an SKTexture by running the *original Canvas draw code* through
// CGReplay, and every frame only node transforms / alpha / hidden flags change.
//
// Attach + render contract (see `attach(to:)`, `render(_:_:_:)`):
//   stars + moonlight   -> `scene.nightBackLayer`  (z -1000, behind everything)
//   fireflies + campfire glow -> `scene.nightFrontLayer` (z 1100, above the flock)

/// The `{ x, y, state }` records the Flock hands to `update`/`render`
/// (TS: `Array<{ x: number; y: number; state: SheepState }>`).
nonisolated struct SheepPosition: Equatable {
    var x: Double
    var y: Double
    var state: SheepState
}

/// Bakes Canvas draw code into a texture (used by NightAmbience/WeatherEffects).
enum EffectTexture {
    /// Runs `draw` against a scratch `Canvas` and rasterizes `rect` (canvas
    /// space, points) at `scale` pixels per point. The texture is
    /// bilinear-filtered so sub-pixel node positions read like canvas AA.
    static func bake(rect: CGRect, scale: Double, _ draw: (Canvas) -> Void) -> SKTexture? {
        let canvas = Canvas()
        canvas.beginFrame()
        draw(canvas)
        let ops = canvas.groups.flatMap(\.ops)
        guard !ops.isEmpty, let image = CGReplay.image(ops, rect: rect, scale: scale) else { return nil }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear
        return texture
    }
}

final class NightAmbience {
    struct Star {
        var x: Double
        var y: Double
        var twinkleSpeed: Double
    }

    struct Firefly {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var phase: Double
    }

    private(set) var stars: [Star] = []
    private(set) var fireflies: [Firefly] = []
    private var screenWidth: Double
    private var screenHeight: Double
    /// Milliseconds since creation (sum of `update` dts).
    private(set) var time: Double = 0

    // MARK: SpriteKit state (populated by `attach(to:)` / `render`)

    private weak var scene: OverlayScene?
    private var backingScale: Double = 2
    /// Owned containers inside the scene's night layers; hidden when it isn't night.
    let backRoot = SKNode()
    let frontRoot = SKNode()
    private(set) var starNodes: [SKSpriteNode] = []
    private(set) var moonNode: SKSpriteNode?
    private(set) var fireflyGlowNodes: [SKSpriteNode] = []
    private(set) var fireflyCoreNodes: [SKSpriteNode] = []
    private(set) var campfireNodes: [SKSpriteNode] = []
    private var starSmallTexture: SKTexture?
    private var starLargeTexture: SKTexture?
    private var moonTexture: SKTexture?
    private var moonBakedWidth: Double = -1
    private var fireflyGlowTexture: SKTexture?
    private var fireflyCoreTexture: SKTexture?
    private var campfireTexture: SKTexture?

    private static let starPad: Double = 1
    private static let fireflyGlowRadius: Double = 6
    private static let campfireRadius: Double = 80

    init(_ screenWidth: Double, _ screenHeight: Double) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        seedStars()
        backRoot.isHidden = true
        frontRoot.isHidden = true
    }

    private func seedStars() {
        stars = []
        for _ in 0..<35 {
            let x = SimRandom.next()
            let y = SimRandom.next() * 0.6 // upper 60% of screen
            let twinkleSpeed = 0.5 + SimRandom.next() * 2
            stars.append(Star(x: x, y: y, twinkleSpeed: twinkleSpeed))
        }
    }

    /// 0..1 night intensity for a local time of day in hours (fractional).
    static func nightAlpha(atHour h: Double) -> Double {
        if h >= 6 && h < 20 { return 0 } // daytime
        if h >= 20 && h < 22 { return (h - 20) / 2 } // ramp up
        if h >= 22 || h < 4 { return 1 } // full night
        // 4am–6am: ramp down
        return 1 - (h - 4) / 2
    }

    /// Returns 0..1 night intensity based on current hour (via `SimClock`)
    func getNightAlpha() -> Double {
        let parts = Calendar.current.dateComponents(
            [.hour, .minute], from: Date(timeIntervalSince1970: SimClock.nowMs() / 1000))
        let h = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        return Self.nightAlpha(atHour: h)
    }

    func update(_ dt: Double, _ sheepPositions: [SheepPosition]) {
        time += dt
        let nightAlpha = getNightAlpha()

        if nightAlpha <= 0 {
            fireflies = []
            return
        }

        // Spawn fireflies near calm sheep
        let calmStates: [SheepState] = [.idle, .sit, .sleep, .idleSleep, .idleCampfire, .idleCounting]
        let calmSheep = sheepPositions.filter { calmStates.contains($0.state) }

        if !calmSheep.isEmpty && fireflies.count < 6 && SimRandom.next() < 0.02 {
            let target = calmSheep[SimRandom.int(calmSheep.count)]
            let x = target.x + (SimRandom.next() - 0.5) * 80
            let y = target.y + (SimRandom.next() - 0.5) * 60
            let vx = (SimRandom.next() - 0.5) * 20
            let vy = (SimRandom.next() - 0.5) * 15
            let phase = SimRandom.next() * Double.pi * 2
            fireflies.append(Firefly(x: x, y: y, vx: vx, vy: vy, phase: phase))
        }

        // Update fireflies — random walk bounded near sheep
        let dtSec = dt / 1000
        var kept: [Firefly] = []
        kept.reserveCapacity(fireflies.count)
        for var f in fireflies {
            f.vx += (SimRandom.next() - 0.5) * 40 * dtSec
            f.vy += (SimRandom.next() - 0.5) * 30 * dtSec
            f.vx *= 0.95
            f.vy *= 0.95
            f.x += f.vx * dtSec
            f.y += f.vy * dtSec
            f.phase += dt / 400

            // Keep bounded on screen
            if f.x > -20 && f.x < screenWidth + 20 && f.y > -20 && f.y < screenHeight + 20 {
                kept.append(f)
            }
        }
        fireflies = kept
    }

    func updateScreenSize(_ w: Double, _ h: Double) {
        screenWidth = w
        screenHeight = h
        seedStars()
    }

    // MARK: - SpriteKit rendering

    /// Bake the particle textures and add this effect's node containers to
    /// `scene.nightBackLayer` (stars, moonlight) and `scene.nightFrontLayer`
    /// (fireflies, campfire glow). Idempotent: call it again (e.g. after
    /// `scene.backingScale` changes) to re-bake and re-parent.
    func attach(to scene: OverlayScene) {
        detach()
        self.scene = scene
        backingScale = scene.backingScale
        bakeTextures()
        scene.nightBackLayer.addChild(backRoot)
        scene.nightFrontLayer.addChild(frontRoot)
    }

    /// Remove all nodes from the scene (the sim keeps running).
    func detach() {
        backRoot.removeAllChildren()
        frontRoot.removeAllChildren()
        backRoot.removeFromParent()
        frontRoot.removeFromParent()
        starNodes = []
        moonNode = nil
        moonBakedWidth = -1
        fireflyGlowNodes = []
        fireflyCoreNodes = []
        campfireNodes = []
        scene = nil
    }

    private func bakeTextures() {
        // Stars: `ctx.fillStyle = "#ffffff"; ctx.fillRect(x, y, size, size)` (size 1 or 2),
        // baked at full alpha — the twinkle alpha is the node's alpha.
        let pad = Self.starPad
        for size in [1.0, 2.0] {
            let tex = EffectTexture.bake(
                rect: CGRect(x: -pad, y: -pad, width: size + pad * 2, height: size + pad * 2),
                scale: backingScale
            ) { ctx in
                ctx.fillStyle = "#ffffff"
                ctx.fillRect(0, 0, size, size)
            }
            if size == 1 { starSmallTexture = tex } else { starLargeTexture = tex }
        }

        // Fireflies: radial glow (r 6) + bright center (r 1.5), both drawn at the
        // firefly's pulse alpha — so two sprites per firefly, each at that alpha.
        let gr = Self.fireflyGlowRadius
        fireflyGlowTexture = EffectTexture.bake(
            rect: CGRect(x: -gr - 1, y: -gr - 1, width: gr * 2 + 2, height: gr * 2 + 2),
            scale: backingScale
        ) { ctx in
            let grad = ctx.createRadialGradient(0, 0, 0, 0, 0, gr)
            grad.addColorStop(0, "rgba(200, 255, 100, 1)")
            grad.addColorStop(1, "rgba(200, 255, 100, 0)")
            ctx.fillStyle = grad
            ctx.beginPath()
            ctx.arc(0, 0, gr, 0, Double.pi * 2)
            ctx.fill()
        }
        fireflyCoreTexture = EffectTexture.bake(
            rect: CGRect(x: -2.5, y: -2.5, width: 5, height: 5),
            scale: backingScale
        ) { ctx in
            ctx.fillStyle = "rgba(220, 255, 150, 1)"
            ctx.beginPath()
            ctx.arc(0, 0, 1.5, 0, Double.pi * 2)
            ctx.fill()
        }

        // Campfire glow: radial gradient (5 → 80) filled into a circle of r 80.
        let cr = Self.campfireRadius
        campfireTexture = EffectTexture.bake(
            rect: CGRect(x: -cr, y: -cr, width: cr * 2, height: cr * 2),
            scale: backingScale
        ) { ctx in
            let grad = ctx.createRadialGradient(0, 0, 5, 0, 0, cr)
            grad.addColorStop(0, "rgba(255, 150, 50, 1)")
            grad.addColorStop(1, "rgba(255, 150, 50, 0)")
            ctx.fillStyle = grad
            ctx.beginPath()
            ctx.arc(0, 0, cr, 0, Double.pi * 2)
            ctx.fill()
        }

        moonTexture = nil
        moonBakedWidth = -1
    }

    /// Moonlight glow: one big soft sprite. Depends only on the screen width
    /// (radius w * 0.4), so it is re-baked when that changes.
    private func bakeMoonIfNeeded(_ w: Double) {
        guard w > 0, w != moonBakedWidth else { return }
        moonBakedWidth = w
        let radius = w * 0.4
        let diameter = radius * 2
        // The glow is smooth: ~512px across is plenty and keeps memory small.
        let scale = min(backingScale, 512 / diameter)
        moonTexture = EffectTexture.bake(
            rect: CGRect(x: 0, y: 0, width: diameter, height: diameter), scale: scale
        ) { ctx in
            let grad = ctx.createRadialGradient(radius, radius, 10, radius, radius, radius)
            grad.addColorStop(0, "rgba(180, 200, 255, 1)")
            grad.addColorStop(1, "rgba(180, 200, 255, 0)")
            ctx.fillStyle = grad
            ctx.fillRect(0, 0, diameter, diameter)
        }
    }

    private func makeSprite(_ z: CGFloat) -> SKSpriteNode {
        let node = SKSpriteNode(texture: nil, color: .clear, size: .zero)
        node.zPosition = z
        node.isHidden = true
        return node
    }

    /// Per-frame sync of both night layers: stars + moonlight (back) and
    /// fireflies + campfire glow (front). Call once per frame after `update`,
    /// with the current screen size and the same sheep positions the Flock
    /// gave `update`. No-op until `attach(to:)`. Hides everything by daylight.
    func render(_ w: Double, _ h: Double, _ sheepPositions: [SheepPosition]? = nil) {
        let nightAlpha = getNightAlpha()
        syncBackground(w, h, nightAlpha)
        syncForeground(w, h, sheepPositions, nightAlpha)
    }

    /// Stars and moonlight only (ex-`drawBackground`; sits behind the flock).
    func renderBackground(_ w: Double, _ h: Double) {
        syncBackground(w, h, getNightAlpha())
    }

    /// Fireflies and campfire glow only (ex-`drawForeground`; sits above the flock).
    func renderForeground(_ w: Double, _ h: Double, _ sheepPositions: [SheepPosition]? = nil) {
        syncForeground(w, h, sheepPositions, getNightAlpha())
    }

    private func syncBackground(_ w: Double, _ h: Double, _ nightAlpha: Double) {
        guard let scene else { return }
        if nightAlpha <= 0 {
            backRoot.isHidden = true
            return
        }
        backRoot.isHidden = false

        // Stars
        while starNodes.count < stars.count {
            let node = makeSprite(0)
            backRoot.addChild(node)
            starNodes.append(node)
        }
        let t = time / 1000
        for (i, node) in starNodes.enumerated() {
            guard i < stars.count else {
                node.isHidden = true
                continue
            }
            let star = stars[i]
            let alpha = nightAlpha * (0.3 + 0.7 * abs(sin(t * star.twinkleSpeed)))
            let size: Double = 1 + (star.twinkleSpeed > 1.5 ? 1 : 0)
            let tex = size > 1 ? starLargeTexture : starSmallTexture
            if node.texture !== tex { node.texture = tex }
            let box = size + Self.starPad * 2
            node.size = CGSize(width: box, height: box)
            // fillRect(star.x * w, star.y * h, size, size): top-left anchored, so center = +size/2.
            node.position = scene.scenePoint(star.x * w + size / 2, star.y * h + size / 2)
            node.alpha = alpha
            node.isHidden = tex == nil
        }

        // Moonlight glow — subtle radial gradient top-right
        let moon: SKSpriteNode
        if let existing = moonNode {
            moon = existing
        } else {
            moon = makeSprite(1)
            backRoot.addChild(moon)
            moonNode = moon
            moonBakedWidth = -1
        }
        bakeMoonIfNeeded(w)
        if moon.texture !== moonTexture { moon.texture = moonTexture }
        moon.size = CGSize(width: w * 0.8, height: w * 0.8)
        moon.position = scene.scenePoint(w * 0.85, h * 0.08)
        // The bake is full-alpha; TS used `0.04 * nightAlpha` in the first color stop.
        moon.alpha = 0.04 * nightAlpha
        moon.isHidden = moonTexture == nil
    }

    private func syncForeground(_ w: Double, _ h: Double, _ sheepPositions: [SheepPosition]?,
                                _ nightAlpha: Double) {
        guard let scene else { return }
        if nightAlpha <= 0 {
            frontRoot.isHidden = true
            return
        }
        frontRoot.isHidden = false

        let t = time / 1000

        // Fireflies (glow z 0, bright center z 1)
        while fireflyGlowNodes.count < fireflies.count {
            let glow = makeSprite(0)
            let core = makeSprite(1)
            glow.texture = fireflyGlowTexture
            glow.size = CGSize(width: Self.fireflyGlowRadius * 2 + 2, height: Self.fireflyGlowRadius * 2 + 2)
            core.texture = fireflyCoreTexture
            core.size = CGSize(width: 5, height: 5)
            frontRoot.addChild(glow)
            frontRoot.addChild(core)
            fireflyGlowNodes.append(glow)
            fireflyCoreNodes.append(core)
        }
        for i in 0..<fireflyGlowNodes.count {
            let glow = fireflyGlowNodes[i]
            let core = fireflyCoreNodes[i]
            guard i < fireflies.count else {
                glow.isHidden = true
                core.isHidden = true
                continue
            }
            let f = fireflies[i]
            let pulse = 0.4 + 0.6 * abs(sin(f.phase))
            let alpha = nightAlpha * pulse
            let p = scene.scenePoint(f.x, f.y)
            glow.position = p
            core.position = p
            glow.alpha = alpha
            core.alpha = alpha
            glow.isHidden = glow.texture == nil
            core.isHidden = core.texture == nil
        }

        // Enhanced campfire glow at night
        var campfires: [SheepPosition] = []
        if let sheepPositions {
            for s in sheepPositions where s.state == .idleCampfire { campfires.append(s) }
        }
        while campfireNodes.count < campfires.count {
            let node = makeSprite(2)
            node.texture = campfireTexture
            node.size = CGSize(width: Self.campfireRadius * 2, height: Self.campfireRadius * 2)
            frontRoot.addChild(node)
            campfireNodes.append(node)
        }
        for (i, node) in campfireNodes.enumerated() {
            guard i < campfires.count else {
                node.isHidden = true
                continue
            }
            let s = campfires[i]
            let glowX = s.x + 96 + 10 // approximate campfire position
            let glowY = s.y + 76
            let flicker = 0.8 + 0.2 * sin(t * 3)
            node.position = scene.scenePoint(glowX, glowY)
            // The bake is full-alpha; TS used `0.08 * nightAlpha * flicker` in the first color stop.
            node.alpha = 0.08 * nightAlpha * flicker
            node.isHidden = node.texture == nil
        }
    }
}

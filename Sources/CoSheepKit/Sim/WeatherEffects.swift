import CoreGraphics
import Foundation
import SpriteKit

// Ex-weather-effects.ts.
//
// Simulation (particle arrays, spawn counts, speeds, sway) is a straight port.
// Drawing is SpriteKit-native: a raindrop / snowflake look is baked once into an
// SKTexture with the original Canvas code (see `EffectTexture`), and every frame
// only node position / rotation / scale / hidden flags change.
//
// Attach + render contract (see `attach(to:)`, `render()`):
//   rain / snow -> `scene.weatherLayer` (z 1000, above the flock)

final class WeatherEffects {
    struct Particle {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var life: Double
    }

    private(set) var particles: [Particle] = []
    private(set) var condition: String?

    // MARK: SpriteKit state

    private weak var scene: OverlayScene?
    /// Owned container inside `scene.weatherLayer`; hidden when there is nothing to show.
    let root = SKNode()
    private(set) var rainNodes: [SKSpriteNode] = []
    private(set) var snowNodes: [SKSpriteNode] = []
    private var rainTexture: SKTexture?
    private var snowTexture: SKTexture?

    // Raindrop: a 1pt stroke from the particle down 6pt; the texture is padded
    // so bilinear sampling at sub-pixel positions has room to blur like canvas AA.
    private static let rainRect = CGRect(x: -2, y: -1, width: 4, height: 8)
    /// Where the stroke's start point sits inside the texture (SK anchor: origin bottom-left).
    private static let rainAnchor = CGPoint(x: 0.5, y: 1 - 1.0 / 8.0)
    // Snowflake: circle baked at its max radius (2); per-frame radius is applied as node scale.
    private static let snowMaxRadius: Double = 2
    private static let snowRect = CGRect(x: -3, y: -3, width: 6, height: 6)

    init() {
        root.isHidden = true
    }

    func setCondition(_ c: String?) {
        if c == condition { return }
        condition = c
        particles = []
    }

    func update(_ dt: Double, _ screenW: Double, _ screenH: Double) {
        guard let condition, !condition.isEmpty, condition != "clear", condition != "cloudy" else { return }

        let dtSec = dt / 1000

        if condition == "rain" {
            // Spawn rain particles
            while particles.count < 50 {
                let x = SimRandom.next() * screenW
                let y = -10 - SimRandom.next() * 50
                let vx = -20 + SimRandom.next() * 10 // slight wind
                let vy = 300 + SimRandom.next() * 200
                let life = SimRandom.next() * Double.pi * 2
                particles.append(Particle(x: x, y: y, vx: vx, vy: vy, life: life))
            }
        } else if condition == "snow" {
            while particles.count < 30 {
                let x = SimRandom.next() * screenW
                let y = -10 - SimRandom.next() * 30
                let vy = 20 + SimRandom.next() * 40
                // Random phase so flakes get distinct sway and twinkle
                let life = SimRandom.next() * Double.pi * 2
                particles.append(Particle(x: x, y: y, vx: 0, vy: vy, life: life))
            }
        }

        // Update particles
        for i in particles.indices {
            var p = particles[i]
            p.x += p.vx * dtSec
            p.y += p.vy * dtSec
            p.life += dtSec // drives per-particle sway phase and twinkle

            // Snow: horizontal sine drift
            if condition == "snow" {
                p.vx = sin(p.y / 60 + p.life * 10) * 15
            }

            // Recycle particles that exit the bottom
            if p.y > screenH + 10 {
                p.y = -10
                p.x = SimRandom.next() * screenW
                particles[i] = p
                continue
            }
            if p.x < -20 || p.x > screenW + 20 {
                p.x = SimRandom.next() * screenW
                p.y = -10
            }
            particles[i] = p
        }
    }

    // MARK: - SpriteKit rendering

    /// Bake the raindrop / snowflake textures and add the node container to
    /// `scene.weatherLayer`. Idempotent: call it again (e.g. after
    /// `scene.backingScale` changes) to re-bake and re-parent.
    func attach(to scene: OverlayScene) {
        detach()
        self.scene = scene
        let scale = scene.backingScale

        // ctx.strokeStyle = "rgba(130, 170, 255, 0.4)"; ctx.lineWidth = 1;
        // moveTo(p.x, p.y); lineTo(p.x + p.vx * 0.01, p.y + 6)   (baked with p = origin, vx = 0;
        // the tiny per-particle slant is applied as node rotation in `render`)
        rainTexture = EffectTexture.bake(rect: Self.rainRect, scale: scale) { ctx in
            ctx.strokeStyle = "rgba(130, 170, 255, 0.4)"
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(0, 0)
            ctx.lineTo(0, 6)
            ctx.stroke()
        }

        // ctx.fillStyle = "rgba(255, 255, 255, 0.7)"; arc(p.x, p.y, size, 0, 2π)
        snowTexture = EffectTexture.bake(rect: Self.snowRect, scale: scale) { ctx in
            ctx.fillStyle = "rgba(255, 255, 255, 0.7)"
            ctx.beginPath()
            ctx.arc(0, 0, Self.snowMaxRadius, 0, Double.pi * 2)
            ctx.fill()
        }

        scene.weatherLayer.addChild(root)
    }

    /// Remove all nodes from the scene (the sim keeps running).
    func detach() {
        root.removeAllChildren()
        root.removeFromParent()
        rainNodes = []
        snowNodes = []
        scene = nil
    }

    /// Per-frame sync (ex-`draw(ctx)`): maps each particle to a pooled sprite.
    /// Call once per frame after `update`. No-op until `attach(to:)`; hides
    /// everything when there is no rain/snow to show.
    func render() {
        guard let scene else { return }
        guard let condition, !particles.isEmpty else {
            root.isHidden = true
            return
        }

        if condition == "rain" {
            root.isHidden = false
            while rainNodes.count < particles.count {
                let node = SKSpriteNode(texture: rainTexture, color: .clear,
                                        size: Self.rainRect.size)
                node.anchorPoint = Self.rainAnchor
                node.isHidden = true
                root.addChild(node)
                rainNodes.append(node)
            }
            for (i, node) in rainNodes.enumerated() {
                guard i < particles.count else {
                    node.isHidden = true
                    continue
                }
                let p = particles[i]
                node.position = scene.scenePoint(p.x, p.y)
                // The stroke runs (p.vx * 0.01, +6) in y-down canvas space; the baked
                // drop points straight down, so tilt it about its start point.
                node.zRotation = atan2(p.vx * 0.01, 6)
                node.isHidden = rainTexture == nil
            }
            for node in snowNodes { node.isHidden = true }
        } else if condition == "snow" {
            root.isHidden = false
            while snowNodes.count < particles.count {
                let node = SKSpriteNode(texture: snowTexture, color: .clear,
                                        size: Self.snowRect.size)
                node.isHidden = true
                root.addChild(node)
                snowNodes.append(node)
            }
            for (i, node) in snowNodes.enumerated() {
                guard i < particles.count else {
                    node.isHidden = true
                    continue
                }
                let p = particles[i]
                let size = 1.5 + sin(p.life * 5) * 0.5
                node.position = scene.scenePoint(p.x, p.y)
                node.setScale(size / Self.snowMaxRadius)
                node.isHidden = snowTexture == nil
            }
            for node in rainNodes { node.isHidden = true }
        } else {
            // Other conditions (fog, …) never had a draw branch.
            root.isHidden = true
        }
    }
}

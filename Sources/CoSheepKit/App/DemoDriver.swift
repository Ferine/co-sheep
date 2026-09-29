import Foundation

/// TEMPORARY foundation smoke test (deleted in the glue phase): a sprite
/// sheep walking along the bottom of the screen with a canvas-drawn bubble,
/// exercising sprites, tint, flip, paths, gradients, shadow and text.
final class DemoDriver: OverlayDriver {
    private let walk = SpriteSheet("/assets/sprites/sheep-walk.png", 32, 32, 4, 6)
    private let idle = SpriteSheet("/assets/sprites/sheep-idle.png", 32, 32, 2, 2)
    private var x: Double = 100
    private var vx: Double = 0.08
    private let screen: ScreenSize
    var bounds: [CGRect] = []

    init(screen: ScreenSize) { self.screen = screen }

    private var frames = 0
    func update(dt: Double) {
        frames += 1
        if frames % 120 == 1 { Log.info("demo", "frame \(frames) dt=\(Int(dt)) main=\(Thread.isMainThread)") }
        walk.update(dt)
        idle.update(dt)
        x += vx * dt
        if x > screen.width - 200 || x < 50 { vx = -vx }
    }

    func draw(_ c: Canvas) {
        let size = 96.0
        let y = screen.height - size - 10
        c.group("demo:sheep") {
            walk.draw(c, x, y, 3, vx < 0)
            c.save()
            c.fillStyle = "#e94560"
            c.beginPath()
            c.arc(x + size / 2, y - 6, 4, 0, .pi * 2)
            c.fill()
            c.restore()
        }
        c.group("demo:friend") {
            idle.draw(c, 700, y, 3, false, FRIEND_TINTS[.pink])
            let g = c.createRadialGradient(700 + 48, y + 48, 0, 700 + 48, y + 48, 70)
            g.addColorStop(0, "rgba(255, 200, 100, 0.35)")
            g.addColorStop(1, "rgba(255, 200, 100, 0)")
            c.fillStyle = g
            c.fillRect(700 - 30, y - 30, 156, 156)
        }
        c.group("demo:bubble", layer: .overlay) {
            let bx = x - 40, by = y - 70, bw = 180.0, bh = 44.0
            c.save()
            c.shadowColor = "rgba(0, 0, 0, 0.3)"
            c.shadowBlur = 12
            c.shadowOffsetY = 4
            c.fillStyle = "#1a1a2e"
            c.beginPath()
            c.roundRect(bx, by, bw, bh, 12)
            c.fill()
            c.restore()
            c.strokeStyle = "#e94560"
            c.lineWidth = 2
            c.beginPath()
            c.roundRect(bx, by, bw, bh, 12)
            c.stroke()
            c.fillStyle = "#eee"
            c.font = "14px 'Courier New', monospace"
            c.fillText("Baaa. Swift now? 🐑", bx + 16, by + 27)
        }
        bounds = [CGRect(x: x, y: y, width: size, height: size)]
    }
}

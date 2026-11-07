import SpriteKit

/// What the scene drives each frame (ex-`gameLoop`: update, then draw).
protocol OverlayDriver: AnyObject {
    /// `dt` in milliseconds.
    func update(dt: Double)
    func draw(_ ctx: Canvas)
    /// Mouse input, in canvas coordinates (top-left origin, y down).
    func mouseDown(x: Double, y: Double, clickCount: Int)
    func mouseDragged(x: Double, y: Double)
    func mouseUp(x: Double, y: Double, clickCount: Int)
    func mouseMoved(x: Double, y: Double)
    func rightMouseDown(x: Double, y: Double)
}

extension OverlayDriver {
    func mouseDown(x: Double, y: Double, clickCount: Int) {}
    func mouseDragged(x: Double, y: Double) {}
    func mouseUp(x: Double, y: Double, clickCount: Int) {}
    func mouseMoved(x: Double, y: Double) {}
    func rightMouseDown(x: Double, y: Double) {}
}

/// SpriteKit host: runs the loop, composites Canvas tiles, and exposes
/// z-banded parents for SK-native effects (see plan: z-order bands).
final class OverlayScene: SKScene {
    let canvas = Canvas()
    let tiles = CanvasTileLayer()
    /// z -1000: night sky (stars, moonlight).
    let nightBackLayer = SKNode()
    /// z 1000: rain / snow.
    let weatherLayer = SKNode()
    /// z 1100: fireflies, campfire glow.
    let nightFrontLayer = SKNode()

    weak var driver: OverlayDriver?
    var backingScale: Double = 2
    private var lastTime: TimeInterval = 0

    override init(size: CGSize) {
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        anchorPoint = .zero
        nightBackLayer.zPosition = -1000
        weatherLayer.zPosition = 1000
        nightFrontLayer.zPosition = 1100
        tiles.zPosition = 0
        for n in [nightBackLayer, tiles, weatherLayer, nightFrontLayer] { addChild(n) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Canvas (y-down) → scene (y-up) point, for SK-native effect nodes.
    func scenePoint(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x, y: size.height - y)
    }

    func canvasPoint(_ p: CGPoint) -> (x: Double, y: Double) {
        (Double(p.x), Double(size.height - p.y))
    }

    /// The longest step the sim takes in one frame. The TS loop fed the raw
    /// delta through, so the first frame after display sleep, a lock screen or
    /// a stall was one step of minutes: sheep teleported, timed states and
    /// cooldowns elapsed in a single tick.
    nonisolated static let MAX_FRAME_MS = 100.0

    /// Milliseconds to step for a frame at `currentTime` (seconds) after one at
    /// `lastTime` (0 = no frame yet: 16ms, like the TS loop's first frame).
    nonisolated static func frameDelta(currentTime: TimeInterval, lastTime: TimeInterval) -> Double {
        if lastTime == 0 { return 16 }
        return min(max(0, (currentTime - lastTime) * 1000), MAX_FRAME_MS)
    }

    override func update(_ currentTime: TimeInterval) {
        let dt = Self.frameDelta(currentTime: currentTime, lastTime: lastTime)
        lastTime = currentTime
        driver?.update(dt: dt)
        canvas.beginFrame()
        driver?.draw(canvas)
        tiles.sync(canvas.groups, viewport: CGRect(origin: .zero, size: size), scale: backingScale)
    }

    // MARK: Mouse → driver (canvas coordinates)

    private func point(_ event: NSEvent) -> (x: Double, y: Double) {
        canvasPoint(event.location(in: self))
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        driver?.mouseDown(x: p.x, y: p.y, clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        driver?.mouseDragged(x: p.x, y: p.y)
    }

    override func mouseUp(with event: NSEvent) {
        let p = point(event)
        driver?.mouseUp(x: p.x, y: p.y, clickCount: event.clickCount)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        driver?.mouseMoved(x: p.x, y: p.y)
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = point(event)
        driver?.rightMouseDown(x: p.x, y: p.y)
    }
}

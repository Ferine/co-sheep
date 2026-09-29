import Foundation

/// Ex-sprite.ts: a horizontal strip of animation frames drawn through `Canvas`.
final class SpriteSheet {
    private static var imageCache: [String: CanvasImage] = [:]

    private let image: CanvasImage?
    private let frameWidth: Double
    private let frameHeight: Double
    private let frameCount: Int
    private(set) var currentFrame = 0
    private var frameTimer: Double = 0
    private let frameDuration: Double

    /// `src` accepts the web path ("/assets/sprites/sheep-idle.png") or a
    /// resource path ("sprites/sheep-idle.png").
    init(_ src: String, _ frameWidth: Double, _ frameHeight: Double, _ frameCount: Int, _ fps: Double = 4) {
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.frameCount = frameCount
        self.frameDuration = 1000 / fps
        self.image = SpriteSheet.load(src)
    }

    private static func load(_ src: String) -> CanvasImage? {
        if let cached = imageCache[src] { return cached }
        var path = src
        if path.hasPrefix("/") { path.removeFirst() }
        if path.hasPrefix("assets/") { path.removeFirst("assets/".count) }
        guard let cg = ResourceFiles.cgImage(path) else {
            Log.info("sprite", "error: missing sprite \(src)")
            return nil
        }
        let img = CanvasImage(cg)
        imageCache[src] = img
        return img
    }

    func update(_ dt: Double) {
        frameTimer += dt
        if frameTimer >= frameDuration {
            frameTimer -= frameDuration
            currentFrame = (currentFrame + 1) % frameCount
        }
    }

    func draw(_ ctx: Canvas, _ x: Double, _ y: Double, _ scale: Double, _ flipX: Bool = false, _ tint: String? = nil) {
        guard let image else {
            // Fallback: draw a simple sheep shape
            drawFallback(ctx, x, y, scale)
            return
        }

        let w = frameWidth * scale
        let h = frameHeight * scale
        let sx = Double(currentFrame) * frameWidth

        ctx.save()
        if flipX {
            ctx.translate(x + w, y)
            ctx.scale(-1, 1)
        }
        let dx = flipX ? 0 : x
        let dy = flipX ? 0 : y
        if let tint {
            ctx.drawImageTinted(image, sx, 0, frameWidth, frameHeight, dx, dy, w, h, tint: tint)
        } else {
            ctx.drawImage(image, sx, 0, frameWidth, frameHeight, dx, dy, w, h)
        }
        ctx.restore()
    }

    private func drawFallback(_ ctx: Canvas, _ x: Double, _ y: Double, _ scale: Double) {
        let w = frameWidth * scale
        let h = frameHeight * scale

        ctx.save()

        // Body (fluffy white)
        ctx.fillStyle = "#f5f5f5"
        ctx.beginPath()
        ctx.ellipse(x + w * 0.5, y + h * 0.55, w * 0.35, h * 0.3, 0, 0, .pi * 2)
        ctx.fill()
        ctx.strokeStyle = "#ccc"
        ctx.lineWidth = 2
        ctx.stroke()

        // Head
        ctx.fillStyle = "#333"
        ctx.beginPath()
        ctx.ellipse(x + w * 0.72, y + h * 0.38, w * 0.14, h * 0.16, 0, 0, .pi * 2)
        ctx.fill()

        // Eye
        ctx.fillStyle = "#fff"
        ctx.beginPath()
        ctx.arc(x + w * 0.76, y + h * 0.35, w * 0.04, 0, .pi * 2)
        ctx.fill()
        ctx.fillStyle = "#000"
        ctx.beginPath()
        ctx.arc(x + w * 0.77, y + h * 0.35, w * 0.02, 0, .pi * 2)
        ctx.fill()

        // Legs
        ctx.fillStyle = "#333"
        ctx.fillRect(x + w * 0.3, y + h * 0.78, w * 0.08, h * 0.2)
        ctx.fillRect(x + w * 0.45, y + h * 0.78, w * 0.08, h * 0.2)
        ctx.fillRect(x + w * 0.55, y + h * 0.78, w * 0.08, h * 0.2)
        ctx.fillRect(x + w * 0.65, y + h * 0.78, w * 0.08, h * 0.2)

        ctx.restore()
    }

    func reset() {
        currentFrame = 0
        frameTimer = 0
    }
}

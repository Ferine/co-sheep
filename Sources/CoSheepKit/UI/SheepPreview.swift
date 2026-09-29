import CoreGraphics
import Foundation

/// The Wardrobe's sheep preview, drawn through the real Canvas pipeline
/// (idle sprite + `createCompositeOverlay`) and replayed into a bitmap by
/// `CGReplay`, so it shows exactly what the overlay will draw.
enum SheepPreview {
    /// Preview size in points. The page's canvas was 200×120 with the sheep
    /// at (55, 15); a little more headroom keeps tall hats (wizard hat,
    /// antenna) from being clipped.
    static let size = CGSize(width: 200, height: 130)
    static let origin = CGPoint(x: 55, y: 24)
    /// 32px sprite × 3.
    static let displaySize = Sheep.DISPLAY_SIZE

    /// The recorded draw ops for a sheep wearing `accessories`.
    static func ops(accessories: [String]) -> [DrawOp] {
        let canvas = Canvas()
        let sprite = SpriteSheet("sprites/sheep-idle.png", 32, 32, 2, 2)
        canvas.group("wardrobe:preview") {
            canvas.imageSmoothingEnabled = false
            sprite.draw(canvas, origin.x, origin.y, Sheep.SCALE, false)
            if let overlay = createCompositeOverlay(accessories) {
                overlay(canvas, origin.x, origin.y, displaySize, true, .idle)
            }
        }
        return canvas.groups.first?.ops ?? []
    }

    /// The preview bitmap at `scale` pixels per point.
    static func image(accessories: [String], scale: Double) -> CGImage? {
        CGReplay.image(
            ops(accessories: accessories),
            rect: CGRect(origin: .zero, size: size), scale: scale)
    }
}

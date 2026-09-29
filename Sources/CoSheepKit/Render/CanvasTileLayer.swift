import CoreGraphics
import SpriteKit

/// Turns each frame's `CanvasGroup`s into textured `SKSpriteNode`s: bbox →
/// CoreGraphics raster at backing scale → texture. A group whose ops are
/// identical to last frame's is left untouched (no raster, no upload).
final class CanvasTileLayer: SKNode {
    private final class Tile {
        let node = SKSpriteNode()
        var ops: [DrawOp] = []
        var rect: CGRect = .null
        var context: CGContext?
        var contextPixels = (w: 0, h: 0)

        init() {
            node.anchorPoint = CGPoint(x: 0, y: 1)
            node.blendMode = .alpha
        }
    }

    static let worldZBase: CGFloat = 0
    static let overlayZBase: CGFloat = 2000

    private var tiles: [String: Tile] = [:]
    private(set) var rasterizedLastFrame = 0

    /// - Parameters:
    ///   - viewport: visible canvas-space rect (the screen); tiles are clipped to it.
    ///   - scale: backing scale factor (pixels per point).
    func sync(_ groups: [CanvasGroup], viewport: CGRect, scale: Double) {
        var seen = Set<String>()
        var rasterized = 0
        var worldIndex = 0
        var overlayIndex = 0

        for group in groups {
            seen.insert(group.key)
            let tile: Tile
            if let t = tiles[group.key] {
                tile = t
            } else {
                tile = Tile()
                tiles[group.key] = tile
                addChild(tile.node)
            }

            switch group.layer {
            case .world:
                tile.node.zPosition = Self.worldZBase + CGFloat(min(worldIndex, 999))
                worldIndex += 1
            case .overlay:
                tile.node.zPosition = Self.overlayZBase + CGFloat(overlayIndex)
                overlayIndex += 1
            }

            if group.ops == tile.ops, tile.node.texture != nil || group.ops.isEmpty { continue }
            tile.ops = group.ops

            let rect = Self.snap(group.bounds.intersection(viewport), scale: scale)
            guard !rect.isNull, rect.width >= 1 / scale, rect.height >= 1 / scale else {
                tile.node.isHidden = true
                tile.node.texture = nil
                continue
            }

            let px = CGReplay.pixelSize(rect, scale: scale)
            if tile.context == nil || tile.contextPixels != px {
                tile.context = CGReplay.makeBitmap(pixelWidth: px.w, pixelHeight: px.h)
                tile.contextPixels = px
            }
            guard let ctx = tile.context else { continue }
            CGReplay.renderTile(group.ops, in: ctx, rect: rect, scale: scale)
            guard let image = ctx.makeImage() else { continue }

            let texture = SKTexture(cgImage: image)
            texture.filteringMode = .nearest
            tile.node.texture = texture
            tile.node.size = rect.size
            tile.node.position = CGPoint(x: rect.minX, y: viewport.maxY - rect.minY)
            tile.node.isHidden = false
            tile.rect = rect
            rasterized += 1
        }

        for (key, tile) in tiles where !seen.contains(key) {
            tile.node.removeFromParent()
            tiles[key] = nil
        }
        rasterizedLastFrame = rasterized
    }

    /// Expand to whole device pixels so textures map 1:1 onto the screen.
    static func snap(_ r: CGRect, scale: Double) -> CGRect {
        guard !r.isNull, !r.isEmpty else { return .null }
        let minX = (r.minX * scale).rounded(.down) / scale
        let minY = (r.minY * scale).rounded(.down) / scale
        let maxX = (r.maxX * scale).rounded(.up) / scale
        let maxY = (r.maxY * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

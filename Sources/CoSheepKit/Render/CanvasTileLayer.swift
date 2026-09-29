import CoreGraphics
import SpriteKit

/// Turns each frame's `CanvasGroup`s into textured `SKSpriteNode`s: bbox →
/// CoreGraphics raster at backing scale → texture. A group whose ops are
/// identical to last frame's is left untouched (no raster, no upload).
///
/// Rasters are RGBA (premultipliedLast) so `SKTexture(cgImage:)` can take the
/// pixels without a vImage format conversion. (An `SKMutableTexture` rewritten
/// in place was tried and rejected: its row order was inconsistent between
/// headless and on-screen rendering.)
final class CanvasTileLayer: SKNode {
    private final class Tile {
        let node = SKSpriteNode()
        var ops: [DrawOp] = []
        var rect: CGRect = .null
        var context: CGContext?
        var contextPixels = (w: 0, h: 0)
        var scale: Double = 0
        var anchored = false

        init() {
            node.anchorPoint = CGPoint(x: 0, y: 1)
            node.blendMode = .alpha
        }
    }

    static let worldZBase: CGFloat = 0
    static let overlayZBase: CGFloat = 2000

    private var tiles: [String: Tile] = [:]
    private(set) var rasterizedLastFrame = 0
    /// Device pixels rasterized in the last `sync` (perf regression tests).
    private(set) var rasterizedPixelsLastFrame = 0
    // Debug stats (CO_SHEEP_DEBUG): per-key raster counts + pixel area.
    private var statFrames = 0
    private var statRasters: [String: Int] = [:]
    private var statPixels = 0

    /// - Parameters:
    ///   - viewport: visible canvas-space rect (the screen); tiles are clipped to it.
    ///   - scale: backing scale factor (pixels per point).
    func sync(_ groups: [CanvasGroup], viewport: CGRect, scale: Double) {
        var seen = Set<String>()
        var rasterized = 0
        var pixels = 0
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

            let anchor = group.anchor ?? .zero
            let unchanged = group.ops == tile.ops && tile.scale == scale
                && tile.anchored == (group.anchor != nil) && (tile.node.texture != nil || group.ops.isEmpty)
            if !unchanged {
                tile.ops = group.ops
                tile.scale = scale
                tile.anchored = group.anchor != nil
                // Anchored content may move without re-rasterizing, so clip it
                // generously (a screen's margin) rather than to the viewport.
                let clip = group.anchor == nil
                    ? viewport
                    : viewport.insetBy(dx: -viewport.width, dy: -viewport.height).offsetBy(dx: -anchor.x, dy: -anchor.y)
                let rect = Self.snap(group.bounds.intersection(clip), scale: scale)
                guard !rect.isNull, rect.width >= 1 / scale, rect.height >= 1 / scale else {
                    tile.node.isHidden = true
                    tile.node.texture = nil
                    tile.rect = .null
                    continue
                }

                let px = CGReplay.pixelSize(rect, scale: scale)
                if tile.context == nil || tile.contextPixels != px {
                    tile.context = CGReplay.makeBitmap(pixelWidth: px.w, pixelHeight: px.h)
                    tile.contextPixels = px
                }
                guard let ctx = tile.context else { continue }
                CGReplay.renderTile(group.ops, in: ctx, rect: rect, scale: scale)
                pixels += px.w * px.h
                if Log.isDebug {
                    statRasters[group.key, default: 0] += 1
                    statPixels += px.w * px.h
                }
                guard let image = ctx.makeImage() else { continue }
                let texture = SKTexture(cgImage: image)
                texture.filteringMode = .nearest
                tile.node.texture = texture
                tile.node.size = rect.size
                tile.node.isHidden = false
                tile.rect = rect
                rasterized += 1
            }
            guard !tile.rect.isNull else { continue }
            // Position every frame — anchored tiles follow their anchor,
            // snapped to device pixels so textures map 1:1.
            let ox = ((anchor.x + tile.rect.minX) * scale).rounded() / scale
            let oy = ((anchor.y + tile.rect.minY) * scale).rounded() / scale
            tile.node.position = CGPoint(x: ox, y: viewport.maxY - oy)
        }

        for (key, tile) in tiles where !seen.contains(key) {
            tile.node.removeFromParent()
            tiles[key] = nil
        }
        rasterizedLastFrame = rasterized
        rasterizedPixelsLastFrame = pixels
        if Log.isDebug {
            statFrames += 1
            if statFrames == 300 {
                let top = statRasters.sorted { $0.value > $1.value }.prefix(8)
                    .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                Log.debug("render", "300f: tiles=\(tiles.count) rasters=\(statRasters.values.reduce(0, +)) px/f=\(statPixels / 300) [\(top)]")
                statFrames = 0
                statRasters.removeAll()
                statPixels = 0
            }
        }
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

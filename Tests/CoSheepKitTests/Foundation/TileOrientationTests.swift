import AppKit
import CoreGraphics
import SpriteKit
import Testing
@testable import CoSheepKit

/// Regression: text and images must render upright, both in a standalone
/// replay and through a tile shown in a real SKView. (Fills alone are
/// symmetric about the flip and hid a mirrored-glyph bug.)
@Suite("tile orientation")
struct TileOrientationTests {
    /// 1×2 image: top pixel red, bottom pixel blue.
    private func redOverBlue() throws -> CanvasImage {
        let ctx = try #require(CGContext(data: nil, width: 1, height: 2, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGReplay.colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 1, width: 1, height: 1)) // CG y=1 is the top row
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return CanvasImage(try #require(ctx.makeImage()))
    }

    private func pattern(_ c: Canvas) throws {
        let img = try redOverBlue()
        c.beginFrame()
        c.group("t") {
            c.fillStyle = "#000"
            c.fillRect(0, 0, 40, 80)
            c.imageSmoothingEnabled = false
            c.drawImage(img, 0, 0, 1, 2, 0, 0, 20, 40)      // image in the top-left 20×40
            c.fillStyle = "#fff"
            c.font = "bold 30px monospace"
            c.fillText("_", 20, 30)                          // underscore sits just above y=30
        }
    }

    /// (topIsRed, textInTopHalf) for an RGBA image, y from the top.
    private func probe(_ img: CGImage) -> (Bool, Bool) {
        let rep = NSBitmapImageRep(cgImage: img)
        let s = Double(img.width) / 40
        let top = rep.colorAt(x: Int(10 * s), y: Int(5 * s))!
        var textTop = false
        for y in 0..<Int(40 * s) {
            if let p = rep.colorAt(x: Int(30 * s), y: y), p.brightnessComponent > 0.8 { textTop = true }
        }
        return (top.redComponent > 0.5 && top.blueComponent < 0.5, textTop)
    }

    @Test func replayDrawsImagesAndTextUpright() throws {
        let c = Canvas()
        try pattern(c)
        let img = try #require(CGReplay.image(c.groups[0].ops, rect: CGRect(x: 0, y: 0, width: 40, height: 80), scale: 2))
        let (topRed, textTop) = probe(img)
        #expect(topRed, "image drawn upside down")
        #expect(textTop, "text drawn in the wrong half / mirrored")
    }

    @Test func tileDrawsImagesAndTextUprightInAScene() throws {
        let size = CGSize(width: 40, height: 80)
        let view = SKView(frame: CGRect(origin: .zero, size: size))
        let scene = SKScene(size: size)
        scene.anchorPoint = .zero
        scene.backgroundColor = .gray
        let tiles = CanvasTileLayer()
        scene.addChild(tiles)
        view.presentScene(scene)
        let c = Canvas()
        try pattern(c)
        tiles.sync(c.groups, viewport: CGRect(origin: .zero, size: size), scale: 1)
        let first = try #require(view.texture(from: scene)?.cgImage())
        let (topRed1, textTop1) = probe(first)
        #expect(topRed1, "first raster: image drawn upside down")
        #expect(textTop1, "first raster: text drawn in the wrong half / mirrored")
        // Again on the reused context/texture.
        try pattern(c)
        // Force a re-raster on the same tile with a change that can't affect the probes.
        c.group("t") { c.fillStyle = "#000"; c.fillRect(39, 79, 1, 1) }
        tiles.sync(c.groups, viewport: CGRect(origin: .zero, size: size), scale: 1)
        let shot = try #require(view.texture(from: scene)?.cgImage())
        let (topRed, textTop) = probe(shot)
        #expect(topRed, "re-raster: image drawn upside down")
        #expect(textTop, "re-raster: text drawn in the wrong half / mirrored")
    }
}

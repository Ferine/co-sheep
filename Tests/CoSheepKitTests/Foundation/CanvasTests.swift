import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

@Suite("css color")
struct CSSColorTests {
    @Test func hexForms() {
        #expect(CSSColor.parse("#fff") == RGBA(r: 1, g: 1, b: 1, a: 1))
        #expect(CSSColor.parse("#FF0000") == RGBA(r: 1, g: 0, b: 0, a: 1))
        #expect(CSSColor.parse("#00000080")?.a == Double(0x80) / 255)
        #expect(CSSColor.parse("#f008")?.a == Double(0x88) / 255)
        #expect(CSSColor.parse("#ggg") == nil)
    }

    @Test func rgbForms() {
        #expect(CSSColor.parse("rgba(255, 255, 255, 0.8)") == RGBA(r: 1, g: 1, b: 1, a: 0.8))
        #expect(CSSColor.parse("rgb(0,0,0)") == .black)
        #expect(CSSColor.parse("rgb(255 0 0 / 50%)") == RGBA(r: 1, g: 0, b: 0, a: 0.5))
        #expect(CSSColor.parse("rgba(220, 255, 150, 0.35)")?.a == 0.35)
    }

    @Test func hslForms() {
        let c = CSSColor.parse("hsl(0, 100%, 50%)")!
        #expect(abs(c.r - 1) < 1e-9 && abs(c.g) < 1e-9 && abs(c.b) < 1e-9)
        let t = CSSColor.parse("hsla(210, 70%, 65%, 0.35)")!
        #expect(t.a == 0.35)
        #expect(t.b > t.g && t.g > t.r)
    }

    @Test func namedColors() {
        #expect(CSSColor.parse("white") == RGBA(r: 1, g: 1, b: 1, a: 1))
        #expect(CSSColor.parse("transparent")?.a == 0)
        #expect(CSSColor.parse("notacolor") == nil)
    }
}

@Suite("css font")
struct CSSFontTests {
    @Test func shorthand() {
        let f = CSSFont.parse("bold 12px monospace")!
        #expect(f.size == 12 && f.bold && !f.italic && f.family == "Courier")
        #expect(CSSFont.parse("14px serif")?.family == "Times")
        #expect(CSSFont.parse("14px 'Courier New', monospace")?.family == "Courier New")
        #expect(CSSFont.parse("italic 700 9px sans-serif")?.italic == true)
        #expect(CSSFont.parse("nonsense") == nil)
    }
}

@Suite("canvas")
struct CanvasTests {
    @Test func invalidAssignmentsAreIgnored() {
        let c = Canvas()
        c.fillStyle = "#123456"
        c.fillStyle = "garbage"
        #expect(c.fillStyle as? String == "#123456")
        c.font = "bold 12px monospace"
        c.font = "wat"
        #expect(c.font == "bold 12px monospace")
        c.globalAlpha = 0.5
        c.globalAlpha = 2
        #expect(c.globalAlpha == 0.5)
    }

    @Test func saveRestoreRestoresState() {
        let c = Canvas()
        c.save()
        c.fillStyle = "#fff"
        c.translate(10, 10)
        c.restore()
        #expect(c.fillStyle as? String == "#000000")
        c.beginFrame()
        c.fillRect(0, 0, 1, 1)
        #expect(c.groups[0].ops[0].ctm == .identity)
    }

    @Test func groupsOrderAndDefaultGroup() {
        let c = Canvas()
        c.beginFrame()
        c.fillRect(0, 0, 1, 1)
        c.group("b") { c.fillRect(0, 0, 1, 1) }
        c.group("bubble", layer: .overlay) { c.fillRect(0, 0, 1, 1) }
        c.group("b") { c.fillRect(1, 1, 1, 1) }
        #expect(c.groups.map(\.key) == ["_default", "b", "bubble"])
        #expect(c.groups[1].ops.count == 2)
        #expect(c.groups[2].layer == .overlay)
        c.beginFrame()
        #expect(c.groups.isEmpty)
    }

    @Test func boundsFollowTransforms() {
        let c = Canvas()
        c.beginFrame()
        c.save()
        c.translate(100, 50)
        c.scale(2, 2)
        c.fillRect(0, 0, 10, 5)
        c.restore()
        let b = c.groups[0].bounds
        #expect(b == CGRect(x: 100, y: 50, width: 20, height: 10))
    }

    @Test func strokeBoundsIncludeLineWidth() {
        let c = Canvas()
        c.beginFrame()
        c.lineWidth = 4
        c.lineJoin = "round"
        c.beginPath()
        c.moveTo(10, 10)
        c.lineTo(20, 10)
        c.stroke()
        let b = c.groups[0].bounds
        #expect(b.minY <= 8 && b.maxY >= 12)
    }

    @Test func fullCircleSweepsClamp() {
        #expect(Canvas.normalizedSweep(0, .pi * 4, false) == (0, .pi * 2))
        #expect(Canvas.normalizedSweep(0, -.pi * 3, true) == (0, -.pi * 2))
        #expect(Canvas.normalizedSweep(1, 2, false) == (1, 2))
        // A whole turn "the other way" is still a full circle (WebKit).
        #expect(Canvas.normalizedSweep(0.5, 0.5 + .pi * 2, true) == (0.5, 0.5 - .pi * 2))
        #expect(Canvas.normalizedSweep(0.5, 0.5 - .pi * 2, false) == (0.5, 0.5 + .pi * 2))
    }

    @Test func rectLeavesTheCurrentPointAtItsOrigin() {
        let c = Canvas()
        c.beginFrame()
        c.beginPath()
        c.roundRect(10, 10, 20, 20, 4)
        c.lineTo(100, 10)          // spec: from (10, 10), not from the arc start
        c.stroke()
        guard case let .stroke(path, _, _) = c.groups[0].ops[0].kind else {
            Issue.record("expected a stroke op")
            return
        }
        var elements: [(CGPathElementType, CGPoint)] = []
        path.applyWithBlock { e in
            elements.append((e.pointee.type, e.pointee.type == .closeSubpath ? .zero : e.pointee.points[0]))
        }
        let tail = elements.suffix(2)
        #expect(tail.first?.0 == .moveToPoint && tail.first?.1 == CGPoint(x: 10, y: 10))
        #expect(tail.last?.0 == .addLineToPoint && tail.last?.1 == CGPoint(x: 100, y: 10))
    }

    @Test func arcAndEllipseBounds() {
        let c = Canvas()
        c.beginFrame()
        c.beginPath()
        c.arc(50, 50, 10, 0, .pi * 2)
        c.fill()
        c.beginPath()
        c.ellipse(200, 100, 20, 5, 0, 0, .pi * 2)
        c.fill()
        let a = c.groups[0].ops[0].bounds
        let e = c.groups[0].ops[1].bounds
        #expect(abs(a.minX - 40) < 0.01 && abs(a.maxY - 60) < 0.01)
        #expect(abs(e.width - 40) < 0.01 && abs(e.height - 10) < 0.01)
    }

    @Test func identicalFramesProduceEqualOps() {
        let c = Canvas()
        func frame() -> [DrawOp] {
            c.beginFrame()
            c.group("s") {
                c.fillStyle = "#abc"
                c.beginPath()
                c.arc(10, 10, 5, 0, .pi)
                c.fill()
                c.fillText("hi", 0, 0)
            }
            return c.groups[0].ops
        }
        #expect(frame() == frame())
    }

    @Test func replayRendersPixels() throws {
        let c = Canvas()
        c.beginFrame()
        c.fillStyle = "#ff0000"
        c.fillRect(0, 0, 10, 10)
        c.fillStyle = "rgba(0, 0, 255, 1)"
        c.fillRect(10, 0, 10, 10)
        let img = try #require(CGReplay.image(c.groups[0].ops, rect: CGRect(x: 0, y: 0, width: 20, height: 10), scale: 2))
        #expect(img.width == 40 && img.height == 20)
        let px = pixels(img)
        // Top-left quadrant red, right half blue (y-down canvas → top rows of the image).
        #expect(px(5, 5) == (255, 0, 0, 255))
        #expect(px(30, 15) == (0, 0, 255, 255))
    }

    @Test func tintOnlyColorsOpaquePixels() throws {
        // 2x1 image: left opaque white, right transparent.
        let ctx = try #require(CGReplay.makeBitmap(pixelWidth: 2, pixelHeight: 1))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let src = CanvasImage(try #require(ctx.makeImage()))
        let c = Canvas()
        c.beginFrame()
        c.imageSmoothingEnabled = false
        c.drawImageTinted(src, 0, 0, 2, 1, 0, 0, 2, 1, tint: "rgba(255, 0, 0, 1)")
        let img = try #require(CGReplay.image(c.groups[0].ops, rect: CGRect(x: 0, y: 0, width: 2, height: 1), scale: 1))
        let px = pixels(img)
        #expect(px(0, 0) == (255, 0, 0, 255))
        #expect(px(1, 0).3 == 0)
    }

    /// RGBA8 (unpremultiplied for opaque pixels) sampler, y from the top.
    private func pixels(_ img: CGImage) -> (Int, Int) -> (Int, Int, Int, Int) {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGReplay.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return { x, y in
            let i = (y * w + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
        }
    }
}

@Suite("json value")
struct JSONValueTests {
    @Test func roundTrips() throws {
        let src = #"{"a":1,"b":[true,null,"x"],"c":{"d":1.5}}"#
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(src.utf8))
        #expect(v["a"]?.doubleValue == 1)
        #expect(v["c"]?["d"]?.doubleValue == 1.5)
        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
        #expect(again == v)
    }
}

@Suite("canvas anchors")
struct CanvasAnchorTests {
    private func frame(_ c: Canvas, at x: Double, _ y: Double) -> [DrawOp] {
        c.beginFrame()
        c.group("s", anchor: CGPoint(x: x, y: y)) {
            // Absolute-coordinate drawing, like Sheep.draw.
            c.fillStyle = "#abc"
            c.beginPath()
            c.arc(x + 62.4, y + 11.7, 5, 0, .pi * 2)
            c.fill()
            c.fillText("Fluffy", x + 10, y + 90)
            // translate()-positioned drawing, like the flipped sprite.
            c.save()
            c.translate(x + 96, y)
            c.scale(-1, 1)
            c.fillRect(0, 0, 3, 3)
            c.restore()
        }
        return c.groups[0].ops
    }

    @Test func pureMotionKeepsOpsEqual() {
        let c = Canvas()
        let a = frame(c, at: 100.3, 200.7)
        let b = frame(c, at: 517.9, 13.1)
        #expect(a == b)
    }

    @Test func realChangeStillDiffers() {
        let c = Canvas()
        let a = frame(c, at: 100, 200)
        c.beginFrame()
        c.group("s", anchor: CGPoint(x: 100, y: 200)) {
            c.fillStyle = "#abd"
            c.beginPath()
            c.arc(162.4, 211.7, 5, 0, .pi * 2)
            c.fill()
        }
        #expect(a != c.groups[0].ops)
    }

    @Test func anchoredBoundsAreRelative() {
        let c = Canvas()
        c.beginFrame()
        c.group("s", anchor: CGPoint(x: 1000, y: 500)) { c.fillRect(1010, 520, 4, 4) }
        #expect(c.groups[0].bounds == CGRect(x: 10, y: 20, width: 4, height: 4))
    }
}

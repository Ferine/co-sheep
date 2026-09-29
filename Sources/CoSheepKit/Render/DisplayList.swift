import CoreGraphics
import CoreText
import Foundation

nonisolated struct GradientStop: Equatable {
    var offset: Double
    var color: RGBA
}

/// A resolved paint snapshot (gradients are captured at draw time, like Canvas).
nonisolated enum Paint: Equatable {
    case color(RGBA)
    case linear(x0: Double, y0: Double, x1: Double, y1: Double, stops: [GradientStop])
    case radial(x0: Double, y0: Double, r0: Double, x1: Double, y1: Double, r1: Double, stops: [GradientStop])

    /// Solid color used where a gradient can't apply (text).
    var solidFallback: RGBA {
        switch self {
        case .color(let c): c
        case .linear(_, _, _, _, let stops), .radial(_, _, _, _, _, _, let stops): stops.first?.color ?? .black
        }
    }
}

nonisolated struct StrokeParams: Equatable {
    var lineWidth: Double
    var lineCap: CGLineCap
    var lineJoin: CGLineJoin
    var miterLimit: Double
}

nonisolated struct ShadowParams: Equatable {
    var blur: Double
    var color: RGBA
    var offsetX: Double
    var offsetY: Double
}

nonisolated enum TextAlign: String, Equatable {
    case start, end, left, right, center
}

nonisolated enum TextBaseline: String, Equatable {
    case alphabetic, top, hanging, middle, ideographic, bottom
}

/// One recorded Canvas draw call. Geometry is stored in user space together
/// with the transform in effect at draw time (`ctm`), which reproduces
/// Canvas2D semantics for gradients and stroke widths under transforms.
struct DrawOp: Equatable {
    enum Kind: Equatable {
        case fill(CGPath, Paint, evenOdd: Bool)
        case stroke(CGPath, Paint, StrokeParams)
        case text(String, CSSFont, x: Double, y: Double, align: TextAlign, baseline: TextBaseline, Paint)
        case image(CGImage, dst: CGRect, smoothing: Bool, tint: RGBA?)
        case clear(CGPath)
    }

    var kind: Kind
    var ctm: CGAffineTransform
    var alpha: Double
    var shadow: ShadowParams?

    /// Canvas-space (device-independent) bounds, including stroke/shadow bleed.
    var bounds: CGRect {
        var r: CGRect
        switch kind {
        case .fill(let p, _, _), .clear(let p):
            r = p.boundingBoxOfPath.applying(ctm)
        case .stroke(let p, _, let s):
            let scale = max(hypot(ctm.a, ctm.b), hypot(ctm.c, ctm.d))
            let bleed = s.lineWidth * scale * (s.lineJoin == .miter ? max(1, s.miterLimit / 2) : 1) / 2 + 1
            r = p.boundingBoxOfPath.applying(ctm).insetBy(dx: -bleed, dy: -bleed)
        case .text(let text, let font, let x, let y, let align, let baseline, _):
            r = TextGeometry.box(text, font, x: x, y: y, align: align, baseline: baseline).applying(ctm)
        case .image(_, let dst, _, _):
            r = dst.applying(ctm)
        }
        if let s = shadow {
            let spread = s.blur * 2 + 1
            let moved = r.offsetBy(dx: s.offsetX, dy: s.offsetY).insetBy(dx: -spread, dy: -spread)
            r = r.union(moved)
        }
        return r
    }
}

enum TextGeometry {
    /// Horizontal offset from the anchor x for a given alignment (LTR).
    static func alignOffset(_ width: Double, _ align: TextAlign) -> Double {
        switch align {
        case .start, .left: 0
        case .center: -width / 2
        case .end, .right: -width
        }
    }

    /// Offset from the anchor y to the alphabetic baseline (y-down).
    static func baselineOffset(_ font: CSSFont, _ baseline: TextBaseline) -> Double {
        let ct = font.ctFont
        let ascent = Double(CTFontGetAscent(ct))
        let descent = Double(CTFontGetDescent(ct))
        switch baseline {
        case .alphabetic, .ideographic: return 0
        case .top, .hanging: return ascent
        case .middle: return (ascent - descent) / 2
        case .bottom: return -descent
        }
    }

    /// Loose user-space box around the rendered glyphs.
    static func box(_ text: String, _ font: CSSFont, x: Double, y: Double,
                    align: TextAlign, baseline: TextBaseline) -> CGRect {
        let line = TextLines.line(text, font)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = Double(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let bx = x + alignOffset(width, align)
        let by = y + baselineOffset(font, baseline)
        // Emoji and italic glyphs overhang their advance a bit.
        let pad = font.size * 0.25
        return CGRect(x: bx - pad, y: by - Double(ascent) - pad,
                      width: width + pad * 2, height: Double(ascent + descent) + pad * 2)
    }
}

nonisolated enum CanvasLayer: Equatable {
    /// Scene content, z 0…999 in draw order.
    case world
    /// Above SK-native weather/night effects (speech bubbles), z 2000+.
    case overlay
}

/// The ops recorded for one tile this frame.
final class CanvasGroup {
    let key: String
    let layer: CanvasLayer
    let order: Int
    var ops: [DrawOp] = []

    init(key: String, layer: CanvasLayer, order: Int) {
        self.key = key
        self.layer = layer
        self.order = order
    }

    var bounds: CGRect {
        ops.reduce(CGRect.null) { $0.union($1.bounds) }
    }
}

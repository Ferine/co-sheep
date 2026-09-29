import CoreGraphics
import CoreText
import Foundation

/// Replays recorded Canvas ops into a CoreGraphics context whose user space
/// is canvas space (y-down points). `deviceScale` is the pixels-per-point of
/// the context's base space (shadow blur is specified in base space).
enum CGReplay {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A premultiplied RGBA bitmap context (identity CTM, pixel space) —
    /// the layout SpriteKit textures use natively.
    static func makeBitmap(pixelWidth w: Int, pixelHeight h: Int) -> CGContext? {
        CGContext(
            data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: max(1, w) * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
    }

    static func pixelSize(_ rect: CGRect, scale: Double) -> (w: Int, h: Int) {
        (max(1, Int((rect.width * scale).rounded())), max(1, Int((rect.height * scale).rounded())))
    }

    /// Clear the whole bitmap, then replay `ops` with `rect` (canvas space)
    /// mapped onto its pixels at `scale`, y flipped so canvas coordinates apply.
    static func renderTile(_ ops: [DrawOp], in ctx: CGContext, rect: CGRect, scale: Double) {
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.saveGState()
        prepare(ctx, rect: rect, scale: scale, pixelHeight: ctx.height)
        render(ops, in: ctx, deviceScale: scale)
        ctx.restoreGState()
    }

    static func prepare(_ ctx: CGContext, rect: CGRect, scale: Double, pixelHeight: Int) {
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
    }

    static func render(_ ops: [DrawOp], in ctx: CGContext, deviceScale: Double) {
        for op in ops { render(op, in: ctx, deviceScale: deviceScale) }
    }

    static func render(_ op: DrawOp, in ctx: CGContext, deviceScale: Double) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(op.alpha)
        var layered = false
        if let s = op.shadow {
            // Offsets are in base space, whose y axis is up.
            ctx.setShadow(offset: CGSize(width: s.offsetX * deviceScale, height: -s.offsetY * deviceScale),
                          blur: s.blur * deviceScale, color: s.color.cgColor)
            if case .fill(_, let paint, _) = op.kind, paint != .color(paint.solidFallback) {
                // Gradient fills clip, which would clip the shadow away —
                // composite through a transparency layer instead.
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                layered = true
            }
        }
        ctx.concatenate(op.ctm)

        switch op.kind {
        case let .fill(path, paint, evenOdd):
            ctx.addPath(path)
            fill(ctx, paint: paint, evenOdd: evenOdd)

        case let .stroke(path, paint, params):
            ctx.addPath(path)
            ctx.setLineWidth(params.lineWidth)
            ctx.setLineCap(params.lineCap)
            ctx.setLineJoin(params.lineJoin)
            ctx.setMiterLimit(params.miterLimit)
            if case .color(let c) = paint {
                ctx.setStrokeColor(c.cgColor)
                ctx.strokePath()
            } else {
                ctx.replacePathWithStrokedPath()
                fill(ctx, paint: paint, evenOdd: false)
            }

        case let .text(text, font, x, y, align, baseline, paint):
            let line = TextLines.line(text, font)
            let width = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.setFillColor(paint.solidFallback.cgColor)
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: x + TextGeometry.alignOffset(width, align),
                                       y: y + TextGeometry.baselineOffset(font, baseline))
            CTLineDraw(line, ctx)

        case let .image(image, dst, smoothing, tint):
            ctx.interpolationQuality = smoothing ? .high : .none
            ctx.translateBy(x: dst.minX, y: dst.maxY)
            ctx.scaleBy(x: 1, y: -1)
            let local = CGRect(x: 0, y: 0, width: dst.width, height: dst.height)
            if let tint {
                ctx.beginTransparencyLayer(in: local, auxiliaryInfo: nil)
                ctx.draw(image, in: local)
                ctx.setBlendMode(.sourceAtop)
                ctx.setFillColor(tint.cgColor)
                ctx.fill(local)
                ctx.endTransparencyLayer()
            } else {
                ctx.draw(image, in: local)
            }

        case let .clear(path):
            ctx.setBlendMode(.clear)
            ctx.addPath(path)
            ctx.fillPath()
        }

        if layered { ctx.endTransparencyLayer() }
    }

    /// Fill the context's current path with a solid or gradient paint.
    private static func fill(_ ctx: CGContext, paint: Paint, evenOdd: Bool) {
        let rule: CGPathFillRule = evenOdd ? .evenOdd : .winding
        switch paint {
        case .color(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fillPath(using: rule)
        case let .linear(x0, y0, x1, y1, stops):
            guard let g = gradient(stops) else { ctx.beginPath(); return }
            ctx.clip(using: rule)
            ctx.drawLinearGradient(g, start: CGPoint(x: x0, y: y0), end: CGPoint(x: x1, y: y1),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case let .radial(x0, y0, r0, x1, y1, r1, stops):
            guard let g = gradient(stops) else { ctx.beginPath(); return }
            ctx.clip(using: rule)
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: x0, y: y0), startRadius: r0,
                                   endCenter: CGPoint(x: x1, y: y1), endRadius: r1,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    private static func gradient(_ stops: [GradientStop]) -> CGGradient? {
        guard !stops.isEmpty else { return nil }
        let s = stops.count == 1 ? [stops[0], GradientStop(offset: 1, color: stops[0].color)] : stops
        return CGGradient(colorsSpace: colorSpace, colors: s.map(\.color.cgColor) as CFArray,
                          locations: s.map { CGFloat($0.offset) })
    }

    /// Render ops into a standalone image of `rect` (e.g. Capture Moment).
    static func image(_ ops: [DrawOp], rect: CGRect, scale: Double) -> CGImage? {
        let px = pixelSize(rect, scale: scale)
        guard let ctx = makeBitmap(pixelWidth: px.w, pixelHeight: px.h) else { return nil }
        renderTile(ops, in: ctx, rect: rect, scale: scale)
        return ctx.makeImage()
    }
}

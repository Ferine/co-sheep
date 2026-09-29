import CoreGraphics
import CoreText
import Foundation

/// Anything assignable to `fillStyle` / `strokeStyle`: a CSS color string
/// or a gradient — so ported code keeps `c.fillStyle = "#fff"` verbatim.
protocol CanvasPaint {}
extension String: CanvasPaint {}

/// ex-CanvasGradient. Stops may be added after assignment; the paint is
/// snapshotted when a fill/stroke is recorded.
final class CanvasGradient: CanvasPaint {
    enum Geometry: Equatable {
        case linear(Double, Double, Double, Double)
        case radial(Double, Double, Double, Double, Double, Double)
    }

    let geometry: Geometry
    private(set) var stops: [GradientStop] = []

    init(_ geometry: Geometry) { self.geometry = geometry }

    func addColorStop(_ offset: Double, _ color: String) {
        guard let c = CSSColor.parse(color) else { return }
        stops.append(GradientStop(offset: min(1, max(0, offset)), color: c))
        stops.sort { $0.offset < $1.offset }
    }

    var paint: Paint {
        switch geometry {
        case let .linear(x0, y0, x1, y1): .linear(x0: x0, y0: y0, x1: x1, y1: y1, stops: stops)
        case let .radial(x0, y0, r0, x1, y1, r1): .radial(x0: x0, y0: y0, r0: r0, x1: x1, y1: y1, r1: r1, stops: stops)
        }
    }
}

struct TextMetrics {
    var width: Double
}

/// Canvas2D-shaped immediate-mode API (y-down, points). Draw calls are
/// recorded into per-frame `CanvasGroup`s, then rasterized by
/// `CanvasTileLayer` (or `CGReplay` directly, e.g. for Capture Moment).
///
/// Like a real canvas, drawing state persists across frames; only the
/// recorded groups reset at `beginFrame()`.
final class Canvas {
    private enum PaintSource {
        case solid(RGBA)
        case gradient(CanvasGradient)

        var snapshot: Paint {
            switch self {
            case .solid(let c): .color(c)
            case .gradient(let g): g.paint
            }
        }
    }

    private struct State {
        var transform: CGAffineTransform = .identity
        var fill: PaintSource = .solid(.black)
        var fillRaw: any CanvasPaint = "#000000"
        var stroke: PaintSource = .solid(.black)
        var strokeRaw: any CanvasPaint = "#000000"
        var lineWidth: Double = 1
        var lineCap: CGLineCap = .butt
        var lineJoin: CGLineJoin = .miter
        var miterLimit: Double = 10
        var globalAlpha: Double = 1
        var font: CSSFont = .default
        var fontRaw = "10px sans-serif"
        var textAlign: TextAlign = .start
        var textBaseline: TextBaseline = .alphabetic
        var shadowBlur: Double = 0
        var shadowColor: RGBA = .transparent
        var shadowColorRaw = "rgba(0, 0, 0, 0)"
        var shadowOffsetX: Double = 0
        var shadowOffsetY: Double = 0
        var imageSmoothingEnabled = true
        var composite = "source-over"
    }

    private var state = State()
    private var stack: [State] = []
    /// Current path, in canvas space (points already transformed, as Canvas does).
    private var path = CGMutablePath()

    private(set) var groups: [CanvasGroup] = []
    private var groupIndex: [String: CanvasGroup] = [:]
    private var groupStack: [CanvasGroup] = []
    private var warnedComposite = Set<String>()

    // MARK: Frame / groups

    func beginFrame() {
        groups.removeAll(keepingCapacity: true)
        groupIndex.removeAll(keepingCapacity: true)
        groupStack.removeAll()
    }

    /// Route everything drawn in `body` into the tile `key`. Groups are
    /// z-ordered by first use within their layer; reusing a key appends.
    func group(_ key: String, layer: CanvasLayer = .world, _ body: () -> Void) {
        groupStack.append(obtainGroup(key, layer: layer))
        body()
        groupStack.removeLast()
    }

    private func obtainGroup(_ key: String, layer: CanvasLayer) -> CanvasGroup {
        if let g = groupIndex[key] { return g }
        let g = CanvasGroup(key: key, layer: layer, order: groups.count)
        groups.append(g)
        groupIndex[key] = g
        return g
    }

    private func record(_ kind: DrawOp.Kind) {
        let alpha = state.globalAlpha
        guard alpha > 0 else { return }
        var shadow: ShadowParams?
        if state.shadowColor.a > 0, state.shadowBlur > 0 || state.shadowOffsetX != 0 || state.shadowOffsetY != 0 {
            shadow = ShadowParams(blur: state.shadowBlur, color: state.shadowColor,
                                  offsetX: state.shadowOffsetX, offsetY: state.shadowOffsetY)
        }
        if state.composite != "source-over", !warnedComposite.contains(state.composite) {
            warnedComposite.insert(state.composite)
            Log.debug("canvas", "globalCompositeOperation '\(state.composite)' not supported; using source-over")
        }
        let target = groupStack.last ?? obtainGroup("_default", layer: .world)
        target.ops.append(DrawOp(kind: kind, ctm: state.transform, alpha: alpha, shadow: shadow))
    }

    // MARK: State

    func save() { stack.append(state) }
    func restore() { if let s = stack.popLast() { state = s } }

    var fillStyle: any CanvasPaint {
        get { state.fillRaw }
        set {
            if let g = newValue as? CanvasGradient { state.fill = .gradient(g); state.fillRaw = g }
            else if let s = newValue as? String, let c = CSSColor.parse(s) { state.fill = .solid(c); state.fillRaw = s }
        }
    }

    var strokeStyle: any CanvasPaint {
        get { state.strokeRaw }
        set {
            if let g = newValue as? CanvasGradient { state.stroke = .gradient(g); state.strokeRaw = g }
            else if let s = newValue as? String, let c = CSSColor.parse(s) { state.stroke = .solid(c); state.strokeRaw = s }
        }
    }

    var lineWidth: Double {
        get { state.lineWidth }
        set { if newValue > 0, newValue.isFinite { state.lineWidth = newValue } }
    }

    var lineCap: String {
        get { switch state.lineCap { case .round: "round"; case .square: "square"; default: "butt" } }
        set {
            switch newValue {
            case "round": state.lineCap = .round
            case "square": state.lineCap = .square
            case "butt": state.lineCap = .butt
            default: break
            }
        }
    }

    var lineJoin: String {
        get { switch state.lineJoin { case .round: "round"; case .bevel: "bevel"; default: "miter" } }
        set {
            switch newValue {
            case "round": state.lineJoin = .round
            case "bevel": state.lineJoin = .bevel
            case "miter": state.lineJoin = .miter
            default: break
            }
        }
    }

    var miterLimit: Double {
        get { state.miterLimit }
        set { if newValue > 0 { state.miterLimit = newValue } }
    }

    var globalAlpha: Double {
        get { state.globalAlpha }
        set { if newValue.isFinite, newValue >= 0, newValue <= 1 { state.globalAlpha = newValue } }
    }

    var font: String {
        get { state.fontRaw }
        set { if let f = CSSFont.parse(newValue) { state.font = f; state.fontRaw = newValue } }
    }

    var textAlign: String {
        get { state.textAlign.rawValue }
        set { if let a = TextAlign(rawValue: newValue) { state.textAlign = a } }
    }

    var textBaseline: String {
        get { state.textBaseline.rawValue }
        set { if let b = TextBaseline(rawValue: newValue) { state.textBaseline = b } }
    }

    var shadowBlur: Double {
        get { state.shadowBlur }
        set { if newValue >= 0, newValue.isFinite { state.shadowBlur = newValue } }
    }

    var shadowColor: String {
        get { state.shadowColorRaw }
        set { if let c = CSSColor.parse(newValue) { state.shadowColor = c; state.shadowColorRaw = newValue } }
    }

    var shadowOffsetX: Double {
        get { state.shadowOffsetX }
        set { state.shadowOffsetX = newValue }
    }

    var shadowOffsetY: Double {
        get { state.shadowOffsetY }
        set { state.shadowOffsetY = newValue }
    }

    var imageSmoothingEnabled: Bool {
        get { state.imageSmoothingEnabled }
        set { state.imageSmoothingEnabled = newValue }
    }

    var globalCompositeOperation: String {
        get { state.composite }
        set { state.composite = newValue }
    }

    // MARK: Transforms

    func translate(_ x: Double, _ y: Double) {
        state.transform = CGAffineTransform(translationX: x, y: y).concatenating(state.transform)
    }

    func rotate(_ angle: Double) {
        state.transform = CGAffineTransform(rotationAngle: angle).concatenating(state.transform)
    }

    func scale(_ x: Double, _ y: Double) {
        state.transform = CGAffineTransform(scaleX: x, y: y).concatenating(state.transform)
    }

    func setTransform(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
        state.transform = CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
    }

    func resetTransform() { state.transform = .identity }

    // MARK: Paths (points are transformed at insertion time, like Canvas)

    func beginPath() { path = CGMutablePath() }

    func moveTo(_ x: Double, _ y: Double) {
        path.move(to: CGPoint(x: x, y: y), transform: state.transform)
    }

    func lineTo(_ x: Double, _ y: Double) {
        if path.isEmpty { moveTo(x, y); return }
        path.addLine(to: CGPoint(x: x, y: y), transform: state.transform)
    }

    func quadraticCurveTo(_ cpx: Double, _ cpy: Double, _ x: Double, _ y: Double) {
        if path.isEmpty { moveTo(cpx, cpy) }
        path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cpx, y: cpy), transform: state.transform)
    }

    func bezierCurveTo(_ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double, _ x: Double, _ y: Double) {
        if path.isEmpty { moveTo(c1x, c1y) }
        path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y),
                      control2: CGPoint(x: c2x, y: c2y), transform: state.transform)
    }

    /// Canvas `arc`: angles increase clockwise on screen (y-down), which is
    /// increasing angle in CG math too — so `clockwise: counterclockwise`.
    func arc(_ x: Double, _ y: Double, _ radius: Double, _ startAngle: Double, _ endAngle: Double,
             _ counterclockwise: Bool = false) {
        guard radius >= 0 else { return }
        let (s, e) = Canvas.normalizedSweep(startAngle, endAngle, counterclockwise)
        path.addArc(center: CGPoint(x: x, y: y), radius: radius, startAngle: s, endAngle: e,
                    clockwise: counterclockwise, transform: state.transform)
    }

    func ellipse(_ x: Double, _ y: Double, _ radiusX: Double, _ radiusY: Double, _ rotation: Double,
                 _ startAngle: Double, _ endAngle: Double, _ counterclockwise: Bool = false) {
        guard radiusX >= 0, radiusY >= 0 else { return }
        let (s, e) = Canvas.normalizedSweep(startAngle, endAngle, counterclockwise)
        let t = CGAffineTransform(scaleX: max(radiusX, 1e-9), y: max(radiusY, 1e-9))
            .concatenating(CGAffineTransform(rotationAngle: rotation))
            .concatenating(CGAffineTransform(translationX: x, y: y))
            .concatenating(state.transform)
        path.addArc(center: .zero, radius: 1, startAngle: s, endAngle: e, clockwise: counterclockwise, transform: t)
    }

    /// Canvas draws a full circle when the sweep covers ≥ 2π in the drawing
    /// direction; CG would reduce the angles modulo 2π, so clamp explicitly.
    static func normalizedSweep(_ start: Double, _ end: Double, _ ccw: Bool) -> (Double, Double) {
        let tau = Double.pi * 2
        if !ccw, end - start >= tau { return (start, start + tau) }
        if ccw, start - end >= tau { return (start, start - tau) }
        return (start, end)
    }

    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        path.addRect(CGRect(x: x, y: y, width: w, height: h), transform: state.transform)
    }

    func roundRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ radius: Double) {
        let r = CGRect(x: x, y: y, width: w, height: h).standardized
        let rr = max(0, min(radius, min(r.width, r.height) / 2))
        path.addRoundedRect(in: r, cornerWidth: rr, cornerHeight: rr, transform: state.transform)
    }

    func closePath() { if !path.isEmpty { path.closeSubpath() } }

    // MARK: Drawing

    /// Current path mapped back into the current user space.
    private func userPath(_ canvasPath: CGPath) -> CGPath? {
        let t = state.transform
        if t.isIdentity { return canvasPath }
        guard abs(t.a * t.d - t.b * t.c) > 1e-12 else { return nil }
        var inv = t.inverted()
        return canvasPath.copy(using: &inv)
    }

    func fill(_ rule: String = "nonzero") {
        guard !path.isEmpty, let p = userPath(path) else { return }
        record(.fill(p, state.fill.snapshot, evenOdd: rule == "evenodd"))
    }

    func stroke() {
        guard !path.isEmpty, let p = userPath(path) else { return }
        record(.stroke(p, state.stroke.snapshot, strokeParams))
    }

    private var strokeParams: StrokeParams {
        StrokeParams(lineWidth: state.lineWidth, lineCap: state.lineCap,
                     lineJoin: state.lineJoin, miterLimit: state.miterLimit)
    }

    func fillRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        guard w != 0, h != 0 else { return }
        record(.fill(CGPath(rect: CGRect(x: x, y: y, width: w, height: h).standardized, transform: nil),
                     state.fill.snapshot, evenOdd: false))
    }

    func strokeRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        record(.stroke(CGPath(rect: CGRect(x: x, y: y, width: w, height: h).standardized, transform: nil),
                       state.stroke.snapshot, strokeParams))
    }

    func clearRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        let saved = state.globalAlpha
        state.globalAlpha = 1
        record(.clear(CGPath(rect: CGRect(x: x, y: y, width: w, height: h).standardized, transform: nil)))
        state.globalAlpha = saved
    }

    func fillText(_ text: String, _ x: Double, _ y: Double) {
        guard !text.isEmpty else { return }
        record(.text(text, state.font, x: x, y: y, align: state.textAlign,
                     baseline: state.textBaseline, state.fill.snapshot))
    }

    func measureText(_ text: String) -> TextMetrics {
        TextMetrics(width: TextLines.width(text, state.font))
    }

    func createLinearGradient(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> CanvasGradient {
        CanvasGradient(.linear(x0, y0, x1, y1))
    }

    func createRadialGradient(_ x0: Double, _ y0: Double, _ r0: Double,
                              _ x1: Double, _ y1: Double, _ r1: Double) -> CanvasGradient {
        CanvasGradient(.radial(x0, y0, r0, x1, y1, r1))
    }

    /// `drawImage(img, sx, sy, sw, sh, dx, dy, dw, dh)`.
    func drawImage(_ image: CanvasImage, _ sx: Double, _ sy: Double, _ sw: Double, _ sh: Double,
                   _ dx: Double, _ dy: Double, _ dw: Double, _ dh: Double) {
        guard let crop = image.crop(CGRect(x: sx, y: sy, width: sw, height: sh)) else { return }
        record(.image(crop, dst: CGRect(x: dx, y: dy, width: dw, height: dh),
                      smoothing: state.imageSmoothingEnabled, tint: nil))
    }

    /// `drawImage(img, dx, dy)` / `drawImage(img, dx, dy, dw, dh)`.
    func drawImage(_ image: CanvasImage, _ dx: Double, _ dy: Double, _ dw: Double? = nil, _ dh: Double? = nil) {
        record(.image(image.cgImage, dst: CGRect(x: dx, y: dy, width: dw ?? Double(image.width),
                                                 height: dh ?? Double(image.height)),
                      smoothing: state.imageSmoothingEnabled, tint: nil))
    }

    /// Sprite tinting (ex-offscreen canvas + `source-atop` fill in sprite.ts):
    /// the tint only colors the image's own opaque pixels.
    func drawImageTinted(_ image: CanvasImage, _ sx: Double, _ sy: Double, _ sw: Double, _ sh: Double,
                         _ dx: Double, _ dy: Double, _ dw: Double, _ dh: Double, tint: String) {
        guard let crop = image.crop(CGRect(x: sx, y: sy, width: sw, height: sh)) else { return }
        record(.image(crop, dst: CGRect(x: dx, y: dy, width: dw, height: dh),
                      smoothing: state.imageSmoothingEnabled, tint: CSSColor.parse(tint)))
    }
}

/// An image usable with `drawImage`; caches cropped sub-images so identical
/// frames produce identical (pointer-equal) ops and skip re-rasterization.
final class CanvasImage {
    let cgImage: CGImage
    private var crops: [CGRect: CGImage] = [:]

    init(_ cgImage: CGImage) { self.cgImage = cgImage }

    var width: Int { cgImage.width }
    var height: Int { cgImage.height }

    func crop(_ rect: CGRect) -> CGImage? {
        let r = rect.integral
        if r.origin == .zero, r.width == Double(width), r.height == Double(height) { return cgImage }
        if let hit = crops[r] { return hit }
        guard let c = cgImage.cropping(to: r) else { return nil }
        crops[r] = c
        return c
    }
}

import CoreText
import Foundation

/// Ex-speech-bubble.ts. The DOM element + `.speech-bubble` CSS become a
/// Canvas drawing that reproduces the CSS box model:
///
///     * { box-sizing: border-box }
///     .speech-bubble { position: fixed; transform: translateX(-50%);
///       background: #1a1a2e; color: #eee; padding: 12px 16px; border-radius: 12px;
///       font: 14px "Courier New", monospace; max-width: 300px; min-width: 120px;
///       border: 2px solid #e94560; box-shadow: 0 4px 12px rgba(0,0,0,.3) }
///     .speech-bubble-text { line-height: 1.4 }
///     ::before / ::after: the 22px / 16px wide tail triangles
///
/// The caller wraps `draw` in `ctx.group("bubble:<id>", layer: .overlay)`.
final class SpeechBubble {
    // MARK: CSS constants

    static let FONT = "14px 'Courier New', monospace"
    /// `line-height: 1.4` on a 14px font.
    static let LINE_HEIGHT = 19.6
    static let PADDING_X = 16.0
    static let PADDING_Y = 12.0
    static let BORDER_WIDTH = 2.0
    static let BORDER_RADIUS = 12.0
    static let MAX_WIDTH = 300.0
    static let MIN_WIDTH = 120.0
    static let BACKGROUND = "#1a1a2e"
    static let TEXT_COLOR = "#eee"
    static let DEFAULT_BORDER_COLOR = "#e94560"
    static let SHADOW_COLOR = "rgba(0, 0, 0, 0.3)"

    /// ex-`window.innerWidth/innerHeight`: the overlay's size. The app sets
    /// this (and updates it on screen changes).
    static var viewport = ScreenSize(width: 1512, height: 982)

    private static let font = CSSFont.parse(FONT)!

    /// Total horizontal / vertical padding + border (border-box sizing).
    private static let chromeW = 2 * (PADDING_X + BORDER_WIDTH)
    private static let chromeH = 2 * (PADDING_Y + BORDER_WIDTH)

    // MARK: State

    private var isVisible = false
    private var destroyed = false
    private var typewriterTimer: TimerToken?
    private var hideTimer: TimerToken?
    private var unlisten: (() -> Void)?
    private var lastText: String = ""
    /// The text being typed, as UTF-16 units (JS `text.length` / `text[i]`).
    private var units: [UInt16] = []
    private(set) var typedCount = 0
    private let borderColor: String
    /// CSS `left` / `bottom` as last set by `updatePosition` (kept across
    /// hide/show like the element's inline style). nil = never positioned.
    private(set) var left: Double?
    private(set) var bottom: Double?
    private var cachedLayout: (key: LayoutKey, layout: Layout)?
    private var revision = 0

    /// Callback invoked when an animation should be triggered
    var onAnimation: ((SheepAnimation) -> Void)?

    init(listenToCommentary: Bool = true, borderColor: String? = nil) {
        if let borderColor, !borderColor.isEmpty, CSSColor.parse(borderColor) != nil {
            self.borderColor = borderColor
        } else {
            self.borderColor = Self.DEFAULT_BORDER_COLOR
        }

        if listenToCommentary {
            // ex-listen("sheep-commentary"): structured events from the backend
            unlisten = AppEvents.shared.sheepCommentary.on { [weak self] event in
                Log.info("bubble", "Speech bubble: \(event.text) animation: \(event.animation?.rawValue ?? "nil")")
                self?.show(event.text, duration: 8000)
                if let anim = event.animation, let cb = self?.onAnimation {
                    cb(anim)
                }
            }
        }
    }

    isolated deinit {
        clear()
        unlisten?()
    }

    var visible: Bool { isVisible }

    var currentText: String { isVisible ? lastText : "" }

    /// The text typed so far (what the DOM element's textContent holds).
    var displayedText: String {
        var n = typedCount
        // Never show half a surrogate pair (JS would render a replacement
        // glyph for one 30ms tick).
        if n > 0, n < units.count, UTF16.isLeadSurrogate(units[n - 1]) { n -= 1 }
        return String(decoding: units[0..<n], as: UTF16.self)
    }

    // MARK: show / hide

    func show(_ text: String, duration: Double = 5000) {
        clear()
        lastText = text
        isVisible = true
        units = Array(text.utf16)
        typedCount = 0
        revision += 1

        // Typewriter effect
        typewriterTimer = SimTimers.every(30) { [weak self] in
            self?.typewriterTick()
        }

        // Auto-hide after duration — but never before the 30ms/char typewriter
        // has finished, or long replies vanish mid-type
        hideTimer = SimTimers.after(Self.autoHideDelay(textLength: units.count, duration: duration)) { [weak self] in
            self?.hide()
        }
    }

    /// `Math.max(duration, text.length * 30 + 2500)` (length in UTF-16 units).
    static func autoHideDelay(textLength: Int, duration: Double) -> Double {
        max(duration, Double(textLength) * 30 + 2500)
    }

    /// One 30ms typewriter interval tick.
    func typewriterTick() {
        if typedCount < units.count {
            typedCount += 1
        } else {
            typewriterTimer?.cancel()
            typewriterTimer = nil
        }
    }

    func hide() {
        clear()
        isVisible = false
    }

    /// Stop listening and timers when this bubble is no longer needed.
    func destroy() {
        clear()
        unlisten?()
        unlisten = nil
        destroyed = true
    }

    private func clear() {
        typewriterTimer?.cancel()
        typewriterTimer = nil
        hideTimer?.cancel()
        hideTimer = nil
    }

    // MARK: Layout (CSS box model)

    struct Layout: Equatable {
        /// Border-box size (what `getBoundingClientRect` reports).
        var width: Double
        var height: Double
        /// Text lines after word wrapping.
        var lines: [String]
    }

    private struct LayoutKey: Equatable {
        var revision: Int
        var typed: Int
        var left: Double?
        var viewportWidth: Double
    }

    /// The layout of the currently displayed text at the current `left`.
    var layout: Layout {
        let key = LayoutKey(revision: revision, typed: typedCount, left: left, viewportWidth: Self.viewport.width)
        if let c = cachedLayout, c.key == key { return c.layout }
        let l = Self.layout(text: displayedText, left: left, viewportWidth: Self.viewport.width)
        cachedLayout = (key, l)
        return l
    }

    /// CSS `white-space: normal`: whitespace runs collapse to one space and
    /// leading/trailing whitespace disappears, so the text is just its words.
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if u == " " || u == "\t" || u == "\n" || u == "\r" || u == "\u{0C}" {
                if !cur.isEmpty { out.append(String(cur)); cur = String.UnicodeScalarView() }
            } else {
                cur.append(u)
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    static func measure(_ text: String) -> Double {
        TextLines.width(text, font)
    }

    /// Lays out `text` like the DOM element did: a fixed-position box with
    /// `left` set and `width: auto` (shrink-to-fit against the room to the
    /// right of `left`: min(max(min-content, available), max-content)),
    /// then clamped by max-width 300 / min-width 120 (border-box). Text wraps
    /// at spaces; a word wider than the box overflows.
    ///
    /// - Parameter left: the CSS `left` in effect (nil = never positioned).
    static func layout(text: String, left: Double?, viewportWidth: Double) -> Layout {
        let words = words(text)
        guard !words.isEmpty else {
            // No line boxes: only padding + border remain.
            return Layout(width: MIN_WIDTH, height: chromeH, lines: [])
        }

        let maxContent = measure(words.joined(separator: " "))
        let minContent = words.reduce(0) { max($0, measure($1)) }
        let available = left.map { viewportWidth - $0 - chromeW } ?? .infinity
        let shrunk = min(max(minContent, available), maxContent)
        let content = max(MIN_WIDTH - chromeW, min(MAX_WIDTH - chromeW, shrunk))

        let lines = wrap(words, contentWidth: content)
        return Layout(
            width: content + chromeW,
            height: chromeH + Double(lines.count) * LINE_HEIGHT,
            lines: lines
        )
    }

    /// Greedy first-fit line breaking at spaces.
    static func wrap(_ words: [String], contentWidth: Double) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
                continue
            }
            let candidate = current + " " + word
            if measure(candidate) <= contentWidth + 1e-6 {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    // MARK: Positioning

    func updatePosition(_ sheepX: Double, _ sheepY: Double, _ sheepSize: Double) {
        if !isVisible { return }

        // Position above the sheep, centered horizontally
        let bubbleX = sheepX + sheepSize / 2
        let bubbleY = sheepY - 20

        // Clamp to viewport edges so bubbles don't overflow — including the
        // top edge, or a sheep high on a window platform pushes the bubble
        // entirely off-screen
        let vp = Self.viewport
        let rect = layout
        let halfW = rect.width / 2
        let clampedX = max(halfW + 4, min(bubbleX, vp.width - halfW - 4))
        let clampedBottom = min(
            max(rect.height + 16, vp.height - bubbleY),
            vp.height - rect.height - 8
        )

        left = clampedX
        bottom = clampedBottom
    }

    // MARK: Drawing

    /// Draws nothing while hidden (or before the first `updatePosition`).
    func draw(_ ctx: Canvas) {
        guard isVisible, !destroyed, let left, let bottom else { return }

        let vp = Self.viewport
        let l = layout
        let w = l.width
        let h = l.height
        // `left` is the center (translateX(-50%)); `bottom` is measured up
        // from the viewport bottom.
        let x = left - w / 2
        let y = vp.height - bottom - h

        ctx.save()

        // border-box: shadow + 2px border ring (outer radius 12), then the
        // background inside it (inner radius 12 - 2)
        ctx.save()
        ctx.shadowColor = Self.SHADOW_COLOR
        ctx.shadowBlur = 12
        ctx.shadowOffsetX = 0
        ctx.shadowOffsetY = 4
        ctx.fillStyle = borderColor
        ctx.beginPath()
        ctx.roundRect(x, y, w, h, Self.BORDER_RADIUS)
        ctx.fill()
        ctx.restore()

        let b = Self.BORDER_WIDTH
        ctx.fillStyle = Self.BACKGROUND
        ctx.beginPath()
        ctx.roundRect(x + b, y + b, w - 2 * b, h - 2 * b, Self.BORDER_RADIUS - b)
        ctx.fill()

        // Tail. ::before/::after are absolutely positioned against the
        // padding box (2px inside the border), `bottom: -11px` / `-8px`, so
        // both triangles start at the padding-box bottom edge.
        let cx = x + w / 2
        let tailTop = y + h - b
        ctx.fillStyle = borderColor
        ctx.beginPath()
        ctx.moveTo(cx - 11, tailTop)
        ctx.lineTo(cx + 11, tailTop)
        ctx.lineTo(cx, tailTop + 11)
        ctx.closePath()
        ctx.fill()
        ctx.fillStyle = Self.BACKGROUND
        ctx.beginPath()
        ctx.moveTo(cx - 8, tailTop)
        ctx.lineTo(cx + 8, tailTop)
        ctx.lineTo(cx, tailTop + 8)
        ctx.closePath()
        ctx.fill()

        // Text: line boxes are 19.6px tall with the glyphs vertically
        // centred by half-leading (WebKit rounds font ascent/descent).
        if !l.lines.isEmpty {
            let ct = Self.font.ctFont
            let ascent = Double(CTFontGetAscent(ct)).rounded()
            let descent = Double(CTFontGetDescent(ct)).rounded()
            let baseline = (Self.LINE_HEIGHT - (ascent + descent)) / 2 + ascent
            ctx.font = Self.FONT
            ctx.fillStyle = Self.TEXT_COLOR
            ctx.textAlign = "left"
            ctx.textBaseline = "alphabetic"
            let textX = x + b + Self.PADDING_X
            let textTop = y + b + Self.PADDING_Y
            for (i, line) in l.lines.enumerated() {
                ctx.fillText(line, textX, textTop + Double(i) * Self.LINE_HEIGHT + baseline)
            }
        }

        ctx.restore()
    }
}

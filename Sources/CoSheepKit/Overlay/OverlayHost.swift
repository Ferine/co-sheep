import AppKit
import ImageIO
import SpriteKit

/// SKView that accepts file drops (ex-document `drop` listener) and gets
/// mouseMoved via a tracking area (ex-document `mousemove`). Events only
/// arrive while the panel is interactive, exactly like the webview.
final class OverlaySKView: SKView {
    /// File URL + drop point in canvas coordinates.
    var onFileDrop: ((URL, Double, Double) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Cursor while the overlay is interactive (i.e. over a sheep, or chat
    /// open): ex-CSS `body { cursor: grab }` / `body.dragging { cursor: grabbing }`.
    var dragging = false

    override func mouseMoved(with event: NSEvent) {
        scene?.mouseMoved(with: event)
        (dragging ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        (dragging ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let url = urls?.first else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        onFileDrop?(url, Double(p.x), Double(bounds.height - p.y))
        return true
    }
}

/// Owns the overlay window stack: panel → SKView → OverlayScene, sized to
/// the primary screen. Canvas coordinates == global top-left screen points.
final class OverlayHost {
    let panel: OverlayPanel
    let view: OverlaySKView
    let scene: OverlayScene
    private(set) var screenFrame: NSRect
    private var interactive = false

    init() {
        // No display (e.g. headless login): start at a nominal size; `refit()`
        // adopts the real screen once one appears.
        let screen = NSScreen.screens.first ?? NSScreen.main
        screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        panel = OverlayPanel(frame: screenFrame)
        view = OverlaySKView(frame: NSRect(origin: .zero, size: screenFrame.size))
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        // Same cadence as the webview's rAF by default; CO_SHEEP_FPS overrides.
        view.preferredFramesPerSecond = ProcessInfo.processInfo.environment["CO_SHEEP_FPS"].flatMap(Int.init) ?? 60
        view.shouldCullNonVisibleNodes = true
        scene = OverlayScene(size: screenFrame.size)
        scene.backingScale = Double(screen?.backingScaleFactor ?? 2)
        view.presentScene(scene)
        panel.contentView = view
        panel.setFrame(screenFrame, display: true)
        panel.orderFrontRegardless()
        Log.info("app", "Overlay \(Int(screenFrame.width))x\(Int(screenFrame.height)) @\(scene.backingScale)x")
    }

    var screenSize: ScreenSize {
        ScreenSize(width: Double(screenFrame.width), height: Double(screenFrame.height))
    }

    /// Re-fit to the primary screen (resolution/arrangement changed).
    /// Returns true when the size changed.
    @discardableResult
    func refit() -> Bool {
        guard let screen = NSScreen.screens.first, screen.frame != screenFrame else { return false }
        screenFrame = screen.frame
        panel.setFrame(screenFrame, display: true)
        view.frame = NSRect(origin: .zero, size: screenFrame.size)
        scene.size = screenFrame.size
        scene.backingScale = screen.backingScaleFactor
        return true
    }

    /// Dev aid: write the composited scene over mid-gray to a PNG
    /// (works without Screen Recording permission).
    func snapshotPNG(to url: URL) {
        guard let tex = view.texture(from: scene), let img = tex.cgImage() as CGImage? else {
            Log.info("app", "error: snapshot failed")
            return
        }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGReplay.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.45, alpha: 1))
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
        Log.info("app", "Snapshot written to \(url.path)")
    }

    /// Global cursor position in canvas coordinates.
    func cursorInCanvas() -> (x: Double, y: Double) {
        let loc = NSEvent.mouseLocation
        return (Double(loc.x - screenFrame.minX), Double(screenFrame.maxY - loc.y))
    }

    /// Click-through (ex-cursor.rs): interactive only while the cursor is
    /// over a character, or while forced (dragging / chat input open).
    func updateClickThrough(bounds: [CGRect], forceInteractive: Bool) {
        let over: Bool
        if forceInteractive {
            over = true
        } else {
            let (cx, cy) = cursorInCanvas()
            over = bounds.contains { b in
                b.width > 0 && b.height > 0 && cx >= b.minX && cx <= b.maxX && cy >= b.minY && cy <= b.maxY
            }
        }
        guard over != interactive else { return }
        interactive = over
        panel.ignoresMouseEvents = !over
        Log.debug("cursor", "Cursor \(over ? "OVER" : "LEFT") character")
    }
}

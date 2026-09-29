import AppKit

/// Full-screen transparent, always-on-top, click-through overlay window
/// (ex-Tauri "main" window: transparent, undecorated, alwaysOnTop,
/// visibleOnAllWorkspaces, starts with ignore-cursor-events on).
final class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    // Key status is needed for the chat input field.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Cover the whole screen, menu bar included, so canvas coordinates equal
    // global top-left screen coordinates (window platforms rely on that).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

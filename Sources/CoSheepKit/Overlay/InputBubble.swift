import AppKit

/// Ex-input-bubble.ts: the chat bubble with a text field, hosted as a native
/// view over the SKView. Styled after `.speech-bubble.input-bubble` CSS.
struct InputBubbleConfig {
    var promptText: String
    var placeholder: String
    var buttonText: String
    var onSubmit: (String) async -> Void
    var onClose: (() -> Void)?
    /// Return true to keep the bubble open for this outside mousedown (e.g. a sheep grab).
    var shouldIgnoreClickAway: ((_ x: Double, _ y: Double) -> Bool)?
}

final class InputBubble {
    private let config: InputBubbleConfig
    private let view: InputBubbleView
    private weak var host: OverlayHost?
    private(set) var isShown = false


    init(config: InputBubbleConfig, host: OverlayHost) {
        self.config = config
        self.host = host
        view = InputBubbleView(promptText: config.promptText, placeholder: config.placeholder,
                               buttonText: config.buttonText)
        view.isHidden = true
        view.onSubmit = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in await self.config.onSubmit(text) }
        }
        view.onEscape = { [weak self] in self?.config.onClose?() }
        host.view.addSubview(view)
    }

    /// Outside mousedown (canvas coords) — ends the conversation unless ignored.
    /// Returns true when the click was consumed as a dismissal.
    @discardableResult
    func handleMouseDown(x: Double, y: Double) -> Bool {
        guard isShown, let host else { return false }
        let p = NSPoint(x: x, y: Double(host.screenFrame.height) - y)
        if view.frame.contains(p) { return false }
        if config.shouldIgnoreClickAway?(x, y) == true { return false }
        config.onClose?()
        return true
    }

    /// Render the sheep's reply inside the bubble and hand the input back.
    func showReply(_ text: String, isError: Bool = false) {
        view.showReply(text, isError: isError)
    }

    func show() {
        view.isHidden = false
        isShown = true
        host?.panel.makeKey()
        SimTimers.after(100) { [weak self] in self?.view.focusInput() }
    }

    func hide() {
        view.isHidden = true
        isShown = false
        releaseKey()
    }

    /// show() made the full-screen overlay panel key; left that way it keeps
    /// eating keystrokes after the chat closes. Re-ordering drops key status
    /// and, the panel being non-activating, hands typing back to the user's app.
    private func releaseKey() {
        guard let panel = host?.panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    func destroy() {
        hide()
        view.removeFromSuperview()
    }

    func setLoading(_ on: Bool) {
        view.setLoading(on, promptText: config.promptText)
    }

    func updatePosition(_ sheepX: Double, _ sheepY: Double, _ sheepSize: Double) {
        guard let host else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let innerW = Double(host.screenFrame.width)
        let innerH = Double(host.screenFrame.height)
        let bubbleX = sheepX + sheepSize / 2
        let bubbleY = sheepY - 20
        let halfW = Double(size.width) / 2
        // The view includes the tail below the box; CSS sizes/positions the
        // box alone (the tail is an absolutely positioned pseudo-element).
        let tail = Double(BubbleStyle.tailOuter)
        let boxH = Double(size.height) - tail
        let clampedX = max(halfW + 4, min(bubbleX, innerW - halfW - 4))
        // Clamp against the top edge too — the chat input must stay visible
        // even when the sheep is high up on a window platform
        let clampedBottom = min(max(boxH + 16, innerH - bubbleY), innerH - boxH - 8)
        // View coordinates are y-up: CSS `bottom` is the box's bottom edge,
        // so the view (box + tail) starts one tail height lower.
        view.frame = NSRect(x: clampedX - halfW, y: clampedBottom - tail, width: Double(size.width),
                            height: Double(size.height))
    }
}

// MARK: - View

private enum BubbleStyle {
    static let background = NSColor(srgbRed: 0x1a / 255, green: 0x1a / 255, blue: 0x2e / 255, alpha: 1)
    static let border = NSColor(srgbRed: 0xe9 / 255, green: 0x45 / 255, blue: 0x60 / 255, alpha: 1)
    static let borderHover = NSColor(srgbRed: 1, green: 0x6b / 255, blue: 0x6b / 255, alpha: 1)
    static let text = NSColor(srgbRed: 0xee / 255, green: 0xee / 255, blue: 0xee / 255, alpha: 1)
    static let inputBackground = NSColor(srgbRed: 0x16 / 255, green: 0x21 / 255, blue: 0x3e / 255, alpha: 1)
    static let loading = NSColor(srgbRed: 0x88 / 255, green: 0x88 / 255, blue: 0x88 / 255, alpha: 1)
    static let error = NSColor(srgbRed: 1, green: 0x6b / 255, blue: 0x6b / 255, alpha: 1)

    /// CSS `.speech-bubble-text { line-height: 1.4 }`.
    static func textAttributes(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = font.pointSize * 1.4
        p.maximumLineHeight = font.pointSize * 1.4
        return [.font: font, .foregroundColor: color, .paragraphStyle: p]
    }

    static func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        var font = NSFont(name: "Courier New", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
        return font
    }

    // CSS: width 300 (max-width; the flex form fills it), padding 12/16, border 2.
    static let width: CGFloat = 300
    static let padX: CGFloat = 16
    static let padY: CGFloat = 12
    static let borderWidth: CGFloat = 2
    static let radius: CGFloat = 12
    static let tailOuter: CGFloat = 11
    static let tailInner: CGFloat = 8
}

/// Text field that reports Escape (ex-keydown "Escape" listener).
private final class BubbleTextField: NSTextField {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private final class InputBubbleView: NSView {
    var onSubmit: ((String) -> Void)?
    var onEscape: (() -> Void)? {
        didSet { input.onEscape = onEscape }
    }

    private let prompt = NSTextField(wrappingLabelWithString: "")
    private let replyScroll = NSScrollView()
    private let replyText = NSTextView()
    private let input = BubbleTextField()
    private let button = NSButton()
    private let stack = NSStackView()
    private let promptText: String

    init(promptText: String, placeholder: String, buttonText: String) {
        self.promptText = promptText
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.3)
            s.shadowBlurRadius = 12
            s.shadowOffset = NSSize(width: 0, height: -4)
            return s
        }()

        prompt.attributedStringValue = NSAttributedString(
            string: promptText, attributes: BubbleStyle.textAttributes(BubbleStyle.font(14), BubbleStyle.text))
        prompt.isSelectable = false

        replyText.isEditable = false
        replyText.isSelectable = true
        replyText.drawsBackground = false
        replyText.font = BubbleStyle.font(14)
        replyText.textColor = BubbleStyle.text
        replyText.textContainerInset = .zero
        replyText.textContainer?.lineFragmentPadding = 0
        replyText.isVerticallyResizable = true
        replyText.isHorizontallyResizable = false
        replyText.autoresizingMask = [.width]
        // Let the document view grow past the 120px clip so long replies scroll.
        replyText.minSize = NSSize(width: 0, height: 0)
        replyText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        replyText.textContainer?.widthTracksTextView = true
        replyScroll.documentView = replyText
        replyScroll.drawsBackground = false
        replyScroll.hasVerticalScroller = true
        replyScroll.autohidesScrollers = true
        replyScroll.borderType = .noBorder
        replyScroll.isHidden = true

        input.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: BubbleStyle.font(13), .foregroundColor: BubbleStyle.loading,
        ])
        input.font = BubbleStyle.font(13)
        input.textColor = BubbleStyle.text
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.wantsLayer = true
        input.layer?.backgroundColor = BubbleStyle.inputBackground.cgColor
        input.layer?.borderColor = BubbleStyle.border.cgColor
        input.layer?.borderWidth = 1
        input.layer?.cornerRadius = 6
        input.target = self
        input.action = #selector(submit)
        (input.cell as? NSTextFieldCell)?.usesSingleLineMode = true
        input.cell?.isScrollable = true

        button.title = buttonText
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = BubbleStyle.border.cgColor
        button.layer?.cornerRadius = 6
        button.attributedTitle = NSAttributedString(string: buttonText, attributes: [
            .font: BubbleStyle.font(13, bold: true), .foregroundColor: NSColor.white,
        ])
        button.target = self
        button.action = #selector(submit)

        let form = NSStackView(views: [input, button])
        form.orientation = .horizontal
        form.spacing = 8
        form.alignment = .centerY

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.addArrangedSubview(prompt)
        stack.addArrangedSubview(replyScroll)
        stack.addArrangedSubview(form)
        stack.setCustomSpacing(10, after: replyScroll)
        stack.setCustomSpacing(10, after: prompt)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let contentW = BubbleStyle.width - 2 * (BubbleStyle.padX + BubbleStyle.borderWidth)
        let inset = BubbleStyle.padX + BubbleStyle.borderWidth
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: BubbleStyle.padY + BubbleStyle.borderWidth),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor,
                                          constant: -(BubbleStyle.padY + BubbleStyle.borderWidth + BubbleStyle.tailOuter)),
            stack.widthAnchor.constraint(equalToConstant: contentW),
            prompt.widthAnchor.constraint(equalToConstant: contentW),
            replyScroll.widthAnchor.constraint(equalToConstant: contentW),
            form.widthAnchor.constraint(equalToConstant: contentW),
            input.heightAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
            button.widthAnchor.constraint(equalToConstant: button.attributedTitle.size().width + 28),
        ])
        replyHeight = replyScroll.heightAnchor.constraint(equalToConstant: 0)
        replyHeight?.isActive = true
    }

    private var replyHeight: NSLayoutConstraint?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }

    func focusInput() {
        window?.makeFirstResponder(input)
    }

    @objc private func submit() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, input.isEnabled else { return }
        input.stringValue = ""
        onSubmit?(text)
    }

    func showReply(_ text: String, isError: Bool) {
        prompt.isHidden = true
        replyScroll.isHidden = false
        replyScroll.alphaValue = 1
        replyText.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: BubbleStyle.textAttributes(BubbleStyle.font(14, italic: isError),
                                                   isError ? BubbleStyle.error : BubbleStyle.text)))
        // CSS: max-height 120, overflow-y auto.
        if let lm = replyText.layoutManager, let tc = replyText.textContainer {
            tc.containerSize = NSSize(width: replyScroll.contentSize.width > 0 ? replyScroll.contentSize.width
                                          : BubbleStyle.width - 2 * (BubbleStyle.padX + BubbleStyle.borderWidth),
                                      height: .greatestFiniteMagnitude)
            lm.ensureLayout(for: tc)
            replyHeight?.constant = min(120, ceil(lm.usedRect(for: tc).height))
        }
        input.isEnabled = true
        button.isEnabled = true
        button.alphaValue = 1
        input.alphaValue = 1
        focusInput()
        needsLayout = true
    }

    func setLoading(_ on: Bool, promptText: String) {
        input.isEnabled = !on
        button.isEnabled = !on
        input.alphaValue = on ? 0.5 : 1
        button.alphaValue = on ? 0.5 : 1
        // The previous reply stays visible (it's the conversation context) but
        // dims while the next one is being thought up
        replyScroll.alphaValue = on ? 0.5 : 1
        if on {
            // showReply hides the prompt line — bring it back for "thinking..."
            prompt.isHidden = false
            prompt.attributedStringValue = NSAttributedString(
                string: "thinking...",
                attributes: BubbleStyle.textAttributes(BubbleStyle.font(14, italic: true), BubbleStyle.loading))
        } else {
            prompt.attributedStringValue = NSAttributedString(
                string: promptText, attributes: BubbleStyle.textAttributes(BubbleStyle.font(14), BubbleStyle.text))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let tail = BubbleStyle.tailOuter
        let box = NSRect(x: BubbleStyle.borderWidth / 2, y: tail + BubbleStyle.borderWidth / 2,
                         width: bounds.width - BubbleStyle.borderWidth,
                         height: bounds.height - tail - BubbleStyle.borderWidth)
        let path = NSBezierPath(roundedRect: box, xRadius: BubbleStyle.radius, yRadius: BubbleStyle.radius)
        BubbleStyle.background.setFill()
        path.fill()
        BubbleStyle.border.setStroke()
        path.lineWidth = BubbleStyle.borderWidth
        path.stroke()

        // Tail: outer triangle in the border color, inner in the background.
        let cx = bounds.midX
        let bottom = box.minY - BubbleStyle.borderWidth / 2
        let outer = NSBezierPath()
        outer.move(to: NSPoint(x: cx - tail, y: bottom))
        outer.line(to: NSPoint(x: cx, y: bottom - tail))
        outer.line(to: NSPoint(x: cx + tail, y: bottom))
        outer.close()
        BubbleStyle.border.setFill()
        outer.fill()
        let innerH = BubbleStyle.tailInner
        let inner = NSBezierPath()
        inner.move(to: NSPoint(x: cx - innerH, y: bottom + 0.5))
        inner.line(to: NSPoint(x: cx, y: bottom - innerH))
        inner.line(to: NSPoint(x: cx + innerH, y: bottom + 0.5))
        inner.close()
        BubbleStyle.background.setFill()
        inner.fill()
    }
}

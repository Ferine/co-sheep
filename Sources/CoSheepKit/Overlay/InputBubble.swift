import AppKit
import SwiftUI

/// Ex-input-bubble.ts: the chat box with a text field, hosted as a native
/// view over the SKView. A Liquid Glass panel with the system's own controls
/// (see `InputBubbleView`); the web page's dark `.speech-bubble.input-bubble`
/// look is gone.
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
        // The view includes the tail below the box; the box alone is what
        // gets sized and positioned.
        let tail = Double(BubbleStyle.tail)
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

/// Metrics and text styles of the chat box.
enum BubbleStyle {
    /// The app's accent (#e94560), for the Send button.
    static let accent = NSColor(srgbRed: 0xe9 / 255, green: 0x45 / 255, blue: 0x60 / 255, alpha: 1)

    static let width: CGFloat = 320
    static let padX: CGFloat = 16
    static let padY: CGFloat = 14
    static let radius: CGFloat = 20
    /// Height of the tail that points down at the sheep.
    static let tail: CGFloat = 11
    static let tailWidth: CGFloat = 26
    static let fieldHeight: CGFloat = 30
    /// Diameter of the round close button.
    static let closeSize: CGFloat = 28
    /// A long reply scrolls inside this height.
    static let replyMaxHeight: CGFloat = 120

    static func font(italic: Bool = false) -> NSFont {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
    }

    static func text(_ string: String, color: NSColor = .labelColor, italic: Bool = false) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font(italic: italic), .foregroundColor: color])
    }
}

/// The outline of the chat box: a rounded panel with a soft tail at the bottom
/// centre, pointing at the sheep it belongs to (what a popover's arrow does).
nonisolated struct ChatBubbleShape: Shape {
    var radius: CGFloat
    var tail: CGFloat
    var tailWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let box = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, rect.height - tail))
        let r = min(radius, box.height / 2, box.width / 2)
        let cx = box.midX
        let half = min(tailWidth / 2, max(0, box.width / 2 - r))
        var p = Path()
        p.move(to: CGPoint(x: box.minX + r, y: box.minY))
        p.addLine(to: CGPoint(x: box.maxX - r, y: box.minY))
        p.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY),
                 tangent2End: CGPoint(x: box.maxX, y: box.minY + r), radius: r)
        p.addLine(to: CGPoint(x: box.maxX, y: box.maxY - r))
        p.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY),
                 tangent2End: CGPoint(x: box.maxX - r, y: box.maxY), radius: r)
        // The tail: two shallow curves meeting at the tip.
        p.addLine(to: CGPoint(x: cx + half, y: box.maxY))
        p.addQuadCurve(to: CGPoint(x: cx, y: rect.maxY), control: CGPoint(x: cx + half * 0.35, y: box.maxY))
        p.addQuadCurve(to: CGPoint(x: cx - half, y: box.maxY), control: CGPoint(x: cx - half * 0.35, y: box.maxY))
        p.addLine(to: CGPoint(x: box.minX + r, y: box.maxY))
        p.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY),
                 tangent2End: CGPoint(x: box.minX, y: box.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: box.minX, y: box.minY + r))
        p.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY),
                 tangent2End: CGPoint(x: box.minX + r, y: box.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

/// The glass the chat box is made of, in the box's own shape.
private struct ChatBubbleGlass: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular, in: ChatBubbleShape(
                radius: BubbleStyle.radius, tail: BubbleStyle.tail, tailWidth: BubbleStyle.tailWidth))
    }
}

/// Text field that reports Escape (ex-keydown "Escape" listener).
private final class BubbleTextField: NSTextField {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// The chat box: Liquid Glass in the shape of a speech bubble, with the
/// sheep's line, a close button, a text field and a Send button. The controls
/// are AppKit's own (glass bezels, system font and colors), so the box
/// follows the system appearance like any other panel.
final class InputBubbleView: NSView {
    var onSubmit: ((String) -> Void)?
    /// Escape, or the close button: the human is done chatting.
    var onEscape: (() -> Void)? {
        didSet { input.onEscape = onEscape }
    }

    private let glass = NSHostingView(rootView: ChatBubbleGlass())
    private let prompt = NSTextField(wrappingLabelWithString: "")
    private let replyScroll = NSScrollView()
    private let replyText = NSTextView()
    private let input = BubbleTextField()
    private let inputWell = NSBox()
    /// The X in the corner. Internal so tests can click it.
    let closeButton = NSButton()
    let sendButton = NSButton()
    private let stack = NSStackView()
    private let promptText: String
    private var replyHeight: NSLayoutConstraint?

    init(promptText: String, placeholder: String, buttonText: String) {
        self.promptText = promptText
        super.init(frame: .zero)

        glass.sizingOptions = []
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        prompt.attributedStringValue = BubbleStyle.text(promptText)
        prompt.isSelectable = false

        replyText.isEditable = false
        replyText.isSelectable = true
        replyText.drawsBackground = false
        replyText.font = BubbleStyle.font()
        replyText.textColor = .labelColor
        replyText.textContainerInset = .zero
        replyText.textContainer?.lineFragmentPadding = 0
        replyText.isVerticallyResizable = true
        replyText.isHorizontallyResizable = false
        replyText.autoresizingMask = [.width]
        // Let the document view grow past the clip so long replies scroll.
        replyText.minSize = NSSize(width: 0, height: 0)
        replyText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        replyText.textContainer?.widthTracksTextView = true
        replyScroll.documentView = replyText
        replyScroll.drawsBackground = false
        replyScroll.hasVerticalScroller = true
        replyScroll.autohidesScrollers = true
        replyScroll.borderType = .noBorder
        replyScroll.isHidden = true

        // The one way out that needs no keyboard: a round glass X in the
        // top right corner, where a panel's close button is expected.
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close chat")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .heavy))
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleNone
        closeButton.contentTintColor = .labelColor
        closeButton.bezelStyle = .glass
        closeButton.controlSize = .large
        closeButton.toolTip = "Close chat (Esc)"
        closeButton.setAccessibilityLabel("Close chat")
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The field sits in a capsule well, like the system's search fields.
        input.placeholderAttributedString = BubbleStyle.text(placeholder, color: .placeholderTextColor)
        input.font = BubbleStyle.font()
        input.textColor = .labelColor
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.target = self
        input.action = #selector(submit)
        (input.cell as? NSTextFieldCell)?.usesSingleLineMode = true
        input.cell?.isScrollable = true
        input.translatesAutoresizingMaskIntoConstraints = false

        inputWell.boxType = .custom
        inputWell.titlePosition = .noTitle
        inputWell.cornerRadius = BubbleStyle.fieldHeight / 2
        inputWell.fillColor = .quaternarySystemFill
        inputWell.borderColor = .separatorColor
        inputWell.borderWidth = 1
        inputWell.contentViewMargins = .zero
        inputWell.addSubview(input)

        sendButton.title = buttonText
        sendButton.bezelStyle = .glass
        sendButton.bezelColor = BubbleStyle.accent
        sendButton.controlSize = .large
        sendButton.target = self
        sendButton.action = #selector(submit)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let texts = NSStackView(views: [prompt, replyScroll])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0

        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // The text takes the row; the X keeps to the corner.
        let header = NSStackView(views: [texts, closeButton])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .top
        header.spacing = 10

        let form = NSStackView(views: [inputWell, sendButton])
        form.orientation = .horizontal
        form.distribution = .fill
        form.spacing = 8
        form.alignment = .centerY
        inputWell.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(form)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let contentW = BubbleStyle.width - 2 * BubbleStyle.padX
        let replyHeight = replyScroll.heightAnchor.constraint(equalToConstant: 0)
        self.replyHeight = replyHeight
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BubbleStyle.padX),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -BubbleStyle.padX),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: BubbleStyle.padY),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(BubbleStyle.padY + BubbleStyle.tail)),
            stack.widthAnchor.constraint(equalToConstant: contentW),
            header.widthAnchor.constraint(equalToConstant: contentW),
            form.widthAnchor.constraint(equalToConstant: contentW),
            prompt.widthAnchor.constraint(equalTo: texts.widthAnchor),
            replyScroll.widthAnchor.constraint(equalTo: texts.widthAnchor),
            replyHeight,

            closeButton.widthAnchor.constraint(equalToConstant: BubbleStyle.closeSize),
            closeButton.heightAnchor.constraint(equalToConstant: BubbleStyle.closeSize),
            // One line of text sits level with the X; more lines grow down.
            texts.heightAnchor.constraint(greaterThanOrEqualToConstant: BubbleStyle.closeSize),

            inputWell.heightAnchor.constraint(equalToConstant: BubbleStyle.fieldHeight),
            input.leadingAnchor.constraint(equalTo: inputWell.leadingAnchor, constant: 12),
            input.trailingAnchor.constraint(equalTo: inputWell.trailingAnchor, constant: -12),
            input.centerYAnchor.constraint(equalTo: inputWell.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }

    func focusInput() {
        window?.makeFirstResponder(input)
    }

    @objc private func close() {
        onEscape?()
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
        replyText.textStorage?.setAttributedString(
            BubbleStyle.text(text, color: isError ? .systemRed : .labelColor, italic: isError))
        // A long reply scrolls rather than growing the box without end.
        layoutSubtreeIfNeeded()
        if let lm = replyText.layoutManager, let tc = replyText.textContainer {
            let width = replyScroll.contentSize.width > 0
                ? replyScroll.contentSize.width : BubbleStyle.width - 2 * BubbleStyle.padX
            tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            lm.ensureLayout(for: tc)
            replyHeight?.constant = min(BubbleStyle.replyMaxHeight, ceil(lm.usedRect(for: tc).height))
        }
        input.isEnabled = true
        sendButton.isEnabled = true
        focusInput()
        needsLayout = true
    }

    func setLoading(_ on: Bool, promptText: String) {
        input.isEnabled = !on
        sendButton.isEnabled = !on
        // The previous reply stays visible (it's the conversation context) but
        // dims while the next one is being thought up
        replyScroll.alphaValue = on ? 0.5 : 1
        if on {
            // showReply hides the prompt line — bring it back for "thinking..."
            prompt.isHidden = false
            prompt.attributedStringValue = BubbleStyle.text("thinking...", color: .secondaryLabelColor, italic: true)
        } else {
            prompt.attributedStringValue = BubbleStyle.text(promptText)
        }
    }
}

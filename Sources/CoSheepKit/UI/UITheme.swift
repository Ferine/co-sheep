import Observation
import SwiftUI

/// Shared look of the aux windows: native controls, tinted with the pages'
/// pink accent.
///
/// Liquid Glass belongs to the layer of controls that floats above content:
/// the title bar, toolbars, and the action bar at the bottom of a dialog
/// (`dialogBar`). Content itself (forms, lists, cards) stays plain; a card is
/// a filled `UITheme.card` shape, never glass on glass.
enum UITheme {
    /// The pages' accent, #e94560.
    static let accent = Color(red: 0xe9 / 255, green: 0x45 / 255, blue: 0x60 / 255)
    /// The pages' "saved" green, #4ecca3.
    static let success = Color(red: 0x4e / 255, green: 0xcc / 255, blue: 0xa3 / 255)
    /// The dark canvas the sheep preview sits on, #16213e.
    static let previewBackground = Color(red: 0x16 / 255, green: 0x21 / 255, blue: 0x3e / 255)

    /// The corner shape of a free-standing content card: the radius of the
    /// grouped form's own sections, so cards and sections read as one family.
    static let card = RoundedRectangle(cornerRadius: 12, style: .continuous)

    /// A card nested inside a form section: tighter, so its corners stay
    /// concentric with the section around it.
    static let nestedCard = RoundedRectangle(cornerRadius: 7, style: .continuous)

    /// Outer margin of content that isn't a form (forms bring their own).
    static let margin: CGFloat = 20
}

extension View {
    /// The row of actions at the bottom of a dialog (Cancel / Save). It
    /// floats over the scrolling content as Liquid Glass, and the content
    /// dissolves beneath it through the scroll edge effect, instead of
    /// sitting in an opaque strip under a divider. Give its buttons the
    /// `.glass` / `.glassProminent` styles.
    func dialogBar(@ViewBuilder _ bar: () -> some View) -> some View {
        safeAreaBar(edge: .bottom) {
            GlassEffectContainer {
                HStack(spacing: 12) { bar() }
            }
            .controlSize(.large)
            .padding(.horizontal, UITheme.margin)
            .padding(.vertical, 12)
        }
    }
}

/// A window's reload contract: `WindowManager` calls `reload()` each time the
/// window is opened or brought to the front, so it never shows stale data.
protocol WindowModel: AnyObject {
    func reload()
}

/// A flag that raises for a while and then falls on its own ("Settings saved.").
@Observable
final class TimedFlag {
    private(set) var isOn = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func raise(for seconds: Double) {
        task?.cancel()
        isOn = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.isOn = false
        }
    }
}

/// A confirmation line that fades in and out (`.saved-msg`).
struct FadingMessage: View {
    let text: String
    let visible: Bool
    var color: Color = UITheme.success

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .center)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.3), value: visible)
            .accessibilityHidden(!visible)
    }
}

/// Italic secondary text for an empty list (`.empty`).
struct EmptyNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .italic()
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }
}

/// One choice of a `Picker` (`<option value=… >label</option>`).
struct ChoiceOption: Identifiable, Equatable {
    let value: String
    let label: String
    var id: String { value }

    /// `base`, plus the saved `current` value when it isn't one of them, so
    /// an unrecognised config value round-trips instead of blanking the picker.
    static func including(_ current: String, in base: [ChoiceOption]) -> [ChoiceOption] {
        if current.isEmpty || base.contains(where: { $0.value == current }) { return base }
        return base + [ChoiceOption(value: current, label: current)]
    }
}

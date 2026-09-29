import Observation
import SwiftUI

/// Shared look of the aux windows: native controls, tinted with the pages'
/// pink accent.
enum UITheme {
    /// The pages' accent, #e94560.
    static let accent = Color(red: 0xe9 / 255, green: 0x45 / 255, blue: 0x60 / 255)
    /// The pages' "saved" green, #4ecca3.
    static let success = Color(red: 0x4e / 255, green: 0xcc / 255, blue: 0xa3 / 255)
    /// The dark canvas the sheep preview sits on, #16213e.
    static let previewBackground = Color(red: 0x16 / 255, green: 0x21 / 255, blue: 0x3e / 255)
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

/// The page's `<h1>` (+ optional subtitle).
struct WindowHeading: View {
    let title: String
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(UITheme.accent)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

import Observation
import SwiftUI

// Ex-public/settings.html ("co-sheep Settings").

@Observable
final class SettingsModel: WindowModel {
    static let personalities = [
        ChoiceOption(value: "snarky", label: "Snarky"),
        ChoiceOption(value: "wholesome", label: "Wholesome"),
        ChoiceOption(value: "chaotic", label: "Chaotic"),
        ChoiceOption(value: "passive-aggressive", label: "Passive-Aggressive"),
    ]

    static let personalityDescriptions: [String: String] = [
        "snarky": "Judgmental and opinionated, like self-aware Clippy.",
        "wholesome": "Supportive and encouraging, your cozy desk buddy.",
        "chaotic": "Unhinged energy, zero filter, maximum sheep puns.",
        "passive-aggressive": "Master of backhanded compliments and loud sighs.",
    ]

    static let languages = [
        ChoiceOption(value: "nynorsk", label: "Nynorsk"),
        ChoiceOption(value: "bokmål", label: "Bokmål"),
        ChoiceOption(value: "english", label: "English"),
        ChoiceOption(value: "swedish", label: "Svenska"),
        ChoiceOption(value: "danish", label: "Dansk"),
        ChoiceOption(value: "german", label: "Deutsch"),
        ChoiceOption(value: "french", label: "Français"),
        ChoiceOption(value: "spanish", label: "Español"),
        ChoiceOption(value: "japanese", label: "日本語"),
        ChoiceOption(value: "korean", label: "한국어"),
    ]

    static let easterModes = [
        ChoiceOption(value: "auto", label: "Auto (Easter week)"),
        ChoiceOption(value: "on", label: "Always on"),
        ChoiceOption(value: "off", label: "Always off"),
    ]

    static let summerModes = [
        ChoiceOption(value: "auto", label: "Auto (June–August)"),
        ChoiceOption(value: "on", label: "Always on"),
        ChoiceOption(value: "off", label: "Always off"),
    ]

    static let christmasModes = [
        ChoiceOption(value: "auto", label: "Auto (December 1 – January 6)"),
        ChoiceOption(value: "on", label: "Always on"),
        ChoiceOption(value: "off", label: "Always off"),
    ]

    /// The slider's range (`<input type="range" min="30" max="600" step="10">`).
    static let intervalRange: ClosedRange<Double> = 30...600
    static let intervalStep = 10.0

    var name = ""
    var intervalSecs = 150.0
    var personality = "snarky"
    var language = "nynorsk"
    var weatherLocation = ""
    var easterMode = "auto"
    var summerMode = "auto"
    var christmasMode = "auto"
    var breakReminders = true
    var herdEnabled = true
    var shepherdCommentary = true
    var errorMessage: String?
    let saved = TimedFlag()

    /// Whether the on-device model lists a language option as supported
    /// (tests swap it for a fixed answer).
    @ObservationIgnored var supportsLanguage: (String) -> Bool = { AppleAI.supportsLanguage($0) }

    /// The line under the language picker, with a warning when the model
    /// doesn't officially speak the chosen language (Nynorsk, for one).
    var languageNote: String {
        let base = "The language your sheep speaks in."
        if supportsLanguage(language) { return base }
        let label = Self.languages.first { $0.value == language }?.label ?? language
        return base + " Apple Intelligence doesn't list \(label) as supported on this Mac, so expect slips into other languages."
    }

    /// `formatInterval`: "45s", "2 min", "2.5 min".
    static func formatInterval(_ secs: Int) -> String {
        if secs < 60 { return "\(secs)s" }
        let mins = Double(secs) / 60
        return mins.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(mins)) min"
            : String(format: "%.1f min", mins)
    }

    /// An `<input type="range">` sanitizes its value to the range and step.
    static func snapInterval(_ secs: Double) -> Double {
        let clamped = min(max(secs, intervalRange.lowerBound), intervalRange.upperBound)
        let steps = ((clamped - intervalRange.lowerBound) / intervalStep).rounded()
        return intervalRange.lowerBound + steps * intervalStep
    }

    var intervalLabel: String { Self.formatInterval(Int(intervalSecs)) }

    var personalityDescription: String { Self.personalityDescriptions[personality] ?? "" }

    /// Load the saved settings (with the page's `||` fallbacks).
    func reload() {
        let s = WindowCommands.getSettings()
        name = s.name
        let interval = s.intervalSecs == 0 ? 150 : s.intervalSecs
        intervalSecs = Self.snapInterval(Double(interval))
        personality = s.personality.isEmpty ? "snarky" : s.personality
        language = s.language.isEmpty ? "nynorsk" : s.language
        weatherLocation = s.weatherLocation
        easterMode = s.easterMode.isEmpty ? "auto" : s.easterMode
        summerMode = s.summerMode.isEmpty ? "auto" : s.summerMode
        christmasMode = s.christmasMode.isEmpty ? "auto" : s.christmasMode
        breakReminders = s.breakReminders
        herdEnabled = s.herdEnabled
        shepherdCommentary = s.shepherdCommentary
        errorMessage = nil
    }

    func save() {
        do {
            try WindowCommands.saveSettings(
                name: Self.trimmed(name).isEmpty ? "Sheep" : Self.trimmed(name),
                personality: personality,
                intervalSecs: Int(intervalSecs),
                language: language,
                breakReminders: breakReminders,
                easterMode: easterMode,
                summerMode: summerMode,
                weatherLocation: Self.trimmed(weatherLocation),
                christmasMode: christmasMode,
                herdEnabled: herdEnabled,
                shepherdCommentary: shepherdCommentary)
            errorMessage = nil
            saved.raise(for: 3)
        } catch {
            errorMessage = "Couldn't save settings: \(error.localizedDescription)"
        }
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                TextField("Sheep Name", text: $model.name, prompt: Text("Name your sheep..."))
            }

            Section("AI") {
                Text("Runs fully on-device with Apple Intelligence — free and private: what's on your screen never leaves your Mac. Requires Apple Silicon with Apple Intelligence enabled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(spacing: 4) {
                    HStack {
                        Text("Commentary Interval")
                        Spacer()
                        Text(model.intervalLabel)
                            .monospacedDigit()
                            .foregroundStyle(UITheme.accent)
                    }
                    Slider(
                        value: $model.intervalSecs,
                        in: SettingsModel.intervalRange,
                        step: SettingsModel.intervalStep
                    ) { Text("Commentary Interval") }
                        .labelsHidden()
                }
            }

            Section {
                Picker("Personality", selection: $model.personality) {
                    ForEach(ChoiceOption.including(model.personality, in: SettingsModel.personalities)) {
                        Text($0.label).tag($0.value)
                    }
                }
            } footer: {
                Text(model.personalityDescription).italic()
            }

            Section {
                Picker("Language", selection: $model.language) {
                    ForEach(ChoiceOption.including(model.language, in: SettingsModel.languages)) {
                        Text($0.label).tag($0.value)
                    }
                }
            } footer: {
                Text(model.languageNote)
            }

            Section {
                TextField(
                    "Weather Location", text: $model.weatherLocation,
                    prompt: Text("Oslo, London, Tokyo..."))
            } footer: {
                Text("City name for weather awareness, looked up at wttr.in — the one thing co-sheep sends over the network. Leave empty to disable.")
            }

            Section {
                Picker("Easter Mode", selection: $model.easterMode) {
                    ForEach(ChoiceOption.including(model.easterMode, in: SettingsModel.easterModes)) {
                        Text($0.label).tag($0.value)
                    }
                }
            } footer: {
                Text("Eggs to paint and hunt. Auto runs from the Tuesday before Easter Sunday to the Tuesday after.")
            }

            Section {
                Picker("Summer Mode", selection: $model.summerMode) {
                    ForEach(ChoiceOption.including(model.summerMode, in: SettingsModel.summerModes)) {
                        Text($0.label).tag($0.value)
                    }
                }
            } footer: {
                Text("Sun, sunflowers and butterflies. With a weather location, Auto waits for a clear day of 18 °C or more.")
            }

            Section {
                Picker("Christmas Mode", selection: $model.christmasMode) {
                    ForEach(ChoiceOption.including(model.christmasMode, in: SettingsModel.christmasModes)) {
                        Text($0.label).tag($0.value)
                    }
                }
            } footer: {
                Text("Tree, lights, snow and nisseluer, plus a julekalender door every day until Christmas Eve.")
            }

            Section {
                Toggle("Break Reminders", isOn: $model.breakReminders)
            } footer: {
                Text("Nudge me to take breaks after 45 min of continuous work.")
            }

            Section {
                Toggle("Show agent lambs", isOn: $model.herdEnabled)
                Toggle("Shepherd commentary", isOn: $model.shepherdCommentary)
            } header: {
                Text("Agent Herd")
            } footer: {
                Text("Every Claude Code session becomes a lamb. Connect Claude Code from the co-sheep menu.")
            }
        }
        .formStyle(.grouped)
        .tint(UITheme.accent)
        .dialogBar {
            Button("Cancel") { WindowManager.shared.close(.settings) }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.glass)
            Group {
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                } else {
                    FadingMessage(text: "Settings saved.", visible: model.saved.isOn)
                }
            }
            .frame(maxWidth: .infinity)
            Button("Save") { model.save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(UITheme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

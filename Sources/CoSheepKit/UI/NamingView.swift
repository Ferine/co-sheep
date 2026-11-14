import Observation
import SwiftUI

// Ex-public/naming.html ("Name your sheep!"): first-run onboarding.

@Observable
final class NamingModel: WindowModel {
    var name = ""
    var errorMessage: String?

    /// Nothing to reload: the window always opens on an empty field.
    func reload() {}

    /// Saves the trimmed name and reports whether the window should close
    /// (`saveSheepName` emits `namingComplete`, which lets the overlay greet).
    /// An empty name does nothing, like the page.
    @discardableResult
    func submit() -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        do {
            try WindowCommands.saveSheepName(trimmed)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn't save the name: \(error.localizedDescription)"
            return false
        }
    }
}

struct NamingView: View {
    @Bindable var model: NamingModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text("Baaaa!")
                .font(.title2.bold())
                .foregroundStyle(UITheme.accent)
            Text("I just parachuted onto your desktop! What's my name?")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            TextField("Name your sheep...", text: $model.name)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused)
                .onSubmit(submit)
        }
        .padding(.horizontal, UITheme.margin)
        .padding(.top, UITheme.margin)
        .tint(UITheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The same glass action bar as every other dialog.
        .dialogBar {
            Text(model.errorMessage ?? "")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Return is handled by the field's `onSubmit`; a default-button
            // shortcut on top of it would submit twice.
            Button("OK", action: submit)
                .buttonStyle(.glassProminent)
                .tint(UITheme.accent)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        if model.submit() { WindowManager.shared.close(.naming) }
    }
}

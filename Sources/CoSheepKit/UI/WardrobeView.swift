import Observation
import SwiftUI

// Ex-public/wardrobe.html ("Wardrobe"): pick the main sheep's accessories.

/// The accessories the Wardrobe and the friends' accessory panels offer, in
/// page order (the Easter-only bunny ears and basket are left out).
let WARDROBE_ACCESSORY_IDS = [
    "party_hat", "crown", "top_hat", "wizard_hat", "chef_hat", "halo",
    "bandana", "headphones", "antenna", "flower", "sunglasses",
    "pirate_patch", "monocle", "mustache", "bow_tie", "scarf", "cape", "necklace",
]

@Observable
final class WardrobeModel: WindowModel {
    /// Name and category come from the real accessory registry.
    @ObservationIgnored let accessories: [AccessoryDef]

    /// Selected ids in insertion order (the page kept a JS `Set`); ids the
    /// grid doesn't offer are kept so a save doesn't drop them.
    private(set) var selected: [String] = []
    /// What the config held when the window loaded.
    private var loaded: [String] = []
    let saved = TimedFlag()
    var errorMessage: String?

    init() {
        let defs = getAccessoryDefs()
        accessories = WARDROBE_ACCESSORY_IDS.compactMap { id in defs.first { $0.id == id } }
    }

    func isSelected(_ id: String) -> Bool { selected.contains(id) }

    func toggle(_ id: String) {
        if let i = selected.firstIndex(of: id) {
            selected.remove(at: i)
        } else {
            selected.append(id)
        }
    }

    func binding(for id: String) -> Binding<Bool> {
        Binding(get: { self.isSelected(id) }, set: { on in
            if on != self.isSelected(id) { self.toggle(id) }
        })
    }

    func reload() {
        var seen = Set<String>()
        selected = WindowCommands.getAccessories().filter { seen.insert($0).inserted }
        loaded = selected
        errorMessage = nil
    }

    func save() {
        // Keep anything saved since the window loaded (a merchant's gift) —
        // the selection is a snapshot and would otherwise silently drop it
        let known = Set(loaded + selected)
        var seen = Set<String>()
        let arrived = WindowCommands.getAccessories().filter { !known.contains($0) && seen.insert($0).inserted }
        let accessories = selected + arrived
        do {
            try WindowCommands.saveAccessories(accessories)
            selected = accessories
            loaded = accessories
            errorMessage = nil
            saved.raise(for: 2)
        } catch {
            errorMessage = "Couldn't save accessories: \(error.localizedDescription)"
        }
    }
}

struct WardrobeView: View {
    @Bindable var model: WardrobeModel
    @Environment(\.displayScale) private var displayScale

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 14) {
            WindowHeading("Wardrobe")

            preview

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(model.accessories, id: \.id) { acc in
                        Toggle(isOn: model.binding(for: acc.id)) {
                            VStack(spacing: 2) {
                                Text(acc.name)
                                Text(acc.category.rawValue)
                                    .font(.system(size: 9))
                                    .textCase(.uppercase)
                                    .opacity(0.6)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .toggleStyle(.button)
                    }
                }
                .padding(2)
            }

            VStack(spacing: 8) {
                Button("Save") { model.save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.defaultAction)
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                } else {
                    FadingMessage(text: "Accessories saved!", visible: model.saved.isOn)
                }
            }
        }
        .padding(20)
        .tint(UITheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var preview: some View {
        Group {
            if let image = SheepPreview.image(accessories: model.selected, scale: displayScale) {
                Image(decorative: image, scale: displayScale)
                    .interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: SheepPreview.size.width, height: SheepPreview.size.height)
        .background(UITheme.previewBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 2))
        .accessibilityLabel("Sheep preview")
    }
}

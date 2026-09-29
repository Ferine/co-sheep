import Observation
import SwiftUI

// Ex-public/friends.html ("Manage Friends"): the flock, add / remove, and
// each friend's accessories.

@Observable
final class FriendsModel: WindowModel {
    static let personalities = [
        ChoiceOption(value: "wholesome", label: "Wholesome"),
        ChoiceOption(value: "snarky", label: "Snarky"),
        ChoiceOption(value: "chaotic", label: "Chaotic"),
        ChoiceOption(value: "passive-aggressive", label: "Passive-Aggressive"),
    ]

    /// No blue: that is Good Colleague's.
    static let colors = [
        ChoiceOption(value: "pink", label: "Pink"),
        ChoiceOption(value: "green", label: "Green"),
        ChoiceOption(value: "gold", label: "Gold"),
        ChoiceOption(value: "purple", label: "Purple"),
        ChoiceOption(value: "orange", label: "Orange"),
    ]

    /// `colorDots`: the swatch shown next to a friend.
    static let colorDots: [String: Color] = [
        "pink": Color(red: 0xe9 / 255, green: 0x45 / 255, blue: 0x60 / 255),
        "blue": Color(red: 0x4a / 255, green: 0x90 / 255, blue: 0xd9 / 255),
        "green": Color(red: 0x4e / 255, green: 0xcc / 255, blue: 0xa3 / 255),
        "gold": Color(red: 0xd4 / 255, green: 0xa5 / 255, blue: 0x20 / 255),
        "purple": Color(red: 0x9b / 255, green: 0x59 / 255, blue: 0xb6 / 255),
        "orange": Color(red: 0xe6 / 255, green: 0x7e / 255, blue: 0x22 / 255),
    ]

    /// `<input maxlength="20">`.
    static let maxNameLength = 20

    private(set) var friends: [FriendDef] = []
    var newName = "" {
        didSet {
            if newName.count > Self.maxNameLength { newName = String(newName.prefix(Self.maxNameLength)) }
        }
    }
    var newPersonality = "wholesome"
    var newColor = "pink"
    /// Friends whose accessories panel is open.
    var openPanels: Set<String> = []
    /// Unsaved accessory choices per friend, in insertion order (a JS `Set`).
    private(set) var drafts: [String: [String]] = [:]
    var pendingRemoval: FriendDef?
    private(set) var status = ""
    private(set) var statusIsError = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    var atCapacity: Bool { friends.count >= WindowCommands.maxFriends }

    var addButtonTitle: String { atCapacity ? "Max friends reached" : "Add Friend" }

    var canAdd: Bool {
        !atCapacity && !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reload() {
        friends = WindowCommands.getFriends()
        drafts = Dictionary(friends.map { ($0.id, $0.accessories) }, uniquingKeysWith: { first, _ in first })
        openPanels.formIntersection(friends.map(\.id))
    }

    /// `accId.replace(/_/g, ' ')`.
    static func chipTitle(_ id: String) -> String { id.replacingOccurrences(of: "_", with: " ") }

    static func dotColor(_ color: String) -> Color { colorDots[color] ?? colorDots["pink"]! }

    func isOn(_ accessory: String, for friendId: String) -> Bool {
        drafts[friendId]?.contains(accessory) ?? false
    }

    func toggle(_ accessory: String, for friendId: String) {
        var list = drafts[friendId] ?? []
        if let i = list.firstIndex(of: accessory) {
            list.remove(at: i)
        } else {
            list.append(accessory)
        }
        drafts[friendId] = list
    }

    func binding(_ accessory: String, for friendId: String) -> Binding<Bool> {
        Binding(get: { self.isOn(accessory, for: friendId) }, set: { on in
            if on != self.isOn(accessory, for: friendId) { self.toggle(accessory, for: friendId) }
        })
    }

    func panelBinding(for friendId: String) -> Binding<Bool> {
        Binding(get: { self.openPanels.contains(friendId) }, set: { open in
            if open { self.openPanels.insert(friendId) } else { self.openPanels.remove(friendId) }
        })
    }

    func saveAccessories(for friend: FriendDef) {
        do {
            try WindowCommands.saveFriendAccessories(id: friend.id, accessories: drafts[friend.id] ?? [])
            showStatus("Accessories saved!")
        } catch {
            showStatus("Couldn't save accessories: \(error.localizedDescription)", isError: true)
        }
    }

    func confirmRemoval() {
        guard let friend = pendingRemoval else { return }
        pendingRemoval = nil
        do {
            try WindowCommands.removeFriend(id: friend.id)
            friends.removeAll { $0.id == friend.id }
            drafts[friend.id] = nil
            openPanels.remove(friend.id)
            showStatus("Friend removed!")
        } catch {
            showStatus("Couldn't remove friend: \(error.localizedDescription)", isError: true)
        }
    }

    func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return }
        if atCapacity { return }
        do {
            try WindowCommands.addFriend(name: name, color: newColor, personality: newPersonality)
            newName = ""
            reload()
            showStatus("\(name) is parachuting in!")
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    func showStatus(_ message: String, isError: Bool = false) {
        statusTask?.cancel()
        status = message
        statusIsError = isError
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.status = ""
            self?.statusIsError = false
        }
    }
}

struct FriendsView: View {
    @Bindable var model: FriendsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WindowHeading(
                "Manage Friends",
                subtitle: "Good Colleague is always here. Add up to 4 more friends.")

            List {
                goodColleagueRow
                ForEach(model.friends, id: \.id) { friend in
                    FriendRow(model: model, friend: friend)
                }
            }
            .listStyle(.inset)

            Divider()

            addForm

            Text(model.status)
                .font(.callout)
                .foregroundStyle(model.statusIsError ? Color.red : UITheme.success)
                .frame(maxWidth: .infinity, minHeight: 18)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .tint(UITheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(
            "Remove \(model.pendingRemoval?.name ?? "this friend")?",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.pendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) { model.confirmRemoval() }
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: {
            Text("They'll parachute away forever.")
        }
    }

    private var goodColleagueRow: some View {
        HStack(spacing: 10) {
            Circle().fill(FriendsModel.dotColor("blue")).frame(width: 14, height: 14)
            Text("Good Colleague")
            Spacer()
            Text("snarky")
                .font(.caption2)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text("built-in")
                .font(.caption2)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add New Friend")
                .font(.headline)

            Form {
                TextField("Name", text: $model.newName, prompt: Text("Enter a name..."))
                    .onSubmit { model.add() }
                Picker("Personality", selection: $model.newPersonality) {
                    ForEach(FriendsModel.personalities) { Text($0.label).tag($0.value) }
                }
                Picker("Color", selection: $model.newColor) {
                    ForEach(FriendsModel.colors) { opt in
                        Label {
                            Text(opt.label)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(FriendsModel.dotColor(opt.value))
                        }
                        .tag(opt.value)
                    }
                }
            }
            .formStyle(.columns)

            Button(model.addButtonTitle) { model.add() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!model.canAdd)
        }
    }
}

private struct FriendRow: View {
    @Bindable var model: FriendsModel
    let friend: FriendDef

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 4)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(FriendsModel.dotColor(friend.color)).frame(width: 14, height: 14)
                Text(friend.name)
                Spacer()
                Text(friend.personality.isEmpty ? "wholesome" : friend.personality)
                    .font(.caption2)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Button("Acc.") {
                    model.panelBinding(for: friend.id).wrappedValue.toggle()
                }
                .help("Accessories")
                .controlSize(.small)
                Button("Remove") { model.pendingRemoval = friend }
                    .controlSize(.small)
            }

            if model.openPanels.contains(friend.id) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(WARDROBE_ACCESSORY_IDS, id: \.self) { accId in
                        Toggle(FriendsModel.chipTitle(accId), isOn: model.binding(accId, for: friend.id))
                            .toggleStyle(.button)
                            .controlSize(.small)
                    }
                }
                Button("Save Accessories") { model.saveAccessories(for: friend) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

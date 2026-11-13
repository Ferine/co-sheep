import Observation
import SwiftUI

// Ex-public/friend-memory.html ("Friend Relationships"): every friend's mood,
// affinity toward the others, stats and memory timeline.

@Observable
final class FriendMemoryModel: WindowModel {
    /// One card per loaded friend brain, by id.
    private(set) var data: [String: FriendRelationshipSummary] = [:]
    private(set) var selectedId: String?
    /// The selected friend's full brain.
    private(set) var brain: FriendBrain?

    private static let moodEmoji = [
        "happy": "\u{1F60A}", "grumpy": "\u{1F612}", "sleepy": "\u{1F634}", "excited": "\u{1F929}",
    ]

    /// Card ids in key order (the JSON object was sorted by key).
    var sortedIds: [String] { data.keys.sorted { $0.utf8Precedes($1) } }

    /// `${moodEmoji[mood] || ''} ${mood}`.
    static func moodLabel(_ mood: String) -> String { "\(moodEmoji[mood] ?? "") \(mood)" }

    /// Reload the cards; the selected friend's detail follows along (and is
    /// dropped if that friend is gone).
    func reload() {
        data = WindowCommands.getAllRelationships()
        if let id = selectedId {
            if data[id] != nil {
                brain = WindowCommands.getFriendMemory(id: id)
            } else {
                selectedId = nil
                brain = nil
            }
        }
    }

    func select(_ id: String) {
        selectedId = id
        brain = WindowCommands.getFriendMemory(id: id)
    }

    /// The selected friend's affinities, minus itself, in key order.
    var relationships: [(id: String, name: String, value: Int)] {
        guard let brain else { return [] }
        return brain.relationships
            .filter { $0.key != brain.id }
            .sorted { $0.key.utf8Precedes($1.key) }
            .map { (id: $0.key, name: data[$0.key]?.name ?? $0.key, value: $0.value) }
    }

    /// The 15 newest memories, newest first.
    var recentMemories: [FriendMemoryEntry] {
        guard let brain else { return [] }
        return Array(brain.memories.reversed().prefix(15))
    }

    /// Bar fill: `(val + 10) / 110`, clamped to 0…1.
    static func affinityFraction(_ value: Int) -> Double {
        max(0, min(1, Double(value + 10) / 110))
    }

    /// Bar color: red below zero, gold above 30, green above 10, else gray.
    static func affinityColor(_ value: Int) -> Color {
        if value < 0 { return UITheme.accent }
        if value > 30 { return Color(red: 1, green: 0xd7 / 255, blue: 0) }
        if value > 10 { return UITheme.success }
        return Color(white: 0x55 / 255)
    }
}

struct FriendMemoryView: View {
    @Bindable var model: FriendMemoryModel

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        // One scrolling form: the friend cards, then the picked friend's
        // details. It runs under the toolbar, where Refresh sits in glass.
        Form {
            Section {
                if model.data.isEmpty {
                    EmptyNote("No friend data yet. Friends build memories over time.")
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(model.sortedIds, id: \.self) { id in
                            card(id)
                        }
                    }
                }
            }

            if let brain = model.brain {
                detail(brain)
            }
        }
        .formStyle(.grouped)
        .tint(UITheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { model.reload() }
                    .help("Refresh")
            }
        }
    }

    private func card(_ id: String) -> some View {
        let friend = model.data[id]
        let selected = id == model.selectedId
        return Button {
            model.select(id)
        } label: {
            VStack(spacing: 4) {
                Text(friend?.name ?? id).font(.callout.bold())
                Text(FriendMemoryModel.moodLabel(friend?.mood ?? ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(
                selected ? AnyShapeStyle(UITheme.accent.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                in: UITheme.nestedCard)
            .overlay {
                if selected { UITheme.nestedCard.strokeBorder(UITheme.accent, lineWidth: 1.5) }
            }
            .contentShape(UITheme.nestedCard)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func detail(_ brain: FriendBrain) -> some View {
        Group {
            Section(brain.name) {
                stat("Mood", brain.mood)
                stat("Conversations (today)", brain.stats.conversationsToday)
                stat("Conversations (total)", brain.stats.conversationsTotal)
                stat("Times Petted", brain.stats.timesPetted)
                stat("Group Activities", brain.stats.groupActivities)
                stat("Days Alive", brain.stats.daysAlive)
            }

            Section("Relationships") {
                let rels = model.relationships
                if rels.isEmpty {
                    EmptyNote("No relationships yet.")
                } else {
                    ForEach(rels, id: \.id) { rel in
                        HStack(spacing: 8) {
                            Text(rel.name).frame(width: 90, alignment: .leading)
                            ProgressView(value: FriendMemoryModel.affinityFraction(rel.value))
                                .tint(FriendMemoryModel.affinityColor(rel.value))
                            Text("\(rel.value)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }

            Section("Recent Memories") {
                let memories = model.recentMemories
                if memories.isEmpty {
                    EmptyNote("No memories yet. They'll form over time.")
                } else {
                    ForEach(Array(memories.enumerated()), id: \.offset) { _, m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.text)
                            Text(m.timestamp).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).bold().foregroundStyle(UITheme.accent)
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        stat(label, String(value))
    }
}

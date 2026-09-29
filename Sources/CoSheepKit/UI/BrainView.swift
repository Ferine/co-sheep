import Observation
import SwiftUI

// Ex-public/memory.html ("Sheep's Brain"): opinions, today's tallies, the diary.

@Observable
final class BrainModel: WindowModel {
    enum Tab: String, CaseIterable, Identifiable {
        case opinions, counts, journal
        var id: String { rawValue }

        var title: String {
            switch self {
            case .opinions: "Opinions"
            case .counts: "Today's Tallies"
            case .journal: "Diary"
            }
        }
    }

    /// How a stretch of diary text is styled (`renderJournal`).
    enum JournalStyle: Equatable {
        case plain
        /// `# ` / `## ` heading lines: bold teal.
        case heading
        /// The `**Comment**:` marker, shown as a bold accent "Comment:".
        case commentLabel
    }

    struct JournalSegment: Equatable {
        var text: String
        var style: JournalStyle
    }

    var tab: Tab = .opinions
    var display = BrainDisplay(
        opinions: [], todayCounts: [:], totalComments: 0, totalInteractions: 0, todayJournal: "")

    func reload() {
        display = WindowCommands.getMemory()
    }

    /// Opinions, most-seen first; ties keep their stored order (JS sort is stable).
    var sortedOpinions: [Opinion] {
        display.opinions.enumerated()
            .sorted { a, b in
                a.element.timesSeen != b.element.timesSeen
                    ? a.element.timesSeen > b.element.timesSeen : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Tallies, biggest first; ties in key order (the JSON object was sorted by key).
    var sortedCounts: [(key: String, count: Int)] {
        display.todayCounts
            .sorted { a, b in
                a.value != b.value ? a.value > b.value : a.key.utf8Precedes(b.key)
            }
            .map { (key: $0.key, count: $0.value) }
    }

    /// An opinion counts as "hot" from 5 sightings on.
    static func isHot(_ op: Opinion) -> Bool { op.timesSeen >= 5 }

    /// `op.category || 'opinion'`.
    static func category(_ op: Opinion) -> String { op.category.isEmpty ? "opinion" : op.category }

    /// One diary line as styled segments: `#`/`##` lines are headings,
    /// `**Comment**:` becomes a highlighted "Comment:".
    static func journalSegments(_ line: String) -> [JournalSegment] {
        if line.hasPrefix("# ") || line.hasPrefix("## ") {
            return [JournalSegment(text: line, style: .heading)]
        }
        let marker = "**Comment**:"
        guard line.contains(marker) else { return [JournalSegment(text: line, style: .plain)] }
        var segments: [JournalSegment] = []
        let parts = line.components(separatedBy: marker)
        for (i, part) in parts.enumerated() {
            if i > 0 { segments.append(JournalSegment(text: "Comment:", style: .commentLabel)) }
            if !part.isEmpty { segments.append(JournalSegment(text: part, style: .plain)) }
        }
        return segments
    }

    /// The whole diary, styled; nil when there is nothing to show
    /// (`!text || !text.trim()`).
    static func journalText(_ text: String) -> AttributedString? {
        if text.rustTrimmed().isEmpty { return nil }
        var result = AttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            for seg in journalSegments(line) {
                var piece = AttributedString(seg.text)
                switch seg.style {
                case .plain: break
                case .heading:
                    piece.font = .system(.caption, design: .monospaced).bold()
                    piece.foregroundColor = UITheme.success
                case .commentLabel:
                    piece.font = .system(.caption, design: .monospaced).bold()
                    piece.foregroundColor = UITheme.accent
                }
                result.append(piece)
            }
            if i < lines.count - 1 { result.append(AttributedString("\n")) }
        }
        return result
    }
}

struct BrainView: View {
    @Bindable var model: BrainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WindowHeading(
                "Sheep's Brain", subtitle: "What your sheep knows, believes, and obsesses over")

            GroupBox {
                HStack(spacing: 18) {
                    stat("Comments", model.display.totalComments)
                    stat("Interactions", model.display.totalInteractions)
                    stat("Opinions", model.display.opinions.count)
                    Spacer()
                }
                .padding(2)
            }

            HStack {
                Picker("", selection: $model.tab) {
                    ForEach(BrainModel.Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Button("Refresh") { model.reload() }
            }

            switch model.tab {
            case .opinions: opinions
            case .counts: counts
            case .journal: journal
            }
        }
        .padding(20)
        .tint(UITheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text("\(label):").foregroundStyle(.secondary)
            Text("\(value)").bold().foregroundStyle(UITheme.accent)
        }
        .font(.callout)
    }

    // MARK: Opinions

    @ViewBuilder private var opinions: some View {
        if model.display.opinions.isEmpty {
            EmptyNote("No opinions yet. The sheep will start forming beliefs as it watches you.")
            Spacer(minLength: 0)
        } else {
            List(model.sortedOpinions) { op in
                OpinionRow(op: op)
            }
        }
    }

    // MARK: Tallies

    @ViewBuilder private var counts: some View {
        if model.display.todayCounts.isEmpty {
            EmptyNote("No tallies yet today.")
            Spacer(minLength: 0)
        } else {
            List(model.sortedCounts, id: \.key) { row in
                HStack {
                    Text(row.key)
                    Spacer()
                    Text("\(row.count)x").bold().foregroundStyle(UITheme.accent)
                }
            }
        }
    }

    // MARK: Diary

    @ViewBuilder private var journal: some View {
        if let text = BrainModel.journalText(model.display.todayJournal) {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        } else {
            EmptyNote("No diary entries today.")
            Spacer(minLength: 0)
        }
    }
}

private struct OpinionRow: View {
    let op: Opinion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(op.topic)
                    .font(.caption.bold())
                    .textCase(.uppercase)
                    .foregroundStyle(UITheme.accent)
                Spacer()
                Text("seen \(op.timesSeen)x")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .foregroundStyle(BrainModel.isHot(op) ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .background(
                        BrainModel.isHot(op) ? AnyShapeStyle(UITheme.accent) : AnyShapeStyle(.quaternary),
                        in: Capsule())
            }
            Text(op.opinion)
            HStack(spacing: 6) {
                CategoryTag(category: BrainModel.category(op))
                Text("First: \(op.firstSeen) · Last: \(op.lastSeen)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

/// `.category-tag` — habit / fact / opinion / pattern each get their own hue.
private struct CategoryTag: View {
    let category: String

    private var color: Color {
        switch category {
        case "habit": UITheme.success
        case "fact": Color(red: 0x6e / 255, green: 0xb5 / 255, blue: 0xff / 255)
        case "opinion": UITheme.accent
        case "pattern": Color(red: 0xf0 / 255, green: 0xc0 / 255, blue: 0x40 / 255)
        default: .secondary
        }
    }

    var body: some View {
        Text(category)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
    }
}

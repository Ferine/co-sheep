import Foundation
import Testing
@testable import CoSheepKit

// Ex-memory.rs tests + persistence/journal/context coverage.
extension BrainTests {
    @Suite("memory")
    struct MemoryTests {
        private func opinion(_ topic: String, _ text: String, _ timesSeen: Int, _ lastSeen: String) -> Opinion {
            Opinion(
                topic: topic, opinion: text, timesSeen: timesSeen,
                firstSeen: "2026-01-01", lastSeen: lastSeen, category: "habit")
        }

        private let today = naiveDate(2026, 7, 4)

        // MARK: ported from memory.rs

        @Test func recencyHalvesScorePerHalfLife() {
            let fresh = opinion("a", "x", 10, "2026-07-04 10:00")
            let twoWeeks = opinion("b", "x", 10, "2026-06-20 10:00")
            let none = Set<String>()
            let sFresh = Memory.scoreOpinion(fresh, queryTokens: none, today: today)
            let sOld = Memory.scoreOpinion(twoWeeks, queryTokens: none, today: today)
            #expect(abs(sFresh - 10.0) < 1e-9)
            #expect(abs(sOld - 5.0) < 1e-9)
        }

        @Test func unparseableLastSeenScoresMidpoint() {
            let bad = opinion("a", "x", 10, "garbage")
            #expect(abs(Memory.scoreOpinion(bad, queryTokens: [], today: today) - 5.0) < 1e-9)
        }

        @Test func staleStrongOpinionLosesToFreshRelevantOne() {
            // Strong stale opinion vs weak fresh one that matches the query
            let strong = opinion("tab_hoarding", "hoards tabs", 40, "2026-03-01 10:00")
            let weak = opinion("twitter_usage", "always on twitter", 3, "2026-07-03 10:00")
            let picked = Memory.selectOpinions(
                [strong, weak], query: "Twitter home timeline trending", today: today, limit: 20)
            #expect(picked[0].topic == "twitter_usage")
        }

        @Test func relevanceBoostIsCapped() {
            let op = opinion("twitter_usage", "twitter twitter twitter", 1, "2026-07-04 10:00")
            let q = Memory.tokenize("twitter usage twitter twitter")
            #expect(Memory.relevanceBoost(op, queryTokens: q) <= 2.0 + 1e-9)
        }

        @Test func shortTokensAreDropped() {
            let toks = Memory.tokenize("Go is ok C no")
            #expect(toks.isEmpty)
        }

        @Test func selectionCapsAtTwenty() {
            let ops = (0..<30).map { opinion("t\($0)", "x", $0 + 1, "2026-07-04 10:00") }
            let picked = Memory.selectOpinions(ops, query: nil, today: today, limit: 20)
            #expect(picked.count == 20)
            #expect(picked[0].topic == "t29") // highest conviction first
        }

        @Test func canonicalizeLowercasesAndUnderscores() {
            #expect(Memory.canonicalizeTopic("  Twitter Usage ") == "twitter_usage")
            #expect(Memory.canonicalizeTopic("dark_mode") == "dark_mode")
            #expect(Memory.canonicalizeTopic("Tab   Hoarding") == "tab_hoarding")
        }

        @Test func normalizeOpinionsFoldsLegacyTopicVariants() {
            var ops = [
                Opinion(
                    topic: "Twitter Usage", opinion: "old text", timesSeen: 5,
                    firstSeen: "2026-02-01", lastSeen: "2026-06-01 10:00", category: "habit"),
                Opinion(
                    topic: "twitter_usage", opinion: "new text", timesSeen: 3,
                    firstSeen: "2026-03-01", lastSeen: "2026-07-01 10:00", category: "habit"),
                Opinion(
                    topic: "dark_mode", opinion: "likes it dark", timesSeen: 1,
                    firstSeen: "2026-04-01", lastSeen: "2026-04-01 10:00", category: "fact"),
            ]
            Memory.normalizeOpinions(&ops)
            #expect(ops.count == 2)
            #expect(ops[0].topic == "twitter_usage")
            #expect(ops[0].timesSeen == 8)
            #expect(ops[0].firstSeen == "2026-02-01")
            #expect(ops[0].lastSeen == "2026-07-01 10:00")
            #expect(ops[0].opinion == "new text")
            #expect(ops[1].topic == "dark_mode")
        }

        @Test func listsJournalDaysSortedIgnoringStrays() throws {
            try withBrainRoot { dir in
                let journal = dir.appendingPathComponent("journal-list", isDirectory: true)
                for name in ["2026-07-02.md", "2026-06-30.md", "notes.md", "2026-07-01.md"] {
                    try write("x", to: journal.appendingPathComponent(name))
                }
                let days = Memory.listJournalDays(in: journal)
                #expect(days == ["2026-06-30", "2026-07-01", "2026-07-02"])
            }
        }

        // MARK: new — helpers

        @Test func tailAtCharBoundaryNeverSplitsMultibyteCharacters() {
            let s = "abcæøå"                       // a b c + 3×2 bytes = 9 bytes
            #expect(Memory.tailAtCharBoundary(s, maxBytes: 100) == s)
            #expect(Memory.tailAtCharBoundary(s, maxBytes: 4) == "øå")   // exactly two characters
            #expect(Memory.tailAtCharBoundary(s, maxBytes: 5) == "øå")   // cut lands inside 'æ' → moves forward
            #expect(Memory.tailAtCharBoundary(s, maxBytes: 6) == "æøå")
            #expect(Memory.tailAtCharBoundary(s, maxBytes: 0) == "")
        }

        @Test func tokenizeCountsBytesNotCharacters() {
            // 'æø' is 2 chars but 4 bytes, so Rust's `t.len() >= 3` keeps it.
            #expect(Memory.tokenize("æø") == ["æø"])
            #expect(Memory.tokenize("ab") == [])
            #expect(Memory.tokenize("Rust-2026, tabs/spaces") == ["rust", "2026", "tabs", "spaces"])
        }

        @Test func naiveDateParsesAndDoesArithmetic() {
            #expect(NaiveDate(parsing: "2026-07-04") == naiveDate(2026, 7, 4))
            #expect(NaiveDate(parsing: "2026-7-4") == naiveDate(2026, 7, 4))
            #expect(NaiveDate(parsing: "2026-02-30") == nil)
            #expect(NaiveDate(parsing: "2026-13-01") == nil)
            #expect(NaiveDate(parsing: "2026-07-04 10:00") == nil)
            #expect(NaiveDate(parsing: "garbage") == nil)
            #expect(NaiveDate(parsing: "") == nil)
            #expect(naiveDate(2026, 3, 1).addingDays(-1).description == "2026-02-28")
            #expect(naiveDate(2024, 3, 1).addingDays(-1).description == "2024-02-29")
            #expect(naiveDate(2026, 1, 1).addingDays(-1).description == "2025-12-31")
            #expect(naiveDate(2026, 7, 4).daysSince(naiveDate(2026, 6, 20)) == 14)
            #expect(naiveDate(1970, 1, 1).epochDays == 0)
            #expect(NaiveDate(epochDays: 20_638) == naiveDate(2026, 7, 4))
            #expect(naiveDate(2026, 7, 4) > naiveDate(2026, 7, 3))
        }

        @Test func rustFileStemMatchesPathFileStem() {
            #expect(rustFileStem("2026-07-02.md") == "2026-07-02")
            #expect(rustFileStem("notes") == "notes")
            #expect(rustFileStem(".DS_Store") == ".DS_Store")
            #expect(rustFileStem("a.b.json") == "a.b")
        }

        // MARK: new — persistence

        @Test func loadBrainWithoutAFileIsTheDefaultBrain() {
            withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                let b = Memory.loadBrain()
                #expect(b.opinions.isEmpty)
                #expect(b.countsDate == "2026-07-04")
                #expect(b.totalComments == 0)
                #expect(b.lastReflectionDate == "")
            }
        }

        @Test func opinionsJSONRoundTripKeepsTheRustShape() throws {
            try withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                // A brain as the Rust app wrote it, incl. a legacy topic variant.
                try write(#"""
                {
                  "opinions": [
                    {"topic": "Twitter Usage", "opinion": "chronically online", "times_seen": 4,
                     "first_seen": "2026-06-01", "last_seen": "2026-07-03 21:15", "category": "habit"}
                  ],
                  "today_counts": {"app:browser": 3},
                  "counts_date": "2026-07-04",
                  "total_comments": 12,
                  "total_interactions": 5,
                  "last_reflection_date": "2026-07-03",
                  "backfill_cursor": "2026-07-02",
                  "some_future_field": true
                }
                """#, to: Paths.opinions)
                var b = Memory.loadBrain()
                #expect(b.opinions.map(\.topic) == ["twitter_usage"])
                #expect(b.todayCounts == ["app:browser": 3])
                #expect(b.totalComments == 12)
                #expect(b.lastReflectionDate == "2026-07-03")
                #expect(b.backfillCursor == "2026-07-02")

                try Memory.updateBrain { $0.totalInteractions += 1 }
                b = Memory.loadBrain()
                #expect(b.totalInteractions == 6)

                let json = try #require(try readJSON(Paths.opinions).objectValue)
                #expect(Set(json.keys) == [
                    "opinions", "today_counts", "counts_date", "total_comments",
                    "total_interactions", "last_reflection_date", "backfill_cursor",
                ])
                let op = try #require(json["opinions"]?.arrayValue?.first?.objectValue)
                #expect(Set(op.keys) == ["topic", "opinion", "times_seen", "first_seen", "last_seen", "category"])
                #expect(op["times_seen"] == .number(4))
            }
        }

        @Test func brainMissingOptionalFieldsDefaultsThem() throws {
            try withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                try write(
                    #"{"opinions":[],"today_counts":{},"counts_date":"2026-07-04","total_comments":1,"total_interactions":2}"#,
                    to: Paths.opinions)
                let b = Memory.loadBrain()
                #expect(b.totalComments == 1)
                #expect(b.lastReflectionDate == "")
                #expect(b.backfillCursor == "")
            }
        }

        @Test func brainMissingARequiredFieldLoadsAsDefault() throws {
            // Rust: serde error → `unwrap_or_default()` (the brain resets).
            try withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                try write(#"{"opinions":[],"total_comments":9}"#, to: Paths.opinions)
                #expect(Memory.loadBrain().totalComments == 0)
                try write("not json at all", to: Paths.opinions)
                #expect(Memory.loadBrain().totalComments == 0)
            }
        }

        @Test func newDayClearsTodayCounts() throws {
            try withBrainRoot(now: localDate(2026, 7, 5)) { _ in
                try write(
                    #"{"opinions":[],"today_counts":{"x":4},"counts_date":"2026-07-04","total_comments":0,"total_interactions":0}"#,
                    to: Paths.opinions)
                let b = Memory.loadBrain()
                #expect(b.todayCounts.isEmpty)
                #expect(b.countsDate == "2026-07-05")
            }
        }

        @Test func saveOpinionIgnoresABlankTopic() throws {
            try withBrainRoot { _ in
                try Memory.saveOpinion(topic: "  ", opinion: "whatever", category: "fact")
                #expect(Memory.loadBrain().opinions.isEmpty)
            }
        }

        @Test func saveOpinionCreatesThenStrengthens() throws {
            try withBrainRoot(now: localDate(2026, 7, 4, 9, 5)) { _ in
                try Memory.saveOpinion(topic: "Twitter Usage", opinion: "addicted", category: "habit")
                var b = Memory.loadBrain()
                #expect(b.opinions.count == 1)
                let first = b.opinions[0]
                #expect(first.topic == "twitter_usage")
                #expect(first.timesSeen == 1)
                #expect(first.firstSeen == "2026-07-04")
                #expect(first.lastSeen == "2026-07-04 09:05")
                #expect(first.category == "habit")

                SimClock.nowSource = { localDate(2026, 7, 5, 22, 30).timeIntervalSince1970 * 1000 }
                try Memory.saveOpinion(topic: "twitter usage", opinion: "", category: "fact")
                b = Memory.loadBrain()
                #expect(b.opinions.count == 1)
                #expect(b.opinions[0].timesSeen == 2)
                #expect(b.opinions[0].opinion == "addicted")   // empty text keeps the old opinion
                #expect(b.opinions[0].category == "habit")      // category only set on creation
                #expect(b.opinions[0].firstSeen == "2026-07-04")
                #expect(b.opinions[0].lastSeen == "2026-07-05 22:30")

                try Memory.saveOpinion(topic: "twitter_usage", opinion: "worse", category: "habit")
                #expect(Memory.loadBrain().opinions[0].opinion == "worse")
            }
        }

        @Test func countersAndInteractions() throws {
            try withBrainRoot(now: localDate(2026, 7, 4, 14, 0)) { _ in
                #expect(Memory.incrementToday("app:browser") == 1)
                #expect(Memory.incrementToday("app:browser") == 2)
                #expect(Memory.incrementToday("app:editor") == 1)
                Memory.recordComment()
                Memory.recordComment()
                Memory.recordInteraction("petted")
                let b = Memory.loadBrain()
                #expect(b.todayCounts == ["app:browser": 2, "app:editor": 1])
                #expect(b.totalComments == 2)
                #expect(b.totalInteractions == 1)
                let journal = try Memory.getTodayJournal()
                #expect(journal.contains("*My human petted me!*"))
            }
        }

        @Test func snapshotOpinionsWritesTheBackupFile() throws {
            try withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                Memory.snapshotOpinions()   // no file yet: nothing happens
                #expect(!FileManager.default.fileExists(atPath: Paths.opinionsBackup.path))
                try Memory.saveOpinion(topic: "a_topic", opinion: "one", category: "fact")
                Memory.snapshotOpinions()
                let original = try Data(contentsOf: Paths.opinions)
                #expect(try Data(contentsOf: Paths.opinionsBackup) == original)
                try Memory.saveOpinion(topic: "b_topic", opinion: "two", category: "fact")
                Memory.snapshotOpinions()   // one generation: overwritten
                #expect(try Data(contentsOf: Paths.opinionsBackup) == Data(contentsOf: Paths.opinions))
            }
        }

        // MARK: new — journal

        @Test func journalFirstEntryGetsAHeaderAndLaterOnesDoNot() throws {
            try withBrainRoot(now: localDate(2026, 7, 4, 15, 7)) { _ in
                try Config.saveConfig(name: "Dolly")
                try Memory.appendJournal("first")
                SimClock.nowSource = { localDate(2026, 7, 4, 9, 30).timeIntervalSince1970 * 1000 }
                try Memory.appendJournal("second")
                let text = try String(
                    contentsOf: Paths.journal.appendingPathComponent("2026-07-04.md"), encoding: .utf8)
                #expect(text == "# July 04, 2026 — Dolly's Diary\n\n## 03:07 PM\nfirst\n\n## 09:30 AM\nsecond\n")
            }
        }

        @Test func journalHeaderFallsBackToSheepWithoutAConfig() throws {
            try withBrainRoot(now: localDate(2026, 12, 31, 0, 5)) { _ in
                try Memory.appendJournal("late")
                let text = try String(
                    contentsOf: Paths.journal.appendingPathComponent("2026-12-31.md"), encoding: .utf8)
                #expect(text == "# December 31, 2026 — Sheep's Diary\n\n## 12:05 AM\nlate\n")
            }
        }

        @Test func todayJournalIsTheLast2000Bytes() throws {
            try withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                #expect(try Memory.getTodayJournal() == "")
                let body = String(repeating: "æ", count: 1500)  // 3000 bytes
                try write(body, to: Paths.journal.appendingPathComponent("2026-07-04.md"))
                let tail = try Memory.getTodayJournal()
                #expect(tail.utf8.count == 2000)
                #expect(tail.allSatisfy { $0 == "æ" })
            }
        }

        @Test func readJournalForReturnsNilForMissingDays() throws {
            try withBrainRoot { _ in
                try write("hei", to: Paths.journal.appendingPathComponent("2026-07-03.md"))
                #expect(Memory.readJournalFor("2026-07-03") == "hei")
                #expect(Memory.readJournalFor("2026-07-02") == nil)
            }
        }

        // MARK: new — context

        @Test func recentContextStartsWithJustStatsOnAFreshBrain() throws {
            try withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                let ctx = try Memory.getRecentContext(query: nil)
                #expect(ctx == "## Stats\nTotal comments made: 0\nTotal interactions with human: 0")
            }
        }

        @Test func recentContextListsOpinionsTalliesStatsAndJournal() throws {
            try withBrainRoot(now: localDate(2026, 7, 4, 10, 0)) { _ in
                try Memory.saveOpinion(topic: "dark_mode", opinion: "likes it dark", category: "fact")
                try Memory.saveOpinion(topic: "dark_mode", opinion: "still dark", category: "fact")
                Memory.incrementToday("b_key")
                Memory.incrementToday("a_key")
                Memory.incrementToday("a_key")
                Memory.recordComment()
                try Memory.appendJournal("watched the human")
                let ctx = try Memory.getRecentContext(query: "dark")
                let journal = try Memory.getTodayJournal()
                #expect(ctx == """
                ## Your opinions about your human (strongest first)
                - [dark_mode] still dark (seen 2 times, last: 2026-07-04 10:00)

                ## Today's tallies
                - a_key: 2 times today
                - b_key: 1 times today

                ## Stats
                Total comments made: 1
                Total interactions with human: 0

                ## Recent diary entries (today)
                \(journal)
                """)
            }
        }

        @Test func recentContextTrimsLongJournalToWholeLines() throws {
            try withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                let lines = (0..<200).map { "line-\($0)-padding-padding-padding" }
                try write(lines.joined(separator: "\n"), to: Paths.journal.appendingPathComponent("2026-07-04.md"))
                let ctx = try Memory.getRecentContext(query: nil)
                let diary = try #require(ctx.components(separatedBy: "## Recent diary entries (today)\n").last)
                #expect(diary.utf8.count <= 1200)
                #expect(diary.hasPrefix("line-"))          // starts at a line boundary
                #expect(diary.hasSuffix("line-199-padding-padding-padding"))
            }
        }

        @Test func brainForDisplayMirrorsTheMemoryViewerPayload() throws {
            try withBrainRoot(now: localDate(2026, 7, 4)) { _ in
                try Memory.saveOpinion(topic: "x_topic", opinion: "y", category: "habit")
                Memory.incrementToday("k")
                Memory.recordInteraction("petted")
                let d = Memory.getBrainForDisplay()
                #expect(d.opinions.map(\.topic) == ["x_topic"])
                #expect(d.todayCounts == ["k": 1])
                #expect(d.totalInteractions == 1)
                #expect(d.todayJournal.contains("petted"))
                let data = try JSONEncoder().encode(d)
                let json = try #require(try JSONDecoder().decode(JSONValue.self, from: data).objectValue)
                #expect(Set(json.keys) == [
                    "opinions", "today_counts", "total_comments", "total_interactions", "today_journal",
                ])
            }
        }
    }
}

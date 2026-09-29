import Foundation
import Testing
@testable import CoSheepKit

// Ex-reflect.rs tests (17) + the async scheduling that was untested in Rust.
extension BrainTests {
    @Suite("reflect")
    struct ReflectTests {
        private func opinion(_ topic: String, _ timesSeen: Int, _ lastSeen: String) -> Opinion {
            Opinion(
                topic: topic, opinion: "about \(topic)", timesSeen: timesSeen,
                firstSeen: "2026-01-01", lastSeen: lastSeen, category: "habit")
        }

        private func brain(_ opinions: [Opinion]) -> SheepBrain {
            var b = SheepBrain()
            b.opinions = opinions
            return b
        }

        private let today = naiveDate(2026, 7, 4)

        /// Mutable flag the loop's `isVisionTickRunning` closure can observe.
        private final class Flag {
            var value: Bool
            init(_ value: Bool) { self.value = value }
        }

        // MARK: ported from reflect.rs

        @Test func parsesOpsWithMarkdownFences() throws {
            let raw = "```json\n{\"ops\": [{\"op\": \"prune\", \"topic\": \"dead\"}]}\n```"
            let ops = try Reflect.parseOps(raw)
            #expect(ops == [.prune(topic: "dead")])
        }

        @Test func parseRejectsGarbage() {
            #expect(throws: (any Error).self) {
                try Reflect.parseOps("the sheep dreams of electric grass")
            }
        }

        @Test func parsesEmptyOps() throws {
            #expect(try Reflect.parseOps(#"{"ops": []}"#).isEmpty)
        }

        @Test func mergeSumsConvictionAndKeepsDateRange() {
            var a = opinion("twitter_usage", 10, "")
            a.firstSeen = "2026-02-01"
            a.lastSeen = "2026-06-01 10:00"
            var b2 = opinion("twitter_habit", 5, "")
            b2.firstSeen = "2026-03-01"
            b2.lastSeen = "2026-07-01 10:00"
            var b = brain([a, b2])
            let ops: [ReflectOp] = [.merge(
                from: ["twitter_usage", "twitter_habit"], into: "twitter_usage", text: "chronically online")]
            let stats = Reflect.applyOps(&b, ops, .daily(today))
            #expect(stats.merged == 1)
            #expect(b.opinions.count == 1)
            let m = b.opinions[0]
            #expect(m.topic == "twitter_usage")
            #expect(m.timesSeen == 15)
            #expect(m.firstSeen == "2026-02-01")
            #expect(m.lastSeen == "2026-07-01 10:00")
            #expect(m.opinion == "chronically online")
        }

        @Test func mergeWithFewerThanTwoRealSourcesIsSkipped() {
            var b = brain([opinion("a", 3, "2026-07-01 10:00")])
            let ops: [ReflectOp] = [.merge(from: ["a", "ghost"], into: "a", text: "")]
            let stats = Reflect.applyOps(&b, ops, .daily(today))
            #expect(stats.merged == 0)
            #expect(stats.skipped == 1)
            #expect(b.opinions[0].timesSeen == 3)
        }

        @Test func pruneRespectsStrengthAndIdleness() {
            var b = brain([
                opinion("strong_active", 40, "2026-07-03 10:00"), // strong + fresh: protected
                opinion("weak", 1, "2026-07-03 10:00"),           // weak: prunable
                opinion("stale", 40, "2026-05-01 10:00"),         // idle > 21d: prunable
            ])
            let ops: [ReflectOp] = [
                .prune(topic: "strong_active"), .prune(topic: "weak"), .prune(topic: "stale"),
            ]
            let stats = Reflect.applyOps(&b, ops, .daily(today))
            #expect(stats.pruned == 2)
            #expect(stats.skipped == 1)
            #expect(b.opinions.contains { $0.topic == "strong_active" })
        }

        @Test func pruneCappedPerRun() {
            var b = brain((0..<5).map { opinion("w\($0)", 1, "2026-07-03 10:00") })
            let ops: [ReflectOp] = (0..<5).map { .prune(topic: "w\($0)") }
            let stats = Reflect.applyOps(&b, ops, .daily(today))
            #expect(stats.pruned == 3)
            #expect(b.opinions.count == 2)
        }

        @Test func backfillPolicyRejectsAllPrunes() {
            var b = brain([opinion("weak", 1, "2026-07-03 10:00")])
            let stats = Reflect.applyOps(&b, [.prune(topic: "weak")], .backfill(today))
            #expect(stats.pruned == 0)
            #expect(b.opinions.count == 1)
        }

        @Test func unparseableLastSeenCountsAsNotIdle() {
            var b = brain([opinion("mystery", 40, "garbage")])
            let stats = Reflect.applyOps(&b, [.prune(topic: "mystery")], .daily(today))
            #expect(stats.pruned == 0) // strong + not-provably-idle: protected
        }

        @Test func addCapsAndSkipsExisting() {
            var b = brain([opinion("existing", 3, "2026-07-03 10:00")])
            var ops: [ReflectOp] = (0..<7).map {
                .add(topic: "new_\($0)", text: "x", category: "habit")
            }
            ops.append(.add(topic: "existing", text: "dup", category: nil))
            let stats = Reflect.applyOps(&b, ops, .daily(today))
            #expect(stats.added == 5)
            #expect(stats.skipped == 3) // 2 over cap + 1 duplicate
            #expect(b.opinions.count == 6)
        }

        @Test func updateReplacesTextOnlyForKnownTopics() {
            var b = brain([opinion("known", 3, "2026-07-03 10:00")])
            let ops: [ReflectOp] = [
                .update(topic: "known", text: "new view"),
                .update(topic: "ghost", text: "boo"),
            ]
            let stats = Reflect.applyOps(&b, ops, .daily(today))
            #expect(stats.updated == 1)
            #expect(stats.skipped == 1)
            #expect(b.opinions[0].opinion == "new view")
            #expect(b.opinions[0].timesSeen == 3)
        }

        @Test func reflectionPromptListsOpinionsAndJournal() {
            let ops = [opinion("twitter_usage", 5, "2026-07-01 10:00")]
            let p = Reflect.buildReflectionPrompt(
                ops, "## 10:00 AM\nScrolled twitter again.", "Diary for 2026-07-03")
            #expect(p.contains("[twitter_usage]"))
            #expect(p.contains("Scrolled twitter again."))
            #expect(p.contains("Diary for 2026-07-03"))
            #expect(p.contains(#""ops""#))
        }

        @Test func reflectionPromptBudgetsLongJournals() {
            let ops = [opinion("a", 1, "2026-07-01 10:00")]
            let huge = String(repeating: "baa ", count: 2000) // 8000 bytes
            let p = Reflect.buildReflectionPrompt(ops, huge, "Diary")
            #expect(p.utf8.count < 6500)
        }

        @Test func reflectionPromptCapsOpinionCount() {
            let many = (0..<80).map { opinion("t\($0)", $0, "2026-07-01 10:00") }
            let p = Reflect.buildReflectionPrompt(many, "x", "Diary")
            // Strongest survive the cap; weakest are cut
            #expect(p.contains("[t79]"))
            #expect(!p.contains("[t0]"))
        }

        @Test func backfillPicksOldestUnprocessedDayBeforeBound() {
            let days = ["2026-06-30", "2026-07-01", "2026-07-03", "2026-07-04"]
            #expect(Reflect.pendingBackfillDay(days, "", "2026-07-04") == "2026-06-30")
            #expect(Reflect.pendingBackfillDay(days, "2026-06-30", "2026-07-04") == "2026-07-01")
            #expect(Reflect.pendingBackfillDay(days, "2026-07-01", "2026-07-04") == "2026-07-03")
            // Today is excluded; cursor at last eligible day means done
            #expect(Reflect.pendingBackfillDay(days, "2026-07-03", "2026-07-04") == nil)
            // Regression: bound = yesterday (today is 2026-07-04) must exclude
            // yesterday itself — that day belongs to the daily reflection pass.
            let twoDayGap = ["2026-07-01", "2026-07-03"]
            #expect(Reflect.pendingBackfillDay(twoDayGap, "2026-07-01", "2026-07-03") == nil)
        }

        @Test func steadyStateCursorAdvancePreventsDoubleProcessing() {
            let days = ["2026-07-01", "2026-07-02", "2026-07-03"]
            // Archive drained to N-2; daily pass about to consolidate 07-03
            #expect(Reflect.advancedCursor(days, "2026-07-02", "2026-07-03") == "2026-07-03")
            // Next day: cursor now 07-03, backfill bound 07-04 — nothing pending
            let days2 = ["2026-07-01", "2026-07-02", "2026-07-03", "2026-07-04"]
            #expect(Reflect.pendingBackfillDay(days2, "2026-07-03", "2026-07-04") == nil)
        }

        @Test func cursorNotAdvancedWhileArchivePending() {
            // App was off: 07-01 and 07-02 journals never processed; daily does 07-03
            let days = ["2026-07-01", "2026-07-02", "2026-07-03"]
            #expect(Reflect.advancedCursor(days, "2026-06-30", "2026-07-03") == nil)
        }

        // MARK: new — parsing / applying details

        @Test func parsesEveryOpVariantWithSerdeDefaults() throws {
            let raw = #"""
            {"ops": [
              {"op": "merge", "from": ["a", "b"], "into": "a"},
              {"op": "merge", "from": ["a"], "into": "a", "text": "t", "extra": 1},
              {"op": "update", "topic": "k", "text": "new"},
              {"op": "prune", "topic": "k"},
              {"op": "add", "topic": "n", "text": "x"},
              {"op": "add", "topic": "n", "text": "x", "category": null},
              {"op": "add", "topic": "n", "text": "x", "category": "habit"}
            ]}
            """#
            #expect(try Reflect.parseOps(raw) == [
                .merge(from: ["a", "b"], into: "a", text: ""),
                .merge(from: ["a"], into: "a", text: "t"),
                .update(topic: "k", text: "new"),
                .prune(topic: "k"),
                .add(topic: "n", text: "x", category: nil),
                .add(topic: "n", text: "x", category: nil),
                .add(topic: "n", text: "x", category: "habit"),
            ])
        }

        @Test func parseRejectsUnknownOpsAndMissingFields() {
            for raw in [
                #"{"ops": [{"op": "explode", "topic": "x"}]}"#,
                #"{"ops": [{"op": "Prune", "topic": "x"}]}"#,       // tags are lowercase-only
                #"{"ops": [{"op": "prune"}]}"#,
                #"{"ops": [{"op": "update", "topic": "x"}]}"#,
                #"{"ops": [{"topic": "x"}]}"#,
                #"{"opinions": []}"#,
                #"{"ops": []} trailing"#,
            ] {
                #expect(throws: (any Error).self, "\(raw)") { try Reflect.parseOps(raw) }
            }
        }

        @Test func parseStripsRepeatedFencesAndWhitespace() throws {
            // `trim_start_matches` / `trim_end_matches` strip *adjacent* repeats only
            #expect(try Reflect.parseOps("\n  ```json```json{\"ops\": []}``````  \n").isEmpty)
            #expect(try Reflect.parseOps("  \n```json\n{\"ops\": []}\n```  \n").isEmpty)
            #expect(throws: (any Error).self) { try Reflect.parseOps("```json\n```json\n{\"ops\": []}\n```") }
            #expect(try Reflect.parseOps("```\n{\"ops\": []}\n```").isEmpty)
        }

        @Test func mergeCanonicalizesTopicsAndKeepsFirstCategoryAndText() {
            var a = opinion("twitter_usage", 2, "2026-06-01 10:00")
            a.category = "fact"
            var b = brain([a, opinion("twitter_habit", 3, "2026-06-05 10:00")])
            let stats = Reflect.applyOps(
                &b, [.merge(from: ["Twitter Habit"], into: "  Twitter Usage ", text: "   ")], .daily(today))
            #expect(stats.merged == 1)
            #expect(b.opinions.count == 1)
            #expect(b.opinions[0].opinion == "about twitter_usage")   // blank text keeps the first source's
            #expect(b.opinions[0].category == "fact")
            #expect(b.opinions[0].timesSeen == 5)
            #expect(b.opinions[0].lastSeen == "2026-06-05 10:00")
        }

        @Test func addStampsThePolicyDayAndDefaultsTheCategory() {
            var b = brain([])
            let stats = Reflect.applyOps(
                &b, [.add(topic: " New  Topic ", text: "fresh", category: nil)], .daily(today))
            #expect(stats.added == 1)
            #expect(b.opinions == [Opinion(
                topic: "new_topic", opinion: "fresh", timesSeen: 1,
                firstSeen: "2026-07-04", lastSeen: "2026-07-04 00:00", category: "opinion")])
        }

        @Test func addSkipsBlankKeysAndBlankText() {
            var b = brain([])
            let stats = Reflect.applyOps(&b, [
                .add(topic: "   ", text: "x", category: nil),
                .add(topic: "k", text: "  \n ", category: nil),
                .update(topic: "k", text: "  "),
            ], .daily(today))
            #expect(stats.added == 0 && stats.skipped == 3)
            #expect(b.opinions.isEmpty)
        }

        @Test func pruneOfUnknownTopicIsSkipped() {
            var b = brain([opinion("weak", 1, "2026-07-03 10:00")])
            let stats = Reflect.applyOps(&b, [.prune(topic: "ghost")], .daily(today))
            #expect(stats == ApplyStats(merged: 0, updated: 0, pruned: 0, added: 0, skipped: 1))
        }

        @Test func idleDaysUseTheDatePartOfLastSeen() {
            #expect(Reflect.idleDays(opinion("a", 1, "2026-06-13 23:59"), today: today) == 21)
            #expect(Reflect.idleDays(opinion("a", 1, "garbage"), today: today) == nil)
            // exactly 21 idle days is not "> 21": a strong opinion survives
            var b = brain([opinion("a", 40, "2026-06-13 10:00")])
            #expect(Reflect.applyOps(&b, [.prune(topic: "a")], .daily(today)).pruned == 0)
            b = brain([opinion("a", 40, "2026-06-12 10:00")])
            #expect(Reflect.applyOps(&b, [.prune(topic: "a")], .daily(today)).pruned == 1)
        }

        @Test func policiesHaveTheRustLimits() {
            let d = ReflectPolicy.daily(today)
            #expect(d == ReflectPolicy(
                allowPrune: true, maxPrunes: 3, maxAdds: 5, pruneMinIdleDays: 21, pruneMaxTimesSeen: 2, today: today))
            #expect(!ReflectPolicy.backfill(today).allowPrune)
            #expect(ReflectPolicy.backfill(today).maxAdds == 5)
        }

        @Test func applyStatsDebugFormatMatchesRust() {
            #expect(ApplyStats(merged: 1, updated: 2, pruned: 3, added: 4, skipped: 5).description
                == "ApplyStats { merged: 1, updated: 2, pruned: 3, added: 4, skipped: 5 }")
        }

        @Test func reflectionPromptExactLayout() {
            let p = Reflect.buildReflectionPrompt(
                [opinion("twitter_usage", 5, "2026-07-01 10:00")], "diary text", "Diary for 2026-07-03")
            #expect(p == """
            Current opinions:
            - [twitter_usage] about twitter_usage (category: habit, seen 5x, last: 2026-07-01 10:00)

            Diary for 2026-07-03:
            diary text

            Tidy the opinions:
            - merge: topics that mean the same thing
            - update: opinion text the diary shows is outdated
            - prune: opinions that no longer matter
            - add: a clear recurring pattern in the diary that has no opinion yet

            Reply with JSON only:
            {"ops": [
              {"op": "merge", "from": ["key_a", "key_b"], "into": "key_a", "text": "combined opinion"},
              {"op": "update", "topic": "key", "text": "new text"},
              {"op": "prune", "topic": "key"},
              {"op": "add", "topic": "new_key", "text": "opinion text", "category": "habit"}
            ]}
            If nothing needs tidying: {"ops": []}
            """)
        }

        // MARK: new — model round trip

        private func seedOpinions(_ opinions: [Opinion], lastReflection: String = "", cursor: String = "") throws {
            var b = SheepBrain()
            b.opinions = opinions
            b.lastReflectionDate = lastReflection
            b.backfillCursor = cursor
            try JSONFile.write(b, to: Paths.opinions)
        }

        private func journal(_ day: String, _ text: String = "## 10:00 AM\nScrolled twitter again.") throws {
            try write(text, to: Paths.journal.appendingPathComponent("\(day).md"))
        }

        @Test func dailyReflectionAppliesOpsSnapshotsAndMarksTheDay() async throws {
            try await withBrainRoot(now: localDate(2026, 7, 4, 3, 0)) { _ in
                try seedOpinions([opinion("twitter_usage", 5, "2026-07-03 10:00"), opinion("twitter_habit", 2, "2026-07-02 10:00")])
                try journal("2026-07-03")
                let model = FakeModel(reply: """
                ```json
                {"ops": [{"op": "merge", "from": ["twitter_usage", "twitter_habit"], "into": "twitter_usage", "text": "chronically online"},
                         {"op": "add", "topic": "night_owl", "text": "codes after midnight"}]}
                ```
                """)
                await Reflect.runDailyReflection(model: model)

                #expect(model.calls.count == 1)
                #expect(model.calls[0].system.hasPrefix("You are the memory-consolidation process for a desktop sheep. You tidy the sheep's opinion list using its diary."))
                #expect(model.calls[0].prompt.contains("Diary for 2026-07-03:\n## 10:00 AM\nScrolled twitter again."))
                let b = Memory.loadBrain()
                #expect(b.lastReflectionDate == "2026-07-04")
                #expect(b.opinions.map(\.topic).sorted() == ["night_owl", "twitter_usage"])
                #expect(b.opinions.first { $0.topic == "twitter_usage" }?.timesSeen == 7)
                // the backup holds the pre-reflection brain
                let backup = try JSONFile.readStrict(SheepBrain.self, from: Paths.opinionsBackup)
                #expect(backup.opinions.count == 2)
                #expect(try Memory.getTodayJournal().contains("*Slept on it. Tidied my thoughts.*"))
                // the cursor is claimed for yesterday: backfill has nothing left
                #expect(b.backfillCursor == "2026-07-03")
                #expect(await Reflect.runBackfillStep(model: model) == false)
            }
        }

        @Test func dailyReflectionRunsOncePerCalendarDay() async throws {
            try await withBrainRoot(now: localDate(2026, 7, 4, 3, 0)) { _ in
                try seedOpinions([opinion("a", 5, "2026-07-03 10:00")])
                try journal("2026-07-03")
                let model = FakeModel()
                await Reflect.runDailyReflection(model: model)
                await Reflect.runDailyReflection(model: model)
                #expect(model.calls.count == 1)
                SimClock.nowSource = { localDate(2026, 7, 5, 3, 0).timeIntervalSince1970 * 1000 }
                try journal("2026-07-04")
                await Reflect.runDailyReflection(model: model)
                #expect(model.calls.count == 2)
                #expect(Memory.loadBrain().lastReflectionDate == "2026-07-05")
            }
        }

        @Test func dailyReflectionWithoutAJournalMarksTheDayAndSkipsTheModel() async throws {
            try await withBrainRoot(now: localDate(2026, 7, 4, 3, 0)) { _ in
                try seedOpinions([opinion("a", 5, "2026-07-03 10:00")])
                let model = FakeModel()
                await Reflect.runDailyReflection(model: model)
                #expect(model.calls.isEmpty)
                #expect(Memory.loadBrain().lastReflectionDate == "2026-07-04")
                #expect(!FileManager.default.fileExists(atPath: Paths.opinionsBackup.path))
            }
        }

        @Test func garbageModelOutputStillMarksTheDayAndChangesNothing() async throws {
            try await withBrainRoot(now: localDate(2026, 7, 4, 3, 0)) { _ in
                try seedOpinions([opinion("a", 5, "2026-07-03 10:00")])
                try journal("2026-07-03")
                let model = FakeModel(reply: "the sheep dreams of electric grass")
                await Reflect.runDailyReflection(model: model)
                await Reflect.runDailyReflection(model: model)   // no retry the same day
                #expect(model.calls.count == 1)
                let b = Memory.loadBrain()
                #expect(b.lastReflectionDate == "2026-07-04")
                #expect(b.opinions.map(\.topic) == ["a"])
                #expect(!(try Memory.getTodayJournal().contains("Slept on it")))
            }
        }

        @Test func modelErrorsAreSwallowedLikeGarbage() async throws {
            struct Boom: Error {}
            try await withBrainRoot(now: localDate(2026, 7, 4, 3, 0)) { _ in
                try seedOpinions([opinion("a", 5, "2026-07-03 10:00")])
                try journal("2026-07-03")
                let model = FakeModel { _, _ in throw Boom() }
                await Reflect.runDailyReflection(model: model)
                #expect(model.calls.count == 1)
                #expect(Memory.loadBrain().lastReflectionDate == "2026-07-04")
            }
        }

        @Test func dailyPassAdvancesTheCursorOnlyWhenTheArchiveIsDrained() async throws {
            try await withBrainRoot(now: localDate(2026, 7, 4, 3, 0)) { _ in
                try seedOpinions([opinion("a", 5, "2026-07-03 10:00")], cursor: "2026-06-30")
                for day in ["2026-07-01", "2026-07-02", "2026-07-03"] { try journal(day) }
                await Reflect.runDailyReflection(model: FakeModel())
                // 07-01 and 07-02 are still pending for backfill, so the cursor stays
                #expect(Memory.loadBrain().backfillCursor == "2026-06-30")
            }
        }

        @Test func backfillStepWalksTheArchiveOldestFirstWithoutPruning() async throws {
            try await withBrainRoot(now: localDate(2026, 7, 4, 3, 0)) { _ in
                try seedOpinions([opinion("weak", 1, "2026-06-01 10:00")])
                for day in ["2026-06-28", "2026-06-29", "2026-07-03", "2026-07-04"] { try journal(day, "entry for \(day)") }
                let model = FakeModel(reply: #"{"ops": [{"op": "prune", "topic": "weak"}]}"#)

                #expect(await Reflect.runBackfillStep(model: model) == true)
                #expect(Memory.loadBrain().backfillCursor == "2026-06-28")
                #expect(model.calls[0].prompt.contains("Diary for 2026-06-28:\nentry for 2026-06-28"))
                #expect(await Reflect.runBackfillStep(model: model) == true)
                #expect(Memory.loadBrain().backfillCursor == "2026-06-29")
                // bound is yesterday (07-03), which belongs to the daily pass
                #expect(await Reflect.runBackfillStep(model: model) == false)
                #expect(model.calls.count == 2)
                #expect(Memory.loadBrain().opinions.map(\.topic) == ["weak"])   // backfill never prunes
                #expect(Memory.loadBrain().lastReflectionDate == "")             // and doesn't mark the day
            }
        }

        @Test func backfillCursorAdvancesEvenWhenTheModelFails() async throws {
            try await withBrainRoot(now: localDate(2026, 7, 4, 3, 0)) { _ in
                try seedOpinions([opinion("a", 5, "2026-06-01 10:00")])
                try journal("2026-06-28")
                let model = FakeModel(reply: "garbage")
                #expect(await Reflect.runBackfillStep(model: model) == true)
                #expect(Memory.loadBrain().backfillCursor == "2026-06-28")
                #expect(await Reflect.runBackfillStep(model: model) == false)
                #expect(model.calls.count == 1)
            }
        }

        @Test func generateTimeoutFailsThePassAndAbandonsTheCall() async throws {
            try await withBrainRoot(now: localDate(2026, 7, 4, 3, 0)) { _ in
                try seedOpinions([opinion("a", 5, "2026-07-03 10:00")])
                let model = FakeModel { _, _ in
                    try await Task.sleep(for: .seconds(60))
                    return #"{"ops": []}"#
                }
                let started = ContinuousClock.now
                await #expect(throws: ReflectError.self) {
                    try await Reflect.reflectOnce(
                        model: model, opinions: [], journal: "x", label: "Diary", policy: .daily(naiveDate(2026, 7, 4)),
                        timeoutSecs: 0.05)
                }
                #expect(ContinuousClock.now - started < .seconds(5))
                #expect(!FileManager.default.fileExists(atPath: Paths.opinionsBackup.path))
            }
        }

        @Test func timeoutMessageNamesTheLimit() async {
            let model = FakeModel { _, _ in
                try await Task.sleep(for: .seconds(60))
                return ""
            }
            do {
                _ = try await Reflect.reflectOnce(
                    model: model, opinions: [], journal: "x", label: "Diary", policy: .daily(naiveDate(2026, 7, 4)),
                    timeoutSecs: 0.02)
                Issue.record("expected a timeout")
            } catch {
                #expect("\(error)" == "reflection generate timed out after 0s")
            }
        }

        // MARK: new — the loop

        @Test func loopWaitsThenReflectsAndBackfillsUnlessVisionIsBusy() async throws {
            try await withBrainRoot(now: localDate(2026, 7, 4, 3, 0)) { _ in
                try seedOpinions([opinion("a", 5, "2026-07-03 10:00")])
                try journal("2026-07-03")
                try journal("2026-06-20")
                let model = FakeModel()
                let busy = Flag(true)
                let loop = ReflectionLoop(
                    model: model, isVisionTickRunning: { busy.value }, initialDelaySecs: 0.01, intervalSecs: 0.02)
                #expect(!loop.isRunning)
                loop.start()
                loop.start()   // idempotent
                #expect(loop.isRunning)

                try await Task.sleep(for: .milliseconds(200))
                #expect(model.calls.isEmpty, "the vision pipeline is mid-tick: reflection must yield")

                busy.value = false
                var waited = 0
                while model.calls.count < 2 && waited < 100 {
                    try await Task.sleep(for: .milliseconds(20))
                    waited += 1
                }
                loop.stop()
                #expect(!loop.isRunning)
                // one daily pass (07-03) and one backfill step (06-20), then nothing left
                #expect(model.calls.count == 2)
                #expect(model.calls[0].prompt.contains("Diary for 2026-07-03"))
                #expect(model.calls[1].prompt.contains("Diary for 2026-06-20"))

                let seen = model.calls.count
                try await Task.sleep(for: .milliseconds(100))
                #expect(model.calls.count == seen, "stopped loops stay stopped")
            }
        }

        @Test func loopConstantsMatchRust() {
            #expect(Reflect.LOOP_INITIAL_DELAY_SECS == 90)
            #expect(Reflect.LOOP_INTERVAL_SECS == 180)
            #expect(Reflect.GENERATE_TIMEOUT_SECS == 120)
        }
    }
}

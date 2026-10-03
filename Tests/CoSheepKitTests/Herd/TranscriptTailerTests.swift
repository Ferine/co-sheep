import Darwin
import Foundation
import Testing
@testable import CoSheepKit

// The transcript format is undocumented, so these use synthetic lines shaped
// like what Claude Code writes (verified read-only against local transcripts).
@Suite("herd transcript tailer")
struct TranscriptTailerTests {
    private typealias F = IngestFixtures

    private func consume(_ lines: [String]) -> (TranscriptUpdate, TranscriptCursor) {
        var cursor = TranscriptCursor()
        let update = cursor.consume(F.file(lines))
        return (update, cursor)
    }

    // MARK: tokens

    @Test func assistantUsageSumsAllFourCounters() {
        let (update, _) = consume([F.assistant(id: "m1", input: 10, cacheCreation: 200, cacheRead: 3000, output: 40)])
        #expect(update.tokensDelta == 3250)
        #expect(update.title == nil)
        #expect(!update.interrupted)
        #expect(update.grewAtMs == nil)
    }

    @Test func linesSharingAMessageIdCountOnce() {
        let line = F.assistant(id: "m1", input: 5, cacheRead: 100, output: 7)
        let (update, cursor) = consume([line, line, line, F.assistant(id: "m2", output: 50)])
        #expect(update.tokensDelta == 112 + 50)
        #expect(cursor.seenMessageIds == ["m1", "m2"])
    }

    @Test func dedupeSurvivesAcrossConsumeCalls() {
        var cursor = TranscriptCursor()
        let line = F.assistant(id: "m1", output: 9)
        #expect(cursor.consume(F.file([line])).tokensDelta == 9)
        #expect(cursor.consume(F.file([line, F.assistant(id: "m2", output: 1)])).tokensDelta == 1)
        #expect(cursor.consume(F.file([line])).tokensDelta == 0)
    }

    @Test func linesWithoutAnIdCannotBeDeduped() {
        let line = F.assistant(id: nil, output: 4)
        let (update, cursor) = consume([line, line])
        #expect(update.tokensDelta == 8)
        #expect(cursor.seenMessageIds.isEmpty)
    }

    @Test func aLineWithoutUsageDoesNotUseUpItsMessageId() {
        let (update, _) = consume([F.assistantWithoutUsage(id: "m1"), F.assistant(id: "m1", output: 12)])
        #expect(update.tokensDelta == 12)
    }

    @Test func nonNumericOrNegativeCountersAreZero() {
        let odd = #"{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":"7","output_tokens":true,"cache_read_input_tokens":-4,"cache_creation_input_tokens":2.0}}}"#
        let (update, _) = consume([odd])
        #expect(update.tokensDelta == 2)
    }

    @Test func otherLineTypesAreIgnored() {
        let noise = [
            F.userString("hello"), F.toolResult("output"),
            #"{"type":"attachment","usage":"not tokens"}"#,
            #"{"type":"system","message":{"usage":{"output_tokens":99}}}"#,
            #"{"type":"mode","mode":"plan"}"#,
        ]
        let (update, _) = consume(noise)
        #expect(update.isEmpty)
    }

    // MARK: malformed input

    @Test func malformedLinesAreSkipped() {
        let lines = [
            "{not json at all",
            #"{"type":"assistant","message":{"id":"m1","usage":{"output_tokens":5}"#, // truncated
            "[1,2,3]",
            "null",
            "\"usage\"",
            F.assistant(id: "m2", output: 8),
            "",
            "   ",
        ]
        let (update, _) = consume(lines)
        #expect(update.tokensDelta == 8)
    }

    @Test func binaryGarbageIsHarmless() {
        var cursor = TranscriptCursor()
        var data = Data([0xFF, 0xFE, 0x00, 0x0A, 0x80, 0x0A])
        data.append(F.file([F.assistant(id: "m1", output: 3)]))
        data.append(Data([0x7B, 0x22, 0xC3, 0x28, 0x0A]))
        let update = cursor.consume(data)
        #expect(update.tokensDelta == 3)
    }

    @Test func escapedKeysAreDecodedByTheJSONParser() {
        let (update, _) = consume([#"{"type":"assistant","message":{"id":"m1","usage":{"output_tokens":5,"input_tokens":1}}}"#])
        #expect(update.tokensDelta == 6)
    }

    @Test func hugeIrrelevantLinesAreSkippedCheaply() {
        let (update, cursor) = consume([F.filler(bytes: 3_000_000), F.assistant(id: "m1", output: 2), F.filler(bytes: 1_000_000)])
        #expect(update.tokensDelta == 2)
        #expect(cursor.carry.isEmpty)
    }

    // MARK: partial lines

    @Test func aLineSplitAcrossConsumeCallsIsParsedOnce() {
        let whole = F.file([F.title("Split me"), F.assistant(id: "m1", input: 1, output: 4)])
        for cut in 1..<whole.count {
            var cursor = TranscriptCursor()
            let first = cursor.consume(whole.prefix(cut))
            let second = cursor.consume(whole.suffix(from: cut))
            #expect(first.tokensDelta + second.tokensDelta == 5, "cut at \(cut)")
            #expect(first.title ?? second.title == "Split me", "cut at \(cut)")
            #expect(cursor.offset == whole.count)
            #expect(cursor.carry.isEmpty)
        }
    }

    @Test func tinyChunksGiveTheSameTotalsAsOneBigRead() {
        let lines = [
            F.title("Ünïcode ✓ title"), F.assistant(id: "a", input: 3, output: 4), F.userString("hi"),
            F.assistant(id: "a", input: 3, output: 4), F.assistant(id: "b", cacheRead: 100),
        ]
        let whole = F.file(lines)
        var one = TranscriptCursor()
        let expected = one.consume(whole)
        #expect(expected.tokensDelta == 107)

        var cursor = TranscriptCursor()
        var total = 0
        var title: String?
        var index = 0
        while index < whole.count {
            let end = min(whole.count, index + 7)
            let update = cursor.consume(whole.subdata(in: index..<end))
            total += update.tokensDelta
            title = update.title ?? title
            index = end
        }
        #expect(total == expected.tokensDelta)
        #expect(title == "Ünïcode ✓ title")
        #expect(cursor == one)
    }

    @Test func theUnfinishedLastLineWaitsInTheCarry() {
        var cursor = TranscriptCursor()
        let line = F.assistant(id: "m1", output: 6)
        let half = Data(line.utf8.prefix(line.utf8.count / 2))
        let update = cursor.consume(half)
        #expect(update.isEmpty)
        #expect(cursor.carry == half)
        #expect(cursor.offset == half.count)
    }

    @Test func aCompleteFinalLineWithoutANewlineCountsAtOnce() {
        var cursor = TranscriptCursor()
        let line = F.assistant(id: "m1", output: 6)
        #expect(cursor.consume(Data(line.utf8)).tokensDelta == 6)
        #expect(cursor.carry.isEmpty)
        // its newline arrives later and changes nothing
        #expect(cursor.consume(Data("\n".utf8)).isEmpty)
        #expect(cursor.consume(F.file([line])).tokensDelta == 0)
    }

    @Test func aFinalLineThatLooksCompleteButIsNotStaysPending() {
        var cursor = TranscriptCursor()
        let prefix = #"{"type":"assistant","message":{"id":"m1","usage":{"output_tokens":5}}"# // missing one brace
        #expect(cursor.consume(Data(prefix.utf8)).isEmpty)
        #expect(!cursor.carry.isEmpty)
        #expect(cursor.consume(Data("}\n".utf8)).tokensDelta == 5)
        #expect(cursor.carry.isEmpty)
    }

    @Test func aRunawayLineIsDroppedInsteadOfBufferedForever() {
        var cursor = TranscriptCursor()
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 33 * 1024 * 1024)
        _ = cursor.consume(chunk)
        #expect(cursor.carry.count == chunk.count)
        _ = cursor.consume(chunk)
        #expect(cursor.carry.isEmpty)
        #expect(cursor.offset == chunk.count * 2)
    }

    @Test func emptyDataChangesNothing() {
        var cursor = TranscriptCursor()
        #expect(cursor.consume(Data()).isEmpty)
        #expect(cursor == TranscriptCursor())
    }

    // MARK: title

    @Test func theLastTitleWins() {
        let (update, _) = consume([F.title("First"), F.assistant(id: "m", output: 1), F.title("  Second \n")])
        #expect(update.title == "Second")
    }

    @Test func emptyOrMalformedTitlesAreIgnored() {
        let (update, _) = consume([#"{"type":"ai-title","aiTitle":""}"#, #"{"type":"ai-title","aiTitle":42}"#, #"{"type":"ai-title"}"#])
        #expect(update.title == nil)
    }

    @Test func aTitleLineMentionedInsideAnotherLineIsNotATitle() {
        let (update, _) = consume([F.userString(#"what is "type":"ai-title"?"#)])
        #expect(update.title == nil)
    }

    @Test func longTitlesAreCapped() {
        let (update, _) = consume([F.title(String(repeating: "t", count: 500))])
        #expect(update.title?.unicodeScalars.count == 200)
    }

    // MARK: interrupts

    @Test func anInterruptedTurnIsSpotted() {
        for marker in ["[Request interrupted by user]", "[Request interrupted by user for tool use]"] {
            let (blocks, _) = consume([F.userBlocks(marker)])
            #expect(blocks.interrupted, "\(marker) as blocks")
            let (string, _) = consume([F.userString(marker)])
            #expect(string.interrupted, "\(marker) as a string")
        }
    }

    @Test func aPromptThatQuotesTheMarkerIsNotAnInterrupt() {
        let (update, _) = consume([F.userString("why do I see [Request interrupted by user] in my logs?")])
        #expect(!update.interrupted)
    }

    @Test func aToolResultThatContainsTheMarkerIsNotAnInterrupt() {
        let (update, _) = consume([F.toolResult("[Request interrupted by user]")])
        #expect(!update.interrupted)
    }

    @Test func anAssistantLineAfterTheMarkerEndsTheInterrupt() {
        let (update, _) = consume([F.userBlocks("[Request interrupted by user]"), F.assistant(id: "m1", output: 2)])
        #expect(!update.interrupted)
        #expect(update.tokensDelta == 2)
    }

    @Test func aNewPromptAfterTheMarkerEndsTheInterrupt() {
        let (typed, _) = consume([F.userBlocks("[Request interrupted by user]"), F.userString("carry on")])
        #expect(!typed.interrupted)
        let (blocks, _) = consume([F.userBlocks("[Request interrupted by user]"), F.userBlocks("carry on")])
        #expect(!blocks.interrupted)
    }

    @Test func anOldInterruptInHistoryDoesNotCount() {
        let history = [
            F.userBlocks("[Request interrupted by user]"), F.userString("next"),
            F.assistant(id: "m1", output: 1), F.assistant(id: "m2", output: 1),
        ]
        let (update, _) = consume(history)
        #expect(!update.interrupted)
        let (live, _) = consume(history + [F.userBlocks("[Request interrupted by user for tool use]")])
        #expect(live.interrupted)
    }

    @Test func claudeCodesOwnPlaceholderReplyDoesNotEndTheInterrupt() {
        let placeholder = F.assistant(id: "m1", model: "<synthetic>")
        let (update, _) = consume([F.userBlocks("[Request interrupted by user]"), placeholder])
        #expect(update.interrupted)
    }

    @Test func bookkeepingLinesAfterTheMarkerDoNotEndTheInterrupt() {
        let (update, _) = consume([
            F.userBlocks("[Request interrupted by user]"), F.toolResult("leftover"),
            #"{"type":"file-history-snapshot"}"#, #"{"type":"attachment"}"#, #"{"type":"last-prompt"}"#,
        ])
        #expect(update.interrupted)
    }

    @Test func anInterruptSplitAcrossReadsIsSpotted() {
        let whole = F.file([F.assistant(id: "m1", output: 1), F.userBlocks("[Request interrupted by user]")])
        var cursor = TranscriptCursor()
        let cut = whole.count - 12
        let first = cursor.consume(whole.prefix(cut))
        #expect(!first.interrupted)
        let second = cursor.consume(whole.suffix(from: cut))
        #expect(second.interrupted)
    }

    // MARK: reading files

    private func withTempDir<T>(_ body: (URL) throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("herd-tail-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    private func append(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    @Test func aMissingFileLeavesTheCursorAlone() {
        withTempDir { dir in
            let result = TranscriptTailer.readNew(path: dir.appendingPathComponent("nope.jsonl").path, cursor: TranscriptCursor(), nowMs: 5)
            #expect(result.update == nil)
            #expect(result.cursor == TranscriptCursor())
        }
    }

    @Test func theFirstReadTakesTheWholeExistingFile() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("big.jsonl")
            var lines: [String] = [F.title("Old session")]
            for i in 0..<2000 { lines.append(F.assistant(id: "m\(i)", input: 1, output: 2)) }
            lines.append(F.filler(bytes: 200_000))
            try F.file(lines).write(to: url)

            let result = TranscriptTailer.readNew(path: url.path, cursor: TranscriptCursor(), nowMs: 99)
            #expect(result.update?.tokensDelta == 6000)
            #expect(result.update?.title == "Old session")
            #expect(result.update?.grewAtMs != nil)
            #expect(result.cursor.offset == (try Data(contentsOf: url)).count)
        }
    }

    @Test func laterReadsOnlySeeWhatWasAppended() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("s.jsonl")
            try append(F.file([F.assistant(id: "m1", output: 10)]), to: url)
            var read = TranscriptTailer.readNew(path: url.path, cursor: TranscriptCursor(), nowMs: 1)
            #expect(read.update?.tokensDelta == 10)

            let idle = TranscriptTailer.readNew(path: url.path, cursor: read.cursor, nowMs: 2)
            #expect(idle.update == nil)
            #expect(idle.cursor == read.cursor)

            try append(F.file([F.assistant(id: "m2", output: 5), F.title("Now titled")]), to: url)
            read = TranscriptTailer.readNew(path: url.path, cursor: read.cursor, nowMs: 3)
            #expect(read.update?.tokensDelta == 5)
            #expect(read.update?.title == "Now titled")
        }
    }

    @Test func aLineBeingWrittenIsCompletedByTheNextRead() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("s.jsonl")
            let line = F.assistant(id: "m1", output: 21)
            let bytes = F.file([line])
            try append(bytes.prefix(bytes.count / 2), to: url)
            var read = TranscriptTailer.readNew(path: url.path, cursor: TranscriptCursor(), nowMs: 1)
            #expect(read.update?.tokensDelta == 0)
            try append(bytes.suffix(from: bytes.count / 2), to: url)
            read = TranscriptTailer.readNew(path: url.path, cursor: read.cursor, nowMs: 2)
            #expect(read.update?.tokensDelta == 21)
        }
    }

    @Test func aShrunkFileIsReadFromTheStartWithoutDoubleCounting() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("s.jsonl")
            try F.file([F.assistant(id: "m1", output: 10), F.assistant(id: "m2", output: 20), F.filler(bytes: 500)]).write(to: url)
            var read = TranscriptTailer.readNew(path: url.path, cursor: TranscriptCursor(), nowMs: 1)
            #expect(read.update?.tokensDelta == 30)
            let oldOffset = read.cursor.offset

            // rewritten shorter: one known message, one new one
            try F.file([F.assistant(id: "m2", output: 20), F.assistant(id: "m3", output: 7)]).write(to: url)
            read = TranscriptTailer.readNew(path: url.path, cursor: read.cursor, nowMs: 2)
            #expect(read.update?.tokensDelta == 7)
            #expect(read.cursor.offset < oldOffset)
            #expect(read.cursor.offset == (try Data(contentsOf: url)).count)
        }
    }

    @Test func aTruncatedToEmptyFileRewindsQuietly() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("s.jsonl")
            try F.file([F.assistant(id: "m1", output: 10)]).write(to: url)
            var read = TranscriptTailer.readNew(path: url.path, cursor: TranscriptCursor(), nowMs: 1)
            try Data().write(to: url)
            read = TranscriptTailer.readNew(path: url.path, cursor: read.cursor, nowMs: 2)
            #expect(read.update == nil)
            #expect(read.cursor.offset == 0)
            #expect(read.cursor.carry.isEmpty)
        }
    }

    @Test func aCappedReadContinuesOnTheNextPoll() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("s.jsonl")
            var lines: [String] = []
            for i in 0..<50 { lines.append(F.assistant(id: "m\(i)", output: i + 1)) }
            try F.file(lines).write(to: url)

            var cursor = TranscriptCursor()
            var total = 0
            var polls = 0
            while polls < 1000 {
                let read = TranscriptTailer.readNew(path: url.path, cursor: cursor, nowMs: 1, maxBytes: 333)
                cursor = read.cursor
                guard let update = read.update else { break }
                total += update.tokensDelta
                polls += 1
            }
            #expect(total == (1...50).reduce(0, +))
            #expect(polls > 5)
        }
    }

    @Test func onlyAbsoluteJsonlRegularFilesAreRead() throws {
        try withTempDir { dir in
            let payload = F.file([F.assistant(id: "m1", output: 10)])
            let txt = dir.appendingPathComponent("s.txt")
            try payload.write(to: txt)
            #expect(TranscriptTailer.readNew(path: txt.path, cursor: TranscriptCursor(), nowMs: 1).update == nil)

            let real = dir.appendingPathComponent("real.jsonl")
            try payload.write(to: real)
            #expect(TranscriptTailer.readNew(path: "real.jsonl", cursor: TranscriptCursor(), nowMs: 1).update == nil)

            let folder = dir.appendingPathComponent("folder.jsonl", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #expect(TranscriptTailer.readNew(path: folder.path, cursor: TranscriptCursor(), nowMs: 1).update == nil)

            let fifo = dir.appendingPathComponent("pipe.jsonl")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            #expect(TranscriptTailer.readNew(path: fifo.path, cursor: TranscriptCursor(), nowMs: 1).update == nil)

            #expect(TranscriptTailer.readNew(path: real.path, cursor: TranscriptCursor(), nowMs: 1).update?.tokensDelta == 10)
        }
    }

    @Test func tildeIsExpanded() {
        #expect(TranscriptTailer.expand("~/.claude/projects/x/s.jsonl") == NSHomeDirectory() + "/.claude/projects/x/s.jsonl")
        #expect(TranscriptTailer.expand("/abs/path.jsonl") == "/abs/path.jsonl")
        // a missing file under the expanded home is simply absent
        let missing = TranscriptTailer.readNew(path: "~/definitely-not-a-transcript-\(UUID().uuidString).jsonl", cursor: TranscriptCursor(), nowMs: 1)
        #expect(missing.update == nil)
    }

    @Test func theAsyncReaderMatchesTheBlockingOne() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("herd-async-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try F.file([F.assistant(id: "m1", output: 3)]).write(to: url)
        let result = await TranscriptTailer.read(path: url.path, cursor: TranscriptCursor(), nowMs: 7)
        #expect(result == TranscriptTailer.readNew(path: url.path, cursor: TranscriptCursor(), nowMs: 7))
        #expect(result.update?.tokensDelta == 3)
    }

    @Test func growthIsStampedWithTheFileModificationTimeNotNow() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("s.jsonl")
            try F.file([F.assistant(id: "m1", output: 3)]).write(to: url)
            let old = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            let now = Date().timeIntervalSince1970 * 1000
            let read = TranscriptTailer.readNew(path: url.path, cursor: TranscriptCursor(), nowMs: now)
            // an old transcript replayed at startup must not look like fresh activity
            #expect(read.update?.grewAtMs == 1_700_000_000_000)
            // and a clock behind the file clamps rather than reporting the future
            let behind = TranscriptTailer.readNew(path: url.path, cursor: TranscriptCursor(), nowMs: 5)
            #expect(behind.update?.grewAtMs == 5)
        }
    }
}

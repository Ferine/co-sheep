import Foundation
import Testing
@testable import CoSheepKit

// The pure half of vision.rs: response parsing, the classification parse, the
// prompts and the interval jitter. No globals are touched, so this suite needs
// no temp root.
@Suite("vision parsing")
struct VisionParsingTests {
    private func parse(_ raw: String) -> ParsedResponse {
        VisionPipeline.parseCommentaryResponse(raw)
    }

    // MARK: ported from vision.rs (9)

    @Test func parsesFullValidResponse() {
        let p = parse(
            #"{"text": "Baaa.", "animation": "bounce", "opinion_topic": "routers", "opinion": "too many", "opinion_category": "habit", "count": "router_talk"}"#)
        #expect(p.event.text == "Baaa.")
        #expect(p.event.animation == .bounce)
        #expect(p.count == "router_talk")
        #expect(p.opinionTopic == "routers")
        #expect(p.opinion == "too many")
        #expect(p.opinionCategory == "habit")
    }

    @Test func coercesNumericCountInsteadOfFailing() {
        // The on-device model bends types — a numeric count must not dump
        // raw JSON into the speech bubble
        let p = parse(#"{"text": "Baaa.", "animation": null, "count": 3}"#)
        #expect(p.event.text == "Baaa.")
        #expect(p.count == "3")
    }

    @Test func ignoresWrongTypedOptionalFields() {
        let p = parse(#"{"text": "Baaa.", "animation": true, "opinion": ["a", "b"]}"#)
        #expect(p.event.text == "Baaa.")
        #expect(p.event.animation == nil)
        #expect(p.opinion == nil)
    }

    @Test func filtersInvalidAnimationNames() {
        let p = parse(#"{"text": "Baaa.", "animation": "moonwalk"}"#)
        #expect(p.event.animation == nil)
    }

    @Test func salvagesTextFromTruncatedJson() {
        // Output cut off mid-generation after the text field closed
        let p = parse(#"{"text": "Du har ein fancy router.", "animation": "bounce", "opinion_topic": "tekno"#)
        #expect(p.event.text == "Du har ein fancy router.")
        #expect(p.event.animation == nil)
    }

    @Test func salvagesPartialTextWhenStringIsCut() {
        let p = parse(#"{"text": "Du har ein skikkeleg fancy rout"#)
        #expect(p.event.text == "Du har ein skikkeleg fancy rout…")
    }

    @Test func handlesEscapesInSalvagedText() {
        let p = parse(#"{"text": "Han sa \"baaa\" til meg.", "animation": bro"#)
        #expect(p.event.text == "Han sa \"baaa\" til meg.")
    }

    @Test func fallsBackToRawForGarbage() {
        let p = parse("Baaa, eg er berre ein sau.")
        #expect(p.event.text == "Baaa, eg er berre ein sau.")
        #expect(p.event.animation == nil)
    }

    @Test func stripsMarkdownFences() {
        let p = parse("```json\n{\"text\": \"Baaa.\", \"animation\": null}\n```")
        #expect(p.event.text == "Baaa.")
    }

    // MARK: parsing edges (new)

    @Test func allSixAnimationsPass() {
        for name in ["bounce", "spin", "backflip", "headshake", "zoom", "vibrate"] {
            let p = parse(#"{"text": "x", "animation": "\#(name)"}"#)
            #expect(p.event.animation?.rawValue == name)
        }
    }

    @Test func emptyStringOptionalsAreAbsent() {
        let p = parse(#"{"text": "Baaa.", "opinion_topic": "", "opinion": "", "count": ""}"#)
        #expect(p.opinionTopic == nil)
        #expect(p.opinion == nil)
        #expect(p.count == nil)
    }

    @Test func numericOptionalsAreStringified() {
        let p = parse(#"{"text": "Baaa.", "count": 3.5, "opinion_category": 7}"#)
        #expect(p.count == "3.5")
        #expect(p.opinionCategory == "7")
    }

    @Test func numericAnimationIsNotAnAnimation() {
        #expect(parse(#"{"text": "Baaa.", "animation": 3}"#).event.animation == nil)
    }

    @Test func nonStringTextFallsThroughToSalvageThenRaw() {
        // `text` is present but a number: not usable as the sheep's line, and
        // there is no quoted text to salvage, so the raw response is shown.
        let raw = #"{"text": 42, "animation": "bounce"}"#
        let p = parse(raw)
        #expect(p.event.text == raw)
        #expect(p.event.animation == nil)
    }

    @Test func rawFallbackIsTrimmedButKeepsFences() {
        // Only the salvage/JSON paths look at the stripped text; the raw
        // fallback shows the model's words (trimmed) exactly.
        let p = parse("  ```\nbaaa\n```  \n")
        #expect(p.event.text == "```\nbaaa\n```")
    }

    @Test func repeatedFencesAreAllStripped() {
        // Rust's `trim_start_matches` / `trim_end_matches` strip every repetition.
        let p = parse("```json```json{\"text\": \"Baaa.\"}``````")
        #expect(p.event.text == "Baaa.")
    }

    @Test func topLevelNonObjectJsonFallsBackToRaw() {
        #expect(parse(#""just a string""#).event.text == #""just a string""#)
        #expect(parse("[1, 2]").event.text == "[1, 2]")
    }

    @Test func salvageDecodesUnicodeEscapesAndSurrogatePairs() {
        #expect(VisionPipeline.extractTextField(#"{"text": "Hei p\u00e5 deg \ud83d\udc11 der"#) == "Hei på deg 🐑 der…")
        #expect(VisionPipeline.extractTextField(#"{"text": "line one\r\nline two"}"#) == "line one\r\nline two")
        // Truncated mid-escape: the stub is dropped, not turned into NUL
        #expect(VisionPipeline.extractTextField(#"{"text": "Hello there \u00"#) == "Hello there …")
    }

    @Test func modelOutputMentioningTheScreenIsNotACaptureError() {
        let parse = VisionError("Failed to parse classification: bad — raw: The screen shows a code editor")
        #expect(!VisionPipeline.isCaptureError(parse, parse.description))
        let capture = PlatformError("No monitor found for screen capture")
        #expect(VisionPipeline.isCaptureError(capture, VisionPipeline.describe(capture)))
    }

    @Test func salvageThresholdIsMoreThanTenCharacters() {
        // Unterminated text needs more than 10 characters to be worth showing.
        #expect(VisionPipeline.extractTextField(#"{"text": "0123456789"#) == nil)
        #expect(VisionPipeline.extractTextField(#"{"text": "01234567890"#) == "01234567890…")
        // Counted in characters (scalars), not bytes: ten 2-byte letters is still ten.
        #expect(VisionPipeline.extractTextField(#"{"text": "æøåæøåæøåæ"#) == nil)
        #expect(VisionPipeline.extractTextField(#"{"text": "æøåæøåæøåæø"#) == "æøåæøåæøåæø…")
    }

    @Test func salvageOfEmptyTextIsNil() {
        #expect(VisionPipeline.extractTextField(#"{"text": "", "animation": null}"#) == nil)
    }

    @Test func salvageNeedsAColonAndAnOpeningQuote() {
        #expect(VisionPipeline.extractTextField(#"{"text" "no colon"#) == nil)
        #expect(VisionPipeline.extractTextField(#"{"text": no quote"#) == nil)
        #expect(VisionPipeline.extractTextField("no key at all") == nil)
    }

    @Test func salvageDecodesNewlineAndTabEscapesAndKeepsOthers() {
        let s = VisionPipeline.extractTextField(#"{"text": "a\nb\tc\/d\\e"}"#)
        #expect(s == "a\nb\tc/d\\e")
    }

    @Test func salvageStopsOnATrailingBackslash() {
        // A dangling backslash ends the scan; what came before still counts.
        #expect(VisionPipeline.extractTextField(#"{"text": "0123456789abc\"#) == "0123456789abc…")
    }

    // MARK: classification

    @Test func parsesClassification() throws {
        let c = try VisionPipeline.parseClassification(
            #"{"interesting": true, "category": "code", "summary": "Xcode with errors"}"#)
        #expect(c == ScreenClassification(interesting: true, category: "code", summary: "Xcode with errors"))
    }

    @Test func classificationToleratesFencesAndExtraFields() throws {
        let c = try VisionPipeline.parseClassification(
            "```json\n{\"interesting\": false, \"category\": \"idle\", \"summary\": \"Desktop\", \"extra\": 1}\n```")
        #expect(c.interesting == false)
        #expect(c.summary == "Desktop")
    }

    @Test func classificationRequiresAllThreeFields() {
        for raw in [
            #"{"interesting": true, "summary": "no category"}"#,
            #"{"category": "x", "summary": "no interesting"}"#,
            #"{"interesting": true, "category": "x"}"#,
        ] {
            #expect(throws: VisionError.self) { try VisionPipeline.parseClassification(raw) }
        }
    }

    @Test func classificationRejectsWrongTypesAndTrailingText() {
        #expect(throws: VisionError.self) {
            try VisionPipeline.parseClassification(#"{"interesting": "yes", "category": "x", "summary": "y"}"#)
        }
        #expect(throws: VisionError.self) {
            try VisionPipeline.parseClassification(#"{"interesting": true, "category": "x", "summary": "y"} trailing"#)
        }
    }

    @Test func classificationErrorNamesTheFailureAndEchoesTheRawText() {
        do {
            _ = try VisionPipeline.parseClassification("Looks like a nice desktop")
            Issue.record("expected a throw")
        } catch {
            let text = VisionPipeline.describe(error)
            #expect(text.hasPrefix("Failed to parse classification: "))
            #expect(text.hasSuffix(" — raw: Looks like a nice desktop"))
        }
    }

    // MARK: prompts (verbatim)

    @Test func promptsAreVerbatim() {
        #expect(VisionPipeline.CLASSIFY_SYSTEM
            == "You classify screen content for a desktop pet app. Reply only with the requested JSON.")
        #expect(VisionPipeline.CLASSIFY_PROMPT.hasPrefix("Below is text extracted (OCR) from a screenshot of the user's screen."))
        #expect(VisionPipeline.CLASSIFY_PROMPT.contains(
            "\n\nReply ONLY with JSON, no markdown: {\"interesting\": true/false, \"category\": \"string\", \"summary\": \"brief description\"}\n\n"))
        #expect(VisionPipeline.CLASSIFY_PROMPT.hasSuffix(
            "Mark as NOT interesting if: normal coding, idle desktop, standard productivity work."))
        #expect(VisionPipeline.COMMENTARY_PROMPT
            == "Give a short snarky comment (1-2 sentences max) about what you see on this screen. Stay in character. Reference past observations if relevant. Reply with JSON: {\"text\": \"your comment\", \"animation\": \"name_or_null\"}")
        #expect(VisionPipeline.OCR_BUDGET == 4000)
        #expect(VisionPipeline.CHAT_MSG_BUDGET == 2000)
    }

    // MARK: history JSON (serde_json::json!(...).to_string())

    @Test func sheepTurnsAreCompactJsonWithSortedKeys() {
        #expect(VisionPipeline.sheepTurnJSON("Baaa.") == #"{"animation":null,"text":"Baaa."}"#)
    }

    @Test func sheepTurnJsonEscapesLikeSerde() {
        // Quotes, backslashes and control characters are escaped; slashes and
        // non-ASCII are not.
        let json = VisionPipeline.sheepTurnJSON("Han sa \"baaa\" \\ på/ny\nlinje\t☃")
        #expect(json == #"{"animation":null,"text":"Han sa \"baaa\" \\ på/ny\nlinje\t☃"}"#)
    }

    // MARK: pacing

    @Test func intervalJitterStaysWithinTwentyPercent() {
        // base 150 -> jitter 30 -> uniformly 120...180
        #expect(VisionPipeline.nextDelaySecs(base: 150, nanos: 0) == 120)
        #expect(VisionPipeline.nextDelaySecs(base: 150, nanos: 30) == 150)
        #expect(VisionPipeline.nextDelaySecs(base: 150, nanos: 60) == 180)
        #expect(VisionPipeline.nextDelaySecs(base: 150, nanos: 61) == 120) // modulo 61 wraps
        for nanos in stride(from: UInt64(0), to: 999_999_999, by: 12_345_679) {
            let d = VisionPipeline.nextDelaySecs(base: 150, nanos: nanos)
            #expect((120...180).contains(d))
        }
    }

    @Test func intervalJitterTruncatesAndHandlesTinyBases() {
        #expect(VisionPipeline.nextDelaySecs(base: 4, nanos: 7) == 4) // jitter 0: no randomness
        #expect(VisionPipeline.nextDelaySecs(base: 0, nanos: 12345) == 0)
        // 0.2 * 10 = 2 -> 8...12
        #expect(VisionPipeline.nextDelaySecs(base: 10, nanos: 0) == 8)
        #expect(VisionPipeline.nextDelaySecs(base: 10, nanos: 4) == 12)
    }

    @Test func subsecNanosIsBelowOneSecond() {
        #expect(VisionPipeline.subsecNanos() < 1_000_000_000)
    }
}

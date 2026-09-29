import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

/// New tests: the DOM/CSS speech bubble became a Canvas drawing, so these
/// pin the CSS box model, the clamping math and the typewriter/timing rules.
@Suite("speech bubble layout")
struct SpeechBubbleLayoutTests {
    private let chrome = 36.0 // 2 * (16 padding + 2 border)
    private let charW = SpeechBubble.measure("m")

    @Test func emptyTextIsAMinWidthPill() {
        let l = SpeechBubble.layout(text: "", left: nil, viewportWidth: 1000)
        #expect(l.width == 120)
        #expect(l.height == 28) // 2*12 padding + 2*2 border, no line boxes
        #expect(l.lines.isEmpty)
    }

    @Test func shortTextIsFlooredAtMinWidth() {
        let l = SpeechBubble.layout(text: "Hi", left: nil, viewportWidth: 1000)
        #expect(l.width == 120)
        #expect(l.lines == ["Hi"])
        #expect(abs(l.height - (28 + 19.6)) < 1e-9)
    }

    @Test func mediumTextShrinksToFitItsContent() {
        let text = "Hello sheep world"
        let l = SpeechBubble.layout(text: text, left: nil, viewportWidth: 1000)
        let expected = SpeechBubble.measure(text) + chrome
        #expect(expected > 120 && expected < 300)
        #expect(abs(l.width - expected) < 1e-9)
        #expect(l.lines == [text])
    }

    @Test func longTextIsCappedAtMaxWidthAndWraps() {
        let text = Array(repeating: "word", count: 40).joined(separator: " ")
        let l = SpeechBubble.layout(text: text, left: nil, viewportWidth: 1000)
        #expect(l.width == 300)
        #expect(l.lines.count > 1)
        #expect(abs(l.height - (28 + 19.6 * Double(l.lines.count))) < 1e-9)
        // Wrapping only breaks at spaces and loses nothing
        #expect(l.lines.joined(separator: " ") == text)
        // Every line fits the 264pt content box
        for line in l.lines {
            #expect(SpeechBubble.measure(line) <= 264 + 1e-6)
        }
        // First-fit: the next word would not have fitted on the previous line
        for (i, line) in l.lines.dropLast().enumerated() {
            let nextWord = l.lines[i + 1].split(separator: " ")[0]
            #expect(SpeechBubble.measure(line + " " + nextWord) > 264)
        }
    }

    @Test func wrapExactlyAtContentWidth() {
        // With a monospace face, N chars fit iff N * charW <= 264.
        let perLine = Int((264 / charW).rounded(.down))
        let word = String(repeating: "a", count: perLine - 3)
        let l = SpeechBubble.layout(text: "\(word) bb ccc", left: nil, viewportWidth: 1000)
        // "word bb" fits exactly perLine chars; "ccc" wraps
        #expect(l.lines == ["\(word) bb", "ccc"])
    }

    @Test func aWordWiderThanTheBoxOverflowsLikeCSS() {
        let word = String(repeating: "x", count: 60) // far wider than 264pt
        let l = SpeechBubble.layout(text: "\(word) end", left: nil, viewportWidth: 1000)
        #expect(l.width == 300)
        #expect(l.lines == [word, "end"]) // not broken mid-word
    }

    @Test func whitespaceCollapsesLikeWhiteSpaceNormal() {
        #expect(SpeechBubble.words("  a \n\t b\r\n  c  ") == ["a", "b", "c"])
        #expect(SpeechBubble.words("   \n ") == [])
        let l = SpeechBubble.layout(text: "  a \n\t b  ", left: nil, viewportWidth: 1000)
        #expect(l.lines == ["a b"])
        // A trailing space (mid-typewriter) doesn't change the width
        let typed = SpeechBubble.layout(text: "Hello ", left: nil, viewportWidth: 1000)
        let done = SpeechBubble.layout(text: "Hello", left: nil, viewportWidth: 1000)
        #expect(typed == done)
    }

    @Test func roomToTheRightOfLeftShrinksTheBubble() {
        // position: fixed; left: L; width: auto → shrink-to-fit against W - L
        let text = Array(repeating: "word", count: 40).joined(separator: " ")
        let free = SpeechBubble.layout(text: text, left: 100, viewportWidth: 1000)
        #expect(free.width == 300)
        let tight = SpeechBubble.layout(text: text, left: 800, viewportWidth: 1000)
        #expect(tight.width == 200) // 1000 - 800 available, border-box
        let tighter = SpeechBubble.layout(text: text, left: 950, viewportWidth: 1000)
        #expect(tighter.width == 120) // min-width wins
        #expect(tight.lines.count > free.lines.count)
        // The longest word is min-content: the box never wraps inside a word
        let wide = SpeechBubble.layout(text: String(repeating: "y", count: 20), left: 950, viewportWidth: 1000)
        #expect(wide.lines.count == 1)
        #expect(abs(wide.width - (SpeechBubble.measure(String(repeating: "y", count: 20)) + chrome)) < 1e-9)
    }

    @Test func emojiTextMeasuresAndWraps() {
        let l = SpeechBubble.layout(text: "Baaa 🐑 swift now? 🐑🐑🐑", left: nil, viewportWidth: 1000)
        #expect(l.width >= 120 && l.width <= 300)
        #expect(!l.lines.isEmpty)
    }
}

@Suite("speech bubble behaviour", .serialized)
struct SpeechBubbleBehaviourTests {
    private func withViewport(_ w: Double, _ h: Double, _ body: () throws -> Void) rethrows {
        let saved = SpeechBubble.viewport
        SpeechBubble.viewport = ScreenSize(width: w, height: h)
        defer { SpeechBubble.viewport = saved }
        try body()
    }

    /// Finish the typewriter without waiting on real timers.
    private func finishTyping(_ b: SpeechBubble, _ text: String) {
        for _ in 0..<(text.utf16.count + 1) { b.typewriterTick() }
    }

    @Test func showHideAndCurrentText() {
        let b = SpeechBubble(listenToCommentary: false)
        #expect(!b.visible)
        #expect(b.currentText == "")
        b.show("Baaa", duration: 1000)
        #expect(b.visible)
        #expect(b.currentText == "Baaa") // the full text, not what was typed so far
        b.hide()
        #expect(!b.visible)
        #expect(b.currentText == "")
        b.destroy()
    }

    @Test func typewriterRevealsOneUnitPerTick() {
        let b = SpeechBubble(listenToCommentary: false)
        b.show("abc")
        #expect(b.displayedText == "")
        b.typewriterTick()
        #expect(b.displayedText == "a")
        b.typewriterTick()
        b.typewriterTick()
        #expect(b.displayedText == "abc")
        b.typewriterTick() // the tick after the last char stops the interval
        #expect(b.displayedText == "abc")
        b.destroy()
    }

    @Test func typewriterNeverShowsHalfASurrogatePair() {
        let b = SpeechBubble(listenToCommentary: false)
        b.show("a🐑!")
        b.typewriterTick()
        #expect(b.displayedText == "a")
        b.typewriterTick() // high surrogate only
        #expect(b.displayedText == "a")
        b.typewriterTick()
        #expect(b.displayedText == "a🐑")
        b.typewriterTick()
        #expect(b.displayedText == "a🐑!")
        b.destroy()
    }

    @Test func boxGrowsAsCharactersAppear() {
        let b = SpeechBubble(listenToCommentary: false)
        let text = Array(repeating: "word", count: 40).joined(separator: " ")
        b.show(text)
        #expect(b.layout.lines.isEmpty)
        for _ in 0..<12 { b.typewriterTick() }
        let early = b.layout
        #expect(early.lines.count == 1)
        finishTyping(b, text)
        #expect(b.layout.height > early.height)
        #expect(b.layout.width == 300)
        b.destroy()
    }

    @Test func autoHideDelayNeverPrecedesTheTypewriter() {
        #expect(SpeechBubble.autoHideDelay(textLength: 10, duration: 5000) == 5000)
        #expect(SpeechBubble.autoHideDelay(textLength: 200, duration: 5000) == 200 * 30 + 2500)
        #expect(SpeechBubble.autoHideDelay(textLength: 0, duration: 100) == 2500)
    }

    @Test func updatePositionCentersAboveTheSheep() {
        withViewport(1000, 800) {
            let b = SpeechBubble(listenToCommentary: false)
            b.show("Hi")
            finishTyping(b, "Hi")
            let h = 28 + 19.6
            #expect(abs(b.layout.height - h) < 1e-9)
            b.updatePosition(500, 600, 96)
            // bubbleX = 548, bubbleY = 580 → bottom = viewportH - bubbleY
            #expect(b.left == 548)
            #expect(b.bottom == 220)
            b.destroy()
        }
    }

    @Test func updatePositionClampsToTheViewportEdges() {
        withViewport(1000, 800) {
            let b = SpeechBubble(listenToCommentary: false)
            b.show("Hi")
            finishTyping(b, "Hi")
            let h = 28 + 19.6

            b.updatePosition(0, 600, 96) // bubbleX 48 < halfW + 4
            #expect(b.left == 64)
            b.updatePosition(990, 600, 96) // bubbleX 1038 > W - halfW - 4
            #expect(b.left == 936)

            // A sheep near the top pushes the bubble down so it stays on screen
            b.updatePosition(500, -50, 96)
            #expect(abs((b.bottom ?? 0) - (800 - h - 8)) < 1e-9)
            // A sheep at the very bottom: at least height + 16 above the bottom
            b.updatePosition(500, 790, 96)
            #expect(abs((b.bottom ?? 0) - (h + 16)) < 1e-9)
            b.destroy()
        }
    }

    @Test func updatePositionDoesNothingWhileHidden() {
        let b = SpeechBubble(listenToCommentary: false)
        b.updatePosition(500, 500, 96)
        #expect(b.left == nil && b.bottom == nil)
        b.destroy()
    }

    @Test func positionSurvivesHideAndShowLikeInlineStyle() {
        withViewport(1000, 800) {
            let b = SpeechBubble(listenToCommentary: false)
            b.show("Hi")
            b.updatePosition(500, 600, 96)
            b.hide()
            b.show("Again")
            #expect(b.left == 548)
            b.destroy()
        }
    }

    @Test func drawsNothingWhileHiddenUnpositionedOrDestroyed() {
        withViewport(1000, 800) {
            let b = SpeechBubble(listenToCommentary: false)
            let c = Canvas()
            c.beginFrame()
            c.group("bubble:main", layer: .overlay) { b.draw(c) }
            #expect(c.groups.first?.ops.isEmpty ?? true)

            b.show("Hi") // visible but never positioned
            c.beginFrame()
            c.group("bubble:main", layer: .overlay) { b.draw(c) }
            #expect(c.groups.first?.ops.isEmpty ?? true)

            b.updatePosition(500, 600, 96)
            b.destroy()
            c.beginFrame()
            c.group("bubble:main", layer: .overlay) { b.draw(c) }
            #expect(c.groups.first?.ops.isEmpty ?? true)
        }
    }

    @Test func drawReproducesTheCSSBox() throws {
        try withViewport(1000, 800) {
            let b = SpeechBubble(listenToCommentary: false, borderColor: "#4a90d9")
            b.show("Hi")
            finishTyping(b, "Hi")
            b.updatePosition(500, 600, 96)

            let c = Canvas()
            c.beginFrame()
            c.group("bubble:main", layer: .overlay) { b.draw(c) }
            let group = try #require(c.groups.first)
            #expect(group.layer == .overlay)

            let fills: [(CGRect, Paint, ShadowParams?)] = group.ops.compactMap { op in
                if case .fill(let path, let paint, _) = op.kind { return (path.boundingBoxOfPath, paint, op.shadow) }
                return nil
            }
            // border ring, background, outer tail, inner tail
            #expect(fills.count == 4)

            let w = 120.0, h = 28 + 19.6
            let x = 548 - w / 2
            let y = 800 - 220 - h
            let border = Paint.color(try #require(CSSColor.parse("#4a90d9")))
            let bg = Paint.color(try #require(CSSColor.parse("#1a1a2e")))

            // Outer box: border color, radius 12, box-shadow 0 4px 12px rgba(0,0,0,.3)
            let ring = fills[0]
            #expect(rectsEqual(ring.0, CGRect(x: x, y: y, width: w, height: h)))
            #expect(ring.1 == border)
            let shadow = try #require(ring.2)
            #expect(shadow.blur == 12 && shadow.offsetX == 0 && shadow.offsetY == 4)
            #expect(shadow.color == RGBA(r: 0, g: 0, b: 0, a: 0.3))

            // Background inside the 2px border
            #expect(rectsEqual(fills[1].0, CGRect(x: x + 2, y: y + 2, width: w - 4, height: h - 4)))
            #expect(fills[1].1 == bg)
            #expect(fills[1].2 == nil)

            // Tails hang from the padding-box bottom (2px inside the border box)
            let tailTop = y + h - 2
            #expect(rectsEqual(fills[2].0, CGRect(x: 548 - 11, y: tailTop, width: 22, height: 11)))
            #expect(fills[2].1 == border)
            #expect(rectsEqual(fills[3].0, CGRect(x: 548 - 8, y: tailTop, width: 16, height: 8)))
            #expect(fills[3].1 == bg)

            // Text: one line at the content origin (border 2 + padding 16 / 12)
            let texts: [(String, Double, Double)] = group.ops.compactMap { op in
                if case .text(let s, _, let tx, let ty, _, _, _) = op.kind { return (s, tx, ty) }
                return nil
            }
            #expect(texts.count == 1)
            #expect(texts[0].0 == "Hi")
            #expect(abs(texts[0].1 - (x + 18)) < 1e-9)
            // Baseline sits inside the first 19.6pt line box
            let lineTop = y + 14
            #expect(texts[0].2 > lineTop && texts[0].2 < lineTop + 19.6)
            b.destroy()
        }
    }

    @Test func multiLineTextAdvancesByTheLineHeight() throws {
        try withViewport(1000, 800) {
            let b = SpeechBubble(listenToCommentary: false)
            let text = Array(repeating: "word", count: 40).joined(separator: " ")
            b.show(text)
            finishTyping(b, text)
            b.updatePosition(500, 600, 96)
            let c = Canvas()
            c.beginFrame()
            c.group("b", layer: .overlay) { b.draw(c) }
            let ys: [Double] = try #require(c.groups.first).ops.compactMap { op in
                if case .text(_, _, _, let ty, _, _, _) = op.kind { return ty }
                return nil
            }
            #expect(ys.count == b.layout.lines.count)
            #expect(ys.count > 1)
            for i in 1..<ys.count {
                #expect(abs((ys[i] - ys[i - 1]) - 19.6) < 1e-9)
            }
            // The box (and its tail) stays inside the group's bounds
            let bounds = try #require(c.groups.first).bounds
            let l = b.layout
            #expect(bounds.contains(CGRect(x: b.left! - l.width / 2, y: 800 - b.bottom! - l.height,
                                           width: l.width, height: l.height + 9)))
            b.destroy()
        }
    }

    @Test func borderColorFallsBackToTheDefault() throws {
        try withViewport(1000, 800) {
            let b = SpeechBubble(listenToCommentary: false, borderColor: "not-a-color")
            b.show("Hi")
            b.updatePosition(500, 600, 96)
            let c = Canvas()
            c.beginFrame()
            c.group("b", layer: .overlay) { b.draw(c) }
            let first = try #require(c.groups.first?.ops.first)
            guard case .fill(_, let paint, _) = first.kind else { Issue.record("expected fill"); return }
            #expect(paint == .color(try #require(CSSColor.parse("#e94560"))))
            b.destroy()
        }
    }

    @Test func commentaryEventsShowTextForEightSecondsAndFireTheAnimation() {
        let b = SpeechBubble(listenToCommentary: true)
        var got: [SheepAnimation] = []
        b.onAnimation = { got.append($0) }

        AppEvents.shared.sheepCommentary.emit(CommentaryEvent(text: "Baaa", animation: .spin))
        #expect(b.visible)
        #expect(b.currentText == "Baaa")
        #expect(got == [.spin])

        // No animation → no callback
        AppEvents.shared.sheepCommentary.emit(CommentaryEvent(text: "plain", animation: nil))
        #expect(b.currentText == "plain")
        #expect(got == [.spin])

        // destroy() unsubscribes
        b.hide()
        b.destroy()
        AppEvents.shared.sheepCommentary.emit(CommentaryEvent(text: "ignored", animation: .bounce))
        #expect(!b.visible)
        #expect(got == [.spin])
    }

    @Test func bubblesThatDoNotListenIgnoreCommentary() {
        let b = SpeechBubble(listenToCommentary: false)
        AppEvents.shared.sheepCommentary.emit(CommentaryEvent(text: "hello", animation: nil))
        #expect(!b.visible)
        b.destroy()
    }

    private func rectsEqual(_ a: CGRect, _ b: CGRect, tolerance: Double = 1e-6) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}

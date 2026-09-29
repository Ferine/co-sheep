import Testing
@testable import CoSheepKit

@Suite("overlay helpers", .serialized)
struct OverlayHelpersTests {
    @Test func fileCommentsPickByExtension() {
        let saved = SimRandom.source
        defer { SimRandom.source = saved }
        SimRandom.source = { 0 }
        #expect(FileComments.comment(forFileName: "main.RS") == "Rust! Now we're talking. *happy sheep noises*")
        #expect(FileComments.comment(forFileName: "report.pdf") == "A PDF? *chews* Dry.")
        #expect(FileComments.comment(forFileName: "thing.xyz") == "A .xyz file? Never heard of it. *chews anyway*")
        SimRandom.source = { 0.99 }
        #expect(FileComments.comment(forFileName: "notes.md") == "*reads* Wait, is this about me?")
        #expect(FileComments.comment(forFileName: "a.b.c") == "You're feeding me \"a.b.c\"? I have standards. Low ones, but still.")
    }

    @Test func stampedeNeedsSpeedAndReversals() {
        var d = StampedeDetector()
        var fired: (x: Double, y: Double)?
        // 11 samples, 10ms apart, zig-zagging 100px → 10000 px/s, 9 reversals.
        for i in 0...10 {
            let x = i % 2 == 0 ? 500.0 : 600.0
            if let hit = d.sample(x: x, y: 300, now: 20_000 + Double(i) * 10) { fired = hit }
        }
        #expect(fired != nil)
        #expect(d.history.count == 1) // cleared on fire (10th sample), then the 11th appended
        // Cooldown: immediately shaking again doesn't fire.
        var again: (x: Double, y: Double)?
        for i in 0...10 {
            let x = i % 2 == 0 ? 500.0 : 600.0
            if let hit = d.sample(x: x, y: 300, now: 21_000 + Double(i) * 10) { again = hit }
        }
        #expect(again == nil)
    }

    @Test func fastStraightLineIsNotAStampede() {
        var d = StampedeDetector()
        var fired = false
        for i in 0...10 {
            if d.sample(x: Double(i) * 100, y: 0, now: 20_000 + Double(i) * 10) != nil { fired = true }
        }
        #expect(!fired)
    }

    @Test func bubbleShapeDraws() {
        let c = Canvas()
        c.beginFrame()
        drawBubbleShape(c, 100, 80, "Moment captured with a fairly long line of text that must wrap")
        #expect(c.groups.first?.ops.isEmpty == false)
    }
}

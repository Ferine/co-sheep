import Foundation

// Pure pieces of main.ts, kept separate from OverlayController so they're testable.

/// Ex-`getFileComment`: what a sheep says when fed a file.
enum FileComments {
    static func comment(forFileName name: String) -> String {
        let ext = name.split(separator: ".", omittingEmptySubsequences: false).last.map { $0.lowercased() } ?? ""

        let comments: [String: [String]] = [
            "pdf": [
                "A PDF? *chews* Dry.",
                "\"\(name)\"... riveting literature, I'm sure.",
                "*nibbles corner* Tastes like bureaucracy.",
            ],
            "png": [
                "Ooh, a picture! *munches* Not bad.",
                "Is this your idea of art? Bold choice.",
                "*examines pixels* I've seen better.",
            ],
            "jpg": [
                "A JPEG? The compression! My taste buds!",
                "*squints at artifacts* Needs more pixels.",
            ],
            "gif": [
                "A GIF! Finally, some entertainment.",
                "*watches loop 47 times* Still funny.",
            ],
            "mp3": [
                "Music? My ears are made of wool, but I'll try.",
                "*bobs head* Not baaad.",
            ],
            "mp4": [
                "A video? I don't have that kind of attention span.",
                "*stares* Is this what you watch instead of working?",
            ],
            "js": [
                "JavaScript? *gags* At least it's not PHP.",
                "*reads code* I have opinions. None of them good.",
            ],
            "ts": [
                "TypeScript! A sheep of culture, your human.",
                "*types checked* ...mostly.",
            ],
            "rs": [
                "Rust! Now we're talking. *happy sheep noises*",
                "*borrows and returns* The borrow checker approves.",
            ],
            "py": [
                "Python? *hisses* Snakes are NOT my friends.",
                "Significant whitespace? In THIS economy?",
            ],
            "zip": [
                "*swallows whole* That was a lot to digest.",
                "A zip file? I'm not opening that. I'm a sheep, not a bomb squad.",
            ],
            "exe": [
                "An exe? I'm not clicking that and neither should you.",
                "*backs away slowly*",
            ],
            "md": [
                "Markdown! My diary format of choice.",
                "*reads* Wait, is this about me?",
            ],
            "txt": [
                "Plain text. How refreshingly boring.",
                "*reads entire thing in 0.3 seconds* Meh.",
            ],
        ]

        let pool = comments[ext] ?? [
            "A .\(ext) file? Never heard of it. *chews anyway*",
            "*sniffs \(name)* Smells like work.",
            "You're feeding me \"\(name)\"? I have standards. Low ones, but still.",
        ]

        return pool[SimRandom.int(pool.count)]
    }
}

/// Ex-stampede detection in main.ts: rapid mouse shaking with direction reversals.
struct StampedeDetector {
    static let COOLDOWN: Double = 15000
    static let SPEED_THRESHOLD: Double = 3000 // px/s average speed
    static let SAMPLES = 10
    static let MIN_REVERSALS = 3

    private(set) var history: [(x: Double, y: Double, time: Double)] = []
    private(set) var lastStampedeTime: Double = 0

    /// Feed a mousemove; returns the trigger point when a stampede should start.
    mutating func sample(x: Double, y: Double, now: Double) -> (x: Double, y: Double)? {
        history.append((x, y, now))
        if history.count > Self.SAMPLES + 1 {
            history.removeFirst()
        }

        guard history.count >= Self.SAMPLES, now - lastStampedeTime > Self.COOLDOWN else { return nil }
        var totalDist: Double = 0
        var reversals = 0
        for i in 1..<history.count {
            let dx = history[i].x - history[i - 1].x
            let dy = history[i].y - history[i - 1].y
            totalDist += (dx * dx + dy * dy).squareRoot()
            if i >= 2 {
                let prevDx = history[i - 1].x - history[i - 2].x
                if (dx > 0 && prevDx < 0) || (dx < 0 && prevDx > 0) { reversals += 1 }
            }
        }
        let elapsed = (history[history.count - 1].time - history[0].time) / 1000
        let speed = elapsed > 0 ? totalDist / elapsed : 0

        guard speed > Self.SPEED_THRESHOLD, reversals >= Self.MIN_REVERSALS else { return nil }
        let center = (history[history.count - 1].x, history[history.count - 1].y)
        lastStampedeTime = now
        history.removeAll()
        return center
    }
}

/// Ex-`drawBubbleShape` (Capture Moment's baked-in speech bubble).
func drawBubbleShape(_ ctx: Canvas, _ cx: Double, _ bottomY: Double, _ text: String) {
    ctx.save()
    ctx.font = "12px 'Courier New', monospace"

    // Wrap text
    let maxLineW: Double = 180
    let words = text.components(separatedBy: " ")
    var lines: [String] = []
    var currentLine = ""
    for word in words {
        let test = currentLine.isEmpty ? word : currentLine + " " + word
        if ctx.measureText(test).width > maxLineW {
            if !currentLine.isEmpty { lines.append(currentLine) }
            currentLine = word
        } else {
            currentLine = test
        }
    }
    if !currentLine.isEmpty { lines.append(currentLine) }

    let lineH: Double = 16
    let padX: Double = 10
    let padY: Double = 8
    let bubbleW = min(maxLineW + padX * 2, 200)
    let bubbleH = Double(lines.count) * lineH + padY * 2
    let bubbleX = cx - bubbleW / 2
    let bubbleY = bottomY - bubbleH - 8

    // Background
    ctx.fillStyle = "#1a1a2e"
    ctx.strokeStyle = "#e94560"
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.roundRect(bubbleX, bubbleY, bubbleW, bubbleH, 6)
    ctx.fill()
    ctx.stroke()

    // Tail
    ctx.fillStyle = "#1a1a2e"
    ctx.beginPath()
    ctx.moveTo(cx - 6, bubbleY + bubbleH)
    ctx.lineTo(cx, bubbleY + bubbleH + 8)
    ctx.lineTo(cx + 6, bubbleY + bubbleH)
    ctx.closePath()
    ctx.fill()
    ctx.strokeStyle = "#e94560"
    ctx.beginPath()
    ctx.moveTo(cx - 6, bubbleY + bubbleH)
    ctx.lineTo(cx, bubbleY + bubbleH + 8)
    ctx.lineTo(cx + 6, bubbleY + bubbleH)
    ctx.stroke()

    // Text
    ctx.fillStyle = "#eee"
    for (i, line) in lines.enumerated() {
        ctx.fillText(line, bubbleX + padX, bubbleY + padY + Double(i + 1) * lineH - 3)
    }
    ctx.restore()
}

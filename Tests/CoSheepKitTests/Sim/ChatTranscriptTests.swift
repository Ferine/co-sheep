import Testing
@testable import CoSheepKit

private func turn(_ role: ChatTurn.Role, _ text: String) -> ChatTurn {
    ChatTurn(role: role, text: text)
}

// Ex-chat-transcript.test.ts
@Suite("capTranscript")
struct CapTranscriptTests {
    @Test func returnsEmptyForEmptyHistory() {
        #expect(capTranscript([]) == [])
    }

    @Test func keepsShortHistoriesUnchanged() {
        let turns = [turn(.human, "hei"), turn(.sheep, "bæ")]
        #expect(capTranscript(turns) == turns)
    }

    @Test func capsToTheLast8Turns() {
        let turns = (0..<12).map { i in
            turn(i % 2 == 0 ? .human : .sheep, "msg \(i)")
        }
        let capped = capTranscript(turns)
        #expect(capped.count == 8)
        #expect(capped[0].text == "msg 4")
        #expect(capped[7].text == "msg 11")
    }

    @Test func dropsOldestTurnsToStayUnderTheCharBudget() {
        let big = String(repeating: "x", count: 700)
        let turns = [
            turn(.human, big),
            turn(.sheep, big),
            turn(.human, big),
        ]
        let capped = capTranscript(turns)
        #expect(capped.count == 2)
        #expect(capped[0].role == .sheep)
    }

    @Test func alwaysKeepsTheNewestTurnEvenIfItAloneBustsTheBudget() {
        let turns = [turn(.human, String(repeating: "x", count: 9000))]
        #expect(capTranscript(turns).count == 1)
    }

    // New: JS `.length` counts UTF-16 units, so an emoji costs 2.
    @Test func budgetCountsUTF16UnitsLikeJS() {
        let sheepEmoji = String(repeating: "🐑", count: 400) // 800 UTF-16 units, 400 characters
        let turns = [
            turn(.human, sheepEmoji),
            turn(.sheep, sheepEmoji),
        ]
        // 1600 units > 1500 budget → the oldest drops (would fit at 800 characters)
        #expect(capTranscript(turns).count == 1)
    }
}

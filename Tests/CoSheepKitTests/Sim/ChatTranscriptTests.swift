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

@Suite("chat session log")
struct ChatSessionLogTests {
    @Test func aRepliedExchangeIsKeptAndFeedsTheNextHistory() {
        var log = ChatSessionLog()
        let (s1, h1) = log.send("hi")
        #expect(h1.isEmpty)
        let r1 = log.answered(s1, "Baa.")
        #expect(r1)
        let (_, h2) = log.send("how are you?")
        #expect(h2 == [ChatTurn(role: .human, text: "hi"), ChatTurn(role: .sheep, text: "Baa.")])
    }

    @Test func aFailedMessageLeavesNoTurnBehind() {
        var log = ChatSessionLog()
        let (s1, _) = log.send("hi")
        let r2 = log.failed(s1)
        #expect(r2)
        #expect(log.turns.isEmpty)
    }

    @Test func aSupersededMessageNeitherAnswersNorLingers() {
        var log = ChatSessionLog()
        let (s1, _) = log.send("first") // slow; the input comes back
        let (s2, h2) = log.send("second")
        #expect(h2.isEmpty) // the unanswered "first" isn't sent as history
        let r3 = log.answered(s1, "late reply")
        #expect(!r3)
        let r4 = log.failed(s1)
        #expect(!r4)
        #expect(log.turns == [ChatTurn(role: .human, text: "second")])
        let r5 = log.answered(s2, "Baa.")
        #expect(r5)
        #expect(log.turns == [ChatTurn(role: .human, text: "second"), ChatTurn(role: .sheep, text: "Baa.")])
    }

    @Test func aSupersededFailureDoesNotDropTheNewerTurn() {
        var log = ChatSessionLog()
        let (s1, _) = log.send("first")
        _ = log.send("second")
        let r6 = log.failed(s1)
        #expect(!r6)
        #expect(log.turns == [ChatTurn(role: .human, text: "second")])
    }

    @Test func aReplyIsOnlyTakenOnce() {
        var log = ChatSessionLog()
        let (s1, _) = log.send("hi")
        let r7 = log.answered(s1, "Baa.")
        #expect(r7)
        let r8 = log.answered(s1, "Baa again.")
        #expect(!r8)
        let r9 = log.failed(s1)
        #expect(!r9)
        #expect(log.turns.count == 2)
    }
}

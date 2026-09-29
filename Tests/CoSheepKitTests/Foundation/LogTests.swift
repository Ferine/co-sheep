import Foundation
import Testing
@testable import CoSheepKit

// Ex-logging.rs tests
@Suite("logging")
struct LogTests {
    @Test func shortStringsPassThrough() {
        #expect(Log.truncateForLog("bæææ", maxBytes: 200) == "bæææ")
    }

    @Test func truncationRespectsCharBoundariesAndAppendsEllipsis() {
        // 'æ' is 2 bytes; cutting at byte 4 would split the second 'æ'
        #expect(Log.truncateForLog("bæææ tenker", maxBytes: 4) == "bæ…")
    }

    @Test func exactFitIsNotTruncated() {
        #expect(Log.truncateForLog("abcd", maxBytes: 4) == "abcd")
    }

    @Test func stripsPlainAndIdLegacyPrefixes() {
        #expect(Log.stripLegacyPrefix("[co-sheep] Canvas ready") == "Canvas ready")
        #expect(Log.stripLegacyPrefix("[co-sheep:friend_123] bounce") == "bounce")
        #expect(Log.stripLegacyPrefix("no prefix here") == "no prefix here")
        #expect(Log.stripLegacyPrefix("[other] tag") == "[other] tag")
    }

    @Test func lineFormatPadsTag() {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 29; c.hour = 7; c.minute = 5; c.second = 9
        let d = Calendar.current.date(from: c)!
        #expect(Log.line("app", "hi", date: d) == "07:05:09 [app    ] hi")
        #expect(Log.line("reflection", "x", date: d) == "07:05:09 [reflection] x")
    }
}

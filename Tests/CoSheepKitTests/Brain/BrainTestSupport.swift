import CoreGraphics
import Foundation
import Testing
@testable import CoSheepKit

/// Root of every Brain suite. All of them point the process-global
/// `Paths.root` (and sometimes `SimClock`) at temp state, and the async ones
/// interleave at suspension points, so the whole tree runs serially.
@Suite("Brain", .serialized)
struct BrainTests {}

/// A local wall-clock `Date` (the Brain code formats in the local zone).
func localDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .autoupdatingCurrent
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

func naiveDate(_ y: Int, _ m: Int, _ d: Int) -> NaiveDate {
    NaiveDate(year: y, month: m, day: d)!
}

private func enterTempRoot(now: Date?) -> (root: URL, restore: () -> Void) {
    let savedRoot = Paths.root
    let savedNow = SimClock.nowSource
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("co-sheep-brain-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    Paths.root = dir
    if let now { SimClock.nowSource = { now.timeIntervalSince1970 * 1000 } }
    FriendMemory.resetCache()
    return (dir, {
        Paths.root = savedRoot
        SimClock.nowSource = savedNow
        FriendMemory.resetCache()
        try? FileManager.default.removeItem(at: dir)
    })
}

/// Run `body` with `Paths.root` pointing at a fresh temp dir (and, when
/// `now` is given, the clock pinned), restoring both afterwards.
func withBrainRoot<T>(now: Date? = nil, _ body: (URL) throws -> T) rethrows -> T {
    let (root, restore) = enterTempRoot(now: now)
    defer { restore() }
    return try body(root)
}

func withBrainRoot<T>(now: Date? = nil, _ body: (URL) async throws -> T) async rethrows -> T {
    let (root, restore) = enterTempRoot(now: now)
    defer { restore() }
    return try await body(root)
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

func readJSON(_ url: URL) throws -> JSONValue {
    try JSONFile.readStrict(JSONValue.self, from: url)
}

/// Scriptable `LanguageModel`: replies come from `handler`.
final class FakeModel: LanguageModel {
    private(set) var calls: [(system: String, prompt: String)] = []
    var handler: (String, String) async throws -> String

    init(reply: String = #"{"ops": []}"#) {
        handler = { _, _ in reply }
    }

    init(handler: @escaping (String, String) async throws -> String) {
        self.handler = handler
    }

    func unavailableReason() -> String? { nil }

    func generate(system: String, prompt: String) async throws -> String {
        calls.append((system, prompt))
        return try await handler(system, prompt)
    }

    func generateChat(system: String, prompt: String, history: [HistoryTurn]) async throws -> String {
        try await generate(system: system, prompt: prompt)
    }

    func ocr(_ image: CGImage) async throws -> String { "" }
}

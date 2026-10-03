import Foundation
import Synchronization
import Testing
@testable import CoSheepKit

// Anyone on this machine who can reach 127.0.0.1 chooses what a `/hook` payload
// says, so: the big body allowance is only for an authorized hook POST, and the
// tailer only reads files shaped like Claude Code transcripts, opened safely.
@Suite("herd hardening")
struct HerdHardeningTests {
    // MARK: transcript path policy

    @Test(arguments: [
        "/Users/x/.claude/projects/-Users-x-dev-app/abc-123.jsonl",
        "~/.claude/projects/-Users-x-dev-app/abc-123.jsonl",
        "/scratch/claude-config/projects/p/abc-123.jsonl",
    ])
    func claudeShapedTranscriptPathsAreAccepted(_ path: String) {
        #expect(TranscriptTailer.isTranscriptPath(path, sessionId: "abc-123"))
    }

    @Test(arguments: [
        "/etc/passwd",
        "/Users/x/.claude/projects/p/other-session.jsonl",
        "/Users/x/.claude/elsewhere/p/abc-123.jsonl",
        "/Users/x/.claude/projects/abc-123.jsonl",
        "/Users/x/.claude/projects/p/../../secrets/abc-123.jsonl",
        "/Users/x/.claude/projects/p/./abc-123.jsonl",
        "relative/projects/p/abc-123.jsonl",
        "",
    ])
    func otherPathsAreRefused(_ path: String) {
        #expect(!TranscriptTailer.isTranscriptPath(path, sessionId: "abc-123"))
    }

    @Test func anEmptySessionIdNeverMatches() {
        #expect(!TranscriptTailer.isTranscriptPath("/a/projects/p/.jsonl", sessionId: ""))
    }

    @Test func theStoreOnlyTailsAcceptedPaths() async {
        let reads = Mutex<[String]>([])
        let store = HerdStore(
            events: AppEvents(),
            now: { 1_000 },
            isAlive: { _ in true },
            readTranscript: { path, cursor, _ in
                reads.withLock { $0.append(path) }
                return TranscriptRead(cursor: cursor, update: nil)
            },
            findTerminal: { _ in nil },
            findRepo: { ($0, ($0 as NSString).lastPathComponent) })
        store.ingest(HookEvent(sessionId: "s1", hookEventName: "SessionStart", cwd: "/w/app",
                               transcriptPath: "/home/me/.ssh/id_ed25519.jsonl"))
        store.ingest(HookEvent(sessionId: "s2", hookEventName: "SessionStart", cwd: "/w/app",
                               transcriptPath: "/home/me/.claude/projects/-w-app/s2.jsonl"))
        await store.pollTranscripts()
        #expect(reads.withLock { $0 } == ["/home/me/.claude/projects/-w-app/s2.jsonl"])
    }

    // MARK: reader opens, then checks what it opened

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herd-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aFifoNamedLikeATranscriptIsSkippedWithoutBlocking() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("s1.jsonl").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let started = Date()
        let read = TranscriptTailer.readNew(path: fifo, cursor: TranscriptCursor(), nowMs: 0)
        #expect(read.update == nil)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func aSymlinkedTranscriptLeafIsRefused() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.jsonl")
        try Data(#"{"type":"ai-title","aiTitle":"secret"}"#.utf8 + [0x0a]).write(to: target)
        let link = dir.appendingPathComponent("s1.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(TranscriptTailer.readNew(path: link.path, cursor: TranscriptCursor(), nowMs: 0).update == nil)
        // The regular file itself still reads.
        #expect(TranscriptTailer.readNew(path: target.path, cursor: TranscriptCursor(), nowMs: 0).update?.title == "secret")
    }

    // MARK: body allowance is decided from the head

    private func head(
        method: String = "POST", target: String = "/hook", host: String = "127.0.0.1:4917",
        authorization: String? = nil
    ) -> HTTPRequest {
        var headers = [HTTPHeader(name: "Host", value: host)]
        if let authorization { headers.append(HTTPHeader(name: "Authorization", value: authorization)) }
        return HTTPRequest(method: method, target: target, headers: headers)
    }

    private func endpoint(token: String) -> MCPEndpoint {
        MCPEndpoint(token: token, perform: { _ in })
    }

    @Test func anAuthorizedHookPostGetsTheLargeAllowance() {
        #expect(endpoint(token: "").bodyLimit(for: head()) == MCPServer.maxBodyBytes)
        #expect(endpoint(token: "sekrit").bodyLimit(for: head(authorization: "Bearer sekrit")) == MCPServer.maxBodyBytes)
    }

    @Test func everythingElseKeepsTheDefaultAllowance() {
        let small = HTTPParser.maxBodyBytes
        #expect(endpoint(token: "sekrit").bodyLimit(for: head()) == small)
        #expect(endpoint(token: "sekrit").bodyLimit(for: head(authorization: "Bearer nope")) == small)
        #expect(endpoint(token: "").bodyLimit(for: head(target: "/mcp")) == small)
        #expect(endpoint(token: "").bodyLimit(for: head(method: "PUT")) == small)
        #expect(endpoint(token: "").bodyLimit(for: head(host: "evil.example:4917")) == small)
    }

    @Test func theParserAppliesTheHeadDependentLimitBeforeReadingTheBody() {
        let raw = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(HTTPParser.maxBodyBytes + 1)\r\n\r\n"
        let ep = endpoint(token: "")
        #expect(HTTPParser.parse(Data(raw.utf8), bodyLimit: { ep.bodyLimit(for: $0) })
                == .failure(status: 413, reason: "Content Too Large"))
        let hook = raw.replacingOccurrences(of: "/mcp", with: "/hook")
        #expect(HTTPParser.parse(Data(hook.utf8), bodyLimit: { ep.bodyLimit(for: $0) })
                == .needMore(expectContinue: false))
    }
}

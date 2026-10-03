import Foundation
import Testing
@testable import CoSheepKit

// Agent herd: the generated hook shim, executed for real with /bin/sh.

/// A one-shot HTTP listener on 127.0.0.1 (ephemeral port) that records the
/// first request and answers 204.
nonisolated final class LoopbackListener: @unchecked Sendable {
    // `captured` is written once by the serving thread before `done` is
    // signalled, and only read after waiting on `done`.
    let port: UInt16
    private let listenFD: Int32
    private let done = DispatchSemaphore(value: 0)
    private var captured = Data()

    /// A free port: bound, then released (nothing listens on it afterwards).
    static func unusedPort() throws -> UInt16 {
        let (fd, port) = try bindLoopback()
        close(fd)
        return port
    }

    private static func bindLoopback() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        var len = size
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard bound == 0, named == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    init() throws {
        let (fd, port) = try Self.bindLoopback()
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.listenFD = fd
        self.port = port
        Thread.detachNewThread { [self] in serve() }
    }

    private func serve() {
        defer {
            close(listenFD)
            done.signal()
        }
        var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 8000) > 0 else { return }
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var total: Int?
        while true {
            let n = recv(client, &buffer, buffer.count, 0)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if total == nil, let end = data.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
                let length = head.components(separatedBy: "\r\n")
                    .first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
                total = end.upperBound + (length ?? 0)
            }
            if let total, data.count >= total { break }
        }
        captured = data
        let reply = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
        _ = reply.withCString { send(client, $0, strlen($0), 0) }
    }

    /// The recorded request, or nil when nothing arrived in time.
    func request() -> (head: String, body: Data)? {
        guard done.wait(timeout: .now() + 12) == .success, !captured.isEmpty else { return nil }
        guard let end = captured.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return (String(decoding: captured[..<end.lowerBound], as: UTF8.self), Data(captured[end.upperBound...]))
    }
}

extension BrainTests {
    @Suite("hook shim")
    struct HookShimTests {
        private struct Run {
            var status: Int32
            var stdout: String
            var stderr: String
            var seconds: Double
        }

        private func withShim<T>(
            port: UInt16, token: String = "", _ body: (HookInstaller) throws -> T
        ) throws -> T {
            try withBrainRoot { root in
                let installer = HookInstaller(
                    claudeDir: root.appendingPathComponent("claude"),
                    shimURL: Paths.dir("hooks").appendingPathComponent("claude-hook.sh"),
                    port: port, token: token)
                try installer.install()
                return try body(installer)
            }
        }

        private func run(_ shim: URL, stdin: Data, env: [String: String] = [:]) throws -> Run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [shim.path]
            var environment = ProcessInfo.processInfo.environment
            environment["CLAUDE_PID"] = nil
            for (k, v) in env { environment[k] = v }
            process.environment = environment
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors

            let start = Date()
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let seconds = Date().timeIntervalSince(start)
            return Run(
                status: process.terminationStatus,
                stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                stderr: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                seconds: seconds)
        }

        private let sample = Data(#"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash"}"#.utf8)

        // MARK: script text

        @Test func scriptForPort4917WithoutATokenIsExactlyThis() {
            let expected = #"""
            #!/bin/sh
            # co-sheep: Claude Code hook (written by co-sheep; Connect/Repair rewrites it).
            # Forwards the hook event on stdin to co-sheep on 127.0.0.1:4917 so the session
            # shows up as a lamb on the desktop. Prints nothing and ALWAYS exits 0, so it can
            # never block, steer or slow down Claude Code.
            payload=$(cat)
            pid=${CLAUDE_PID:-$PPID}
            case $pid in ''|*[!0-9]*) pid=$PPID ;; esac
            { printf '%s' "$payload" | /usr/bin/curl -s -o /dev/null --connect-timeout 0.3 -m 1 \
              --noproxy '*' -X POST -H 'Content-Type: application/json' -H 'Expect:' \
              -H "X-Co-Sheep-Pid: $pid" \
              --data-binary @- "http://127.0.0.1:4917/hook" ; } >/dev/null 2>&1
            exit 0

            """#
            #expect(HookInstaller.shimScript(port: 4917, token: "") == expected)
        }

        @Test func tokenGoesInASingleQuotedBearerHeader() {
            let script = HookInstaller.shimScript(port: 4917, token: "abc123")
            #expect(script.contains("  -H 'Authorization: Bearer abc123' \\\n  --data-binary"))
            #expect(!HookInstaller.shimScript(port: 4917, token: "").contains("Authorization"))
        }

        @Test func aQuoteInTheTokenIsEscapedForTheShell() {
            let script = HookInstaller.shimScript(port: 1, token: "it's")
            #expect(script.contains(#"-H 'Authorization: Bearer it'\''s'"#))
            #expect(HookInstaller.singleQuoted("a'b") == #"'a'\''b'"#)
        }

        @Test func scriptsParseAsPOSIXShell() throws {
            for token in ["", "plain", "it's", "a\"b$(x)`y`\\z", "sp ace;&|<>"] {
                try withShim(port: 4917, token: token) { i in
                    let check = Process()
                    check.executableURL = URL(fileURLWithPath: "/bin/sh")
                    check.arguments = ["-n", i.shimURL.path]
                    try check.run()
                    check.waitUntilExit()
                    #expect(check.terminationStatus == 0, "\(token)")
                }
            }
        }

        // MARK: running it

        @Test func exitsZeroSilentlyAndFastWhenNothingListens() throws {
            let port = try LoopbackListener.unusedPort()
            try withShim(port: port) { i in
                let result = try run(i.shimURL, stdin: sample)
                #expect(result.status == 0)
                #expect(result.stdout.isEmpty)
                #expect(result.stderr.isEmpty)
                #expect(result.seconds < 2)
            }
        }

        @Test func exitsZeroWithEmptyStdinAndAGarbageClaudePid() throws {
            let port = try LoopbackListener.unusedPort()
            try withShim(port: port, token: "it's") { i in
                let result = try run(i.shimURL, stdin: Data(), env: ["CLAUDE_PID": "12; rm -rf /"])
                #expect(result.status == 0)
                #expect(result.stdout.isEmpty)
                #expect(result.stderr.isEmpty)
                #expect(result.seconds < 2)
            }
        }

        @Test func aHugeUnreadPayloadStillExitsZeroQuietly() throws {
            let port = try LoopbackListener.unusedPort()
            try withShim(port: port) { i in
                let big = Data(("{\"session_id\":\"s\",\"hook_event_name\":\"PostToolUse\",\"tool_response\":\""
                    + String(repeating: "x", count: 6_000_000) + "\"}").utf8)
                let result = try run(i.shimURL, stdin: big)
                #expect(result.status == 0)
                #expect(result.stdout.isEmpty)
                #expect(result.stderr.isEmpty)
                #expect(result.seconds < 4)
            }
        }

        @Test func postsTheEventWithPidAndTokenToHook() throws {
            let listener = try LoopbackListener()
            try withShim(port: listener.port, token: "s3cret") { i in
                let result = try run(i.shimURL, stdin: sample, env: ["CLAUDE_PID": "4242"])
                #expect(result.status == 0)
                #expect(result.stdout.isEmpty)
                let request = try #require(listener.request())
                #expect(request.head.hasPrefix("POST /hook HTTP/1.1"))
                #expect(request.head.contains("X-Co-Sheep-Pid: 4242"))
                #expect(request.head.contains("Authorization: Bearer s3cret"))
                #expect(request.head.lowercased().contains("content-type: application/json"))
                #expect(request.body == sample)
            }
        }

        @Test func fallsBackToTheParentPidWithoutClaudePid() throws {
            let listener = try LoopbackListener()
            try withShim(port: listener.port) { i in
                _ = try run(i.shimURL, stdin: sample)
                let request = try #require(listener.request())
                let ppid = ProcessInfo.processInfo.processIdentifier
                #expect(request.head.contains("X-Co-Sheep-Pid: \(ppid)"))
                #expect(!request.head.contains("Authorization"))
            }
        }

        @Test func aHostileTokenReachesTheServerLiterallyAndRunsNothing() throws {
            let listener = try LoopbackListener()
            try withBrainRoot { root in
                let marker = root.appendingPathComponent("pwned")
                let token = "a'b\"c$(touch \(marker.path))`touch \(marker.path)`;touch \(marker.path)"
                let i = HookInstaller(
                    claudeDir: root.appendingPathComponent("claude"),
                    shimURL: Paths.dir("hooks").appendingPathComponent("claude-hook.sh"),
                    port: listener.port, token: token)
                try i.install()
                let result = try run(i.shimURL, stdin: sample)
                #expect(result.status == 0)
                #expect(result.stdout.isEmpty)
                let request = try #require(listener.request())
                #expect(request.head.contains("Authorization: Bearer \(token)"))
                #expect(!FileManager.default.fileExists(atPath: marker.path))
            }
        }

        @Test func aMultiMegabytePayloadArrivesWholeWithoutAnExpectHandshake() throws {
            let listener = try LoopbackListener()
            try withShim(port: listener.port) { i in
                let big = Data(("{\"session_id\":\"s\",\"hook_event_name\":\"PostToolUse\",\"tool_response\":\""
                    + String(repeating: "y", count: 1_500_000) + "\"}").utf8)
                let result = try run(i.shimURL, stdin: big)
                #expect(result.status == 0)
                let request = try #require(listener.request())
                #expect(!request.head.lowercased().contains("expect:"))
                #expect(request.body == big)
            }
        }
    }
}

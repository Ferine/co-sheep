import Darwin
import Foundation
import Synchronization
import Testing
@testable import CoSheepKit

// Loopback integration: a real MCPServer on an ephemeral port, driven with
// URLSession (a real HTTP client) and, for framing edge cases, a raw socket.

/// Blocking raw TCP exchange with 127.0.0.1:`port`. Writes each chunk (waiting
/// `delayMs` before it), then reads until the server closes the connection.
@concurrent
private func rawExchange(port: UInt16, chunks: [(String, Int)]) async throws -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw PlatformError("socket() failed") }
    defer { close(fd) }

    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw PlatformError("connect() failed: errno \(errno)") }

    for (chunk, delayMs) in chunks {
        if delayMs > 0 { try await Task.sleep(for: .milliseconds(delayMs)) }
        let bytes = Array(chunk.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break } // the server may already have answered and closed
            sent += n
        }
    }

    var received = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { break }
        received.append(contentsOf: buffer[0..<n])
    }
    return String(decoding: received, as: UTF8.self)
}

@Suite("mcp server over loopback")
struct MCPServerTests {
    private struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
        var json: JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: body) }
        var result: JSONValue? { json?["result"] }
        var text: String? { result?["content"]?.arrayValue?.first?["text"]?.stringValue }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:] // never route loopback through a system proxy
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    private func http(
        _ session: URLSession, port: UInt16, method: String = "POST", path: String = "/mcp",
        body: String? = nil, token: String? = nil, extra: [String: String] = [:]
    ) async throws -> Reply {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in extra { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers["\(k)".lowercased()] = "\(v)" }
        return Reply(status: http.statusCode, headers: headers, body: data)
    }

    private func makeServer() -> (MCPServer, AppEvents) {
        let events = AppEvents()
        return (MCPServer(store: SessionStore(events: events), events: events), events)
    }

    // MARK: the real flow

    @Test func initializeThenToolsListThenToolsCall() async throws {
        let (server, events) = makeServer()
        var sessionEvents: [SessionEvent] = []
        events.sheepSession.on { sessionEvents.append($0) }
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }
        #expect(port != 0)
        #expect(server.port == port)
        #expect(server.isRunning)
        let session = Self.makeSession()

        let initialize = try await http(session, port: port, body:
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        #expect(initialize.status == 200)
        #expect(initialize.headers["content-type"] == "application/json")
        #expect(initialize.headers["connection"]?.lowercased() != "keep-alive")
        #expect(initialize.result == (try JSONDecoder().decode(JSONValue.self, from: Data(RmcpFixtures.initializeResult.utf8))))

        let initialized = try await http(session, port: port, body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(initialized.status == 202)
        #expect(initialized.body.isEmpty)

        let list = try await http(session, port: port, body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(list.status == 200)
        #expect(list.result == (try JSONDecoder().decode(JSONValue.self, from: Data(RmcpFixtures.toolsListResult.utf8))))

        let begin = try await http(session, port: port, body:
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"session_begin","arguments":{"task":"port to swift"}}}"#)
        #expect(begin.status == 200)
        #expect(begin.text == "ok")
        #expect(begin.json?["id"] == .number(3))

        let progress = try await http(session, port: port, body:
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"progress","arguments":{"fraction":0.5}}}"#)
        #expect(progress.text == "ok")
        let milestone = try await http(session, port: port, body:
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"milestone","arguments":{"kind":"waiting_on_you","detail":"need the API key"}}}"#)
        #expect(milestone.text == "ok")

        // The tool result is only sent after the event was emitted on the main actor.
        #expect(sessionEvents.map(\.kind) == ["begin", "progress", "milestone"])
        #expect(sessionEvents[0].task == "port to swift")
        #expect(sessionEvents[0].health == "good")
        #expect(sessionEvents[1].progress == 0.5)
        #expect(sessionEvents[2] == SessionEvent(
            kind: "milestone", task: "port to swift", progress: 0.5,
            milestone: "waiting_on_you", detail: "need the API key", health: "degraded"))
    }

    @Test func sayEmitsCommentaryWithAKnownAnimation() async throws {
        let (server, events) = makeServer()
        var lines: [CommentaryEvent] = []
        events.sheepCommentary.on { lines.append($0) }
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }
        let session = Self.makeSession()

        let spin = try await http(session, port: port, body:
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"say","arguments":{"text":"Baaa 🐑","animation":"spin"}}}"#)
        #expect(spin.text == "ok")
        let unknown = try await http(session, port: port, body:
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"say","arguments":{"text":"plain","animation":"moonwalk"}}}"#)
        #expect(unknown.text == "ok")
        let bare = try await http(session, port: port, body:
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"say","arguments":{"text":"bare"}}}"#)
        #expect(bare.text == "ok")

        #expect(lines == [
            CommentaryEvent(text: "Baaa 🐑", animation: .spin),
            CommentaryEvent(text: "plain", animation: nil),
            CommentaryEvent(text: "bare", animation: nil),
        ])
    }

    @Test func concurrentCallsAreAllApplied() async throws {
        let (server, events) = makeServer()
        var count = 0
        events.sheepSession.on { _ in count += 1 }
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }
        let session = Self.makeSession()

        try await withThrowingTaskGroup(of: String?.self) { group in
            for i in 0..<25 {
                group.addTask { @concurrent in
                    try await self.http(session, port: port, body:
                        #"{"jsonrpc":"2.0","id":\#(i),"method":"tools/call","params":{"name":"set_task","arguments":{"label":"task \#(i)"}}}"#).text
                }
            }
            for try await text in group { #expect(text == "ok") }
        }
        #expect(count == 25)
        #expect(server.isRunning)
    }

    // MARK: HTTP policy end to end

    @Test func bearerTokenIsEnforced() async throws {
        let (server, events) = makeServer()
        var seen = 0
        events.sheepSession.on { _ in seen += 1 }
        let port = try await server.start(port: 0, token: "s3cret")
        defer { server.stop() }
        let session = Self.makeSession()
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"session_begin","arguments":{}}}"#

        let none = try await http(session, port: port, body: call)
        #expect(none.status == 401)
        let wrong = try await http(session, port: port, body: call, token: "nope")
        #expect(wrong.status == 401)
        #expect(seen == 0)
        let right = try await http(session, port: port, body: call, token: "s3cret")
        #expect(right.status == 200)
        #expect(right.text == "ok")
        #expect(seen == 1)
    }

    @Test func getIs405AndUnknownPathIs404() async throws {
        let (server, _) = makeServer()
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }
        let session = Self.makeSession()

        let get = try await http(session, port: port, method: "GET")
        #expect(get.status == 405)
        #expect(get.headers["allow"] == "POST")
        let delete = try await http(session, port: port, method: "DELETE")
        #expect(delete.status == 405)
        let other = try await http(session, port: port, path: "/nope", body: "{}")
        #expect(other.status == 404)
    }

    @Test func nonJSONContentTypeIs415() async throws {
        let (server, _) = makeServer()
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }
        let reply = try await http(Self.makeSession(), port: port, body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
                                   extra: ["Content-Type": "text/plain"])
        #expect(reply.status == 415)
    }

    // MARK: raw framing

    @Test func responsesCloseTheConnectionWithContentLength() async throws {
        let (server, _) = makeServer()
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw = try await rawExchange(port: port, chunks: [(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)", 0)])
        // rawExchange only returns once the server closed the connection.
        #expect(raw.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(raw.contains("Connection: close\r\n"))
        #expect(raw.contains("Content-Type: application/json\r\n"))
        #expect(raw.hasSuffix(#"{"id":1,"jsonrpc":"2.0","result":{}}"#))
        #expect(raw.contains("Content-Length: 36\r\n"))
    }

    @Test func requestArrivingInPiecesIsReassembled() async throws {
        let (server, _) = makeServer()
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }
        let body = #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#
        let raw = try await rawExchange(port: port, chunks: [
            ("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: appli", 0),
            ("cation/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n", 100),
            (String(body.prefix(10)), 100),
            (String(body.dropFirst(10)), 100),
        ])
        #expect(raw.hasPrefix("HTTP/1.1 200 OK"))
        #expect(raw.hasSuffix(#"{"id":9,"jsonrpc":"2.0","result":{}}"#))
    }

    @Test func expectContinueGetsAnInterimResponse() async throws {
        let (server, _) = makeServer()
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }
        let body = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
        let raw = try await rawExchange(port: port, chunks: [
            ("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nExpect: 100-continue\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n", 0),
            (body, 150),
        ])
        #expect(raw.hasPrefix("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\n"))
    }

    @Test func garbageIs400() async throws {
        let (server, _) = makeServer()
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }
        let raw = try await rawExchange(port: port, chunks: [("this is not http\r\n\r\n", 0)])
        #expect(raw.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
    }

    @Test func oversizedBodyIs413() async throws {
        let (server, _) = makeServer()
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }
        let raw = try await rawExchange(port: port, chunks: [(
            "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 99999999\r\n\r\n", 0)])
        #expect(raw.hasPrefix("HTTP/1.1 413 "))
    }

    @Test func foreignHostHeaderIs403OverTheWire() async throws {
        let (server, events) = makeServer()
        var seen = 0
        events.sheepSession.on { _ in seen += 1 }
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"session_begin","arguments":{}}}"#
        let raw = try await rawExchange(port: port, chunks: [(
            "POST /mcp HTTP/1.1\r\nHost: evil.example:\(port)\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)", 0)])
        #expect(raw.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        #expect(seen == 0)
    }

    @Test func missingHostHeaderIs400OverTheWire() async throws {
        let (server, _) = makeServer()
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }
        let raw = try await rawExchange(port: port, chunks: [(
            "POST /mcp HTTP/1.0\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}", 0)])
        #expect(raw.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
    }

    // Socket work and JSON-RPC handling must not depend on the main thread; only
    // tools/call hops there. With the main thread blocked, a ping still completes.
    @Test func socketHandlingDoesNotNeedTheMainThread() async throws {
        let (server, _) = makeServer()
        let port = try await server.start(port: 0, token: "")
        defer { server.stop() }

        let answer = Mutex<String?>(nil)
        let exchange = Task { @concurrent in
            let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
            let raw = try await rawExchange(port: port, chunks: [(
                "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)", 0)])
            answer.withLock { $0 = raw }
        }

        Self.blockMainThread(for: 1.5)
        let answeredWhileBlocked = answer.withLock { $0 }
        #expect(answeredWhileBlocked?.hasPrefix("HTTP/1.1 200 OK") == true)
        try await exchange.value
    }

    private static func blockMainThread(for seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: lifecycle

    @Test func stopClosesTheListener() async throws {
        let (server, _) = makeServer()
        let port = try await server.start(port: 0, token: "")
        let session = Self.makeSession()
        let before = try await http(session, port: port, body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(before.status == 200)

        server.stop()
        #expect(!server.isRunning)
        #expect(server.port == nil)
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: (any Error).self) {
            _ = try await self.http(Self.makeSession(), port: port, body: #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        }
    }

    @Test func canRestartAfterStop() async throws {
        let (server, _) = makeServer()
        let first = try await server.start(port: 0, token: "")
        server.stop()
        let second = try await server.start(port: 0, token: "")
        defer { server.stop() }
        let reply = try await http(Self.makeSession(), port: second, body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(reply.status == 200)
        _ = first
    }

    @Test func startingTwiceThrows() async throws {
        let (server, _) = makeServer()
        _ = try await server.start(port: 0, token: "")
        defer { server.stop() }
        await #expect(throws: PlatformError.self) {
            _ = try await server.start(port: 0, token: "")
        }
        #expect(server.isRunning)
    }

    @Test func busyPortThrowsAndLeavesTheServerStopped() async throws {
        let (first, _) = makeServer()
        let port = try await first.start(port: 0, token: "")
        defer { first.stop() }

        let (second, _) = makeServer()
        await #expect(throws: (any Error).self) {
            _ = try await second.start(port: port, token: "")
        }
        #expect(!second.isRunning)
        #expect(second.port == nil)
    }
}

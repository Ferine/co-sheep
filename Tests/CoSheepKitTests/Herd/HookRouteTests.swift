import Foundation
import Testing
@testable import CoSheepKit

// `/hook` in front of the herd: same auth and Host checks as `/mcp`, POST + JSON
// only, 204 on success, 400 for anything that isn't a hook event.
@Suite("herd hook route")
struct HookRouteTests {
    private let payload = Data(#"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/work/app","tool_input":{"command":"ls"}}"#.utf8)

    private func request(
        method: String = "POST", target: String = "/hook", headers: [(String, String)]? = nil, body: Data? = nil
    ) -> HTTPRequest {
        let defaults = [("Host", "127.0.0.1:4917"), ("Content-Type", "application/json")]
        return HTTPRequest(
            method: method, target: target,
            headers: (headers ?? defaults).map { HTTPHeader(name: $0.0, value: $0.1) },
            body: body ?? payload)
    }

    private func endpoint(token: String = "", recorder: ActionRecorder = ActionRecorder()) -> MCPEndpoint {
        MCPEndpoint(token: token, perform: { recorder.record($0) })
    }

    private func hookEvents(_ recorder: ActionRecorder) -> [HookEvent] {
        recorder.actions.compactMap { if case .hook(let e) = $0 { e } else { nil } }
    }

    // MARK: happy path

    @Test func aHookEventIsAcceptedWith204AndHandedToTheHerd() async {
        let recorder = ActionRecorder()
        let response = await endpoint(recorder: recorder).handle(request())
        #expect(response.status == 204)
        #expect(response.body.isEmpty)
        let events = hookEvents(recorder)
        #expect(events.count == 1)
        #expect(events.first?.sessionId == "s1")
        #expect(events.first?.hookEventName == "PreToolUse")
        #expect(events.first?.toolName == "Bash")
        #expect(events.first?.cwd == "/work/app")
        #expect(events.first?.pid == nil)
    }

    @Test(arguments: ["/hook", "/hook/", "/hook?v=1", "/hook/?v=1"])
    func theRouteAcceptsTheTrailingSlashAndAQuery(target: String) async {
        let response = await endpoint().handle(request(target: target))
        #expect(response.status == 204, "\(target)")
    }

    @Test func thePidComesFromTheHeader() async {
        let recorder = ActionRecorder()
        let headers = [("Host", "localhost"), ("Content-Type", "application/json"), ("X-Co-Sheep-Pid", "31337")]
        _ = await endpoint(recorder: recorder).handle(request(headers: headers))
        #expect(hookEvents(recorder).first?.pid == 31337)
    }

    @Test func theHeaderNameIsCaseInsensitive() async {
        let recorder = ActionRecorder()
        let headers = [("Host", "localhost"), ("Content-Type", "application/json"), ("x-co-sheep-pid", "77")]
        _ = await endpoint(recorder: recorder).handle(request(headers: headers))
        #expect(hookEvents(recorder).first?.pid == 77)
    }

    @Test(arguments: ["abc", "", "0", "-5", "1.5", "99999999999", "12 34", "0x10"])
    func anUnusablePidHeaderMeansUnknown(value: String) async {
        let recorder = ActionRecorder()
        let headers = [("Host", "localhost"), ("Content-Type", "application/json"), ("X-Co-Sheep-Pid", value)]
        let response = await endpoint(recorder: recorder).handle(request(headers: headers))
        #expect(response.status == 204)
        #expect(hookEvents(recorder).first?.pid == nil, "\(value.debugDescription)")
    }

    @Test func aPaddedPidHeaderIsTrimmed() async {
        let recorder = ActionRecorder()
        let headers = [("Host", "localhost"), ("Content-Type", "application/json"), ("X-Co-Sheep-Pid", "  4242 ")]
        _ = await endpoint(recorder: recorder).handle(request(headers: headers))
        #expect(hookEvents(recorder).first?.pid == 4242)
    }

    @Test func contentTypeWithACharsetIsFine() async {
        let headers = [("Host", "localhost"), ("Content-Type", "application/json; charset=utf-8")]
        #expect(await endpoint().handle(request(headers: headers)).status == 204)
    }

    // MARK: bad bodies

    @Test func undecodableJSONIs400() async {
        let recorder = ActionRecorder()
        for body in ["{nope", "", "[]", "null", "42", #"{"hook_event_name":"Stop"}"#, #"{"session_id":"s"}"#, #"{"session_id":1,"hook_event_name":"Stop"}"#] {
            let response = await endpoint(recorder: recorder).handle(request(body: Data(body.utf8)))
            #expect(response.status == 400, "\(body.debugDescription)")
        }
        #expect(recorder.actions.isEmpty)
    }

    @Test func wrongTypedOptionalFieldsDoNotFailTheEvent() async {
        let recorder = ActionRecorder()
        let body = Data(#"{"session_id":"s","hook_event_name":"Stop","cwd":5,"is_interrupt":"x"}"#.utf8)
        let response = await endpoint(recorder: recorder).handle(request(body: body))
        #expect(response.status == 204)
        #expect(hookEvents(recorder).first?.cwd == nil)
    }

    @Test func aLargeToolOutputIsDecodedAndDropped() async {
        let recorder = ActionRecorder()
        let filler = String(repeating: "y", count: 5 * 1024 * 1024)
        let body = Data(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Read","tool_response":{"content":"\#(filler)"}}"#.utf8)
        let response = await endpoint(recorder: recorder).handle(request(body: body))
        #expect(response.status == 204)
        #expect(hookEvents(recorder).first?.toolName == "Read")
    }

    @Test func theMcpRouteKeepsItsOneMebibyteCap() async {
        let filler = String(repeating: "y", count: HTTPParser.maxBodyBytes)
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"pad":"\#(filler)"}}"#.utf8)
        let mcp = await endpoint().handle(request(target: "/mcp", body: body))
        #expect(mcp.status == 413)
        #expect(String(decoding: mcp.body, as: UTF8.self) == "Content Too Large")
        // the hook route takes the same size (the listener is what bounds it)
        let hook = await endpoint().handle(request(target: "/hook", body: Data(#"{"session_id":"s","hook_event_name":"Stop","pad":"\#(filler)"}"#.utf8)))
        #expect(hook.status == 204)
    }

    // MARK: policy shared with /mcp

    @Test func tokenIsEnforcedBeforeAnythingRuns() async {
        let recorder = ActionRecorder()
        let ep = endpoint(token: "s3cret", recorder: recorder)
        func with(_ authorization: String?) -> HTTPRequest {
            var h = [("Host", "localhost"), ("Content-Type", "application/json")]
            if let authorization { h.append(("Authorization", authorization)) }
            return request(headers: h)
        }
        #expect(await ep.handle(with(nil)).status == 401)
        #expect(await ep.handle(with("Bearer wrong")).status == 401)
        #expect(await ep.handle(with("Basic czNjcmV0")).status == 401)
        #expect(recorder.actions.isEmpty)
        #expect(await ep.handle(with("Bearer s3cret")).status == 204)
        #expect(hookEvents(recorder).count == 1)
    }

    @Test func tokenCheckAlsoWrapsUnknownHookPaths() async {
        let ep = endpoint(token: "s3cret")
        #expect(await ep.handle(request(target: "/hooks")).status == 401)
    }

    @Test(arguments: ["evil.com", "evil.com:4917", "localhost.evil.com", "127.0.0.2", "192.168.1.5"])
    func foreignHostsAreForbidden(host: String) async {
        let recorder = ActionRecorder()
        let response = await endpoint(recorder: recorder).handle(request(headers: [("Host", host), ("Content-Type", "application/json")]))
        #expect(response.status == 403, "\(host)")
        #expect(recorder.actions.isEmpty)
    }

    @Test func aMissingHostIs400() async {
        let response = await endpoint().handle(request(headers: [("Content-Type", "application/json")]))
        #expect(response.status == 400)
    }

    @Test(arguments: ["127.0.0.1", "127.0.0.1:4917", "localhost", "LOCALHOST:80", "[::1]:4917"])
    func loopbackHostsAreFine(host: String) async {
        let response = await endpoint().handle(request(headers: [("Host", host), ("Content-Type", "application/json")]))
        #expect(response.status == 204, "\(host)")
    }

    @Test func onlyPostIsAllowed() async {
        for method in ["GET", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"] {
            let response = await endpoint().handle(request(method: method))
            #expect(response.status == 405, "\(method)")
            #expect(response.headers.contains { $0.name == "Allow" && $0.value == "POST" })
        }
    }

    @Test func nonJSONContentTypeIs415() async {
        for type in ["text/plain", "application/x-www-form-urlencoded", "text/json"] {
            let response = await endpoint().handle(request(headers: [("Host", "localhost"), ("Content-Type", type)]))
            #expect(response.status == 415, "\(type)")
        }
        #expect(await endpoint().handle(request(headers: [("Host", "localhost")])).status == 415)
    }

    @Test func nearbyPathsAreNotHooks() async {
        for target in ["/hooks", "/hook/x", "/Hook", "/mcp/hook", "/hookz"] {
            let response = await endpoint().handle(request(target: target))
            #expect(response.status == 404, "\(target)")
        }
    }

    @Test func mcpIsUnaffected() async {
        let recorder = ActionRecorder()
        let ping = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let response = await endpoint(recorder: recorder).handle(request(target: "/mcp", body: ping))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self).contains(#""result":{}"#))
        #expect(recorder.actions.isEmpty)

        // a hook payload sent to /mcp is still just a malformed JSON-RPC message
        let wrongRoute = await endpoint(recorder: recorder).handle(request(target: "/mcp"))
        #expect(wrongRoute.status == 400)
        #expect(recorder.actions.isEmpty)

        // and the pid header means nothing there
        let withPid = await endpoint(recorder: recorder).handle(request(
            target: "/mcp", headers: [("Host", "localhost"), ("Content-Type", "application/json"), ("X-Co-Sheep-Pid", "5")], body: ping))
        #expect(withPid.status == 200)
    }

    // MARK: HTTP layer

    @Test func a204CarriesNoContentLength() {
        let wire = String(decoding: HTTPResponse(status: 204).serialized(), as: UTF8.self)
        #expect(wire == "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
        // other empty answers keep theirs
        let accepted = String(decoding: HTTPResponse(status: 202).serialized(), as: UTF8.self)
        #expect(accepted.contains("Content-Length: 0\r\n"))
    }

    @Test func theParserTakesAConfiguredBodyCap() {
        let limit = 16 * 1024 * 1024
        let head = "POST /hook HTTP/1.1\r\nContent-Length: \(limit)\r\n\r\n"
        #expect(HTTPParser.parse(Data(head.utf8), maxBodyBytes: limit) == .needMore(expectContinue: false))
        #expect(HTTPParser.parse(Data(head.utf8)) == .failure(status: 413, reason: "Content Too Large"))
        let over = "POST /hook HTTP/1.1\r\nContent-Length: \(limit + 1)\r\n\r\n"
        #expect(HTTPParser.parse(Data(over.utf8), maxBodyBytes: limit) == .failure(status: 413, reason: "Content Too Large"))
        #expect(MCPServer.maxBodyBytes == limit)
    }

    @Test func aBodyReceivedInPiecesIsParsedOnceItIsComplete() {
        let body = String(repeating: "z", count: 200_000)
        let whole = Data("POST /hook HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\nX-Co-Sheep-Pid: 9\r\n\r\n\(body)".utf8)
        var buffer = Data()
        var parsed: HTTPRequest?
        for start in stride(from: 0, to: whole.count, by: 65_536) {
            buffer.append(whole[start..<min(whole.count, start + 65_536)])
            if case .request(let r) = HTTPParser.parse(buffer, maxBodyBytes: MCPServer.maxBodyBytes) { parsed = r }
        }
        #expect(parsed?.body.count == 200_000)
        #expect(parsed?.header("x-co-sheep-pid") == "9")
        #expect(parsed?.path == "/hook")
    }
}

// MARK: - Over loopback

@Suite("herd hook route over loopback")
struct HookRouteLoopbackTests {
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }

    private struct Rig {
        let server: MCPServer
        let herd: HerdStore
        let events: AppEvents
    }

    private func makeRig() -> Rig {
        let events = AppEvents()
        let herd = HerdStore(events: events, findTerminal: { _ in nil }, findRepo: { ($0, "app") })
        return Rig(server: MCPServer(store: SessionStore(events: events), events: events, herd: herd), herd: herd, events: events)
    }

    private func post(
        _ session: URLSession, port: UInt16, path: String = "/hook", body: Data, token: String? = nil, pid: String? = nil
    ) async throws -> HTTPURLResponse {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let pid { request.setValue(pid, forHTTPHeaderField: "X-Co-Sheep-Pid") }
        let (_, response) = try await session.data(for: request)
        return response as! HTTPURLResponse
    }

    @Test func aHookReachesTheHerdStoreAndTheLambs() async throws {
        let rig = makeRig()
        var changes: [HerdChange] = []
        rig.events.herd.on { changes.append($0) }
        let port = try await rig.server.start(port: 0, token: "tok")
        defer { rig.server.stop() }
        let session = Self.makeSession()

        let start = Data(#"{"session_id":"abc","hook_event_name":"SessionStart","source":"startup","cwd":"/work/app","transcript_path":"/t/abc.jsonl"}"#.utf8)
        let first = try await post(session, port: port, body: start, token: "tok", pid: "4242")
        #expect(first.statusCode == 204)
        #expect(first.value(forHTTPHeaderField: "Content-Length") == nil)

        // answered only after the main-actor hop: the change is already out
        #expect(changes.count == 1)
        #expect(changes[0].beat == .arrived)
        #expect(changes[0].session.id == "abc")
        #expect(changes[0].session.agentPid == 4242)
        #expect(changes[0].session.repoName == "app")
        #expect(rig.herd.sessions.map(\.id) == ["abc"])

        let tool = Data(#"{"session_id":"abc","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/x"}}"#.utf8)
        #expect(try await post(session, port: port, body: tool, token: "tok").statusCode == 204)
        #expect(rig.herd.sessions.first?.phase == .working)
        #expect(rig.herd.sessions.first?.tool == .edit)
        #expect(rig.herd.sessions.first?.agentPid == 4242) // the header was only on the first call
    }

    @Test func badTokenAndBadBodiesChangeNothing() async throws {
        let rig = makeRig()
        let port = try await rig.server.start(port: 0, token: "tok")
        defer { rig.server.stop() }
        let session = Self.makeSession()
        let good = Data(#"{"session_id":"abc","hook_event_name":"Stop"}"#.utf8)

        #expect(try await post(session, port: port, body: good).statusCode == 401)
        #expect(try await post(session, port: port, body: good, token: "nope").statusCode == 401)
        #expect(try await post(session, port: port, body: Data("{bad".utf8), token: "tok").statusCode == 400)
        #expect(rig.herd.sessions.isEmpty)
    }

    @Test func aMultiMegabyteToolOutputIsAccepted() async throws {
        let rig = makeRig()
        let port = try await rig.server.start(port: 0, token: "")
        defer { rig.server.stop() }
        let filler = String(repeating: "q", count: 9 * 1024 * 1024)
        let body = Data(#"{"session_id":"big","hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"\#(filler)"}}"#.utf8)
        #expect(body.count > HTTPParser.maxBodyBytes)

        let response = try await post(Self.makeSession(), port: port, body: body)
        #expect(response.statusCode == 204)
        #expect(rig.herd.sessions.map(\.id) == ["big"])
        #expect(rig.herd.sessions.first?.tool == .bash)
    }

    @Test func mcpStillAnswersOnTheSameListener() async throws {
        let rig = makeRig()
        var sessionEvents: [SessionEvent] = []
        rig.events.sheepSession.on { sessionEvents.append($0) }
        let port = try await rig.server.start(port: 0, token: "")
        defer { rig.server.stop() }
        let session = Self.makeSession()

        let begin = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"session_begin","arguments":{"task":"x"}}}"#.utf8)
        #expect(try await post(session, port: port, path: "/mcp", body: begin).statusCode == 200)
        #expect(sessionEvents.map(\.kind) == ["begin"])
        #expect(rig.herd.sessions.isEmpty)

        // a megabyte-and-a-bit JSON-RPC body is still too large for /mcp
        let filler = String(repeating: "q", count: 2 * 1024 * 1024)
        let big = Data(#"{"jsonrpc":"2.0","id":2,"method":"ping","params":{"pad":"\#(filler)"}}"#.utf8)
        #expect(try await post(session, port: port, path: "/mcp", body: big).statusCode == 413)
    }
}

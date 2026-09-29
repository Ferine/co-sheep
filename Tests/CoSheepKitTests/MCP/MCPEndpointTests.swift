import Foundation
import Testing
@testable import CoSheepKit

/// The HTTP policy in front of the JSON-RPC handler, with no sockets:
/// auth, routing, Host validation, method and content-type checks.
@Suite("mcp http policy")
struct MCPEndpointTests {
    private let ping = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)

    private func request(
        method: String = "POST",
        target: String = "/mcp",
        headers: [(String, String)]? = nil,
        body: Data? = nil
    ) -> HTTPRequest {
        let defaults = [("Host", "127.0.0.1:4917"), ("Content-Type", "application/json"),
                        ("Accept", "application/json, text/event-stream")]
        return HTTPRequest(
            method: method, target: target,
            headers: (headers ?? defaults).map { HTTPHeader(name: $0.0, value: $0.1) },
            body: body ?? ping)
    }

    private func endpoint(token: String = "", recorder: ActionRecorder = ActionRecorder()) -> MCPEndpoint {
        MCPEndpoint(token: token, perform: { recorder.record($0) })
    }

    // MARK: happy path

    @Test func postToMcpIsHandled() async {
        let response = await endpoint().handle(request())
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self).contains(#""result":{}"#))
    }

    @Test func trailingSlashAndQueryStringStillRoute() async {
        let slash = await endpoint().handle(request(target: "/mcp/"))
        #expect(slash.status == 200)
        let query = await endpoint().handle(request(target: "/mcp?session=1"))
        #expect(query.status == 200)
    }

    @Test func acceptHeaderIsNotRequired() async {
        // rmcp answered 406 without both media types; JSON-response mode has no
        // reason to insist.
        let response = await endpoint().handle(request(headers: [("Host", "localhost"), ("Content-Type", "application/json")]))
        #expect(response.status == 200)
    }

    @Test func contentTypeWithCharsetIsFine() async {
        let response = await endpoint().handle(request(headers: [
            ("Host", "localhost"), ("Content-Type", "Application/JSON; charset=utf-8")]))
        #expect(response.status == 200)
    }

    // MARK: routing and methods

    @Test func unknownPathsAre404() async {
        for target in ["/", "/mcpx", "/other", "/mcp2/x", "/api/mcp"] {
            let response = await endpoint().handle(request(target: target))
            #expect(response.status == 404, "\(target)")
        }
    }

    @Test func getIs405WithAllowPost() async {
        let response = await endpoint().handle(request(method: "GET", body: Data()))
        #expect(response.status == 405)
        #expect(response.headers.contains { $0.name == "Allow" && $0.value == "POST" })
    }

    @Test func otherMethodsAre405() async {
        for method in ["DELETE", "PUT", "PATCH", "OPTIONS", "HEAD"] {
            let response = await endpoint().handle(request(method: method))
            #expect(response.status == 405, "\(method)")
        }
    }

    @Test func nonJSONContentTypeIs415() async {
        for type in ["text/plain", "application/x-www-form-urlencoded", "text/json"] {
            let response = await endpoint().handle(request(headers: [("Host", "localhost"), ("Content-Type", type)]))
            #expect(response.status == 415, "\(type)")
        }
        let missing = await endpoint().handle(request(headers: [("Host", "localhost")]))
        #expect(missing.status == 415)
    }

    // MARK: bearer token

    @Test func noTokenConfiguredAcceptsAnything() async {
        let open = await endpoint(token: "").handle(request(headers: [
            ("Host", "localhost"), ("Content-Type", "application/json"), ("Authorization", "Bearer whatever")]))
        #expect(open.status == 200)
    }

    @Test func tokenIsEnforced() async {
        let ep = endpoint(token: "s3cret")
        func with(_ authorization: String?) -> HTTPRequest {
            var h = [("Host", "localhost"), ("Content-Type", "application/json")]
            if let authorization { h.append(("Authorization", authorization)) }
            return request(headers: h)
        }
        let missing = await ep.handle(with(nil))
        #expect(missing.status == 401)
        #expect(missing.body.isEmpty)
        // No WWW-Authenticate: it could send OAuth-aware clients down a discovery flow.
        #expect(!missing.headers.contains { $0.name.lowercased() == "www-authenticate" })
        let wrong = await ep.handle(with("Bearer wrong"))
        #expect(wrong.status == 401)
        let basic = await ep.handle(with("Basic czNjcmV0"))
        #expect(basic.status == 401)
        let right = await ep.handle(with("Bearer s3cret"))
        #expect(right.status == 200)
    }

    @Test func tokenIsCheckedBeforeRouting() async {
        // Like the axum layer: the auth middleware wraps every route, 404s included.
        let ep = endpoint(token: "s3cret")
        let unauthorizedElsewhere = await ep.handle(request(target: "/nope"))
        #expect(unauthorizedElsewhere.status == 401)
        let unauthorizedGet = await ep.handle(request(method: "GET"))
        #expect(unauthorizedGet.status == 401)
        var authed = request(target: "/nope")
        authed.headers.append(HTTPHeader(name: "Authorization", value: "Bearer s3cret"))
        let notFound = await ep.handle(authed)
        #expect(notFound.status == 404)
    }

    @Test func unauthorizedCallsNeverRunTools() async {
        let recorder = ActionRecorder()
        let ep = endpoint(token: "s3cret", recorder: recorder)
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_task","arguments":{"label":"x"}}}"#.utf8)
        _ = await ep.handle(request(body: body))
        #expect(recorder.actions.isEmpty)
    }

    // MARK: Host header (rmcp's DNS-rebinding guard)

    @Test(arguments: ["127.0.0.1", "127.0.0.1:4917", "localhost", "localhost:4917", "LOCALHOST:80",
                      "[::1]", "[::1]:4917", "127.0.0.1:1"])
    func loopbackHostsAreAllowed(host: String) async {
        let response = await endpoint().handle(request(headers: [("Host", host), ("Content-Type", "application/json")]))
        #expect(response.status == 200, "\(host)")
    }

    @Test(arguments: ["evil.com", "evil.com:4917", "localhost.evil.com", "127.0.0.2", "0.0.0.0:4917",
                      "192.168.1.5", "[::2]", "example.org"])
    func otherHostsAreForbidden(host: String) async {
        let response = await endpoint().handle(request(headers: [("Host", host), ("Content-Type", "application/json")]))
        #expect(response.status == 403, "\(host)")
        #expect(String(decoding: response.body, as: UTF8.self) == "Forbidden: Host header is not allowed")
    }

    @Test func missingHostIs400() async {
        let response = await endpoint().handle(request(headers: [("Content-Type", "application/json")]))
        #expect(response.status == 400)
        #expect(String(decoding: response.body, as: UTF8.self) == "Bad Request: missing Host header")
    }

    @Test(arguments: ["", "  ", "local host", "localhost:", "localhost:abc", "localhost:99999",
                      "user@localhost", "[::1", "[::1]x", "::1", "a:b:c", "localhost/x"])
    func malformedHostIs400(host: String) async {
        let response = await endpoint().handle(request(headers: [("Host", host), ("Content-Type", "application/json")]))
        #expect(response.status == 400, "\(host.debugDescription)")
    }

    @Test func hostIsCheckedBeforeMethodAndBody() async {
        let response = await endpoint().handle(request(method: "GET", headers: [("Host", "evil.com")]))
        #expect(response.status == 403)
    }

    @Test func parseHostNormalisesCaseAndBrackets() {
        #expect(MCPEndpoint.parseHost("LocalHost:4917") == "localhost")
        #expect(MCPEndpoint.parseHost("[::1]:4917") == "::1")
        #expect(MCPEndpoint.parseHost("[::1]") == "::1")
        #expect(MCPEndpoint.parseHost("127.0.0.1") == "127.0.0.1")
        #expect(MCPEndpoint.parseHost(" localhost ") == "localhost")
        #expect(MCPEndpoint.parseHost("localhost:65535") == "localhost")
        #expect(MCPEndpoint.parseHost("localhost:65536") == nil)
        #expect(MCPEndpoint.parseHost("") == nil)
    }
}

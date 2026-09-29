import Foundation

// Ex-mcp.rs, the protocol half: the co-sheep MCP companion server. Fact-shaped
// tools drive the sheep. Streamable HTTP in JSON-response mode: every POST is
// answered with `application/json` (the spec allows this instead of an SSE
// stream), there are no sessions, and GET has nothing to stream (405). This is
// a deliberate simplification: the Rust server used rmcp's defaults (stateful,
// SSE); JSON mode is all a facts-in tool server needs and clients accept it.

/// What a `tools/call` resolved to. Applied on the main actor.
nonisolated enum MCPAction: Equatable {
    case fact(Fact)
    /// The `say` escape hatch: an exact line, optionally with an animation name.
    case say(text: String, animation: String?)
}

// MARK: - Tool catalogue

/// One tool argument, described the way schemars derives it from the Rust
/// `*Args` structs (doc-comment descriptions, `Option<_>` = not required).
nonisolated struct MCPToolArg {
    enum Kind {
        case string
        /// Rust `f32`.
        case float
    }

    var name: String
    var description: String
    var kind: Kind
    var required: Bool

    /// schemars 1.x, draft 2020-12: `Option<String>` is `["string","null"]`,
    /// `f32` is a `number` with `"format": "float"`.
    var schema: JSONValue {
        var s: [String: JSONValue] = ["description": .string(description)]
        switch kind {
        case .string:
            s["type"] = required ? .string("string") : .array([.string("string"), .string("null")])
        case .float:
            s["type"] = .string("number")
            s["format"] = .string("float")
        }
        return .object(s)
    }
}

nonisolated struct MCPToolSpec {
    var name: String
    var description: String
    var args: [MCPToolArg]

    /// What rmcp put in `inputSchema`: the derived schema without the wrapper
    /// type's title/description. `required` is omitted when empty.
    var inputSchema: JSONValue {
        var props: [String: JSONValue] = [:]
        for a in args { props[a.name] = a.schema }
        var schema: [String: JSONValue] = [
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "type": .string("object"),
            "properties": .object(props),
        ]
        let required = args.filter(\.required).map { JSONValue.string($0.name) }
        if !required.isEmpty { schema["required"] = .array(required) }
        return .object(schema)
    }

    var listEntry: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }

    /// serde's view of the `*Args` struct: nil when `arguments` deserialize,
    /// else the error text serde_json would have produced.
    func validationError(for arguments: [String: JSONValue]) -> String? {
        for arg in args {
            guard let value = arguments[arg.name] else {
                if arg.required { return "missing field `\(arg.name)`" }
                continue
            }
            if case .null = value {
                if arg.required { return "invalid type: null, expected \(arg.kind.expected)" }
                continue
            }
            switch (arg.kind, value) {
            case (.string, .string), (.float, .number):
                break
            default:
                return "invalid type: \(Self.unexpected(value)), expected \(arg.kind.expected)"
            }
        }
        return nil
    }

    /// Only call after `validationError` returned nil.
    func action(from arguments: [String: JSONValue]) -> MCPAction {
        func string(_ key: String) -> String? { arguments[key]?.stringValue }
        switch name {
        case "session_begin":
            return .fact(.begin(task: string("task")))
        case "set_task":
            return .fact(.task(label: string("label") ?? ""))
        case "progress":
            return .fact(.progress(fraction: arguments["fraction"]?.doubleValue ?? 0))
        case "milestone":
            return .fact(.milestone(kind: string("kind") ?? "", detail: string("detail")))
        case "say":
            return .say(text: SessionReducer.truncate(string("text") ?? "", 500), animation: string("animation"))
        default: // session_end
            return .fact(.end(summary: string("summary")))
        }
    }

    /// serde_json's `Unexpected` wording.
    private static func unexpected(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let b): "boolean `\(b)`"
        case .number(let n):
            n.rounded() == n && abs(n) < 9.0e15 ? "integer `\(Int64(n))`" : "floating point `\(n)`"
        case .string(let s): "string \"\(s)\""
        case .array: "sequence"
        case .object: "map"
        }
    }
}

private nonisolated extension MCPToolArg.Kind {
    var expected: String {
        switch self {
        case .string: "a string"
        case .float: "f32"
        }
    }
}

// MARK: - JSON-RPC

nonisolated enum MCPProtocol {
    static let serverName = "co-sheep"
    /// ex-`env!("CARGO_PKG_VERSION")`; matches `VERSION` in scripts/bundle.sh.
    static let serverVersion = "0.1.0"

    /// Protocol versions this server implements. An `initialize` naming one of
    /// them is echoed back; anything else gets `latestProtocolVersion`.
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    static let latestProtocolVersion = "2025-11-25"

    static func negotiate(_ requested: String) -> String {
        supportedProtocolVersions.contains(requested) ? requested : latestProtocolVersion
    }

    /// ex-`get_info().instructions`, verbatim.
    static let instructions = """
        co-sheep is the human's desktop companion: a pixel sheep that narrates \
        YOUR work to them on their screen. Call these tools as you work so the \
        human can follow along without watching your output -- and, above all, \
        so you can pull their attention back when you need it.

        Suggested flow: `session_begin` when you start a task; `set_task` when \
        you switch focus; `progress` now and then during long work; `milestone` \
        the instant something notable happens; `session_end` when you finish.

        The attention-grabbers are `milestone` with kind `blocked` or \
        `waiting_on_you` -- call them the moment you are stuck or need a \
        decision, because the human is usually looking away and the sheep will \
        visibly nudge them back to the screen. Report plain facts (what \
        happened, a short `detail`); the sheep writes its own snark, so do not \
        pre-format jokes. Use `say` only to force an exact line.
        """

    /// The six tools, in the order rmcp lists them (sorted by name). Descriptions
    /// are the Rust `#[tool(description = …)]` and `#[schemars(description = …)]`
    /// strings verbatim.
    static let tools: [MCPToolSpec] = [
        MCPToolSpec(
            name: "milestone",
            description: """
                Call the moment something notable happens. Use kind `blocked` or \
                `waiting_on_you` WHENEVER YOU NEED THE HUMAN'S ATTENTION (you are stuck, or need a \
                decision or input) -- the sheep visibly nudges them back to the screen. Use `done` \
                when the task succeeds and `failed` when something breaks. Put specifics in \
                `detail` (e.g. '3 tests failing', 'need the API key').
                """,
            args: [
                MCPToolArg(
                    name: "kind",
                    description: """
                        done = task succeeded; failed = something broke; \
                        blocked = you are stuck and cannot proceed; waiting_on_you = you need the human's \
                        input to continue. Use blocked or waiting_on_you to grab the human's attention.
                        """,
                    kind: .string, required: true),
                MCPToolArg(
                    name: "detail",
                    description: """
                        Short factual detail, e.g. '3 tests failed' or 'need the \
                        API key' -- the sheep works this into its line.
                        """,
                    kind: .string, required: false),
            ]),
        MCPToolSpec(
            name: "progress",
            description: """
                Call every so often during longer work to report how far along \
                you are (0.0 to 1.0), so the human can tell at a glance whether to keep waiting or \
                step away.
                """,
            args: [
                MCPToolArg(
                    name: "fraction", description: "Progress fraction 0.0..1.0",
                    kind: .float, required: true),
            ]),
        MCPToolSpec(
            name: "say",
            description: """
                Escape hatch: make the sheep say an EXACT line you provide. \
                Prefer the fact tools above (milestone/progress/set_task) -- the sheep phrases \
                those in its own voice; use `say` only for a specific verbatim message. Optional \
                `animation`: bounce|spin|backflip|headshake|zoom|vibrate.
                """,
            args: [
                MCPToolArg(
                    name: "text", description: "The exact line for the sheep to say",
                    kind: .string, required: true),
                MCPToolArg(
                    name: "animation",
                    description: "Optional animation: bounce|spin|backflip|headshake|zoom|vibrate",
                    kind: .string, required: false),
            ]),
        MCPToolSpec(
            name: "session_begin",
            description: """
                Call at the START of a task, before you begin the work: the \
                sheep clocks in so the human knows you are now on the job. Optional `task` labels \
                what you are starting.
                """,
            args: [
                MCPToolArg(
                    name: "task", description: "Optional label for the task you're starting",
                    kind: .string, required: false),
            ]),
        MCPToolSpec(
            name: "session_end",
            description: """
                Call when the task is fully finished, so the sheep clocks out. \
                Optional `summary` of what got done.
                """,
            args: [
                MCPToolArg(
                    name: "summary", description: "Optional closing summary",
                    kind: .string, required: false),
            ]),
        MCPToolSpec(
            name: "set_task",
            description: """
                Call when you switch to a new sub-task or focus, so the sheep \
                announces on-screen what you are now working on. Keep `label` to a few words.
                """,
            args: [
                MCPToolArg(
                    name: "label", description: "Short label of the current task",
                    kind: .string, required: true),
            ]),
    ]

    static var toolsListResult: JSONValue {
        .object(["tools": .array(tools.map(\.listEntry))])
    }

    static func initializeResult(requestedVersion: String) -> JSONValue {
        .object([
            "protocolVersion": .string(negotiate(requestedVersion)),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string(serverName),
                "version": .string(serverVersion),
            ]),
            "instructions": .string(instructions),
        ])
    }

    // MARK: Dispatch

    /// Handle one POST body. `protocolVersionHeader` is the `MCP-Protocol-Version`
    /// request header. `perform` applies a resolved tool call (it hops to the
    /// main actor); it runs before the "ok" result is returned.
    ///
    /// - Parse error: HTTP 400, JSON-RPC -32700. Not a JSON-RPC message: 400, -32600.
    /// - Notifications and client responses: HTTP 202, no body.
    /// - Unknown method: -32601. Malformed params, unknown tool: -32602.
    /// - Arguments that do not fit a tool's schema come back as a tool result with
    ///   `isError: true` (what rmcp answers), not as a JSON-RPC error.
    static func handle(
        body: Data,
        protocolVersionHeader: String? = nil,
        perform: @Sendable (MCPAction) async -> Void
    ) async -> HTTPResponse {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return errorResponse(id: .null, code: -32700, message: "Parse error", status: 400)
        }
        guard case .object(let object) = message, object["jsonrpc"]?.stringValue == "2.0" else {
            return errorResponse(id: .null, code: -32600, message: "Invalid Request", status: 400)
        }

        let idValue = object["id"]
        let hasID: Bool
        switch idValue {
        case nil, .null?: hasID = false
        case .string?, .number?: hasID = true
        default:
            return errorResponse(id: .null, code: -32600, message: "Invalid Request", status: 400)
        }
        let id = hasID ? idValue! : JSONValue.null

        guard let method = object["method"]?.stringValue else {
            // A response or error from the client to a server request: nothing to do.
            if hasID, object["result"] != nil || object["error"] != nil {
                return protocolHeaderRejection(protocolVersionHeader) ?? .init(status: 202)
            }
            return errorResponse(id: id, code: -32600, message: "Invalid Request", status: 400)
        }
        let params = object["params"]

        // MCP-Protocol-Version: on initialize it must agree with the body; on
        // everything else it must name a version we know (absent is fine).
        if let header = protocolVersionHeader {
            if hasID, method == "initialize" {
                if let requested = params?["protocolVersion"]?.stringValue, requested != header {
                    return errorResponse(
                        id: id, code: -32600,
                        message: "Invalid Request: MCP-Protocol-Version header (\(header)) does not match "
                            + "initialize params.protocolVersion (\(requested))",
                        status: 400)
                }
            } else if let rejection = protocolHeaderRejection(header) {
                return rejection
            }
        }

        guard hasID else {
            return .init(status: 202) // notifications/* (and any other notification)
        }

        switch method {
        case "initialize":
            guard case .object? = params, let requested = params?["protocolVersion"]?.stringValue else {
                return errorResponse(id: id, code: -32602, message: "Invalid params: missing field `protocolVersion`")
            }
            return resultResponse(id: id, result: initializeResult(requestedVersion: requested))
        case "ping":
            return resultResponse(id: id, result: .object([:]))
        case "tools/list":
            return resultResponse(id: id, result: toolsListResult)
        case "tools/call":
            return await callTool(id: id, params: params, perform: perform)
        // rmcp answers these with empty lists even though only tools are advertised.
        case "resources/list":
            return resultResponse(id: id, result: .object(["resources": .array([])]))
        case "resources/templates/list":
            return resultResponse(id: id, result: .object(["resourceTemplates": .array([])]))
        case "prompts/list":
            return resultResponse(id: id, result: .object(["prompts": .array([])]))
        default:
            return errorResponse(id: id, code: -32601, message: method)
        }
    }

    private static func callTool(
        id: JSONValue,
        params: JSONValue?,
        perform: @Sendable (MCPAction) async -> Void
    ) async -> HTTPResponse {
        guard case .object(let p)? = params, let name = p["name"]?.stringValue else {
            return errorResponse(id: id, code: -32602, message: "Invalid params: missing field `name`")
        }
        guard let tool = tools.first(where: { $0.name == name }) else {
            return errorResponse(id: id, code: -32602, message: "tool not found")
        }
        let arguments: [String: JSONValue]
        switch p["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let o)?: arguments = o
        default:
            return errorResponse(id: id, code: -32602, message: "Invalid params: `arguments` must be an object")
        }
        if let problem = tool.validationError(for: arguments) {
            return resultResponse(
                id: id, result: toolResult(text: "failed to deserialize parameters: \(problem)", isError: true))
        }
        Log.debug("mcp", "tools/call \(name)")
        await perform(tool.action(from: arguments))
        return resultResponse(id: id, result: toolResult(text: "ok", isError: false))
    }

    /// ex-`ok()` / `CallToolResult::success`.
    private static func toolResult(text: String, isError: Bool) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }

    private static func protocolHeaderRejection(_ header: String?) -> HTTPResponse? {
        guard let header, !supportedProtocolVersions.contains(header) else { return nil }
        return .text(400, "Bad Request: Unsupported MCP-Protocol-Version: \(header)")
    }

    // MARK: Responses

    static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    static func resultResponse(id: JSONValue, result: JSONValue) -> HTTPResponse {
        .json(200, encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": result])))
    }

    static func errorResponse(id: JSONValue, code: Int, message: String, status: Int = 200) -> HTTPResponse {
        .json(status, encode(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ])))
    }
}

// MARK: - HTTP layer

/// The HTTP-level policy in front of the JSON-RPC handler. Order matches the
/// Rust stack: the bearer-token layer wraps everything (so a missing token is
/// 401 even for unknown paths), then routing (`/mcp`), then rmcp's own checks:
/// Host, method, content type. There is no Origin check (rmcp's
/// `allowed_origins` was left empty).
nonisolated struct MCPEndpoint: Sendable {
    /// Empty: no token configured, the loopback binding is the only control.
    var token: String
    var perform: @Sendable (MCPAction) async -> Void

    /// rmcp's default `allowed_hosts`. Any port is fine.
    static let allowedHosts = ["localhost", "127.0.0.1", "::1"]

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard SessionReducer.checkAuth(request.header("authorization"), expected: token) else {
            return HTTPResponse(status: 401)
        }

        guard request.path == "/mcp" || request.path == "/mcp/" else {
            return HTTPResponse(status: 404)
        }

        // Guards against DNS rebinding: a browser page can reach 127.0.0.1 through
        // a hostname it controls, but it cannot make the Host header say localhost.
        if let rejection = Self.validateHost(request.header("host")) {
            return rejection
        }

        guard request.method == "POST" else {
            var response = HTTPResponse.text(405, "Method Not Allowed")
            response.headers.append(HTTPHeader(name: "Allow", value: "POST"))
            return response
        }

        guard request.header("content-type")?.lowercased().hasPrefix("application/json") == true else {
            return .text(415, "Unsupported Media Type: Content-Type must be application/json")
        }

        return await MCPProtocol.handle(
            body: request.body,
            protocolVersionHeader: request.header("mcp-protocol-version"),
            perform: perform)
    }

    /// nil when the Host header is acceptable, else the rejection (400 for a
    /// missing or malformed header, 403 for a host that is not loopback).
    static func validateHost(_ header: String?) -> HTTPResponse? {
        guard let header else { return .text(400, "Bad Request: missing Host header") }
        guard let host = parseHost(header) else { return .text(400, "Bad Request: Invalid Host header") }
        guard allowedHosts.contains(host) else { return .text(403, "Forbidden: Host header is not allowed") }
        return nil
    }

    /// The lowercased host of a `Host` header (`host`, `host:port`, `[v6]`,
    /// `[v6]:port`), or nil when it is not a valid authority.
    static func parseHost(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !v.isEmpty, !v.contains("@"), !v.contains("/"),
              !v.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7f })
        else { return nil }

        let host: Substring
        let portPart: Substring?
        if v.hasPrefix("[") {
            guard let close = v.firstIndex(of: "]") else { return nil }
            host = v[v.index(after: v.startIndex)..<close]
            let rest = v[v.index(after: close)...]
            if rest.isEmpty {
                portPart = nil
            } else if rest.hasPrefix(":") {
                portPart = rest.dropFirst()
            } else {
                return nil
            }
        } else {
            let pieces = v.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            host = pieces[0]
            portPart = pieces.count == 2 ? pieces[1] : nil
            if host.contains(":") { return nil }
        }
        guard !host.isEmpty else { return nil }
        if let portPart {
            guard !portPart.isEmpty, portPart.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let port = Int(portPart), port <= 65535
            else { return nil }
        }
        return host.lowercased()
    }
}

// MARK: - Server

/// Owns the listener. `start`/`stop` and every resolved tool call run on the
/// main actor; socket work and JSON-RPC handling stay off it and only hop here
/// to touch `SessionStore` and `AppEvents`.
final class MCPServer {
    static let shared = MCPServer()

    private let store: SessionStore
    private let events: AppEvents
    private var http: HTTPServer?

    /// The bound port while running.
    private(set) var port: UInt16?

    var isRunning: Bool { port != nil }

    init(store: SessionStore = .shared, events: AppEvents = .shared) {
        self.store = store
        self.events = events
    }

    /// ex-`serve`: listens on 127.0.0.1:`port` (0 picks a free port) and returns
    /// the bound port once ready. An empty `token` accepts every request. Throws
    /// when the port cannot be bound; the caller logs
    /// `error: server disabled: …` like lib.rs did.
    @discardableResult
    func start(port: UInt16, token: String) async throws -> UInt16 {
        guard http == nil else { throw PlatformError("MCP server is already running") }

        let endpoint = MCPEndpoint(token: token) { [weak self] action in
            await self?.perform(action)
        }
        let server = HTTPServer { request in
            await endpoint.handle(request)
        }
        http = server // claimed before the first suspension, so a second start is refused
        do {
            let bound = try await server.start(port: port)
            guard http === server else {
                server.stop() // stop() ran while the listener was starting
                throw PlatformError("MCP server was stopped while starting")
            }
            self.port = bound
            Log.info("mcp", "server ready at http://127.0.0.1:\(bound)/mcp")
            return bound
        } catch {
            if http === server { http = nil }
            throw error
        }
    }

    func stop() {
        http?.stop()
        http = nil
        port = nil
    }

    /// Applies a resolved tool call: facts go through the session store (which
    /// emits `sheep-session`), `say` emits `sheep-commentary` directly.
    func perform(_ action: MCPAction) {
        switch action {
        case .fact(let fact):
            store.commit(fact)
        case .say(let text, let animation):
            // The overlay only knows the six animations; an unknown name just
            // means no animation, the line is still shown.
            events.sheepCommentary.emit(CommentaryEvent(
                text: text, animation: animation.flatMap(SheepAnimation.init(rawValue:))))
        }
    }
}

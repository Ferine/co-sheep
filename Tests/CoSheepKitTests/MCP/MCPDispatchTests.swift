import Foundation
import Synchronization
import Testing
@testable import CoSheepKit

/// Collects what `tools/call` resolved to, from whichever thread the server used.
nonisolated final class ActionRecorder: Sendable {
    private let store = Mutex<[MCPAction]>([])
    func record(_ action: MCPAction) { store.withLock { $0.append(action) } }
    var actions: [MCPAction] { store.withLock { $0 } }
}

/// JSON-RPC dispatch with no sockets: `MCPProtocol.handle` and `MCPEndpoint.handle`.
@Suite("mcp json-rpc dispatch")
struct MCPDispatchTests {
    private struct Reply {
        var response: HTTPResponse
        var json: JSONValue?
        var result: JSONValue? { json?["result"] }
        var error: JSONValue? { json?["error"] }
        var errorCode: Double? { error?["code"]?.doubleValue }
        var text: String? { result?["content"]?.arrayValue?.first?["text"]?.stringValue }
    }

    private func send(
        _ body: String, header: String? = nil, recorder: ActionRecorder = ActionRecorder()
    ) async -> Reply {
        let response = await MCPProtocol.handle(
            body: Data(body.utf8), protocolVersionHeader: header, perform: { recorder.record($0) })
        let json = response.body.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: response.body)
        return Reply(response: response, json: json)
    }

    private func call(_ name: String, _ arguments: String, recorder: ActionRecorder = ActionRecorder()) async -> Reply {
        await send(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#,
            recorder: recorder)
    }

    private func decode(_ s: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    // MARK: initialize

    @Test func initializeMatchesTheRustServerVerbatim() async throws {
        let reply = await send(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        #expect(reply.response.status == 200)
        #expect(reply.response.headers.contains { $0.name == "Content-Type" && $0.value == "application/json" })
        #expect(reply.result == (try decode(RmcpFixtures.initializeResult)))
        #expect(reply.json?["id"] == .number(1))
        #expect(reply.json?["jsonrpc"] == .string("2.0"))
    }

    @Test(arguments: ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"])
    func initializeEchoesSupportedVersions(version: String) async {
        let reply = await send(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)"}}"#)
        #expect(reply.result?["protocolVersion"]?.stringValue == version)
    }

    @Test(arguments: ["2099-01-01", "1999-12-31", "latest", ""])
    func initializeFallsBackToLatestForUnknownVersions(version: String) async {
        let reply = await send(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)"}}"#)
        #expect(reply.result?["protocolVersion"]?.stringValue == MCPProtocol.latestProtocolVersion)
    }

    @Test func initializeAdvertisesOnlyTools() async {
        let reply = await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        #expect(reply.result?["capabilities"] == .object(["tools": .object([:])]))
        #expect(reply.result?["serverInfo"]?["name"]?.stringValue == "co-sheep")
    }

    @Test func initializeWithoutProtocolVersionIsInvalidParams() async {
        let reply = await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        #expect(reply.errorCode == -32602)
        let noParams = await send(#"{"jsonrpc":"2.0","id":2,"method":"initialize"}"#)
        #expect(noParams.errorCode == -32602)
    }

    // MARK: tools/list

    @Test func toolsListMatchesTheRustServerVerbatim() async throws {
        let reply = await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(reply.result == (try decode(RmcpFixtures.toolsListResult)))
    }

    @Test func toolsListNamesAndRequiredFields() async {
        let reply = await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = reply.result?["tools"]?.arrayValue ?? []
        #expect(tools.compactMap { $0["name"]?.stringValue }
            == ["milestone", "progress", "say", "session_begin", "session_end", "set_task"])
        let required = Dictionary(uniqueKeysWithValues: tools.map {
            ($0["name"]?.stringValue ?? "", $0["inputSchema"]?["required"]?.arrayValue?.compactMap(\.stringValue))
        })
        #expect(required["milestone"] == ["kind"])
        #expect(required["progress"] == ["fraction"])
        #expect(required["say"] == ["text"])
        #expect(required["set_task"] == ["label"])
        #expect(required["session_begin"] == .some(nil))
        #expect(required["session_end"] == .some(nil))
    }

    @Test func everyToolSchemaIsAnObjectWithDescribedProperties() {
        for tool in MCPProtocol.tools {
            let schema = tool.inputSchema
            #expect(schema["type"]?.stringValue == "object")
            #expect(schema["$schema"]?.stringValue == "https://json-schema.org/draft/2020-12/schema")
            for arg in tool.args {
                #expect(schema["properties"]?[arg.name]?["description"]?.stringValue == arg.description)
            }
        }
    }

    // MARK: tools/call

    @Test func everyToolCallReturnsOkAndResolvesToItsAction() async {
        let recorder = ActionRecorder()
        let calls: [(String, String)] = [
            ("session_begin", #"{"task":"wire mpls"}"#),
            ("set_task", #"{"label":"tests"}"#),
            ("progress", #"{"fraction":0.5}"#),
            ("milestone", #"{"kind":"blocked","detail":"need the API key"}"#),
            ("say", #"{"text":"Baaa","animation":"spin"}"#),
            ("session_end", #"{"summary":"done"}"#),
        ]
        for (name, args) in calls {
            let reply = await call(name, args, recorder: recorder)
            #expect(reply.response.status == 200, "\(name)")
            #expect(reply.text == "ok", "\(name)")
            #expect(reply.result?["isError"] == .bool(false), "\(name)")
            #expect(reply.result?["content"]?.arrayValue?.first?["type"]?.stringValue == "text")
        }
        #expect(recorder.actions == [
            .fact(.begin(task: "wire mpls")),
            .fact(.task(label: "tests")),
            .fact(.progress(fraction: 0.5)),
            .fact(.milestone(kind: "blocked", detail: "need the API key")),
            .say(text: "Baaa", animation: "spin"),
            .fact(.end(summary: "done")),
        ])
    }

    @Test func optionalArgumentsMayBeOmittedOrNull() async {
        let recorder = ActionRecorder()
        _ = await call("session_begin", "{}", recorder: recorder)
        _ = await call("session_begin", #"{"task":null}"#, recorder: recorder)
        _ = await call("milestone", #"{"kind":"done","detail":null}"#, recorder: recorder)
        _ = await send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"session_end"}}"#, recorder: recorder)
        #expect(recorder.actions == [
            .fact(.begin(task: nil)),
            .fact(.begin(task: nil)),
            .fact(.milestone(kind: "done", detail: nil)),
            .fact(.end(summary: nil)),
        ])
    }

    @Test func unknownExtraArgumentsAreIgnored() async {
        let recorder = ActionRecorder()
        let reply = await call("set_task", #"{"label":"x","surprise":1}"#, recorder: recorder)
        #expect(reply.text == "ok")
        #expect(recorder.actions == [.fact(.task(label: "x"))])
    }

    @Test func integerFractionIsAccepted() async {
        let recorder = ActionRecorder()
        let reply = await call("progress", #"{"fraction":1}"#, recorder: recorder)
        #expect(reply.text == "ok")
        #expect(recorder.actions == [.fact(.progress(fraction: 1))])
    }

    @Test func sayTruncatesTheLineTo500Characters() async {
        let recorder = ActionRecorder()
        let long = String(repeating: "æ", count: 700)
        _ = await call("say", #"{"text":"\#(long)"}"#, recorder: recorder)
        guard case .say(let text, let animation)? = recorder.actions.first else {
            Issue.record("expected a say action")
            return
        }
        #expect(text.unicodeScalars.count == 500)
        #expect(animation == nil)
    }

    // Arguments that do not fit the schema come back as a tool error result with
    // the same text rmcp produced (captured from the Rust server).
    @Test func missingRequiredArgumentIsAToolError() async {
        let recorder = ActionRecorder()
        let reply = await call("set_task", "{}", recorder: recorder)
        #expect(reply.response.status == 200)
        #expect(reply.error == nil)
        #expect(reply.result?["isError"] == .bool(true))
        #expect(reply.text == "failed to deserialize parameters: missing field `label`")
        #expect(recorder.actions.isEmpty)

        let noArguments = await send(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"progress"}}"#, recorder: recorder)
        #expect(noArguments.text == "failed to deserialize parameters: missing field `fraction`")
    }

    @Test func wrongArgumentTypeIsAToolError() async {
        let recorder = ActionRecorder()
        let string = await call("progress", #"{"fraction":"abc"}"#, recorder: recorder)
        #expect(string.text == #"failed to deserialize parameters: invalid type: string "abc", expected f32"#)
        let number = await call("set_task", #"{"label":5}"#, recorder: recorder)
        #expect(number.text == "failed to deserialize parameters: invalid type: integer `5`, expected a string")
        let float = await call("set_task", #"{"label":1.5}"#, recorder: recorder)
        #expect(float.text == "failed to deserialize parameters: invalid type: floating point `1.5`, expected a string")
        let bool = await call("say", #"{"text":true}"#, recorder: recorder)
        #expect(bool.text == "failed to deserialize parameters: invalid type: boolean `true`, expected a string")
        let null = await call("set_task", #"{"label":null}"#, recorder: recorder)
        #expect(null.text == "failed to deserialize parameters: invalid type: null, expected a string")
        let array = await call("milestone", #"{"kind":[]}"#, recorder: recorder)
        #expect(array.text == "failed to deserialize parameters: invalid type: sequence, expected a string")
        let object = await call("milestone", #"{"kind":"done","detail":{}}"#, recorder: recorder)
        #expect(object.text == "failed to deserialize parameters: invalid type: map, expected a string")
        for reply in [string, number, float, bool, null, array, object] {
            #expect(reply.result?["isError"] == .bool(true))
        }
        #expect(recorder.actions.isEmpty)
    }

    @Test func unknownToolIsInvalidParams() async {
        let reply = await call("nope", "{}")
        #expect(reply.response.status == 200)
        #expect(reply.errorCode == -32602)
        #expect(reply.error?["message"]?.stringValue == "tool not found")
    }

    @Test func malformedToolCallParamsAreInvalidParams() async {
        for body in [#"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#,
                     #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#,
                     #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":7}}"#,
                     #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":"x"}"#,
                     #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"say","arguments":[1]}}"#] {
            let reply = await send(body)
            #expect(reply.errorCode == -32602, "\(body)")
        }
    }

    // MARK: everything else

    @Test func pingReturnsEmptyResult() async {
        let reply = await send(#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#)
        #expect(reply.result == .object([:]))
        #expect(reply.json?["id"] == .number(6))
    }

    @Test func stringIdsAreEchoedVerbatim() async {
        let reply = await send(#"{"jsonrpc":"2.0","id":"req-α","method":"ping"}"#)
        #expect(reply.json?["id"] == .string("req-α"))
    }

    @Test func unknownMethodIsMethodNotFoundNamingTheMethod() async {
        let reply = await send(#"{"jsonrpc":"2.0","id":7,"method":"foo/bar"}"#)
        #expect(reply.response.status == 200)
        #expect(reply.errorCode == -32601)
        #expect(reply.error?["message"]?.stringValue == "foo/bar")
        #expect(reply.json?["id"] == .number(7))
        let read = await send(#"{"jsonrpc":"2.0","id":8,"method":"resources/read","params":{"uri":"x"}}"#)
        #expect(read.errorCode == -32601)
    }

    @Test func emptyListsForTheCapabilitiesWeDoNotAdvertise() async {
        let resources = await send(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)
        #expect(resources.result == .object(["resources": .array([])]))
        let templates = await send(#"{"jsonrpc":"2.0","id":2,"method":"resources/templates/list"}"#)
        #expect(templates.result == .object(["resourceTemplates": .array([])]))
        let prompts = await send(#"{"jsonrpc":"2.0","id":3,"method":"prompts/list"}"#)
        #expect(prompts.result == .object(["prompts": .array([])]))
    }

    @Test func notificationsAreAcceptedWithNoBody() async {
        for body in [#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                     #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#,
                     #"{"jsonrpc":"2.0","id":null,"method":"notifications/whatever"}"#] {
            let reply = await send(body)
            #expect(reply.response.status == 202, "\(body)")
            #expect(reply.response.body.isEmpty)
        }
    }

    @Test func clientResponsesAreAcceptedWithNoBody() async {
        let reply = await send(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        #expect(reply.response.status == 202)
        #expect(reply.response.body.isEmpty)
    }

    @Test func invalidJSONIsAParseError() async {
        for body in ["", "{", "not json", #"{"jsonrpc":"2.0","id":1,"method":"ping""#] {
            let reply = await send(body)
            #expect(reply.response.status == 400, "\(body)")
            #expect(reply.errorCode == -32700, "\(body)")
            #expect(reply.json?["id"] == .null)
        }
    }

    @Test func nonRequestsAreInvalidRequests() async {
        for body in ["[]", "42", #""ping""#,
                     #"{"id":1,"method":"ping"}"#,
                     #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":1}"#,
                     #"{"jsonrpc":"2.0","id":1,"method":7}"#,
                     #"{"jsonrpc":"2.0","id":{},"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#] {
            let reply = await send(body)
            #expect(reply.response.status == 400, "\(body)")
            #expect(reply.errorCode == -32600, "\(body)")
        }
    }

    @Test func invalidRequestEchoesAValidId() async {
        let reply = await send(#"{"jsonrpc":"2.0","id":5}"#)
        #expect(reply.json?["id"] == .number(5))
    }

    // MARK: MCP-Protocol-Version header

    @Test func protocolHeaderMustMatchInitializeBody() async {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
        let mismatch = await send(body, header: "2025-03-26")
        #expect(mismatch.response.status == 400)
        #expect(mismatch.errorCode == -32600)
        #expect(mismatch.json?["id"] == .number(1))
        let match = await send(body, header: "2025-06-18")
        #expect(match.response.status == 200)
        #expect(match.result?["protocolVersion"]?.stringValue == "2025-06-18")
        let absent = await send(body, header: nil)
        #expect(absent.response.status == 200)
    }

    @Test func protocolHeaderMustBeKnownOnOtherRequests() async {
        let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let bad = await send(list, header: "1999-01-01")
        #expect(bad.response.status == 400)
        #expect(String(decoding: bad.response.body, as: UTF8.self) == "Bad Request: Unsupported MCP-Protocol-Version: 1999-01-01")
        for version in MCPProtocol.supportedProtocolVersions {
            let good = await send(list, header: version)
            #expect(good.response.status == 200)
        }
        let notification = await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, header: "1999-01-01")
        #expect(notification.response.status == 400)
        let ok = await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, header: "2025-06-18")
        #expect(ok.response.status == 202)
    }

    @Test func rejectedCallsDoNotRunTheTool() async {
        let recorder = ActionRecorder()
        let reply = await send(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_task","arguments":{"label":"x"}}}"#,
            header: "1999-01-01", recorder: recorder)
        #expect(reply.response.status == 400)
        #expect(recorder.actions.isEmpty)
    }

    // MARK: version negotiation and shape

    @Test func negotiation() {
        #expect(MCPProtocol.negotiate("2025-06-18") == "2025-06-18")
        #expect(MCPProtocol.negotiate("2025-03-26") == "2025-03-26")
        #expect(MCPProtocol.negotiate("2024-11-05") == "2024-11-05")
        #expect(MCPProtocol.negotiate("3000-01-01") == MCPProtocol.latestProtocolVersion)
        #expect(MCPProtocol.supportedProtocolVersions.contains(MCPProtocol.latestProtocolVersion))
    }

    @Test func responsesAreCompactJSONWithSortedKeys() {
        let response = MCPProtocol.resultResponse(id: .number(1), result: .object(["b": .number(2), "a": .string("x/y")]))
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"id":1,"jsonrpc":"2.0","result":{"a":"x/y","b":2}}"#)
    }
}

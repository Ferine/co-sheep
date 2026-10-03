import Foundation
@testable import CoSheepKit

/// Builders shared by the herd ingest tests. All synthetic: no real transcript
/// or hook content is copied here.
nonisolated enum IngestFixtures {
    static func hook(
        _ name: String, session: String = "s1", cwd: String? = "/work/app", transcript: String? = "/t/s1.jsonl",
        mode: String? = nil, tool: String? = nil, notification: String? = nil, message: String? = nil,
        source: String? = nil, reason: String? = nil, error: String? = nil, interrupt: Bool? = nil,
        agentId: String? = nil, agentType: String? = nil, pid: Int32? = 4242
    ) -> HookEvent {
        HookEvent(
            sessionId: session, hookEventName: name, cwd: cwd, transcriptPath: transcript, permissionMode: mode,
            toolName: tool, notificationType: notification, message: message, source: source, reason: reason,
            error: error, isInterrupt: interrupt, agentId: agentId, agentType: agentType, pid: pid)
    }

    // MARK: Transcript lines

    private static func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func assistant(
        id: String?, input: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0, output: Int = 0,
        model: String = "claude-test"
    ) -> String {
        var message: [String: Any] = [
            "role": "assistant", "model": model,
            "content": [["type": "text", "text": "ok"]],
            "usage": [
                "input_tokens": input, "cache_creation_input_tokens": cacheCreation,
                "cache_read_input_tokens": cacheRead, "output_tokens": output,
                "service_tier": "standard",
            ] as [String: Any],
        ]
        if let id { message["id"] = id }
        return line(["type": "assistant", "message": message, "uuid": UUID().uuidString])
    }

    static func assistantWithoutUsage(id: String) -> String {
        line(["type": "assistant", "message": ["id": id, "role": "assistant", "content": []] as [String: Any]])
    }

    static func title(_ text: String) -> String {
        line(["type": "ai-title", "aiTitle": text, "sessionId": "s1"])
    }

    static func userString(_ text: String) -> String {
        line(["type": "user", "message": ["role": "user", "content": text] as [String: Any]])
    }

    static func userBlocks(_ text: String) -> String {
        line(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]] as [String: Any]])
    }

    static func toolResult(_ text: String) -> String {
        line(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_1", "content": text],
        ]] as [String: Any]])
    }

    static func filler(bytes: Int) -> String {
        line(["type": "attachment", "payload": String(repeating: "x", count: bytes)])
    }

    /// Lines joined with newlines, ending in one.
    static func file(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

/// Runs reducer folds with a clock that advances a second per event.
struct IngestFold {
    var state = HerdState()
    var now = 1_000_000.0

    @discardableResult
    mutating func send(_ event: HookEvent, advanceMs: Double = 1000) -> [HerdChange] {
        now += advanceMs
        return HerdReducer.apply(&state, event, nowMs: now)
    }

    @discardableResult
    mutating func send(
        _ name: String, session: String = "s1", tool: String? = nil, advanceMs: Double = 1000,
        configure: (inout HookEvent) -> Void = { _ in }
    ) -> [HerdChange] {
        var event = IngestFixtures.hook(name, session: session, tool: tool)
        configure(&event)
        return send(event, advanceMs: advanceMs)
    }

    var s1: AgentSession? { state.sessions["s1"] }
}

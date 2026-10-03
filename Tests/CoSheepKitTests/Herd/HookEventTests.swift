import Foundation
import Testing
@testable import CoSheepKit

// Payloads shaped like Claude Code's hook JSON (synthetic values). Only the
// fields HookEvent keeps survive; the rest, prompts and tool I/O included, is dropped.
@Suite("herd hook event decoding")
struct HookEventTests {
    private func decode(_ json: String) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    @Test func preToolUseKeepsTheToolNameAndDropsItsInput() throws {
        let e = try decode("""
        {"session_id":"sess-1","transcript_path":"/Users/me/.claude/projects/-p/sess-1.jsonl","cwd":"/Users/me/p",
         "permission_mode":"acceptEdits","hook_event_name":"PreToolUse","tool_name":"Bash",
         "tool_input":{"command":"rm -rf build","description":"clean"},"tool_use_id":"toolu_01"}
        """)
        #expect(e.sessionId == "sess-1")
        #expect(e.hookEventName == "PreToolUse")
        #expect(e.toolName == "Bash")
        #expect(e.cwd == "/Users/me/p")
        #expect(e.transcriptPath == "/Users/me/.claude/projects/-p/sess-1.jsonl")
        #expect(e.permissionMode == "acceptEdits")
        #expect(e.agentId == nil)
        #expect(e.pid == nil)
    }

    @Test func postToolUseWithAHugeResponseDecodes() throws {
        let big = String(repeating: "line of output\\n", count: 20_000)
        let e = try decode("""
        {"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Read",
         "tool_input":{"file_path":"/x"},"tool_response":{"content":"\(big)","truncated":false},"duration_ms":12}
        """)
        #expect(e.toolName == "Read")
    }

    @Test func notificationFields() throws {
        let e = try decode("""
        {"session_id":"s","hook_event_name":"Notification","notification_type":"permission_prompt",
         "message":"Claude needs your permission to use Bash","title":"Permission needed"}
        """)
        #expect(e.notificationType == "permission_prompt")
        #expect(e.message == "Claude needs your permission to use Bash")
    }

    @Test func sessionStartAndEndFields() throws {
        let start = try decode(#"{"session_id":"s","hook_event_name":"SessionStart","source":"clear","model":"claude-x"}"#)
        #expect(start.source == "clear")
        let end = try decode(#"{"session_id":"s","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#)
        #expect(end.reason == "prompt_input_exit")
    }

    @Test func subagentFields() throws {
        let e = try decode(#"{"session_id":"s","hook_event_name":"SubagentStart","agent_id":"agent-7","agent_type":"Explore"}"#)
        #expect(e.agentId == "agent-7")
        #expect(e.agentType == "Explore")
    }

    @Test func failureFields() throws {
        let tool = try decode(#"{"session_id":"s","hook_event_name":"PostToolUseFailure","tool_name":"Bash","error":"Command exited with 2","is_interrupt":true}"#)
        #expect(tool.error == "Command exited with 2")
        #expect(tool.isInterrupt == true)
        let stop = try decode(#"{"session_id":"s","hook_event_name":"StopFailure","error":"rate_limit"}"#)
        #expect(stop.error == "rate_limit")
        #expect(stop.isInterrupt == nil)
    }

    @Test func unknownFieldsAreIgnored() throws {
        let e = try decode(#"{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done","brand_new":{"a":[1,2,3]}}"#)
        #expect(e.sessionId == "s")
        #expect(e.hookEventName == "Stop")
        #expect(e.message == nil)
    }

    @Test func wrongTypedOptionalFieldsBecomeNil() throws {
        let e = try decode("""
        {"session_id":"s","hook_event_name":"PostToolUseFailure","cwd":42,"transcript_path":["a"],
         "permission_mode":{"x":1},"tool_name":false,"notification_type":7,"message":null,"source":1.5,
         "reason":[],"error":{"msg":"boom"},"is_interrupt":"yes","agent_id":99,"agent_type":true}
        """)
        #expect(e.sessionId == "s")
        #expect(e.cwd == nil)
        #expect(e.transcriptPath == nil)
        #expect(e.permissionMode == nil)
        #expect(e.toolName == nil)
        #expect(e.notificationType == nil)
        #expect(e.message == nil)
        #expect(e.source == nil)
        #expect(e.reason == nil)
        #expect(e.error == nil)
        #expect(e.isInterrupt == nil)
        #expect(e.agentId == nil)
        #expect(e.agentType == nil)
    }

    @Test func aMissingSessionIdOrEventNameThrows() {
        #expect(throws: (any Error).self) { try decode(#"{"hook_event_name":"Stop"}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"session_id":"s"}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"session_id":7,"hook_event_name":"Stop"}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"session_id":"s","hook_event_name":null}"#) }
        #expect(throws: (any Error).self) { try decode("{}") }
    }

    @Test func nonObjectsAndGarbageThrow() {
        for json in ["[]", "\"s\"", "42", "null", "", "{not json", #"[{"session_id":"s","hook_event_name":"Stop"}]"#] {
            #expect(throws: (any Error).self, "\(json)") { try decode(json) }
        }
    }

    @Test func thePidIsNeverReadFromTheJson() throws {
        let e = try decode(#"{"session_id":"s","hook_event_name":"Stop","pid":999,"claude_pid":1}"#)
        #expect(e.pid == nil)
    }

    @Test func aPayloadWithOnlyTheRequiredFieldsIsFine() throws {
        let e = try decode(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"never stored"}"#)
        #expect(e == HookEvent(sessionId: "s", hookEventName: "UserPromptSubmit"))
    }
}

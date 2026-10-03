import Foundation

// The agent herd's shared vocabulary: what a Claude Code hook reports, what a
// session looks like once folded, and the change events the lambs react to.
// Spec: docs/superpowers/specs/2026-10-03-agent-herd-design.md.

/// One Claude Code hook invocation, as POSTed to `/hook` by the shim. Only the
/// fields the herd needs; everything else in the payload (prompts, tool
/// input/output) is ignored and never stored.
nonisolated struct HookEvent: Equatable, Sendable, Decodable {
    var sessionId: String
    var hookEventName: String
    var cwd: String?
    var transcriptPath: String?
    var permissionMode: String?
    var toolName: String?
    /// Notification: permission_prompt | idle_prompt | agent_needs_input |
    /// elicitation_dialog | … (see the spec).
    var notificationType: String?
    var message: String?
    /// SessionStart: startup | resume | clear | compact | fork.
    var source: String?
    /// SessionEnd: clear | resume | logout | prompt_input_exit | other.
    var reason: String?
    /// PostToolUseFailure / StopFailure.
    var error: String?
    /// PostToolUseFailure: the human interrupted the tool.
    var isInterrupt: Bool?
    /// Set inside subagents (and SubagentStart/Stop).
    var agentId: String?
    var agentType: String?
    /// Not part of the hook JSON: `$CLAUDE_PID` (falling back to `$PPID`),
    /// sent by the shim in the `X-Co-Sheep-Pid` header.
    var pid: Int32?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case transcriptPath = "transcript_path"
        case permissionMode = "permission_mode"
        case toolName = "tool_name"
        case notificationType = "notification_type"
        case message, source, reason, error
        case isInterrupt = "is_interrupt"
        case agentId = "agent_id"
        case agentType = "agent_type"
    }

    init(sessionId: String, hookEventName: String, cwd: String? = nil, transcriptPath: String? = nil,
         permissionMode: String? = nil, toolName: String? = nil, notificationType: String? = nil,
         message: String? = nil, source: String? = nil, reason: String? = nil, error: String? = nil,
         isInterrupt: Bool? = nil, agentId: String? = nil, agentType: String? = nil, pid: Int32? = nil) {
        self.sessionId = sessionId
        self.hookEventName = hookEventName
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.permissionMode = permissionMode
        self.toolName = toolName
        self.notificationType = notificationType
        self.message = message
        self.source = source
        self.reason = reason
        self.error = error
        self.isInterrupt = isInterrupt
        self.agentId = agentId
        self.agentType = agentType
        self.pid = pid
    }

    /// Lenient: a field of the wrong type decodes as nil instead of failing
    /// the whole event. Only `session_id` and `hook_event_name` are required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        hookEventName = try c.decode(String.self, forKey: .hookEventName)
        func s(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        cwd = s(.cwd)
        transcriptPath = s(.transcriptPath)
        permissionMode = s(.permissionMode)
        toolName = s(.toolName)
        notificationType = s(.notificationType)
        message = s(.message)
        source = s(.source)
        reason = s(.reason)
        error = s(.error)
        isInterrupt = (try? c.decodeIfPresent(Bool.self, forKey: .isInterrupt)) ?? nil
        agentId = s(.agentId)
        agentType = s(.agentType)
        pid = nil
    }
}

/// What the lamb is holding. Drives the tool prop.
nonisolated enum ToolKind: String, Equatable, Sendable, CaseIterable {
    case thinking   // no tool: thought cloud
    case edit       // knitting needles + yarn
    case bash       // shovel, dirt flying
    case read       // tiny open book
    case web        // telescope
    case subagent   // shepherd's whistle
    case plan       // clipboard
    case mcp        // tin-can telephone
    case ask        // AskUserQuestion: the agent is asking you
    case compacting // chewing cud
    case other      // magic wand sparkles

    static func classify(_ toolName: String?) -> ToolKind {
        guard let name = toolName, !name.isEmpty else { return .thinking }
        if name.hasPrefix("mcp__") { return .mcp }
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return .edit
        case "Bash", "BashOutput", "KillShell", "KillBash", "PowerShell", "Monitor": return .bash
        case "Read", "Grep", "Glob", "LS", "LSP", "NotebookRead": return .read
        case "WebFetch", "WebSearch": return .web
        case "Task", "Agent", "SendMessage", "Workflow": return .subagent
        case "TodoWrite", "TaskCreate", "TaskUpdate", "EnterPlanMode", "ExitPlanMode": return .plan
        case "AskUserQuestion": return .ask
        default: return .other
        }
    }
}

nonisolated enum AgentPhase: String, Equatable, Sendable {
    /// Turn finished; waiting for the next prompt. The lamb sleeps.
    case idle
    /// Thinking or running tools. The lamb works its prop.
    case working
    /// Needs the human: permission prompt, question, elicitation. `?` + bleats.
    case waiting
    /// Session over. The lamb is sheared and trots off-screen.
    case ended
}

/// One-shot things a lamb reacts to on top of its phase.
nonisolated enum HerdBeat: String, Equatable, Sendable {
    case arrived           // new session (parachute in)
    case turnDone          // Stop
    case toolFailed        // PostToolUseFailure (not an interrupt)
    case permissionDenied  // PermissionDenied
    case apiError          // StopFailure
    case interrupted       // human interrupt (PostToolUseFailure is_interrupt, or transcript marker)
    case compacted         // PreCompact
    case cleared           // /clear re-keyed this lamb: shear, but stay
    case departed          // SessionEnd or liveness sweep
}

/// A folded Claude Code session. Value type; `HerdStore` owns the live copies.
nonisolated struct AgentSession: Equatable, Sendable {
    var id: String
    var cwd: String?
    /// Git root (or cwd when not in a repo). Same key → same wool colour.
    var repoKey: String?
    /// Last path component of `repoKey`: the lamb's name tag.
    var repoName: String?
    var transcriptPath: String?
    var permissionMode: String?
    /// The `claude` process (liveness) and the terminal app hosting it (focus).
    var agentPid: Int32?
    var terminalPid: Int32?

    var phase: AgentPhase = .idle
    var tool: ToolKind = .thinking
    /// Raw tool name of the current/last tool (for bubbles and the shepherd).
    var toolName: String?
    /// What it's waiting on (tool name or notification message), while `.waiting`.
    var waitingFor: String?
    /// Last error text (tool failure / API error), for the shepherd.
    var lastError: String?

    var startedMs: Double
    var lastEventMs: Double
    var phaseSinceMs: Double

    var toolCalls: Int = 0
    var failures: Int = 0
    var turnsDone: Int = 0
    /// Active subagents (SubagentStart − SubagentStop, never below 0).
    var subagents: Int = 0
    /// Σ input + cache creation + cache read + output, from the transcript.
    var tokens: Int = 0
    /// The transcript's `ai-title`, when Claude Code has written one.
    var title: String?

    init(id: String, nowMs: Double) {
        self.id = id
        startedMs = nowMs
        lastEventMs = nowMs
        phaseSinceMs = nowMs
    }

    /// Name for bubbles and the name tag.
    var displayName: String { repoName ?? "lamb" }
}

/// What `HerdStore` publishes on `AppEvents.herd` after every fold.
nonisolated struct HerdChange: Equatable, Sendable {
    /// The session after the change.
    var session: AgentSession
    /// nil when the session is new.
    var previousPhase: AgentPhase?
    var beat: HerdBeat?
    /// Set when /clear re-keyed an existing session: the lamb that was
    /// `previousId` is now `session.id`.
    var previousId: String?
}

/// Wool colour for a repo: a stable hue in 0..<360 from FNV-1a of the key.
nonisolated enum HerdPalette {
    static func hue(forRepoKey key: String) -> Double {
        var h: UInt32 = 2_166_136_261
        for b in key.utf8 {
            h ^= UInt32(b)
            h = h &* 16_777_619
        }
        return Double(h % 360)
    }

    /// The `Sheep.tint` string: same alpha/shape as `FRIEND_TINTS`.
    static func tint(forRepoKey key: String) -> String {
        "hsla(\(Int(hue(forRepoKey: key))), 70%, 62%, 0.35)"
    }

    /// Solid colour for bubbles/borders/wool puffs.
    static func solid(forRepoKey key: String, lightness: Int = 60) -> String {
        "hsl(\(Int(hue(forRepoKey: key))), 65%, \(lightness)%)"
    }
}

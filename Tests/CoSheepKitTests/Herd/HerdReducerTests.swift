import Foundation
import Testing
@testable import CoSheepKit

// The reducer table from the herd spec, row by row, plus /clear re-keying,
// subagents, liveness sweeps and transcript folds.
@Suite("herd reducer")
struct HerdReducerTests {
    private func hook(_ name: String, session: String = "s1", tool: String? = nil) -> HookEvent {
        IngestFixtures.hook(name, session: session, tool: tool)
    }

    // MARK: session start / creation

    @Test func sessionStartCreatesAnIdleLambThatArrives() {
        var fold = IngestFold()
        let changes = fold.send(IngestFixtures.hook("SessionStart", source: "startup"))
        #expect(changes.count == 1)
        let change = changes[0]
        #expect(change.beat == .arrived)
        #expect(change.previousPhase == nil)
        #expect(change.previousId == nil)
        #expect(change.session.phase == .idle)
        #expect(change.session.id == "s1")
        #expect(change.session.cwd == "/work/app")
        #expect(change.session.transcriptPath == "/t/s1.jsonl")
        #expect(change.session.agentPid == 4242)
        #expect(fold.s1 == change.session)
        #expect(change.session.startedMs == fold.now)
    }

    @Test func resumeOfAKnownSessionDoesNotArriveAgain() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send("UserPromptSubmit")
        #expect(fold.s1?.phase == .working)

        let changes = fold.send(IngestFixtures.hook("SessionStart", source: "resume"))
        #expect(changes.count == 1)
        #expect(changes[0].beat == nil)
        #expect(changes[0].previousPhase == .working)
        #expect(changes[0].session.phase == .idle)
        #expect(fold.state.sessions.count == 1)
    }

    @Test func aRestartedProcessUnderTheSameIdAdoptsItsNewPid() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("SessionStart", pid: 100))
        fold.state.sessions["s1"]?.terminalPid = 55
        fold.send(IngestFixtures.hook("SessionStart", source: "resume", pid: 200))
        #expect(fold.s1?.agentPid == 200)
        #expect(fold.s1?.terminalPid == nil) // to be looked up again
        // other events never move the pid
        fold.send(IngestFixtures.hook("Stop", pid: 300))
        #expect(fold.s1?.agentPid == 200)
    }

    @Test func eventsForAnUnknownSessionCreateIt() {
        var fold = IngestFold()
        let changes = fold.send("PreToolUse", tool: "Bash")
        #expect(changes.count == 1)
        #expect(changes[0].beat == .arrived)
        #expect(changes[0].previousPhase == nil)
        #expect(changes[0].session.phase == .working)
        #expect(changes[0].session.tool == .bash)
        #expect(changes[0].session.toolCalls == 1)
        #expect(fold.state.sessions.count == 1)
    }

    @Test(arguments: ["UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Notification", "PreCompact"])
    func anyHandledEventCreatesAnUnknownSession(name: String) {
        var fold = IngestFold()
        let changes = fold.send(name, tool: "Read")
        #expect(changes.count == 1)
        #expect(changes[0].beat == .arrived)
        #expect(fold.state.sessions.keys.sorted() == ["s1"])
    }

    @Test func sessionEndForAnUnknownSessionCreatesNothing() {
        var fold = IngestFold()
        #expect(fold.send(IngestFixtures.hook("SessionEnd", reason: "logout")).isEmpty)
        #expect(fold.state.sessions.isEmpty)
    }

    @Test func unknownEventNamesAndEmptyIdsAreIgnored() {
        var fold = IngestFold()
        #expect(fold.send("CwdChanged").isEmpty)
        #expect(fold.state.sessions.isEmpty)
        #expect(fold.send("PreToolUse", session: "", tool: "Bash").isEmpty)
        #expect(fold.state.sessions.isEmpty)
    }

    @Test func unknownEventNamesStillProveASessionIsAlive() {
        var fold = IngestFold()
        fold.send("SessionStart")
        let before = fold.s1!
        #expect(fold.send("FileChanged", advanceMs: 5000).isEmpty)
        #expect(fold.s1?.lastEventMs == before.lastEventMs + 5000)
        #expect(fold.s1?.phase == before.phase)
    }

    // MARK: the table

    @Test func userPromptStartsThinking() {
        var fold = IngestFold()
        fold.send("SessionStart")
        let change = fold.send("UserPromptSubmit")[0]
        #expect(change.session.phase == .working)
        #expect(change.session.tool == .thinking)
        #expect(change.session.toolName == nil)
        #expect(change.previousPhase == .idle)
        #expect(change.beat == nil)
    }

    @Test func preToolUseWorksTheToolsProp() {
        var fold = IngestFold()
        fold.send("SessionStart")
        let cases: [(String, ToolKind)] = [
            ("Edit", .edit), ("Bash", .bash), ("Grep", .read), ("WebFetch", .web), ("Agent", .subagent),
            ("TodoWrite", .plan), ("mcp__co-sheep__progress", .mcp), ("Mystery", .other),
        ]
        for (index, (tool, kind)) in cases.enumerated() {
            let change = fold.send("PreToolUse", tool: tool)[0]
            #expect(change.session.phase == .working)
            #expect(change.session.tool == kind, "\(tool)")
            #expect(change.session.toolName == tool)
            #expect(change.session.toolCalls == index + 1)
        }
    }

    @Test func askUserQuestionWaitsOnTheHuman() {
        var fold = IngestFold()
        fold.send("SessionStart")
        let change = fold.send("PreToolUse", tool: "AskUserQuestion")[0]
        #expect(change.session.phase == .waiting)
        #expect(change.session.tool == .ask)
        #expect(change.session.waitingFor == "AskUserQuestion")
        #expect(change.session.toolCalls == 1)
        // answering clears it
        let after = fold.send("PostToolUse", tool: "AskUserQuestion")[0]
        #expect(after.session.phase == .working)
        #expect(after.session.waitingFor == nil)
    }

    @Test func permissionRequestWaitsAndPostToolUseClearsIt() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send("PreToolUse", tool: "Bash")
        let waiting = fold.send("PermissionRequest", tool: "Bash")[0]
        #expect(waiting.session.phase == .waiting)
        #expect(waiting.session.tool == .bash)
        #expect(waiting.session.waitingFor == "Bash")
        #expect(waiting.previousPhase == .working)
        #expect(waiting.session.toolCalls == 1) // the request itself isn't a call

        let after = fold.send("PostToolUse", tool: "Bash")[0]
        #expect(after.session.phase == .working)
        #expect(after.session.tool == .bash)
        #expect(after.session.waitingFor == nil)
        #expect(after.previousPhase == .waiting)
        #expect(after.session.toolCalls == 1) // PostToolUse doesn't count either
    }

    @Test(arguments: ["permission_prompt", "agent_needs_input", "elicitation_dialog"])
    func needsInputNotificationsWait(type: String) {
        var fold = IngestFold()
        fold.send("SessionStart")
        let change = fold.send(IngestFixtures.hook("Notification", notification: type, message: "Claude needs you"))[0]
        #expect(change.session.phase == .waiting)
        #expect(change.session.waitingFor == "Claude needs you")
        #expect(change.beat == nil)
    }

    @Test func aNotificationKeepsTheToolNameAPermissionRequestAlreadyGave() {
        var fold = IngestFold()
        fold.send("PermissionRequest", tool: "Write")
        let change = fold.send(IngestFixtures.hook("Notification", notification: "permission_prompt", message: "needs permission"))[0]
        #expect(change.session.phase == .waiting)
        #expect(change.session.waitingFor == "Write")
    }

    @Test func aNotificationFillsAMissingWaitingFor() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("PermissionRequest", tool: nil))
        #expect(fold.s1?.waitingFor == nil)
        fold.send(IngestFixtures.hook("Notification", notification: "permission_prompt", message: "needs permission"))
        #expect(fold.s1?.waitingFor == "needs permission")
    }

    @Test func waitingForIsTruncatedToOneHundredTwentyScalars() {
        var fold = IngestFold()
        let long = String(repeating: "🐑", count: 300)
        let change = fold.send(IngestFixtures.hook("Notification", notification: "elicitation_dialog", message: long))[0]
        #expect(change.session.waitingFor?.unicodeScalars.count == 120)
        #expect(long.hasPrefix(change.session.waitingFor ?? "x"))
    }

    @Test func idlePromptNotificationGoesIdle() {
        var fold = IngestFold()
        fold.send("UserPromptSubmit")
        let change = fold.send(IngestFixtures.hook("Notification", notification: "idle_prompt"))[0]
        #expect(change.session.phase == .idle)
        #expect(change.previousPhase == .working)
        #expect(change.beat == nil)
    }

    @Test func otherNotificationsChangeNothingButStillEmit() {
        var fold = IngestFold()
        fold.send("UserPromptSubmit")
        let changes = fold.send(IngestFixtures.hook("Notification", notification: "auth_success", message: "hi"))
        #expect(changes.count == 1)
        #expect(changes[0].session.phase == .working)
        #expect(changes[0].previousPhase == .working)
    }

    @Test func postToolUseFailureIsAFailureNotAnInterrupt() {
        var fold = IngestFold()
        fold.send("SessionStart")
        let change = fold.send(IngestFixtures.hook("PostToolUseFailure", tool: "Bash", error: "exit 1", interrupt: false))[0]
        #expect(change.session.phase == .working)
        #expect(change.session.tool == .bash)
        #expect(change.beat == .toolFailed)
        #expect(change.session.failures == 1)
        #expect(change.session.lastError == "exit 1")
    }

    @Test func aFailureWithoutTheInterruptFlagStillCounts() {
        var fold = IngestFold()
        let change = fold.send(IngestFixtures.hook("PostToolUseFailure", tool: "Read", error: "nope", interrupt: nil))[0]
        #expect(change.beat == .arrived)
        #expect(change.session.failures == 1)
        #expect(change.session.phase == .working)
    }

    @Test func interruptedToolFailureGoesIdle() {
        var fold = IngestFold()
        fold.send("UserPromptSubmit")
        let change = fold.send(IngestFixtures.hook("PostToolUseFailure", tool: "Bash", error: "interrupted", interrupt: true))[0]
        #expect(change.session.phase == .idle)
        #expect(change.beat == .interrupted)
        #expect(change.previousPhase == .working)
        #expect(change.session.failures == 0)
        #expect(change.session.lastError == nil)
    }

    @Test func lastErrorIsTruncatedToTwoHundredScalars() {
        var fold = IngestFold()
        let long = String(repeating: "æ", count: 500)
        fold.send(IngestFixtures.hook("PostToolUseFailure", tool: "Bash", error: long))
        #expect(fold.s1?.lastError?.unicodeScalars.count == 200)
        fold.send(IngestFixtures.hook("StopFailure", error: String(repeating: "x", count: 250)))
        #expect(fold.s1?.lastError?.unicodeScalars.count == 200)
    }

    @Test func permissionDeniedKeepsWorking() {
        var fold = IngestFold()
        fold.send("PermissionRequest", tool: "Bash")
        let change = fold.send("PermissionDenied", tool: "Bash")[0]
        #expect(change.session.phase == .working)
        #expect(change.session.waitingFor == nil)
        #expect(change.beat == .permissionDenied)
        #expect(change.previousPhase == .waiting)
    }

    @Test func stopEndsTheTurn() {
        var fold = IngestFold()
        fold.send("UserPromptSubmit")
        fold.send("PreToolUse", tool: "Edit")
        let change = fold.send("Stop")[0]
        #expect(change.session.phase == .idle)
        #expect(change.session.tool == .thinking)
        #expect(change.session.toolName == "Edit") // the last tool stays for the shepherd
        #expect(change.beat == .turnDone)
        #expect(change.session.turnsDone == 1)
        fold.send("UserPromptSubmit")
        fold.send("Stop")
        #expect(fold.s1?.turnsDone == 2)
    }

    @Test func stopFailureIsAnApiError() {
        var fold = IngestFold()
        fold.send("UserPromptSubmit")
        let change = fold.send(IngestFixtures.hook("StopFailure", error: "rate_limit"))[0]
        #expect(change.session.phase == .idle)
        #expect(change.beat == .apiError)
        #expect(change.session.lastError == "rate_limit")
        #expect(change.session.turnsDone == 0)
    }

    @Test func stopFailureFallsBackToTheMessage() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("StopFailure", message: "overloaded"))
        #expect(fold.s1?.lastError == "overloaded")
    }

    @Test func preCompactChewsTheCud() {
        var fold = IngestFold()
        fold.send("UserPromptSubmit")
        fold.send("PreToolUse", tool: "Edit")
        let change = fold.send("PreCompact")[0]
        #expect(change.session.phase == .working)
        #expect(change.session.tool == .compacting)
        #expect(change.session.toolName == nil)
        #expect(change.beat == .compacted)
    }

    @Test func sessionEndDepartsAndForgetsTheSession() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send("UserPromptSubmit")
        let changes = fold.send(IngestFixtures.hook("SessionEnd", reason: "logout"))
        #expect(changes.count == 1)
        #expect(changes[0].session.phase == .ended)
        #expect(changes[0].previousPhase == .working)
        #expect(changes[0].beat == .departed)
        #expect(fold.state.sessions.isEmpty)
    }

    // MARK: bookkeeping

    @Test func phaseSinceMovesOnlyWhenThePhaseDoes() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send("UserPromptSubmit")
        let since = fold.s1!.phaseSinceMs
        #expect(since == fold.now)

        fold.send("PreToolUse", tool: "Edit", advanceMs: 4000)
        fold.send("PostToolUse", tool: "Edit", advanceMs: 4000)
        #expect(fold.s1?.phaseSinceMs == since)
        #expect(fold.s1?.lastEventMs == fold.now)

        fold.send("Stop", advanceMs: 4000)
        #expect(fold.s1?.phaseSinceMs == fold.now)
    }

    @Test func everyEventRefreshesLastEvent() {
        var fold = IngestFold()
        fold.send("SessionStart")
        for name in ["SubagentStart", "Notification", "SubagentStop", "PermissionDenied"] {
            let before = fold.s1!.lastEventMs
            fold.send(IngestFixtures.hook(name, agentType: "Explore"), advanceMs: 7000)
            #expect(fold.s1?.lastEventMs == before + 7000, "\(name)")
        }
    }

    @Test func missingFieldsAreFilledFromLaterEvents() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("SessionStart", cwd: nil, transcript: nil, pid: nil))
        #expect(fold.s1?.cwd == nil)
        #expect(fold.s1?.transcriptPath == nil)
        #expect(fold.s1?.agentPid == nil)

        fold.send(IngestFixtures.hook("UserPromptSubmit", cwd: "/a", transcript: "/t/a.jsonl", mode: "plan", pid: 77))
        #expect(fold.s1?.cwd == "/a")
        #expect(fold.s1?.transcriptPath == "/t/a.jsonl")
        #expect(fold.s1?.permissionMode == "plan")
        #expect(fold.s1?.agentPid == 77)

        // what is known is not overwritten (cwd drifts as the agent cd's) ...
        fold.send(IngestFixtures.hook("Stop", cwd: "/b", transcript: "/t/b.jsonl", pid: 88))
        #expect(fold.s1?.cwd == "/a")
        #expect(fold.s1?.transcriptPath == "/t/a.jsonl")
        #expect(fold.s1?.agentPid == 77)
        // ... except the permission mode, which really changes
        fold.send(IngestFixtures.hook("UserPromptSubmit", mode: "acceptEdits"))
        #expect(fold.s1?.permissionMode == "acceptEdits")
        fold.send(IngestFixtures.hook("Stop", mode: nil))
        #expect(fold.s1?.permissionMode == "acceptEdits")
    }

    @Test func nonPositivePidsAreIgnored() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("SessionStart", pid: 0))
        #expect(fold.s1?.agentPid == nil)
        fold.send(IngestFixtures.hook("Stop", pid: -3))
        #expect(fold.s1?.agentPid == nil)
    }

    @Test func waitingForLivesOnlyWhileWaiting() {
        for leaving in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionDenied", "Stop", "StopFailure", "PreCompact"] {
            var fold = IngestFold()
            fold.send("PermissionRequest", tool: "Bash")
            #expect(fold.s1?.waitingFor == "Bash")
            fold.send(leaving, tool: "Read")
            #expect(fold.s1?.waitingFor == nil, "\(leaving)")
            #expect(fold.s1?.phase != .waiting, "\(leaving)")
        }
    }

    // MARK: subagents

    @Test func subagentsAreCountedAndNeverGoBelowZero() {
        var fold = IngestFold()
        fold.send("SessionStart")
        func start() { fold.send(IngestFixtures.hook("SubagentStart", agentId: "a1", agentType: "Explore")) }
        func stop() { fold.send(IngestFixtures.hook("SubagentStop", agentId: "a1", agentType: "Explore")) }
        start()
        start()
        #expect(fold.s1?.subagents == 2)
        stop()
        #expect(fold.s1?.subagents == 1)
        stop()
        stop()
        stop()
        #expect(fold.s1?.subagents == 0)
    }

    @Test func subagentStartAndStopEmitChanges() {
        var fold = IngestFold()
        fold.send("SessionStart")
        let change = fold.send(IngestFixtures.hook("SubagentStart", agentId: "a1", agentType: "general-purpose"))
        #expect(change.count == 1)
        #expect(change[0].session.subagents == 1)
        #expect(change[0].beat == nil)
        #expect(change[0].session.phase == .idle)
    }

    @Test func subagentsWithoutATypeAreIgnored() {
        var fold = IngestFold()
        fold.send("SessionStart")
        for agentType in [nil, ""] as [String?] {
            #expect(fold.send(IngestFixtures.hook("SubagentStart", agentType: agentType)).isEmpty)
            #expect(fold.send(IngestFixtures.hook("SubagentStop", agentType: agentType)).isEmpty)
        }
        #expect(fold.s1?.subagents == 0)
        fold.send(IngestFixtures.hook("SubagentStart", agentType: "Explore"))
        #expect(fold.send(IngestFixtures.hook("SubagentStop", agentType: "")).isEmpty)
        #expect(fold.s1?.subagents == 1)
    }

    @Test func anIgnoredSubagentEventDoesNotCreateASession() {
        var fold = IngestFold()
        #expect(fold.send(IngestFixtures.hook("SubagentStop", agentType: "")).isEmpty)
        #expect(fold.state.sessions.isEmpty)
    }

    @Test func subagentToolEventsUpdateToolAndPhaseButNotTheCallCount() {
        var fold = IngestFold()
        fold.send("UserPromptSubmit")
        fold.send("PreToolUse", tool: "Agent")
        #expect(fold.s1?.toolCalls == 1)

        let inner = fold.send(IngestFixtures.hook("PreToolUse", tool: "Grep", agentId: "a1", agentType: "Explore"))[0]
        #expect(inner.session.tool == .read)
        #expect(inner.session.toolName == "Grep")
        #expect(inner.session.phase == .working)
        #expect(inner.session.toolCalls == 1)

        let waiting = fold.send(IngestFixtures.hook("PermissionRequest", tool: "Bash", agentId: "a1", agentType: "Explore"))[0]
        #expect(waiting.session.phase == .waiting)
        #expect(waiting.session.waitingFor == "Bash")

        let done = fold.send(IngestFixtures.hook("PostToolUse", tool: "Bash", agentId: "a1", agentType: "Explore"))[0]
        #expect(done.session.phase == .working)
        #expect(done.session.toolCalls == 1)
    }

    // MARK: /clear

    @Test func aClearIsNotADepartureRightAway() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send("UserPromptSubmit")
        let changes = fold.send(IngestFixtures.hook("SessionEnd", reason: "clear"))
        #expect(changes.isEmpty)
        #expect(fold.state.sessions.isEmpty)
        #expect(fold.state.recentlyCleared.count == 1)
        #expect(fold.state.recentlyCleared[0].id == "s1")
        #expect(fold.state.recentlyCleared[0].agentPid == 4242)
        #expect(fold.state.recentlyCleared[0].cwd == "/work/app")
    }

    @Test func sessionStartAfterAClearRekeysTheLamb() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send("UserPromptSubmit")
        fold.send("PreToolUse", tool: "Edit")
        fold.send("Stop")
        fold.send("UserPromptSubmit")
        fold.state.sessions["s1"]?.tokens = 90_000
        fold.state.sessions["s1"]?.title = "Fix the thing"
        fold.state.sessions["s1"]?.failures = 2
        fold.state.sessions["s1"]?.repoKey = "/work/app"
        fold.state.sessions["s1"]?.repoName = "app"
        fold.state.sessions["s1"]?.terminalPid = 9
        let started = fold.s1!.startedMs
        fold.send(IngestFixtures.hook("SessionEnd", reason: "clear"))

        let changes = fold.send(IngestFixtures.hook("SessionStart", session: "s2", transcript: "/t/s2.jsonl", source: "clear"), advanceMs: 800)
        #expect(changes.count == 1)
        let change = changes[0]
        #expect(change.beat == .cleared)
        #expect(change.previousId == "s1")
        #expect(change.previousPhase == .working) // what the lamb last saw
        let s = change.session
        #expect(s.id == "s2")
        #expect(s.phase == .idle)
        #expect(s.tokens == 0)
        #expect(s.title == nil)
        #expect(s.toolCalls == 0)
        #expect(s.turnsDone == 0)
        #expect(s.failures == 0)
        #expect(s.subagents == 0)
        #expect(s.tool == .thinking)
        #expect(s.toolName == nil)
        #expect(s.transcriptPath == "/t/s2.jsonl")
        #expect(s.repoKey == "/work/app") // same lamb, same pasture
        #expect(s.repoName == "app")
        #expect(s.terminalPid == 9)
        #expect(s.agentPid == 4242)
        #expect(s.startedMs == started)
        #expect(s.phaseSinceMs == fold.now)

        #expect(fold.state.sessions.keys.sorted() == ["s2"])
        #expect(fold.state.recentlyCleared.isEmpty)
    }

    @Test func aRekeyedLambKeepsWorkingUnderTheNewId() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send(IngestFixtures.hook("SessionEnd", reason: "clear"))
        fold.send(IngestFixtures.hook("SessionStart", session: "s2", source: "clear"))
        let change = fold.send("UserPromptSubmit", session: "s2")[0]
        #expect(change.beat == nil)
        #expect(change.previousId == nil)
        #expect(change.session.phase == .working)
        // the old id is gone for good
        #expect(fold.send("Stop", session: "s1").first?.beat == .arrived)
    }

    @Test func theClearMatchesOnCwdWhenPidsAreMissing() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("SessionStart", pid: nil))
        fold.send(IngestFixtures.hook("SessionEnd", reason: "clear", pid: nil))
        let hit = fold.send(IngestFixtures.hook("SessionStart", session: "s2", source: "clear", pid: nil))
        #expect(hit.first?.beat == .cleared)

        var other = IngestFold()
        other.send(IngestFixtures.hook("SessionStart", pid: nil))
        other.send(IngestFixtures.hook("SessionEnd", reason: "clear", pid: nil))
        let miss = other.send(IngestFixtures.hook("SessionStart", session: "s2", cwd: "/elsewhere", source: "clear", pid: nil))
        #expect(miss.first?.beat == .arrived)
        #expect(other.state.recentlyCleared.count == 1)
    }

    @Test func oneSidedPidFallsBackToCwd() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("SessionStart", pid: nil))
        fold.send(IngestFixtures.hook("SessionEnd", reason: "clear", pid: nil))
        let change = fold.send(IngestFixtures.hook("SessionStart", session: "s2", source: "clear", pid: 55))
        #expect(change.first?.beat == .cleared)
        #expect(change.first?.session.agentPid == 55)
    }

    @Test func aClearFromAnotherProcessIsNotRekeyed() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("SessionStart", pid: 100))
        fold.send(IngestFixtures.hook("SessionEnd", reason: "clear", pid: 100))
        // same directory, different `claude` process: a new lamb
        let change = fold.send(IngestFixtures.hook("SessionStart", session: "s2", source: "clear", pid: 200))
        #expect(change.first?.beat == .arrived)
        #expect(fold.state.sessions.keys.sorted() == ["s2"])
        #expect(fold.state.recentlyCleared.count == 1)
    }

    @Test func aClearDoesNotRekeyAfterTenSeconds() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send(IngestFixtures.hook("SessionEnd", reason: "clear"), advanceMs: 1000)
        let late = fold.send(IngestFixtures.hook("SessionStart", session: "s2", source: "clear"), advanceMs: 10_001)
        #expect(late.first?.beat == .arrived)
        #expect(late.first?.previousId == nil)
        #expect(fold.state.recentlyCleared.count == 1)
    }

    @Test func aClearRekeysUpToTheTenSecondMark() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send(IngestFixtures.hook("SessionEnd", reason: "clear"), advanceMs: 1000)
        let change = fold.send(IngestFixtures.hook("SessionStart", session: "s2", source: "clear"), advanceMs: 10_000)
        #expect(change.first?.beat == .cleared)
    }

    @Test func aPlainSessionStartNeverClaimsAClearedLamb() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send(IngestFixtures.hook("SessionEnd", reason: "clear"))
        for source in ["startup", "resume", "compact", nil] as [String?] {
            var copy = fold
            let change = copy.send(IngestFixtures.hook("SessionStart", session: "s2", source: source))
            #expect(change.first?.beat == .arrived, "\(String(describing: source))")
        }
    }

    @Test func theNextClearBelongsToTheMostRecentCandidate() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("SessionStart", session: "a", pid: 100))
        fold.send(IngestFixtures.hook("SessionStart", session: "b", pid: 100))
        fold.send(IngestFixtures.hook("SessionEnd", session: "a", reason: "clear", pid: 100))
        fold.send(IngestFixtures.hook("SessionEnd", session: "b", reason: "clear", pid: 100))
        let change = fold.send(IngestFixtures.hook("SessionStart", session: "c", source: "clear", pid: 100))[0]
        #expect(change.previousId == "b")
        #expect(fold.state.recentlyCleared.map(\.id) == ["a"])
    }

    @Test func anExpiredClearDepartsOnTheNextSweepAndOnlyOnce() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send("UserPromptSubmit")
        fold.send(IngestFixtures.hook("SessionEnd", reason: "clear"))

        // still inside the window: the sweep leaves it alone
        let early = HerdReducer.sweep(&fold.state, nowMs: fold.now + 9000, isAlive: { _ in true }, transcriptActivityMs: { _ in nil })
        #expect(early.isEmpty)
        #expect(fold.state.recentlyCleared.count == 1)

        let swept = HerdReducer.sweep(&fold.state, nowMs: fold.now + 10_500, isAlive: { _ in true }, transcriptActivityMs: { _ in nil })
        #expect(swept.count == 1)
        #expect(swept[0].beat == .departed)
        #expect(swept[0].session.id == "s1")
        #expect(swept[0].session.phase == .ended)
        #expect(swept[0].previousPhase == .working)
        #expect(fold.state.recentlyCleared.isEmpty)

        let again = HerdReducer.sweep(&fold.state, nowMs: fold.now + 30_000, isAlive: { _ in true }, transcriptActivityMs: { _ in nil })
        #expect(again.isEmpty)
    }

    @Test func lateEventsForAClearedIdAreIgnored() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send(IngestFixtures.hook("SessionEnd", reason: "clear"))
        // hooks are async: a Stop from before the clear can arrive after it
        #expect(fold.send("Stop").isEmpty)
        #expect(fold.send("PostToolUse", tool: "Bash").isEmpty)
        #expect(fold.state.sessions.isEmpty)
        #expect(fold.state.recentlyCleared.count == 1)
    }

    @Test func aRealEndOfAClearedIdDepartsAtOnce() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send(IngestFixtures.hook("SessionEnd", reason: "clear"))
        let changes = fold.send(IngestFixtures.hook("SessionEnd", reason: "logout"))
        #expect(changes.first?.beat == .departed)
        #expect(fold.state.recentlyCleared.isEmpty)
        // a second clear for the same pending id changes nothing
        var again = IngestFold()
        again.send("SessionStart")
        again.send(IngestFixtures.hook("SessionEnd", reason: "clear"))
        #expect(again.send(IngestFixtures.hook("SessionEnd", reason: "clear")).isEmpty)
        #expect(again.state.recentlyCleared.count == 1)
    }

    @Test func aSessionStartForAClearedIdBringsItBack() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send("UserPromptSubmit")
        fold.send(IngestFixtures.hook("SessionEnd", reason: "clear"))
        let change = fold.send(IngestFixtures.hook("SessionStart", source: "resume"))[0]
        #expect(change.beat == nil) // the lamb never left
        #expect(change.session.id == "s1")
        #expect(fold.state.recentlyCleared.isEmpty)
        #expect(fold.state.sessions.count == 1)
    }

    @Test func clearSourceForAKnownIdIsAnOrdinaryStart() {
        var fold = IngestFold()
        fold.send("SessionStart")
        fold.send("UserPromptSubmit")
        let change = fold.send(IngestFixtures.hook("SessionStart", source: "clear"))[0]
        #expect(change.beat == nil)
        #expect(change.previousId == nil)
        #expect(change.session.phase == .idle)
    }

    // MARK: sweep

    private func sweep(
        _ fold: inout IngestFold, atMs now: Double, dead: Set<Int32> = [], growth: [String: Double] = [:]
    ) -> [HerdChange] {
        HerdReducer.sweep(
            &fold.state, nowMs: now, isAlive: { !dead.contains($0) }, transcriptActivityMs: { growth[$0] })
    }

    @Test func aSessionWhoseProcessIsGoneDeparts() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("SessionStart", pid: 100))
        fold.send(IngestFixtures.hook("SessionStart", session: "s2", pid: 200))
        fold.send("UserPromptSubmit", session: "s2")

        let changes = sweep(&fold, atMs: fold.now + 1000, dead: [200])
        #expect(changes.count == 1)
        #expect(changes[0].session.id == "s2")
        #expect(changes[0].session.phase == .ended)
        #expect(changes[0].beat == .departed)
        #expect(changes[0].previousPhase == .working)
        #expect(fold.state.sessions.keys.sorted() == ["s1"])
    }

    @Test func aSessionWithoutAPidIsNotKilledByLiveness() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("SessionStart", pid: nil))
        #expect(sweep(&fold, atMs: fold.now + 60_000, dead: [0, 4242]).isEmpty)
        #expect(fold.state.sessions.count == 1)
    }

    @Test func fortyFiveMinutesOfSilenceEndsTheSession() {
        var fold = IngestFold()
        fold.send("SessionStart")
        let silent = 45.0 * 60_000
        #expect(sweep(&fold, atMs: fold.now + silent - 1).isEmpty)
        let changes = sweep(&fold, atMs: fold.now + silent)
        #expect(changes.count == 1)
        #expect(changes[0].beat == .departed)
        #expect(changes[0].session.phase == .ended)
        #expect(fold.state.sessions.isEmpty)
    }

    @Test func silenceWithoutAPidAlsoEndsTheSession() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("SessionStart", pid: nil))
        #expect(sweep(&fold, atMs: fold.now + 46 * 60_000).first?.beat == .departed)
    }

    @Test func transcriptGrowthCountsAsActivity() {
        var fold = IngestFold()
        fold.send("SessionStart")
        let start = fold.now
        // the file grew 5 minutes ago: not silent
        let changes = sweep(&fold, atMs: start + 50 * 60_000, growth: ["s1": start + 45 * 60_000])
        #expect(changes.isEmpty)
        #expect(fold.state.sessions.count == 1)
        // growth for another session doesn't help
        #expect(sweep(&fold, atMs: start + 50 * 60_000, growth: ["other": start + 49 * 60_000]).count == 1)
    }

    @Test func aQuietWorkingSessionGoesIdleAfterTenMinutes() {
        var fold = IngestFold()
        fold.send("UserPromptSubmit")
        fold.send("PreToolUse", tool: "Bash")
        let last = fold.s1!.lastEventMs
        #expect(sweep(&fold, atMs: last + 10 * 60_000 - 1).isEmpty)

        let at = last + 10 * 60_000
        let changes = sweep(&fold, atMs: at)
        #expect(changes.count == 1)
        #expect(changes[0].previousPhase == .working)
        #expect(changes[0].session.phase == .idle)
        #expect(changes[0].session.tool == .thinking)
        #expect(changes[0].session.phaseSinceMs == at)
        #expect(changes[0].beat == nil)
        // it stays known, and the activity clock is not reset by the sweep
        #expect(fold.s1?.phase == .idle)
        #expect(fold.s1?.lastEventMs == last)
        #expect(sweep(&fold, atMs: at + 10_000).isEmpty)
    }

    @Test func transcriptGrowthKeepsAWorkingSessionWorking() {
        var fold = IngestFold()
        fold.send("UserPromptSubmit")
        let last = fold.s1!.lastEventMs
        let changes = sweep(&fold, atMs: last + 11 * 60_000, growth: ["s1": last + 10 * 60_000])
        #expect(changes.isEmpty)
        #expect(fold.s1?.phase == .working)
    }

    @Test func onlyWorkingSessionsGoStale() {
        var fold = IngestFold()
        fold.send("PermissionRequest", tool: "Bash")
        fold.send("Stop", session: "idle")
        let changes = sweep(&fold, atMs: fold.now + 20 * 60_000)
        #expect(changes.isEmpty)
        #expect(fold.s1?.phase == .waiting)
        #expect(fold.state.sessions["idle"]?.phase == .idle)
    }

    @Test func deadProcessWinsOverStaleness() {
        var fold = IngestFold()
        fold.send("UserPromptSubmit")
        let changes = sweep(&fold, atMs: fold.now + 11 * 60_000, dead: [4242])
        #expect(changes.map(\.beat) == [.departed])
    }

    @Test func sweepReportsSessionsOldestFirst() {
        var fold = IngestFold()
        fold.send(IngestFixtures.hook("SessionStart", session: "late", pid: 3), advanceMs: 0)
        fold.send(IngestFixtures.hook("SessionStart", session: "early", pid: 3), advanceMs: -5000)
        fold.send(IngestFixtures.hook("SessionStart", session: "mid", pid: 3), advanceMs: 2000)
        let changes = sweep(&fold, atMs: fold.now + 1000, dead: [3])
        #expect(changes.map(\.session.id) == ["early", "mid", "late"])
        #expect(fold.state.sessions.isEmpty)
    }

    // MARK: transcript

    private func started() -> IngestFold {
        var fold = IngestFold()
        fold.send("SessionStart")
        return fold
    }

    @Test func transcriptTokensAccumulateAndTheTitleIsSet() {
        var fold = started()
        let change = HerdReducer.applyTranscript(
            &fold.state, sessionId: "s1", update: TranscriptUpdate(tokensDelta: 1200, title: "Fix login"), nowMs: fold.now + 1)
        #expect(change?.session.tokens == 1200)
        #expect(change?.session.title == "Fix login")
        #expect(change?.previousPhase == .idle)
        #expect(change?.beat == nil)
        #expect(change?.previousId == nil)

        let more = HerdReducer.applyTranscript(
            &fold.state, sessionId: "s1", update: TranscriptUpdate(tokensDelta: 300), nowMs: fold.now + 2)
        #expect(more?.session.tokens == 1500)
        #expect(more?.session.title == "Fix login")
        #expect(fold.s1?.tokens == 1500)
    }

    @Test func aTranscriptUpdateThatChangesNothingReturnsNil() {
        var fold = started()
        #expect(HerdReducer.applyTranscript(&fold.state, sessionId: "s1", update: TranscriptUpdate(), nowMs: 1) == nil)
        _ = HerdReducer.applyTranscript(&fold.state, sessionId: "s1", update: TranscriptUpdate(title: "Same"), nowMs: 1)
        #expect(HerdReducer.applyTranscript(&fold.state, sessionId: "s1", update: TranscriptUpdate(title: "Same"), nowMs: 2) == nil)
        // growth alone is the sweep's business, not a change
        #expect(HerdReducer.applyTranscript(&fold.state, sessionId: "s1", update: TranscriptUpdate(grewAtMs: 5), nowMs: 3) == nil)
        // an interrupt of an idle lamb has nothing to interrupt
        #expect(HerdReducer.applyTranscript(&fold.state, sessionId: "s1", update: TranscriptUpdate(interrupted: true), nowMs: 4) == nil)
    }

    @Test func aTranscriptUpdateForAnUnknownSessionIsDropped() {
        var state = HerdState()
        #expect(HerdReducer.applyTranscript(&state, sessionId: "nope", update: TranscriptUpdate(tokensDelta: 5), nowMs: 1) == nil)
        #expect(state.sessions.isEmpty)
    }

    @Test func anInterruptReturnsAWorkingLambToIdle() {
        var fold = started()
        fold.send("UserPromptSubmit")
        fold.send("PreToolUse", tool: "Bash")
        let at = fold.now + 500
        let change = HerdReducer.applyTranscript(
            &fold.state, sessionId: "s1", update: TranscriptUpdate(interrupted: true), nowMs: at)
        #expect(change?.session.phase == .idle)
        #expect(change?.session.tool == .thinking)
        #expect(change?.session.phaseSinceMs == at)
        #expect(change?.previousPhase == .working)
        #expect(change?.beat == .interrupted)
        #expect(fold.s1?.phase == .idle)
    }

    @Test func anInterruptAlsoClearsAnAbandonedPrompt() {
        var fold = started()
        fold.send("PermissionRequest", tool: "Bash")
        let change = HerdReducer.applyTranscript(
            &fold.state, sessionId: "s1", update: TranscriptUpdate(interrupted: true), nowMs: fold.now + 1)
        #expect(change?.session.phase == .idle)
        #expect(change?.session.waitingFor == nil)
        #expect(change?.beat == .interrupted)
    }

    @Test func tokensAndTitleStillLandWithAnInterrupt() {
        var fold = started()
        fold.send("UserPromptSubmit")
        let change = HerdReducer.applyTranscript(
            &fold.state, sessionId: "s1", update: TranscriptUpdate(tokensDelta: 10, title: "T", interrupted: true), nowMs: fold.now + 1)
        #expect(change?.session.tokens == 10)
        #expect(change?.session.title == "T")
        #expect(change?.beat == .interrupted)
    }

    @Test func transcriptFoldsLeaveTheActivityClockAlone() {
        var fold = started()
        let last = fold.s1!.lastEventMs
        _ = HerdReducer.applyTranscript(&fold.state, sessionId: "s1", update: TranscriptUpdate(tokensDelta: 9), nowMs: last + 99_999)
        #expect(fold.s1?.lastEventMs == last)
    }
}

import Foundation
import Synchronization
import Testing
@testable import CoSheepKit

/// In-memory transcript files behind a `TranscriptReader`, using the real
/// cursor, so the store is exercised without touching disk.
private nonisolated final class FakeFiles: Sendable {
    private struct State {
        var files: [String: Data] = [:]
        var reads: [String] = []
        var hook: (@Sendable () async -> Void)?
    }

    private let state = Mutex(State())

    func write(_ path: String, _ lines: [String]) {
        state.withLock { $0.files[path] = IngestFixtures.file(lines) }
    }

    func append(_ path: String, _ lines: [String]) {
        state.withLock { $0.files[path, default: Data()].append(IngestFixtures.file(lines)) }
    }

    var reads: [String] { state.withLock { $0.reads } }

    func setHook(_ hook: (@Sendable () async -> Void)?) {
        state.withLock { $0.hook = hook }
    }

    var reader: TranscriptReader {
        { [self] path, cursor, nowMs in
            if let hook = state.withLock({ $0.hook }) { await hook() }
            return state.withLock { s in
                s.reads.append(path)
                var cursor = cursor
                guard let data = s.files[path], data.count > cursor.offset else {
                    return TranscriptRead(cursor: cursor, update: nil)
                }
                var update = cursor.consume(data.suffix(from: cursor.offset))
                update.grewAtMs = nowMs
                return TranscriptRead(cursor: cursor, update: update)
            }
        }
    }
}

private final class TestClock {
    var ms = 1_700_000_000_000.0
    func advance(minutes: Double) { ms += minutes * 60_000 }
    func advance(seconds: Double) { ms += seconds * 1000 }
}

private final class Calls {
    var repo: [String] = []
    var terminal: [Int32] = []
}

@Suite("herd store")
struct HerdStoreTests {
    private typealias F = IngestFixtures

    private struct Rig {
        let store: HerdStore
        let events: AppEvents
        let clock: TestClock
        let files: FakeFiles
        let calls: Calls
        let changes: ChangeLog
        let dead: DeadPids
    }

    private final class ChangeLog {
        var all: [HerdChange] = []
        var beats: [HerdBeat?] { all.map(\.beat) }
        var last: HerdChange? { all.last }
    }

    private final class DeadPids {
        var pids: Set<Int32> = []
    }

    private func makeRig(
        terminal: @escaping (Int32) -> Int32? = { $0 + 1000 }, transcriptInterval: Double = 3600, sweepInterval: Double = 3600
    ) -> Rig {
        let events = AppEvents()
        let clock = TestClock()
        let files = FakeFiles()
        let calls = Calls()
        let dead = DeadPids()
        let log = ChangeLog()
        events.herd.on { log.all.append($0) }
        let store = HerdStore(
            events: events,
            now: { clock.ms },
            isAlive: { !dead.pids.contains($0) },
            readTranscript: files.reader,
            findTerminal: { pid in calls.terminal.append(pid); return terminal(pid) },
            findRepo: { cwd in calls.repo.append(cwd); return (cwd, (cwd as NSString).lastPathComponent) },
            acceptsTranscript: { _, _ in true },
            transcriptInterval: transcriptInterval,
            sweepInterval: sweepInterval)
        return Rig(store: store, events: events, clock: clock, files: files, calls: calls, changes: log, dead: dead)
    }

    // MARK: publishing

    @Test func everyFoldIsPublishedInOrder() {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart"))
        rig.store.ingest(F.hook("UserPromptSubmit"))
        rig.store.ingest(F.hook("Stop"))
        rig.store.ingest(F.hook("SessionEnd", reason: "logout"))
        #expect(rig.changes.beats == [.arrived, nil, .turnDone, .departed])
        #expect(rig.changes.all.map(\.session.phase) == [.idle, .working, .idle, .ended])
        #expect(rig.store.sessions.isEmpty)
    }

    @Test func ignoredEventsPublishNothing() {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionEnd", session: "ghost", reason: "other"))
        rig.store.ingest(F.hook("FileChanged"))
        rig.store.ingest(F.hook("SubagentStop", agentType: ""))
        #expect(rig.changes.all.isEmpty)
        #expect(rig.store.sessions.isEmpty)
    }

    @Test func sessionsComeBackOldestFirst() {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", session: "b"))
        rig.clock.advance(seconds: 5)
        rig.store.ingest(F.hook("SessionStart", session: "a"))
        rig.clock.advance(seconds: 5)
        rig.store.ingest(F.hook("SessionStart", session: "c"))
        #expect(rig.store.sessions.map(\.id) == ["b", "a", "c"])
    }

    @Test func theSharedStoreIsOneInstance() {
        #expect(HerdStore.shared === HerdStore.shared)
        #expect(!HerdStore.shared.isRunning)
    }

    // MARK: repo and terminal

    @Test func theRepoIsResolvedOncePerCwdAndPublishedWithTheFirstChange() {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", session: "a", cwd: "/work/app"))
        rig.store.ingest(F.hook("SessionStart", session: "b", cwd: "/work/app"))
        rig.store.ingest(F.hook("UserPromptSubmit", session: "a", cwd: "/work/app"))
        rig.store.ingest(F.hook("SessionStart", session: "c", cwd: "/work/other"))
        #expect(rig.calls.repo == ["/work/app", "/work/other"])

        let first = rig.changes.all[0].session
        #expect(first.repoKey == "/work/app")
        #expect(first.repoName == "app")
        #expect(rig.store.sessions.first { $0.id == "a" }?.repoName == "app")
        #expect(rig.store.sessions.first { $0.id == "c" }?.repoName == "other")
    }

    @Test func aSessionWithoutACwdHasNoRepoUntilOneShowsUp() {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", cwd: nil))
        #expect(rig.changes.all[0].session.repoKey == nil)
        #expect(rig.calls.repo.isEmpty)
        rig.store.ingest(F.hook("UserPromptSubmit", cwd: "/late/project"))
        #expect(rig.changes.all[1].session.repoName == "project")
        #expect(rig.store.sessions[0].repoKey == "/late/project")
    }

    @Test func theTerminalIsResolvedOncePerAgentPid() {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", session: "a", pid: 100))
        rig.store.ingest(F.hook("UserPromptSubmit", session: "a", pid: 100))
        rig.store.ingest(F.hook("SessionStart", session: "b", pid: 100)) // same claude process
        rig.store.ingest(F.hook("SessionStart", session: "c", pid: 200))
        #expect(rig.calls.terminal == [100, 200])
        #expect(rig.changes.all[0].session.terminalPid == 1100)
        #expect(rig.store.sessions.first { $0.id == "b" }?.terminalPid == 1100)
        #expect(rig.store.sessions.first { $0.id == "c" }?.terminalPid == 1200)
    }

    @Test func aTerminalThatWasNotFoundIsNotLookedForAgain() {
        let rig = makeRig(terminal: { _ in nil })
        for name in ["SessionStart", "UserPromptSubmit", "Stop"] {
            rig.store.ingest(F.hook(name, pid: 300))
        }
        #expect(rig.calls.terminal == [300])
        #expect(rig.store.sessions[0].terminalPid == nil)
    }

    @Test func aRestartedProcessGetsItsTerminalLookedUpAgain() {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", pid: 100))
        rig.store.ingest(F.hook("SessionStart", source: "resume", pid: 200))
        #expect(rig.calls.terminal == [100, 200])
        #expect(rig.store.sessions[0].terminalPid == 1200)
    }

    @Test func aSessionWithoutAPidNeverLooksForATerminal() {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", pid: nil))
        #expect(rig.calls.terminal.isEmpty)
    }

    // MARK: transcripts

    @Test func newTranscriptBytesBecomeTokensAndATitle() async {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", transcript: "/t/a.jsonl"))
        rig.files.write("/t/a.jsonl", [F.assistant(id: "m1", input: 10, cacheRead: 90, output: 5), F.title("Tidy the pasture")])
        rig.changes.all.removeAll()

        await rig.store.pollTranscripts()
        #expect(rig.changes.all.count == 1)
        #expect(rig.changes.last?.session.tokens == 105)
        #expect(rig.changes.last?.session.title == "Tidy the pasture")
        #expect(rig.changes.last?.previousPhase == .idle)
        #expect(rig.store.sessions[0].tokens == 105)

        // nothing new: nothing published
        await rig.store.pollTranscripts()
        #expect(rig.changes.all.count == 1)

        rig.files.append("/t/a.jsonl", [F.assistant(id: "m1", input: 10, cacheRead: 90, output: 5), F.assistant(id: "m2", output: 20)])
        await rig.store.pollTranscripts()
        #expect(rig.changes.all.count == 2)
        #expect(rig.store.sessions[0].tokens == 125)
        #expect(rig.files.reads == ["/t/a.jsonl", "/t/a.jsonl", "/t/a.jsonl"])
    }

    @Test func aSessionIsOnlyTailedOnceItHasATranscriptPath() async {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", transcript: nil))
        await rig.store.pollTranscripts()
        #expect(rig.files.reads.isEmpty)

        rig.files.write("/t/late.jsonl", [F.assistant(id: "m1", output: 7)])
        rig.store.ingest(F.hook("UserPromptSubmit", transcript: "/t/late.jsonl"))
        await rig.store.pollTranscripts()
        #expect(rig.files.reads == ["/t/late.jsonl"])
        #expect(rig.store.sessions[0].tokens == 7)
    }

    @Test func eachSessionIsTailedFromItsOwnFile() async {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", session: "a", transcript: "/t/a.jsonl"))
        rig.store.ingest(F.hook("SessionStart", session: "b", transcript: "/t/b.jsonl"))
        rig.files.write("/t/a.jsonl", [F.assistant(id: "m1", output: 1)])
        rig.files.write("/t/b.jsonl", [F.assistant(id: "m1", output: 2), F.assistant(id: "m2", output: 3)])
        await rig.store.pollTranscripts()
        #expect(rig.store.sessions.first { $0.id == "a" }?.tokens == 1)
        #expect(rig.store.sessions.first { $0.id == "b" }?.tokens == 5)
    }

    @Test func anInterruptInHistoryIsIgnoredButALiveOneReturnsTheLambToIdle() async {
        let rig = makeRig()
        rig.files.write("/t/a.jsonl", [F.assistant(id: "m1", output: 1), F.userBlocks("[Request interrupted by user]")])
        rig.store.ingest(F.hook("UserPromptSubmit", transcript: "/t/a.jsonl"))

        await rig.store.pollTranscripts() // the replay of the file as it was
        #expect(rig.store.sessions[0].phase == .working)

        rig.files.append("/t/a.jsonl", [F.userString("go on"), F.assistant(id: "m2", output: 1), F.userBlocks("[Request interrupted by user for tool use]")])
        await rig.store.pollTranscripts()
        #expect(rig.store.sessions[0].phase == .idle)
        #expect(rig.changes.last?.beat == .interrupted)
        #expect(rig.changes.last?.previousPhase == .working)
    }

    @Test func aDepartedSessionIsNoLongerTailed() async {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", transcript: "/t/a.jsonl"))
        rig.store.ingest(F.hook("SessionEnd", reason: "logout"))
        rig.files.write("/t/a.jsonl", [F.assistant(id: "m1", output: 1)])
        await rig.store.pollTranscripts()
        #expect(rig.files.reads.isEmpty)
    }

    @Test func aClearMovesTheTailToTheNewConversation() async {
        let rig = makeRig()
        rig.files.write("/t/old.jsonl", [F.assistant(id: "m1", output: 500)])
        rig.store.ingest(F.hook("SessionStart", session: "old", transcript: "/t/old.jsonl"))
        await rig.store.pollTranscripts()
        #expect(rig.store.sessions[0].tokens == 500)

        rig.store.ingest(F.hook("SessionEnd", session: "old", reason: "clear"))
        rig.store.ingest(F.hook("SessionStart", session: "new", transcript: "/t/new.jsonl", source: "clear"))
        #expect(rig.changes.last?.beat == .cleared)
        #expect(rig.changes.last?.previousId == "old")

        rig.files.write("/t/new.jsonl", [F.assistant(id: "n1", output: 9)])
        rig.files.append("/t/old.jsonl", [F.assistant(id: "m2", output: 1000)])
        let readsBefore = rig.files.reads.count
        await rig.store.pollTranscripts()
        #expect(rig.files.reads.suffix(from: readsBefore) == ["/t/new.jsonl"])
        #expect(rig.store.sessions.map(\.id) == ["new"])
        #expect(rig.store.sessions[0].tokens == 9)
    }

    @Test func aReadThatFinishesAfterTheSessionLeftIsDiscarded() async {
        let rig = makeRig()
        rig.files.write("/t/a.jsonl", [F.assistant(id: "m1", output: 40)])
        rig.store.ingest(F.hook("SessionStart", transcript: "/t/a.jsonl"))
        rig.changes.all.removeAll()

        let (started, signalStarted) = AsyncStream.makeStream(of: Void.self)
        let (proceed, letItFinish) = AsyncStream.makeStream(of: Void.self)
        rig.files.setHook {
            signalStarted.yield()
            for await _ in proceed { break }
        }
        let poll = Task { await rig.store.pollTranscripts() }
        for await _ in started { break }
        rig.store.ingest(F.hook("SessionEnd", reason: "logout"))
        rig.files.setHook(nil)
        letItFinish.yield()
        await poll.value

        #expect(rig.changes.beats == [.departed])
        #expect(rig.store.sessions.isEmpty)
    }

    @Test func aReadThatFinishesAfterTheTailWasReplacedIsDiscarded() async {
        let rig = makeRig()
        rig.files.write("/t/a.jsonl", [F.assistant(id: "m1", output: 40)])
        rig.store.ingest(F.hook("SessionStart", transcript: "/t/a.jsonl"))

        let (started, signalStarted) = AsyncStream.makeStream(of: Void.self)
        let (proceed, letItFinish) = AsyncStream.makeStream(of: Void.self)
        rig.files.setHook {
            signalStarted.yield()
            for await _ in proceed { break }
        }
        let poll = Task { await rig.store.pollTranscripts() }
        for await _ in started { break }
        // /clear and a new conversation under another id while the old read is in flight
        rig.store.ingest(F.hook("SessionEnd", reason: "clear"))
        rig.store.ingest(F.hook("SessionStart", session: "s2", transcript: "/t/b.jsonl", source: "clear"))
        rig.files.setHook(nil)
        letItFinish.yield()
        await poll.value

        #expect(rig.store.sessions.map(\.id) == ["s2"])
        #expect(rig.store.sessions[0].tokens == 0)
    }

    // MARK: liveness

    @Test func theSweepRetiresASessionWhoseProcessIsGone() {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", session: "a", pid: 100))
        rig.store.ingest(F.hook("SessionStart", session: "b", pid: 200))
        rig.changes.all.removeAll()

        rig.clock.advance(seconds: 10)
        rig.store.sweep()
        #expect(rig.changes.all.isEmpty)

        rig.dead.pids = [200]
        rig.clock.advance(seconds: 10)
        rig.store.sweep()
        #expect(rig.changes.beats == [.departed])
        #expect(rig.changes.last?.session.id == "b")
        #expect(rig.store.sessions.map(\.id) == ["a"])
    }

    @Test func silenceEndsASessionAfterFortyFiveMinutes() {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart"))
        rig.clock.advance(minutes: 44)
        rig.store.sweep()
        #expect(rig.store.sessions.count == 1)
        rig.clock.advance(minutes: 2)
        rig.store.sweep()
        #expect(rig.store.sessions.isEmpty)
        #expect(rig.changes.last?.beat == .departed)
    }

    @Test func aGrowingTranscriptKeepsASilentSessionAlive() async {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", transcript: "/t/a.jsonl"))
        rig.files.write("/t/a.jsonl", [F.assistant(id: "m1", output: 1)])

        rig.clock.advance(minutes: 30)
        await rig.store.pollTranscripts() // growth at +30 min
        rig.clock.advance(minutes: 30)    // +60 min since the last hook, 30 since the file grew
        rig.store.sweep()
        #expect(rig.store.sessions.count == 1)

        rig.clock.advance(minutes: 20)    // 50 min since the file grew
        rig.store.sweep()
        #expect(rig.store.sessions.isEmpty)
    }

    @Test func aSessionThatDepartsStopsBeingTailedAndForgotten() async {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart", transcript: "/t/a.jsonl", pid: 100))
        rig.files.write("/t/a.jsonl", [F.assistant(id: "m1", output: 1)])
        await rig.store.pollTranscripts()
        let reads = rig.files.reads.count

        rig.dead.pids = [100]
        rig.store.sweep()
        await rig.store.pollTranscripts()
        #expect(rig.files.reads.count == reads)
        #expect(rig.store.sessions.isEmpty)
    }

    @Test func anUnclaimedClearDepartsOnTheSweep() {
        let rig = makeRig()
        rig.store.ingest(F.hook("SessionStart"))
        rig.store.ingest(F.hook("SessionEnd", reason: "clear"))
        #expect(rig.changes.beats == [.arrived])
        rig.clock.advance(seconds: 5)
        rig.store.sweep()
        #expect(rig.changes.beats == [.arrived])
        rig.clock.advance(seconds: 10)
        rig.store.sweep()
        #expect(rig.changes.beats == [.arrived, .departed])
        #expect(rig.changes.last?.session.repoName == "app") // enriched when it arrived
    }

    @Test func aQuietWorkingSessionIsPutToSleepBySweep() {
        let rig = makeRig()
        rig.store.ingest(F.hook("UserPromptSubmit"))
        rig.clock.advance(minutes: 11)
        rig.store.sweep()
        #expect(rig.store.sessions[0].phase == .idle)
        #expect(rig.changes.last?.previousPhase == .working)
    }

    // MARK: loops

    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test func startAndStopToggleTheLoops() {
        let rig = makeRig()
        #expect(!rig.store.isRunning)
        rig.store.start()
        #expect(rig.store.isRunning)
        rig.store.start() // idempotent
        #expect(rig.store.isRunning)
        rig.store.stop()
        #expect(!rig.store.isRunning)
        rig.store.stop()
        rig.store.start()
        #expect(rig.store.isRunning)
        rig.store.stop()
    }

    @Test func theTranscriptLoopPollsOnItsOwn() async {
        let rig = makeRig(transcriptInterval: 0.01)
        rig.files.write("/t/a.jsonl", [F.assistant(id: "m1", output: 33)])
        rig.store.ingest(F.hook("SessionStart", transcript: "/t/a.jsonl"))
        rig.store.start()
        defer { rig.store.stop() }
        let arrived = await eventually { rig.store.sessions.first?.tokens == 33 }
        #expect(arrived)
    }

    @Test func theSweepLoopRetiresDeadSessionsOnItsOwn() async {
        let rig = makeRig(sweepInterval: 0.01)
        rig.store.ingest(F.hook("SessionStart", pid: 100))
        rig.dead.pids = [100]
        rig.store.start()
        defer { rig.store.stop() }
        let gone = await eventually { rig.store.sessions.isEmpty }
        #expect(gone)
        #expect(rig.changes.last?.beat == .departed)
    }

    @Test func stoppingEndsThePolling() async {
        let rig = makeRig(transcriptInterval: 0.005)
        rig.store.ingest(F.hook("SessionStart", transcript: "/t/a.jsonl"))
        rig.store.start()
        let polling = await eventually { rig.files.reads.count >= 2 }
        #expect(polling)
        rig.store.stop()
        // let a pass that was already in flight finish, however slowly
        var settled = -1
        while settled != rig.files.reads.count {
            settled = rig.files.reads.count
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.files.reads.count == settled)
    }
}

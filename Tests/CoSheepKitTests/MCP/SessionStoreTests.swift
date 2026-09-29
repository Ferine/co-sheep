import Testing
@testable import CoSheepKit

// Ex-mcp.rs tests (the first nine are the Rust #[test]s, same assertions).
@Suite("mcp session reducer")
struct SessionStoreTests {
    @Test func beginMarksActiveAndGood() {
        var s = SessionState()
        let ev = SessionReducer.apply(&s, .begin(task: "wire mpls"))
        #expect(s.active)
        #expect(s.task == "wire mpls")
        #expect(s.health == .good)
        #expect(ev.kind == "begin")
        #expect(ev.health == "good")
    }

    @Test func milestoneFailedSetsFailing() {
        var s = SessionState()
        _ = SessionReducer.apply(&s, .begin(task: nil))
        let ev = SessionReducer.apply(&s, .milestone(kind: "failed", detail: "3 tests"))
        #expect(s.health == .failing)
        #expect(ev.milestone == "failed")
        #expect(ev.health == "failing")
    }

    @Test func milestoneDoneRecoversToGood() {
        var s = SessionState(active: true, health: .failing)
        _ = SessionReducer.apply(&s, .milestone(kind: "done", detail: nil))
        #expect(s.health == .good)
    }

    @Test func blockedIsDegraded() {
        var s = SessionState()
        _ = SessionReducer.apply(&s, .milestone(kind: "blocked", detail: nil))
        #expect(s.health == .degraded)
    }

    @Test func progressIsClampedAndRecorded() {
        var s = SessionState()
        let ev = SessionReducer.apply(&s, .progress(fraction: 1.7))
        #expect(s.progress == 1.0)
        #expect(ev.progress == 1.0)
        _ = SessionReducer.apply(&s, .progress(fraction: -0.2))
        #expect(s.progress == 0.0)
    }

    @Test func endDeactivates() {
        var s = SessionState(active: true)
        let ev = SessionReducer.apply(&s, .end(summary: nil))
        #expect(!s.active)
        #expect(ev.kind == "end")
    }

    @Test func truncateRespectsCharBoundary() {
        let s = String(repeating: "æøå", count: 400) // 1200 chars
        let t = SessionReducer.truncate(s, 500)
        #expect(t.unicodeScalars.count <= 500)
        #expect(s.hasPrefix(t))
    }

    @Test func authOpenWhenNoToken() {
        #expect(SessionReducer.checkAuth(nil, expected: ""))
        #expect(SessionReducer.checkAuth("anything", expected: ""))
    }

    @Test func authRequiresMatchingBearer() {
        #expect(SessionReducer.checkAuth("Bearer s3cret", expected: "s3cret"))
        #expect(!SessionReducer.checkAuth("Bearer wrong", expected: "s3cret"))
        #expect(!SessionReducer.checkAuth(nil, expected: "s3cret"))
    }

    // MARK: - Adaptations and details the Rust tests did not pin down

    @Test func authIsExactAboutSchemeCaseAndLength() {
        #expect(!SessionReducer.checkAuth("bearer s3cret", expected: "s3cret"))
        #expect(!SessionReducer.checkAuth("Bearer s3cret ", expected: "s3cret"))
        #expect(!SessionReducer.checkAuth("Bearer s3cre", expected: "s3cret"))
        #expect(!SessionReducer.checkAuth("s3cret", expected: "s3cret"))
        #expect(!SessionReducer.checkAuth("", expected: "s3cret"))
    }

    @Test func truncateCountsScalarsLikeRustChars() {
        // "e" + combining acute is two Rust chars (one Swift Character).
        let s = "e\u{301}e\u{301}e\u{301}"
        #expect(SessionReducer.truncate(s, 4).unicodeScalars.count == 4)
        #expect(SessionReducer.truncate("abc", 3) == "abc")
        #expect(SessionReducer.truncate("abc", 2) == "ab")
        #expect(SessionReducer.truncate("", 5) == "")
    }

    @Test func clamp01Bounds() {
        #expect(SessionReducer.clamp01(0.25) == 0.25)
        #expect(SessionReducer.clamp01(-1) == 0)
        #expect(SessionReducer.clamp01(2) == 1)
    }

    @Test func taskAndDetailAreTruncatedTo500AndKindTo32() {
        var s = SessionState()
        let long = String(repeating: "x", count: 600)
        _ = SessionReducer.apply(&s, .begin(task: long))
        #expect(s.task?.count == 500)
        _ = SessionReducer.apply(&s, .task(label: long))
        #expect(s.task?.count == 500)
        let ev = SessionReducer.apply(&s, .milestone(kind: String(repeating: "k", count: 40), detail: long))
        #expect(ev.milestone?.count == 32)
        #expect(ev.detail?.count == 500)
        let end = SessionReducer.apply(&s, .end(summary: long))
        #expect(end.detail?.count == 500)
    }

    @Test func beginResetsProgressAndHealth() {
        var s = SessionState()
        _ = SessionReducer.apply(&s, .progress(fraction: 0.6))
        _ = SessionReducer.apply(&s, .milestone(kind: "failed", detail: nil))
        let ev = SessionReducer.apply(&s, .begin(task: nil))
        #expect(s.progress == nil)
        #expect(s.task == nil)
        #expect(s.health == .good)
        #expect(ev.progress == nil)
        #expect(ev.task == nil)
    }

    @Test func eventCarriesRunningTaskAndProgress() {
        var s = SessionState()
        _ = SessionReducer.apply(&s, .begin(task: "deploy"))
        _ = SessionReducer.apply(&s, .progress(fraction: 0.5))
        let ev = SessionReducer.apply(&s, .milestone(kind: "waiting_on_you", detail: "need the API key"))
        #expect(ev == SessionEvent(
            kind: "milestone", task: "deploy", progress: 0.5,
            milestone: "waiting_on_you", detail: "need the API key", health: "degraded"))
    }

    @Test func storeCommitAppliesAndEmits() {
        let events = AppEvents()
        let store = SessionStore(events: events)
        var seen: [SessionEvent] = []
        events.sheepSession.on { seen.append($0) }

        let first = store.commit(.begin(task: "port to swift"))
        store.commit(.progress(fraction: 0.5))

        #expect(store.state.active)
        #expect(store.state.progress == 0.5)
        #expect(seen.count == 2)
        #expect(seen[0] == first)
        #expect(seen[1].kind == "progress")
        #expect(seen[1].task == "port to swift")
    }
}

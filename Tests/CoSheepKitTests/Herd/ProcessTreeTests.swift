import Darwin
import Foundation
import Testing
@testable import CoSheepKit

// Run against the test process itself and a child we spawn, so nothing here
// depends on which terminal launched `swift test`.
@Suite("herd process tree")
struct ProcessTreeTests {
    @Test func theTestProcessHasAParentAndAName() {
        let me = getpid()
        let parent = ProcessTree.parent(of: me)
        #expect(parent != nil)
        #expect((parent ?? 0) > 0)
        #expect(parent == getppid())
        let name = ProcessTree.name(of: me)
        #expect(name?.isEmpty == false)
    }

    @Test func theTestProcessIsAlive() {
        #expect(ProcessTree.isAlive(getpid()))
    }

    @Test func launchdIsAliveEvenThoughWeCannotSignalIt() {
        // kill(1, 0) fails with EPERM for a normal user: still alive.
        #expect(ProcessTree.isAlive(1))
    }

    @Test func nonsensePidsAreNeitherAliveNorKnown() {
        for pid: Int32 in [0, -1, -999, Int32.max] {
            #expect(!ProcessTree.isAlive(pid), "\(pid)")
            #expect(ProcessTree.parent(of: pid) == nil, "\(pid)")
            #expect(ProcessTree.name(of: pid) == nil, "\(pid)")
        }
    }

    @Test func ancestorsWalkUpwardAndExcludeTheProcessItself() {
        let chain = ProcessTree.ancestors(of: getpid())
        #expect(chain.first == getppid())
        #expect(!chain.contains(getpid()))
        #expect(!chain.contains(1))
        #expect(!chain.contains(0))
        #expect(Set(chain).count == chain.count)
        for (child, parent) in zip([getpid()] + chain, chain) {
            #expect(ProcessTree.parent(of: child) == parent)
        }
    }

    @Test func theAncestorLimitIsRespected() {
        #expect(ProcessTree.ancestors(of: getpid(), limit: 0).isEmpty)
        #expect(ProcessTree.ancestors(of: getpid(), limit: 1).count <= 1)
        #expect(ProcessTree.ancestors(of: Int32.max).isEmpty)
    }

    @Test func aChildProcessIsSeenWhileItRunsAndNotAfter() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        defer { if child.isRunning { child.terminate() } }

        #expect(ProcessTree.isAlive(pid))
        #expect(ProcessTree.parent(of: pid) == getpid())
        #expect(ProcessTree.name(of: pid) == "sleep")
        #expect(ProcessTree.ancestors(of: pid).first == getpid())

        child.terminate()
        child.waitUntilExit()
        // Gone once reaped; give Foundation a moment to do that.
        for _ in 0..<100 where ProcessTree.isAlive(pid) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!ProcessTree.isAlive(pid))
        #expect(ProcessTree.parent(of: pid) == nil)
    }

    // MARK: terminal focus

    @Test func theTerminalIsTheNearestRegularAppAncestor() {
        let chain: [Int32] = [50, 40, 30, 20]
        let regular: Set<Int32> = [30, 20]
        #expect(TerminalFocus.terminalPid(forAgentPid: 60, ancestors: chain, isRegularApp: { regular.contains($0) }) == 30)
        #expect(TerminalFocus.terminalPid(forAgentPid: 60, ancestors: chain, isRegularApp: { _ in false }) == nil)
        #expect(TerminalFocus.terminalPid(forAgentPid: 60, ancestors: [], isRegularApp: { _ in true }) == nil)
    }

    @Test func lookingUpTheTerminalOfARealProcessDoesNotCrash() {
        // Depends on where the tests run (a terminal, an IDE, CI): any answer is fine,
        // but it must be a pid of one of our ancestors.
        if let found = TerminalFocus.terminalPid(forAgentPid: getpid()) {
            #expect(ProcessTree.ancestors(of: getpid()).contains(found))
        }
        #expect(TerminalFocus.terminalPid(forAgentPid: Int32.max) == nil)
    }

    @Test func activatingAPidThatIsNotAnAppFails() {
        #expect(!TerminalFocus.activate(pid: Int32.max))
        #expect(!TerminalFocus.activate(pid: -5))
        #expect(!TerminalFocus.activate(pid: 0))
        #expect(!TerminalFocus.activate(pid: 99_999_999))
    }
}

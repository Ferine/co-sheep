import AppKit
import Darwin
import Foundation

// Process lookups for the agent herd: is the `claude` process still alive, and
// which terminal app hosts it (the app that comes forward when you click a lamb).

nonisolated enum ProcessTree {
    /// The kernel's record for `pid`, or nil when no such process exists.
    private static func info(for pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0, info.kp_proc.p_pid == pid
        else { return nil }
        return info
    }

    /// The parent's pid, or nil when `pid` doesn't exist.
    static func parent(of pid: Int32) -> Int32? {
        info(for: pid)?.kp_eproc.e_ppid
    }

    /// The executable name (`p_comm`, which the kernel truncates to 16 bytes).
    static func name(of pid: Int32) -> String? {
        guard var comm = info(for: pid)?.kp_proc.p_comm else { return nil }
        return withUnsafePointer(to: &comm) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) {
                String(cString: $0)
            }
        }
    }

    /// Signal 0 probes without delivering anything. EPERM means it exists but
    /// belongs to someone else, which still counts as alive.
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// `pid`'s parent, grandparent, … up to `limit` levels, stopping before
    /// launchd (pid 1) or on a loop. Does not include `pid` itself.
    static func ancestors(of pid: Int32, limit: Int = 32) -> [Int32] {
        var result: [Int32] = []
        var seen: Set<Int32> = [pid]
        var current = pid
        while result.count < limit, let parent = parent(of: current), parent > 1, seen.insert(parent).inserted {
            result.append(parent)
            current = parent
        }
        return result
    }
}

/// Bringing the terminal that hosts a `claude` process to the front.
enum TerminalFocus {
    /// The nearest ancestor of the agent process that is a regular Dock app: the
    /// terminal (or IDE) it runs in.
    static func terminalPid(forAgentPid agentPid: Int32) -> Int32? {
        terminalPid(forAgentPid: agentPid, ancestors: ProcessTree.ancestors(of: agentPid), isRegularApp: { pid in
            NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        })
    }

    /// The same walk over an explicit ancestor chain (innermost first).
    static func terminalPid(forAgentPid agentPid: Int32, ancestors: [Int32], isRegularApp: (Int32) -> Bool) -> Int32? {
        ancestors.first(where: isRegularApp)
    }

    /// Asks the system to bring `pid`'s app forward. macOS decides whether to
    /// allow it (cooperative activation): we yield first, then ask to be
    /// activated on our behalf. Returns false when the app is gone or the
    /// request was refused.
    @discardableResult
    static func activate(pid: Int32) -> Bool {
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        NSApplication.shared.yieldActivation(to: app)
        return app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
    }
}

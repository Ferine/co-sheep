import Foundation

// What the shepherd could remark on. See Shepherd.swift for the overview.

// MARK: - Trigger

/// Something the shepherd could remark on. Names are the lambs' display names
/// (the repo folder).
nonisolated enum ShepherdTrigger: Equatable, Sendable {
    /// A new lamb parachuted in (first arrival in a window).
    case arrival(name: String)
    /// A lamb has been waiting on the human for `minutes`.
    case longWait(name: String, minutes: Int, waitingFor: String?)
    /// A lamb's failure count crossed 3, 6, 10, 15, ...
    case failureStreak(name: String, failures: Int)
    /// A lamb finished a turn after `minutes` of continuous work.
    case longRunFinished(name: String, minutes: Int)
    /// A substantial lamb (long-lived or token-hungry) left the pasture.
    case departed(name: String, tokens: Int, minutes: Int)
    /// The periodic look at the whole herd.
    case herdReview

    /// Short stable label for logs.
    var kind: String {
        switch self {
        case .arrival: "arrival"
        case .longWait: "longWait"
        case .failureStreak: "failureStreak"
        case .longRunFinished: "longRunFinished"
        case .departed: "departed"
        case .herdReview: "herdReview"
        }
    }
}

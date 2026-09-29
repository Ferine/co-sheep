import Foundation

/// Every signal that flows through the flock (ex-events.ts). Payloads are plain data.
nonisolated enum FlockEvent {
    case sheepPetted(id: String)
    case groupActivity(type: String, participants: [String])
    case conversationHappened(idA: String, idB: String, topic: String)
    case appSwitched(AppSwitch)
    case weatherChanged(condition: String?)
    case aiCommentary(animation: SheepAnimation?)
    case dramaStateChanged(idA: String, idB: String, from: String, to: String, cause: String)
    case spectacleStarted(type: String)
    case spectacleEnded(type: String)

    var name: FlockEventName {
        switch self {
        case .sheepPetted: .sheepPetted
        case .groupActivity: .groupActivity
        case .conversationHappened: .conversationHappened
        case .appSwitched: .appSwitched
        case .weatherChanged: .weatherChanged
        case .aiCommentary: .aiCommentary
        case .dramaStateChanged: .dramaStateChanged
        case .spectacleStarted: .spectacleStarted
        case .spectacleEnded: .spectacleEnded
        }
    }
}

nonisolated enum FlockEventName: String, CaseIterable {
    case sheepPetted = "sheep-petted"
    case groupActivity = "group-activity"
    case conversationHappened = "conversation-happened"
    case appSwitched = "app-switched"
    case weatherChanged = "weather-changed"
    case aiCommentary = "ai-commentary"
    case dramaStateChanged = "drama-state-changed"
    case spectacleStarted = "spectacle-started"
    case spectacleEnded = "spectacle-ended"
}

nonisolated struct AppSwitch: Equatable {
    var app: String
    var previousApp: String?
    var previousDurationMs: Double
}

/// Typed pub/sub. Handlers are isolated: one throwing cannot break the rest.
final class FlockBus {
    static let shared = FlockBus()

    private var handlers: [FlockEventName: [(id: Int, fn: (FlockEvent) throws -> Void)]] = [:]
    private var nextId = 0

    func emit(_ event: FlockEvent) {
        for h in handlers[event.name] ?? [] {
            do {
                try h.fn(event)
            } catch {
                Log.info("bus", "error: handler for '\(event.name.rawValue)' failed: \(error)")
            }
        }
    }

    /// Subscribe; returns an unsubscribe closure.
    @discardableResult
    func on(_ name: FlockEventName, _ handler: @escaping (FlockEvent) throws -> Void) -> () -> Void {
        nextId += 1
        let id = nextId
        handlers[name, default: []].append((id, handler))
        return { [weak self] in
            self?.handlers[name]?.removeAll { $0.id == id }
        }
    }
}

/// Module-level alias matching the TS `bus` singleton.
var bus: FlockBus { FlockBus.shared }

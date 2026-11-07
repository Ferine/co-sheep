import Foundation

/// Multi-subscriber typed callback list.
final class Signal<T> {
    private var handlers: [(id: Int, fn: (T) -> Void)] = []
    private var nextId = 0

    @discardableResult
    func on(_ fn: @escaping (T) -> Void) -> () -> Void {
        nextId += 1
        let id = nextId
        handlers.append((id, fn))
        return { [weak self] in self?.handlers.removeAll { $0.id == id } }
    }

    func emit(_ value: T) {
        for h in handlers { h.fn(value) }
    }
}

extension Signal where T == Void {
    func emit() { emit(()) }
}

import Foundation

/// Concurrent callers await one load. Invalidating cannot publish an old model
/// after a settings/storage change, even if the library ignores cancellation.
final class SharedModelLoader<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (id: UUID, key: String, value: Value)?
    private var pending: (id: UUID, key: String, task: Task<Value, Error>)?

    private enum Selection {
        case cached(Value)
        case flight(id: UUID, key: String, task: Task<Value, Error>)
    }

    var value: Value? { lock.withLock { cached?.value } }
    var isLoading: Bool { lock.withLock { pending != nil } }

    func invalidate() {
        lock.withLock {
            cached = nil
            pending?.task.cancel()
            pending = nil
        }
    }

    func load(key: String, operation: @escaping () async throws -> Value) async throws -> Value {
        while true {
            try Task.checkCancellation()
            let selection: Selection = lock.withLock {
                if let cached, cached.key == key { return .cached(cached.value) }
                if let pending { return .flight(id: pending.id, key: pending.key, task: pending.task) }
                let task = Task { try await operation() }
                let flight = (id: UUID(), key: key, task: task)
                pending = flight
                return .flight(id: flight.id, key: key, task: task)
            }
            let flight: (id: UUID, key: String, task: Task<Value, Error>)
            switch selection {
            case .cached(let value): return value
            case .flight(let id, let key, let task): flight = (id, key, task)
            }
            do {
                let value = try await flight.task.value
                let accepted = lock.withLock { () -> Bool in
                    if pending?.id == flight.id {
                        cached = (flight.id, flight.key, value)
                        pending = nil
                        return true
                    }
                    // Another waiter may already have published this flight.
                    return cached?.id == flight.id
                }
                guard accepted else { throw CancellationError() }
                if flight.key == key { return value }
            } catch {
                lock.withLock {
                    if pending?.id == flight.id { pending = nil }
                }
                throw error
            }
        }
    }
}

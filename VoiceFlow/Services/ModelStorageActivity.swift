import Foundation
import Combine

/// Serializes storage migration against model loads, downloads and dictation.
final class ModelStorageActivity: ObservableObject, @unchecked Sendable {
    static let shared = ModelStorageActivity()
    private let lock = NSLock()
    private var readers = 0
    private var migrating = false

    var isBusy: Bool { lock.withLock { migrating || readers > 0 } }
    var isMigrating: Bool { lock.withLock { migrating } }

    final class Lease {
        private let release: () -> Void
        init(release: @escaping () -> Void) { self.release = release }
        deinit { release() }
    }

    func acquire() throws -> Lease {
        try lock.withLock {
            guard !migrating else { throw StorageError.busy }
            readers += 1
        }
        changed()
        return Lease { [self] in
            lock.withLock { readers -= 1 }
            changed()
        }
    }

    func beginMigration() throws -> Lease {
        try lock.withLock {
            guard !migrating, readers == 0 else { throw StorageError.busy }
            migrating = true
        }
        changed()
        return Lease { [self] in
            lock.withLock { migrating = false }
            changed()
        }
    }

    private func changed() {
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    enum StorageError: LocalizedError {
        case busy
        var errorDescription: String? {
            "Model storage is busy. Wait for dictation, downloads or the current move to finish."
        }
    }
}

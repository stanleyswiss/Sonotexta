import Foundation

/// Copy, verify, then publish. Original weights are never removed on a failure.
/// The caller persists the new setting before calling removeOriginals(). A crash
/// can leave extra copies, but cannot leave the old setting without its models.
enum ModelStorageMigration {
    struct Pair: Sendable {
        let name: String
        let source: URL
        let destination: URL
    }

    struct Prepared: Sendable {
        let pairs: [Pair]
        let volumeIDs: [String: String]
        let names: [String]

        func removeOriginals(fileManager fm: FileManager = .default) -> String {
            var retained = [String]()
            for pair in pairs {
                do {
                    if let expected = volumeIDs[pair.source.path], ModelStorage.volumeUUID(at: pair.source) != expected {
                        retained.append(pair.source.path)
                        continue
                    }
                    // An external process may have changed originals while copying.
                    guard try ModelStorageMigration.containsCopy(of: pair.source, at: pair.destination, fm: fm) else {
                        retained.append(pair.source.path)
                        continue
                    }
                    try fm.removeItem(at: pair.source)
                } catch { retained.append(pair.source.path) }
            }
            let summary = names.isEmpty ? "No existing models to move." : "Moved: \(names.joined(separator: ", "))."
            return retained.isEmpty ? summary : summary + " Old copies could not be removed: " + retained.joined(separator: ", ")
        }
    }

    enum MigrationError: LocalizedError {
        case overlap, conflict(String), verification(String)
        var errorDescription: String? {
            switch self {
            case .overlap: return "Choose a folder outside the current model folders."
            case .conflict(let path): return "Different model files already exist at \(path). Choose an empty folder or resolve the conflict first."
            case .verification(let path): return "The copied model could not be verified at \(path). Original models were kept."
            }
        }
    }

    /// File-operation injection lets regression tests fail the second copy or
    /// publication without filling disks or touching the user's actual weights.
    static func prepare(
        pairs: [Pair],
        progress: (String) -> Void = { _ in },
        copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
        publish: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws -> Prepared {
        let fm = FileManager.default
        let pairs = pairs.map {
            Pair(name: $0.name, source: $0.source.resolvingSymlinksInPath().standardizedFileURL,
                 destination: $0.destination.resolvingSymlinksInPath().standardizedFileURL)
        }.filter { $0.source.path != $0.destination.path && fm.fileExists(atPath: $0.source.path) }

        let volumeIDs = Dictionary(uniqueKeysWithValues: pairs.compactMap { pair in
            ModelStorage.volumeUUID(at: pair.source).map { (pair.source.path, $0) }
        })
        for pair in pairs {
            for other in pairs {
                if isInside(pair.destination, other.source) || isInside(other.source, pair.destination) {
                    throw MigrationError.overlap
                }
            }
        }

        var transfers: [(source: URL, destination: URL)] = []
        func plan(_ source: URL, _ destination: URL) throws {
            guard fm.fileExists(atPath: destination.path) else {
                transfers.append((source, destination))
                return
            }
            let src = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let dst = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard src.isSymbolicLink != true, dst.isSymbolicLink != true else {
                throw MigrationError.conflict(destination.path)
            }
            if src.isDirectory == true && dst.isDirectory == true {
                for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    try plan(child, destination.appendingPathComponent(child.lastPathComponent))
                }
            } else if !fm.contentsEqual(atPath: source.path, andPath: destination.path) {
                throw MigrationError.conflict(destination.path)
            }
        }
        for pair in pairs { try plan(pair.source, pair.destination) }

        var staged: [(temporary: URL, destination: URL)] = []
        var published = [URL]()
        do {
            for (index, transfer) in transfers.enumerated() {
                progress("Copying models (\(index + 1) of \(transfers.count))…")
                let parent = transfer.destination.deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                let temporary = parent.appendingPathComponent(".sonotexta-move-\(UUID().uuidString)")
                staged.append((temporary, transfer.destination))
                try copy(transfer.source, temporary)
                progress("Verifying copied models…")
                guard fm.contentsEqual(atPath: transfer.source.path, andPath: temporary.path) else {
                    throw MigrationError.verification(temporary.path)
                }
            }
            progress("Finishing model move…")
            for item in staged {
                // Never replace an item created by another process during copying.
                guard !fm.fileExists(atPath: item.destination.path) else {
                    throw MigrationError.conflict(item.destination.path)
                }
                try publish(item.temporary, item.destination)
                published.append(item.destination)
            }
        } catch {
            // Only our newly copied items are removed; originals remain intact.
            for item in staged { try? fm.removeItem(at: item.temporary) }
            for item in published { try? fm.removeItem(at: item) }
            throw error
        }
        return Prepared(pairs: pairs, volumeIDs: volumeIDs, names: pairs.map(\.name))
    }

    private static func containsCopy(of source: URL, at destination: URL, fm: FileManager) throws -> Bool {
        let info = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if info.isDirectory == true && info.isSymbolicLink != true {
            let target = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard target.isDirectory == true, target.isSymbolicLink != true else { return false }
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                if try !containsCopy(of: child, at: destination.appendingPathComponent(child.lastPathComponent), fm: fm) { return false }
            }
            return true
        }
        return fm.contentsEqual(atPath: source.path, andPath: destination.path)
    }

    private static func isInside(_ child: URL, _ parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }
}

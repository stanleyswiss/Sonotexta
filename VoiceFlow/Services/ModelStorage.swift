import Foundation

/// Single source of truth for WHERE model weights live on disk (3.16.6,
/// beta-tester request: point downloads at an external drive instead of the
/// OS disk).
///
/// Layout:
/// - Default (no custom root):
///     Whisper   → ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml
///                 (WhisperKit/HubApi's own default — predates this feature)
///     FluidAudio→ ~/Library/Application Support/FluidAudio/Models/…
/// - Custom root R (user-chosen folder):
///     Whisper   → R/WhisperKit/models/argmaxinc/whisperkit-coreml
///                 (we pass R/WhisperKit as HubApi downloadBase)
///     FluidAudio→ R/FluidAudio/Models/…
///
/// UNREACHABLE-DRIVE POLICY: if a custom root is set but missing (external
/// drive unplugged), we deliberately do NOT fall back to the default
/// location — that would silently re-download gigabytes onto the OS disk.
/// Paths keep pointing at the custom root, loads fail loudly, and the
/// Settings UI + dictation overlay surface the reason.
enum ModelStorage {

    // MARK: - Root resolution

    /// User-chosen root, or nil for system defaults. Backed by AppSettings.
    static var customRoot: URL? {
        guard let path = AppSettings.shared.modelStoragePath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// True when a custom root is configured (regardless of reachability).
    static var isCustomRootSet: Bool { customRoot != nil }

    /// True when no custom root is set, or the custom root directory exists.
    static var isRootReachable: Bool {
        (try? validateCurrentRoot()) != nil
    }

    /// Human-readable description of the active storage location for the UI.
    static var displayDescription: String {
        customRoot?.path ?? "Default (Documents & Application Support)"
    }

    // MARK: - Whisper (WhisperKit / HubApi)

    /// Value to pass as `WhisperKitConfig.downloadBase`. nil = HubApi default.
    static var whisperDownloadBase: URL? { whisperDownloadBase(customRoot: customRoot) }

    /// Directory that actually contains the `openai_whisper-*` model folders —
    /// used by ModelManager for listing, sizing, and deleting.
    static var whisperModelsDirectory: URL { whisperModelsDirectory(customRoot: customRoot) }

    // Parameterized cores — pure functions of the chosen root, unit-testable
    // without touching the real AppSettings singleton.

    static func whisperDownloadBase(customRoot: URL?) -> URL? {
        customRoot?.appendingPathComponent("WhisperKit", isDirectory: true)
    }

    static func whisperModelsDirectory(customRoot: URL?) -> URL {
        let hubRoot = whisperDownloadBase(customRoot: customRoot)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/huggingface", isDirectory: true)
        return hubRoot.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    // MARK: - FluidAudio (Parakeet + Parakeet Live)

    /// Root that contains per-repo model folders (mirrors FluidAudio's own
    /// AppSupport/FluidAudio/Models default when no custom root is set).
    static var fluidAudioModelsRoot: URL { fluidAudioModelsRoot(customRoot: customRoot) }

    static func fluidAudioModelsRoot(customRoot: URL?) -> URL {
        if let root = customRoot {
            return root
                .appendingPathComponent("FluidAudio", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Directory for a specific FluidAudio repo folder (e.g.
    /// "parakeet-tdt-0.6b-v3-coreml" or "parakeet-eou-streaming/160ms").
    static func fluidAudioModelDirectory(repoFolder: String) -> URL {
        fluidAudioModelsRoot.appendingPathComponent(repoFolder, isDirectory: true)
    }

    /// Validate before any library is allowed to create its cache directories.
    static func validateRoot(_ root: URL?, expectedVolumeUUID: String? = nil) throws {
        guard let root else { return }
        let values: URLResourceValues
        var checkedRoot = root
        checkedRoot.removeAllCachedResourceValues()
        do {
            values = try checkedRoot.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey])
        } catch {
            throw RootError.unavailable(root.path)
        }
        guard values.isDirectory == true else { throw RootError.unavailable(root.path) }
        if let expectedVolumeUUID, values.volumeUUIDString != expectedVolumeUUID {
            throw RootError.unavailable(root.path)
        }
    }

    static func validateCurrentRoot() throws {
        try validateRoot(customRoot, expectedVolumeUUID: AppSettings.shared.modelStorageVolumeUUID)
    }

    static func volumeUUID(at root: URL?) -> String? {
        guard let root else { return nil }
        var checkedRoot = root
        checkedRoot.removeAllCachedResourceValues()
        return try? checkedRoot.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    static func migrationPairs(from oldRoot: URL?, to newRoot: URL?) -> [ModelStorageMigration.Pair] {
        [
            .init(name: "Whisper", source: whisperModelsDirectory(customRoot: oldRoot),
                  destination: whisperModelsDirectory(customRoot: newRoot)),
            .init(name: "Parakeet", source: fluidAudioModelsRoot(customRoot: oldRoot),
                  destination: fluidAudioModelsRoot(customRoot: newRoot))
        ]
    }

    enum RootError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let path):
                return "Model storage is unavailable at \(path). Reconnect the drive, or choose Use Default in Model Storage to download models to this Mac."
            }
        }
    }
}

extension Notification.Name {
    static let modelStorageChanged = Notification.Name("SonotextaModelStorageChanged")
}

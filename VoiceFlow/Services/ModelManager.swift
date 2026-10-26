import Foundation
import Combine
import WhisperKit

final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var downloadedModels: Set<String> = []
    @Published var downloadingModel: String?
    @Published var downloadStartTime: Date?
    @Published var downloadElapsed: TimeInterval = 0

    private var timer: Timer?

    private init() {
        refreshDownloadedModels()
    }

    func refreshDownloadedModels() {
        let hubDir = ModelStorage.whisperModelsDirectory

        var found = Set<String>()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: hubDir.path) {
            for dir in contents where dir.hasPrefix("openai_whisper-") {
                let modelPath = hubDir.appendingPathComponent(dir)
                let melSpec = modelPath.appendingPathComponent("MelSpectrogram.mlmodelc")
                if FileManager.default.fileExists(atPath: melSpec.path) {
                    let shortName = dir.replacingOccurrences(of: "openai_whisper-", with: "")
                    found.insert(shortName)
                }
            }
        }
        downloadedModels = found
    }

    func isDownloaded(_ model: WhisperModelSize) -> Bool {
        downloadedModels.contains(model.rawValue)
    }

    func modelSizeOnDisk(_ model: WhisperModelSize) -> String? {
        let hubDir = ModelStorage.whisperModelsDirectory
            .appendingPathComponent("openai_whisper-\(model.rawValue)")
        guard FileManager.default.fileExists(atPath: hubDir.path) else { return nil }

        let size = directorySize(hubDir)
        if size > 1_000_000_000 {
            return String(format: "%.1f GB", Double(size) / 1_000_000_000)
        } else {
            return String(format: "%.0f MB", Double(size) / 1_000_000)
        }
    }

    private func directorySize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    func downloadModel(_ model: WhisperModelSize) async throws {
        let lease = try ModelStorageActivity.shared.acquire()
        defer { withExtendedLifetime(lease) {} }
        try ModelStorage.validateCurrentRoot()
        let modelName = model.rawValue
        print("[VoiceFlow] Downloading model: openai_whisper-\(modelName)")

        await MainActor.run {
            downloadingModel = modelName
            downloadStartTime = Date()
            downloadElapsed = 0
            startTimer()
        }

        let config = WhisperKitConfig(
            model: "openai_whisper-\(modelName)",
            downloadBase: ModelStorage.whisperDownloadBase
        )

        do {
            let _ = try await WhisperKit(config)
            await MainActor.run {
                downloadedModels.insert(modelName)
                stopTimer()
                downloadingModel = nil
            }
            print("[VoiceFlow] Model ready: openai_whisper-\(modelName)")
        } catch {
            await MainActor.run {
                stopTimer()
                downloadingModel = nil
            }
            throw error
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.downloadStartTime else { return }
            self.downloadElapsed = Date().timeIntervalSince(start)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func deleteModel(_ model: WhisperModelSize) {
        guard let lease = try? ModelStorageActivity.shared.acquire(),
              (try? ModelStorage.validateCurrentRoot()) != nil else { return }
        defer { withExtendedLifetime(lease) {} }
        let hubDir = ModelStorage.whisperModelsDirectory
            .appendingPathComponent("openai_whisper-\(model.rawValue)")
        try? FileManager.default.removeItem(at: hubDir)
        downloadedModels.remove(model.rawValue)
        print("[VoiceFlow] Deleted model: \(model.rawValue)")
    }

    func formatElapsed(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}

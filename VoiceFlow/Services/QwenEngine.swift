import AVFoundation
import CoreML
import FluidAudio

/// Qwen's bundled CoreML conversion is experimental. Recognition is performed
/// after capture stops; no cloud service or API key is involved.
@MainActor
final class QwenEngine: @preconcurrency STTEngineProtocol {
    let engineType: STTEngineType = .qwen
    var isAvailable: Bool { modelLoader.value != nil }
    var languageHint: String?
    private(set) var finalizationError: Error?

    // Settings downloads, launch preloading and dictation share one load/cache.
    private static let sharedModels = SharedModelLoader<Qwen3AsrManager>()
    private var modelLoader: SharedModelLoader<Qwen3AsrManager> { Self.sharedModels }
    private static let readyMarker = ".sonotexta-qwen-ready"
    private let captured = QwenCaptureBuffer()
    private var audioEngine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var onResult: ((String, Bool) -> Void)?
    private var sessionLanguage: String?

    static func modelDirectory(customRoot: URL?) -> URL {
        ModelStorage.fluidAudioModelsRoot(customRoot: customRoot)
            .appendingPathComponent(Repo.qwen3Asr.folderName, isDirectory: true)
    }

    static var isDownloaded: Bool {
        isReady(at: modelDirectory(customRoot: ModelStorage.customRoot))
    }

    static func isReady(at directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(readyMarker).path)
            && Qwen3AsrModels.modelsExist(at: directory)
    }

    func unloadModel() { modelLoader.invalidate() }

    func loadModel(progress: DownloadUtils.ProgressHandler? = nil) async throws {
        let lease = try ModelStorageActivity.shared.acquire()
        defer { withExtendedLifetime(lease) {} }
        try ModelStorage.validateCurrentRoot()
        let root = ModelStorage.fluidAudioModelsRoot
        let target = root.appendingPathComponent(Repo.qwen3Asr.folderName, isDirectory: true)
        _ = try await modelLoader.load(key: target.path) {
            // Qwen3AsrModels.download(to:) in this vendored version ignores its
            // custom root. Use the downloader's explicit root instead.
            if !Self.isReady(at: target) {
                try await DownloadUtils.downloadRepo(.qwen3Asr, to: root, progressHandler: progress)
            }
            try Task.checkCancellation()
            guard Qwen3AsrModels.modelsExist(at: target) else {
                throw QwenEngineError.incompleteDownload
            }
            progress?(.init(fractionCompleted: 1, phase: .compiling(modelName: "Qwen3-ASR")))
            let manager = Qwen3AsrManager()
            // The stateful decoder's Metal attention kernel aborts on macOS 27
            // (verified by the real-speech smoke test). Exclude GPU execution;
            // CoreML can place supported work on ANE and use CPU otherwise.
            try await manager.loadModels(from: target, computeUnits: .cpuAndNeuralEngine)
            // A model directory alone can be left by an interrupted download.
            // Publish readiness only after all components successfully load.
            let marker = target.appendingPathComponent(Self.readyMarker)
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data("Qwen3-ASR 0.6B f32\n".utf8).write(to: marker, options: .atomic)
            }
            return manager
        }
    }

    func deleteModel() throws {
        let lease = try ModelStorageActivity.shared.beginMigration()
        defer { withExtendedLifetime(lease) {} }
        try ModelStorage.validateCurrentRoot()
        unloadModel()
        let directory = Self.modelDirectory(customRoot: ModelStorage.customRoot)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor func startTranscription(locale: Locale, onResult: @escaping (String, Bool) -> Void) async throws {
        finalizationError = nil
        captured.begin()
        self.onResult = onResult
        sessionLanguage = languageHint
        do {
            if let hint = sessionLanguage, Qwen3AsrConfig.Language(from: hint) == nil {
                throw QwenEngineError.unsupportedLanguage(hint)
            }
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw QwenEngineError.microphonePermission
                }
            }
            // A key release during permission/model loading must not restart capture.
            if captured.isActive {
                let engine = AVAudioEngine()
                AudioSessionHelper.configureSharedInput(for: engine)
                try Self.installTap(on: engine, captured: captured)
                configObserver = AudioSessionHelper.installReconfigObserver(
                    for: engine, engineName: "qwen",
                    isActive: { [captured] in captured.isActive },
                    setupTap: { [captured] engine in try Self.installTap(on: engine, captured: captured) },
                    onFatal: { [captured] in captured.fail(QwenEngineError.captureInterrupted) }
                )
                audioEngine = engine
                try await AudioSessionHelper.startEngine(engine)
                if !captured.isActive { pauseCapture() }
            }
            // Capture precedes the cold model load, preserving the first words.
            try await loadModel()
        } catch {
            pauseCapture()
            captured.discard()
            self.onResult = nil
            throw error
        }
    }

    nonisolated private static func installTap(on engine: AVAudioEngine, captured: QwenCaptureBuffer) throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw QwenEngineError.invalidInputFormat
        }
        let resampler = LocalAudioResampler(logLabel: "qwen")
        let exception = ObjCExceptionCatcher.catchException {
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
                guard captured.isActive else { return }
                do { captured.append(try resampler.convert(buffer)) }
                catch { captured.fail(error) }
            }
        }
        if exception != nil { throw QwenEngineError.invalidInputFormat }
    }

    func pauseCapture() {
        captured.pause()
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    @MainActor func stopTranscription() async -> String? {
        pauseCapture()
        let (samples, captureError) = captured.take()
        defer { onResult = nil }
        do {
            if let captureError { throw captureError }
            guard !samples.isEmpty else { return nil }
            let text = try await transcribe(samples: samples, language: sessionLanguage)
            guard !text.isEmpty else { return nil }
            onResult?(text, true)
            return text
        } catch {
            // Never deliver a successful-looking prefix when a later chunk fails.
            finalizationError = error
            print("[Sonotexta][qwen] Transcription failed: \(error.localizedDescription)")
            return nil
        }
    }
    /// Shared file/capture inference path, also exercised by the opt-in real-model smoke test.
    func transcribe(samples: [Float], language: String?) async throws -> String {
        guard let manager = modelLoader.value else { throw QwenEngineError.modelNotLoaded }
        var parts: [String] = []
        // Keep audio context below the bundled decoder's 512-token cache and
        // leave room for generated text. Every sample belongs to one chunk.
        for range in QwenAudioChunks.ranges(in: samples) {
            try Task.checkCancellation()
            let text = try await manager.transcribe(
                audioSamples: Array(samples[range]), language: language
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: " ")
    }

}

/// The audio callback and control actor share only this locked buffer.
final class QwenCaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var samples: [Float] = []
    private var error: Error?
    var isActive: Bool { lock.withLock { active } }
    func begin() { lock.withLock { samples = []; error = nil; active = true } }
    func pause() { lock.withLock { active = false } }
    func append(_ values: [Float]) { lock.withLock { if active { samples.append(contentsOf: values) } } }
    func fail(_ failure: Error) { lock.withLock { if error == nil { error = failure }; active = false } }
    func take() -> ([Float], Error?) {
        lock.withLock {
            let result = (samples, error)
            samples = []
            error = nil
            return result
        }
    }
    func discard() { _ = take() }
}

enum QwenAudioChunks {
    static let sampleRate = 16_000
    static let maximumSamples = 12 * sampleRate

    static func ranges(in samples: [Float]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        let window = sampleRate / 10
        while start < samples.count {
            var end = min(start + maximumSamples, samples.count)
            if end < samples.count {
                // Find the quietest 100ms window in the last two seconds.
                var bestEnergy = Float.infinity
                for candidate in stride(from: end - 2 * sampleRate, through: end - window, by: window) {
                    let energy = samples[candidate..<(candidate + window)].reduce(Float(0)) { $0 + $1 * $1 }
                    if energy <= bestEnergy {
                        bestEnergy = energy
                        end = candidate + window / 2
                    }
                }
            }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }
}

enum QwenEngineError: LocalizedError {
    case microphonePermission, modelNotLoaded, incompleteDownload, captureInterrupted, invalidInputFormat
    case unsupportedLanguage(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let code): return "Qwen3-ASR does not support the selected input language (\(code)). Choose another engine or input language."
        case .invalidInputFormat: return "The microphone format is unavailable. Check the selected input device and try again."
        case .microphonePermission: return "Microphone access is required for Qwen dictation."
        case .modelNotLoaded: return "The Qwen3-ASR model is not loaded."
        case .incompleteDownload: return "The Qwen3-ASR download is incomplete. Please retry the download."
        case .captureInterrupted: return "Microphone capture was interrupted. Please try dictating again."
        }
    }
}

import FluidAudio
import AVFoundation

final class ParakeetEngine: STTEngineProtocol {
    let engineType: STTEngineType = .parakeet

    var isAvailable: Bool { asrManager != nil }
    var isModelLoaded: Bool { asrManager != nil }
    var isLoading: Bool { modelLoader.isLoading }

    private let modelLoader = SharedModelLoader<AsrManager>()
    private var asrManager: AsrManager? { modelLoader.value }
    private let captureStateLock = NSLock()
    private var stopRequested = false
    private var captureStopRequested: Bool {
        get { captureStateLock.withLock { stopRequested } }
        set { captureStateLock.withLock { stopRequested = newValue } }
    }
    private var audioEngine: AVAudioEngine?
    private var transcribing = false
    private var isTranscribing: Bool {
        get { captureStateLock.withLock { transcribing } }
        set { captureStateLock.withLock { transcribing = newValue } }
    }
    /// Audio frames accumulated by the input tap. Access ONLY under
    /// `bufferLock` — the tap thread and the periodic transcription task
    /// both touch this array, and Swift `[Float]` is not thread-safe.
    ///
    /// 3.14.1: `NSLock` replaces the previous `DispatchQueue` design —
    /// `DispatchQueue.sync` from Swift Concurrency Tasks stalled the
    /// cooperative pool in 3.14.0.
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var onResult: ((String, Bool) -> Void)?
    private var transcriptionTask: Task<Void, Never>?
    private var isRestartingCapture = false
    /// AVAudioEngineConfigurationChange observer — re-arms after Bluetooth
    /// profile flips that auto-stop AVAudioEngine.
    private var configChangeObserver: NSObjectProtocol?

    func unloadModel() {
        modelLoader.invalidate()
    }

    func loadModel() async throws {
        let lease = try ModelStorageActivity.shared.acquire()
        defer { withExtendedLifetime(lease) {} }
        try ModelStorage.validateCurrentRoot()
        let selected = AppSettings.shared.selectedParakeetModel
        let version: AsrModelVersion = selected == .v2 ? .v2 : .v3
        let folder = selected == .v2 ? "parakeet-tdt-0.6b-v2-coreml" : "parakeet-tdt-0.6b-v3-coreml"
        let target = ModelStorage.fluidAudioModelDirectory(repoFolder: folder)
        _ = try await modelLoader.load(key: target.path) {
            let directory = try await AsrModels.download(to: target, version: version)
            let models = try await AsrModels.load(from: directory, version: version)
            let manager = AsrManager()
            try await manager.initialize(models: models)
            return manager
        }
    }

    func startTranscription(locale: Locale, onResult: @escaping (String, Bool) -> Void) async throws {
        if isTranscribing {
            _ = await stopTranscription()
        }
        captureStopRequested = false

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus != .authorized {
            if micStatus == .notDetermined {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw ParakeetError.micPermissionDenied }
            } else { throw ParakeetError.micPermissionDenied }
        }

        self.onResult = onResult
        bufferLock.withLock { self.audioBuffer = [] }
        self.isTranscribing = !captureStopRequested
        self.isRestartingCapture = false

        // 3.16.5: capture BEFORE (lazy) model load — audio spoken during the
        // load lands in audioBuffer and is transcribed once the model is up.
        if !captureStopRequested { try await startAudioCapture() }

        do {
            print("[VoiceFlow] Parakeet model loading while capture buffers…")
            do {
                try await loadModel()
            } catch {
                _ = await stopTranscription()
                throw error
            }
        }
        guard let asrManager = self.asrManager else {
            _ = await stopTranscription()
            throw ParakeetError.modelNotLoaded
        }
        print("[VoiceFlow] Parakeet audio capture started")

        transcriptionTask = Task { [weak self] in
            while self?.isTranscribing == true {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isTranscribing else { continue }
                // Snapshot atomically before transcribing — lock held only
                // for the array copy (microseconds).
                let currentAudio = self.bufferLock.withLock { self.audioBuffer }
                guard currentAudio.count > 16000 else { continue }

                if let pcmBuffer = self.floatArrayToPCMBuffer(currentAudio),
                   let result = try? await asrManager.transcribe(pcmBuffer) {
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if self.isTranscribing && !text.isEmpty {
                        self.onResult?(text, false)
                    }
                }
            }
        }
    }

    func pauseCapture() {
        captureStopRequested = true
        isTranscribing = false
        transcriptionTask?.cancel()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRestartingCapture = false
    }

    func stopTranscription() async -> String? {
        pauseCapture()
        // Wait for the last partial/chunk task before final inference/reset.
        let pending = transcriptionTask
        await pending?.value
        transcriptionTask = nil

        let bufferSnapshot = bufferLock.withLock {
            let snapshot = audioBuffer
            audioBuffer = []
            return snapshot
        }

        var finalText: String?
        if let asrManager, !bufferSnapshot.isEmpty {
            // 3.16.4-beta.1: log final-inference failures instead of `try?`
            // swallowing them — a failed final is not the same as silence.
            var finalResult: ASRResult?
            if let pcmBuffer = floatArrayToPCMBuffer(bufferSnapshot) {
                do {
                    finalResult = try await asrManager.transcribe(pcmBuffer)
                } catch {
                    print("[VoiceFlow] Parakeet FINAL TRANSCRIBE FAILED: \(error.localizedDescription)")
                }
            }
            if let result = finalResult {
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    #if DEBUG
                    print("[VoiceFlow] Parakeet final: \(text)")
                    #endif
                    finalText = text
                    onResult?(text, true)
                }
            }
        }
        onResult = nil
        return finalText
    }

    private func startAudioCapture() async throws {
        let engine = AVAudioEngine()
        AudioSessionHelper.configureSharedInput(for: engine)
        engine.inputNode.removeTap(onBus: 0)
        try installTap(on: engine)

        configChangeObserver = AudioSessionHelper.installReconfigObserver(
            for: engine,
            engineName: "parakeet",
            isActive: { [weak self] in self?.isTranscribing ?? false },
            setupTap: { [weak self] reconfigEngine in
                guard let self else { return }
                try self.installTap(on: reconfigEngine)
            },
            onFatal: { [weak self] in
                Task { await self?.restartCapture() }
            }
        )

        audioEngine = engine
        do {
            try await AudioSessionHelper.startEngine(engine)
            if captureStopRequested { pauseCapture() }
        } catch {
            pauseCapture()
            throw error
        }
    }

    private func installTap(on engine: AVAudioEngine) throws {
        let resampler = LocalAudioResampler(logLabel: "parakeet")
        engine.inputNode.installTap(onBus: 0, bufferSize: 8192, format: nil) { [weak self] buffer, _ in
            guard let self, self.isTranscribing else { return }
            let downsampled: [Float]
            do { downsampled = try resampler.convert(buffer) }
            catch {
                print("[Sonotexta] Audio conversion failed: \(error.localizedDescription)")
                return
            }
            self.bufferLock.withLock {
                if self.isTranscribing { self.audioBuffer.append(contentsOf: downsampled) }
            }
        }
    }

    private func restartCapture() async {
        print("[Sonotexta][parakeet] restartCapture enter")
        guard isTranscribing else {
            print("[Sonotexta][parakeet] restartCapture skipped because capture is inactive")
            return
        }
        guard !isRestartingCapture else {
            print("[Sonotexta][parakeet] restartCapture already in progress")
            return
        }

        isRestartingCapture = true
        defer {
            isRestartingCapture = false
            print("[Sonotexta][parakeet] restartCapture exit")
        }

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        do {
            try await startAudioCapture()
        } catch {
            print("[Sonotexta][parakeet] restartCapture failed: \(error.localizedDescription)")
        }
    }

    private func floatArrayToPCMBuffer(_ array: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(array.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(array.count)
        if let channelData = buffer.floatChannelData {
            array.withUnsafeBufferPointer { ptr in
                channelData[0].update(from: ptr.baseAddress!, count: array.count)
            }
        }
        return buffer
    }

    /// Check if the currently selected Parakeet model is downloaded
    static var isDownloaded: Bool {
        let version = AppSettings.shared.selectedParakeetModel
        let folderName = version == .v2 ? "parakeet-tdt-0.6b-v2-coreml" : "parakeet-tdt-0.6b-v3-coreml"
        let path = ModelStorage.fluidAudioModelDirectory(repoFolder: folderName)
            .appendingPathComponent("Encoder.mlmodelc")
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Check if a specific version is downloaded
    static func isDownloaded(version: ParakeetModelVersion) -> Bool {
        let folderName = version == .v2 ? "parakeet-tdt-0.6b-v2-coreml" : "parakeet-tdt-0.6b-v3-coreml"
        let path = ModelStorage.fluidAudioModelDirectory(repoFolder: folderName)
            .appendingPathComponent("Encoder.mlmodelc")
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// On-disk size of a downloaded Parakeet model folder, formatted for UI.
    /// Returns nil if the model isn't downloaded or the size can't be read.
    static func sizeOnDisk(version: ParakeetModelVersion) -> String? {
        let folderName = version == .v2 ? "parakeet-tdt-0.6b-v2-coreml" : "parakeet-tdt-0.6b-v3-coreml"
        let base = ModelStorage.fluidAudioModelDirectory(repoFolder: folderName)
        guard FileManager.default.fileExists(atPath: base.path) else { return nil }
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: total)
    }

    /// Delete a downloaded Parakeet model from disk. Removes the entire
    /// model folder (Encoder.mlmodelc, Decoder.mlmodelc, tokenizer.json,
    /// etc.) so the next dictation triggers a fresh download.
    @discardableResult
    static func deleteModel(version: ParakeetModelVersion) -> Bool {
        guard let lease = try? ModelStorageActivity.shared.acquire(),
              (try? ModelStorage.validateCurrentRoot()) != nil else { return false }
        defer { withExtendedLifetime(lease) {} }

        let folderName = version == .v2 ? "parakeet-tdt-0.6b-v2-coreml" : "parakeet-tdt-0.6b-v3-coreml"
        let path = ModelStorage.fluidAudioModelDirectory(repoFolder: folderName)
        do {
            try FileManager.default.removeItem(at: path)
            print("[VoiceFlow] Deleted Parakeet \(version.rawValue) from \(path.path)")
            return true
        } catch {
            print("[VoiceFlow] Failed to delete Parakeet \(version.rawValue): \(error.localizedDescription)")
            return false
        }
    }
}

enum ParakeetError: LocalizedError {
    case modelNotLoaded
    case micPermissionDenied

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Parakeet model not loaded."
        case .micPermissionDenied: return "Microphone access denied."
        }
    }
}

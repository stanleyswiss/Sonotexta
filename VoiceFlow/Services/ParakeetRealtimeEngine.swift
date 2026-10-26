import FluidAudio
import AVFoundation

final class ParakeetRealtimeEngine: STTEngineProtocol {
    let engineType: STTEngineType = .parakeetRealtime
    var isAvailable: Bool { streamingManager != nil }
    var isModelLoaded: Bool { streamingManager != nil }
    var isLoading: Bool { modelLoader.isLoading }

    private let modelLoader = SharedModelLoader<StreamingEouAsrManager>()
    private var streamingManager: StreamingEouAsrManager? { modelLoader.value }
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
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var onResult: ((String, Bool) -> Void)?
    private var transcriptionTask: Task<Void, Never>?
    private var loadedChunkSize: ParakeetRealtimeChunkSize?
    private var configChangeObserver: NSObjectProtocol?
    private var isRestartingCapture = false

    func unloadModel() {
        modelLoader.invalidate()
    }

    func loadModel() async throws {
        let lease = try ModelStorageActivity.shared.acquire()
        defer { withExtendedLifetime(lease) {} }
        try ModelStorage.validateCurrentRoot()
        let selected = AppSettings.shared.selectedParakeetRealtimeChunkSize
        let root = ModelStorage.fluidAudioModelsRoot
        let directory = root.appendingPathComponent("parakeet-eou-streaming/\(selected.folderName)", isDirectory: true)
        _ = try await modelLoader.load(key: directory.path) { [weak self] in
            let encoder = directory.appendingPathComponent("streaming_encoder.mlmodelc")
            let decoder = directory.appendingPathComponent("decoder.mlmodelc")
            if !FileManager.default.fileExists(atPath: encoder.path) || !FileManager.default.fileExists(atPath: decoder.path) {
                let repo: Repo = selected == .ms160 ? .parakeetEou160 : .parakeetEou320
                try await DownloadUtils.downloadRepo(repo, to: root)
            }
            let manager = StreamingEouAsrManager(chunkSize: selected.libraryChunkSize)
            try await manager.loadModels(modelDir: directory)
            await manager.setPartialCallback { [weak self] partial in
                let engine = self
                Task { @MainActor in
                    guard let engine, engine.isTranscribing else { return }
                    engine.onResult?(partial, false)
                }
            }
            return manager
        }
        loadedChunkSize = selected
    }

    func startTranscription(locale: Locale, onResult: @escaping (String, Bool) -> Void) async throws {
        if isTranscribing {
            _ = await stopTranscription()
        }
        captureStopRequested = false

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw ParakeetRealtimeError.micPermissionDenied }
        default:
            throw ParakeetRealtimeError.micPermissionDenied
        }

        self.onResult = onResult
        bufferLock.withLock { audioBuffer.removeAll(keepingCapacity: true) }
        isTranscribing = !captureStopRequested
        isRestartingCapture = false

        // 3.16.5: capture BEFORE (lazy) model load. The tap only appends to
        // audioBuffer; the drain task below (which feeds the streaming
        // manager) is spawned after the model is up, so audio spoken during
        // the load is queued, not lost — previously the first half-sentence
        // after an engine switch vanished (field report).
        if !captureStopRequested { try await startAudioCapture() }

        do {
            print("[VoiceFlow] Parakeet Live model loading while capture buffers…")
            do {
                try await loadModel()
            } catch {
                _ = await stopTranscription()
                throw error
            }
        }
        guard let manager = streamingManager else {
            _ = await stopTranscription()
            throw ParakeetRealtimeError.modelNotLoaded
        }

        await manager.reset()

        let selected = loadedChunkSize ?? .ms160
        let samplesPerChunk = selected.libraryChunkSize.chunkSamples
        print("[VoiceFlow] Parakeet Live audio capture started")

        transcriptionTask = Task { [weak self] in
            while self?.isTranscribing == true {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.isTranscribing else { continue }

                let snapshot = self.bufferLock.withLock {
                    let captured = self.audioBuffer
                    self.audioBuffer.removeAll(keepingCapacity: true)
                    return captured
                }

                guard snapshot.count >= samplesPerChunk else {
                    self.bufferLock.withLock { self.audioBuffer.insert(contentsOf: snapshot, at: 0) }
                    continue
                }

                var offset = 0
                while offset + samplesPerChunk <= snapshot.count {
                    let slice = Array(snapshot[offset..<(offset + samplesPerChunk)])
                    offset += samplesPerChunk
                    if let pcm = self.floatArrayToPCMBuffer(slice) {
                        _ = try? await manager.process(audioBuffer: pcm)
                    }
                }

                if offset < snapshot.count {
                    let leftover = Array(snapshot[offset..<snapshot.count])
                    self.bufferLock.withLock { self.audioBuffer.insert(contentsOf: leftover, at: 0) }
                }
            }
        }
    }

    func pauseCapture() {
        captureStopRequested = true
        isTranscribing = false
        // Let an already-drained chunk batch finish before finalizing.
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

        let leftover = bufferLock.withLock {
            let captured = audioBuffer
            audioBuffer.removeAll()
            return captured
        }

        if !leftover.isEmpty, let pcm = floatArrayToPCMBuffer(leftover) {
            _ = try? await streamingManager?.process(audioBuffer: pcm)
        }

        var finalText: String?
        if let manager = streamingManager {
            do {
                finalText = try await manager.finish()
            } catch {
                // 3.16.4-beta.1: was `try?` — a failed finish looked like an
                // empty dictation. Log loudly so field reports carry evidence.
                print("[VoiceFlow] Parakeet Live FINISH FAILED: \(error.localizedDescription)")
            }
        }
        finalText = finalText?.trimmingCharacters(in: .whitespacesAndNewlines)

        // DO NOT fire onResult(text, true) here.
        //
        // Why: STTEngineProtocol's stop contract says the return value is
        // authoritative — callers prefer it over the callback to avoid the
        // race where a queued final callback hadn't applied before
        // DictationManager reads return state. Firing both made
        // DictationManager double-paste this engine's output in 3.16.0-beta.1
        // when the callback Task ran during the await-resume window BEFORE
        // stopDictation could set isDictating=false. Existing engines
        // (ParakeetEngine, WhisperEngine) only avoid the same race because
        // they fire onResult from a non-MainActor context, which queues the
        // callback behind stopDictation's continuation. Our actor-based
        // pipeline doesn't have that guarantee. Cleanest fix: just don't
        // fire the final callback. The return value covers it.

        await streamingManager?.reset()
        onResult = nil

        if let finalText, !finalText.isEmpty {
            return finalText
        }
        return nil
    }

    private func startAudioCapture() async throws {
        let engine = AVAudioEngine()
        AudioSessionHelper.configureSharedInput(for: engine)
        engine.inputNode.removeTap(onBus: 0)
        try installTap(on: engine)

        configChangeObserver = AudioSessionHelper.installReconfigObserver(
            for: engine,
            engineName: "parakeet-realtime",
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
        let resampler = LocalAudioResampler(logLabel: "parakeet-live")
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
        print("[Sonotexta][parakeet-realtime] restartCapture enter")
        guard isTranscribing else {
            print("[Sonotexta][parakeet-realtime] restartCapture skipped because capture is inactive")
            return
        }
        guard !isRestartingCapture else {
            print("[Sonotexta][parakeet-realtime] restartCapture already in progress")
            return
        }

        isRestartingCapture = true
        defer {
            isRestartingCapture = false
            print("[Sonotexta][parakeet-realtime] restartCapture exit")
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
            print("[Sonotexta][parakeet-realtime] restartCapture failed: \(error.localizedDescription)")
        }
    }

    private func floatArrayToPCMBuffer(_ array: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(array.count)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(array.count)
        guard let channelData = buffer.floatChannelData?[0] else {
            return nil
        }

        array.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channelData.update(from: baseAddress, count: array.count)
        }

        return buffer
    }

    static var isDownloaded: Bool {
        isDownloaded(chunkSize: AppSettings.shared.selectedParakeetRealtimeChunkSize)
    }

    static func isDownloaded(chunkSize: ParakeetRealtimeChunkSize) -> Bool {
        let modelDir = ModelStorage.fluidAudioModelDirectory(
            repoFolder: "parakeet-eou-streaming/\(chunkSize.folderName)")
        let encoderPath = modelDir.appendingPathComponent("streaming_encoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoderPath.path)
    }

    static func sizeOnDisk(chunkSize: ParakeetRealtimeChunkSize) -> String? {
        let modelDir = ModelStorage.fluidAudioModelDirectory(
            repoFolder: "parakeet-eou-streaming/\(chunkSize.folderName)")

        guard FileManager.default.fileExists(atPath: modelDir.path) else { return nil }

        let enumerator = FileManager.default.enumerator(
            at: modelDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )

        var totalSize = Int64(0)
        while let url = enumerator?.nextObject() as? URL {
            guard
                let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                resourceValues.isRegularFile == true,
                let fileSize = resourceValues.fileSize
            else {
                continue
            }
            totalSize += Int64(fileSize)
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }

    @discardableResult
    static func deleteModel(chunkSize: ParakeetRealtimeChunkSize) -> Bool {
        guard let lease = try? ModelStorageActivity.shared.acquire(),
              (try? ModelStorage.validateCurrentRoot()) != nil else { return false }
        defer { withExtendedLifetime(lease) {} }

        let modelDir = ModelStorage.fluidAudioModelDirectory(
            repoFolder: "parakeet-eou-streaming/\(chunkSize.folderName)")

        guard FileManager.default.fileExists(atPath: modelDir.path) else { return true }

        do {
            try FileManager.default.removeItem(at: modelDir)
            return true
        } catch {
            print("[VoiceFlow] Failed deleting Parakeet Live \(chunkSize.rawValue): \(error)")
            return false
        }
    }
}

enum ParakeetRealtimeError: LocalizedError {
    case modelNotLoaded
    case micPermissionDenied

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Parakeet Live model is not loaded."
        case .micPermissionDenied:
            return "Microphone permission is required for Parakeet Live dictation."
        }
    }
}

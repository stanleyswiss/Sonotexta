import WhisperKit
import AVFoundation

final class WhisperEngine: STTEngineProtocol {
    let engineType: STTEngineType = .whisper

    var isAvailable: Bool { whisperKit != nil }
    var isModelLoaded: Bool { whisperKit != nil }
    var isLoading: Bool { modelLoader.isLoading }

    private let modelLoader = SharedModelLoader<WhisperKit>()
    private var whisperKit: WhisperKit? { modelLoader.value }
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
    /// both touch this array, and Swift `[Float]` is not thread-safe. P2.3
    /// fix shipped in 3.14.0 after Codex audit flagged the race.
    ///
    /// 3.14.1: `NSLock` replaces the previous `DispatchQueue`-based design.
    /// `DispatchQueue.sync` from inside Swift Concurrency `Task`s blocks
    /// cooperative-pool threads in a way that caused the stop flow to stall
    /// in 3.14.0. NSLock is async-safe and has no thread-pool entanglement.
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var onResult: ((String, Bool) -> Void)?
    private var transcriptionTask: Task<Void, Never>?
    private var isRestartingCapture = false
    /// AVAudioEngineConfigurationChange observer — re-arms after Bluetooth
    /// profile flips that auto-stop AVAudioEngine.
    private var configChangeObserver: NSObjectProtocol?

    /// Whether to use Whisper's translate task (transcribe to English)
    var useTranslateTask = false

    /// Profile-driven input-language hint, set by DictationManager before each
    /// `startTranscription`. nil / "auto" → let Whisper auto-detect.
    /// A BCP-47 code like "bg-BG" is reduced to the 2-letter ISO code Whisper
    /// expects ("bg"). When the hint is set explicitly we PIN the decoder to
    /// that language for both partials and the final pass — auto-detection
    /// on Whisper-large noisy on short utterances and consistently mis-IDs
    /// Cyrillic dictation as Russian/Ukrainian/Macedonian.
    var inputLanguageHint: String?

    private var activeLanguageCode: String?

    func unloadModel() {
        modelLoader.invalidate()
    }

    func loadModel(name: String = "base") async throws {
        let lease = try ModelStorageActivity.shared.acquire()
        defer { withExtendedLifetime(lease) {} }
        try ModelStorage.validateCurrentRoot()
        let base = ModelStorage.whisperDownloadBase
        let key = "\(base?.path ?? "default")/\(name)"
        _ = try await modelLoader.load(key: key) {
            let config = WhisperKitConfig(model: "openai_whisper-\(name)", downloadBase: base)
            return try await WhisperKit(config)
        }
    }

    func startTranscription(locale: Locale, onResult: @escaping (String, Bool) -> Void) async throws {
        // Stop any existing transcription first
        if isTranscribing {
            _ = await stopTranscription()
        }
        captureStopRequested = false

        // Resolve the 2-letter Whisper language code from the explicit hint set
        // by DictationManager. nil / "auto" → let WhisperKit auto-detect.
        activeLanguageCode = Self.whisperLanguageCode(fromHint: inputLanguageHint)

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus != .authorized {
            if micStatus == .notDetermined {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw WhisperError.micPermissionDenied }
            } else { throw WhisperError.micPermissionDenied }
        }

        self.onResult = onResult
        bufferLock.withLock { self.audioBuffer = [] }
        self.isTranscribing = !captureStopRequested
        self.isRestartingCapture = false

        // 3.16.5: capture BEFORE (lazy) model load. Previously the first
        // dictation after an engine switch dropped everything said during
        // the multi-second model load (field report: first half-sentence
        // missing). The tap only appends to audioBuffer, so audio spoken
        // while the model warms up is transcribed once it's ready.
        if !captureStopRequested { try await startAudioCapture() }

        do {
            print("[VoiceFlow][whisper] model loading while capture buffers…")
            let selectedModel = AppSettings.shared.selectedWhisperModel.rawValue
            do {
                try await loadModel(name: selectedModel)
            } catch {
                _ = await stopTranscription()
                throw error
            }
            guard whisperKit != nil else {
                _ = await stopTranscription()
                throw WhisperError.modelNotLoaded
            }
        }

        let wk = whisperKit!
        let translateTask = useTranslateTask
        let taskType: String = translateTask ? "translate" : "transcribe"
        print("[VoiceFlow] Whisper capture started (task: \(taskType))")

        transcriptionTask = Task { [weak self] in
            while self?.isTranscribing == true {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isTranscribing else { continue }
                // Snapshot the buffer atomically before transcribing so a
                // tap append mid-transcribe can't corrupt our copy. The
                // lock is held only for the duration of the array copy
                // (microseconds) — the heavy `wk.transcribe` work happens
                // outside the lock.
                let currentAudio = self.bufferLock.withLock { self.audioBuffer }
                guard currentAudio.count > 16000 else { continue }

                let options = DecodingOptions(task: translateTask ? .translate : .transcribe, language: self.activeLanguageCode)
                let results = try? await wk.transcribe(audioArray: currentAudio, decodeOptions: options)

                // 3.14.1-beta.3 fix: WhisperKit's `transcribe` is a long
                // synchronous-feeling await that does NOT honor Task
                // cancellation. If the user pressed stop while we were
                // inside the await, `isTranscribing` is already false by
                // the time we get here. Emitting a partial now puts a
                // ghost late event into DictationManager — its `!isStopping`
                // guard prevents double-paste, but `currentTranscription`
                // still gets overwritten by the stale partial, which can
                // present as "the text appeared twice" in the overlay.
                guard self.isTranscribing else {
                    print("[VoiceFlow][whisper] periodic transcribe finished post-stop — dropping late partial (\(results?.first?.text.count ?? 0) chars)")
                    continue
                }

                if let text = results?.first?.text, !text.isEmpty {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !trimmed.hasPrefix("[BLANK") {
                        print("[VoiceFlow][whisper] partial emit len=\(trimmed.count)")
                        self.onResult?(trimmed, false)
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
        if let whisperKit, !bufferSnapshot.isEmpty {
            print("[VoiceFlow][whisper] final transcribe starting (samples=\(bufferSnapshot.count))")
            let tFinal = Date()
            let options = DecodingOptions(task: useTranslateTask ? .translate : .transcribe, language: activeLanguageCode)
            var results: [TranscriptionResult]?
            do {
                results = try await whisperKit.transcribe(audioArray: bufferSnapshot, decodeOptions: options)
            } catch {
                // 3.16.4-beta.1: the FINAL transcribe used to be `try?` — an
                // inference failure was indistinguishable from silence in the
                // field. Log loudly; empty-result handling below still applies.
                print("[VoiceFlow][whisper] FINAL TRANSCRIBE FAILED: \(error.localizedDescription)")
            }
            print("[VoiceFlow][whisper] final transcribe completed (+\(String(format: "%.2f", Date().timeIntervalSince(tFinal)))s)")
            if let text = results?.first?.text, !text.isEmpty {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !trimmed.hasPrefix("[BLANK") {
                    print("[VoiceFlow][whisper] final emit len=\(trimmed.count)")
                    finalText = trimmed
                    onResult?(trimmed, true)
                }
            }
        }
        onResult = nil
        activeLanguageCode = nil
        return finalText
    }

    private func startAudioCapture() async throws {
        let engine = AVAudioEngine()
        AudioSessionHelper.configureSharedInput(for: engine)
        engine.inputNode.removeTap(onBus: 0)
        try installTap(on: engine)

        configChangeObserver = AudioSessionHelper.installReconfigObserver(
            for: engine,
            engineName: "whisper",
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
        let resampler = LocalAudioResampler(logLabel: "whisper")
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
        print("[Sonotexta][whisper] restartCapture enter")
        guard isTranscribing else {
            print("[Sonotexta][whisper] restartCapture skipped because capture is inactive")
            return
        }
        guard !isRestartingCapture else {
            print("[Sonotexta][whisper] restartCapture already in progress")
            return
        }

        isRestartingCapture = true
        defer {
            isRestartingCapture = false
            print("[Sonotexta][whisper] restartCapture exit")
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
            print("[Sonotexta][whisper] restartCapture failed: \(error.localizedDescription)")
        }
    }

    /// Reduce a profile's input-language hint into the 2-letter ISO code that
    /// WhisperKit's `DecodingOptions(language:)` expects. Returns nil for
    /// "auto" / nil so the model picks the language itself.
    static func whisperLanguageCode(fromHint hint: String?) -> String? {
        guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.lowercased() != "auto" else { return nil }
        let lower = raw.lowercased()
        if let dash = lower.firstIndex(of: "-") {
            return String(lower[..<dash])
        }
        return String(lower.prefix(2))
    }
}

enum WhisperError: LocalizedError {
    case modelNotLoaded
    case audioFormatError
    case micPermissionDenied

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Whisper model not loaded."
        case .audioFormatError: return "Could not configure audio format."
        case .micPermissionDenied: return "Microphone access denied."
        }
    }
}

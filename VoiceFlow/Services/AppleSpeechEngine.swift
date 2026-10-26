import Speech
import AVFoundation

final class AppleSpeechEngine: STTEngineProtocol {
    let engineType: STTEngineType = .appleSpeech

    var isAvailable: Bool {
        SFSpeechRecognizer()?.isAvailable ?? false
    }

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var isTranscribing = false
    private var isRestartingCapture = false
    /// AVAudioEngineConfigurationChange observer — re-arms after Bluetooth
    /// profile flips that auto-stop AVAudioEngine.
    private var configChangeObserver: NSObjectProtocol?

    /// Continuation that resolves when the recognizer produces its final result (or times out).
    /// Set up in stopTranscription, fulfilled by the recognition callback when isFinal==true.
    private var finalResultContinuation: CheckedContinuation<Void, Never>?
    private var hasResolvedFinal = false
    /// Last text emitted by the recognizer — captured on every callback so we can return
    /// the most recent transcription from stopTranscription even if isFinal never fires.
    private var lastTranscriptText = ""

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func startTranscription(locale: Locale, onResult: @escaping (String, Bool) -> Void) async throws {
        let status = await Self.requestAuthorization()
        guard status == .authorized else {
            throw SpeechError.notAuthorized
        }

        // Use default recognizer for auto-detect, or locale-specific if provided
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        self.recognitionRequest = request
        self.isTranscribing = true
        self.hasResolvedFinal = false
        self.lastTranscriptText = ""
        self.isRestartingCapture = false

        try await startAudioCapture()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                self.lastTranscriptText = text
                onResult(text, isFinal)
                if isFinal {
                    self.resolveFinalContinuation()
                }
            }

            if error != nil || result?.isFinal == true {
                self.isTranscribing = false
                self.audioEngine?.stop()
                self.audioEngine?.inputNode.removeTap(onBus: 0)
                // Resume the stop-waiter even on error so we don't hang forever.
                self.resolveFinalContinuation()
            }
        }
    }

    func stopTranscription() async -> String? {
        // Signal end of audio so the recognizer produces its final result naturally.
        // Do NOT call cancel() — that aborts without delivering the final.
        isTranscribing = false
        recognitionRequest?.endAudio()

        // Wait up to 1.5s for the recognizer to deliver isFinal==true. If it doesn't,
        // we still proceed with whatever last partial we got — better than dropping.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Race: isFinal may have already fired between endAudio() and here.
            if hasResolvedFinal {
                continuation.resume()
                return
            }
            finalResultContinuation = continuation

            // Timeout safety — never block stop indefinitely.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.resolveFinalContinuation()
            }
        }

        // Snapshot before cleanup.
        let finalText = lastTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        // Only after the final has landed (or timed out) do we tear down.
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)

        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
        lastTranscriptText = ""
        isRestartingCapture = false

        return finalText.isEmpty ? nil : finalText
    }

    private func startAudioCapture() async throws {
        guard let request = recognitionRequest else {
            throw SpeechError.recognizerUnavailable
        }

        let engine = AVAudioEngine()
        AudioSessionHelper.configureSharedInput(for: engine)
        engine.inputNode.removeTap(onBus: 0)
        try installTap(on: engine, request: request)

        configChangeObserver = AudioSessionHelper.installReconfigObserver(
            for: engine,
            engineName: "apple-speech",
            isActive: { [weak self] in self?.isTranscribing ?? false },
            setupTap: { [weak self] reconfigEngine in
                guard let self, let request = self.recognitionRequest else { return }
                try self.installTap(on: reconfigEngine, request: request)
            },
            onFatal: { [weak self] in
                Task { await self?.restartCapture() }
            }
        )

        try await AudioSessionHelper.startEngine(engine)
        audioEngine = engine
    }

    private func installTap(on engine: AVAudioEngine, request: SFSpeechAudioBufferRecognitionRequest) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, self.isTranscribing else { return }
            request.append(buffer)
        }
    }

    private func restartCapture() async {
        print("[Sonotexta][apple-speech] restartCapture enter")
        guard isTranscribing else {
            print("[Sonotexta][apple-speech] restartCapture skipped because capture is inactive")
            return
        }
        guard !isRestartingCapture else {
            print("[Sonotexta][apple-speech] restartCapture already in progress")
            return
        }
        guard recognitionRequest != nil else {
            print("[Sonotexta][apple-speech] restartCapture skipped because recognition request is missing")
            return
        }

        isRestartingCapture = true
        defer {
            isRestartingCapture = false
            print("[Sonotexta][apple-speech] restartCapture exit")
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
            print("[Sonotexta][apple-speech] restartCapture failed: \(error.localizedDescription)")
        }
    }

    /// Idempotent: safe to call from the recognition callback, the timeout, AND the error path.
    private func resolveFinalContinuation() {
        guard !hasResolvedFinal else { return }
        hasResolvedFinal = true
        finalResultContinuation?.resume()
        finalResultContinuation = nil
    }
}

enum SpeechError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition not authorized"
        case .recognizerUnavailable: return "Speech recognizer unavailable"
        }
    }
}
